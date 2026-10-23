import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True

REPO = pathlib.Path(__file__).resolve().parents[3]
SIGNING = REPO / "Tools" / "signing"
ZERO = "0" * 40


class SigningHelperTests(unittest.TestCase):
    """The installed helpers, copied into a throwaway signing folder, with git reading only a throwaway global config.
    No key exists and no key service runs, so nothing here can sign; the tests cover how failures surface."""

    def setUp(self):
        self.home = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.home)
        self.signing = self.home / "signing"
        (self.signing / "bin").mkdir(parents=True)
        for name in ("ssh-keygen-signing", "signature-check"):
            shutil.copy2(SIGNING / "libexec" / name, self.signing / "bin" / name)
        self.config = self.home / "gitconfig"
        self.config.write_text("")
        self.env = dict(os.environ, HOME=str(self.home), GIT_CONFIG_GLOBAL=str(self.config), GIT_CONFIG_NOSYSTEM="1")
        for name in ("SSH_AUTH_SOCK", "GIT_DIR", "GIT_WORK_TREE"):
            self.env.pop(name, None)
        self.git_global("user.name", "Test")
        self.git_global("user.email", "me@example.com")
        self.repo = self.home / "repo"
        self.git("init", "-q", str(self.repo), cwd=self.home)

    def git(self, *args, cwd=None, check=True, env=None):
        return subprocess.run(["git", *args], cwd=cwd or self.repo, env=env or self.env, capture_output=True, text=True,
                              check=check)

    def git_global(self, key, value):
        self.git("config", "--global", key, value, cwd=self.home)

    def unsigned_commit(self, message, email="me@example.com", date=None):
        env = dict(self.env)
        if date:
            env.update(GIT_AUTHOR_DATE=date, GIT_COMMITTER_DATE=date)
        self.git("-c", "commit.gpgsign=false", "-c", f"user.email={email}", "commit", "-q", "--allow-empty", "-m",
                 message, env=env)
        return self.git("rev-parse", "HEAD").stdout.strip()

    def hook(self, mode, stdin=""):
        return subprocess.run([str(self.signing / "bin" / "signature-check"), mode, "origin", "https://example.com/r"],
                              cwd=self.repo, env=self.env, input=stdin, capture_output=True, text=True, check=False)

    def test_without_the_key_service_git_makes_no_commit(self):
        self.git_global("gpg.format", "ssh")
        self.git_global("commit.gpgsign", "true")
        self.git_global("gpg.ssh.program", str(self.signing / "bin" / "ssh-keygen-signing"))
        self.git_global("user.signingkey", "key::ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleOnlyNotAKeyExampleOnlyNotAKey")
        result = self.git("commit", "--allow-empty", "-m", "signed", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("the commit-signing key service is not running", result.stderr)
        self.assertIn("failed to write commit object", result.stderr)
        self.assertNotEqual(self.git("rev-parse", "-q", "--verify", "HEAD", check=False).returncode, 0)

    def test_after_an_unsigned_commit_it_warns(self):
        self.unsigned_commit("unsigned")
        result = self.hook("post-commit")
        self.assertEqual(result.returncode, 0)
        self.assertIn("has no good signature (status N)", result.stderr)

    def test_it_refuses_to_push_your_unsigned_commit(self):
        sha = self.unsigned_commit("unsigned")
        result = self.hook("pre-push", f"refs/heads/main {sha} refs/heads/main {ZERO}\n")
        self.assertEqual(result.returncode, 1)
        self.assertIn("refusing to push commits you made without a good signature", result.stderr)
        self.assertIn(sha[:12], result.stderr)

    def test_it_lets_other_peoples_commits_and_deletions_through(self):
        sha = self.unsigned_commit("someone else's", email="other@example.com")
        self.assertEqual(self.hook("pre-push", f"refs/heads/main {sha} refs/heads/main {ZERO}\n").returncode, 0)
        self.assertEqual(self.hook("pre-push", f"(delete) {ZERO} refs/heads/old {sha}\n").returncode, 0)

    def test_it_checks_only_commits_the_remote_does_not_have(self):
        base = self.unsigned_commit("already pushed")
        tip = self.unsigned_commit("someone else's", email="other@example.com")
        result = self.hook("pre-push", f"refs/heads/main {tip} refs/heads/main {base}\n")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_commits_before_the_guard_was_installed_are_not_checked(self):
        (self.signing / "enforce-since").write_text("2026-01-01T00:00:00Z\n")
        old = self.unsigned_commit("old", date="2025-06-01T12:00:00Z")
        self.assertEqual(self.hook("pre-push", f"refs/heads/main {old} refs/heads/main {ZERO}\n").returncode, 0)
        new = self.unsigned_commit("new")
        self.assertEqual(self.hook("pre-push", f"refs/heads/main {new} refs/heads/main {ZERO}\n").returncode, 1)


class SigningScriptTests(unittest.TestCase):
    """setup.sh and verify.sh, copied into a throwaway tree and run with a throwaway HOME and git config, so they find
    no key, keychain or settings of the person running the tests."""

    def setUp(self):
        self.root = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root)
        shutil.copytree(SIGNING, self.root / "Tools" / "signing")
        self.home = self.root / "home"
        self.home.mkdir()
        config = self.root / "gitconfig"
        config.write_text("[user]\n\tname = Test\n\temail = me@example.com\n")
        self.env = dict(os.environ, HOME=str(self.home), GIT_CONFIG_GLOBAL=str(config), GIT_CONFIG_NOSYSTEM="1",
                        OH_RELEASE_ENV=str(self.home / "absent.env"))
        for name in ("OH_SIGNING_KEYCHAIN", "OH_SIGNING_KEYCHAIN_PASSWORD_FILE", "OH_SIGN_IDENTITY", "OH_NOTARY_PROFILE",
                     "OH_UPDATE_FEED_URL", "OH_SPARKLE_PUBLIC_KEY", "OH_SPARKLE_ACCOUNT", "SSH_CONNECTION", "SSH_TTY"):
            self.env.pop(name, None)

    def run_script(self, name, *args):
        return subprocess.run(["bash", str(self.root / "Tools" / "signing" / name), *args], env=self.env,
                              stdin=subprocess.DEVNULL, capture_output=True, text=True, check=False)

    def test_setup_needs_a_terminal(self):
        result = self.run_script("setup.sh")
        self.assertEqual(result.returncode, 1)
        self.assertIn("run this yourself in Terminal.app", result.stderr)
        self.assertEqual(list(self.home.iterdir()), [])

    def test_a_setup_dry_run_changes_nothing(self):
        result = self.run_script("setup.sh", "--dry-run")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("dry run: would create", result.stdout)
        self.assertIn("dry run: nothing was changed.", result.stdout)
        self.assertEqual(list(self.home.iterdir()), [])

    def test_verify_fails_loudly_without_a_setup(self):
        result = self.run_script("verify.sh")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("FAIL  no commit-signing key", result.stdout)
        self.assertIn("FAIL  OH_SIGNING_KEYCHAIN is not set", result.stdout)
        self.assertIn("errSecInternalComponent", result.stdout)
        self.assertIn("OH_UPDATE_FEED_URL and OH_SPARKLE_PUBLIC_KEY are not set: builds are made without updates",
                      result.stdout)

    def test_verify_checks_the_update_settings_without_reading_a_key(self):
        self.env.update(OH_UPDATE_FEED_URL="http://updates.example.test/appcast.xml", OH_SPARKLE_PUBLIC_KEY="not a key",
                        OH_SPARKLE_ACCOUNT="openhuman-mail-absent-test-account")
        result = self.run_script("verify.sh", "--builds")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("FAIL  OH_UPDATE_FEED_URL 'http://updates.example.test/appcast.xml' is not an https:// address",
                      result.stdout)
        self.assertIn("FAIL  OH_SPARKLE_PUBLIC_KEY is not a base64 EdDSA public key of 32 bytes", result.stdout)
        self.assertIn("WARN  sign_update is not installed", result.stdout)
        self.assertIn("WARN  no Sparkle signing key for account 'openhuman-mail-absent-test-account'", result.stdout)
        self.env.update(OH_UPDATE_FEED_URL="https://updates.example.test/appcast.xml",
                        OH_SPARKLE_PUBLIC_KEY="11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo=")
        result = self.run_script("verify.sh", "--builds")
        self.assertIn("PASS  OH_UPDATE_FEED_URL is an https:// feed (https://updates.example.test/appcast.xml)", result.stdout)
        self.assertIn("PASS  OH_SPARKLE_PUBLIC_KEY is a 32-byte EdDSA public key", result.stdout)


if __name__ == "__main__":
    unittest.main()
