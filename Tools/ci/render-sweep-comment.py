#!/usr/bin/env python3
"""Stage a render-sweep folder for a pull request comment and print the comment body.

Usage: render-sweep-comment.py --renders DIR --staging DIR --pr N --sha SHA --repo OWNER/NAME --run-id ID
                               [--tag pr-screenshots] [--limit 60]

Copies at most --limit PNGs listed in DIR/index.json into --staging as release assets named pr-<N>-<file>, and prints
Markdown that shows them from https://github.com/<repo>/releases/download/<tag>/. The folder may come from a run of
untrusted pull request code, so it is treated as data: only plain file names ending in .png that are regular files
holding PNG bytes are copied, and screen and theme names are reduced to plain text before they reach the Markdown.
Stdlib only.
"""
import argparse
import json
import os
import re
import shutil
import sys

sys.dont_write_bytecode = True

MARKER = "<!-- render-sweep -->"
SAFE_FILE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,150}\.png$")
PNG_MAGIC = b"\x89PNG\r\n\x1a\n"
MAX_BYTES = 20 * 1024 * 1024


def plain(text, limit=80):
    text = re.sub(r"[^A-Za-z0-9 ._,+()/-]", "", str(text))
    return text[:limit].strip() or "?"


def entries(folder):
    """The index.json entries whose PNG is safe to publish, in index order (screen, then theme)."""
    try:
        with open(os.path.join(folder, "index.json"), encoding="utf-8") as handle:
            index = json.load(handle)
    except (OSError, ValueError):
        return []
    if isinstance(index, dict):
        index = index.get("entries", index.get("renders", []))
    if not isinstance(index, list):
        return []
    found, seen = [], set()
    for entry in index:
        if not isinstance(entry, dict):
            continue
        name = entry.get("file")
        if not isinstance(name, str) or not SAFE_FILE.match(name) or name in seen:
            continue
        path = os.path.join(folder, name)
        if os.path.islink(path) or not os.path.isfile(path) or os.path.getsize(path) > MAX_BYTES:
            continue
        with open(path, "rb") as handle:
            if handle.read(8) != PNG_MAGIC:
                continue
        seen.add(name)
        found.append({"screen": plain(entry.get("screen", name)), "theme": plain(entry.get("theme", "")), "file": name})
    return found


def asset_name(pr, file):
    return f"pr-{pr}-{file}"


def body(shown, total, pr, sha, repo, run_id, tag):
    run = f"https://github.com/{repo}/actions/runs/{run_id}"
    lines = [MARKER, "### Render sweep", ""]
    if not shown:
        lines += ["The sweep rendered no screens.", ""]
    screens = []
    for entry in shown:
        if entry["screen"] not in screens:
            screens.append(entry["screen"])
    for screen in screens:
        lines += [f"<details open><summary><code>{screen}</code></summary>", ""]
        for entry in (e for e in shown if e["screen"] == screen):
            url = f"https://github.com/{repo}/releases/download/{tag}/{asset_name(pr, entry['file'])}?v={sha[:7]}"
            lines.append(f'<img src="{url}" width="420" alt="{screen}, {entry["theme"]}" title="{entry["theme"]}">')
        lines += ["", "</details>", ""]
    if total > len(shown):
        lines += [f"{total - len(shown)} more PNGs are in the `render-sweep` artifact of the run.", ""]
    lines.append(f"<sub>{total} PNGs rendered on sample data at `{sha[:7]}` (<a href=\"{run}\">workflow run</a>, "
                 "artifact <code>render-sweep</code>). Updated on every sweep of this pull request.</sub>")
    return "\n".join(lines) + "\n"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--renders", required=True)
    parser.add_argument("--staging", required=True)
    parser.add_argument("--pr", required=True)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--tag", default="pr-screenshots")
    parser.add_argument("--limit", type=int, default=60)
    args = parser.parse_args(argv)
    checks = [(args.pr, r"[0-9]+"), (args.sha, r"[0-9a-f]{40}"), (args.repo, r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+"),
              (args.run_id, r"[0-9]+"), (args.tag, r"[A-Za-z0-9_.-]+")]
    for value, pattern in checks:
        if not re.fullmatch(pattern, value):
            print(f"render-sweep-comment: invalid argument {value!r}", file=sys.stderr)
            return 2
    found = entries(args.renders)
    shown = found[:max(args.limit, 0)]
    os.makedirs(args.staging, exist_ok=True)
    for entry in shown:
        shutil.copyfile(os.path.join(args.renders, entry["file"]),
                        os.path.join(args.staging, asset_name(args.pr, entry["file"])))
    sys.stdout.write(body(shown, len(found), args.pr, args.sha, args.repo, args.run_id, args.tag))
    return 0


if __name__ == "__main__":
    sys.exit(main())
