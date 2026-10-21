#!/usr/bin/env python3
"""Lists the render-sweep tests and the screens each one renders, read from the test sources (no build needed).

Usage: Tools/render-sweep-list.py [--json]. The package-half names are what Tools/render-sweep.sh --tests takes.
A screen built at run time (string interpolation) is shown with … in place of the interpolated part, and a screen
passed through a variable is not shown.
Stdlib only."""
import glob, json, os, re, sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
HALVES = [
    ("package", "Packages/OpenHumanMailUI/Tests/MailUIMacTests/RenderSweep"),
    ("app", "Apps/Mail/Tests/MailAppTests/RenderSweep"),
]
TEST = re.compile(r"@Test\b(.*?)\bfunc\s+(\w+)\s*\(", re.DOTALL)
SCREEN = re.compile(r"""(?:\bscreen:\s*|\bsweepShootView\(\s*)"((?:[^"\\]|\\.)*)\"""")
# Where a test's body ends: the closing brace of its extension or type, or the next member function
BODY_END = re.compile(r"\n\}|\n    (?:@\w+(?:\([^)]*\))?\s+)*(?:(?:private|fileprivate|static|nonisolated|func)\b)")


def arguments(attributes):
    """The text of the @Test(arguments: ...) list, or None for a test without arguments."""
    start = attributes.find("arguments:")
    if start < 0:
        return None
    depth, text = 1, attributes[start + len("arguments:"):]
    for i, char in enumerate(text):
        depth += {"(": 1, ")": -1}.get(char, 0)
        if depth == 0:
            return " ".join(text[:i].split())
    return " ".join(text.split())


def literal(text):
    return re.sub(r"\\\((?:[^()]|\([^()]*\))*\)", "…", text)


def tests(folder):
    found = []
    for path in sorted(glob.glob(os.path.join(ROOT, folder, "*.swift"))):
        with open(path, encoding="utf-8") as handle:
            source = handle.read()
        matches = list(TEST.finditer(source))
        for i, match in enumerate(matches):
            end = matches[i + 1].start() if i + 1 < len(matches) else len(source)
            body = source[match.end():end]
            stop = BODY_END.search(body)
            body = body[:stop.start()] if stop else body
            themes = arguments(match.group(1))
            if themes is None:
                continue  # not parameterised by theme: a guard test, not a render
            screens = []
            for screen in SCREEN.findall(body):
                screen = literal(screen)
                if screen not in screens:
                    screens.append(screen)
            found.append({"test": match.group(2), "themes": themes,
                          "screens": screens, "file": os.path.relpath(path, ROOT)})
    return found


def main(argv):
    halves = {half: tests(folder) for half, folder in HALVES}
    if "--json" in argv:
        json.dump(halves, sys.stdout, indent=2)
        print()
        return 0
    for half, entries in halves.items():
        title = "package half (--tests <name>)" if half == "package" else "app half (--only app; always every test)"
        print(f"{title}: {len(entries)} tests")
        last = None
        for entry in entries:
            if entry["file"] != last:
                print(f"  {entry['file']}")
                last = entry["file"]
            print(f"    {entry['test']}  [{entry['themes']}]")
            if entry["screens"]:
                print(f"        {', '.join(entry['screens'])}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
