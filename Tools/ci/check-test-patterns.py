#!/usr/bin/env python3
"""Check added Swift test lines and cap legacy sleeps and shared globals across the test tree.

Usage: Tools/ci/check-test-patterns.py [--base origin/main] [--diff-file FILE] [--inventory]
Allow an intentional pattern with // flake-ok: <reason>, a temporary path with // temp-ok: <reason>, or a defaults
suite with // defaults-ok: <reason>. An annotation does not exempt a legacy inventory count. The per-file caps
in test-patterns-baseline.json apply to the whole tree, including untracked Swift tests. --inventory reports only
that inventory and its caps; --diff-file checks synthetic added lines without reading the repository inventory.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

BANNED = [
    (re.compile(r"\b(Task|Thread)\.sleep\b|\busleep\("), "fixed sleep: await the real signal or inject a test clock"),
    (re.compile(r"ContinuousClock\(\)\s*\.measure|\bclock\.measure\b|\.measure\s*\{"), "wall-clock measurement"),
    (re.compile(r"timeIntervalSince\([^)]*\)\s*(<|<=)"), "elapsed-time assertion"),
    (re.compile(r"\belapsed\s*(<|<=)"), "elapsed-time assertion"),
    (re.compile(r"\bWKWebView\("), "real WKWebView in a unit test: use a seam (or flake-ok for the one real-service test)"),
    (re.compile(r"QLPreviewPanel\.shared"), "real Quick Look panel: use a seam"),
    (re.compile(r"\bSecItem(Add|CopyMatching|Delete|Update)\b"), "real Keychain: use an in-memory fake"),
]
WARN = re.compile(r"(?<!func )\b(eventually|waitUntil|waitFor|eventuallyAsync)\s*[({]|\buntil\s*(\(|\{)")
OK = re.compile(r"//\s*flake-ok:\s*\S")
TEMP = re.compile(r"\.temporaryDirectory\b|\bNSTemporaryDirectory\s*\(|\bmk[ds]temp\s*\(|\.itemReplacementDirectory\b")
TEMP_OK = re.compile(r"//\s*temp-ok:\s*\S")
TEMP_HELPER = {"Packages/OpenHumanCore/Tests/OpenHumanCoreTests/TemporaryDirectoryTests.swift"}
DEFAULTS = re.compile(r"\bUserDefaults(\.init)?\s*\(\s*suiteName\s*:")
DEFAULTS_OK = re.compile(r"//\s*defaults-ok:\s*\S")
DEFAULTS_HELPER = {"Packages/OpenHumanCore/Tests/OpenHumanCoreTests/ScopedDefaultsTests.swift"}
SHARED = [
    ("reader_accessory", re.compile(r"\bReaderHeaderAccessorySlot\s*\.\s*(?:shared|current)\b"),
     "shared reader accessory: inject ReaderHeaderAccessoryStore"),
    ("reader_preferences", re.compile(r"\bReaderPreferences\s*\.\s*shared\b"),
     "shared reader preferences: inject ReaderPreferences(defaults: nil)"),
    ("notification_center", re.compile(r"\bNotificationCenter\s*\.\s*default\b"),
     "default notification center: inject a per-test center where supported"),
    ("compose_staging", re.compile(r"\bComposeManager\s*\.\s*defaultStagingDirectory\b"),
     "shared compose staging: inject per-test AttachmentStaging"),
]
# Preference persistence/implementation coverage owns this type. Other listed globals have no dedicated
# singleton-contract tests. Keep exemptions exact, never whole directories or generic support files.
SHARED_OWN_TESTS = {
    "reader_preferences": {"Packages/OpenHumanMailCore/Tests/MailFeaturesTests/Reader/ReaderPureTests.swift"},
}
INVENTORY = [("sleep", re.compile(r"\b(?:Task|Thread)\s*\.\s*sleep\b|\busleep\s*\("))] + [
    (name, rx) for name, rx, _ in SHARED
]
BASELINE = Path(__file__).with_name("test-patterns-baseline.json")


def is_test(path: str) -> bool:
    p = Path(path)
    return p.suffix == ".swift" and "Tests" in p.parts


def run(args: list[str]) -> str:
    return subprocess.run(args, capture_output=True, text=True).stdout


def repository_lines(root: Path) -> list[tuple[str, int, str]]:
    paths = subprocess.run(["git", "-C", str(root), "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
                           capture_output=True, text=True, check=True).stdout.split("\0")
    return [(path, n, text) for path in sorted(set(paths)) if is_test(path) and (root / path).is_file()
            for n, text in enumerate((root / path).read_text(errors="replace").splitlines(), 1)]


def inventory(lines: list[tuple[str, int, str]]) -> dict[str, dict[str, int]]:
    """Count lexical occurrences, including annotated sleeps, rather than grandfathering entire files."""
    counts: dict[str, dict[str, int]] = {name: {} for name, _ in INVENTORY}
    for path, _, text in lines:
        if not is_test(path) or text.lstrip().startswith("//"):
            continue
        code = text.split("//")[0]
        for name, rx in INVENTORY:
            if path in SHARED_OWN_TESTS.get(name, set()):
                continue
            count = len(rx.findall(code))
            if count:
                counts[name][path] = counts[name].get(path, 0) + count
    return counts


def read_baseline(path: Path) -> dict[str, dict[str, int]]:
    data = json.loads(path.read_text())
    names = {name for name, _ in INVENTORY}
    if not isinstance(data, dict) or data.get("version") != 1 or not isinstance(data.get("counts"), dict):
        raise ValueError("expected baseline version 1 and counts")
    counts = data["counts"]
    if set(counts) != names:
        raise ValueError("baseline must include every inventory rule")
    for by_path in counts.values():
        if not isinstance(by_path, dict) or any(not is_test(p) or type(n) is not int or n < 0
                                                for p, n in by_path.items()):
            raise ValueError("baseline counts must map Swift test paths to nonnegative integers")
    return counts


def check_inventory(counts: dict[str, dict[str, int]], baseline: dict[str, dict[str, int]]) -> tuple[list[str], list[str]]:
    bad, warn = [], []
    for name, _ in INVENTORY:
        current, allowed = counts.get(name, {}), baseline.get(name, {})
        total, cap = sum(current.values()), sum(allowed.values())
        if total:
            warn.append(f"legacy {name}: {total} occurrence(s) in {len(current)} file(s), recorded cap {cap}")
        for path, count in sorted(current.items()):
            limit = allowed.get(path, 0)
            if count > limit:
                bad.append(f"{path}: {name} inventory grew to {count} (recorded cap {limit}); "
                           "await the signal or isolate the fixture instead of increasing the baseline")
    return bad, warn


def added_lines(base: str) -> list[tuple[str, int, str]]:
    out: list[tuple[str, int, str]] = []
    diff = run(["git", "diff", "-U0", "--no-color", f"{base}...HEAD"]) + run(["git", "diff", "-U0", "--no-color", "HEAD"])
    path, line = "", 0
    for raw in diff.splitlines():
        if raw.startswith("+++ "):
            path = raw[6:] if raw.startswith("+++ b/") else ""
        elif raw.startswith("@@"):
            m = re.search(r"\+(\d+)", raw)
            line = int(m.group(1)) if m else 0
        elif raw.startswith("+") and not raw.startswith("+++"):
            if path and is_test(path):
                out.append((path, line, raw[1:]))
            line += 1
    for f in run(["git", "ls-files", "--others", "--exclude-standard"]).split("\n"):
        if f and is_test(f):
            for i, l in enumerate(Path(f).read_text(errors="replace").splitlines(), 1):
                out.append((f, i, l))
    return out


def check(lines: list[tuple[str, int, str]]) -> tuple[list[str], list[str]]:
    bad, warn = [], []
    for path, n, text in lines:
        code = text.split("//")[0] if "flake-ok" not in text else text
        if OK.search(text):
            continue
        stripped = text.lstrip()
        if stripped.startswith("//") or stripped.startswith("///"):
            continue
        for name, rx, why in SHARED:
            if path not in SHARED_OWN_TESTS.get(name, set()) and rx.search(text.split("//")[0]):
                warn.append(f"{path}:{n}: {why}: {text.strip()[:110]}")
        for rx, why in BANNED:
            if rx.search(text.split("//")[0]):
                bad.append(f"{path}:{n}: {why}: {text.strip()[:110]}")
                break
        else:
            if TEMP.search(text.split("//")[0]) and path not in TEMP_HELPER and not TEMP_OK.search(text):
                bad.append(f"{path}:{n}: raw temporary path: use TemporaryDirectory so the test removes it: "
                           f"{text.strip()[:110]}")
            elif DEFAULTS.search(text.split("//")[0]) and path not in DEFAULTS_HELPER and not DEFAULTS_OK.search(text):
                bad.append(f"{path}:{n}: raw defaults suite: use ScopedDefaults so the test removes it: "
                           f"{text.strip()[:110]}")
            elif WARN.search(text.split("//")[0]):
                warn.append(f"{path}:{n}: polling helper: {text.strip()[:110]}")
    return bad, warn


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="origin/main")
    ap.add_argument("--diff-file", help="test hook: lines as 'path:line:text'")
    ap.add_argument("--inventory", action="store_true", help="report whole-tree legacy counts and enforce their caps")
    ap.add_argument("--baseline", type=Path, default=BASELINE, help="whole-tree per-file count baseline")
    a = ap.parse_args()
    if a.inventory and a.diff_file:
        ap.error("--inventory and --diff-file cannot be combined")
    if a.diff_file:
        lines = []
        for l in Path(a.diff_file).read_text().splitlines():
            p, n, t = l.split(":", 2)
            if is_test(p):
                lines.append((p, int(n), t))
    else:
        lines = [] if a.inventory else added_lines(a.base)
    bad, warn = check(lines)
    if not a.diff_file:
        try:
            counts = inventory(repository_lines(Path(__file__).resolve().parents[2]))
            growth, legacy = check_inventory(counts, read_baseline(a.baseline))
        except (OSError, ValueError, subprocess.CalledProcessError) as error:
            print(f"FAIL  test pattern inventory: {error}")
            return 1
        bad.extend(growth)
        warn.extend(legacy)
    for w in warn:
        print("warn  " + w)
    for b in bad:
        print("FAIL  " + b)
    if bad:
        print(f"check-test-patterns: {len(bad)} violation(s) in added test code or the legacy inventory; "
              "(or add `// flake-ok: <reason>`, `// temp-ok: <reason>` for a temporary path, "
              "or `// defaults-ok: <reason>` for a defaults suite; annotations do not raise inventory caps)")
        return 1
    print(f"check-test-patterns: OK ({len(lines)} added test line(s), {len(warn)} warning(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main())
