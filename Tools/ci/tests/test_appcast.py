import base64
import contextlib
import importlib.util
import io
import pathlib
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from urllib.parse import urlsplit
from xml.etree import ElementTree

sys.dont_write_bytecode = True

REPO = pathlib.Path(__file__).resolve().parents[3]
RELEASE = REPO / "Tools" / "release"
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
FEED = "https://updates.example.test/appcast.xml"
PREFIX = "https://updates.example.test/mail/"
NOW = datetime(2026, 10, 21, 12, 0, tzinfo=timezone.utc)

spec = importlib.util.spec_from_file_location("update_appcast", RELEASE / "update-appcast.py")
appcast = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = appcast
spec.loader.exec_module(appcast)

# RFC 8032, section 7.1, test 1: an Ed25519 public key and its signature of the empty message, in Sparkle's base64 form
RFC_PUBLIC = "11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo="
RFC_OTHER_PUBLIC = "PUAXw+hDiVqStwqnTRt+vJyYLM8uxJaMwM1V8Sr0Zgw="  # section 7.1, test 2
RFC_SIGNATURE = "5VZDAMNgrHKQhuLMgG6CioSHfx645dl02HPgZSJJAVVfuIIVkKM7rMYeOXAc+bRr0lv18FlbviRlUUFDjnoQCw=="
SIGNATURE = base64.b64encode(bytes(range(64))).decode()
SECRET = "c2VjcmV0LXByaXZhdGUta2V5LW5ldmVyLXByaW50ZWQ="


def enclosure(version="0.2.0", length=123456, prefix=PREFIX):
    return appcast.Enclosure(url=f"{prefix}OpenHuman-Mail-{version}.dmg", length=length, signature=SIGNATURE)


def add(text, version="0.2.0", build="1208", **overrides):
    args = dict(feed_url=FEED, version=version, build=build, enclosure=enclosure(version),
                notes_html="<h3>Changes</h3>\n<ul>\n  <li>Faster search</li>\n</ul>", now=NOW)
    args.update(overrides)
    return appcast.update(text, **args)


def items(text):
    return ElementTree.fromstring(text.encode()).findall("./channel/item")


class AppcastTests(unittest.TestCase):
    def test_a_release_becomes_one_item_sparkle_can_read(self):
        text = add("")
        root = ElementTree.fromstring(text.encode())
        self.assertEqual(root.findtext("./channel/link"), FEED)
        [item] = items(text)
        self.assertEqual(item.findtext(f"{SPARKLE}version"), "1208")
        self.assertEqual(item.findtext(f"{SPARKLE}shortVersionString"), "0.2.0")
        self.assertEqual(item.findtext(f"{SPARKLE}minimumSystemVersion"), "26.0")
        self.assertEqual(item.findtext("pubDate"), "Wed, 21 Oct 2026 12:00:00 +0000")
        found = item.find("enclosure")
        self.assertEqual(found.get("url"), f"{PREFIX}OpenHuman-Mail-0.2.0.dmg")
        self.assertEqual(found.get(f"{SPARKLE}edSignature"), SIGNATURE)
        self.assertEqual(found.get("length"), "123456")
        self.assertIn("<li>Faster search</li>", item.findtext("description"))
        self.assertNotIn("color", item.findtext("description"), "the web view follows the system appearance")

    def test_new_releases_go_on_top_and_older_ones_stay(self):
        text = add(add("", "0.2.0", "1208"), "0.3.0", "1300")
        self.assertEqual([i.findtext(f"{SPARKLE}shortVersionString") for i in items(text)], ["0.3.0", "0.2.0"])

    def test_the_same_version_again_replaces_its_entry(self):
        text = add(add("", "0.2.0", "1208"), "0.2.0", "1209")
        self.assertEqual([i.findtext(f"{SPARKLE}version") for i in items(text)], ["1209"])

    def test_a_build_number_that_does_not_go_up_is_refused(self):
        first = add("", "0.2.0", "1208")
        for build in ("1208", "1207"):
            with self.subTest(build=build), self.assertRaisesRegex(appcast.AppcastError, "not above build 1208"):
                add(first, "0.3.0", build)

    def test_an_item_in_another_layout_stops_the_run_instead_of_being_dropped(self):
        hand_edited = add("").replace("    <item>", "  <item>")
        with self.assertRaisesRegex(appcast.AppcastError, "cannot read"):
            add(hand_edited, "0.3.0", "1300")

    def test_notes_cannot_end_the_cdata_section(self):
        text = add("", notes_html="<p>a ]]> b</p>")
        self.assertIn("<p>a ]]> b</p>", items(text)[0].findtext("description"))

    def test_bad_input_is_refused(self):
        cases = {
            "version": dict(version="0.2"),
            "build number": dict(build="12a"),
            "signature": dict(enclosure=appcast.Enclosure(url=f"{PREFIX}x.dmg", length=1, signature="abc")),
            "empty": dict(enclosure=appcast.Enclosure(url=f"{PREFIX}x.dmg", length=0, signature=SIGNATURE)),
            "minimum macOS": dict(minimum_system_version="26"),
        }
        for name, overrides in cases.items():
            with self.subTest(name), self.assertRaisesRegex(appcast.AppcastError, name):
                add("", **overrides)

    def test_a_published_feed_needs_https_everywhere(self):
        for feed, download in (("http://updates.example.test/appcast.xml", PREFIX),
                               (FEED, "http://updates.example.test/mail/"),
                               ("http://127.0.0.1:8000/appcast.xml", PREFIX),
                               (FEED, "file:///tmp/updates/")):
            with self.subTest(feed=feed, download=download), self.assertRaisesRegex(appcast.AppcastError, "https://"):
                add("", feed_url=feed, enclosure=enclosure(prefix=download))

    def test_a_staged_feed_stays_on_this_mac(self):
        local = "http://127.0.0.1:8000/"
        text = add("", feed_url=local + "appcast.xml", enclosure=enclosure(prefix=local), staged=True)
        root = ElementTree.fromstring(text.encode())
        self.assertEqual(root.findtext("./channel/title"), "OpenHuman Mail (staged update test)")
        self.assertEqual(items(text)[0].find("enclosure").get("url"), local + "OpenHuman-Mail-0.2.0.dmg")
        with self.assertRaisesRegex(appcast.AppcastError, "staged feed stays on this Mac"):
            add("", staged=True)
        for feed, download in (("file:///tmp/appcast.xml", local), (local + "appcast.xml", "file:///tmp/updates/"),
                               (local + "appcast.xml", "http://updates.example.test/mail/")):
            with self.subTest(feed=feed, download=download), \
                    self.assertRaisesRegex(appcast.AppcastError, "only over http or https"):
                add("", feed_url=feed, enclosure=enclosure(prefix=download), staged=True)

    def test_a_staged_feed_and_a_published_one_are_never_mixed(self):
        local = "http://127.0.0.1:8000/"
        staged = add("", feed_url=local + "appcast.xml", enclosure=enclosure(prefix=local), staged=True)
        with self.assertRaisesRegex(appcast.AppcastError, "never mixed"):
            add(staged, "0.3.0", "1300")
        with self.assertRaisesRegex(appcast.AppcastError, "never mixed"):
            add(add(""), "0.3.0", "1300", feed_url=local + "appcast.xml", enclosure=enclosure("0.3.0", prefix=local),
                staged=True)


class ReleaseNotesTests(unittest.TestCase):
    def test_headings_lists_and_paragraphs_become_html(self):
        notes = ("Early development build — expect rough edges.\n\n## Changes\n\n- Faster search\n- Fixed sync\n\n"
                 "## Known limitations\nNone yet.")
        self.assertEqual(appcast.notes_to_html(notes),
                         "<p>Early development build — expect rough edges.</p>\n<h3>Changes</h3>\n<ul>\n"
                         "  <li>Faster search</li>\n  <li>Fixed sync</li>\n</ul>\n<h3>Known limitations</h3>\n"
                         "<p>None yet.</p>")

    def test_every_character_of_the_notes_is_escaped(self):
        result = appcast.notes_to_html("- <script>alert(1)</script> & more\n<b>bold</b>")
        self.assertNotIn("<script>", result)
        self.assertNotIn("<b>", result)
        self.assertIn("&lt;script&gt;alert(1)&lt;/script&gt; &amp; more", result)


class SignAndCheckTests(unittest.TestCase):
    def setUp(self):
        folder = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, folder)
        self.dmg = folder / "OpenHuman-Mail-0.2.0.dmg"
        self.dmg.write_bytes(b"disk image bytes" * 100)

    def test_the_length_is_the_size_that_was_signed(self):
        signed = appcast.sign_and_check(self.dmg, public_key=RFC_PUBLIC, sign=lambda _: SIGNATURE,
                                        verify=lambda key, signature, path: key == RFC_PUBLIC and signature == SIGNATURE)
        self.assertEqual(signed.length, 1600)
        self.assertEqual(signed.signature, SIGNATURE)

    def test_a_disk_image_that_changes_while_it_is_signed_is_refused(self):
        def sign(path):
            with open(path, "ab") as handle:
                handle.write(b"x")
            return SIGNATURE
        with self.assertRaisesRegex(appcast.AppcastError, "changed while it was signed"):
            appcast.sign_and_check(self.dmg, public_key=RFC_PUBLIC, sign=sign, verify=lambda *_: True)

    def test_a_signature_from_another_key_is_refused(self):
        with self.assertRaisesRegex(appcast.AppcastError, "does not match OH_SPARKLE_PUBLIC_KEY"):
            appcast.sign_and_check(self.dmg, public_key=RFC_PUBLIC, sign=lambda _: SIGNATURE, verify=lambda *_: False)

    def test_output_that_is_not_a_signature_is_refused(self):
        with self.assertRaisesRegex(appcast.AppcastError, "did not print"):
            appcast.sign_and_check(self.dmg, public_key=RFC_PUBLIC, sign=lambda _: 'sparkle:edSignature="x"',
                                   verify=lambda *_: True)


FAKE_SIGN_UPDATE = """#!/usr/bin/env python3
import sys
with open(sys.argv[0] + ".log", "a") as log:
    log.write("argv " + " ".join(sys.argv[1:]) + "\\n")
    log.write("stdin " + sys.stdin.read() + "\\n")
print("{signature}")
"""


class CommandTests(unittest.TestCase):
    """The command with a stand-in sign_update that records what it was given, and stand-ins for the disk image
    inspection and the public key check, so no key, keychain or disk image is used."""

    def setUp(self):
        self.folder = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.folder)
        self.dmg = self.folder / "OpenHuman-Mail-0.2.0.dmg"
        self.dmg.write_bytes(b"disk image bytes")
        self.notes = self.folder / "release-notes.md"
        self.notes.write_text("## Changes\n- Faster search\n", encoding="utf-8")
        self.feed = self.folder / "out" / "appcast.xml"
        self.sign_update = self.folder / "sign_update"
        self.sign_update.write_text(FAKE_SIGN_UPDATE.format(signature=SIGNATURE), encoding="utf-8")
        self.sign_update.chmod(0o755)
        self.environ = {"OH_UPDATE_FEED_URL": FEED, "OH_SPARKLE_PUBLIC_KEY": RFC_PUBLIC,
                        "OH_SPARKLE_ACCOUNT": "openhuman-mail", "OH_RELEASE_ENV": str(self.folder / "absent.env")}
        self.app = {"CFBundleShortVersionString": "0.2.0", "CFBundleVersion": "1208", "SUFeedURL": FEED,
                    "SUPublicEDKey": RFC_PUBLIC}

    def run_command(self, *extra, staged=False, key=None):
        args = ["--dmg", str(self.dmg), "--version", "0.2.0", "--build", "1208", "--notes-file", str(self.notes),
                "--appcast", str(self.feed), "--sign-update", str(self.sign_update)]
        if not staged:
            args += ["--download-url-prefix", PREFIX]
        # Why: the last value of an option wins, so a test's own options replace these defaults
        args += extra
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = appcast.main(args, environ=self.environ, stdin=lambda: (key or "").encode(), now=NOW,
                                inspect=lambda path: self.app, verify=lambda public, signature, path: True)
        return code, out.getvalue(), err.getvalue()

    def calls(self):
        log = pathlib.Path(str(self.sign_update) + ".log")
        return log.read_text().splitlines() if log.exists() else []

    def test_it_signs_with_the_keychain_account_and_writes_the_feed(self):
        code, out, err = self.run_command()
        self.assertEqual(code, 0, err)
        self.assertEqual(self.calls()[0], f"argv -p --account openhuman-mail {self.dmg}")
        [item] = items(self.feed.read_text(encoding="utf-8"))
        self.assertEqual(item.find("enclosure").get("url"), f"{PREFIX}OpenHuman-Mail-0.2.0.dmg")
        self.assertEqual(item.find("enclosure").get("length"), str(len(b"disk image bytes")))
        self.assertIn("<li>Faster search</li>", item.findtext("description"))
        self.assertIn("signature checked against the public key", out)

    def test_a_key_from_standard_input_reaches_sign_update_and_is_never_printed(self):
        code, out, err = self.run_command("--ed-key-file", "-", key=SECRET)
        self.assertEqual(code, 0, err)
        argv, stdin = self.calls()[:2]
        self.assertEqual(argv, f"argv -p --ed-key-file - {self.dmg}")
        self.assertEqual(stdin, f"stdin {SECRET}")
        self.assertNotIn(SECRET, out + err + self.feed.read_text(encoding="utf-8"))

    def test_an_app_that_does_not_match_is_refused_before_signing(self):
        for key, value in (("CFBundleVersion", "1207"), ("SUFeedURL", ""), ("SUPublicEDKey", "other"),
                           ("CFBundleShortVersionString", "0.1.0")):
            with self.subTest(key):
                self.app = dict(self.app, **{key: value})
                code, out, err = self.run_command()
                self.assertEqual(code, 1)
                self.assertIn(f"has {key}", err)
                self.assertEqual(self.calls(), [])
                self.assertFalse(self.feed.exists())
                self.setUp()

    def test_a_published_feed_refuses_a_download_that_is_not_https(self):
        code, out, err = self.run_command("--download-url-prefix", "http://updates.example.test/mail/")
        self.assertEqual(code, 1)
        self.assertIn("https://", err)
        self.assertEqual(self.calls(), [])

    def test_staged_writes_a_feed_served_from_this_mac_and_ignores_the_published_feed(self):
        local = "http://127.0.0.1:8000/"
        self.app["SUFeedURL"] = local + "appcast.xml"
        code, out, err = self.run_command("--staged", local, staged=True)
        self.assertEqual(code, 0, err)
        text = self.feed.read_text(encoding="utf-8")
        self.assertEqual(ElementTree.fromstring(text.encode()).findtext("./channel/link"), local + "appcast.xml")
        self.assertEqual(items(text)[0].find("enclosure").get("url"), local + "OpenHuman-Mail-0.2.0.dmg")
        self.assertNotIn(FEED, text)
        self.assertIn("never publish it", out)

    def test_a_failed_run_leaves_the_feed_as_it_was(self):
        self.assertEqual(self.run_command()[0], 0)
        before = self.feed.read_text(encoding="utf-8")
        # Why: a later version whose build number is lower; the same version again would replace its entry instead
        self.app.update(CFBundleShortVersionString="0.3.0", CFBundleVersion="1")
        code, out, err = self.run_command("--version", "0.3.0", "--build", "1")
        self.assertEqual(code, 1)
        self.assertTrue(err.startswith("update-appcast: "), err)
        self.assertIn("not above build 1208", err)
        self.assertEqual(self.feed.read_text(encoding="utf-8"), before)


class SettingsTests(unittest.TestCase):
    def test_settings_come_from_the_environment_then_the_files_make_dmg_reads(self):
        with tempfile.TemporaryDirectory() as folder:
            env_file = pathlib.Path(folder) / "release.env"
            env_file.write_text('# a comment\n: "${OH_UPDATE_FEED_URL:=' + FEED + '}"\n'
                                ': "${OH_SPARKLE_PUBLIC_KEY:=' + RFC_PUBLIC + '}"\nOH_SPARKLE_ACCOUNT=from-file\n'
                                ': "${OH_NOTARY_PROFILE:=$(echo ignored)}"\n', encoding="utf-8")
            found = appcast.settings({"OH_RELEASE_ENV": str(env_file), "OH_SPARKLE_ACCOUNT": "from-environment"})
        self.assertEqual(found["OH_UPDATE_FEED_URL"], FEED)
        self.assertEqual(found["OH_SPARKLE_PUBLIC_KEY"], RFC_PUBLIC)
        self.assertEqual(found["OH_SPARKLE_ACCOUNT"], "from-environment")
        self.assertNotEqual(found.get("OH_NOTARY_PROFILE"), "$(echo ignored)", "lines are read, never run")


@unittest.skipUnless(platform.system() == "Darwin" and shutil.which("xcrun"), "needs macOS and Swift with CryptoKit")
class SignatureScriptTests(unittest.TestCase):
    def check(self, public, signature, data=b""):
        with tempfile.NamedTemporaryFile() as handle:
            handle.write(data)
            handle.flush()
            return subprocess.run(["xcrun", "swift", str(RELEASE / "verify-update-signature.swift"), public, signature,
                                   handle.name], capture_output=True, text=True)

    def test_the_rfc_8032_signature_matches_only_its_message_and_key(self):
        self.assertEqual(self.check(RFC_PUBLIC, RFC_SIGNATURE).returncode, 0)
        self.assertEqual(self.check(RFC_PUBLIC, RFC_SIGNATURE, b"x").returncode, 1)
        self.assertEqual(self.check(RFC_OTHER_PUBLIC, RFC_SIGNATURE).returncode, 1)

    def test_unreadable_input_exits_2(self):
        self.assertEqual(self.check("short", RFC_SIGNATURE).returncode, 2)
        self.assertEqual(self.check(RFC_PUBLIC, "short").returncode, 2)


class PinnedSettingsTests(unittest.TestCase):
    def test_sparkle_is_pinned_to_one_revision_everywhere(self):
        versions = (REPO / "Tools" / "versions.env").read_text(encoding="utf-8")
        revision = re.search(r"^SPARKLE_REVISION=([0-9a-f]{40})$", versions, re.MULTILINE).group(1)
        project = (REPO / "Apps" / "Mail" / "project.yml").read_text(encoding="utf-8")
        self.assertIn(f"Sparkle: {{ url: https://github.com/sparkle-project/Sparkle, revision: {revision} }}", project)
        self.assertIn("- { package: Sparkle, product: Sparkle }", project)

    def test_every_build_has_an_empty_feed_and_key_unless_make_dmg_sets_them(self):
        project = (REPO / "Apps" / "Mail" / "project.yml").read_text(encoding="utf-8")
        self.assertIn("SUFeedURL: $(OH_UPDATE_FEED_URL)\n", project)
        self.assertIn("SUPublicEDKey: $(OH_SPARKLE_PUBLIC_KEY)\n", project)
        self.assertNotRegex(project, r"SUEnable(Downloader|InstallerLauncher)Service")
        base = (REPO / "Apps" / "Mail" / "Config" / "Base.xcconfig").read_text(encoding="utf-8")
        self.assertRegex(base, r"(?m)^OH_UPDATE_FEED_URL =$")
        self.assertRegex(base, r"(?m)^OH_SPARKLE_PUBLIC_KEY =$")
        make_dmg = (RELEASE / "make-dmg.sh").read_text(encoding="utf-8")
        self.assertIn('UPDATES=("OH_UPDATE_FEED_URL=$FEED" "OH_SPARKLE_PUBLIC_KEY=$KEY")', make_dmg)

    def test_no_feed_address_is_written_into_the_code(self):
        address = re.compile(r"https?://[^\s\"')]*appcast[^\s\"')]*")
        places = [*sorted((REPO / "Apps").rglob("*.swift")), *sorted((REPO / "Apps").rglob("*.yml")),
                  *sorted((REPO / "Packages").rglob("*.swift")), *sorted((REPO / ".github").rglob("*.yml"))]
        for path in places:
            if ".build" in path.parts:
                continue
            for found in address.findall(path.read_text(encoding="utf-8", errors="replace")):
                self.assertIn(urlsplit(found).hostname, (None, "updates.example.test", "127.0.0.1", "localhost"),
                              f"{path}: {found}")


if __name__ == "__main__":
    unittest.main()
