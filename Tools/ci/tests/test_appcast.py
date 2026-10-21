import base64
import importlib.util
import pathlib
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from xml.etree import ElementTree

sys.dont_write_bytecode = True

REPO = pathlib.Path(__file__).resolve().parents[3]
RELEASE = REPO / "Tools" / "release"
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"

spec = importlib.util.spec_from_file_location("update_appcast", RELEASE / "update-appcast.py")
appcast = importlib.util.module_from_spec(spec)
spec.loader.exec_module(appcast)

SIGNATURE = 'sparkle:edSignature="' + "A" * 86 + '==" length="123456"'
NOW = datetime(2026, 10, 21, 12, 0, tzinfo=timezone.utc)


def url(version):
    return f"https://github.com/michaelmagan/OpenHuman/releases/download/v{version}/OpenHuman-Mail-{version}.dmg"


def add(text, version="0.2.0", build="140", **overrides):
    args = dict(version=version, build=build, download_url=url(version), signature_fragment=SIGNATURE,
                notes_html="<h3>Changes</h3>\n<ul>\n  <li>Faster search</li>\n</ul>", now=NOW)
    args.update(overrides)
    return appcast.update(text, **args)


def items(text):
    return ElementTree.fromstring(text.encode()).findall("./channel/item")


class AppcastTests(unittest.TestCase):
    def test_the_committed_appcast_is_an_empty_feed_at_the_url_the_app_reads(self):
        text = (REPO / "appcast.xml").read_text(encoding="utf-8")
        root = ElementTree.fromstring(text.encode())
        self.assertEqual(root.findtext("./channel/link"), appcast.FEED_URL)
        project = (REPO / "Apps" / "Mail" / "project.yml").read_text(encoding="utf-8")
        self.assertIn(f"SUFeedURL: {appcast.FEED_URL}\n", project)
        self.assertEqual(text, appcast.APPCAST_TEMPLATE.format(title=appcast.TITLE, link=appcast.FEED_URL, items=""),
                         "the release workflow rewrites the whole file, so the committed one matches its template")

    def test_a_release_becomes_one_item_sparkle_can_read(self):
        text = add("", early_development_note="Early development build — expect rough edges.")
        [item] = items(text)
        self.assertEqual(item.findtext(f"{SPARKLE}version"), "140")
        self.assertEqual(item.findtext(f"{SPARKLE}shortVersionString"), "0.2.0")
        self.assertEqual(item.findtext(f"{SPARKLE}minimumSystemVersion"), "26.0")
        self.assertEqual(item.findtext("pubDate"), "Wed, 21 Oct 2026 12:00:00 +0000")
        enclosure = item.find("enclosure")
        self.assertEqual(enclosure.get("url"), url("0.2.0"))
        self.assertEqual(enclosure.get(f"{SPARKLE}edSignature"), "A" * 86 + "==")
        self.assertEqual(enclosure.get("length"), "123456")
        description = item.findtext("description")
        self.assertIn("<li>Faster search</li>", description)
        self.assertIn("<p><em>Early development build — expect rough edges.</em></p>", description)
        self.assertNotIn("color", description, "the web view follows the system appearance")

    def test_new_releases_go_on_top_and_older_ones_stay(self):
        text = add(add("", "0.2.0", "140"), "0.3.0", "150")
        self.assertEqual([i.findtext(f"{SPARKLE}shortVersionString") for i in items(text)], ["0.3.0", "0.2.0"])

    def test_the_same_version_again_replaces_its_entry(self):
        text = add(add("", "0.2.0", "140"), "0.2.0", "141")
        self.assertEqual([i.findtext(f"{SPARKLE}version") for i in items(text)], ["141"])

    def test_a_build_number_that_does_not_go_up_is_refused(self):
        first = add("", "0.2.0", "140")
        for build in ("140", "139"):
            with self.subTest(build=build), self.assertRaisesRegex(appcast.AppcastError, "not above build 140"):
                add(first, "0.3.0", build)

    def test_an_item_in_another_layout_stops_the_run_instead_of_being_dropped(self):
        hand_edited = add("", "0.2.0", "140").replace("    <item>", "  <item>")
        with self.assertRaisesRegex(appcast.AppcastError, "cannot read"):
            add(hand_edited, "0.3.0", "150")

    def test_notes_cannot_end_the_cdata_section(self):
        text = add("", notes_html="<p>a ]]> b</p>")
        self.assertIn("<p>a ]]> b</p>", items(text)[0].findtext("description"))

    def test_bad_input_is_refused_before_anything_is_written(self):
        cases = {
            "version": dict(version="0.2", download_url=url("0.2")),
            "build number": dict(build="14a"),
            "signature": dict(signature_fragment='sparkle:edSignature="x" length="1" extra="y"'),
            "download": dict(download_url="https://example.com/OpenHuman-Mail-0.2.0.dmg"),
            "minimum macOS": dict(minimum_system_version="26"),
        }
        for name, overrides in cases.items():
            with self.subTest(name), self.assertRaisesRegex(appcast.AppcastError, name):
                add("", **overrides)
        with self.assertRaisesRegex(appcast.AppcastError, "download"):
            add("", download_url=url("0.1.0"))

    def test_the_command_writes_the_file_and_fails_without_writing_on_bad_input(self):
        with tempfile.TemporaryDirectory() as folder:
            feed = pathlib.Path(folder) / "appcast.xml"
            notes = pathlib.Path(folder) / "notes.html"
            notes.write_text("<ul><li>One</li></ul>", encoding="utf-8")
            def command(version, build):
                args = [sys.executable, "-B", RELEASE / "update-appcast.py", "--appcast", feed, "--version", version,
                        "--build", build, "--download-url", url(version), "--signature-fragment", SIGNATURE,
                        "--notes-file", notes]
                return subprocess.run([str(a) for a in args], capture_output=True, text=True)
            ok = command("0.2.0", "140")
            self.assertEqual(ok.returncode, 0, ok.stderr)
            self.assertEqual(len(items(feed.read_text(encoding="utf-8"))), 1)
            before = feed.read_text(encoding="utf-8")
            bad = command("0.3.0", "1")
            self.assertEqual(bad.returncode, 1)
            self.assertTrue(bad.stderr.startswith("update-appcast: "), bad.stderr)
            self.assertEqual(feed.read_text(encoding="utf-8"), before)


class ReleaseNotesTemplateTests(unittest.TestCase):
    def test_every_value_in_the_appcast_template_is_escaped(self):
        text = (RELEASE / "appcast-body.tera").read_text(encoding="utf-8")
        body = re.sub(r"\{#.*?#\}", "", text, flags=re.DOTALL)
        expressions = re.findall(r"\{\{(.*?)\}\}", body)
        self.assertTrue(expressions)
        for expression in expressions:
            self.assertTrue(expression.strip().endswith("escape_xml"), expression)


# RFC 8032, section 7.1, test 1: an Ed25519 seed and its public key, in the base64 form Sparkle's tools use
RFC_SEED = "nWGxne/9WmC6hEr0kuwsxERJxWl7MmkZcDusAxyuf2A="
RFC_PUBLIC = "11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo="


@unittest.skipUnless(platform.system() == "Darwin" and shutil.which("xcrun"), "needs macOS and Swift with CryptoKit")
class SparkleKeyCheckTests(unittest.TestCase):
    def check(self, private, public):
        return subprocess.run(["xcrun", "swift", str(RELEASE / "check-sparkle-key.swift"), public], input=private,
                              capture_output=True, text=True)

    def test_a_private_key_matches_only_its_own_public_key(self):
        ok = self.check(RFC_SEED + "\n", RFC_PUBLIC)
        self.assertEqual(ok.returncode, 0, ok.stderr)
        other = "A" * 43 + "="
        wrong = self.check(RFC_SEED, other)
        self.assertEqual(wrong.returncode, 1, wrong.stderr)
        self.assertNotIn(RFC_SEED, wrong.stdout + wrong.stderr, "the private key is never printed")

    def test_an_old_format_key_is_refused(self):
        old = base64.b64encode(bytes(64) + base64.b64decode(RFC_PUBLIC)).decode()
        self.assertEqual(self.check(old, RFC_PUBLIC).returncode, 2)

    def test_unreadable_input_exits_2(self):
        self.assertEqual(self.check("not a key", RFC_PUBLIC).returncode, 2)
        self.assertEqual(self.check(RFC_SEED, "short").returncode, 2)


if __name__ == "__main__":
    unittest.main()
