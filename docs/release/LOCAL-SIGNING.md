# Signing without prompts

After a one-time setup, signed commits and Developer ID signed, notarized builds
work from any shell on the signing Mac: Terminal, an SSH login, a script or an
AI coding tool. Nothing asks for a passphrase or shows a keychain dialog. One
step stays deliberately manual: putting a build on GitHub.

## Where the line is

| Runs without prompts, from any shell | Manual, done by you |
| --- | --- |
| Signed commits (every commit; unsigned ones are not pushed) | `Tools/release/publish-github.sh`: creating or updating a release or draft, creating its tag, uploading the DMG |
| `Tools/release/make-dmg.sh`: archive, Developer ID signing, notarization, stapling, checks | Publishing a draft, changing repository visibility or Actions settings, Homebrew tap commits |
| `Tools/signing/verify.sh`, `Tools/release/check-release.sh` | Anything in the Apple Developer or App Store Connect accounts: certificates, profiles, API keys |

Everything on the left leaves files on this Mac. Notarization sends the build
to Apple's notary service, which does not publish it. Everything on the right
is visible to other people or changes an account.

Outside GitHub Actions, `publish-github.sh` refuses to run without a terminal.
It lists the repository, tag, target commit and files, and continues only after
you type the tag (for example `v0.1.0`). This guards against accidental uploads
by scripts and tools. It is not a security boundary: anything running as you
with your GitHub credentials can call `gh` directly. Repository rulesets that
restrict who may create `v*` tags are the stronger control.

Releases made by GitHub Actions do not use this setup: `release.yml` builds a
keychain for each run from repository secrets and deletes it afterwards
([In-app updates and automated releases](SPARKLE.md#3-secrets-and-settings)).

## One-time setup

At the Mac, in Terminal.app (not over SSH), from a checkout:

```sh
Tools/signing/setup.sh
```

It explains each change and asks before making it. Steps already done are
skipped, so it is safe to run again; `--dry-run` shows what it would change.
You are asked for:

- a passphrase for the new commit-signing key (optional; typed once),
- permission for `gh` to add the public key to your GitHub account as a signing
  key (a browser sign-in if `gh` lacks the scope),
- a `.p12` of the Developer ID Application identity that builds should use, and
  its export password (see [build signing](#build-signing)),
- notarization credentials: an App Store Connect API key, or an Apple ID with an
  app-specific password.

Then check from any shell, including an SSH login:

```sh
Tools/signing/verify.sh
```

It makes a signed commit in a temporary repository, checks that an unsigned
commit of yours cannot be pushed, signs a copy of `/usr/bin/true` with the
hardened runtime and a secure timestamp, and asks `notarytool` for the profile's
submission history. It submits nothing and changes nothing.

## Commit signing

The setup creates a new ed25519 key used only for signing commits and installs:

- `~/.local/share/git-signing/signing_ed25519`: the key. Its optional passphrase
  is saved in your login keychain with `ssh-add --apple-use-keychain`. The key is
  not in `~/.ssh`, and it is not an authentication key anywhere.
- launchd job `local.git-signing`: starts at login, runs an `ssh-agent` on the
  fixed socket `~/.local/share/git-signing/agent.sock`, loads only this key, and
  restarts if it stops. Your other SSH keys and macOS's own `ssh-agent` are not
  involved.
- git settings in your global config: `gpg.format=ssh`, `commit.gpgsign=true`,
  `user.signingkey=key::<public key>`, `gpg.ssh.allowedSignersFile`, and
  `gpg.ssh.program` set to a small helper. Previous values are saved in
  `~/.local/share/git-signing/previous-git-config`.
- two config-based git hooks (`hook.<name>.command`; the setup checks that your
  git has them): a warning after any commit without a good signature, and a
  `pre-push` check that refuses commits you made without one since the setup.
- the public key on your GitHub account as a **Signing Key**.

macOS may announce the launchd jobs as new background items. Keep them allowed
in System Settings > General > Login Items & Extensions, or they do not start.

How a shell finds the key: git runs `ssh-keygen -Y sign`, which takes the agent
from the `SSH_AUTH_SOCK` environment variable. `IdentityAgent` in
`~/.ssh/config` does not help: `ssh_config` is configuration for `ssh(1)`.
Exporting `SSH_AUTH_SOCK` in shell profiles misses non-interactive shells and
would offer the key to SSH servers. The helper sets `SSH_AUTH_SOCK` for
`ssh-keygen` only, so every shell finds the socket without any environment.
With a `key::` signing key, git documents that "the private key needs to be
available via ssh-agent"; signing never waits for a passphrase.

Failures are loud. When the key service is missing or does not hold the key,
the helper prints what to do and exits, and git stops with
`fatal: failed to write commit object`; no unsigned commit is made. A commit made
with `--no-gpg-sign` or `-c commit.gpgsign=false` triggers the warning, and
`git push` refuses it until it is re-signed. `git push --no-verify` skips the
check deliberately. To turn the check off in one repository:
`git config hook.signed-push-guard.enabled false`.

GitHub shows **Verified** when the signing key is on your account as a Signing
Key and the committer email is a verified address of that account.

### What a leak would mean

- The key can only make signatures. It cannot log in to servers or push. With
  it, someone could make commits that GitHub shows as Verified for you, until
  you remove the key from your account.
- Anything running as you can ask the key service to sign while you are logged
  in. `ssh-agent(1)` says the socket "is accessible only to the current user, but
  is easily abused by root or another instance of the same user". This is the
  price of signing without prompts.
- The passphrase protects the key file in copies of your disk and from processes
  that cannot use your login keychain, such as SSH logins. It does not protect it
  from a process in your desktop session, which can use the keychain as `ssh-add`
  does.

Loading your existing login key into a long-running agent instead would expose a
key that also opens servers and pushes over SSH, and replacing it would mean
updating every place that trusts it. A separate signing key keeps that key out
of reach of anything that only needs to sign commits.

## Build signing

Apple's guidance on `errSecInternalComponent` is explicit: "Logging in via SSH
does not unlock the keychain"
([Apple Developer Forums](https://developer.apple.com/forums/thread/712005)).
An unlock in one SSH login does not carry over to the next
([thread](https://developer.apple.com/forums/thread/768354)). The login keychain's
password is your account password, so storing it to unlock that keychain
automatically is not acceptable. The setup therefore creates a separate keychain
for signing, the same pattern hosted CI uses
([GitHub Docs](https://docs.github.com/en/actions/use-cases-and-examples/deploying/installing-an-apple-certificate-on-macos-runners-for-xcode-development)):

- `~/Library/Keychains/openhuman-signing.keychain-db` with a random password
  kept in `~/.config/openhuman/signing-keychain.password` (mode 600). It never
  locks on its own (`security set-keychain-settings` without options), is added
  to the end of your keychain search list so Xcode finds the identity, and a
  launchd job (`dev.openhuman.signing-keychain`) unlocks it at login so apps never
  ask for its password.
- the identity, imported with `security import -x -T /usr/bin/codesign`: the
  private key cannot be exported again, and only `codesign` may use it without a
  dialog. `security set-key-partition-list -S apple-tool:,apple:` allows Apple's
  tools; `security(1)`: to run codesign with the key, "apple:" must be an element
  of the partition list.
- the public Developer ID intermediate certificates, copied from your keychain
  search list, so the certificate chain also builds in SSH logins.
- a `notarytool` profile stored in that keychain
  (`xcrun notarytool store-credentials --keychain`). Profiles cannot be copied
  between keychains, so the setup asks for the credentials once more.
- `~/.config/openhuman/release.env`, which `make-dmg.sh` reads in every
  checkout: `OH_SIGNING_KEYCHAIN`, `OH_SIGNING_KEYCHAIN_PASSWORD_FILE`,
  `OH_SIGN_IDENTITY` and `OH_NOTARY_PROFILE`.

With `OH_SIGNING_KEYCHAIN` set, `make-dmg.sh` unlocks that keychain first,
looks for the identity only there, passes `--keychain` to `codesign` (directly
and through `OTHER_CODE_SIGN_FLAGS`) and to `notarytool`, and names the identity
to Xcode by its SHA-1 hash. Setting `OH_SIGNING_KEYCHAIN=` (empty) for one run
signs from the login keychain as before. Every signed build also runs
`caffeinate -i -s` while it lasts, because idle sleep drops the network during
notarization waits; `-s` applies only on AC power.

Secure timestamps need the network: `codesign(1)` says the signature fails if
"the timestamp authority service cannot be contacted".

### Use a separate certificate for automation

Apple allows up to five Developer ID Application certificates; the Account
Holder creates them. A revoked certificate is final for what it signed: "Any
Developer ID app signed with a certificate that has been revoked can no longer
be installed nor launch if it's already installed"
([Apple](https://developer.apple.com/support/developer-id/)), and revocation goes
through Apple Product Security
([thread](https://developer.apple.com/forums/thread/712395)). Give the signing
keychain its own certificate, so that revoking it after a leak only affects
builds signed with it:

1. Xcode > Settings > Accounts > your team > Manage Certificates > + >
   Developer ID Application.
2. Keychain Access > login > My Certificates: select the new certificate,
   File > Export Items, save a `.p12` with a temporary password.
3. Give that file to the setup. It offers to remove the identity from the login
   keychain afterwards: Xcode's export step searches every keychain, and an SSH
   login cannot use the login keychain's copy.

To sign a public release with your main certificate instead, run the build in
Terminal.app with `OH_SIGNING_KEYCHAIN= OH_SIGN_IDENTITY=<its SHA-1>`. If you
build with iCloud entitlements, add the new certificate to your Developer ID
provisioning profile and download the profile again.

### What a leak would mean

Anything running as you can read the password file, unlock the keychain, sign
code as your team and submit it for notarization while it runs on this Mac. It
cannot copy the private key elsewhere: the key is non-extractable. Removing the
password file stops unattended signing at once.

## Rotate or revoke

Commit key, routine (for example yearly): run
`Tools/signing/setup.sh --rotate-commit-key`. The old key gets
`valid-before=<now>` in the allowed-signers file, so older signatures still
verify locally; a new key is made, loaded and added to GitHub, and the setup
offers to remove the old key from GitHub. GitHub keeps commits it has already
verified as Verified when a key is rotated or revoked
([GitHub Docs](https://docs.github.com/en/authentication/managing-commit-signature-verification/about-commit-signature-verification)).

Commit key, leaked: run `Tools/signing/setup.sh --rotate-commit-key --compromised`
and let it remove the old key from GitHub (or remove it at
<https://github.com/settings/keys>). The old key also goes into
`gpg.ssh.revocationFile`, so git treats every signature it made as invalid.
Check recent commits on your repositories for ones you did not make.

Build signing, leaked or Mac lost:

1. Revoke the notarization credential: an app-specific password at
   account.apple.com > Sign-In and Security > App-Specific Passwords
   ([Apple](https://support.apple.com/en-us/102654)), or the API key in
   App Store Connect ("An API key can't be reinstated once revoked",
   [Apple](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api/)).
2. Ask Apple Product Security to revoke the automation certificate.
3. On the Mac: `security delete-keychain ~/Library/Keychains/openhuman-signing.keychain-db`,
   delete the password file, create a new certificate, and run
   `Tools/signing/setup.sh --builds`.

Undo the whole setup:

```sh
launchctl bootout "gui/$(id -u)/local.git-signing"
launchctl bootout "gui/$(id -u)/dev.openhuman.signing-keychain"
rm ~/Library/LaunchAgents/local.git-signing.plist ~/Library/LaunchAgents/dev.openhuman.signing-keychain.plist
git config --global --remove-section hook.signed-commit-warning
git config --global --remove-section hook.signed-push-guard
cat ~/.local/share/git-signing/previous-git-config   # restore these values with git config --global
security delete-keychain ~/Library/Keychains/openhuman-signing.keychain-db
rm -r ~/.local/share/git-signing ~/.config/openhuman/signing-keychain.password ~/.config/openhuman/release.env
```

## When something fails

| What you see | Cause | Fix |
| --- | --- | --- |
| `git-signing: the commit-signing key service is not running`, then `fatal: failed to write commit object` | Nobody has logged in to the Mac's desktop since it started, or the launchd job is not loaded | Log in at the Mac, or `launchctl kickstart -k gui/$(id -u)/local.git-signing`; check that it is allowed under Login Items & Extensions |
| `git-signing: the signing key is not loaded` | The key's passphrase is not in the login keychain, or the keychain was locked at login | Read `~/.local/share/git-signing/service.log`; run `Tools/signing/setup.sh --commits` in Terminal |
| `git-signing: cannot connect to .../agent.sock` | A command sandbox blocks Unix sockets | Allow that socket path (in Claude Code: `sandbox.network.allowUnixSockets`) or run git outside the sandbox |
| `No user exists for uid 501` from `ssh-keygen` | The process cannot look up your user account; seen inside some command sandboxes, where `id -un` prints a number | Run the commit outside that sandbox |
| `git-signing: WARNING: commit ... has no good signature` | The commit was made with `--no-gpg-sign` or `commit.gpgsign=false` | `git commit --amend --no-edit -S` |
| `git-signing: refusing to push commits you made without a good signature` | As above, for one or more commits | Re-sign: `git rebase --exec "git commit --amend --no-edit -S" <base>` |
| GitHub shows Unverified | The key is not on your account as a Signing Key, or the committer email is not verified there | Add the key (`gh ssh-key add --type signing`), verify the email |
| `errSecInternalComponent` or `User interaction is not allowed` from `codesign` | Signing from the login keychain in an SSH login (`OH_SIGNING_KEYCHAIN` unset or empty), a locked keychain, or a key that needs a dialog | `Tools/signing/verify.sh --builds`; `Tools/signing/setup.sh --builds` |
| An SSH build fails in the export step with a keychain error | The same identity is also in the login keychain | Let the setup remove that copy, or use `make-dmg.sh --from-archive` |
| `unable to build chain to self-signed root` | The Developer ID intermediate certificate is missing | Install Developer ID - G1 and G2 from <https://www.apple.com/certificateauthority/> |
| `codesign` fails mentioning a timestamp | Apple's timestamp service is unreachable | Check the network and retry; a build without a secure timestamp cannot be notarized |
| `notarytool cannot use the keychain profile ...` | The profile is not in the signing keychain, or its credential was revoked | `Tools/signing/setup.sh --builds` |
| Notarization stops with network errors after a long wait | The Mac slept (`caffeinate -s` holds only on AC power) | Keep the Mac on power and retry |
| `publish-github: uploading to GitHub is the manual release step` | `publish-github.sh` ran without a terminal | Expected: run it yourself in a terminal |

## AI coding tools and sandboxes

Commands these tools run are processes running as you, so the setup applies to
them unchanged, including over SSH. If a tool runs commands in a sandbox, allow
the socket `~/.local/share/git-signing/agent.sock` for commits, and run the
release commands (`make-dmg.sh`, `codesign`, `notarytool`) outside the sandbox,
for example with Claude Code's `sandbox.excludedCommands`. Instruct tools to
stop and report when signing fails, never to retry with `--no-gpg-sign`,
`-c commit.gpgsign=false` or `--no-verify`.
