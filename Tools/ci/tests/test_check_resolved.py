import importlib.util
import os
import subprocess
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("check_resolved", os.path.join(HERE, "..", "check-resolved.py"))
cr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cr)


def resolved(*pins):
    return {"pins": [{"identity": i, "kind": "remoteSourceControl", "state": {"version": v, "revision": r}}
                     for i, v, r in pins]}


class CheckResolvedTests(unittest.TestCase):
    def test_matching_pins_pass(self):
        self.assertEqual(cr.mismatches({"A/Package.resolved": resolved(("grdb.swift", "7.11.1", "abc")),
                                        "B/Package.resolved": resolved(("grdb.swift", "7.11.1", "abc"),
                                                                       ("swiftsoup", "2.14.1", "def"))}), [])

    def test_a_stale_pin_names_both_files(self):
        errors = cr.mismatches({"A/Package.resolved": resolved(("grdb.swift", "7.12.0", "new")),
                                "B/Package.resolved": resolved(("grdb.swift", "7.11.1", "old"))})
        self.assertEqual(len(errors), 1)
        self.assertIn("grdb.swift", errors[0])
        self.assertIn("A/Package.resolved", errors[0])
        self.assertIn("B/Package.resolved", errors[0])

    def test_same_version_different_revision_fails(self):
        self.assertTrue(cr.mismatches({"A/Package.resolved": resolved(("x", "1.0.0", "aaa")),
                                       "B/Package.resolved": resolved(("x", "1.0.0", "bbb"))}))

    def test_the_repo_agrees(self):
        root = os.path.join(HERE, "..", "..", "..")
        result = subprocess.run(["python3", "-B", os.path.join(HERE, "..", "check-resolved.py"), "--root", root],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
