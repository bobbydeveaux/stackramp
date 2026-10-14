#!/usr/bin/env python3
"""Tests for detect.py: python3 platform-action/changes/test_detect.py"""
import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from detect import glob_to_regex  # noqa: E402

# Shaped like ButlerJames: API and worker share api/, browser has its own dir.
CONFIG = {
    "name": "app",
    "frontend": {"framework": "react", "dir": "frontend"},
    "backend": {"language": "go", "dir": "api"},
    "backends": [
        {"name": "worker", "language": "go", "dir": "api"},
        {"name": "browser", "language": "node", "dir": "browser", "watch_paths": ["shared/**"]},
    ],
}
MACHINE = [
    {"name": "worker", "language": "go", "dir": "api"},
    {"name": "browser", "language": "node", "dir": "browser"},
]


def run(changed, force="", config=None):
    with tempfile.NamedTemporaryFile("r", delete=False) as out:
        path = out.name
    env = dict(os.environ)
    env.update({
        "CONFIG_JSON": json.dumps(config or CONFIG),
        "CONFIG_PATH": "stackramp.yaml",
        "CALLER_WORKFLOW": ".github/workflows/deploy.yml",
        "FORCE_REASON": force,
        "APP_NAME": "app",
        "HAS_FRONTEND": "true", "HAS_BACKEND": "true", "HAS_MCP": "false", "HAS_KUBERNETES": "false",
        "FRONTEND_DIR": "frontend", "BACKEND_DIR": "api", "BACKEND_LANGUAGE": "go",
        "MACHINE_BACKENDS": json.dumps(MACHINE),
        "GITHUB_OUTPUT": path,
    })
    env.pop("GITHUB_STEP_SUMMARY", None)
    if changed is None:
        env.pop("CHANGED_FILES", None)
    else:
        env["CHANGED_FILES"] = json.dumps(changed)
    subprocess.run([sys.executable, os.path.join(HERE, "detect.py")], env=env, check=True, capture_output=True)
    res = dict(line.split("=", 1) for line in open(path).read().splitlines())
    os.unlink(path)
    res["machines"] = [m["name"] for m in json.loads(res["machine_deploy"])]
    return res


class Globs(unittest.TestCase):
    def test_semantics(self):
        self.assertTrue(glob_to_regex("api/**").match("api/x/y.go"))
        self.assertTrue(glob_to_regex("api/**").match("api"))
        self.assertFalse(glob_to_regex("api/**").match("apix/y.go"))
        self.assertTrue(glob_to_regex("*.md").match("README.md"))
        self.assertFalse(glob_to_regex("*.md").match("docs/a.md"))
        self.assertTrue(glob_to_regex("**/README.md").match("README.md"))
        self.assertTrue(glob_to_regex("**/README.md").match("a/b/README.md"))
        self.assertTrue(glob_to_regex("**/*.{ts,tsx}").match("a/b.tsx"))
        self.assertTrue(glob_to_regex(".github/**").match(".github/workflows/x.yml"))


class Detect(unittest.TestCase):
    def test_docs_only_deploys_nothing(self):
        r = run(["docs/MANUAL_RESOURCES.md", "README.md", "marketing/a.mp4", "brand/logo.svg"])
        self.assertEqual(r["any_deploy"], "false")
        self.assertEqual(r["build_groups"], "[]")

    def test_shared_dir_deploys_api_and_worker_with_one_build(self):
        r = run(["api/main.go"])
        self.assertEqual((r["deploy_backend"], r["deploy_frontend"]), ("true", "false"))
        self.assertEqual(r["machines"], ["worker"])
        groups = json.loads(r["build_groups"])
        self.assertEqual(groups, [{"dir": "api", "language": "go", "images": "app app-worker"}])

    def test_browser_only(self):
        r = run(["browser/server.mjs"])
        self.assertEqual(r["machines"], ["browser"])
        self.assertEqual(r["deploy_backend"], "false")

    def test_watch_paths(self):
        self.assertEqual(run(["shared/lib.js"])["machines"], ["browser"])

    def test_ignored_file_inside_service_dir(self):
        self.assertEqual(run(["api/README.md"])["any_deploy"], "false")

    def test_config_change_deploys_everything(self):
        r = run(["stackramp.yaml"])
        self.assertEqual(r["full_deploy"], "true")
        self.assertEqual(r["config_changed"], "true")
        self.assertEqual(r["machines"], ["worker", "browser"])

    def test_caller_workflow_change_deploys_everything(self):
        self.assertEqual(run([".github/workflows/deploy.yml"])["full_deploy"], "true")
        self.assertEqual(run([".github/workflows/ci.yml"])["any_deploy"], "false")

    def test_forced_and_unknown(self):
        self.assertEqual(run([], force="manual run")["full_deploy"], "true")
        self.assertEqual(run(None)["full_deploy"], "true")

    def test_config_ignore_and_full_paths(self):
        cfg = dict(CONFIG, deploy={"ignore_paths": ["frontend/**/*.test.ts"], "full_deploy_paths": ["go.work"]})
        self.assertEqual(run(["frontend/src/a.test.ts"], config=cfg)["any_deploy"], "false")
        self.assertEqual(run(["go.work"], config=cfg)["full_deploy"], "true")
        cfg = dict(CONFIG, deploy={"default_ignore_paths": False})
        self.assertEqual(run(["api/README.md"], config=cfg)["deploy_backend"], "true")


if __name__ == "__main__":
    unittest.main()
