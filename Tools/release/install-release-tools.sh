#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/Tools/versions.env"

usage() {
    cat <<'USAGE'
Usage: Tools/release/install-release-tools.sh [--print-dir sparkle|git-cliff]

Downloads the release tools the release workflow uses, at the versions and SHA-256 checksums
pinned in Tools/versions.env, into Tools/.bin/ (ignored by git), and refuses any file whose
checksum differs. Safe to run again. Needs a Mac (the archives are for Apple silicon).

  - Sparkle's command-line tools: sign_update signs a disk image for the appcast, and
    generate_keys makes the one-time signing key (docs/release/SPARKLE.md)
  - git-cliff, which writes the release notes from the commits since the last release tag

  --print-dir <tool>   print the folder that holds the tool's programs, install it if needed
  -h, --help           show this help
USAGE
}

PRINT=""
case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    --print-dir) [[ "${2:-}" == sparkle || "${2:-}" == git-cliff ]] || { echo "install-release-tools: --print-dir needs sparkle or git-cliff" >&2; exit 2; }
                 PRINT="$2" ;;
    "") ;;
    *) echo "install-release-tools: unknown argument $1 (see --help)" >&2; exit 2 ;;
esac

say() { printf 'install-release-tools: %s\n' "$*" >&2; }
die() { printf 'install-release-tools: %s\n' "$*" >&2; exit 1; }
[[ "$(uname -s)" == Darwin ]] || die "run this on a Mac."

BIN="$ROOT/Tools/.bin"
SPARKLE_DIR="$BIN/sparkle-$SPARKLE_VERSION"
CLIFF_DIR="$BIN/git-cliff-$GIT_CLIFF_VERSION"

fetch() {
    local url="$1" sha="$2" dest="$3" tmp
    tmp="$(mktemp -d)"
    say "downloading $url"
    curl -fsSL -o "$tmp/archive" "$url" || { rm -rf "$tmp"; die "could not download $url"; }
    echo "$sha  $tmp/archive" | shasum -a 256 -c - >/dev/null \
        || { rm -rf "$tmp"; die "SHA-256 mismatch for $url; refusing to use it (Tools/versions.env)"; }
    mkdir -p "$tmp/x"
    tar -xf "$tmp/archive" -C "$tmp/x"
    mkdir -p "$BIN"; rm -rf "$dest"
    mv "$tmp/x" "$dest"
    rm -rf "$tmp"
}

if [[ ! -x "$SPARKLE_DIR/bin/sign_update" ]]; then
    fetch "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" \
        "$SPARKLE_SHA256" "$SPARKLE_DIR"
fi
[[ -x "$SPARKLE_DIR/bin/sign_update" ]] || die "Sparkle $SPARKLE_VERSION has no bin/sign_update"
if [[ ! -x "$CLIFF_DIR/git-cliff" ]]; then
    fetch "https://github.com/orhun/git-cliff/releases/download/v$GIT_CLIFF_VERSION/git-cliff-$GIT_CLIFF_VERSION-aarch64-apple-darwin.tar.gz" \
        "$GIT_CLIFF_SHA256" "$CLIFF_DIR.tmp"
    mv "$CLIFF_DIR.tmp/git-cliff-$GIT_CLIFF_VERSION" "$CLIFF_DIR"; rm -rf "$CLIFF_DIR.tmp"
fi
[[ -x "$CLIFF_DIR/git-cliff" ]] || die "git-cliff $GIT_CLIFF_VERSION has no git-cliff program"

case "$PRINT" in
    sparkle) echo "$SPARKLE_DIR/bin" ;;
    git-cliff) echo "$CLIFF_DIR" ;;
    *) say "Sparkle $SPARKLE_VERSION tools in $SPARKLE_DIR/bin, git-cliff $GIT_CLIFF_VERSION in $CLIFF_DIR (checksums verified)" ;;
esac
