#!/usr/bin/env bash
set -uo pipefail

usage() {
    cat <<'EOF'
Usage: Tools/signing/verify.sh [--commits | --builds]

Checks, without prompts, that this shell can sign commits and Developer ID builds as set up by
Tools/signing/setup.sh (docs/release/LOCAL-SIGNING.md). Safe to run from SSH logins and scripts. It
changes no settings, submits nothing to Apple's notary service and pushes nothing anywhere.

Commits: git signs with the dedicated key through its key service, the key is loaded, a commit in a
temporary repository is signed and verifies, and pushing an unsigned commit of yours is refused.
Builds: the signing keychain unlocks with its password file, the Developer ID identity is valid, a
copy of /usr/bin/true is signed with the hardened runtime and a secure timestamp (needs the network)
and verifies, and the notarytool profile answers (it lists past submissions only). When the update
settings for make-dmg.sh --enable-updates are set (OH_UPDATE_FEED_URL, OH_SPARKLE_PUBLIC_KEY), they
are well formed, Sparkle's sign_update is installed and a Sparkle signing key is in your keychains
(its secret is never read).

  --commits     only the commit checks
  --builds      only the build checks
  -h, --help    show this help

Exit status: 0 when every check passes, 1 when any check fails, 2 for bad arguments.
EOF
}

DO_COMMITS=1; DO_BUILDS=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        --commits) DO_BUILDS=0; shift ;;
        --builds) DO_COMMITS=0; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "verify: unknown argument $1 (see --help)" >&2; exit 2 ;;
    esac
done

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GS_DIR="$HOME/.local/share/git-signing"
KEY="$GS_DIR/signing_ed25519"
SOCK="$GS_DIR/agent.sock"
GS_LABEL=local.git-signing
FAILED=0
TMP="$(mktemp -d "${TMPDIR:-/tmp}/signing-verify.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

pass() { printf 'verify: PASS  %s\n' "$*"; }
fail() { printf 'verify: FAIL  %s\n' "$*"; FAILED=1; }
warn() { printf 'verify: WARN  %s\n' "$*"; }
hint() { printf '              %s\n' "$*"; }
step() { printf '\nverify: == %s\n' "$*"; }
indent() { sed -e 's/^/              /' | head -"${1:-8}"; }

with_timeout() {
    local seconds="$1"; shift
    "$@" &
    local pid=$!
    (
        trap 'kill "$sleeper" 2>/dev/null; exit 0' TERM
        sleep "$seconds" & sleeper=$!
        wait "$sleeper"
        kill "$pid" 2>/dev/null
    ) &
    local watcher=$! rc
    wait "$pid"; rc=$?
    kill "$watcher" 2>/dev/null; wait "$watcher" 2>/dev/null
    return "$rc"
}

context() {
    step "This shell"
    if [[ -n "${SSH_CONNECTION:-}${SSH_TTY:-}" ]]; then
        printf 'verify: an SSH login (the login keychain is locked here; nothing below may depend on it)\n'
    else
        printf 'verify: session type %s\n' "$(launchctl managername 2>/dev/null || echo unknown)"
    fi
}

check_commits() {
    step "Commit signing"
    local value pub listed rc out status
    if [[ ! -f "$KEY.pub" ]]; then
        fail "no commit-signing key at $KEY.pub"; hint "Run Tools/signing/setup.sh --commits in Terminal on the Mac."
        return
    fi
    pub="$(awk '{ print $1 " " $2; exit }' "$KEY.pub")"
    value="$(git config --get gpg.format || true)"
    if [[ "$value" == ssh ]]; then pass "gpg.format is ssh"; else fail "gpg.format is '${value}', not ssh"; fi
    value="$(git config --get commit.gpgsign || true)"
    if [[ "$value" == true ]]; then pass "commit.gpgsign is true"; else fail "commit.gpgsign is '${value}' here; commits would not be signed"; fi
    value="$(git config --get user.signingkey || true)"
    if [[ "$value" == "key::$pub" ]]; then pass "user.signingkey is the dedicated key"
    else fail "user.signingkey is '${value}', not the dedicated key (key::$pub)"; fi
    value="$(git config --get gpg.ssh.program || true)"
    if [[ "$value" == "$GS_DIR/bin/ssh-keygen-signing" && -x "$value" ]]; then pass "gpg.ssh.program is the signing helper"
    else fail "gpg.ssh.program is '${value}', not $GS_DIR/bin/ssh-keygen-signing"; fi
    if launchctl print "gui/$(id -u)/$GS_LABEL" >/dev/null 2>&1; then pass "launchd job $GS_LABEL is loaded"
    else fail "launchd job $GS_LABEL is not loaded"; hint "It loads when you log in to the Mac's desktop."; fi
    if [[ -S "$SOCK" ]]; then
        listed="$(SSH_AUTH_SOCK="$SOCK" /usr/bin/ssh-add -L 2>&1)"; rc=$?
        if [[ "$rc" == 2 ]]; then
            fail "cannot connect to $SOCK: $listed"
            hint "A sandbox may block Unix sockets; allow $SOCK or run git outside the sandbox."
        elif [[ "$listed" == *"${pub#* }"* ]]; then
            pass "the key service holds the signing key"
        else
            fail "the key service does not hold the signing key"
            hint "launchctl kickstart -k gui/$(id -u)/$GS_LABEL, then see $GS_DIR/service.log"
        fi
    else
        fail "$SOCK is missing: the key service is not running"
    fi

    local repo="$TMP/repo" bare="$TMP/bare.git"
    git init -q "$repo" && git init -q --bare "$bare"
    if out="$(git -C "$repo" commit -q --allow-empty -m "signing check" </dev/null 2>&1)"; then
        status="$(git -C "$repo" log -1 --format=%G?)"
        if [[ "$status" == G ]] && git -C "$repo" verify-commit HEAD >/dev/null 2>&1; then
            pass "a test commit is signed and verifies (status G)"
        else
            fail "a test commit was made but its signature status is ${status:-?}, not G"
            hint "Is $(git config --get gpg.ssh.allowedSignersFile || echo 'the allowed-signers file') listing this key for $(git config --get user.email)?"
        fi
    else
        fail "git could not make a signed test commit:"; printf '%s\n' "$out" | indent 6
    fi

    if [[ -z "$(git config --get hook.signed-push-guard.command || true)" ]]; then
        fail "the unsigned-push guard (hook.signed-push-guard) is not configured"
        return
    fi
    git -C "$repo" -c commit.gpgsign=false commit -q --allow-empty -m "unsigned check" </dev/null >/dev/null 2>&1
    out="$(git -C "$repo" push -q "$bare" HEAD:refs/heads/check 2>&1)"
    if [[ "$out" == *"git-signing: refusing to push"* ]]; then
        pass "pushing an unsigned commit of yours is refused"
    else
        fail "pushing an unsigned commit of yours was not refused by the guard:"; printf '%s\n' "$out" | indent 6
    fi
}

check_builds() {
    step "Build signing and notarization"
    local settings kc pwfile hash profile ids out info
    for settings in "${OH_RELEASE_ENV:-$HOME/.config/openhuman/release.env}" "$ROOT/Tools/release/release.env"; do
        # shellcheck disable=SC1090
        if [[ -f "$settings" ]]; then source "$settings"; fi
    done
    kc="${OH_SIGNING_KEYCHAIN:-}"; pwfile="${OH_SIGNING_KEYCHAIN_PASSWORD_FILE:-}"
    hash="${OH_SIGN_IDENTITY:-}"; profile="${OH_NOTARY_PROFILE:-}"
    if [[ -z "$kc" ]]; then
        fail "OH_SIGNING_KEYCHAIN is not set, so make-dmg.sh signs from the login keychain"
        hint "An SSH login cannot unlock the login keychain (codesign then fails with errSecInternalComponent)."
        hint "Run Tools/signing/setup.sh --builds in Terminal on the Mac."
        return
    fi
    if [[ ! -f "$kc" ]]; then fail "$kc does not exist"; return; fi
    if [[ -z "$pwfile" || ! -f "$pwfile" ]]; then fail "the keychain password file '${pwfile}' is missing"; return; fi
    if [[ -O "$pwfile" && "$(stat -f '%Lp' "$pwfile")" == 600 ]]; then pass "$pwfile is readable only by you"
    else fail "$pwfile must belong to you with mode 600"; fi
    if out="$(security unlock-keychain -p "$(cat "$pwfile")" "$kc" 2>&1)"; then pass "the signing keychain unlocks"
    else fail "the password file does not unlock $kc: $out"; return; fi
    info="$(security show-keychain-info "$kc" 2>&1 || true)"
    if [[ "$info" == *timeout=* || "$info" == *lock-on-sleep* ]]; then warn "the signing keychain locks on its own ($info)"; fi
    if [[ "$(security list-keychains -d user)" == *"$kc"* ]]; then pass "the signing keychain is in the keychain search list"
    else fail "the signing keychain is not in the keychain search list; Xcode would not find the identity"; fi

    ids="$(security find-identity -v -p codesigning "$kc" 2>/dev/null | grep 'Developer ID Application' || true)"
    if [[ -z "$hash" ]]; then
        if [[ "$(printf '%s\n' "$ids" | grep -c .)" == 1 ]]; then hash="$(printf '%s\n' "$ids" | awk '{ print $2 }')"; fi
    fi
    if [[ -n "$hash" && "$ids" == *"$hash"* ]]; then
        pass "valid Developer ID Application identity $hash in the signing keychain"
    else
        fail "no valid Developer ID Application identity ${hash:+$hash }in $kc"
        if [[ "$(security find-identity -p codesigning "$kc" 2>/dev/null || true)" == *"Developer ID Application"* ]]; then
            hint "It is there but not valid: install the Developer ID intermediate certificates from https://www.apple.com/certificateauthority/"
        fi
        return
    fi
    if [[ "$(security find-identity -p codesigning "$HOME/Library/Keychains/login.keychain-db" 2>/dev/null || true)" == *"$hash"* ]]; then
        warn "the same identity is also in the login keychain; Xcode's export step may pick that copy, which an SSH login cannot use"
    fi

    cp /usr/bin/true "$TMP/signing-check"
    if out="$(with_timeout 120 codesign --force --sign "$hash" --keychain "$kc" --options runtime --timestamp "$TMP/signing-check" 2>&1)"; then
        pass "a test binary is signed with the hardened runtime and a secure timestamp"
    else
        fail "codesign could not sign a test binary:"; printf '%s\n' "$out" | indent 6
        hint "errSecInternalComponent: the key needs a dialog (partition list or ACL) or the keychain is locked."
        hint "Timestamp errors: Apple's timestamp service must be reachable over the network."
        hint "Timed out: a dialog is probably waiting on the Mac's screen."
    fi
    if [[ -f "$TMP/signing-check" ]] && codesign --verify --strict "$TMP/signing-check" >/dev/null 2>&1; then
        out="$(codesign -dvv "$TMP/signing-check" 2>&1)"
        if [[ "$out" == *"Authority=Developer ID Application"* && "$out" == *"Timestamp="* ]]; then
            pass "its signature verifies, names Developer ID Application and carries a timestamp"
        else
            fail "its signature lacks the Developer ID authority or the timestamp"
        fi
    fi

    if [[ -z "$profile" ]]; then fail "OH_NOTARY_PROFILE is not set"
    elif out="$(with_timeout 120 xcrun notarytool history --keychain-profile "$profile" --keychain "$kc" --output-format json 2>&1 >/dev/null)"; then
        pass "notarytool profile '$profile' in the signing keychain answers (nothing submitted)"
    else
        fail "notarytool cannot use profile '$profile' from $kc:"; printf '%s\n' "$out" | indent 6
    fi
    if command -v caffeinate >/dev/null 2>&1; then pass "caffeinate is available (make-dmg.sh keeps the Mac awake)"; fi
}

check_updates() {
    step "Update signing (make-dmg.sh --enable-updates)"
    local feed="${OH_UPDATE_FEED_URL:-}" key="${OH_SPARKLE_PUBLIC_KEY:-}" account="${OH_SPARKLE_ACCOUNT:-openhuman-mail}" tools
    if [[ -z "$feed" && -z "$key" ]]; then
        printf 'verify: OH_UPDATE_FEED_URL and OH_SPARKLE_PUBLIC_KEY are not set: builds are made without updates\n'
        return
    fi
    if [[ -z "$feed" || -z "$key" ]]; then fail "set both OH_UPDATE_FEED_URL and OH_SPARKLE_PUBLIC_KEY, or neither"; return; fi
    case "$feed" in
        https://?*) pass "OH_UPDATE_FEED_URL is an https:// feed ($feed)" ;;
        http://127.0.0.1[:/]*|http://localhost[:/]*) warn "OH_UPDATE_FEED_URL is on this Mac ($feed): staged update tests only" ;;
        *) fail "OH_UPDATE_FEED_URL '$feed' is not an https:// address" ;;
    esac
    if python3 -I -c 'import base64, sys; sys.exit(0 if len(base64.b64decode(sys.argv[1], validate=True)) == 32 else 1)' \
        "$key" >/dev/null 2>&1; then pass "OH_SPARKLE_PUBLIC_KEY is a 32-byte EdDSA public key"
    else fail "OH_SPARKLE_PUBLIC_KEY is not a base64 EdDSA public key of 32 bytes (generate_keys -p prints it)"; fi
    # shellcheck disable=SC1091
    if [[ -f "$ROOT/Tools/versions.env" ]]; then source "$ROOT/Tools/versions.env"; fi
    tools="$ROOT/Tools/.bin/sparkle-${SPARKLE_VERSION:-unknown}/bin"
    if [[ -x "$tools/sign_update" ]]; then pass "Sparkle ${SPARKLE_VERSION:-} sign_update is installed"
    else warn "sign_update is not installed; run Tools/release/install-release-tools.sh"; fi
    if with_timeout 20 security find-generic-password -s https://sparkle-project.org -a "$account" >/dev/null 2>&1; then
        pass "a Sparkle signing key for account '$account' is in your keychains (not read)"
    else
        warn "no Sparkle signing key for account '$account' found (or its keychain is locked over SSH)"
        hint "Make one once with generate_keys --account $account (docs/release/SPARKLE.md), or sign with --ed-key-file."
    fi
}

context
if [[ "$DO_COMMITS" == 1 ]]; then check_commits; fi
if [[ "$DO_BUILDS" == 1 ]]; then check_builds; check_updates; fi
printf '\n'
if [[ "$FAILED" == 0 ]]; then printf 'verify: all checks passed\n'; exit 0; fi
printf 'verify: some checks failed (above); see docs/release/LOCAL-SIGNING.md, "When something fails"\n'
exit 1
