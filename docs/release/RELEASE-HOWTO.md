# Releasing OpenHuman Mail

A release starts with a clean source commit and ends with a verified DMG, its
checksum, `release-info.txt`, and reviewed notes. Building a DMG does not upload
it. A GitHub draft does not make it publicly downloadable. People without
repository access need a **published** release in a **public** repository.

Use this guide for a Developer ID signed, notarized release. `--no-icloud` is
the route without a provisioning profile; the optional iCloud route is below.
Unsigned builds remain available for development, with different first-open
requirements. Do not commit binaries, archives, OAuth clients, or credentials.

## Prerequisites

- The app requires Apple silicon and macOS 27. Build with full Xcode 27 and
  Swift 6.4 or later, including Xcode's Metal toolchain component.
- Install Git and Python 3. Install GitHub CLI (`gh`) for the later upload step.
- For signing, install your **Developer ID Application** certificate and its
  private key in the signing Mac's login Keychain. An Apple Development
  certificate is insufficient. See [Apple's Developer ID guide](https://developer.apple.com/developer-id/).
- Run app-hosted tests directly in Terminal.app on the Mac's logged-in
  desktop. An SSH/headless shell is not an equivalent app-launch environment.
- Sign in Terminal.app too, unless you have run the one-time setup in
  [Signing without prompts](LOCAL-SIGNING.md): an SSH login cannot unlock the
  login keychain. After that setup, signing and notarization also work from SSH
  logins and scripts.

`Tools/bootstrap.sh` checks Xcode/Swift, downloads checksum-verified XcodeGen,
and generates the ignored Xcode project. `Tools/versions.env` is authoritative
for the pin; currently XcodeGen is 2.46.0. No Homebrew or Mint install is needed
for XcodeGen. If Metal is missing, install it with:

```sh
xcodebuild -downloadComponent MetalToolchain
```

## Choose and preserve the source

Set the version and commit it before selecting the release commit:

```sh
Tools/release/bump-version.sh            # read the current version
Tools/release/bump-version.sh --label    # includes the early development label
```

When a new version is intended, run `Tools/release/bump-version.sh patch`,
review the change and commit it before continuing.

`Apps/Mail/Config/Version.xcconfig` holds the version and
`OH_RELEASE_CHANNEL = early-development`. Every release stays an early
development pre-release. Keep the generated notes' notice:

> Early development build — expect rough edges. Please send feedback.

Choose a build number greater than previously distributed builds; do not rely
on a fresh repository's commit count. Examples below use version `0.1.0` and
build `1003`; substitute your version/build consistently.

The release wrapper puts DerivedData, archive, logs, and outputs under its own
checkout's `build/release/`. It has no output or DerivedData path override.
For external-volume builds, put the release checkout on that volume. From an
existing clone, after committing the intended version and changes:

```sh
RELEASE_COMMIT="$(git rev-parse HEAD)"
RELEASE_VOLUME="/Volumes/Builds"
RELEASE_ROOT="$RELEASE_VOLUME/OpenHuman-release"
RELEASE_CACHE="$RELEASE_VOLUME/OpenHuman-cache"
VERSION="$(Tools/release/bump-version.sh)"
BUILD_NUMBER="1003"
df -h "$RELEASE_VOLUME" /
```

Confirm that the chosen volume is mounted and has room for Xcode output, and
keep at least 10 GB free internally. The wrapper's own preflight checks only
6 GB on the checkout's filesystem. Do not create a replacement directory under
`/Volumes` when a drive is absent. Then create a fresh checkout:

```sh
git worktree add --detach "$RELEASE_ROOT" "$RELEASE_COMMIT" &&
cd "$RELEASE_ROOT" &&
test "$(git rev-parse HEAD)" = "$RELEASE_COMMIT" &&
test -z "$(git status --porcelain)"
```

Keep this checkout at the binary's source through publication, even if `main`
later advances. Stop if a command fails. Preserve earlier release folders,
archives/dSYMs and caches; use a new build number rather than overwriting an
existing output. Only one local build/test should run at a time.

### Optional compilation cache on the build volume

Create an override containing **only** these cache settings, outside Git:

```sh
mkdir -p "$RELEASE_CACHE"
cat > "$RELEASE_CACHE/cache-only.xcconfig" <<EOF
COMPILATION_CACHE_ENABLE_CACHING = YES
COMPILATION_CACHE_CAS_PATH = "$RELEASE_CACHE/cas"
EOF
export XCODE_XCCONFIG_FILE="$RELEASE_CACHE/cache-only.xcconfig"
```

Xcode applies this file to all targets, overriding other settings. Do not put
signing, team, entitlement, version, or product-identity settings in it.
`OH_COMPILATION_CACHE_PATH` configures other CI wrappers, **not** the direct
archive in `make-dmg.sh`; exporting that variable alone does not configure this
release build. Keep the CAS cache separate from DerivedData. Unset
`XCODE_XCCONFIG_FILE` when you finish using this override.

## Validate before signing

Run in the release checkout, in the same local Terminal:

```sh
Tools/bootstrap.sh
Tools/ci/check-imports.sh
python3 -B Tools/ci/check-test-patterns.py
mkdir -p "$RELEASE_ROOT/build"
xcodebuild test -project Apps/Mail/Mail.xcodeproj -scheme Mail \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$RELEASE_ROOT/build/test-dd" \
  -resultBundlePath "$RELEASE_ROOT/build/AppTests-$(date -u +%Y%m%dT%H%M%SZ).xcresult" \
  -jobs 2 -parallel-testing-enabled NO -only-testing:MailAppTests \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  SWIFT_USE_INTEGRATED_DRIVER=YES
```

Require the test action to succeed and the complete expected suites to finish.
Keep the result bundle and investigate failures; a compiled app, an interrupted
run, or a partial log is not a passing test run. Fixture tests must not use real
mail. `test-without-building` can reuse already verified compiled products at
unchanged source and DerivedData; it is not a replacement for compiling a fresh
candidate. See [Build and test](../BUILD.md) for the package/test surfaces.

Run affected Swift package tests serially with an explicit worker limit, for
example:

```sh
swift test --package-path Packages/OpenHumanGmail \
  --scratch-path "$RELEASE_ROOT/build/package-tests/OpenHumanGmail" --jobs 2
```

The package wrapper does not forward a `--jobs` option to Swift; do not append
one to `Tools/ci/test-all.sh`. For resource-limited local runs, invoke the needed
packages directly with `--jobs 2`. The app command above limits concurrent
Xcode operations and disables parallel testing. The release archive already
uses `-jobs 2` and `SWIFT_USE_INTEGRATED_DRIVER=YES`. Native Swift `-j` values in
integrated-driver logs describe planning, not measured active worker counts.

## Signing setup

Store notarization credentials interactively in Keychain:

```sh
xcrun notarytool store-credentials openhuman-notary \
  --apple-id you@example.com --team-id YOUR_TEAM_ID
cp Tools/release/release.env.example Tools/release/release.env
```

The command prompts for the app-specific password. Never put passwords,
tokens, signing keys, or `.p8` files in Git or command arguments. Edit the ignored
`release.env` with the notary Keychain-profile name, an identity name/hash if
needed, and an optional provisioning-profile path. Names are not the stored
credentials. The wrapper checks the identity and notary profile before building;
keep the normal login Keychain available for prompts.

To sign and notarize without prompts, including from SSH logins and scripts,
run `Tools/signing/setup.sh` once in Terminal.app instead. It keeps a Developer
ID identity and the notary profile in a separate signing keychain and writes
`~/.config/openhuman/release.env`, which `make-dmg.sh` reads in every checkout.
See [Signing without prompts](LOCAL-SIGNING.md).

See [Apple's notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

## Signed build

From the clean release checkout, with the optional cache override still set:

```sh
Tools/release/make-dmg.sh --no-icloud --build-number "$BUILD_NUMBER"
```

This needs no provisioning profile. It retains Developer ID signing, hardened
runtime, secure timestamps, export, notarization and stapling. The script
serially generates the project, archives Release, exports and checks the app,
submits an app ZIP to Apple, staples the app, packages/signs the DMG, submits
the DMG to Apple, staples it and performs the final checks. These are real
Apple submissions. It does not push, tag, upload to GitHub or publish a release.

`--dry-run` prints commands and can enumerate signing identities, but proves no
real build/sign/notary result. `--sign-only` and `--allow-dirty` are rehearsals,
not distributable releases. `--from-archive` still makes a fresh archive; it
only skips export and uses that archive's app, so it is not a resume option.

### Confirm completion

Require the script to reach **Done**, not just archive/export success. Keep the
final source/version/build and `SHA-256` output. For the example above:

```sh
OUTPUT="$RELEASE_ROOT/build/release/OpenHuman-Mail-$VERSION-$BUILD_NUMBER"
DMG="$OUTPUT/OpenHuman-Mail-$VERSION.dmg"
(cd "$OUTPUT" && shasum -a 256 -c "$(basename "$DMG").sha256")
Tools/release/check-release.sh --expect-commit "$(git rev-parse --short HEAD)" "$DMG"
Tools/release/check-release.sh "$OUTPUT/release-info.txt"
```

The folder contains the DMG, its `.sha256`, `release-info.txt`, starter
`release-notes.md`, app/DMG notarization answers, `logs/`, and `.xcarchive`.
The temporary `work/` app is removed on success; keep the archive and dSYMs for
crash reports. Check both Apple answers are `Accepted`, the checksum matches
both sidecar and record, the record names the intended commit/version/build,
and it says `signing=developer-id`, `notarized=yes`, `icloud=no` for this route.
The checks cover signatures, hardened runtime, entitlements, stapled tickets,
Gatekeeper and absence of bundled OAuth clients/developer switches. A record
alone does not prove another Mac can install and launch the app.

### Smoke-check on another Mac or user account

Use an Apple silicon Mac running macOS 27. Download through a browser so the
normal quarantine/Gatekeeper path is exercised; verify the checksum, open the
DMG and drag OpenHuman Mail to Applications. Confirm first launch and rendering.
Follow the in-app Google setup guide to create/import your own **Desktop app
OAuth client JSON**, or use Settings › Accounts › Import client JSON…. No shared
Google client is bundled. Calendar consent is a separate, optional step.

Check sign-in, relaunch with the saved sign-in, recovery after refused Keychain
access, and features changed by the release. Perform real Gmail/Calendar
changes only deliberately on an account you intend to use. Keep these manual
results separate from the fixture suite. See [requirements and setup](../../README.md#build).

## iCloud entitlements

This section covers signing capabilities. It does not deploy a CloudKit schema
or establish that a synchronization feature is enabled.

A signed build carries the iCloud entitlements in
`Apps/Mail/Entitlements/Mail-iCloud.entitlements`: CloudKit with the container
`iCloud.dev.openhuman.mail`, push notifications (`production`), the `Production`
iCloud environment and the keychain group `<TEAMID>.dev.openhuman.shared` that the
Mac and iPhone apps share. A Developer ID app may use them only with a
Developer ID provisioning profile that grants them. macOS checks that profile
when the app is installed and at every launch, and an app whose profile is
missing, expired or does not match does not open.

Set up once in the Apple Developer portal (Certificates, Identifiers & Profiles):

1. Register the iCloud container `iCloud.dev.openhuman.mail`.
2. Register the explicit App ID `dev.openhuman.mail` with iCloud (CloudKit, using
   that container) and Push Notifications.
3. Create a Developer ID provisioning profile for that App ID with your Developer
   ID Application certificate, and download it.
4. Keep the file outside the repository and set its path in
   `Tools/release/release.env`:

   ```sh
   : "${OH_PROVISIONING_PROFILE:=$HOME/Documents/OpenHuman_Mail_Developer_ID.provisionprofile}"
   ```

Before it builds anything, `make-dmg.sh` decodes the profile with
`security cms -D -i` and checks that it is a macOS Developer ID profile (it lists
no devices) for your team and App ID, that it has not expired, that it lists the
certificate you sign with, and that it grants every entitlement in
`Mail-iCloud.entitlements` once `$(AppIdentifierPrefix)`, `$(DEVELOPMENT_TEAM)`
and `$(PRODUCT_BUNDLE_IDENTIFIER)` are filled in. It stops and names each
mismatch otherwise. After Xcode exports the app, the script copies the profile to
`Contents/embedded.provisionprofile` and signs the app again with those
entitlements, the hardened runtime and a secure timestamp.

`check-release.sh` fails an app signed with any entitlement that needs a
provisioning profile when the embedded profile is missing or does not grant it,
an app with an entitlement outside its allowed list, nested code that carries
one, an unsigned build that carries one, and an app whose `OHKeychainAccessGroup`
in `Info.plist` is not a keychain group its signature grants.
`make-dmg.sh` passes it `--icloud`, so a signed build that lost these
entitlements fails too.

`make-dmg.sh --no-icloud` signs and notarizes without these entitlements and
without a profile. Unsigned builds never carry them, and Xcode, CI and contributor
builds use the empty `Mail.entitlements` (see [Entitlements](../BUILD.md#entitlements)).
Open the first build signed with a new profile on another Mac before handing it
out: only macOS can tell whether it accepts the profile at launch.

## Upload and publish the verified artifact

Finish the notes' changes, requirements, Google-client setup and limitations,
preserving the early-development notice. `--notes` can select a reviewed file
instead of the generated `release-notes.md` beside the DMG; it does not replace
that generated file on disk.

Run the publisher from a clean checkout at the **binary's source commit**.
It requires the record's commit to equal checkout `HEAD`, checks a local
`v<version>` tag if present, and creates a missing release/tag with `--target`
set to full `HEAD`. The helper has no `--target` override. If only documentation
has merged since the binary was built, keep/use the clean release checkout at
that older binary commit, or rebuild at the newer commit. Never change the
binary's record/stamp or move a release tag to disguise a different source.
Verify any existing remote version tag also names the binary commit.

### Hosted CI and unsigned-workflow collision

Before creating a signed release tag/draft, disable **only** the separate
`release-unsigned.yml` workflow when Actions is enabled, and verify its state.
That workflow listens on `v*` tags and builds an unsigned DMG. Its publisher
can update an existing draft and uses `--clobber` with the same DMG, checksum
and record asset names, so it can replace a signed draft's assets. Do not rely
on whether a particular tag-creation method triggers it. Keep it disabled for
this signed release; leave `ci.yml` enabled for validation.

```sh
gh workflow disable release-unsigned.yml --repo owner/repo
gh api repos/owner/repo/actions/workflows/release-unsigned.yml --jq .state
```

Require `disabled_manually` before uploading signed assets. This is a
repository workflow setting change, separate from building or signing. See
[GitHub's workflow controls](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/disable-and-enable-workflows).

If `main` has advanced beyond the artifact source, use a dedicated release
candidate branch fixed at the binary commit and protect it from changes during
validation. After intentionally creating/pushing that ref, dispatch the CI
workflow at it (use the same repository as your `origin`):

```sh
git push origin "${RELEASE_COMMIT}:refs/heads/release-candidate/$VERSION"
gh workflow run ci.yml --ref "release-candidate/$VERSION" --repo owner/repo
gh run list --workflow ci.yml --branch "release-candidate/$VERSION" \
  --repo owner/repo --json databaseId,headSha,status,conclusion
```

`ci.yml` has `workflow_dispatch` and uses the dispatched ref; there is no
checkout-SHA input. Its automatic push trigger covers `main`, so pushing the
candidate branch alone is not enough. Confirm the resulting run's `headSha`
is the exact binary commit and its conclusion is success. CI does its normal
hosted build/tests and creates a development ZIP; it does not rebuild or replace
the notarized DMG. Do not dispatch the unsigned-release workflow for this check.

### Create a draft, then publish it

After artifact checks, manual smoke checks and notes review, authenticate the
maintainer's `gh` login and explicitly supply the existing signed artifact:

```sh
Tools/release/publish-github.sh --repo owner/repo \
  --dmg "$DMG" --notes "$OUTPUT/release-notes.md" "$VERSION"
```

Outside GitHub Actions the publisher runs only in a terminal: it lists what it
will send and continues after you type the tag. This is the release's one manual
step ([Signing without prompts](LOCAL-SIGNING.md#where-the-line-is)).

**Always pass `--dmg` to reuse a signed build.** Without it the publisher builds
a new unsigned DMG. It checks the clean source/version/channel, tag consistency,
record and checksum, then uploads the DMG, checksum and `release-info.txt` as a
**draft pre-release**. Creating a draft can create a tag and uploads assets;
it is an external action, not a local preview. Review its actual asset names,
source target, notes and checksums. `--dry-run` prints proposed commands but is
not publication or proof that remote settings/assets are correct.

Publish the reviewed draft in GitHub's UI, or intentionally repeat the command
with `--publish`. Building, uploading a draft, publishing, and changing source
visibility are separate actions. Keep the unsigned workflow disabled throughout.

A draft is not a public download page. A published release in a private
repository still requires repository access. For a download link that
works without signing in, the repository must be public and the release must
be published with its assets. Verify the release page, DMG and checksum from a
signed-out browser before sending people to
[Releases](https://github.com/michaelmagan/OpenHuman/releases).
See [GitHub's release access documentation](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases).

The app's Check for Updates… reads published releases from GitHub's public API.
It ignores drafts, compares version/build, and opens the release page in a
browser; it does not download or install updates. A private or unpublished
release is not an anonymous update/download channel.

## Unsigned development builds

```sh
Tools/release/make-dmg.sh --unsigned --build-number "$BUILD_NUMBER"
```

These use ad-hoc signing and are not notarized. macOS may block first open;
the generated notes explain the System Settings › Privacy & Security › Open
Anyway route. Keep that explanation when sharing an unsigned development build.
`--unsigned` never carries iCloud entitlements. CI's ad-hoc signed ZIP is also a
development artifact. The separate unsigned-release workflow intentionally
builds/uploads an unsigned draft; do not enable it for the signed flow above.

## Homebrew

Start with a tap named `homebrew-openhuman`. Generate its
`Casks/openhuman-mail.rb` from the final signed DMG:

```sh
python3 Tools/release/make-cask.py --repository michaelmagan/OpenHuman \
  --version "$VERSION" \
  --dmg "$DMG" \
  --output /path/to/homebrew-openhuman/Casks/openhuman-mail.rb
```

The generator accepts only a signed, notarized DMG whose `release-info.txt`
marks it as an early development pre-release. It checks the DMG and that record
using `check-release.sh` and calculates the checksum. The cask's description
and caveats say it is an early development build. Commit that cask in the tap
after publishing the matching GitHub release. Test it with Homebrew's
`brew style`, `brew audit`, and an actual install before announcing:

```sh
brew install --cask michaelmagan/openhuman/openhuman-mail
```

This command becomes available after the tap and release are published. The
cask installs the app. The CLI can currently be built separately from source.
See the [Homebrew Cask Cookbook](https://docs.brew.sh/Cask-Cookbook).
