import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, os.path.join(ROOT, path))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


comment = load("render_sweep_comment", "Tools/ci/render-sweep-comment.py")
listing = load("render_sweep_list", "Tools/render-sweep-list.py")
PNG = b"\x89PNG\r\n\x1a\n" + b"\0" * 16
SHA = "0123456789abcdef0123456789abcdef01234567"


class RenderSweepCommentTests(unittest.TestCase):
    def temporary(self):
        holder = tempfile.TemporaryDirectory()
        self.addCleanup(holder.cleanup)
        return holder.name

    def folder(self, entries, files):
        directory = self.temporary()
        for name, data in files.items():
            with open(os.path.join(directory, name), "wb") as handle:
                handle.write(data)
        with open(os.path.join(directory, "index.json"), "w", encoding="utf-8") as handle:
            json.dump(entries, handle)
        return directory

    def run_main(self, renders, *extra):
        staging = os.path.join(self.temporary(), "assets")
        result = subprocess.run([sys.executable, "-I", os.path.join(ROOT, "Tools/ci/render-sweep-comment.py"),
                                 "--renders", renders, "--staging", staging, "--pr", "12", "--sha", SHA,
                                 "--repo", "owner/name", "--run-id", "99", *extra],
                                capture_output=True, text=True, check=False)
        return result, staging

    def test_only_plain_png_files_from_the_index_are_kept(self):
        renders = self.folder([
            {"screen": "inbox", "theme": "Light", "file": "inbox--light.png"},
            {"screen": "inbox", "theme": "Dark", "file": "inbox--dark.png"},
            {"screen": "fake", "theme": "Light", "file": "not-a-png.png"},
            {"screen": "escape", "theme": "Light", "file": "../outside.png"},
            {"screen": "missing", "theme": "Light", "file": "missing.png"},
            {"screen": "inbox", "theme": "Light", "file": "inbox--light.png"},
        ], {"inbox--light.png": PNG, "inbox--dark.png": PNG, "not-a-png.png": b"GIF89a"})
        self.assertEqual([e["file"] for e in comment.entries(renders)], ["inbox--light.png", "inbox--dark.png"])

    def test_screen_and_theme_text_cannot_inject_markup(self):
        renders = self.folder([{"screen": "<img src=x onerror=1>\n`|x", "theme": "Light\"><script>", "file": "a.png"}],
                              {"a.png": PNG})
        entry = comment.entries(renders)[0]
        self.assertNotRegex(entry["screen"] + entry["theme"], r"[<>\"`|\n]")

    def test_stages_assets_and_prints_one_marked_comment(self):
        renders = self.folder([{"screen": "inbox", "theme": "Light", "file": "inbox--light.png"},
                               {"screen": "reader-cards", "theme": "Dark", "file": "reader-cards--dark.png"}],
                              {"inbox--light.png": PNG, "reader-cards--dark.png": PNG})
        result, staging = self.run_main(renders, "--limit", "1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sorted(os.listdir(staging)), ["pr-12-inbox--light.png"])
        self.assertTrue(result.stdout.startswith(comment.MARKER))
        self.assertIn("https://github.com/owner/name/releases/download/pr-screenshots/pr-12-inbox--light.png?v=0123456",
                      result.stdout)
        self.assertIn("1 more PNGs", result.stdout)
        self.assertIn("/actions/runs/99", result.stdout)

    def test_rejects_arguments_that_are_not_plain_values(self):
        renders = self.folder([], {})
        for flag, value in (("--pr", "12; rm"), ("--sha", "abc"), ("--repo", "a/b/c"), ("--run-id", "1 2")):
            with self.subTest(flag=flag):
                args = {"--pr": "12", "--sha": SHA, "--repo": "owner/name", "--run-id": "99", flag: value}
                result = subprocess.run([sys.executable, "-I", os.path.join(ROOT, "Tools/ci/render-sweep-comment.py"),
                                         "--renders", renders, "--staging", renders,
                                         *[x for pair in args.items() for x in pair]],
                                        capture_output=True, text=True, check=False)
                self.assertEqual(result.returncode, 2)

    def test_an_empty_or_missing_index_renders_a_note(self):
        result, _ = self.run_main(os.path.join(self.temporary(), "missing"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("rendered no screens", result.stdout)


class RenderSweepListTests(unittest.TestCase):
    def test_lists_the_package_tests_that_the_sweep_filter_accepts(self):
        halves = {half: listing.tests(folder) for half, folder in listing.HALVES}
        names = [entry["test"] for entry in halves["package"]]
        self.assertIn("inbox", names)
        self.assertIn("reader", names)
        self.assertEqual(len(names), len(set(names)), "test function names are unique, so --tests picks one each")
        for name in names:
            self.assertRegex(name, r"^[A-Za-z_][A-Za-z0-9_]*$")
        self.assertNotIn("refusesAnOutputFolderInsideAGitWorkTree", names)
        inbox = next(e for e in halves["package"] if e["test"] == "inbox")
        self.assertEqual(inbox["screens"], ["inbox"])
        self.assertTrue(halves["app"])

    def test_reads_view_screens_and_stops_at_the_next_member(self):
        holder = tempfile.TemporaryDirectory()
        self.addCleanup(holder.cleanup)
        with open(os.path.join(holder.name, "RenderSweepExampleTests.swift"), "w", encoding="utf-8") as handle:
            handle.write("""extension RenderSweepTests {
    @Test(arguments: SweepTheme.selected(SweepTheme.allBuiltIns, slugs: "light")) @available(macOS 26, *)
    func cards(_ theme: SweepTheme) async throws {
        try await sweepShootView("card-error", theme: theme, size: .zero) { _ in Text("x") }
        try await sweepShoot(window, screen: "card-\\(name)", theme: theme)
    }

    private func helper() async throws {
        try await sweepShoot(window, screen: "helper-only", theme: theme)
    }
}
""")
        [entry] = listing.tests(holder.name)
        self.assertEqual(entry["test"], "cards")
        self.assertEqual(entry["themes"], 'SweepTheme.selected(SweepTheme.allBuiltIns, slugs: "light")')
        self.assertEqual(entry["screens"], ["card-error", "card-…"])

    def test_interpolated_screens_are_shown_with_an_ellipsis(self):
        self.assertEqual(listing.literal(r"settings-\(page.slug)-full"), "settings-…-full")

    def test_render_sweep_list_flag_prints_the_listing(self):
        result = subprocess.run(["bash", os.path.join(ROOT, "Tools/render-sweep.sh"), "--list"],
                                capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(re.match(r"package half .*: \d+ tests", result.stdout), result.stdout[:200])


if __name__ == "__main__":
    unittest.main()
