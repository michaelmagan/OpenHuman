#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

usage() {
    cat <<'EOF'
Usage: Tools/ci/build-app.sh [options]

Builds the Mail app. Runs Tools/bootstrap.sh first, which installs the pinned
XcodeGen and generates the Xcode project.

  --configuration <Debug|DevTools|Release>
                                   default Release. DevTools is optimised like Release and adds the
                                   developer tools: the Developer menu, the test checklist, Developer
                                   options and the sample-data launch arguments. Release has none of them
  --derived-data <dir>             default <repo>/build/dd (ignored by git)
  --arch <arm64|universal>         default arm64: the app runs only on Apple silicon. universal adds
                                   x86_64 and roughly doubles the compile time of a Release build
  --build-number <n>               CURRENT_PROJECT_VERSION; default: the project's value
  --local-install                  after a Release or DevTools build, copy the app to "OpenHuman Mail.app"
                                   in the install folder (default ~/Applications, created if missing; no sudo).
                                   Override with --install-dir <dir> or OH_INSTALL_DIR. An existing copy at
                                   that path (or under the old name "Mail by OpenHuman.app") is replaced.
                                   Never touches /Applications unless you ask for it.
  --install-dir <dir>              install folder for --local-install
  -h, --help                       show this help

Signing: if Apps/Mail/Config/Local.xcconfig exists (your DEVELOPMENT_TEAM and "Apple Development"
identity), the build uses it, so rebuilt apps keep their Keychain access. Without it the build is
ad-hoc signed (CODE_SIGN_IDENTITY=-): fine for CI artifacts and sample-data runs, but macOS asks for
Keychain access again after every rebuild. No notarization, no Developer ID, no secrets.
EOF
}

CONFIG=Release; ARCH=arm64; DD="$ROOT/build/dd"; BUILD_NUMBER=""; INSTALL=0; INSTALL_DIR="${OH_INSTALL_DIR:-$HOME/Applications}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --configuration) CONFIG="$2"; shift 2 ;;
        --derived-data) DD="$2"; shift 2 ;;
        --arch) ARCH="$2"; shift 2 ;;
        --build-number) BUILD_NUMBER="$2"; shift 2 ;;
        --local-install) INSTALL=1; shift ;;
        --install-dir) INSTALL_DIR="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "build-app: unknown argument $1 (see --help)" >&2; exit 2 ;;
    esac
done
case "$CONFIG" in Debug|DevTools|Release) ;; *) echo "build-app: --configuration must be Debug, DevTools or Release" >&2; exit 2 ;; esac
case "$ARCH" in arm64|universal) ;; *) echo "build-app: --arch must be arm64 or universal" >&2; exit 2 ;; esac
[[ "$INSTALL" == 0 || "$CONFIG" != Debug ]] || { echo "build-app: --local-install needs --configuration Release or DevTools" >&2; exit 2; }

"$ROOT/Tools/bootstrap.sh"

args=(build -project "$ROOT/Apps/Mail/Mail.xcodeproj" -scheme Mail -configuration "$CONFIG"
      -destination 'generic/platform=macOS' -derivedDataPath "$DD"
      "OH_GIT_COMMIT=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)")
cache_dir="${OH_COMPILATION_CACHE_PATH:-$HOME/Library/Caches/OpenHuman/compilation-cache}"
args+=(COMPILATION_CACHE_ENABLE_CACHING=YES "COMPILATION_CACHE_CAS_PATH=$cache_dir")
[[ -z "$BUILD_NUMBER" ]] || args+=("CURRENT_PROJECT_VERSION=$BUILD_NUMBER")
[[ "$ARCH" == universal ]] || args+=(ARCHS=arm64)
if [[ ! -f "$ROOT/Apps/Mail/Config/Local.xcconfig" ]]; then
    args+=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=)
fi
xcodebuild -skipPackageUpdates "${args[@]}"

APP="$DD/Build/Products/$CONFIG/OpenHumanMail.app"
[[ -d "$APP" ]] || { echo "build-app: expected $APP after the build" >&2; exit 1; }
echo "build-app: built $APP"

if [[ "$INSTALL" == 1 ]]; then
    DEST="$INSTALL_DIR/OpenHuman Mail.app"
    mkdir -p "$INSTALL_DIR"
    rm -rf "$DEST"
    OLD="$INSTALL_DIR/Mail by OpenHuman.app"
    if [[ -d "$OLD" ]]; then rm -rf "$OLD"; echo "build-app: removed the old-named copy $OLD"; fi
    /usr/bin/ditto "$APP" "$DEST"
    codesign --verify --deep --strict "$DEST"
    echo "build-app: installed $DEST"
fi
