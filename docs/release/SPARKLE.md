# In-app updates and automated releases

OpenHuman Mail updates itself with [Sparkle](https://sparkle-project.org). A
release is built, signed and notarized in GitHub Actions, and it reaches
people only after a maintainer merges a pull request. This page covers how
that works and the one-time setup it needs.

## How it fits together

| Piece | Where |
| --- | --- |
| Sparkle 2.10.0, as a Swift package of the app | `Apps/Mail/project.yml` (`packages: Sparkle`) |
| The feed the app reads (`SUFeedURL`) | `https://raw.githubusercontent.com/michaelmagan/OpenHuman/main/appcast.xml` |
| The public key updates must be signed with (`SUPublicEDKey`) | `Apps/Mail/project.yml`, `info: properties` |
| The private key | the `SPARKLE_PRIVATE_KEY` Actions secret, and the maintainer's Keychain |
| The feed itself | `appcast.xml` at the repository root |
| Phase 1: build, sign, draft, open the appcast pull request | `.github/workflows/release.yml` |
| Phase 2: publish when that pull request merges | `.github/workflows/release-publish.yml` |
| The feed writer, release notes and pinned tools | `Tools/release/update-appcast.py`, `cliff.toml`, `appcast-body.tera`, `install-release-tools.sh` |

### In the app

The app menu's **Check for Updates…**, the command palette entry and
**Settings › General › Updates** stay where they were. What answers them depends
on the build:

- A **Release** build whose `Info.plist` has a feed URL and a 32-byte EdDSA public
  key starts Sparkle. Sparkle then owns the check, the download, the signature
  check, the install and the relaunch, with its own windows. Settings shows
  **Check Now**, the time of the last check, and **Check for updates
  automatically**. On the second launch Sparkle asks once whether to check
  automatically; nothing is checked in the background before the person agrees.
  Automatic checks run once a day. A check sends the app's version in the
  request and nothing else: Sparkle's system profiling stays off.
- **Debug** and **DevTools** builds, test runs, and any build without a public key
  keep the earlier GitHub check (`UpdateCheckCenter` asking GitHub's releases API
  when someone clicks, then opening the release page). Tests never start Sparkle
  and never reach the network: `UpdateCheckSupport` returns no updater when
  `XCTestConfigurationFilePath` is set, as the GitHub check already did.

Sparkle installs an update only when its EdDSA signature matches
`SUPublicEDKey`, and, because the app is Developer ID signed, only when the new
app is signed by the same team. A changed DMG on GitHub's CDN or a hijacked feed
cannot install anything.

### Why the feed is on raw.githubusercontent.com

The appcast is a file on `main`, served by
`raw.githubusercontent.com`:

- It needs no Pages site, deploy workflow or extra hosting. Pages would add a
  deploy job and a setting to keep enabled, for one static file.
- The feed changes only through a reviewed, merged pull request, so main's
  history is the record of what was offered to whom.
- It is HTTPS, as Sparkle requires, and the DMG it points at is a GitHub release
  asset, so both halves have the same availability.
- GitHub caches raw files for about five minutes, so a merged release can take
  that long to be offered. That is fine for a daily check.

The repository must stay public: a private repository's raw files and release
assets need a login, and Sparkle has none. Moving the feed later means shipping
one release that still reads the old URL and points `SUFeedURL` at the new one.

## One-time setup

Until this is done, the app keeps the GitHub check and `release.yml` stops at its
first checks with an error naming what is missing.

### 1. Make the Sparkle key pair

On the maintainer's Mac:

```sh
Tools/release/install-release-tools.sh
SPARKLE_BIN="$(Tools/release/install-release-tools.sh --print-dir sparkle)"
"$SPARKLE_BIN/generate_keys" --account openhuman-mail
```

`generate_keys` keeps the private key in your login Keychain and prints the
public key. Export the private key for the Actions secret:

```sh
"$SPARKLE_BIN/generate_keys" --account openhuman-mail -x sparkle_private_key
```

Treat the exported file like an SSH private key. The Keychain copy is the one to
keep; delete the file once the secret is set.

### 2. Commit the public key

Paste the printed public key into `Apps/Mail/project.yml`:

```yaml
        SUPublicEDKey: "the base64 public key"
```

Commit it on a branch and merge it like any change. Every build made after that
starts Sparkle, and every copy installed from it trusts only that key. The key is
kept in `project.yml` rather than an `.xcconfig` file because `//`, which base64
can contain, starts a comment there.

### 3. Secrets and settings

In **Settings › Secrets and variables › Actions**, add these repository secrets,
or put them on the `release` environment that `release.yml` runs in (GitHub
creates the environment on the first run; add required reviewers there to
approve each release run):

| Secret | Value |
| --- | --- |
| `SPARKLE_PRIVATE_KEY` | the contents of `sparkle_private_key` from step 1 |
| `DEVELOPER_ID_P12_BASE64` | a "Developer ID Application" identity exported as `.p12`, base64-encoded (`base64 -i identity.p12`) |
| `DEVELOPER_ID_P12_PASSWORD` | the password of that `.p12` |
| `NOTARY_API_KEY_P8_BASE64` | an App Store Connect API key (`AuthKey_XXXX.p8`, role Developer), base64-encoded |
| `NOTARY_API_KEY_ID` | that key's ID |
| `NOTARY_API_ISSUER_ID` | the issuer ID shown above the keys in App Store Connect |
| `DEVELOPER_ID_PROVISIONING_PROFILE` | optional: the Developer ID provisioning profile, base64-encoded, for releases with the **icloud** option |

```sh
gh secret set SPARKLE_PRIVATE_KEY < sparkle_private_key && rm sparkle_private_key
base64 -i identity.p12 | gh secret set DEVELOPER_ID_P12_BASE64
base64 -i AuthKey_XXXX.p8 | gh secret set NOTARY_API_KEY_P8_BASE64
```

Use a separate Developer ID certificate for CI, for the reason in
[Signing without prompts](LOCAL-SIGNING.md#use-a-separate-certificate-for-automation):
revoking it after a leak affects only builds it signed. With the iCloud option,
add that certificate to the Developer ID provisioning profile.

Also, under **Settings › Actions › General**, turn on **Allow GitHub Actions to
create and approve pull requests**, so `release.yml` can open the appcast pull
request. The existing variables `MACOS_RUNNER_LABEL`, `XCODE_APP` and
`XCODE_VERSION` choose the runner and Xcode, as for CI.

Secrets reach only the `prepare` job of `release.yml`. It imports the identity
into a keychain made for that run under the runner's temporary folder, adds it to
the keychain search list only while the job runs, and deletes it and the key
files in a final step that runs even when the job fails. The self-hosted runner
also runs CI for pull requests, so keep fork pull requests from running
workflows without approval (**Settings › Actions › General › Fork pull request
workflows**).

## Making a release

1. Raise the version with `Tools/release/bump-version.sh patch` (or `minor`,
   `major`) and merge it. A version that already has a tag or a published
   release is refused.
2. Wait for CI on main to finish green on that commit, then run:

   ```sh
   gh workflow run release.yml --ref main          # add -f icloud=true for an iCloud build
   ```

   **Phase 1, `release.yml`**, on the tip of main:
   1. requires a green `ci.yml` run on the commit, checks that the Sparkle private
      key belongs to the committed `SUPublicEDKey`, and checks every secret, all
      before building;
   2. writes the release notes with git-cliff (below);
   3. runs `Tools/release/make-dmg.sh` (Developer ID signing, hardened runtime,
      notarization and stapling of the app and the DMG, `check-release.sh`);
   4. signs the DMG with `sign_update`;
   5. puts the DMG, its checksum and `release-info.txt` on a **draft**
      pre-release with `Tools/release/publish-github.sh`, aimed at that exact
      commit (no tag yet, nothing public);
   6. adds the release to `appcast.xml` and opens a `release/v<version>` pull
      request with that one change. The branch and commit are made through
      GitHub's API, so the commit is signed by GitHub.
3. Review the draft and the pull request. Edit the draft's notes (for example
   **Known limitations**) and open the DMG on another Mac
   ([smoke check](RELEASE-HOWTO.md#smoke-check-on-another-mac-or-user-account)).
   GitHub does not run workflows for a pull request opened by Actions: close and
   reopen it to run CI, then merge once green.
4. **Phase 2, `release-publish.yml`**, runs on the merge. It publishes the draft
   as a pre-release, which creates the tag at the commit the DMG was built from,
   and deletes the branch. From then on installed copies are offered the update.

The build number, which Sparkle compares, is the commit count of main, raised
when needed to one more than the last release's or appcast entry's build. 0.1.0
was build 1004 and shipped without Sparkle: people on 0.1.0 install the next
release by hand once, and get updates from then on.

To redo a release before its pull request merges, run `release.yml` again: it
replaces the draft and points the open pull request's branch at the new appcast.

### Release notes

`release.yml` runs git-cliff with `Tools/release/cliff.toml` twice over the same
commits: markdown for the GitHub release (under **Changes** in the notes
`make-dmg.sh` starts) and HTML for the appcast, through
`Tools/release/appcast-body.tera`, because Sparkle shows notes in a web view.
Conventional subjects (`feat:`, `fix:`, `perf:`, `docs:`) get their own groups,
other subjects are listed under **Changes**, and merges and `chore(release)`
commits are left out.

Both runs use one range, `--unreleased --tag v<version>`, defined once in the
step. Never `--latest`: the job runs before the tag exists, so git-cliff's latest
release is still the previous one, and `--latest` prints that release's notes,
which look plausible and are wrong. The step then checks that every commit in the
notes is in `<last tag>..HEAD` and stops otherwise.

Every value in `appcast-body.tera` goes through `escape_xml`: Tera does not
escape by default, and a `<` in a commit subject would otherwise become a tag in
Sparkle's window. `update-appcast.py` wraps the notes in CDATA, adds the early
development notice and a small style block without colors, so dark mode works.

### Where the tag goes

The tag names the commit the DMG was built from, which `release-info.txt` also
records, as [the release guide](RELEASE-HOWTO.md#upload-and-publish-the-verified-artifact)
requires. The draft is created with that full SHA as its target, and phase 2
publishes it with `--target <that SHA>`, never `--target main`: a branch name
would put the tag wherever main is when the job runs. Phase 2 first checks that
the commit is in main's history at the merge, and publishes nothing otherwise.
Because the tag never moves past the built commit, merging other pull requests
while a release pull request is open does not drop them from any notes: they fall
into the next release's range.

### If a run fails

- Before **Put the DMG on a draft pre-release**: nothing left the runner except
  Apple notarization submissions. Fix the cause and run it again.
- After it: a draft exists. Running again replaces it. To abandon the release,
  delete the draft (`gh release delete v<version>`) and close the pull request.
- If phase 2 refuses: delete the draft, revert the appcast entry that merged, and
  run `release.yml` again.

The job uploads `build/release/*/logs` as an artifact when it fails.

## Rotating the Sparkle key

If the private key leaks:

1. Make a new pair (step 1) and put the new public key in `project.yml`.
2. Replace the `SPARKLE_PRIVATE_KEY` secret.
3. Release. Installed copies still trust only the old key, so they refuse this
   release: tell people to install it by hand once. Later releases update again.

## Checking a DMG by hand

```sh
SPARKLE_BIN="$(Tools/release/install-release-tools.sh --print-dir sparkle)"
"$SPARKLE_BIN/sign_update" --account openhuman-mail --verify OpenHuman-Mail-0.2.0.dmg '<sparkle:edSignature from appcast.xml>'
```

`sign_update` reads the key from your Keychain. To check that a private key belongs to the committed public
key without signing anything:

```sh
printf '%s' "$KEY" | xcrun swift Tools/release/check-sparkle-key.swift '<SUPublicEDKey>'
```
