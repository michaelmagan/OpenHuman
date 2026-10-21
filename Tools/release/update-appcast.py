#!/usr/bin/env python3
"""Add a release to the Sparkle appcast (appcast.xml at the repository root).

The release workflow runs this after it signed the disk image with Sparkle's sign_update, and opens a pull request with
the result. Each release is one <item> at the top of <channel>; older items stay, so an old copy of the app still
finds a valid feed. Sparkle compares <sparkle:version> with the running app's CFBundleVersion (the build number), so
a new item must carry a higher build number than every item already in the feed.

sign_update prints the enclosure attributes, for example:
    sparkle:edSignature="abc...==" length="12345678"
They are checked and copied into <enclosure> unchanged.

Sparkle shows <description> in a web view, so --notes-file holds HTML: the workflow renders it with git-cliff and
Tools/release/appcast-body.tera.

Usage: Tools/release/update-appcast.py --appcast appcast.xml --version 0.2.0 --build 140 \\
           --download-url https://github.com/<owner>/<repo>/releases/download/v0.2.0/OpenHuman-Mail-0.2.0.dmg \\
           --signature-fragment 'sparkle:edSignature="..." length="..."' --notes-file notes.html
"""

from __future__ import annotations

import argparse
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlparse
from xml.etree import ElementTree
from xml.sax.saxutils import escape

FEED_URL = "https://raw.githubusercontent.com/michaelmagan/OpenHuman/main/appcast.xml"
TITLE = "OpenHuman Mail"

APPCAST_TEMPLATE = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>{title}</title>
    <link>{link}</link>
    <description>Most recent updates to {title}</description>
    <language>en</language>
{items}  </channel>
</rss>
"""

# The notes pane is small: headings at body size, tighter spacing. No colors, so the web view follows dark mode.
RELEASE_NOTES_STYLE = """<style>
        h2, h3, h4, h5, h6 { font-size: 1em; margin: 1em 0 0.3em; }
        p { margin: 0.4em 0; }
        ul { margin: 0.2em 0; padding-left: 1.4em; }
        li { margin: 0.15em 0; }
        style + * { margin-top: 0; }
      </style>"""

VERSION_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
BUILD_RE = re.compile(r"^[0-9]+$")
MACOS_RE = re.compile(r"^[0-9]+\.[0-9]+(\.[0-9]+)?$")
FRAGMENT_RE = re.compile(r'^sparkle:edSignature="[A-Za-z0-9+/]+={0,2}" length="[0-9]+"$')
ITEM_RE = re.compile(r"    <item>.*?</item>\n", re.DOTALL)
ITEM_BUILD_RE = re.compile(r"<sparkle:version>([0-9]+)</sparkle:version>")
ITEM_VERSION_RE = re.compile(r"<sparkle:shortVersionString>([^<]*)</sparkle:shortVersionString>")


class AppcastError(Exception):
    pass


def attribute(text: str) -> str:
    return escape(text, {'"': "&quot;"})


def build_item(version: str, build: str, download_url: str, signature_fragment: str, notes_html: str,
               minimum_system_version: str, early_development_note: str, pub_date: str) -> str:
    notes = notes_html.strip() or f"<p>{escape(TITLE)} {escape(version)}</p>"
    if early_development_note:
        notes = f"<p><em>{escape(early_development_note)}</em></p>\n{notes}"
    # A stray "]]>" would end the CDATA section early, so it is split across two sections.
    notes = notes.replace("]]>", "]]]]><![CDATA[>")
    notes = "\n".join(f"      {line}" if line else "" for line in notes.splitlines())
    return f"""    <item>
      <title>Version {escape(version)}</title>
      <pubDate>{pub_date}</pubDate>
      <sparkle:version>{escape(build)}</sparkle:version>
      <sparkle:shortVersionString>{escape(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{escape(minimum_system_version)}</sparkle:minimumSystemVersion>
      <description><![CDATA[
      {RELEASE_NOTES_STYLE}
{notes}
      ]]></description>
      <enclosure url="{attribute(download_url)}" type="application/octet-stream" {signature_fragment} />
    </item>
"""


def existing_items(text: str) -> list[str]:
    return ITEM_RE.findall(text)


def update(appcast_text: str, *, version: str, build: str, download_url: str, signature_fragment: str,
           notes_html: str, minimum_system_version: str = "26.0", early_development_note: str = "",
           now: datetime | None = None) -> str:
    if not VERSION_RE.match(version):
        raise AppcastError(f"the version must be three numbers such as 0.2.0 (got {version!r})")
    if not BUILD_RE.match(build):
        raise AppcastError(f"the build number must be a whole number (got {build!r})")
    signature_fragment = signature_fragment.strip()
    if not FRAGMENT_RE.match(signature_fragment):
        raise AppcastError("the signature must be what sign_update prints: "
                           'sparkle:edSignature="<base64>" length="<bytes>"')
    url = urlparse(download_url)
    if url.scheme != "https" or url.hostname != "github.com" or not url.path.endswith(f"/OpenHuman-Mail-{version}.dmg"):
        raise AppcastError(f"the download must be this version's DMG on a GitHub release (got {download_url!r})")
    if not MACOS_RE.match(minimum_system_version):
        raise AppcastError(f"the minimum macOS version must look like 26.0 (got {minimum_system_version!r})")

    found = existing_items(appcast_text)
    if appcast_text.count("<item>") != len(found):
        raise AppcastError("the appcast has <item> entries this tool cannot read (it expects the layout it writes); "
                           "fix appcast.xml by hand so no release is dropped")
    kept = []
    for item in found:
        old_build = ITEM_BUILD_RE.search(item)
        old_version = ITEM_VERSION_RE.search(item)
        if old_version and old_version.group(1) == version:
            continue  # the same version again (a repeated release run) replaces its entry
        if old_build and int(old_build.group(1)) >= int(build):
            raise AppcastError(f"build {build} is not above build {old_build.group(1)} already in the appcast "
                               f"({old_version.group(1) if old_version else 'unknown version'}); Sparkle would not "
                               "offer it. Release with a higher build number")
        kept.append(item)

    pub_date = (now or datetime.now(tz=timezone.utc)).strftime("%a, %d %b %Y %H:%M:%S +0000")
    item = build_item(version, build, download_url, signature_fragment, notes_html, minimum_system_version,
                      early_development_note, pub_date)
    result = APPCAST_TEMPLATE.format(title=escape(TITLE), link=escape(FEED_URL), items=item + "".join(kept))
    ElementTree.fromstring(result.encode("utf-8"))  # never write a feed Sparkle cannot read
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Add a release to the Sparkle appcast.")
    parser.add_argument("--appcast", required=True, type=Path)
    parser.add_argument("--version", required=True, help="CFBundleShortVersionString, such as 0.2.0")
    parser.add_argument("--build", required=True, help="CFBundleVersion of the released app")
    parser.add_argument("--download-url", required=True)
    parser.add_argument("--signature-fragment", required=True, help="what sign_update printed for the DMG")
    parser.add_argument("--notes-file", type=Path, help="HTML release notes")
    parser.add_argument("--minimum-system-version", default="26.0")
    parser.add_argument("--early-development-note", default="",
                        help="a line shown above the notes, such as the early development notice")
    args = parser.parse_args(argv)

    current = args.appcast.read_text(encoding="utf-8") if args.appcast.exists() else ""
    try:
        text = update(current, version=args.version, build=args.build, download_url=args.download_url,
                      signature_fragment=args.signature_fragment,
                      notes_html=args.notes_file.read_text(encoding="utf-8") if args.notes_file else "",
                      minimum_system_version=args.minimum_system_version,
                      early_development_note=args.early_development_note)
    except (AppcastError, ElementTree.ParseError) as error:
        print(f"update-appcast: {error}", file=sys.stderr)
        return 1
    args.appcast.write_text(text, encoding="utf-8")
    print(f"update-appcast: wrote {args.appcast} with {text.count('<item>')} release(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
