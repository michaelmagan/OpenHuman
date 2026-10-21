#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OH_SNAPSHOT_DIR:-$HOME/Downloads/OpenHuman-renders/$(date +%Y%m%d-%H%M%S)}"
ONLY=""; SWIFTPM=0; KEEP=0; TESTS=""; THEMES=""
KNOWN_THEMES="light dark paper midnight system-light system-dark light-reduce-motion dark-reduce-motion light-increase-contrast dark-increase-contrast"
usage() {
    cat <<'EOF'
Usage: Tools/render-sweep.sh [options]

Renders the app's main screens and states on sample data into PNGs, with index.json
(screen, theme, file) beside them, for a visual check. Two test suites do the work, each
only when OH_SNAPSHOT_DIR is set:
  package half  MailUIMacTests/RenderSweepTests          (main window, reader, composer, overlays,
                                                          start-up screens)
  app half      MailAppTests/RenderSweepSettingsTests    (every Settings page, 780 x 560, as the
                                                          app hosts them)
The output folder must be outside every git work tree (the script and the suites both refuse
one inside); never commit the PNGs. Build products go to a temporary folder outside the
repository and are deleted afterwards. With OH_SCRATCH_ROOT set, the swift test path builds
in $OH_SCRATCH_ROOT/OpenHumanMailUI instead, so a second run builds incrementally.

  --out <dir>                output folder (default: $OH_SNAPSHOT_DIR, else
                             ~/Downloads/OpenHuman-renders/<timestamp>)
  --only <package|app>       run one half only
  --swiftpm                  run the package half with `swift test --filter` instead of xcodebuild
  --tests <name[,name...]>   only these RenderSweepTests functions (e.g. remindSheets,searchSheets);
                             implies --swiftpm and --only package, and checks the folder with
                             Tools/render-sweep-check.py at the end
  --themes <slug[,slug...]>  only these themes in the package half (OH_SWEEP_THEMES): light, dark,
                             paper, midnight, system-light, system-dark, light-reduce-motion,
                             dark-reduce-motion, light-increase-contrast, dark-increase-contrast.
                             The app half always renders the six built-in themes.
  --list                     print each test, the themes it takes and the screens it renders, read from
                             the test sources (Tools/render-sweep-list.py), then exit; needs no Xcode
  --keep-derived             keep the temporary build folder (its path is printed)
  -h, --help                 show this help
EOF
}
die() { echo "render-sweep: $1" >&2; exit 2; }
needs_value() { [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || die "$1 needs a value (see --help)"; }
while [[ $# -gt 0 ]]; do
    case "$1" in
        --out) needs_value "$@"; OUT="$2"; shift 2 ;;
        --only) needs_value "$@"; ONLY="$2"; shift 2 ;;
        --swiftpm) SWIFTPM=1; shift ;;
        --tests) needs_value "$@"; TESTS="$2"; shift 2 ;;
        --themes) needs_value "$@"; THEMES="$2"; shift 2 ;;
        --list) exec python3 "$ROOT/Tools/render-sweep-list.py" ;;
        --keep-derived) KEEP=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument $1 (see --help)" ;;
    esac
done
[[ -z "$ONLY" || "$ONLY" == package || "$ONLY" == app ]] || die "--only takes package or app"

FILTER="RenderSweepTests"
if [[ -n "$TESTS" ]]; then
    names=""
    IFS=',' read -r -a requested <<<"$TESTS"
    for name in "${requested[@]}"; do
        name="$(printf '%s' "$name" | tr -d '[:space:]')"
        [[ -z "$name" ]] && continue
        [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "--tests: '$name' is not a test function name"
        names="${names:+$names|}$name"
    done
    [[ -n "$names" ]] || die "--tests needs at least one function name"
    [[ "$ONLY" != app ]] || die "--tests names package-half functions; it cannot run with --only app"
    ONLY=package; SWIFTPM=1
    # Swift Testing ids read Suite/function(_:); the '(' keeps inbox from also matching inboxFoo
    FILTER="RenderSweepTests/($names)\\("
fi

if [[ -n "$THEMES" ]]; then
    slugs=""
    IFS=',' read -r -a requested <<<"$THEMES"
    for slug in "${requested[@]}"; do
        slug="$(printf '%s' "$slug" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
        [[ -z "$slug" ]] && continue
        [[ " $KNOWN_THEMES " == *" $slug "* ]] || die "--themes: unknown theme '$slug' (one of: ${KNOWN_THEMES// /, })"
        slugs="${slugs:+$slugs,}$slug"
    done
    [[ -n "$slugs" ]] || die "--themes needs at least one theme"
    THEMES="$slugs"
fi

case "$OUT" in
    "~"*) OUT="$HOME${OUT#\~}" ;;
    /*) ;;
    *) OUT="$PWD/$OUT" ;;
esac
inside_git_work_tree() {
    local p="$1"
    while :; do
        [[ -e "$p/.git" ]] && { echo "$p"; return 0; }
        [[ "$p" == "/" || -z "$p" ]] && return 1
        p="$(dirname "$p")"
    done
}
if tree="$(inside_git_work_tree "$OUT")"; then
    echo "render-sweep: $OUT is inside the git work tree $tree; pick a folder outside every checkout" >&2
    exit 1
fi
mkdir -p "$OUT/logs"
OUT="$(cd "$OUT" && pwd -P)"
if tree="$(inside_git_work_tree "$OUT")"; then
    echo "render-sweep: $OUT resolves inside the git work tree $tree" >&2
    exit 1
fi

for _ in $(seq 1 15); do
    free_gib="$(df -g / | awk 'NR==2 {print $4}')"
    (( free_gib >= 6 )) && break
    echo "render-sweep: ${free_gib} GiB free on /, waiting for 6 GiB"
    sleep 120
done
(( "$(df -g / | awk 'NR==2 {print $4}')" >= 6 )) || { echo "render-sweep: not enough free disk" >&2; exit 1; }

WORK="$(mktemp -d -t oh-render-sweep)"
cleanup() {
    if [[ "$KEEP" == 1 ]]; then echo "render-sweep: build folder kept at $WORK"; else rm -rf "$WORK"; fi
}
trap cleanup EXIT

spm_scratch() {
    local root="${OH_SCRATCH_ROOT-}"
    if [[ -n "$root" && -d "$(dirname "$root")" ]]; then echo "$root/OpenHumanMailUI"; else echo "$WORK/spm"; fi
}

status=0
run_logged() {
    local name="$1"; shift
    local log="$OUT/logs/$name.log"
    echo "render-sweep: $name (log: $log)"
    local rc=0
    "$@" >"$log" 2>&1 || rc=$?
    if [[ "$rc" != 0 ]]; then
        echo "render-sweep: $name failed (exit $rc); last lines:" >&2
        tail -n 30 "$log" >&2
        status=1
    fi
}

if [[ -z "$ONLY" || "$ONLY" == package ]]; then
    PKG="$ROOT/Packages/OpenHumanMailUI"
    scheme=""
    if [[ "$SWIFTPM" == 0 ]]; then
        scheme="$(cd "$PKG" && xcodebuild -list 2>/dev/null | sed -n 's/^ *\(OpenHumanMailUI-Package\) *$/\1/p' | head -1)"
        [[ -n "$scheme" ]] || echo "render-sweep: no OpenHumanMailUI-Package scheme listed; using swift test for the package half"
    fi
    [[ -z "$THEMES" ]] || echo "render-sweep: themes $THEMES"
    if [[ -n "$scheme" ]]; then
        run_logged package env TEST_RUNNER_OH_SNAPSHOT_DIR="$OUT" OH_SNAPSHOT_DIR="$OUT" \
            TEST_RUNNER_OH_SWEEP_THEMES="$THEMES" OH_SWEEP_THEMES="$THEMES" \
            bash -c 'cd "$1" && xcodebuild test -skipPackageUpdates -scheme "$2" -destination "platform=macOS,arch=arm64" \
                -derivedDataPath "$3/dd-package" -only-testing:MailUIMacTests/RenderSweepTests' _ "$PKG" "$scheme" "$WORK"
    else
        scratch="$(spm_scratch)"
        [[ -z "$TESTS" ]] || echo "render-sweep: tests $names (filter $FILTER)"
        run_logged package env OH_SNAPSHOT_DIR="$OUT" OH_SWEEP_THEMES="$THEMES" \
            bash -c 'cd "$1" && swift test --scratch-path "$2" --filter "$3"' _ "$PKG" "$scratch" "$FILTER"
    fi
fi

if [[ -z "$ONLY" || "$ONLY" == app ]]; then
    [[ -z "$THEMES" ]] || echo "render-sweep: note: the app half renders the six built-in themes (--themes is the package half's)"
    run_logged bootstrap "$ROOT/Tools/bootstrap.sh"
    args=(test -project "$ROOT/Apps/Mail/Mail.xcodeproj" -scheme Mail -destination 'platform=macOS,arch=arm64'
          -derivedDataPath "$WORK/dd-app" -only-testing:MailAppTests/RenderSweepSettingsTests)
    if [[ ! -f "$ROOT/Apps/Mail/Config/Local.xcconfig" ]]; then
        args+=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=)
    fi
    run_logged app env TEST_RUNNER_OH_SNAPSHOT_DIR="$OUT" xcodebuild -skipPackageUpdates "${args[@]}"
fi

count="$(find "$OUT" -maxdepth 1 -name '*.png' | wc -l | tr -d ' ')"
screens="$(python3 -c 'import json, sys; print(len({e["screen"] for e in json.load(open(sys.argv[1]))}))' \
    "$OUT/index.json" 2>/dev/null || echo 0)"
echo "render-sweep: $count PNGs, $screens distinct screens in index.json, in $OUT"

if [[ -n "$TESTS" ]]; then
    check_log="$OUT/logs/check.log"
    if python3 "$ROOT/Tools/render-sweep-check.py" "$OUT" >"$check_log" 2>&1; then
        echo "render-sweep: check: $(head -n 1 "$check_log")"
    else
        echo "render-sweep: check found problems (log: $check_log):" >&2
        head -n 20 "$check_log" >&2
        status=1
    fi
fi
exit "$status"
