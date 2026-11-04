import hashlib
import importlib.util
import os
import pathlib
import plistlib
import pty
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.dont_write_bytecode = True

REPO = pathlib.Path(__file__).resolve().parents[3]
RELEASE = REPO / "Tools" / "release"
CHECK = RELEASE / "check-release.sh"
NOTICE = "Early development build — expect rough edges. Please send feedback."
SCAN_CLEAN = "no developer switches or sample-data launch arguments in the app"
SCAN_FAILED = "developer switches or sample-data launch arguments in the app. Only Debug and DevTools builds"

spec = importlib.util.spec_from_file_location("make_cask", RELEASE / "make-cask.py")
make_cask = importlib.util.module_from_spec(spec)
spec.loader.exec_module(make_cask)


def run(args, env=None):
    return subprocess.run([str(a) for a in args], capture_output=True, text=True, env=env, check=False)


def developer_names():
    match = re.search(r'^DEVELOPER_NAMES="([^"]*)"', CHECK.read_text(encoding="utf-8"), re.MULTILINE)
    return match.group(1).split() if match else []


def release_info(**over):
    fields = {"version": "0.1.0", "build": "1001", "commit": "abc1234", "channel": "early-development",
              "prerelease": "yes", "label": "0.1.0 (early development)", "notarized": "yes",
              "dmg": "OpenHuman-Mail-0.1.0.dmg"}
    fields.update(over)
    return "".join(f"{k}={v}\n" for k, v in fields.items() if v is not None)


class BumpVersionTests(unittest.TestCase):
    def setUp(self):
        self.root = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root)
        (self.root / "Tools" / "release").mkdir(parents=True)
        (self.root / "Apps" / "Mail" / "Config").mkdir(parents=True)
        self.script = self.root / "Tools" / "release" / "bump-version.sh"
        shutil.copy2(RELEASE / "bump-version.sh", self.script)
        self.config = self.root / "Apps" / "Mail" / "Config" / "Version.xcconfig"

    def write_config(self, text):
        self.config.write_text(text)

    def test_prints_version_channel_and_label(self):
        self.write_config("MARKETING_VERSION = 0.1.0\nOH_RELEASE_CHANNEL = early-development\n")
        self.assertEqual(run([self.script]).stdout, "0.1.0\n")
        self.assertEqual(run([self.script, "--channel"]).stdout, "early-development\n")
        self.assertEqual(run([self.script, "--label"]).stdout, "0.1.0 (early development)\n")

    def test_a_bump_keeps_the_channel(self):
        self.write_config("// comment\nMARKETING_VERSION = 0.1.9\nOH_RELEASE_CHANNEL = early-development\n")
        result = run([self.script, "patch"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("0.1.9 -> 0.1.10 (early development)", result.stdout)
        self.assertEqual(self.config.read_text(),
                         "// comment\nMARKETING_VERSION = 0.1.10\nOH_RELEASE_CHANNEL = early-development\n")
        self.assertEqual(run([self.script, "--label"]).stdout, "0.1.10 (early development)\n")

    def test_a_missing_channel_stops_every_mode(self):
        self.write_config("MARKETING_VERSION = 0.1.0\n")
        for args in ([], ["--label"], ["patch"]):
            result = run([self.script, *args])
            self.assertEqual(result.returncode, 1, args)
            self.assertIn("OH_RELEASE_CHANNEL", result.stderr)
        self.assertEqual(self.config.read_text(), "MARKETING_VERSION = 0.1.0\n")

    def test_the_checked_in_version_is_an_early_development_build(self):
        self.assertEqual(run([RELEASE / "bump-version.sh", "--channel"]).stdout, "early-development\n")


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("codesign"), "needs macOS codesign")
class CheckReleaseAppTests(unittest.TestCase):
    """Synthetic, ad-hoc signed bundles: a copy of /usr/bin/true with an invented Info.plist."""

    def make_app(self, resources=None, **info):
        root = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, root)
        app = root / "Synthetic.app"
        (app / "Contents" / "MacOS").mkdir(parents=True)
        shutil.copy(shutil.which("true"), app / "Contents" / "MacOS" / "Synthetic")
        for name, text in (resources or {}).items():
            (app / "Contents" / "Resources").mkdir(exist_ok=True)
            (app / "Contents" / "Resources" / name).write_text(text)
        plist = {"CFBundleExecutable": "Synthetic", "CFBundleIdentifier": "dev.example.synthetic",
                 "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1001",
                 "OHGitCommit": "abc1234", "OHReleaseChannel": "early-development"}
        plist.update(info)
        with open(app / "Contents" / "Info.plist", "wb") as handle:
            plistlib.dump({k: v for k, v in plist.items() if v is not None}, handle)
        signed = run(["codesign", "--force", "--sign", "-", app])
        self.assertEqual(signed.returncode, 0, signed.stderr)
        return app

    def test_an_unsigned_early_development_build_passes_the_unsigned_checks(self):
        result = run([CHECK, "--unsigned", self.make_app()])
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("ok    early development build (OHReleaseChannel early-development)", result.stdout)
        self.assertIn("ok    app: ad-hoc signature (unsigned build: no Developer ID, not notarized)", result.stdout)
        self.assertIn(f"ok    {SCAN_CLEAN}", result.stdout)

    def test_a_developer_name_anywhere_in_the_bundle_fails_on_its_own(self):
        app = self.make_app(resources={"steps.json": '{"step": "Launch with -UseFakeData"}',
                                       "notes.txt": "nothing to see"})
        result = run([CHECK, "--unsigned", app])
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertEqual(result.stdout.count("  FAIL  "), 1, result.stdout)
        self.assertIn(f"FAIL  {SCAN_FAILED}", result.stdout)
        self.assertIn("Contents/Resources/steps.json: -UseFakeData\n", result.stdout)
        self.assertNotIn("notes.txt", result.stdout)

    def test_the_scan_reads_the_executable_and_names_each_variable_once(self):
        app = self.make_app()
        with open(app / "Contents" / "MacOS" / "Synthetic", "ab") as handle:
            handle.write(b"\0OPENHUMAN_HOME\0-UseFakeGmail\0OPENHUMAN_HOME\0OPENHUMAN_DEVELOPER_NOTE\0")
        result = run([CHECK, "--unsigned", app])
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn(f"FAIL  {SCAN_FAILED}", result.stdout)
        self.assertIn("Contents/MacOS/Synthetic: -UseFakeGmail OPENHUMAN_DEVELOPER OPENHUMAN_HOME\n", result.stdout)

    def test_every_listed_name_is_caught(self):
        names = developer_names()
        self.assertLessEqual({"-UseFakeGmail", "-UseFakeData", "-UseFixtureStore", "-UseFakeCalendar",
                              "-FakeGmailNotifications", "OPENHUMAN_DEV_FEEDBACK", "OPENHUMAN_DEVELOPER",
                              "OPENHUMAN_HOME", "OPENHUMAN_OAUTH_CLIENT_JSON", "OPENHUMAN_INSECURE_FILE_TOKENS",
                              "OPENHUMAN_STORE_POLL_ONLY"}, set(names))
        result = run([CHECK, "--unsigned", self.make_app(resources={"x.txt": " | ".join(reversed(names))})])
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn(f"Contents/Resources/x.txt: {' '.join(sorted(set(names)))}\n", result.stdout)

    def test_a_build_without_the_marker_fails(self):
        for channel in (None, "", "stable"):
            result = run([CHECK, "--unsigned", self.make_app(OHReleaseChannel=channel)])
            self.assertEqual(result.returncode, 1, channel)
            self.assertIn("FAIL  OHReleaseChannel", result.stdout)

    def test_the_signed_checks_still_reject_an_ad_hoc_build(self):
        result = run([CHECK, "--pre-notarization", self.make_app()])
        self.assertEqual(result.returncode, 1)
        self.assertIn("FAIL  app: ad-hoc signature, not Developer ID", result.stdout)
        self.assertIn("FAIL  app: hardened runtime off", result.stdout)
        self.assertIn("ok    early development build", result.stdout)

    def test_unsigned_takes_no_team(self):
        self.assertEqual(run([CHECK, "--unsigned", "--team", "ABCDE12345", self.make_app()]).returncode, 2)


class CheckReleaseInfoTests(unittest.TestCase):
    def setUp(self):
        self.dir = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.dir)
        self.info = self.dir / "release-info.txt"

    def check(self, info, notes=None):
        self.info.write_text(info)
        if notes is not None:
            (self.dir / "release-notes.md").write_text(notes)
        return run([CHECK, self.info])

    def test_a_marked_release_passes(self):
        result = self.check(release_info(), notes=f"# OpenHuman Mail 0.1.0 (early development)\n\n{NOTICE}\n")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("ok    channel early-development", result.stdout)
        self.assertIn("ok    marked as a pre-release", result.stdout)
        self.assertIn("ok    release notes say it is an early development build", result.stdout)

    def test_an_unsigned_release_is_marked_the_same_way(self):
        result = self.check(release_info(notarized="no", signing="ad-hoc"), notes=NOTICE + "\n")
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_missing_notes_only_warn(self):
        result = self.check(release_info())
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("warn  no release-notes.md", result.stdout)

    def test_each_missing_marker_fails(self):
        cases = {"channel": release_info(channel=None), "other channel": release_info(channel="stable"),
                 "prerelease": release_info(prerelease=None), "not prerelease": release_info(prerelease="no"),
                 "label": release_info(label="0.1.0"), "version": release_info(version="0.1")}
        for name, info in cases.items():
            result = self.check(info)
            self.assertEqual(result.returncode, 1, name)
            self.assertIn("FAIL", result.stdout, name)

    def test_notes_without_the_notice_fail(self):
        result = self.check(release_info(), notes="# OpenHuman Mail 0.1.0\n\nNew things.\n")
        self.assertEqual(result.returncode, 1)
        self.assertIn("FAIL  release-notes.md does not say", result.stdout)


class CheckGitHubReleaseTests(unittest.TestCase):
    """A stand-in `gh` on PATH prints what `gh release view --json isPrerelease,name` would."""

    def check(self, answer, tag="v0.1.0"):
        bin_dir = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, bin_dir)
        args_file = bin_dir / "args"
        gh = bin_dir / "gh"
        gh.write_text(f"#!/bin/sh\nprintf '%s\\n' \"$@\" > '{args_file}'\nprintf '%s\\n' '{answer}'\n")
        gh.chmod(0o755)
        env = dict(os.environ, PATH=f"{bin_dir}{os.pathsep}{os.environ['PATH']}")
        result = run([CHECK, "--github-release", tag], env=env)
        return result, args_file.read_text().split("\n")

    def test_a_pre_release_with_the_marked_title_passes(self):
        result, args = self.check("true\tOpenHuman Mail 0.1.0 (early development)")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(args[:3], ["release", "view", "v0.1.0"])
        self.assertIn("ok    GitHub release v0.1.0 is marked as a pre-release", result.stdout)

    def test_a_full_release_fails(self):
        result, _ = self.check("false\tOpenHuman Mail 0.1.0 (early development)")
        self.assertEqual(result.returncode, 1)
        self.assertIn("FAIL  GitHub release v0.1.0 is not marked as a pre-release", result.stdout)

    def test_a_title_without_the_marker_fails(self):
        result, _ = self.check("true\tOpenHuman Mail 0.1.0")
        self.assertEqual(result.returncode, 1)
        self.assertIn("FAIL  GitHub release v0.1.0 title", result.stdout)


class MakeCaskTests(unittest.TestCase):
    def test_the_cask_says_early_development(self):
        cask = make_cask.cask_text("owner/repo", "0.1.0", "ab" * 32, "early-development")
        self.assertIn('desc "Keyboard-first Gmail client (early development build)"', cask)
        self.assertIn("early development build", cask.split("caveats", 1)[1])
        self.assertIn("https://github.com/owner/repo/issues", cask)
        self.assertIn('url "https://github.com/owner/repo/releases/download/v#{version}/OpenHuman-Mail-#{version}.dmg"',
                      cask)
        self.assertNotIn(";", cask)

    def refusal(self, info):
        directory = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, directory)
        dmg = directory / "OpenHuman-Mail-0.1.0.dmg"
        dmg.write_bytes(b"synthetic")
        if info is not None:
            (directory / "release-info.txt").write_text(info)
        argv = ["make-cask.py", "--repository", "owner/repo", "--version", "0.1.0", "--dmg", str(dmg),
                "--output", str(directory / "out.rb")]
        with mock.patch.object(make_cask.subprocess, "run", side_effect=AssertionError("check-release ran")), \
                mock.patch.object(sys, "argv", argv), mock.patch("sys.stderr"):
            with self.assertRaises(SystemExit) as stop:
                make_cask.main()
        self.assertEqual(stop.exception.code, 2)
        self.assertFalse((directory / "out.rb").exists())

    def test_it_refuses_a_release_without_the_marker(self):
        self.refusal(None)
        self.refusal(release_info(channel=None))
        self.refusal(release_info(prerelease="no"))
        self.refusal(release_info(version="0.2.0"))

    def test_it_refuses_an_unsigned_release(self):
        self.refusal(release_info(notarized="no", signing="ad-hoc"))


FAKE_GH = """#!/bin/sh
printf '%s\\n' "$*" >> "$FAKE_GH_LOG"
case "$*" in
    "release view "*"--json isDraft"*)
        case "$FAKE_GH_STATE" in
            missing) echo "release not found" >&2; exit 1 ;;
            draft) echo true ;;
            published) echo false ;;
        esac ;;
    "release view "*"--json url"*) echo "https://github.example/owner/repo/releases/tag/v0.1.0" ;;
    "release view "*"--json isPrerelease,name"*) printf 'true\\tOpenHuman Mail 0.1.0 (early development)\\n' ;;
esac
exit 0
"""

UNSIGNED_NOTES = (NOTICE + "\n\n## Opening an unsigned build\n\nmacOS may block unsigned builds because they are not "
                  "notarized by Apple.\n")


class PublishGitHubTests(unittest.TestCase):
    """A throwaway Git repository with copies of the release scripts, invented artifacts outside it, and a stand-in
    `gh` on PATH that logs each call. Nothing reaches GitHub. GITHUB_ACTIONS is set as on a hosted runner, except in
    the tests of the confirmation asked for everywhere else."""

    def setUp(self):
        self.root = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root)
        (self.root / "Tools" / "release").mkdir(parents=True)
        for name in ("publish-github.sh", "bump-version.sh", "check-release.sh"):
            shutil.copy2(RELEASE / name, self.root / "Tools" / "release" / name)
        (self.root / "Apps" / "Mail" / "Config").mkdir(parents=True)
        (self.root / "Apps" / "Mail" / "Config" / "Version.xcconfig").write_text(
            "MARKETING_VERSION = 0.1.0\nOH_RELEASE_CHANNEL = early-development\n")
        (self.root / ".gitignore").write_text("build/\n")
        bin_dir = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, bin_dir)
        (bin_dir / "gh").write_text(FAKE_GH)
        (bin_dir / "gh").chmod(0o755)
        self.log = bin_dir / "calls"
        self.env = dict(os.environ, PATH=f"{bin_dir}{os.pathsep}{os.environ['PATH']}", FAKE_GH_LOG=str(self.log),
                        FAKE_GH_STATE="missing", GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1",
                        GITHUB_ACTIONS="true")
        self.env.pop("GH_REPO", None)
        self.git("init", "-q")
        self.commit("fixture")
        self.head = self.git("rev-parse", "HEAD").strip()
        self.short = self.git("rev-parse", "--short", "HEAD").strip()
        self.artifacts = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.artifacts)
        self.dmg = self.artifacts / "OpenHuman-Mail-0.1.0.dmg"
        self.dmg.write_bytes(b"synthetic disk image")
        self.write_info()
        (self.artifacts / "release-notes.md").write_text(UNSIGNED_NOTES)

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.root), *args], env=self.env, capture_output=True, text=True,
                              check=True).stdout

    def commit(self, message):
        self.git("add", "-A")
        self.git("-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-q", "--allow-empty",
                 "-m", message)

    def write_info(self, **over):
        sha = hashlib.sha256(self.dmg.read_bytes()).hexdigest()
        fields = dict(commit=self.short, sha256=sha, notarized="no", signing="ad-hoc")
        fields.update(over)
        (self.artifacts / "release-info.txt").write_text(release_info(**fields))

    def publish(self, *args):
        return run([self.root / "Tools" / "release" / "publish-github.sh", *args], env=self.env)

    def calls(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def refused(self, *args, says):
        result = self.publish("--dry-run", *args)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(says, result.stderr)
        self.assertEqual(self.calls(), [])

    def test_a_dry_run_prints_every_gh_command_and_runs_none(self):
        result = self.publish("--dry-run", "--dmg", self.dmg, "0.1.0")
        self.assertEqual(result.returncode, 0, result.stderr)
        create = next(line for line in result.stdout.splitlines() if "gh release create" in line)
        for part in (f"gh release create v0.1.0 --target {self.head} --prerelease", "--draft",
                     str(self.dmg), f"{self.dmg}.sha256", str(self.artifacts / "release-info.txt"),
                     str(self.artifacts / "release-notes.md")):
            self.assertIn(part, create)
        self.assertIn("gh release upload v0.1.0 --clobber", result.stdout)
        self.assertIn("check-release.sh --github-release v0.1.0", result.stdout)
        self.assertEqual(self.calls(), [])
        self.assertFalse(pathlib.Path(f"{self.dmg}.sha256").exists())

    def test_a_dry_run_without_a_dmg_prints_the_unsigned_build(self):
        result = self.publish("--dry-run", "0.1.0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("make-dmg.sh --unsigned --build-number 1", result.stdout)
        self.assertIn("OpenHuman-Mail-0.1.0-1-unsigned/OpenHuman-Mail-0.1.0.dmg", result.stdout)
        self.assertEqual(self.calls(), [])

    def test_a_new_release_is_a_draft_pre_release(self):
        result = self.publish("--dmg", self.dmg, "0.1.0")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        create = [c for c in self.calls() if c.startswith("release create")]
        self.assertEqual(len(create), 1)
        self.assertIn(f"release create v0.1.0 --target {self.head} --prerelease "
                      f"--title OpenHuman Mail 0.1.0 (early development) --notes-file "
                      f"{self.artifacts / 'release-notes.md'} --draft {self.dmg} {self.dmg}.sha256 "
                      f"{self.artifacts / 'release-info.txt'}", create[0])
        self.assertFalse(any(c.startswith(("release edit", "release upload")) for c in self.calls()))
        sums = pathlib.Path(f"{self.dmg}.sha256").read_text()
        self.assertEqual(sums.split()[0], hashlib.sha256(self.dmg.read_bytes()).hexdigest())
        self.assertIn("draft: https://github.example/owner/repo/releases/tag/v0.1.0", result.stdout)
        self.assertIn("ok    GitHub release v0.1.0 is marked as a pre-release", result.stdout)

    def test_publishing_is_opt_in(self):
        result = self.publish("--publish", "--dmg", self.dmg, "0.1.0")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        create = next(c for c in self.calls() if c.startswith("release create"))
        self.assertNotIn("--draft", create)
        self.assertIn("published: https://", result.stdout)

    def test_an_existing_draft_is_updated(self):
        self.env["FAKE_GH_STATE"] = "draft"
        result = self.publish("--dmg", self.dmg, "0.1.0")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = self.calls()
        self.assertFalse(any(c.startswith("release create") for c in calls))
        edit = next(c for c in calls if c.startswith("release edit"))
        self.assertIn("release edit v0.1.0 --prerelease --title OpenHuman Mail 0.1.0 (early development)", edit)
        self.assertNotIn("--draft", edit)
        self.assertIn(f"release upload v0.1.0 --clobber {self.dmg} {self.dmg}.sha256", "\n".join(calls))

    def test_a_published_release_is_only_updated_with_publish(self):
        self.env["FAKE_GH_STATE"] = "published"
        result = self.publish("--dmg", self.dmg, "0.1.0")
        self.assertEqual(result.returncode, 1)
        self.assertIn("published already", result.stderr)
        self.assertFalse(any(c.startswith(("release edit", "release upload")) for c in self.calls()))

    def publish_at_terminal(self, answer):
        self.env.pop("GITHUB_ACTIONS")
        primary, secondary = pty.openpty()
        try:
            process = subprocess.Popen([str(self.root / "Tools" / "release" / "publish-github.sh"), "--dmg", str(self.dmg),
                                        "0.1.0"], env=self.env, stdin=secondary, stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, text=True)
            os.close(secondary)
            os.write(primary, f"{answer}\n".encode())
            out, err = process.communicate()
        finally:
            os.close(primary)
        return process.returncode, out, err

    def test_outside_github_actions_uploading_needs_a_terminal(self):
        self.env.pop("GITHUB_ACTIONS")
        result = subprocess.run([str(self.root / "Tools" / "release" / "publish-github.sh"), "--dmg", str(self.dmg),
                                 "0.1.0"], env=self.env, stdin=subprocess.DEVNULL, capture_output=True, text=True,
                                check=False)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("the manual release step", result.stderr)
        self.assertEqual(self.calls(), [])

    def test_typing_the_tag_at_a_terminal_uploads(self):
        code, out, err = self.publish_at_terminal("v0.1.0")
        self.assertEqual(code, 0, out + err)
        self.assertIn(f"upload: {self.dmg}", out)
        self.assertTrue(any(c.startswith("release create v0.1.0") for c in self.calls()))

    def test_any_other_answer_sends_nothing(self):
        code, out, err = self.publish_at_terminal("yes")
        self.assertEqual(code, 1, out + err)
        self.assertIn("not confirmed. Nothing was sent to GitHub.", err)
        self.assertEqual(self.calls(), [])

    def test_it_refuses_a_dirty_tree(self):
        (self.root / "notes.txt").write_text("untracked\n")
        self.refused("--dmg", self.dmg, "0.1.0", says="working tree has changes")

    def test_it_refuses_another_version(self):
        self.refused("--dmg", self.dmg, "0.2.0", says="not the version in Apps/Mail/Config/Version.xcconfig (0.1.0)")

    def test_it_refuses_a_tag_on_another_commit(self):
        self.git("tag", "v0.1.0")
        self.commit("later")
        self.refused("--dmg", self.dmg, "0.1.0", says="tag v0.1.0 points at another commit")

    def test_it_refuses_a_dmg_built_from_another_commit(self):
        self.write_info(commit="0000000")
        self.refused("--dmg", self.dmg, "0.1.0", says="built from 0000000")

    def test_it_refuses_a_changed_dmg(self):
        self.dmg.write_bytes(b"changed after the build")
        self.refused("--dmg", self.dmg, "0.1.0", says="not the one in release-info.txt")

    def test_it_refuses_a_release_without_the_marker(self):
        self.write_info(channel="stable")
        self.refused("--dmg", self.dmg, "0.1.0", says="release-info.txt failed the checks")

    def test_it_refuses_notes_without_the_notice_or_the_unsigned_steps(self):
        notes = self.artifacts / "release-notes.md"
        notes.write_text("## Opening an unsigned build\n")
        self.refused("--dmg", self.dmg, "0.1.0", says="release-info.txt failed the checks")
        other = self.artifacts / "other-notes.md"
        other.write_text("## Opening an unsigned build\n")
        notes.write_text(UNSIGNED_NOTES)
        self.refused("--notes", other, "--dmg", self.dmg, "0.1.0", says="the release notes must say")
        other.write_text(NOTICE + "\n")
        self.refused("--notes", other, "--dmg", self.dmg, "0.1.0", says="must explain how to open it")


class DeveloperNamesInSourcesTests(unittest.TestCase):
    """The scan reads bytes, and Swift can fold a short literal into instructions, so the sources are held to the
    same list: app code names them only inside Debug or dev-tools clauses, package code linked into the app never."""

    NOT_IN_THE_APP = {"OPENHUMAN_HOME": ("Packages/OpenHumanCLI/Sources/",
                                         "Packages/OpenHumanStore/Sources/ohstore-helper/")}
    DEV_CLAUSE = re.compile(r"^\s*(DEBUG|OH_DEV_TOOLS)(\s*\|\|\s*(DEBUG|OH_DEV_TOOLS))*\s*$")

    @classmethod
    def lines(cls, text):
        stack = []
        for number, line in enumerate(text.splitlines(), 1):
            code = line.strip()
            if code.startswith("#if "):
                stack.append(bool(cls.DEV_CLAUSE.match(code[4:])))
            elif code.startswith("#elseif ") and stack:
                stack[-1] = bool(cls.DEV_CLAUSE.match(code[8:]))
            elif code == "#else" and stack:
                stack[-1] = False
            elif code == "#endif" and stack:
                stack.pop()
            elif not code.startswith("//"):
                yield number, line, any(stack)

    def hits(self, *folders):
        names = developer_names()
        for folder in folders:
            for directory, subdirectories, files in os.walk(folder):
                subdirectories[:] = sorted(d for d in subdirectories if not d.startswith("."))
                for file in sorted(f for f in files if f.endswith(".swift")):
                    path = pathlib.Path(directory) / file
                    for number, line, gated in self.lines(path.read_text(encoding="utf-8")):
                        for name in names:
                            if name in line:
                                yield path.relative_to(REPO).as_posix(), number, name, gated

    def test_the_clause_reader_follows_nesting_and_else(self):
        text = "#if DEBUG || OH_DEV_TOOLS\na\n#if os(macOS)\nb\n#endif\n#else\nc\n#endif\n#if !DEBUG\nd\n#endif\ne\n"
        gated = {line: flag for _, line, flag in self.lines(text)}
        self.assertEqual(gated, {"a": True, "b": True, "c": False, "d": False, "e": False})
        flavor = {line: flag for _, line, flag in self.lines("#if DEBUG\nx\n#elseif OH_DEV_TOOLS\ny\n#else\nz\n#endif\n")}
        self.assertEqual(flavor, {"x": True, "y": True, "z": False})

    def test_the_app_names_them_only_in_debug_or_dev_tools_code(self):
        found = list(self.hits(REPO / "Apps" / "Mail" / "Sources"))
        self.assertTrue(any(name == "-UseFakeGmail" for _, _, name, _ in found), "the reader found the fake launch")
        self.assertEqual([hit[:3] for hit in found if not hit[3]], [])

    def test_package_code_in_the_app_never_names_them(self):
        sources = sorted(package / "Sources" for package in (REPO / "Packages").iterdir()
                         if (package / "Sources").is_dir())
        self.assertGreater(len(sources), 5, "found the packages")
        stray = [(path, number, name) for path, number, name, _ in self.hits(*sources)
                 if not path.startswith(self.NOT_IN_THE_APP.get(name, ()))]
        self.assertEqual(stray, [])


class SharedTextTests(unittest.TestCase):
    def test_the_notice_reads_the_same_everywhere(self):
        for path in (REPO / "Packages" / "OpenHumanMailCore" / "Sources" / "MailFeatures" / "System" / "BuildLabel.swift",
                     RELEASE / "make-dmg.sh", RELEASE / "publish-github.sh",
                     REPO / "Apps" / "Mail" / "Resources" / "checklist" / "about.early-development.json"):
            self.assertIn(NOTICE, path.read_text(encoding="utf-8"), path)

    def test_the_unsigned_release_notes_explain_how_to_open_an_unsigned_build(self):
        script = (RELEASE / "make-dmg.sh").read_text(encoding="utf-8")
        self.assertIn("## Opening an unsigned build", script)
        for step in ("Privacy & Security", "Open Anyway", "enter your login password"):
            self.assertIn(step, script)

    def test_the_release_guide_sections_the_scripts_name_exist(self):
        headings = re.findall(r"^## (.+)$", (REPO / "docs" / "release" / "RELEASE-HOWTO.md").read_text(encoding="utf-8"),
                              re.MULTILINE)
        named = set()
        for path in RELEASE.iterdir():
            if path.is_file():
                named.update(re.findall(r"RELEASE-HOWTO(?:\.md)?, '([^']+)'", path.read_text(encoding="utf-8")))
        self.assertTrue(named)
        self.assertLessEqual(named, set(headings))


if __name__ == "__main__":
    unittest.main()
