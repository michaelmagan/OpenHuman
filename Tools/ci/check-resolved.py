#!/usr/bin/env python3
"""Check that every committed Package.resolved pins each dependency to the same version and revision.

Packages pull each other in by local path, so one dependency is pinned in several Package.resolved files. A bump that
updates only the declaring package leaves the others stale; `swift build` re-resolves quietly, so nothing else fails.
Stdlib only. Usage: check-resolved.py [--root DIR]
"""
import argparse
import json
import subprocess
import sys
from collections import defaultdict

sys.dont_write_bytecode = True


def pin_state(pin):
    state = pin.get("state", {})
    return state.get("version") or state.get("branch") or "", state.get("revision", "")


def mismatches(resolved):
    """resolved: {path: parsed Package.resolved}. Returns one message per dependency pinned more than one way."""
    seen = defaultdict(lambda: defaultdict(list))
    for path, data in sorted(resolved.items()):
        for pin in data.get("pins", []):
            seen[pin["identity"]][pin_state(pin)].append(path)
    errors = []
    for identity, states in sorted(seen.items()):
        if len(states) > 1:
            where = "; ".join(f"{v or '?'} @ {r[:12] or '?'} in {', '.join(paths)}"
                              for (v, r), paths in sorted(states.items()))
            errors.append(f"{identity} is pinned differently: {where}")
    return errors


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--root", default=".")
    a = ap.parse_args()
    paths = subprocess.run(["git", "-C", a.root, "ls-files", "*Package.resolved"], capture_output=True, text=True,
                           check=True).stdout.splitlines()
    resolved = {}
    for path in paths:
        with open(f"{a.root}/{path}") as f:
            resolved[path] = json.load(f)
        if resolved[path].get("version", 1) < 2:
            print(f"check-resolved: {path}: Package.resolved version 1 is not supported; resolve it with Swift 5.6 or later")
            return 1
    errors = mismatches(resolved)
    for e in errors:
        print(f"check-resolved: {e}")
    if errors:
        print("check-resolved: run `swift package resolve` in each listed package so they agree")
        return 1
    print(f"check-resolved: OK ({len(paths)} file(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main())
