#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/Tools/versions.env"

usage() {
    cat <<'EOF'
Usage: Tools/release/install-release-tools.sh [--print-dir]

Downloads Sparkle's command-line tools at the version and SHA-256 checksum pinned in
Tools/versions.env into Tools/.bin/ (ignored by git), and refuses an archive whose checksum
differs. Safe to run again. Needs a Mac.

  - generate_keys makes the update signing key once and keeps it in your login keychain
  - sign_update signs a disk image for the update feed (Tools/release/update-appcast.py runs it)

  --print-dir   print the folder that holds the tools, installing them first if needed
  -h, --help    show this help
EOF
}

PRINT=0
case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    --print-dir) PRINT=1 ;;
    "") ;;
    *) echo "install-release-tools: unknown argument $1 (see --help)" >&2; exit 2 ;;
esac

say() { printf 'install-release-tools: %s\n' "$*" >&2; }
die() { printf 'install-release-tools: %s\n' "$*" >&2; exit 1; }
[[ "$(uname -s)" == Darwin ]] || die "run this on a Mac."
[[ -n "${SPARKLE_SHA256:-}" ]] || die "SPARKLE_SHA256 is empty in Tools/versions.env"

DIR="$ROOT/Tools/.bin/sparkle-$SPARKLE_VERSION"
if [[ ! -x "$DIR/bin/sign_update" || ! -x "$DIR/bin/generate_keys" ]]; then
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    url="https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
    say "downloading $url"
    curl -fsSL -o "$tmp/sparkle.tar.xz" "$url" || die "could not download $url"
    echo "$SPARKLE_SHA256  $tmp/sparkle.tar.xz" | shasum -a 256 -c - >/dev/null \
        || die "SHA-256 mismatch for $url; refusing to use it (Tools/versions.env)"
    mkdir -p "$tmp/x"
    tar -xf "$tmp/sparkle.tar.xz" -C "$tmp/x" ./bin
    mkdir -p "$ROOT/Tools/.bin"; rm -rf "$DIR"
    mv "$tmp/x" "$DIR"
fi
[[ -x "$DIR/bin/sign_update" && -x "$DIR/bin/generate_keys" ]] || die "Sparkle $SPARKLE_VERSION has no bin/sign_update or bin/generate_keys"

if [[ "$PRINT" == 1 ]]; then echo "$DIR/bin"
else say "Sparkle $SPARKLE_VERSION tools in $DIR/bin (checksum verified)"; fi
