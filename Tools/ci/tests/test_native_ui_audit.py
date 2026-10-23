import contextlib
import importlib.util
import io
import os
import pathlib
import tempfile
import unittest

TOOLS = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("native_ui_audit", TOOLS / "native-ui-audit.py")
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)

UI = "Packages/OpenHumanMailUI/Sources/MailUI"
MAC = "Packages/OpenHumanMailUI/Sources/MailUIMac"
APP = "Apps/Mail/Sources"

# Each file's hits are listed beside it; the totals below are their sums.
FIXTURE = {
    f"{UI}/Shell/Banner.swift": "\n".join([
        "Button(\"Close\") { close() }.buttonStyle(.plain)",       # P3
        "row.onTapGesture { open() }",                             # P5
        "// row.onTapGesture { ignored, a comment }",
        "    /// .buttonStyle(.plain) in a doc comment",
        "Text(title).onHover { hovering = $0 }.shadow(radius: 2)",  # P6 + P9
        "    .background(theme.bgSidebar.color)",                  # P14 (chrome folder)
        "    .background(RoundedRectangle(cornerRadius: 6).fill(tint))",  # P7
    ]),
    f"{UI}/Support/Plain.swift": "\n".join([
        "let fill = theme.bgSidebar",                               # not chrome: P14 does not apply
        "struct QuietButton: ButtonStyle {",                        # P4
        "let a = theme.component.toast.bg",                         # P10
        "KeycapView(text: \"esc\")",                               # P11
    ]),
    f"{UI}/Overlays/Field.swift": "\n".join([
        "TextField(\"\", text: $q).textFieldStyle(.plain)",       # P12
        ".overlayPreferenceValue(Anchors.self) { _ in }",          # P13
        "Capsule().strokeBorder(.tertiary)",                       # P7
    ]),
    f"{MAC}/Reader/Plate.swift": "\n".join([
        "override func draw(_ dirtyRect: NSRect) {",               # P1
        "    NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()",  # P2
        "    layer?.backgroundColor = NSColor.red.cgColor",          # P8
        "    addTrackingArea(NSTrackingArea(rect: .zero, options: [], owner: self))",  # P6
    ]),
    f"{MAC}/Composer/Toolbar.swift": "Button(\"B\") {}.buttonStyle(.plain)\n",  # skipped file
    f"{APP}/Panel.swift": "override func draw(_ r: NSRect) {}\nlet path = NSBezierPath(rect: r)\n",  # P1 + P2
    f"{APP}/Notes.txt": ".buttonStyle(.plain)\n",                  # not Swift
}
TOTAL = 18
BY_PATTERN = {"P1-draw": 2, "P2-bezier": 2, "P3-plain-btn": 1, "P4-own-style": 1, "P5-tap": 1, "P6-hover": 2,
              "P7-shape-fill": 2, "P8-layer-paint": 1, "P9-shadow": 1, "P10-chrome-tok": 1, "P11-own-ctl": 1,
              "P12-plain-field": 1, "P13-anchor-pop": 1, "P14-chrome-bg": 1}
ALLOW = "\n".join([
    "# fixture allowlist",
    "*/Composer/*\tskip\t# audited elsewhere",
    f"{APP}/Panel.swift\tP1-draw\t1\t# a drawn panel",
    "*/Reader/Plate.swift\t*\t3\t# a drawn plate",
    "*/Shell/Banner.swift\tP5-tap\t4\t# room left over",
]) + "\n"


class NativeUIAudit(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = self.temp.name
        for rel, text in FIXTURE.items():
            path = os.path.join(self.root, rel)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(text + "\n")
        self.allow = self.write("allow.tsv", ALLOW)

    def tearDown(self):
        self.temp.cleanup()

    def write(self, name, text):
        path = os.path.join(self.root, name)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(text)
        return path

    def run_main(self, *args):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = audit.main(list(args))
        return code, out.getvalue(), err.getvalue()

    def test_every_pattern_is_counted_once_per_line_and_comments_are_skipped(self):
        left, allowed, _ = audit.audit(self.root, [], [])
        counts = {pid: sum(1 for hit in left if hit.pid == pid) for pid in audit.PATTERNS}
        self.assertEqual(counts, {**BY_PATTERN, "P3-plain-btn": 2})
        self.assertEqual((len(left), allowed), (TOTAL + 1, 0), "the composer file counts without a skip line")
        self.assertFalse(any(hit.path.endswith(".txt") for hit in left))

    def test_skip_lines_leave_files_out(self):
        rules, skips = audit.load_allowlist(self.allow)
        left, _, _ = audit.audit(self.root, [], skips)
        self.assertEqual(len(left), TOTAL)
        self.assertFalse(any("/Composer/" in hit.path for hit in left))

    def test_the_chrome_background_pattern_applies_only_in_chrome_folders(self):
        left, _, _ = audit.audit(self.root, [], [])
        chrome = [hit.path for hit in left if hit.pid == "P14-chrome-bg"]
        self.assertEqual(chrome, [f"{UI}/Shell/Banner.swift"])

    def test_rules_allow_up_to_their_max_and_report_slack(self):
        rules, skips = audit.load_allowlist(self.allow)
        left, allowed, used = audit.audit(self.root, rules, skips)
        self.assertEqual(used, [1, 3, 1])
        self.assertEqual(allowed, 5)
        self.assertEqual(len(left), TOTAL - 5)
        plate = [hit for hit in left if hit.path.endswith("Plate.swift")]
        self.assertEqual([(hit.pid, hit.line) for hit in plate], [("P6-hover", 4)], "the fourth hit is over the max")
        lines = audit.report(left, allowed, rules, used, listing=False)
        self.assertIn(f"{TOTAL - 5:5d}  REMAINING in 5 files; 5 allowlisted", lines)
        self.assertIn("  allowlist slack: */Shell/Banner.swift P5-tap 1/4", lines)

    def test_the_report_orders_files_by_count_then_path(self):
        left, allowed, used = audit.audit(self.root, [], [])
        lines = audit.report(left, allowed, [], used, listing=True)
        files = [parts[1] for parts in map(str.split, lines) if parts[0].isdigit() and "/" in parts[1]]
        self.assertEqual(files, [f"{UI}/Shell/Banner.swift", f"{MAC}/Reader/Plate.swift", f"{UI}/Overlays/Field.swift",
                                 f"{UI}/Support/Plain.swift", f"{APP}/Panel.swift", f"{MAC}/Composer/Toolbar.swift"])
        self.assertIn(f"  {MAC}/Reader/Plate.swift:1  [P1-draw]  override func draw(_ dirtyRect: NSRect) {{", lines)
        self.assertEqual(lines, audit.report(*audit.audit(self.root, [], [])[:2], [], used, listing=True))

    def test_exit_codes(self):
        code, out, err = self.run_main(self.root, self.allow)
        self.assertEqual((code, err), (1, ""))
        self.assertIn("REMAINING", out)
        self.assertNotIn("[P6-hover]", out)
        self.assertIn(f"{MAC}/Reader/Plate.swift:4  [P6-hover]", self.run_main(self.root, self.allow, "--list")[1])

        clean = self.write("clean.tsv", "*\t*\t100\t# everything\n*/Composer/*\tskip\t# elsewhere\n")
        code, out, _ = self.run_main(self.root, clean)
        self.assertEqual(code, 0)
        self.assertIn("    0  REMAINING in 0 files", out)
        self.assertEqual(self.run_main(self.root, clean, "--strict")[0], 1, "unused room fails a strict run")
        exact = self.write("exact.tsv", f"*\t*\t{TOTAL}\t# everything\n*/Composer/*\tskip\t# elsewhere\n")
        self.assertEqual(self.run_main(self.root, exact, "--strict")[0], 0)

    def test_bad_input_exits_2(self):
        for text, message in [("*\tP99-nope\t1\t# reason\n", "unknown pattern id"),
                              ("*\t*\tmany\t# reason\n", "whole number"),
                              ("*\t*\t1\n", "reason"),
                              ("*\t1\t# reason\n", "separated by tabs")]:
            with self.subTest(text=text):
                code, _, err = self.run_main(self.root, self.write("bad.tsv", text))
                self.assertEqual(code, 2)
                self.assertIn(message, err)
        self.assertEqual(self.run_main(os.path.join(self.root, "missing"), self.allow)[0], 2)
        self.assertEqual(self.run_main(self.root, os.path.join(self.root, "missing.tsv"))[0], 2)

    def test_help_prints_usage(self):
        code, out, err = self.run_main("--help")
        self.assertEqual((code, err), (0, ""))
        self.assertTrue(out.startswith("Usage: Tools/native-ui-audit.py"))

    def test_the_shipped_allowlist_loads_and_every_entry_has_a_reason(self):
        rules, skips = audit.load_allowlist(audit.DEFAULT_ALLOWLIST)
        self.assertLessEqual(len(rules), 17)
        self.assertTrue(skips)
        self.assertTrue(all(rule.reason for rule in rules + skips))


if __name__ == "__main__":
    unittest.main()
