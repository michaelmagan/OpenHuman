import os
import re
import subprocess
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))
SCRIPTS = [
    "Tools/bootstrap.sh",
    "Tools/ci/build-app.sh",
    "Tools/ci/build-ios-app.sh",
    "Tools/ci/build-packages.sh",
    "Tools/ci/package-app.sh",
    "Tools/release/bump-version.sh",
    "Tools/release/check-release.sh",
    "Tools/release/install-release-tools.sh",
    "Tools/release/make-dmg.sh",
    "Tools/release/publish-github.sh",
    "Tools/render-ios.sh",
    "Tools/render-sweep.sh",
    "Tools/signing/setup.sh",
    "Tools/signing/verify.sh",
]
NOT_FOR_USERS = re.compile(r"§|\bagents?\b|\bauthor\b", re.IGNORECASE)
REPO_PATH = re.compile(r"\b(?:Apps|Packages|Tools|docs)/[\w./*-]*\w")
READS_OWN_SOURCE = re.compile(r"\b(?:sed|awk)\b[^\n]*\"\$0\"")


def run(script, *args):
    return subprocess.run(["bash", os.path.join(ROOT, script), *args], cwd=ROOT, capture_output=True, text=True)


class ScriptHelpTests(unittest.TestCase):
    def test_help_prints_usage_and_exits_zero(self):
        for script in SCRIPTS:
            for flag in ("--help", "-h"):
                with self.subTest(script=script, flag=flag):
                    result = run(script, flag)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertTrue(result.stdout.startswith("Usage: "), result.stdout[:200])
                    self.assertEqual(result.stderr, "")

    def test_help_text_is_for_users(self):
        for script in SCRIPTS:
            with self.subTest(script=script):
                text = run(script, "--help").stdout
                self.assertIsNone(NOT_FOR_USERS.search(text), NOT_FOR_USERS.search(text))
                for path in REPO_PATH.findall(text):
                    folder = os.path.dirname(path.split("*", 1)[0].rstrip("/"))
                    self.assertTrue(os.path.isdir(os.path.join(ROOT, folder)), path)

    def test_help_is_not_read_from_the_scripts_own_comments(self):
        for script in SCRIPTS:
            with self.subTest(script=script):
                with open(os.path.join(ROOT, script), encoding="utf-8") as handle:
                    source = handle.read()
                self.assertIsNone(READS_OWN_SOURCE.search(source), READS_OWN_SOURCE.search(source))

    def test_package_app_without_arguments_prints_usage_and_fails(self):
        result = run("Tools/ci/package-app.sh")
        self.assertEqual(result.returncode, 2)
        self.assertTrue(result.stderr.startswith("Usage: "), result.stderr[:200])


if __name__ == "__main__":
    unittest.main()
