import contextlib
import importlib.util
import io
import json
import pathlib
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location("ctp", pathlib.Path(__file__).resolve().parents[1] / "check-test-patterns.py")
ctp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ctp)


def lines(*texts, path="Packages/P/Tests/PTests/ATests.swift"):
    return [(path, i + 1, t) for i, t in enumerate(texts)]


class CheckTestPatterns(unittest.TestCase):
    def test_banned(self):
        for t in ["try await Task.sleep(for: .seconds(1))", "let d = ContinuousClock().measure { x() }",
                  "#expect(Date().timeIntervalSince(start) < 1)", "let v = WKWebView(frame: .zero)",
                  "let s = QLPreviewPanel.shared()", "SecItemAdd(q, nil)"]:
            bad, _ = ctp.check(lines(t))
            self.assertEqual(len(bad), 1, t)

    def test_allowed_and_comments(self):
        bad, _ = ctp.check(lines("try await Task.sleep(for: .seconds(1)) // flake-ok: the sleep is the behaviour",
                                 "// Task.sleep is banned", "/// uses Task.sleep(for:)", "let x = 1"))
        self.assertEqual(bad, [])

    def test_polling_warns_only(self):
        bad, warn = ctp.check(lines("await eventually { model.ready }", "try await until { v.ok }"))
        self.assertEqual((len(bad), len(warn)), (0, 2))

    def test_raw_temporary_paths(self):
        for t in ['let d = FileManager.default.temporaryDirectory.appendingPathComponent("oh-x-\\(UUID().uuidString)")',
                  "let p = (NSTemporaryDirectory() as NSString).appendingPathComponent(name)",
                  "let u = URL.temporaryDirectory.appending(path: name)", "let f = fm.temporaryDirectory",
                  "guard mkdtemp(&template) != nil else { return }",
                  "let r = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: u, create: true)"]:
            bad, _ = ctp.check(lines(t))
            self.assertEqual(len(bad), 1, t)
            self.assertIn("TemporaryDirectory", bad[0])

    def test_temporary_helper_and_escapes_allowed(self):
        bad, _ = ctp.check(lines('let temp = TemporaryDirectory("oh-x")', "defer { temp.cleanup() }",
                                 "let w = Watcher(url: FileManager.default.temporaryDirectory) // temp-ok: watches only",
                                 "// FileManager.default.temporaryDirectory is banned",
                                 "let temporaryDirectory = temp.url"))
        self.assertEqual(bad, [])
        helper = "Packages/OpenHumanCore/Tests/OpenHumanCoreTests/TemporaryDirectoryTests.swift"
        bad, _ = ctp.check(lines("#expect(a.path == FileManager.default.temporaryDirectory.path)", path=helper))
        self.assertEqual(bad, [])

    def test_raw_defaults_suites(self):
        for t in ['let d = UserDefaults(suiteName: "openhuman.test.\\(UUID().uuidString)")!',
                  "let d = try #require(UserDefaults(suiteName: suite))",
                  "let d = name.flatMap(UserDefaults.init(suiteName:)) ?? .standard",
                  "SystemPreferences(defaults: UserDefaults( suiteName : name) ?? .standard)"]:
            bad, _ = ctp.check(lines(t))
            self.assertEqual(len(bad), 1, t)
            self.assertIn("ScopedDefaults", bad[0])

    def test_defaults_helper_and_escapes_allowed(self):
        bad, _ = ctp.check(lines('let defaults = ScopedDefaults("openhuman.test.x")', "defer { defaults.cleanup() }",
                                 "let store = AISettingsStore(suiteName: defaults.name)",
                                 'let nav = UserDefaultsNavigationStore(scope: "fake", suiteName: defaults.name)',
                                 "let keys = UserDefaultsKeymapStore(suiteName: defaults.name)",
                                 "let group = UserDefaults(suiteName: groupID) // defaults-ok: reads the shared group",
                                 "// UserDefaults(suiteName:) is banned", "let d = UserDefaults.standard"))
        self.assertEqual(bad, [])
        helper = "Packages/OpenHumanCore/Tests/OpenHumanCoreTests/ScopedDefaultsTests.swift"
        bad, _ = ctp.check(lines("let reopened = try #require(UserDefaults(suiteName: first.name))", path=helper))
        self.assertEqual(bad, [])

    def test_only_test_files(self):
        self.assertFalse(ctp.is_test("Packages/P/Sources/P/A.swift"))
        self.assertTrue(ctp.is_test("Apps/Mail/Tests/MailAppTests/A.swift"))

    def test_shared_globals_warn(self):
        for text in ["ReaderHeaderAccessorySlot.shared.current = accessory",
                     "ReaderHeaderAccessorySlot.current = accessory", "let prefs = ReaderPreferences.shared",
                     "NotificationCenter.default.post(name: name, object: nil)",
                     "let path = ComposeManager.defaultStagingDirectory",
                     "let center = NotificationCenter . default"]:
            bad, warn = ctp.check(lines(text))
            self.assertEqual(bad, [], text)
            self.assertEqual(len(warn), 1, text)

    def test_isolated_instances_and_similar_names_do_not_warn(self):
        bad, warn = ctp.check(lines("let slot = ReaderHeaderAccessoryStore()",
                                   "let prefs = ReaderPreferences(defaults: nil)",
                                   "let center = NotificationCenter()", "compose.staging = staging",
                                   "let value = MyReaderPreferences.shared", "let prefs = ReaderPreferences.sharedCache",
                                   "// NotificationCenter.default is intentional in an OS integration test"))
        self.assertEqual((bad, warn), ([], []))

    def test_singleton_own_tests_exempt_only_the_owned_type_and_exact_path(self):
        owner = "Packages/OpenHumanMailCore/Tests/MailFeaturesTests/Reader/ReaderPureTests.swift"
        bad, warn = ctp.check(lines("let prefs = ReaderPreferences.shared", path=owner))
        self.assertEqual((bad, warn), ([], []))
        _, warn = ctp.check(lines("let center = NotificationCenter.default", path=owner))
        self.assertEqual(len(warn), 1)
        _, warn = ctp.check(lines("let prefs = ReaderPreferences.shared", path="Packages/P/Tests/ReaderPureTests.swift"))
        self.assertEqual(len(warn), 1)


class LegacyTestInventory(unittest.TestCase):
    def empty(self):
        return {name: {} for name, _ in ctp.INVENTORY}

    def test_counts_sleep_occurrences_including_annotations(self):
        counts = ctp.inventory(lines("try await Task.sleep(for: delay) // flake-ok: a cancellation fixture",
                                     "Thread.sleep(forTimeInterval: 1); usleep(2)", "// Task.sleep(for: delay)"))
        self.assertEqual(sum(counts["sleep"].values()), 3)
        self.assertEqual(sum(counts["reader_accessory"].values()), 0)

    def test_counts_all_globals_and_accessory_alias(self):
        counts = ctp.inventory(lines("ReaderHeaderAccessorySlot.shared.current = accessory",
                                     "ReaderHeaderAccessorySlot.current = nil",
                                     "let prefs = ReaderPreferences.shared", "let center = NotificationCenter.default",
                                     "let path = ComposeManager.defaultStagingDirectory"))
        self.assertEqual([sum(counts[name].values()) for name, _ in ctp.INVENTORY], [0, 2, 1, 1, 1])

    def test_ignores_non_tests_comments_and_own_type_tests(self):
        self.assertEqual(ctp.inventory(lines("Task.sleep(for: delay)", path="Packages/P/Sources/P/A.swift")), self.empty())
        self.assertEqual(ctp.inventory(lines("// ReaderPreferences.shared", "// Task.sleep(for: delay)")), self.empty())
        owner = "Packages/OpenHumanMailCore/Tests/MailFeaturesTests/Reader/ReaderPureTests.swift"
        counts = ctp.inventory(lines("let prefs = ReaderPreferences.shared", "let center = NotificationCenter.default",
                                     path=owner))
        self.assertEqual(counts["reader_preferences"], {})
        self.assertEqual(counts["notification_center"], {owner: 1})

    def test_equal_and_reduced_counts_pass_but_growth_fails(self):
        current = ctp.inventory(lines("try await Task.sleep(for: delay)"))
        bad, warn = ctp.check_inventory(current, current)
        self.assertEqual(bad, [])
        self.assertEqual(len(warn), 1)
        self.assertEqual(ctp.check_inventory(self.empty(), current), ([], []))
        bad, _ = ctp.check_inventory(current, self.empty())
        self.assertEqual(len(bad), 1)
        self.assertIn("recorded cap 0", bad[0])

    def test_one_file_cannot_use_another_files_budget(self):
        baseline = ctp.inventory(lines("Task.sleep(for: delay)", "Task.sleep(for: delay)"))
        current = ctp.inventory(lines("Task.sleep(for: delay)", path="Packages/P/Tests/PTests/NewTests.swift"))
        bad, _ = ctp.check_inventory(current, baseline)
        self.assertEqual(len(bad), 1)
        self.assertIn("NewTests.swift", bad[0])

    def test_annotating_a_new_occurrence_does_not_bypass_the_cap(self):
        added = lines("Task.sleep(for: delay) // flake-ok: intentional cancellation")
        self.assertEqual(ctp.check(added), ([], []))
        bad, _ = ctp.check_inventory(ctp.inventory(added), self.empty())
        self.assertEqual(len(bad), 1)

    def test_repository_inventory_includes_untracked_tests_and_skips_deleted_tests(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            tracked, new, deleted = [f"Packages/P/Tests/PTests/{name}.swift" for name in ("Tracked", "New", "Deleted")]
            (root / tracked).parent.mkdir(parents=True)
            (root / tracked).write_text("let center = NotificationCenter.default\n")
            (root / new).write_text("Task.sleep(for: delay)\n")
            result = mock.Mock(stdout="\0".join([tracked, new, tracked, deleted, "Packages/P/Sources/P/A.swift", ""]))
            with mock.patch.object(ctp.subprocess, "run", return_value=result) as run:
                found = ctp.repository_lines(root)
            self.assertEqual({p for p, _, _ in found}, {tracked, new})
            self.assertEqual(len(found), 2)
            self.assertIn("--others", run.call_args.args[0])
            self.assertTrue(run.call_args.kwargs["check"])

    def test_baseline_schema_is_validated(self):
        data = {"version": 1, "counts": self.empty()}
        with mock.patch.object(pathlib.Path, "read_text", return_value=json.dumps(data)):
            self.assertEqual(ctp.read_baseline(pathlib.Path("baseline.json")), self.empty())
        invalid = [{"version": 2, "counts": self.empty()}, {"version": 1, "counts": {}},
                   {"version": 1, "counts": {**self.empty(), "sleep": {"Packages/P/Tests/A.swift": -1}}},
                   {"version": 1, "counts": {**self.empty(), "sleep": {"Packages/P/Tests/A.swift": True}}},
                   {"version": 1, "counts": {**self.empty(), "sleep": {"Sources/A.swift": 1}}}]
        for value in invalid:
            with self.subTest(value=value), mock.patch.object(pathlib.Path, "read_text", return_value=json.dumps(value)):
                with self.assertRaises(ValueError):
                    ctp.read_baseline(pathlib.Path("baseline.json"))

    def test_normal_command_enforces_inventory_even_with_no_added_lines(self):
        with mock.patch.object(ctp.sys, "argv", ["check-test-patterns.py"]), \
             mock.patch.object(ctp, "added_lines", return_value=[]), \
             mock.patch.object(ctp, "repository_lines", return_value=lines("let center = NotificationCenter.default")), \
             mock.patch.object(ctp, "read_baseline", return_value=self.empty()), \
             contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(ctp.main(), 1)
        self.assertIn("inventory grew", output.getvalue())

    def test_inventory_mode_reports_legacy_sleeps_without_treating_them_as_added(self):
        sample = lines("Task.sleep(for: delay)")
        with mock.patch.object(ctp.sys, "argv", ["check-test-patterns.py", "--inventory"]), \
             mock.patch.object(ctp, "added_lines") as added, \
             mock.patch.object(ctp, "repository_lines", return_value=sample), \
             mock.patch.object(ctp, "read_baseline", return_value=ctp.inventory(sample)), \
             contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(ctp.main(), 0)
        added.assert_not_called()
        self.assertIn("legacy sleep: 1 occurrence", output.getvalue())

    def test_diff_file_hook_does_not_read_real_inventory(self):
        with mock.patch.object(ctp.sys, "argv", ["check-test-patterns.py", "--diff-file", "diff.txt"]), \
             mock.patch.object(pathlib.Path, "read_text", return_value="Packages/P/Tests/A.swift:1:let value = 1\n"), \
             mock.patch.object(ctp, "repository_lines") as repository, \
             contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(ctp.main(), 0)
        repository.assert_not_called()

    def test_missing_baseline_fails_closed(self):
        with mock.patch.object(ctp.sys, "argv", ["check-test-patterns.py", "--inventory"]), \
             mock.patch.object(ctp, "repository_lines", return_value=[]), \
             mock.patch.object(ctp, "read_baseline", side_effect=FileNotFoundError("missing baseline")), \
             contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(ctp.main(), 1)
        self.assertIn("missing baseline", output.getvalue())


if __name__ == "__main__":
    unittest.main()
