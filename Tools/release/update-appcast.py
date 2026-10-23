#!/usr/bin/env python3
"""Sign an updating build's disk image and add it to the Sparkle update feed (appcast.xml).

The disk image comes from Tools/release/make-dmg.sh --enable-updates. This tool checks that the app inside it carries
the version, build number, feed and public key it is offered under, signs the disk image with Sparkle's sign_update
(the private key stays in your keychain, or comes from a file or standard input with --ed-key-file), checks the
signature against the public key with Tools/release/verify-update-signature.swift, and writes the feed with this
release at the top. Older releases stay below it. Sparkle compares <sparkle:version> with the running app's build
number, so each new item must carry a higher build number than every item already in the feed. The private key is
never printed.

Usage:
  Tools/release/update-appcast.py --dmg build/release/OpenHuman-Mail-0.2.0-1208/OpenHuman-Mail-0.2.0.dmg \\
      --version 0.2.0 --build 1208 --notes-file build/release/OpenHuman-Mail-0.2.0-1208/release-notes.md \\
      --download-url-prefix https://downloads.example.test/mail/ --appcast build/updates/appcast.xml

  --staged http://127.0.0.1:8000/ writes a test feed whose feed and downloads are served from this Mac, for the
  staged update test in docs/release/SPARKLE.md. Nothing is published either way: copying the files to the feed's
  host is a separate step.

Settings: OH_UPDATE_FEED_URL (the feed address, --feed-url), OH_SPARKLE_PUBLIC_KEY (--public-key) and
OH_SPARKLE_ACCOUNT (the keychain account of generate_keys, default openhuman-mail), from the environment, then
~/.config/openhuman/release.env (or OH_RELEASE_ENV), then Tools/release/release.env.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import html
import os
import plistlib
import re
import shlex
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable
from urllib.parse import quote, urlsplit
from xml.etree import ElementTree
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parents[2]
TITLE = "OpenHuman Mail"
DEFAULT_ACCOUNT = "openhuman-mail"
MINIMUM_SYSTEM_VERSION = "26.0"
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"

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
        h2, h3, h4 { font-size: 1em; margin: 1em 0 0.3em; }
        p { margin: 0.4em 0; }
        ul { margin: 0.2em 0; padding-left: 1.4em; }
        li { margin: 0.15em 0; }
      </style>"""

VERSION_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
BUILD_RE = re.compile(r"^[0-9]+$")
MACOS_RE = re.compile(r"^[0-9]+\.[0-9]+(\.[0-9]+)?$")
ITEM_RE = re.compile(r"    <item>.*?</item>\n", re.DOTALL)
ITEM_BUILD_RE = re.compile(r"<sparkle:version>([0-9]+)</sparkle:version>")
ITEM_VERSION_RE = re.compile(r"<sparkle:shortVersionString>([^<]*)</sparkle:shortVersionString>")
CHANNEL_LINK_RE = re.compile(r"^    <link>([^<]*)</link>$", re.MULTILINE)
LOOPBACK_HOSTS = ("127.0.0.1", "localhost")


class AppcastError(Exception):
    pass


@dataclass(frozen=True)
class Enclosure:
    url: str
    length: int
    signature: str


@dataclass(frozen=True)
class Measure:
    length: int
    sha256: str


def attribute(text: str) -> str:
    return escape(text, {'"': "&quot;"})


def is_public_key(text: str) -> bool:
    try:
        return len(base64.b64decode(text, validate=True)) == 32
    except (binascii.Error, ValueError):
        return False


def is_signature(text: str) -> bool:
    try:
        return len(base64.b64decode(text, validate=True)) == 64
    except (binascii.Error, ValueError):
        return False


def check_address(url: str, what: str, staged: bool) -> None:
    """https:// for anything published; a staged test uses this Mac's loopback over http instead. Sparkle downloads
    only over http or https, so a file:// address never works."""
    if any(c.isspace() or c in "\"'<>\\" for c in url):
        raise AppcastError(f"the {what} {url!r} is not a usable address")
    parts = urlsplit(url)
    if parts.username or parts.password:
        raise AppcastError(f"the {what} {url!r} carries a user name or password")
    if parts.scheme == "https" and parts.hostname:
        if staged:
            raise AppcastError(f"a staged feed stays on this Mac, but the {what} is {url!r}")
        return
    if staged and parts.scheme == "http" and parts.hostname in LOOPBACK_HOSTS:
        return
    if staged:
        raise AppcastError(f"the {what} of a staged feed must be on http://127.0.0.1 or http://localhost "
                           f"(Sparkle downloads only over http or https), got {url!r}")
    raise AppcastError(f"the {what} must start with https:// (got {url!r}); use --staged for a test on this Mac")


def notes_to_html(text: str) -> str:
    """Release notes as written for GitHub (headings, "- " lists, paragraphs) as HTML for Sparkle's notes pane.

    Every character of the notes is escaped, so a "<" in a note never becomes markup in the update window."""
    out: list[str] = []
    paragraph: list[str] = []
    in_list = False

    def close_paragraph() -> None:
        if paragraph:
            out.append("<p>" + " ".join(paragraph) + "</p>")
            paragraph.clear()

    def close_list() -> None:
        nonlocal in_list
        if in_list:
            out.append("</ul>")
            in_list = False

    for raw in text.splitlines():
        line = raw.strip()
        heading = re.match(r"^#{1,6}\s+(.*)$", line)
        bullet = re.match(r"^[-*]\s+(.*)$", line)
        if not line:
            close_paragraph()
            close_list()
        elif heading:
            close_paragraph()
            close_list()
            out.append("<h3>" + html.escape(heading.group(1), quote=False) + "</h3>")
        elif bullet:
            close_paragraph()
            if not in_list:
                out.append("<ul>")
                in_list = True
            out.append("  <li>" + html.escape(bullet.group(1), quote=False) + "</li>")
        else:
            close_list()
            paragraph.append(html.escape(line, quote=False))
    close_paragraph()
    close_list()
    return "\n".join(out)


def build_item(version: str, build: str, enclosure: Enclosure, notes_html: str, minimum_system_version: str,
               pub_date: str) -> str:
    notes = notes_html.strip() or f"<p>{escape(TITLE)} {escape(version)}</p>"
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
      <enclosure url="{attribute(enclosure.url)}" length="{enclosure.length}" type="application/octet-stream" sparkle:edSignature="{attribute(enclosure.signature)}" />
    </item>
"""


def update(appcast_text: str, *, feed_url: str, version: str, build: str, enclosure: Enclosure, notes_html: str,
           minimum_system_version: str = MINIMUM_SYSTEM_VERSION, staged: bool = False,
           now: datetime | None = None) -> str:
    """The feed with this release at the top. Raises AppcastError, and changes nothing, on any doubt."""
    if not VERSION_RE.match(version):
        raise AppcastError(f"the version must be three numbers such as 0.2.0 (got {version!r})")
    if not BUILD_RE.match(build):
        raise AppcastError(f"the build number must be a whole number (got {build!r})")
    if not MACOS_RE.match(minimum_system_version):
        raise AppcastError(f"the minimum macOS version must look like 26.0 (got {minimum_system_version!r})")
    if not is_signature(enclosure.signature):
        raise AppcastError("the signature must be the base64 EdDSA signature (64 bytes) that sign_update prints")
    if enclosure.length <= 0:
        raise AppcastError("the disk image is empty")
    check_address(feed_url, "feed address", staged)
    check_address(enclosure.url, "download", staged)

    found = ITEM_RE.findall(appcast_text)
    if appcast_text.count("<item>") != len(found):
        raise AppcastError("the appcast has <item> entries this tool cannot read (it expects the layout it writes); "
                           "fix it by hand so no release is dropped")
    if appcast_text.strip():
        links = CHANNEL_LINK_RE.findall(appcast_text)
        if links != [escape(feed_url)]:
            raise AppcastError(f"this appcast belongs to the feed {links[0] if links else 'nowhere'!r}, not "
                               f"{feed_url!r}. A staged feed and a published one are never mixed")
    kept = []
    for item in found:
        old_build = ITEM_BUILD_RE.search(item)
        old_version = ITEM_VERSION_RE.search(item)
        if old_version and old_version.group(1) == version:
            continue  # the same version again (a rebuilt release) replaces its entry
        if old_build and int(old_build.group(1)) >= int(build):
            raise AppcastError(f"build {build} is not above build {old_build.group(1)} already in the appcast "
                               f"({old_version.group(1) if old_version else 'unknown version'}); Sparkle would not "
                               "offer it. Build again with a higher --build-number")
        kept.append(item)

    pub_date = (now or datetime.now(tz=timezone.utc)).strftime("%a, %d %b %Y %H:%M:%S +0000")
    item = build_item(version, build, enclosure, notes_html, minimum_system_version, pub_date)
    title = f"{TITLE} (staged update test)" if staged else TITLE
    result = APPCAST_TEMPLATE.format(title=escape(title), link=escape(feed_url), items=item + "".join(kept))
    ElementTree.fromstring(result.encode("utf-8"))  # never write a feed Sparkle cannot read
    return result


def measure(path: Path) -> Measure:
    digest = hashlib.sha256()
    length = 0
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
            length += len(chunk)
    return Measure(length, digest.hexdigest())


def download_url(prefix: str, dmg: Path) -> str:
    return prefix.rstrip("/") + "/" + quote(dmg.name)


def read_app_info(dmg: Path) -> dict:
    """The Info.plist of the one app at the top of the disk image, attached read-only and hidden from Finder."""
    with tempfile.TemporaryDirectory() as mount:
        attached = subprocess.run(["hdiutil", "attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount,
                                   str(dmg)], capture_output=True, text=True)
        if attached.returncode != 0:
            raise AppcastError(f"could not attach {dmg} read-only: {attached.stderr.strip()}")
        try:
            apps = sorted(Path(mount).glob("*.app"))
            if len(apps) != 1:
                raise AppcastError(f"expected one app at the top of {dmg}, found {len(apps)}")
            with open(apps[0] / "Contents" / "Info.plist", "rb") as handle:
                return plistlib.load(handle)
        finally:
            subprocess.run(["hdiutil", "detach", mount, "-quiet"], capture_output=True)


def check_app_info(info: dict, *, version: str, build: str, feed_url: str, public_key: str) -> None:
    expected = {"CFBundleShortVersionString": version, "CFBundleVersion": build, "SUFeedURL": feed_url,
                "SUPublicEDKey": public_key}
    for key, want in expected.items():
        have = info.get(key, "")
        if have != want:
            hint = " (build it with make-dmg.sh --enable-updates and the same settings)" if key.startswith("SU") else ""
            raise AppcastError(f"the app in the disk image has {key} {have!r}, expected {want!r}{hint}")


def sign_with_sparkle(sign_update: Path, dmg: Path, *, account: str, key_file: str | None,
                      key_input: bytes | None) -> str:
    """The EdDSA signature sign_update prints with -p. Its output is never echoed: only the signature is kept."""
    args = [str(sign_update), "-p"]
    if key_file is not None:
        args += ["--ed-key-file", key_file]
    else:
        args += ["--account", account]
    args.append(str(dmg))
    if key_input is None:
        signed = subprocess.run(args, stdin=subprocess.DEVNULL, capture_output=True)
    else:
        signed = subprocess.run(args, input=key_input, capture_output=True)
    if signed.returncode != 0:
        raise AppcastError(f"sign_update failed (exit {signed.returncode}). Run it by hand to see why: "
                           f"{shlex.join(args[:-1])} <dmg>")
    return signed.stdout.decode("utf-8", "replace").strip()


def verify_with_public_key(public_key: str, signature: str, dmg: Path) -> bool:
    script = ROOT / "Tools" / "release" / "verify-update-signature.swift"
    checked = subprocess.run(["xcrun", "swift", str(script), public_key, signature, str(dmg)],
                             capture_output=True, text=True)
    if checked.returncode not in (0, 1):
        raise AppcastError(f"could not check the signature: {checked.stderr.strip()}")
    return checked.returncode == 0


def sign_and_check(dmg: Path, *, public_key: str, sign: Callable[[Path], str],
                   verify: Callable[[str, str, Path], bool]) -> Enclosure:
    """Signs the disk image and proves the signature covers exactly the bytes that will be offered."""
    before = measure(dmg)
    signature = sign(dmg)
    if not is_signature(signature):
        raise AppcastError("sign_update did not print a base64 EdDSA signature")
    after = measure(dmg)
    if after != before:
        raise AppcastError(f"{dmg} changed while it was signed ({before.length} bytes, sha256 {before.sha256}, now "
                           f"{after.length} bytes, sha256 {after.sha256}); nothing was written")
    if not verify(public_key, signature, dmg):
        raise AppcastError("the signature does not match OH_SPARKLE_PUBLIC_KEY: installed copies would refuse this "
                           "update. Sign with the private key that belongs to the public key in the app")
    return Enclosure(url="", length=before.length, signature=signature)


def sparkle_tools() -> Path:
    versions = (ROOT / "Tools" / "versions.env").read_text(encoding="utf-8")
    version = re.search(r"^SPARKLE_VERSION=(\S+)$", versions, re.MULTILINE)
    return ROOT / "Tools" / ".bin" / f"sparkle-{version.group(1) if version else 'unknown'}" / "bin" / "sign_update"


SETTING_RES = (re.compile(r'^\s*:\s*"\$\{(OH_[A-Z_]+):?=([^"$`]*)\}"\s*$'),
               re.compile(r'^\s*(?:export\s+)?(OH_[A-Z_]+)=(["\']?)([^"\'$`]*)\2\s*$'))


def settings(environ: dict[str, str]) -> dict[str, str]:
    """OH_* names from the environment, then from the settings files make-dmg.sh reads; the first one to set a name
    wins. Lines are read, never run: ': "${OH_NAME:=value}"' and 'OH_NAME=value' with a plain value."""
    found: dict[str, str] = {}
    files = [Path(environ.get("OH_RELEASE_ENV", str(Path.home() / ".config" / "openhuman" / "release.env"))),
             ROOT / "Tools" / "release" / "release.env"]
    for path in reversed(files):
        if not path.is_file():
            continue
        for line in path.read_text(encoding="utf-8").splitlines():
            for pattern in SETTING_RES:
                match = pattern.match(line)
                if match:
                    found[match.group(1)] = match.group(match.lastindex)
                    break
    found.update({key: value for key, value in environ.items() if key.startswith("OH_")})
    return found


def main(argv: list[str] | None = None, *, environ: dict[str, str] | None = None,
         stdin: Callable[[], bytes] | None = None, inspect: Callable[[Path], dict] = read_app_info,
         verify: Callable[[str, str, Path], bool] = verify_with_public_key, now: datetime | None = None) -> int:
    parser = argparse.ArgumentParser(description="Sign a disk image and add it to the Sparkle update feed.")
    parser.add_argument("--dmg", required=True, type=Path, help="the disk image make-dmg.sh --enable-updates wrote")
    parser.add_argument("--version", required=True, help="CFBundleShortVersionString, such as 0.2.0")
    parser.add_argument("--build", required=True, help="CFBundleVersion of the app in the disk image")
    parser.add_argument("--notes-file", type=Path, help="release notes as text or simple markdown")
    parser.add_argument("--appcast", required=True, type=Path, help="the feed to write; created if missing")
    parser.add_argument("--download-url-prefix", help="where the disk image will be published (https://)")
    parser.add_argument("--staged", metavar="URL", help="serve the feed and downloads from this Mac for a test")
    parser.add_argument("--feed-url", help="the feed address built into the app (default OH_UPDATE_FEED_URL)")
    parser.add_argument("--public-key", help="the public key built into the app (default OH_SPARKLE_PUBLIC_KEY)")
    parser.add_argument("--account", help="generate_keys keychain account (default OH_SPARKLE_ACCOUNT or "
                                          f"{DEFAULT_ACCOUNT})")
    parser.add_argument("--ed-key-file", help="read the private key from this file, or from standard input with -")
    parser.add_argument("--sign-update", type=Path, help="Sparkle's sign_update (default: the one "
                                                         "Tools/release/install-release-tools.sh installs)")
    parser.add_argument("--minimum-system-version", default=MINIMUM_SYSTEM_VERSION)
    args = parser.parse_args(argv)

    values = settings(dict(os.environ if environ is None else environ))
    staged = args.staged is not None
    try:
        if staged:
            if args.download_url_prefix:
                raise AppcastError("--staged sets the download address itself; leave out --download-url-prefix")
            prefix = args.staged
            # Why: OH_UPDATE_FEED_URL names the published feed, which a staged test never touches
            feed_url = args.feed_url or (args.staged.rstrip("/") + "/appcast.xml")
        else:
            if not args.download_url_prefix:
                raise AppcastError("give --download-url-prefix, the https:// address the disk image will be published at")
            prefix = args.download_url_prefix
            feed_url = args.feed_url or values.get("OH_UPDATE_FEED_URL", "")
            if not feed_url:
                raise AppcastError("set OH_UPDATE_FEED_URL (or --feed-url) to the feed address built into the app")
        public_key = args.public_key or values.get("OH_SPARKLE_PUBLIC_KEY", "")
        if not is_public_key(public_key):
            raise AppcastError("set OH_SPARKLE_PUBLIC_KEY (or --public-key) to the base64 public key built into the app")
        account = args.account or values.get("OH_SPARKLE_ACCOUNT") or DEFAULT_ACCOUNT
        if not args.dmg.is_file():
            raise AppcastError(f"no disk image at {args.dmg}")
        url = download_url(prefix, args.dmg)
        check_address(feed_url, "feed address", staged)
        check_address(url, "download", staged)
        current = args.appcast.read_text(encoding="utf-8") if args.appcast.exists() else ""
        notes = notes_to_html(args.notes_file.read_text(encoding="utf-8")) if args.notes_file else ""
        placeholder = Enclosure(url=url, length=1, signature=base64.b64encode(bytes(64)).decode())
        # Why: every input is checked before anything is signed, so a bad run never touches the key
        update(current, feed_url=feed_url, version=args.version, build=args.build, enclosure=placeholder,
               notes_html=notes, minimum_system_version=args.minimum_system_version, staged=staged, now=now)
        check_app_info(inspect(args.dmg), version=args.version, build=args.build, feed_url=feed_url,
                       public_key=public_key)

        sign_update = args.sign_update or sparkle_tools()
        if not os.access(sign_update, os.X_OK):
            raise AppcastError(f"no sign_update at {sign_update}; run Tools/release/install-release-tools.sh")
        key_input = None
        if args.ed_key_file == "-":
            key_input = (stdin or sys.stdin.buffer.read)()
        signed = sign_and_check(args.dmg, public_key=public_key, verify=verify,
                                sign=lambda dmg: sign_with_sparkle(sign_update, dmg, account=account,
                                                                   key_file=args.ed_key_file, key_input=key_input))
        key_input = None
        enclosure = Enclosure(url=url, length=signed.length, signature=signed.signature)
        text = update(current, feed_url=feed_url, version=args.version, build=args.build, enclosure=enclosure,
                      notes_html=notes, minimum_system_version=args.minimum_system_version, staged=staged, now=now)
    except (AppcastError, ElementTree.ParseError, OSError) as error:
        print(f"update-appcast: {error}", file=sys.stderr)
        return 1

    args.appcast.parent.mkdir(parents=True, exist_ok=True)
    partial = args.appcast.with_name(args.appcast.name + ".partial")
    partial.write_text(text, encoding="utf-8")
    os.replace(partial, args.appcast)
    print(f"update-appcast: wrote {args.appcast} with {text.count('<item>')} release(s)")
    print(f"update-appcast: {args.version} ({args.build}) at {url}, {enclosure.length} bytes, signature checked "
          "against the public key")
    if staged:
        print("update-appcast: staged feed: serve its folder from this Mac, never publish it")
    else:
        print(f"update-appcast: publish the disk image at {url} first, then the feed at {feed_url}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
