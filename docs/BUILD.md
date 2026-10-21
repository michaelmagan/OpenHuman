# Build and test

The application targets Apple silicon and macOS 26.0 or later. Use Xcode 27
with Swift 6.4 or later; older Swift toolchains cannot parse the package platform
declarations.
MLX compiles Metal shaders, which needs Xcode's Metal toolchain component
(`xcodebuild -downloadComponent MetalToolchain` installs it).

Each directory in `Packages/` is an independent SwiftPM package. There is no
root `Package.swift`. Local package dependencies use relative sibling paths.

```sh
xcodebuild -version
xcrun swift --version
Tools/bootstrap.sh
Tools/ci/build-app.sh
```

Bootstrap downloads the pinned, checksum-verified XcodeGen version from
`Tools/versions.env` and generates `Apps/Mail/Mail.xcodeproj`. The app links
[Sparkle](https://sparkle-project.org) for in-app updates as a Swift package
pinned in `Apps/Mail/project.yml`; Xcode fetches it with the other packages. Generated projects
and downloaded tools are ignored. Local builds use ad-hoc signing by default.
For a development team override, copy
`Apps/Mail/Config/Local.xcconfig.example` to `Local.xcconfig` and edit that local
file. Do not commit signing credentials or OAuth clients.

Open the generated project in Xcode and run the `Mail` scheme. It starts with
`-UseFakeGmail`, the fake mail backend; use `-UseFakeData` for UI fixtures. Untick
`-UseFakeGmail` to sign in to a real account: changes you make there reach Gmail.
First-launch onboarding explains Google client setup for a real account.

```sh
Tools/ci/check-imports.sh
python3 -B Tools/ci/check-test-patterns.py
Tools/ci/build-all.sh
Tools/ci/test-all.sh
xcodebuild test -skipPackageUpdates -project Apps/Mail/Mail.xcodeproj -scheme Mail \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
```

For a focused loop, run `swift test` inside the package you changed.
`Tools/ThemeCodegen/run.sh --check` verifies generated theme sources.
`Tools/render-sweep.sh --help` describes rendering the UI against fake data.
Tests must use fixtures rather than real mail accounts.
Tests make temporary folders with `TemporaryDirectory` from OpenHumanCore and remove
them when the test ends; `check-test-patterns.py` rejects other new temporary paths.
Defaults suites come from `ScopedDefaults` in OpenHumanCore, which keeps the suite's plist
in a temporary folder instead of `~/Library/Preferences` and removes it when the test ends;
`check-test-patterns.py` rejects other new `UserDefaults(suiteName:)` calls in tests.
`Tools/ci/build-packages.sh --platform ios` checks that the packages still compile
for iOS, and `Tools/ci/build-ios-app.sh` builds the iPhone app; see
[Build for iOS](IOS-BUILD.md).

CI runs these same build and test scripts on GitHub's `xcode-27` Apple silicon
runner with a released Xcode (27.0), never the newest installed beta, and installs
the Metal toolchain component when the runner lacks it (MLX compiles Metal
shaders). The repository variables `MACOS_RUNNER_LABEL`, `XCODE_APP` and
`XCODE_VERSION` can select another compatible runner or Xcode. Missing toolchains
and failed checks fail the job.

The project also generates from a source archive without Git metadata (for
example GitHub's Download ZIP); only the build's commit stamp needs Git.

Builds use Xcode's compilation cache, stored in
`~/Library/Caches/OpenHuman/compilation-cache` (override with `OH_COMPILATION_CACHE_PATH`), outside
derived data, so deleting derived data keeps it. It grows to a few GB; delete the folder to reset it.
Hits are per checkout path: another worktree does not reuse them, even with prefix mapping enabled.

Local build output is under `build/`; the app product is
`build/dd/Build/Products/Release/OpenHumanMail.app`. Release signing and binary
distribution are described in [the release guide](release/RELEASE-HOWTO.md).

## Updates

Sparkle starts only in a Release build whose `Info.plist` carries `SUFeedURL`
and a `SUPublicEDKey`, never in Debug or DevTools builds and never under tests,
so local runs and the test suites do not check for updates or reach the network.
Those builds keep the earlier GitHub check behind the same menu item and
Settings section. CI checks that the Release build embeds `Sparkle.framework`
and reads the appcast on `main`. Releases, the appcast and the signing key are
described in [In-app updates and automated releases](release/SPARKLE.md).

## Entitlements

The build setting `OH_ENTITLEMENTS` names the entitlements file Xcode signs the
app with. It defaults to `Entitlements/Mail.entitlements` (in `Apps/Mail`), which
is empty, so every build without a provisioning profile, ad-hoc signed or with a
personal team, still launches. Keep that file empty: `Tools/release/check-release.sh`
fails when it is not. Xcode's Signing & Capabilities editor writes new capabilities
into the file `OH_ENTITLEMENTS` names, so do not commit what it adds there.

`Entitlements/Mail-iCloud.entitlements` holds the iCloud, push and keychain group
entitlements. They need a provisioning profile that grants them; the signed release
adds them together with its Developer ID profile (see
[iCloud entitlements](release/RELEASE-HOWTO.md#icloud-entitlements)). A local
`Local.xcconfig` may set `OH_ENTITLEMENTS` to another file only for a build that is
signed with a matching provisioning profile.

## Build flavours

The app has three build configurations, all from the one `Mail` target:

| Configuration | Compilation conditions | What it adds |
|---|---|---|
| `Debug` | `DEBUG OH_DEV_TOOLS` | Everything below, unoptimised. Xcode runs and the tests use it. |
| `DevTools` | `OH_DEV_TOOLS` | Release optimisation plus the developer tools: the Developer menu (test checklist, feedback over Tailscale), Settings › Advanced › Developer options (including Show debugging tools), the sample-data launch arguments and the developer variables below. Same bundle id and data as Release. |
| `Release` | none | Nothing developer-only; Sparkle updates once the public key is set. This is the build `Tools/release/make-dmg.sh` ships. |

```sh
Tools/ci/build-app.sh --configuration DevTools --local-install
```

Only Debug and DevTools builds read these launch arguments and variables:

- `-UseFakeGmail`, `-UseFakeData`, `-UseFixtureStore`, `-UseFakeCalendar`,
  `-FakeGmailNotifications`: fake mail, fixtures and a sample calendar.
- `OPENHUMAN_HOME`: a separate folder for the mail store, window state and its own
  Keychain entries.
- `OPENHUMAN_OAUTH_CLIENT_JSON`: a Google client file that outranks the imported one.
- `OPENHUMAN_STORE_POLL_ONLY=1`: notice other processes' store changes by polling only.
- `OPENHUMAN_FEEDBACK_DIR` (DevTools and Debug): where developer feedback is saved.

None of them changes whether Mail writes to Gmail. `Tools/release/check-release.sh`
fails an app that contains any of these names, so a Release build that still
carries one never ships. The command-line tool reads `OPENHUMAN_HOME` for its
default `--home` in every build.
