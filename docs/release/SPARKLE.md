# In-app updates

A Developer ID signed release made with `Tools/release/make-dmg.sh --enable-updates`
updates itself with [Sparkle](https://sparkle-project.org) 2.10.0: people who
install it are offered later builds and install them from inside the app. Every
other build never checks for updates. This page covers which builds update, the
one-time key setup, making and publishing an update, and testing an update on
one Mac without publishing anything.

## Which builds update

| Build | Updates |
|---|---|
| Debug and DevTools, including Xcode runs and every test run | Never: the updater is compiled out, and a Debug build does not load Sparkle at all |
| `Tools/ci/build-app.sh`, CI artifacts, `make-dmg.sh --unsigned` | Never: no feed or key in `Info.plist`, and not Developer ID signed |
| `make-dmg.sh` signed, without `--enable-updates` | Never: no feed or key in `Info.plist` |
| `make-dmg.sh --sign-only --no-icloud --enable-updates` with a feed on `127.0.0.1` | Only from this Mac, for the [staged update test](#staged-update-test-on-one-mac) |
| `make-dmg.sh --no-icloud --enable-updates` | Yes |

`SUFeedURL` and `SUPublicEDKey` in `Apps/Mail/project.yml` come from the build
settings `OH_UPDATE_FEED_URL` and `OH_SPARKLE_PUBLIC_KEY`, which
`Apps/Mail/Config/Base.xcconfig` leaves empty. Only `make-dmg.sh --enable-updates`
sets them, on its own command line. When the app launches it starts Sparkle only
if every one of these holds, and otherwise keeps it off:

- it is not running under tests, and it is a Release build;
- `SUFeedURL` is an `https://` address (or `http://127.0.0.1` or `http://localhost`,
  for the staged test) and `SUPublicEDKey` is a 32-byte EdDSA public key;
- the app's own code signature is a Developer ID Application signature.

With Sparkle running, **Check for Updates…** in the app menu, the command palette
entry and **Check Now** in Settings › General › Updates hand the check to Sparkle,
which shows its own windows for the download, the install and the relaunch. The
earlier GitHub release check stays quiet, so a click never prompts twice.
Settings shows the time of the last check and **Check for updates automatically**.
On the second launch Sparkle asks once whether to check automatically; nothing
is checked in the background before the person agrees, and then only once a day.
A check sends the app's version and nothing else: Sparkle's system profiling stays
off.

In every other build, Check for Updates… keeps the GitHub release check, which
opens the release page in a browser, and Settings shows **Updates not available
in this build** with the reason.

Sparkle installs an update only when the disk image's EdDSA signature matches
`SUPublicEDKey` and the new app is signed by the same Developer ID team, so a
changed download or a changed feed cannot install anything.

### Sparkle's XPC services are left out

Sparkle ships two XPC services for sandboxed apps: a downloader and an installer
launcher. Mail is not sandboxed, so Sparkle downloads in the app and installs
through its `Autoupdate` tool; `SUEnableDownloaderService` and
`SUEnableInstallerLauncherService` stay off. Every `make-dmg.sh` build removes
`Sparkle.framework/Versions/B/XPCServices` and signs `Autoupdate`, `Updater.app`,
the framework and the app again, inside out, before the checks and notarization.
`Tools/release/check-release.sh` fails an app that contains any `.xpc` inside
Sparkle or turns either setting on, and its entitlement rules stay as strict as
before: no helper in the release carries entitlements of its own.

## The feed address

The feed is one `appcast.xml` file at a fixed `https://` address that every
installed copy reads. Where it is hosted is not decided yet, so the address is a
single build-time value, `OH_UPDATE_FEED_URL`, never written into the code, the
tests or CI. Choose it before the first updating release: installed copies read
that address for as long as they are installed. Moving the feed later means one
release, published at the old address, whose app carries the new one.

## One-time setup

1. Install Sparkle's tools at the pinned version (checksum-verified, into the
   ignored `Tools/.bin/`):

   ```sh
   Tools/release/install-release-tools.sh
   SPARKLE_BIN="$(Tools/release/install-release-tools.sh --print-dir)"
   ```

2. Make the signing key on the Mac that publishes releases, in Terminal.app:

   ```sh
   "$SPARKLE_BIN/generate_keys" --account openhuman-mail
   ```

   It keeps the private key in your login keychain and prints the public key.
   `generate_keys --account openhuman-mail -p` prints it again. Keep a backup of
   the private key offline (`generate_keys --account openhuman-mail -x <file>`,
   then move that file to offline storage). Without the private key no installed
   copy can be updated again.

3. Put both values in `Tools/release/release.env` (ignored by git) or
   `~/.config/openhuman/release.env`, in the form that keeps a value already set
   in the environment (see `Tools/release/release.env.example`):

   ```sh
   : "${OH_UPDATE_FEED_URL:=https://<feed host>/appcast.xml}"
   : "${OH_SPARKLE_PUBLIC_KEY:=<the public key generate_keys printed>}"
   ```

4. Check them: `Tools/signing/verify.sh --builds` reports whether the address and
   key are well formed, `sign_update` is installed and a signing key for the
   account is in your keychains. It never reads the key itself.

## Make an updating release

Follow [the release guide](RELEASE-HOWTO.md) with one change to the build
command:

```sh
Tools/release/make-dmg.sh --no-icloud --enable-updates --build-number "$BUILD_NUMBER"
```

`make-dmg.sh` refuses `--enable-updates` with `--unsigned`, without `--no-icloud`,
or without both settings, before it builds anything. It builds the feed address
and public key into the app, runs `check-release.sh --updates <feed>
--update-key <key>` on the app and the disk image, and records `updates=yes` and
`update_feed=` in `release-info.txt`. A build without `--enable-updates` is checked
with `--updates off`.

Sparkle offers an update only when its build number is higher than the running
app's, so every updating release needs a build number above every build already
in the feed.

### Every update keeps the first build's entitlements

An update replaces the app in place, so it must keep the entitlements of the build
that was first installed: a change would move or cut off what the installed app
can reach, such as its keychain items. Updating builds are made with `--no-icloud`,
like the current previews, and `make-dmg.sh` refuses `--enable-updates` without
it; `check-release.sh` fails an updating app signed with iCloud entitlements.
Offering iCloud to people on the update channel later is a separate, deliberate
change, not a flag on one release.

## Add a release to the feed

After the disk image is checked and published at its final `https://` address,
add it to the feed, in Terminal.app so `sign_update` can read your keychain:

```sh
Tools/release/update-appcast.py --dmg "$DMG" --version "$VERSION" --build "$BUILD_NUMBER" \
  --notes-file "$OUTPUT/release-notes.md" \
  --download-url-prefix https://<where the disk image is published>/ \
  --appcast <your copy of the feed>/appcast.xml
```

The tool:

1. checks every input, and that the app in the disk image has this version and
   build number and the same `SUFeedURL` and `SUPublicEDKey`;
2. measures the disk image (size and SHA-256) and signs it with
   `sign_update --account openhuman-mail` (`OH_SPARKLE_ACCOUNT` changes the
   account; `--ed-key-file <file>`, or `--ed-key-file -` with the key on standard
   input, reads it from elsewhere). The private key is never printed;
3. measures the disk image again and stops if it changed while it was signed;
4. checks the signature against `OH_SPARKLE_PUBLIC_KEY` with
   `Tools/release/verify-update-signature.swift`, so a key that does not match the
   installed copies is caught before anything is offered;
5. writes the feed with this release at the top: `sparkle:version` is the build
   number, `sparkle:shortVersionString` the version, `sparkle:minimumSystemVersion`
   26.0, and the enclosure carries the length and `sparkle:edSignature`. Older
   releases stay below it. A build number that is not above every one in the feed
   is refused, and the same version again replaces its entry.

Publish the feed only after the disk image is reachable at the address in it.

## Staged update test on one Mac

This tests an update end to end with two local builds. Nothing is published:
the feed and the disk image are served from `127.0.0.1`.

1. Optionally make a separate key for tests, so the release key is never used:

   ```sh
   "$SPARKLE_BIN/generate_keys" --account openhuman-mail-staged
   export OH_SPARKLE_ACCOUNT=openhuman-mail-staged
   export OH_SPARKLE_PUBLIC_KEY="$("$SPARKLE_BIN/generate_keys" --account openhuman-mail-staged -p)"
   export OH_UPDATE_FEED_URL=http://127.0.0.1:8000/appcast.xml
   ```

2. Build the older and the newer copy. A feed on this Mac is accepted only with
   `--sign-only`: both builds are Developer ID signed and not notarized, and are
   never handed out (`check-release.sh` warns about them).

   ```sh
   Tools/release/make-dmg.sh --sign-only --no-icloud --enable-updates --build-number 9001
   Tools/release/make-dmg.sh --sign-only --no-icloud --enable-updates --build-number 9002
   ```

3. Write the staged feed for the newer build and serve it:

   ```sh
   VERSION="$(Tools/release/bump-version.sh)"
   NEWER="build/release/OpenHuman-Mail-$VERSION-9002-signed-only"
   mkdir -p build/updates-staged
   Tools/release/update-appcast.py --staged http://127.0.0.1:8000/ \
     --dmg "$NEWER/OpenHuman-Mail-$VERSION.dmg" --version "$VERSION" --build 9002 \
     --notes-file "$NEWER/release-notes.md" --appcast build/updates-staged/appcast.xml
   cp "$NEWER/OpenHuman-Mail-$VERSION.dmg" build/updates-staged/
   python3 -m http.server 8000 --bind 127.0.0.1 --directory build/updates-staged
   ```

4. Install the older build from
   `build/release/OpenHuman-Mail-$VERSION-9001-signed-only/` into a test folder such
   as `~/Applications`, open it and choose **Check for Updates…**. Sparkle offers
   build 9002, installs it and relaunches; About and Settings › General › Updates
   then show build 9002 and the time of the check.
5. Check the refusals too: append a byte to the served disk image and check
   again (Sparkle refuses the update), then stop the server and check again
   (Sparkle says it cannot reach the feed).
6. Stop the server and delete the test app, `build/updates-staged` and the two
   `-signed-only` folders.

## Rotating the key

If the private key leaks, make a new pair, set the new public key in
`OH_SPARKLE_PUBLIC_KEY` and release. Installed copies still trust only the old
key and refuse that release, so people install it by hand once; later releases
update again. The same holds if the private key is lost.

## Decision: Sparkle as a dependency

- **Need.** People who install a preview should get later builds without
  downloading each one by hand. The earlier check only opens the release page.
- **Choice.** Sparkle 2.10.0, the standard updater for Mac apps distributed
  outside the App Store: EdDSA-signed updates, a Developer ID team check, an
  installer for apps that are not sandboxed, and accessible native windows. It is
  open source under the MIT license.
- **Not chosen.** Writing an updater (signature checks, atomic replacement and
  relaunch are easy to get wrong), and the Mac App Store (Mail is not sandboxed).
- **How it is pinned.** The Swift package is pinned in `Apps/Mail/project.yml` to
  the commit of the 2.10.0 tag (`SPARKLE_REVISION` in `Tools/versions.env`), and
  SwiftPM checks the checksum of the binary framework that commit names. The
  command-line tools come from the 2.10.0 release archive, whose SHA-256 is
  `SPARKLE_SHA256` in `Tools/versions.env`. Change all three together.
- **Limits.** Only the app links Sparkle; no package depends on it. Sparkle runs
  only in updating builds, and its XPC services never ship.
