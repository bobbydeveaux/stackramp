#!/usr/bin/env python3
"""Tests for platform-secrets.sh: python3 providers/gcp/workflows/platform-secrets/test_platform_secrets.py

gcloud is stubbed; the real filter syntax was checked against Secret Manager
by hand (see the PR that added this action).
"""
import os
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "platform-secrets.sh")


def run(*args, names="", any_secret="", fail=False):
    """Run the script with a gcloud stub. `names` answers the scoped listing,
    `any_secret` the unscoped --limit=1 one. Returns (result, calls), each
    call a list of its arguments."""
    with tempfile.TemporaryDirectory() as tmp:
        log = os.path.join(tmp, "calls")
        stub = os.path.join(tmp, "gcloud")
        with open(stub, "w") as f:
            f.write(
                "#!/bin/sh\n"
                f'{{ printf "%s\\037" "$@"; echo; }} >> "{log}"\n'
                f'{"exit 1" if fail else ":"}\n'
                'case " $* " in *" --limit=1 "*) '
                f'printf "{any_secret}" ;; *) printf "{names}" ;; esac\n'
            )
        os.chmod(stub, 0o755)
        env = dict(os.environ, PATH=tmp + os.pathsep + os.environ["PATH"])
        out = subprocess.run(["bash", SCRIPT, *args], env=env, capture_output=True, text=True)
        calls = []
        if os.path.exists(log):
            calls = [line.rstrip("\037").split("\037") for line in open(log).read().splitlines()]
        return out, calls


def filt(app, env):
    out, _ = run("--filter", app, env)
    assert out.returncode == 0, out.stderr
    return out.stdout.strip()


class PlatformSecretsTest(unittest.TestCase):
    def expect(self, app, env):
        return ("labels.platform-inject=true AND "
                f"(-labels.platform-app:* OR labels.platform-app={app}) AND "
                f"(-labels.platform-env:* OR labels.platform-env={env})")

    def test_dev_and_prod(self):
        self.assertEqual(filt("butlerjames", "dev"), self.expect("butlerjames", "dev"))
        self.assertEqual(filt("butlerjames", "prod"), self.expect("butlerjames", "prod"))

    def test_preview_is_dev(self):
        self.assertEqual(filt("butlerjames", "pr-305"), self.expect("butlerjames", "dev"))

    def test_normalised_to_label_value(self):
        self.assertEqual(filt("My_App.v2", "Prod"), self.expect("my_app-v2", "prod"))
        self.assertEqual(len(filt("a" * 80, "dev").split("platform-app=")[1].split(")")[0]), 63)

    def test_missing_inputs_fail(self):
        out, _ = run("--filter", "", "dev")
        self.assertNotEqual(out.returncode, 0)
        out, _ = run("proj", "app", "")
        self.assertNotEqual(out.returncode, 0)

    def test_refs_and_gcloud_call(self):
        out, calls = run("proj", "butlerjames", "prod", names="A_KEY\\nBJ_PROD_X\\n")
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(out.stdout.splitlines(), [
            "secret_refs=A_KEY=A_KEY:latest,BJ_PROD_X=BJ_PROD_X:latest",
            "clear_secrets=false",
        ])
        self.assertEqual(len(calls), 1)  # no second listing when something matched
        self.assertIn("--project=proj", calls[0])
        self.assertIn("--filter=" + self.expect("butlerjames", "prod"), calls[0])
        self.assertIn("--format=value(name.basename())", calls[0])

    def test_none_match_but_project_has_platform_secrets(self):
        out, calls = run("proj", "app", "dev", names="", any_secret="OTHER_APP_KEY\\n")
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(out.stdout.splitlines(), ["secret_refs=", "clear_secrets=true"])
        self.assertIn("--filter=labels.platform-inject=true", calls[1])

    def test_project_without_platform_secrets(self):
        out, _ = run("proj", "app", "dev", names="", any_secret="")
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(out.stdout.splitlines(), ["secret_refs=", "clear_secrets=false"])

    def test_gcloud_failure_fails(self):
        out, _ = run("proj", "app", "dev", names="X\\n", fail=True)
        self.assertNotEqual(out.returncode, 0)
        self.assertEqual(out.stdout, "")


if __name__ == "__main__":
    unittest.main()
