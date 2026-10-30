#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APPLE_ONLY="OpenHumanMailUI OpenHumanAIMLX OpenHumanCloudSync OpenHumanMailLive"
# Why: AppKit-only views, and subprocess-based assistants (Process does not exist on iOS)
IOS_SKIP="MailUIMac OpenHumanAIAgentCLI"

usage() {
    cat <<'EOF'
Usage: Tools/ci/build-packages.sh [--platform macos|linux|ios] [--build-only | --test-only]
                                   [--exclude Package] [--serialized-tests] [Package ...]

Builds and tests every package in Packages/, or only the packages named.

  --platform <macos|linux|ios>  default: the host. On linux the Apple-only packages are skipped;
                                the product targets macOS, so a linux run is a convenience only.
                                ios compiles each library product for the iOS Simulator with
                                xcodebuild and runs no tests. It skips packages that do not declare
                                iOS, executables, and the macOS-only products MailUIMac and
                                OpenHumanAIAgentCLI.
  --build-only                  build the packages and their tests, run nothing
  --test-only                   run the tests (swift test still builds first)
  --exclude <Package>           omit a package; may be repeated
  --serialized-tests            run tests without parallel execution
  -h, --help                    show this help

OH_SCRATCH_ROOT=<dir>  build each package in <dir>/<Package> (swift --scratch-path) instead of its
                       .build folder, so the cache can live outside the checkout between runs.
                       With --platform ios, derived data goes to <dir>/ios-dd/<Package>
                       (default build/ios-dd/<Package>).
OH_COMPILATION_CACHE_PATH=<dir>  compilation cache for --platform ios
                       (default ~/Library/Caches/OpenHuman/compilation-cache).
OH_TEST_LOG_DIR=<dir>   keep package test logs in this directory for CI diagnostics.
EOF
}

platform=""; mode="all"; selected=(); excluded=(); serialized_tests=0
while (( $# )); do
    case "$1" in
        --platform) platform="$2"; shift 2 ;;
        --build-only) mode="build"; shift ;;
        --test-only) mode="test"; shift ;;
        --exclude) excluded+=("$2"); shift 2 ;;
        --serialized-tests) serialized_tests=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) selected+=("$1"); shift ;;
    esac
done
if [[ -z "$platform" ]]; then
    [[ "$(uname -s)" == "Darwin" ]] && platform="macos" || platform="linux"
fi
[[ "$platform" == "macos" || "$platform" == "linux" || "$platform" == "ios" ]] || { echo "unknown platform: $platform" >&2; exit 2; }
[[ "$platform" != "ios" || "$mode" != "test" ]] || { echo "--test-only is not available with --platform ios: the iOS lane only compiles" >&2; exit 2; }

ios_library_products() {
    (cd "$1" && swift package --scratch-path "$2" dump-package) | python3 -c '
import json, sys
manifest = json.load(sys.stdin)
if any(p["platformName"] == "ios" for p in manifest.get("platforms") or []):
    for product in manifest["products"]:
        if "library" in product["type"]:
            print(product["name"])
'
}

build_ios() {
    local sdk
    if ! sdk="$(xcrun --sdk iphonesimulator --show-sdk-path 2>/dev/null)"; then
        echo "The iOS Simulator SDK is not installed. Install it with: xcodebuild -downloadPlatform iOS" >&2
        exit 1
    fi
    echo "iOS Simulator SDK: $sdk"
    local cache_dir="${OH_COMPILATION_CACHE_PATH:-$HOME/Library/Caches/OpenHuman/compilation-cache}"
    local dd_root="${OH_SCRATCH_ROOT:-$ROOT/build}/ios-dd"
    local manifest dir pkg scratch products product
    for manifest in "$ROOT"/Packages/*/Package.swift; do
        dir="$(dirname "$manifest")"; pkg="$(basename "$dir")"
        if (( ${#selected[@]} )) && [[ " ${selected[*]} " != *" $pkg "* ]]; then continue; fi
        if (( ${#excluded[@]} )) && [[ " ${excluded[*]} " == *" $pkg "* ]]; then continue; fi
        scratch="$dir/.build"
        [[ -z "${OH_SCRATCH_ROOT:-}" ]] || scratch="$OH_SCRATCH_ROOT/$pkg"
        products="$(ios_library_products "$dir" "$scratch")" || { failed+=("$pkg"); continue; }
        if [[ -z "$products" ]]; then
            echo "== $pkg: skipped on ios (does not declare iOS)"; continue
        fi
        for product in $products; do
            if [[ " $IOS_SKIP " == *" $product "* ]]; then
                echo "== $pkg/$product: skipped on ios (macOS only)"; continue
            fi
            echo "== $pkg/$product (build, ios)"
            (cd "$dir" && xcodebuild build -quiet -skipPackageUpdates -scheme "$product" \
                -destination 'generic/platform=iOS Simulator' -derivedDataPath "$dd_root/$pkg" \
                COMPILATION_CACHE_ENABLE_CACHING=YES "COMPILATION_CACHE_CAS_PATH=$cache_dir") || failed+=("$pkg/$product")
        done
    done
}

swift --version | head -1
failed=()
if [[ "$platform" == "ios" ]]; then
    build_ios
    if (( ${#failed[@]} )); then
        echo "FAILED: ${failed[*]}"
        exit 1
    fi
    echo "All packages OK (build, ios)"
    exit 0
fi
for manifest in "$ROOT"/Packages/*/Package.swift; do
    dir="$(dirname "$manifest")"; pkg="$(basename "$dir")"
    if (( ${#selected[@]} )) && [[ " ${selected[*]} " != *" $pkg "* ]]; then continue; fi
    if (( ${#excluded[@]} )) && [[ " ${excluded[*]} " == *" $pkg "* ]]; then continue; fi
    if [[ "$platform" == "linux" && " $APPLE_ONLY " == *" $pkg "* ]]; then
        echo "== $pkg: skipped on linux (Apple-only)"; continue
    fi
    scratch=()
    [[ -z "${OH_SCRATCH_ROOT:-}" ]] || scratch=(--scratch-path "$OH_SCRATCH_ROOT/$pkg")
    echo "== $pkg ($mode, $platform)"
    ok=1
    if [[ "$mode" != "test" ]]; then
        (cd "$dir" && swift build --build-tests --jobs 2 ${scratch[@]+"${scratch[@]}"}) || ok=0
    fi
    if [[ "$ok" == 1 && "$mode" != "build" ]]; then
        if [[ -n "${OH_TEST_LOG_DIR:-}" ]]; then
            mkdir -p "$OH_TEST_LOG_DIR"
            log="$OH_TEST_LOG_DIR/$pkg.log"
        else
            log="$(mktemp -t "oh-test-$pkg")"
        fi
        test_args=(--jobs 2)
        if (( serialized_tests )); then test_args+=(--no-parallel); fi
        (cd "$dir" && swift test "${test_args[@]}" ${scratch[@]+"${scratch[@]}"} 2>&1 | tee "$log"; exit "${PIPESTATUS[0]}") || ok=0
        if [[ "$ok" == 1 ]] && ! "$ROOT/Tools/ci/check-test-log.sh" "$log" "$dir"; then
            echo "== $pkg: incomplete test run"; ok=0
        fi
        if [[ -z "${OH_TEST_LOG_DIR:-}" ]]; then rm -f "$log"; fi
    fi
    (( ok )) || failed+=("$pkg")
done

if (( ${#failed[@]} )); then
    echo "FAILED: ${failed[*]}"
    exit 1
fi
echo "All packages OK ($mode, $platform)"
