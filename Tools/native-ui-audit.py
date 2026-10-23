#!/usr/bin/env python3
"""Count hand-drawn chrome left in Mail: custom drawing, plain-styled buttons, hover plates, own control types and
theme chrome tokens where a system control or colour exists.

Usage: Tools/native-ui-audit.py [ROOT] [ALLOWLIST] [--list] [--strict]

ROOT defaults to this checkout and ALLOWLIST to Tools/native-ui-allowlist.tsv. Each allowlist line is
`glob<TAB>pattern-id|*<TAB>max<TAB># reason`: up to `max` hits of that pattern in files matching the glob are
allowed. A line `glob<TAB>skip<TAB># reason` leaves matching files out of the count. Every line needs a reason.
--list prints every remaining hit. Exit 0 when nothing remains, 1 when hits remain (or, with --strict, when an
allowlist entry has unused room), 2 on a usage or allowlist error. Stdlib only.
"""
import argparse
import collections
import fnmatch
import os
import re
import sys

ROOTS = ["Packages/OpenHumanMailUI/Sources", "Apps/Mail/Sources"]
CHROME_DIRS = r"/(Onboarding|Updates|Feedback|DevFeedback|Settings|Review|Overlays|Shell|AI|Invites|Scheduling|Calendar|SignIn)/"
SHAPES = r"(RoundedRectangle|Capsule|Circle)"
PATTERNS = {  # id: (regex, optional path regex the pattern is limited to)
    "P1-draw": (r"override func draw\(", None),
    "P2-bezier": (r"NSBezierPath\(", None),
    "P3-plain-btn": (r"\.buttonStyle\(\.plain\)", None),
    "P4-own-style": (r"(struct|class)\s+\w+\s*:\s*(Primitive)?(ButtonStyle|ToggleStyle|MenuStyle|LabelStyle|TextFieldStyle)\b",
                     None),
    "P5-tap": (r"\.onTapGesture", None),
    "P6-hover": (r"\.onHover\b|NSTrackingArea\(", None),
    "P7-shape-fill": (rf"\.(background|fill|overlay|clipShape)\(\s*{SHAPES}\(|{SHAPES}\([^)]*\)\s*\.(fill|stroke|strokeBorder)"
                      rf"|in:\s*{SHAPES}\(", None),
    "P8-layer-paint": (r"layer\?\.(backgroundColor|cornerRadius|borderColor|borderWidth|shadow\w*)\s*=", None),
    "P9-shadow": (r"\.themeShadow\(|\.shadow\(", None),
    "P10-chrome-tok": (r"component\.(toast|popover|palette|picker|modal|banner|keycap|overlay|sidebar|labelSidebar|toolbar"
                       r"|footer|tab|window|focus)\b|\bbgToast\b|toastTokens", None),
    "P11-own-ctl": (r"\b(KeycapView|OverlayCard|CursorRowBackground|ReaderButton|RowActionButton|ShortcutTipView"
                    r"|KeycapTooltipView|ReaderPlateView|SelectCheckboxGlyph)\b", None),
    "P12-plain-field": (r"\.textFieldStyle\(\.plain\)", None),
    "P13-anchor-pop": (r"overlayPreferenceValue\(", None),
    "P14-chrome-bg": (r"theme\.(bgWindow|bgSunken|bgSidebar|bgElevated|bgRowSelected|bgRowHover)\b", CHROME_DIRS),
}
COMPILED = {pid: (re.compile(rx), re.compile(scope) if scope else None) for pid, (rx, scope) in PATTERNS.items()}
HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_ROOT = os.path.dirname(HERE)
DEFAULT_ALLOWLIST = os.path.join(HERE, "native-ui-allowlist.tsv")


class AllowlistError(Exception):
    pass


Rule = collections.namedtuple("Rule", "glob pid cap reason line")
Hit = collections.namedtuple("Hit", "path pid line text")


def load_allowlist(path):
    """Returns (rules, skips). Rules keep the file's order: a hit uses the first matching rule with room."""
    rules, skips = [], []
    with open(path, encoding="utf-8") as handle:
        for number, raw in enumerate(handle, 1):
            body, _, reason = raw.rstrip("\n").partition("#")
            if not body.strip():
                continue
            fields = [field.strip() for field in body.split("\t") if field.strip()]
            where = f"{path}:{number}"
            if not reason.strip():
                raise AllowlistError(f"{where}: give a reason after #")
            if len(fields) == 2 and fields[1] == "skip":
                skips.append(Rule(fields[0], "skip", 0, reason.strip(), number))
                continue
            if len(fields) != 3:
                raise AllowlistError(f"{where}: expected glob, pattern id and max separated by tabs")
            glob, pid, cap = fields
            if pid != "*" and pid not in PATTERNS:
                raise AllowlistError(f"{where}: unknown pattern id {pid}")
            if not cap.isdigit():
                raise AllowlistError(f"{where}: max must be a whole number, not {cap}")
            rules.append(Rule(glob, pid, int(cap), reason.strip(), number))
    return rules, skips


def swift_files(root):
    """Repository-relative paths of the Swift files under ROOTS, in a stable order."""
    for top in ROOTS:
        for directory, subdirectories, files in os.walk(os.path.join(root, top)):
            subdirectories.sort()
            for name in sorted(files):
                if name.endswith(".swift"):
                    yield os.path.relpath(os.path.join(directory, name), root).replace(os.sep, "/")


def hits_in(rel, lines):
    for number, line in enumerate(lines, 1):
        if line.lstrip().startswith("//"):
            continue
        for pid, (rx, scope) in COMPILED.items():
            if (scope is None or scope.search(rel)) and rx.search(line):
                yield Hit(rel, pid, number, line.strip())


def audit(root, rules, skips):
    """Returns (remaining hits, allowed count, used count per rule index)."""
    used = [0] * len(rules)
    left, allowed = [], 0
    for rel in swift_files(root):
        if any(fnmatch.fnmatch(rel, skip.glob) for skip in skips):
            continue
        with open(os.path.join(root, rel), encoding="utf-8", errors="replace") as handle:
            lines = handle.read().splitlines()
        for hit in hits_in(rel, lines):
            index = next((i for i, rule in enumerate(rules) if fnmatch.fnmatch(rel, rule.glob)
                          and rule.pid in (hit.pid, "*") and used[i] < rule.cap), None)
            if index is None:
                left.append(hit)
            else:
                used[index] += 1
                allowed += 1
    return left, allowed, used


def report(left, allowed, rules, used, listing):
    out = []
    by_pid = collections.Counter(hit.pid for hit in left)
    by_file = collections.Counter(hit.path for hit in left)
    for pid in PATTERNS:
        out.append(f"{by_pid[pid]:5d}  {pid}")
    out.append(f"{len(left):5d}  REMAINING in {len(by_file)} files; {allowed} allowlisted")
    for path, count in sorted(by_file.items(), key=lambda item: (-item[1], item[0])):
        out.append(f"  {count:4d}  {path}")
    if listing:
        for hit in left:
            out.append(f"  {hit.path}:{hit.line}  [{hit.pid}]  {hit.text[:110]}")
    for rule, count in zip(rules, used):
        if count < rule.cap:
            out.append(f"  allowlist slack: {rule.glob} {rule.pid} {count}/{rule.cap}")
    return out


def main(argv=None):
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("root", nargs="?", default=DEFAULT_ROOT)
    parser.add_argument("allowlist", nargs="?", default=DEFAULT_ALLOWLIST)
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--strict", action="store_true")
    parser.add_argument("-h", "--help", action="store_true")
    args = parser.parse_args(argv)
    if args.help:
        print(__doc__.strip().split("\n\n", 1)[1])
        return 0
    if not all(os.path.isdir(os.path.join(args.root, top)) for top in ROOTS):
        print(f"native-ui-audit: {args.root} is not a checkout with {' and '.join(ROOTS)}", file=sys.stderr)
        return 2
    try:
        rules, skips = load_allowlist(args.allowlist)
    except (OSError, AllowlistError) as error:
        print(f"native-ui-audit: {error}", file=sys.stderr)
        return 2
    left, allowed, used = audit(args.root, rules, skips)
    print("\n".join(report(left, allowed, rules, used, args.list)))
    slack = any(count < rule.cap for rule, count in zip(rules, used))
    return 1 if left or (args.strict and slack) else 0


if __name__ == "__main__":
    sys.exit(main())
