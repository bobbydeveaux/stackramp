#!/usr/bin/env python3
"""Tests for fingerprint.sh: python3 providers/gcp/workflows/build-image/test_fingerprint.py"""
import os
import re
import shutil
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "fingerprint.sh")
ACTION_REL = "providers/gcp/workflows/build-image"


def fp(root, context, language):
    out = subprocess.run(
        ["bash", os.path.join(root, ACTION_REL, "fingerprint.sh"), context, language],
        check=True, capture_output=True, text=True,
    )
    return out.stdout.strip()


class FingerprintTest(unittest.TestCase):
    def setUp(self):
        # A fake stackramp checkout with the same layout as the real one.
        self.root = tempfile.mkdtemp()
        action_dir = os.path.join(self.root, ACTION_REL)
        os.makedirs(action_dir)
        shutil.copy(SCRIPT, action_dir)
        self.write(f"{ACTION_REL}/action.yml", "name: build-image\n")
        self.write("platform-action/dockerfiles/go.Dockerfile", "FROM golang:1.25-alpine\n")
        self.write("platform-action/dockerfiles/python.Dockerfile", "FROM python:3.12-slim\n")
        self.app = tempfile.mkdtemp()
        os.makedirs(os.path.join(self.app, "api"))

    def tearDown(self):
        shutil.rmtree(self.root)
        shutil.rmtree(self.app)

    def write(self, rel, text, base=None):
        path = os.path.join(base or self.root, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(text)

    def api(self):
        return os.path.join(self.app, "api")

    def test_format_and_stable(self):
        a = fp(self.root, self.api(), "go")
        self.assertRegex(a, r"^[0-9a-f]{12}$")
        self.assertEqual(a, fp(self.root, self.api(), "go"))

    def test_own_language_dockerfile_changes_it(self):
        before = fp(self.root, self.api(), "go")
        self.write("platform-action/dockerfiles/go.Dockerfile", "FROM golang:1.26-alpine\n")
        self.assertNotEqual(before, fp(self.root, self.api(), "go"))

    def test_other_language_dockerfile_does_not(self):
        before = fp(self.root, self.api(), "go")
        self.write("platform-action/dockerfiles/python.Dockerfile", "FROM python:3.13-slim\n")
        self.assertEqual(before, fp(self.root, self.api(), "go"))

    def test_language_matters(self):
        self.assertNotEqual(fp(self.root, self.api(), "go"), fp(self.root, self.api(), "python"))

    def test_action_change_changes_it(self):
        before = fp(self.root, self.api(), "go")
        self.write(f"{ACTION_REL}/action.yml", "name: build-image\n# new flag\n")
        self.assertNotEqual(before, fp(self.root, self.api(), "go"))

    def test_custom_dockerfile_ignores_platform_dockerfile(self):
        self.write("api/Dockerfile", "FROM scratch\n", base=self.app)
        before = fp(self.root, self.api(), "go")
        # The language only picks a platform Dockerfile, which isn't used here.
        self.assertEqual(before, fp(self.root, self.api(), "python"))
        self.write("platform-action/dockerfiles/go.Dockerfile", "FROM golang:1.26-alpine\n")
        self.assertEqual(before, fp(self.root, self.api(), "go"))
        # ...but the build recipe still counts.
        self.write(f"{ACTION_REL}/action.yml", "name: build-image\n# new flag\n")
        self.assertNotEqual(before, fp(self.root, self.api(), "go"))

    def test_relative_context_from_app_cwd(self):
        # The action runs from the app checkout with a relative context dir.
        absolute = fp(self.root, self.api(), "go")
        out = subprocess.run(
            ["bash", os.path.join(self.root, ACTION_REL, "fingerprint.sh"), "api", "go"],
            check=True, capture_output=True, text=True, cwd=self.app,
        ).stdout.strip()
        self.assertEqual(absolute, out)

    def test_real_checkout(self):
        repo = os.path.abspath(os.path.join(HERE, "..", "..", "..", ".."))
        for lang in ("go", "python", "node", "rust"):
            self.assertTrue(os.path.isfile(os.path.join(repo, f"platform-action/dockerfiles/{lang}.Dockerfile")))
            self.assertRegex(fp(repo, self.api(), lang), re.compile(r"^[0-9a-f]{12}$"))


if __name__ == "__main__":
    unittest.main()
