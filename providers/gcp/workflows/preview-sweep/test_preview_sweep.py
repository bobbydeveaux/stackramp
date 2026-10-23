#!/usr/bin/env python3
"""Tests for preview-sweep.sh and pr-closed.sh:
python3 providers/gcp/workflows/preview-sweep/test_preview_sweep.py

gcloud and curl are stubbed (needs bash and jq). The listing was also run for
real, read-only and dry-run, against bj-platform-dev (see the PR that added
this action).
"""
import json
import os
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SWEEP = os.path.join(HERE, "preview-sweep.sh")
PR_CLOSED = os.path.join(HERE, "..", "..", "..", "..", "platform-action", "pr-closed", "pr-closed.sh")

STUB = r'''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
with open(os.environ["STUB_CFG"]) as f:
    cfg = json.load(f)
with open(os.environ["STUB_LOG"], "a") as f:
    f.write(json.dumps([os.path.basename(sys.argv[0])] + args) + "\n")
name = os.path.basename(sys.argv[0])
if name == "gcloud":
    if args[:3] == ["run", "services", "list"]:
        if cfg.get("list_fails"):
            sys.exit(1)
        print(json.dumps(cfg["services"]))
    elif args[:2] == ["auth", "print-access-token"]:
        print("tok")
    elif args[:3] == ["run", "services", "describe"]:
        sys.exit(1)  # gone
    sys.exit(0)
# curl
url = [a for a in args if a.startswith("http")][0]
if "DELETE" in args:
    print("200", end="")
elif "/sites?" in url:
    print(json.dumps({"sites": [{"name": "projects/p/sites/" + s} for s in cfg["sites"]]}))
elif "/channels?" in url:
    print(json.dumps({"channels": [{"name": "sites/x/channels/" + c} for c in cfg["channels"]]}))
elif "/pulls/" in url:
    n = url.rsplit("/", 1)[1]
    st = cfg["prs"].get(n)
    if st is None:
        sys.exit(22)
    print(json.dumps({"number": int(n), "state": st}))
'''


def svc(name, labels=None):
    return {"metadata": {"name": name, "labels": labels or {}}}


SERVICES = [
    svc("butlerjames-dev"), svc("butlerjames-worker-dev"), svc("butlerjames-prod"),
    svc("butlerjames-pr-5"), svc("butlerjames-worker-pr-5"), svc("butlerjames-browser-pr-7"),
    # a backend since removed from stackramp.yaml, found by its labels
    svc("butlerjames-voicebridge-pr-5", {"stackramp-app": "butlerjames", "stackramp-pr": "5"}),
    # not this app's, or not previews: never touched
    svc("butlerjames-other-pr-5"),           # unknown name, no labels
    svc("butlerjamesx-pr-5"),                # another app
    svc("butlerjames-worker-pr-5x"),         # not digits
    svc("butlerjames-worker-pr-"),
    svc("qbot-pr-5", {"stackramp-app": "qbot", "stackramp-pr": "5"}),
    svc("butlerjames-odd", {"stackramp-app": "butlerjames", "stackramp-pr": "5"}),  # name mismatch
]
BACKENDS = json.dumps([{"name": ""}, {"name": "worker"}, {"name": "browser"}])


def run(script, args=(), env=None, cfg=None):
    cfg = dict({"services": SERVICES, "sites": ["butlerjames-ab12c-dev", "butlerjames-zz99z-prod"],
                "channels": ["live", "pr-5", "pr-7", "pr-12"],
                "prs": {"5": "closed", "7": "open", "12": "closed"}}, **(cfg or {}))
    with tempfile.TemporaryDirectory() as tmp:
        log = os.path.join(tmp, "calls")
        cfg_path = os.path.join(tmp, "cfg.json")
        with open(cfg_path, "w") as f:
            json.dump(cfg, f)
        for name in ("gcloud", "curl"):
            p = os.path.join(tmp, name)
            with open(p, "w") as f:
                f.write(STUB)
            os.chmod(p, 0o755)
        e = dict(os.environ, PATH=tmp + os.pathsep + os.environ["PATH"], STUB_CFG=cfg_path,
                 STUB_LOG=log, APP_NAME="butlerjames", BACKENDS=BACKENDS, PROJECT="p",
                 REGION="r", REPO="o/butlerjames", GH_TOKEN="t", DRY_RUN="false")
        e.pop("GITHUB_STEP_SUMMARY", None)
        e.pop("PR_NUM", None)
        e.update(env or {})
        out = subprocess.run(["bash", script, *args], env=e, capture_output=True, text=True)
        calls = []
        if os.path.exists(log):
            with open(log) as f:
                calls = [json.loads(l) for l in f]
        return out, calls


def deleted_services(calls):
    return sorted(c[4] for c in calls if c[0] == "gcloud" and c[1:4] == ["run", "services", "delete"])


def deleted_channels(calls):
    return sorted([a for a in c if a.startswith("http")][0].rsplit("/", 1)[1]
                  for c in calls if c[0] == "curl" and "DELETE" in c)


def github_calls(calls):
    return [c for c in calls if c[0] == "curl" and any("/pulls/" in a for a in c)]


class SweepTest(unittest.TestCase):
    def test_sweep_deletes_only_closed_prs_of_this_app(self):
        out, calls = run(SWEEP)
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        self.assertEqual(deleted_services(calls), [
            "butlerjames-pr-5", "butlerjames-voicebridge-pr-5", "butlerjames-worker-pr-5"])
        self.assertEqual(deleted_channels(calls), ["pr-12", "pr-5"])
        # one state lookup per PR found
        self.assertEqual(len(github_calls(calls)), 3)

    def test_dry_run_deletes_nothing(self):
        out, calls = run(SWEEP, env={"DRY_RUN": "true"})
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(deleted_services(calls), [])
        self.assertEqual(deleted_channels(calls), [])
        self.assertIn("PR #5 [closed] would delete", out.stdout)
        self.assertIn("PR #7 [open] keep", out.stdout)

    def test_cleanup_mode_one_pr_no_github(self):
        out, calls = run(SWEEP, env={"PR_NUM": "7"})
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(deleted_services(calls), ["butlerjames-browser-pr-7"])
        self.assertEqual(deleted_channels(calls), ["pr-7"])
        self.assertEqual(github_calls(calls), [])

    def test_unknown_state_is_kept(self):
        out, calls = run(SWEEP, cfg={"prs": {"7": "open"}})
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(deleted_services(calls), [])
        self.assertIn("state unknown", out.stdout)

    def test_list_failure_fails(self):
        out, calls = run(SWEEP, cfg={"list_fails": True})
        self.assertNotEqual(out.returncode, 0)
        self.assertEqual(deleted_services(calls), [])

    def test_prefix_is_exact(self):
        # app "qbot" must not match app "qbot-ai"'s previews
        out, calls = run(SWEEP, env={"APP_NAME": "qbot", "BACKENDS": "[]"},
                         cfg={"services": [svc("qbot-ai-pr-5"), svc("qbot-pr-5"), svc("qbot-fe-pr-5")],
                              "sites": [], "channels": []})
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(deleted_services(calls), ["qbot-fe-pr-5", "qbot-pr-5"])

    def test_no_single_dev_site_skips_channels(self):
        out, calls = run(SWEEP, cfg={"sites": ["butlerjames-aaaaa-dev", "butlerjames-bbbbb-dev"]})
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(deleted_channels(calls), [])
        self.assertEqual(len(deleted_services(calls)), 3)


class PrClosedTest(unittest.TestCase):
    def outputs(self, env_name, prs):
        out, calls = run(PR_CLOSED, args=(env_name, "o/r"), cfg={"prs": prs})
        self.assertEqual(out.returncode, 0, out.stderr)
        return dict(l.split("=", 1) for l in out.stdout.split()), calls

    def test_not_a_preview(self):
        for env_name in ("dev", "prod", "pr-", "pr-5x"):
            o, calls = self.outputs(env_name, {})
            self.assertEqual(o["closed"], "false")
            self.assertEqual(calls, [])

    def test_closed_and_open(self):
        self.assertEqual(self.outputs("pr-5", {"5": "closed"})[0], {"closed": "true", "pr": "5"})
        self.assertEqual(self.outputs("pr-5", {"5": "open"})[0], {"closed": "false", "pr": "5"})

    def test_fails_open(self):
        self.assertEqual(self.outputs("pr-5", {})[0]["closed"], "false")


if __name__ == "__main__":
    unittest.main()
