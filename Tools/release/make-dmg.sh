#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: Tools/release/make-dmg.sh [options]

Makes a signed, notarized, stapled DMG of OpenHuman Mail that other people can open on their
Macs (docs/release/RELEASE-HOWTO.md), or with --unsigned an ad-hoc signed DMG that needs no
Apple Developer account. Every release is an early development build: the app, release-info.txt
and the release notes say so, and the GitHub release is a pre-release. For a signed build, run
it on the Mac that holds your Developer ID certificate: in Terminal.app, or from any shell, such as
an SSH login, once Tools/signing/setup.sh has set up the signing keychain (an SSH login cannot
unlock the login keychain). A signed build sends two files to Apple's notary service (the app,
then the dmg). Nothing else is sent anywhere: no push, no tag. caffeinate keeps the Mac awake
while it runs.

A signed build carries the iCloud entitlements in
Apps/Mail/Entitlements/Mail-iCloud.entitlements (CloudKit, push and the shared keychain group).
It embeds your Developer ID provisioning profile in the app, after checking that the profile
grants each of them for this App ID, team and certificate; a profile that does not stops the
build before anything is built.

Every build leaves Sparkle's XPC services out of the app and signs Sparkle again: Mail is not
sandboxed, so the updater never uses them. A build updates itself only when it is made with
--enable-updates, which needs a Developer ID build with --no-icloud and the feed and key settings
below (docs/release/SPARKLE.md). Every other build carries an empty feed and key and never checks.

  --dry-run            print each command instead of running it: builds, signs and sends
                       nothing; needs no certificate
  --build-number <n>   CFBundleVersion (default: the number of commits in HEAD)
  --allow-dirty        build with uncommitted changes; the app then says "+dirty" (rehearsals
                       only)
  --unsigned           no Developer ID and no notarization: the app is ad-hoc signed and the
                       dmg is not signed. macOS blocks it at first open until the person allows
                       it in System Settings. No iCloud entitlements
  --no-icloud          sign without the iCloud entitlements and without a provisioning profile
  --sign-only          sign and package, skip notarization and stapling (rehearsals only; never
                       hand it out)
  --from-archive       skip "xcodebuild -exportArchive" and use the app as signed in the
                       archive (fallback)
  --enable-updates     build in the update feed and public key, so installed copies update
                       themselves. Needs --no-icloud: every update keeps the entitlements of the
                       first installed build. Not with --unsigned
  -h, --help           show this help

Settings (environment, then ~/.config/openhuman/release.env, which Tools/signing/setup.sh writes,
then Tools/release/release.env, which git ignores; copy release.env.example). The first one to set
a name wins:
  OH_NOTARY_PROFILE    the notarytool keychain profile you saved once with "xcrun notarytool
                       store-credentials"
  OH_SIGNING_KEYCHAIN  a keychain to sign and notarize from instead of the login keychain; it is
                       unlocked with the password in OH_SIGNING_KEYCHAIN_PASSWORD_FILE (a file
                       only you can read). Set it empty to use the login keychain
  OH_RELEASE_ENV       another file to read instead of ~/.config/openhuman/release.env
  OH_SIGN_IDENTITY     your "Developer ID Application" identity, by full name or SHA-1 hash
                       (default: the only one in your keychain)
  OH_BUNDLE_ID_PREFIX  default dev.openhuman, giving the bundle id dev.openhuman.mail
  OH_PROVISIONING_PROFILE
                       path to the Developer ID provisioning profile you downloaded for the
                       app's App ID; not needed with --unsigned or --no-icloud
  OH_UPDATE_FEED_URL   with --enable-updates: the https:// address of the update feed
                       (appcast.xml). http://127.0.0.1 is accepted only with --sign-only, for a
                       staged update test on this Mac
  OH_SPARKLE_PUBLIC_KEY
                       with --enable-updates: the base64 public key that "generate_keys -p"
                       prints. Updates must be signed with its private key

Output (ignored by git): build/release/OpenHuman-Mail-<version>-<build>/ (with -unsigned or
-signed-only appended for those builds) with the .dmg, its .sha256, release-info.txt, a
release-notes.md to finish, Apple's notarization answers, logs/, and the .xcarchive (keep it:
its dSYMs read crash reports).
EOF
}
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="$ROOT/Tools/release"
DRY=0; BUILD_NUMBER=""; ALLOW_DIRTY=0; SIGN_ONLY=0; FROM_ARCHIVE=0; UNSIGNED=0; NO_ICLOUD=0; ENABLE_UPDATES=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY=1; shift ;;
        --build-number) [[ $# -ge 2 ]] || { echo "make-dmg: --build-number needs a number" >&2; exit 2; }
                        BUILD_NUMBER="$2"; shift 2 ;;
        --allow-dirty) ALLOW_DIRTY=1; shift ;;
        --unsigned) UNSIGNED=1; shift ;;
        --no-icloud) NO_ICLOUD=1; shift ;;
        --sign-only) SIGN_ONLY=1; shift ;;
        --from-archive) FROM_ARCHIVE=1; shift ;;
        --enable-updates) ENABLE_UPDATES=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "make-dmg: unknown argument $1 (see --help)" >&2; exit 2 ;;
    esac
done
[[ "$UNSIGNED" == 0 || "$SIGN_ONLY" == 0 ]] || { echo "make-dmg: --unsigned and --sign-only do not go together" >&2; exit 2; }
ICLOUD=1; [[ "$UNSIGNED" == 0 && "$NO_ICLOUD" == 0 ]] || ICLOUD=0
if [[ "$ENABLE_UPDATES" == 1 ]]; then
    [[ "$UNSIGNED" == 0 ]] || { echo "make-dmg: --enable-updates needs a Developer ID build; an unsigned build never updates" >&2; exit 2; }
    [[ "$NO_ICLOUD" == 1 ]] || { echo "make-dmg: --enable-updates needs --no-icloud. Every update must keep the entitlements of the first installed build, and updating builds are made without iCloud" >&2; exit 2; }
fi

say()  { printf 'make-dmg: %s\n' "$*"; }
die()  { printf 'make-dmg: %s\n' "$*" >&2; exit 1; }
step() { printf '\nmake-dmg: == %s\n' "$*"; }
run() {
    if [[ "$DRY" == 1 ]]; then printf '  $'; printf ' %q' "$@"; printf '\n'; return 0; fi
    "$@"
}
run_logged() {
    local log="$1"; shift
    if [[ "$DRY" == 1 ]]; then printf '  $'; printf ' %q' "$@"; printf ' > %q 2>&1\n' "$log"; return 0; fi
    say "log: $log"
    if ! "$@" >"$log" 2>&1; then
        echo "---- last lines of $log ----" >&2; tail -40 "$log" >&2
        die "this step failed (full log above)."
    fi
}
need_dir() { [[ "$DRY" == 1 || -d "$1" ]] || die "expected $1 after the previous step, but it is not there."; }

OUT=""; DD="$ROOT/build/release/dd"
on_exit() {
    local rc=$?
    if [[ "$rc" != 0 && "$DRY" == 0 && -n "$OUT" && -d "$OUT" ]]; then
        printf 'make-dmg: stopped. Partial output: %s (logs/ has the details). Delete it, and %s, before the next run.\n' "$OUT" "$DD" >&2
    fi
}
trap on_exit EXIT

for settings in "${OH_RELEASE_ENV:-$HOME/.config/openhuman/release.env}" "$HERE/release.env"; do
    if [[ -f "$settings" ]]; then
        # shellcheck disable=SC1090
        source "$settings"
    fi
done

step "Checks before building"
[[ "$(uname -s)" == Darwin ]] || die "run this on a Mac."
for tool in xcodebuild xcrun codesign hdiutil ditto shasum security plutil git python3; do
    command -v "$tool" >/dev/null 2>&1 || die "'$tool' is missing. Install Xcode 27 and open it once."
done
[[ "$DRY" == 0 ]] || say "dry run: commands are printed, not run."
if [[ "$DRY" == 0 ]] && command -v caffeinate >/dev/null 2>&1; then
    # Why: idle sleep drops the network during the notarization waits, which can take many minutes.
    caffeinate -i -s -w $$ &
fi

COMMIT="$(git -C "$ROOT" rev-parse --short HEAD)"
BRANCH="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"
STAMP="$COMMIT"
if [[ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ]]; then
    if [[ "$ALLOW_DIRTY" == 1 ]]; then
        STAMP="$COMMIT+dirty"; say "warning: uncommitted changes. This build says $STAMP and is for rehearsal only."
    else
        die "you have uncommitted changes in tracked files. Commit them first (a release names its exact commit), or pass --allow-dirty for a rehearsal you will not hand out."
    fi
fi
say "commit $STAMP on branch $BRANCH"

VERSION="$("$HERE/bump-version.sh")" || die "could not read the version (above). Set it with Tools/release/bump-version.sh."
CHANNEL="$("$HERE/bump-version.sh" --channel)"
LABEL="$("$HERE/bump-version.sh" --label)"
[[ "$CHANNEL" == early-development ]] \
    || die "OH_RELEASE_CHANNEL in Apps/Mail/Config/Version.xcconfig is '$CHANNEL'. Every release is an early development build (early-development), and check-release.sh refuses anything else."
NOTICE="Early development build — expect rough edges. Please send feedback."
[[ -n "$BUILD_NUMBER" ]] || BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD)"
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || die "--build-number must be a whole number (got '$BUILD_NUMBER')."
LAST=0
for info in "$ROOT"/build/release/*/release-info.txt; do
    [[ -f "$info" ]] || continue
    n="$(sed -n 's/^build=//p' "$info" | head -1)"
    if [[ "$n" =~ ^[0-9]+$ ]] && (( n > LAST )); then LAST="$n"; fi
done
if (( BUILD_NUMBER <= LAST )); then
    say "warning: build number $BUILD_NUMBER is not above the last one built here ($LAST). Pass a higher --build-number if this build replaces that one."
fi
say "version $LABEL, build $BUILD_NUMBER"

PREFIX="${OH_BUNDLE_ID_PREFIX:-dev.openhuman}"
if [[ -f "$ROOT/Apps/Mail/Config/Local.xcconfig" ]]; then
    say "note: Apps/Mail/Config/Local.xcconfig exists. Its signing settings and OH_ENTITLEMENTS are overridden here; the bundle id is $PREFIX.mail."
fi

KEYCHAIN=(); SEARCH=()
if [[ "$UNSIGNED" == 0 && -n "${OH_SIGNING_KEYCHAIN:-}" ]]; then
    step "Signing keychain"
    KC="$OH_SIGNING_KEYCHAIN"; KC_PASSWORD="${OH_SIGNING_KEYCHAIN_PASSWORD_FILE:-}"
    [[ "$KC" != *[[:space:]]* ]] || die "OH_SIGNING_KEYCHAIN must be a path without spaces (got '$KC')."
    KEYCHAIN=(--keychain "$KC"); SEARCH=("$KC")
    if [[ "$DRY" == 1 ]]; then
        say "dry run: a real run unlocks $KC with the password in ${KC_PASSWORD:-<OH_SIGNING_KEYCHAIN_PASSWORD_FILE>}"
    else
        [[ -f "$KC" ]] || die "OH_SIGNING_KEYCHAIN is $KC, which does not exist. Run Tools/signing/setup.sh --builds in Terminal.app, or set OH_SIGNING_KEYCHAIN empty to use the login keychain."
        [[ -n "$KC_PASSWORD" && -f "$KC_PASSWORD" ]] || die "OH_SIGNING_KEYCHAIN_PASSWORD_FILE ('$KC_PASSWORD') is not a file. Tools/signing/setup.sh --builds writes it."
        [[ -O "$KC_PASSWORD" && "$(stat -f '%Lp' "$KC_PASSWORD")" == 600 ]] || die "$KC_PASSWORD must belong to you and be readable only by you (chmod 600)."
        security unlock-keychain -p "$(cat "$KC_PASSWORD")" "$KC" || die "the password in $KC_PASSWORD does not unlock $KC."
        say "signing keychain $KC is unlocked"
    fi
fi

if [[ "$UNSIGNED" == 1 ]]; then
    step "Signing"
    say "--unsigned: ad-hoc signature, no Developer ID, no notarization. macOS blocks the app at first open until the person allows it in System Settings."
    SIGN_HASH=""; TEAM=""
else
    step "Signing identity"
    IDS="$(security find-identity -v -p codesigning ${SEARCH[@]+"${SEARCH[@]}"} 2>/dev/null \
        | sed -n 's/^[[:space:]]*[0-9][0-9]*)[[:space:]]*\([0-9A-Fa-f]\{40\}\)[[:space:]]*"\(Developer ID Application: .*\)"[[:space:]]*$/\1 \2/p' || true)"
    if [[ -n "${OH_SIGN_IDENTITY:-}" ]]; then
        MATCH="$(printf '%s\n' "$IDS" | awk -v want="$OH_SIGN_IDENTITY" 'NF { if (toupper($1) == toupper(want) || substr($0, 42) == want) print }')"
        if [[ -z "$MATCH" && "$DRY" == 0 ]]; then
            die "OH_SIGN_IDENTITY does not name a valid 'Developer ID Application' identity in your keychain. List yours with: security find-identity -v -p codesigning. (An 'Apple Development' identity cannot be notarized.)"
        fi
    else
        MATCH="$IDS"
    fi
    COUNT="$(printf '%s\n' "$MATCH" | grep -c . || true)"
    if [[ "$COUNT" == 0 ]]; then
        [[ "$DRY" == 1 ]] || die "no 'Developer ID Application' certificate in ${OH_SIGNING_KEYCHAIN:-your keychain}. One-time setup: docs/release/RELEASE-HOWTO.md, 'Signing setup'. An 'Apple Development' certificate is not enough: Apple only notarizes apps signed with Developer ID. Without one, --unsigned makes an ad-hoc signed build."
        say "no 'Developer ID Application' identity in your keychain; the dry run uses placeholders. A real run stops here."
        SIGN_HASH="<SHA-1-of-your-Developer-ID-Application-certificate>"
        SIGN_NAME="Developer ID Application: <Your Name> (<TEAMID>)"; TEAM="<TEAMID>"
    elif [[ "$COUNT" != 1 ]]; then
        printf '%s\n' "$MATCH" | awk '{ printf "  %s  %s\n", $1, substr($0, 42) }' >&2
        die "more than one 'Developer ID Application' identity fits (listed above). Set OH_SIGN_IDENTITY to the hash of the one to use."
    else
        SIGN_HASH="${MATCH%% *}"; SIGN_NAME="${MATCH#* }"
        TEAM="$(printf '%s\n' "$SIGN_NAME" | sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p')"
        [[ -n "$TEAM" ]] || die "could not read the team id from the identity name (expected it to end in '(TEAMID)')."
    fi
    XCODE_IDENTITY="$SIGN_NAME"
    if [[ "$(printf '%s\n' "$IDS" | awk -v n="$SIGN_NAME" 'substr($0, 42) == n' | grep -c . || true)" -gt 1 ]]; then XCODE_IDENTITY="$SIGN_HASH"; fi
    # Why: the login keychain may hold another certificate with the same name.
    [[ -z "${OH_SIGNING_KEYCHAIN:-}" ]] || XCODE_IDENTITY="$SIGN_HASH"
    say "signing with Developer ID Application, team $TEAM (certificate $SIGN_HASH)"
fi

if [[ "$SIGN_ONLY" == 1 ]]; then
    say "--sign-only: no notarization. The result will NOT open cleanly on other Macs; never hand it out."
elif [[ "$UNSIGNED" == 0 ]]; then
    step "Notarization profile"
    if [[ -z "${OH_NOTARY_PROFILE:-}" ]]; then
        [[ "$DRY" == 1 ]] || die "set OH_NOTARY_PROFILE to the profile name you saved with 'xcrun notarytool store-credentials' (RELEASE-HOWTO, 'Signing setup'), or put it in Tools/release/release.env."
        OH_NOTARY_PROFILE="<your-notary-profile>"; say "OH_NOTARY_PROFILE is not set; the dry run uses a placeholder. A real run stops here."
    elif [[ "$DRY" == 0 ]]; then
        xcrun notarytool history --keychain-profile "$OH_NOTARY_PROFILE" ${KEYCHAIN[@]+"${KEYCHAIN[@]}"} >/dev/null 2>&1 \
            || die "notarytool cannot use the keychain profile '$OH_NOTARY_PROFILE'${OH_SIGNING_KEYCHAIN:+ in $OH_SIGNING_KEYCHAIN}. Redo the notarytool step in RELEASE-HOWTO, 'Signing setup', and run this in Terminal.app, or set up the signing keychain for SSH logins (docs/release/LOCAL-SIGNING.md)."
        say "notary profile '$OH_NOTARY_PROFILE' works"
    fi
fi

ICLOUD_ENTITLEMENTS="$ROOT/Apps/Mail/Entitlements/Mail-iCloud.entitlements"
if [[ "$ICLOUD" == 1 ]]; then
    step "Provisioning profile (iCloud)"
    PROFILE="${OH_PROVISIONING_PROFILE:-}"
    if [[ -z "$PROFILE" ]]; then
        [[ "$DRY" == 1 ]] || die "set OH_PROVISIONING_PROFILE (in Tools/release/release.env) to the Developer ID provisioning profile you downloaded for $PREFIX.mail (RELEASE-HOWTO, 'iCloud entitlements'), or pass --no-icloud to sign without iCloud."
        PROFILE="<your-Developer-ID.provisionprofile>"; say "OH_PROVISIONING_PROFILE is not set; the dry run uses a placeholder. A real run stops here."
    fi
    CHECK_PROFILE=(python3 -B "$HERE/provisioning.py" --profile "$PROFILE" --entitlements "$ICLOUD_ENTITLEMENTS"
                   --team "$TEAM" --bundle-id "$PREFIX.mail" --certificate-sha1 "$SIGN_HASH")
    if [[ "$PROFILE" == "<"* ]]; then
        :
    elif [[ ! -f "$PROFILE" ]]; then
        [[ "$DRY" == 1 ]] || die "OH_PROVISIONING_PROFILE is '$PROFILE', which is not a file. Download the Developer ID profile for $PREFIX.mail and set its path (RELEASE-HOWTO, 'iCloud entitlements')."
        say "warning: OH_PROVISIONING_PROFILE is '$PROFILE', which is not a file. A real run stops here."
    elif [[ "$SIGN_HASH" == "<"* ]]; then
        say "no Developer ID identity, so the dry run does not compare the profile with it. A real run does."
    elif PROFILE_SAYS="$("${CHECK_PROFILE[@]}" 2>&1)"; then
        say "$PROFILE_SAYS"
    else
        printf '%s\n' "$PROFILE_SAYS" | sed 's/^/  /' >&2
        [[ "$DRY" == 1 ]] || die "the provisioning profile does not fit this app (above). Nothing was built. Correct the App ID in the developer portal and download its Developer ID profile again (RELEASE-HOWTO, 'iCloud entitlements'), or pass --no-icloud."
        say "warning: the provisioning profile does not fit this app (above). A real run stops here."
    fi
fi

FEED=""; KEY=""
if [[ "$ENABLE_UPDATES" == 1 ]]; then
    step "Updates"
    FEED="${OH_UPDATE_FEED_URL:-}"; KEY="${OH_SPARKLE_PUBLIC_KEY:-}"
    if [[ -z "$FEED" || -z "$KEY" ]]; then
        [[ "$DRY" == 1 ]] || die "--enable-updates needs OH_UPDATE_FEED_URL (the https:// address of the update feed) and OH_SPARKLE_PUBLIC_KEY (the public key generate_keys prints), in the environment or Tools/release/release.env (docs/release/SPARKLE.md). Nothing was built."
        FEED="${FEED:-https://<your-update-feed>/appcast.xml}"; KEY="${KEY:-<your-SUPublicEDKey>}"
        say "OH_UPDATE_FEED_URL or OH_SPARKLE_PUBLIC_KEY is not set; the dry run uses a placeholder. A real run stops here."
    else
        # Why: only stdout carries the feed kind; runtime diagnostics on stderr must not bypass the loopback check.
        FEED_KIND="$(python3 -I -c '
import base64, binascii, sys
from urllib.parse import urlsplit
feed, key = sys.argv[1], sys.argv[2]
try:
    whole = len(base64.b64decode(key, validate=True)) == 32
except (binascii.Error, ValueError):
    whole = False
if not whole:
    sys.exit("OH_SPARKLE_PUBLIC_KEY is not a base64 EdDSA public key of 32 bytes. Copy the key that generate_keys -p prints.")
parts = urlsplit(feed)
if any(c.isspace() or c in "\"<>\\" for c in feed) or parts.username or parts.password or not parts.hostname:
    sys.exit(f"OH_UPDATE_FEED_URL {feed!r} is not a usable address.")
if parts.scheme == "https":
    print("https")
elif parts.scheme == "http" and parts.hostname in ("127.0.0.1", "localhost"):
    print("loopback")
else:
    sys.exit(f"OH_UPDATE_FEED_URL {feed!r} must start with https:// (http://127.0.0.1 only for a staged test with --sign-only).")
' "$FEED" "$KEY")" || die "invalid update settings (above). Nothing was built."
        if [[ "$FEED_KIND" == loopback && "$SIGN_ONLY" == 0 ]]; then
            die "OH_UPDATE_FEED_URL $FEED is on this Mac. That is only for a staged update test: add --sign-only, and never hand the build out. Nothing was built."
        fi
    fi
    say "updates on: feed $FEED, public key $KEY"
else
    say "updates off: no feed or key in the app, so it never checks for updates (--enable-updates turns them on)"
fi
UPDATES=("OH_UPDATE_FEED_URL=$FEED" "OH_SPARKLE_PUBLIC_KEY=$KEY")

NAME="OpenHuman-Mail-$VERSION"
OUT="$ROOT/build/release/$NAME-$BUILD_NUMBER"
[[ "$SIGN_ONLY" == 0 ]] || OUT="$OUT-signed-only"
[[ "$UNSIGNED" == 0 ]] || OUT="$OUT-unsigned"
LOGS="$OUT/logs"; WORK="$OUT/work"
ARCHIVE="$OUT/OpenHumanMail.xcarchive"
APP="$WORK/OpenHuman Mail.app"
DMG="$OUT/$NAME.dmg"
if [[ -e "$OUT" ]]; then
    if [[ "$DRY" == 1 ]]; then say "warning: $OUT already exists; a real run stops here."
    else OUT_EXISTS="$OUT"; OUT=""; die "$OUT_EXISTS already exists. Delete it, or build with a higher --build-number."; fi
fi
if [[ "$UNSIGNED" == 1 ]]; then
    CHECK=("$HERE/check-release.sh" --unsigned --expect-commit "$STAMP")
else
    CHECK=("$HERE/check-release.sh" --team "$TEAM" --expect-commit "$STAMP")
fi
[[ "$ICLOUD" == 0 ]] || CHECK+=(--icloud)
if [[ "$ENABLE_UPDATES" == 1 ]]; then CHECK+=(--updates "$FEED" --update-key "$KEY"); else CHECK+=(--updates off); fi
[[ "$ALLOW_DIRTY" == 0 ]] || CHECK+=(--allow-dirty)

FREE_GB="$(df -g "$ROOT" | awk 'NR == 2 { print $4 }')"
if [[ "$FREE_GB" =~ ^[0-9]+$ ]] && (( FREE_GB < 6 )); then
    if [[ "$DRY" == 1 ]]; then say "warning: only $FREE_GB GB free; a real run needs at least 6 GB."
    else die "only $FREE_GB GB free on this disk; the build needs at least 6 GB. Free some space and run again."; fi
fi

SUBMISSION=""
notarize() {
    local file="$1" label="$2" result="$OUT/notary-$2.json" rc=0 status=""
    say "sending the $label to Apple's notary service and waiting for the answer (often minutes; Apple publishes no maximum)"
    if [[ "$DRY" == 1 ]]; then
        printf '  $'; printf ' %q' xcrun notarytool submit "$file" --keychain-profile "$OH_NOTARY_PROFILE" ${KEYCHAIN[@]+"${KEYCHAIN[@]}"} --wait --output-format json
        printf ' > %q\n' "$result"
        SUBMISSION="<submission-id>"; return 0
    fi
    xcrun notarytool submit "$file" --keychain-profile "$OH_NOTARY_PROFILE" ${KEYCHAIN[@]+"${KEYCHAIN[@]}"} --wait --output-format json >"$result" || rc=$?
    SUBMISSION="$(plutil -extract id raw -o - "$result" 2>/dev/null \
        || grep -Eo '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "$result" | head -1 || true)"
    status="$(plutil -extract status raw -o - "$result" 2>/dev/null || true)"
    if [[ "$rc" == 0 && "$status" == Accepted ]]; then say "Apple accepted the $label (submission $SUBMISSION)"; return 0; fi
    if [[ -n "$SUBMISSION" ]]; then
        xcrun notarytool log "$SUBMISSION" --keychain-profile "$OH_NOTARY_PROFILE" ${KEYCHAIN[@]+"${KEYCHAIN[@]}"} "$OUT/notary-log-$label.json" >/dev/null 2>&1 || true
    fi
    die "Apple did not accept the $label (status: ${status:-unknown}; answer saved in $result). Read $OUT/notary-log-$label.json first: its \"issues\" list names each problem. To fetch it again: xcrun notarytool log ${SUBMISSION:-<submission-id>} --keychain-profile $OH_NOTARY_PROFILE notary-log.json."
}

step "Generate the Xcode project (pinned XcodeGen)"
run mkdir -p "$LOGS" "$WORK"
run "$ROOT/Tools/bootstrap.sh"

step "Archive the Release build (several minutes)"
if [[ "$UNSIGNED" == 1 ]]; then
    SIGNING=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=
             CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO)
else
    SIGNING=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$XCODE_IDENTITY" "DEVELOPMENT_TEAM=$TEAM" PROVISIONING_PROFILE_SPECIFIER=
             ENABLE_HARDENED_RUNTIME=YES "OTHER_CODE_SIGN_FLAGS=--timestamp${KEYCHAIN[*]:+ ${KEYCHAIN[*]}}" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO)
fi
run_logged "$LOGS/archive.log" xcodebuild archive -jobs 2 \
    -project "$ROOT/Apps/Mail/Mail.xcodeproj" -scheme Mail -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$DD" -archivePath "$ARCHIVE" \
    "${SIGNING[@]}" "OH_BUNDLE_ID_PREFIX=$PREFIX" OH_ENTITLEMENTS=Entitlements/Mail.entitlements \
    "OH_GIT_COMMIT=$STAMP" "CURRENT_PROJECT_VERSION=$BUILD_NUMBER" "OH_RELEASE_CHANNEL=$CHANNEL" "${UPDATES[@]}" \
    SWIFT_USE_INTEGRATED_DRIVER=YES
need_dir "$ARCHIVE/Products/Applications/OpenHumanMail.app"

step "Export the app"
if [[ "$FROM_ARCHIVE" == 1 || "$UNSIGNED" == 1 ]]; then
    run ditto "$ARCHIVE/Products/Applications/OpenHumanMail.app" "$APP"
else
    run cp "$HERE/ExportOptions.plist" "$WORK/ExportOptions.plist"
    run /usr/libexec/PlistBuddy -c "Set :signingCertificate $SIGN_HASH" "$WORK/ExportOptions.plist"
    run_logged "$LOGS/export.log" xcodebuild -exportArchive -archivePath "$ARCHIVE" \
        -exportPath "$WORK/export" -exportOptionsPlist "$WORK/ExportOptions.plist"
    need_dir "$WORK/export/OpenHumanMail.app"
    run ditto "$WORK/export/OpenHumanMail.app" "$APP"
    run rm -rf "$WORK/export"
fi
run rm -rf "$DD"

step "Leave Sparkle's XPC services out and sign Sparkle again"
# Why: Mail is not sandboxed, so Sparkle installs through its Autoupdate tool and never starts these services
# (SUEnableDownloaderService and SUEnableInstallerLauncherService stay off). Without them no helper in the release
# carries entitlements of its own
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [[ "$DRY" == 0 && ! -d "$SPARKLE" ]]; then
    [[ "$ENABLE_UPDATES" == 0 ]] || die "the app has no Sparkle.framework, so --enable-updates cannot work."
    say "no Sparkle.framework in the app; nothing to leave out"
else
    if [[ "$UNSIGNED" == 1 ]]; then
        RESIGN=(codesign --force --sign - --preserve-metadata=identifier,entitlements,flags)
    else
        RESIGN=(codesign --force --sign "$SIGN_HASH" ${KEYCHAIN[@]+"${KEYCHAIN[@]}"} --options runtime --timestamp
                --preserve-metadata=identifier,entitlements)
    fi
    run rm -rf "$SPARKLE/Versions/B/XPCServices" "$SPARKLE/XPCServices"
    run "${RESIGN[@]}" "$SPARKLE/Versions/B/Autoupdate"
    run "${RESIGN[@]}" "$SPARKLE/Versions/B/Updater.app"
    run "${RESIGN[@]}" "$SPARKLE"
    # The iCloud step below signs the app itself
    [[ "$ICLOUD" == 1 ]] || run "${RESIGN[@]}" "$APP"
fi

if [[ "$ICLOUD" == 1 ]]; then
    step "Embed the provisioning profile and sign the app with the iCloud entitlements"
    run "${CHECK_PROFILE[@]}" --write "$WORK/Mail-iCloud.entitlements" \
        || die "the provisioning profile does not fit this app (above). Nothing was sent to Apple."
    run cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
    run codesign --force --sign "$SIGN_HASH" ${KEYCHAIN[@]+"${KEYCHAIN[@]}"} --options runtime --timestamp \
        --entitlements "$WORK/Mail-iCloud.entitlements" "$APP"
fi

step "Check the app before anything goes out"
run "${CHECK[@]}" --pre-notarization "$APP" || die "the app failed the checks above. Nothing was sent to Apple."

APP_SUBMISSION=""; DMG_SUBMISSION=""
if [[ "$SIGN_ONLY" == 0 && "$UNSIGNED" == 0 ]]; then
    step "Notarize the app"
    run ditto -c -k --sequesterRsrc --keepParent "$APP" "$WORK/app.zip"
    notarize "$WORK/app.zip" app; APP_SUBMISSION="$SUBMISSION"
    run rm -f "$WORK/app.zip"
    step "Staple the ticket to the app and check it as Gatekeeper would"
    run xcrun stapler staple "$APP"
    run "${CHECK[@]}" "$APP" || die "the notarized app failed the checks above."
fi

step "Build the disk image"
STAGE="$WORK/dmg"
run mkdir -p "$STAGE"
run ditto "$APP" "$STAGE/OpenHuman Mail.app"
run ln -s /Applications "$STAGE/Applications"
run hdiutil create -volname "OpenHuman Mail" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
if [[ "$UNSIGNED" == 1 ]]; then
    step "Final checks: the disk image and the app inside it"
    run "${CHECK[@]}" "$DMG" || die "the disk image failed the checks above."
else
    run codesign --sign "$SIGN_HASH" ${KEYCHAIN[@]+"${KEYCHAIN[@]}"} --timestamp --verbose=2 "$DMG"
    if [[ "$SIGN_ONLY" == 0 ]]; then
        step "Notarize and staple the disk image"
        notarize "$DMG" dmg; DMG_SUBMISSION="$SUBMISSION"
        run xcrun stapler staple "$DMG"
        step "Final checks: the disk image and the app inside it"
        run "${CHECK[@]}" "$DMG" || die "the disk image failed the checks above."
    else
        run "${CHECK[@]}" --pre-notarization "$DMG" || die "the disk image failed the checks above."
    fi
fi

step "Checksum and record"
if [[ "$DRY" == 1 ]]; then
    printf '  $ (cd %q && shasum -a 256 %q > %q)\n' "$OUT" "$NAME.dmg" "$NAME.dmg.sha256"
    printf '  (writes %s/release-info.txt and release-notes.md, then removes %s)\n' "$OUT" "$WORK"
    run "$HERE/check-release.sh" "$OUT/release-info.txt"
    step "Dry run finished"
    say "nothing was built, signed or sent. Not tested by a dry run: whether the Release archive builds and signs (that needs Xcode 27, at least 6 GB of disk and, for a signed build, your Developer ID certificate)."
    [[ "$ICLOUD" == 0 ]] || say "Not tested by any run here: whether macOS accepts the embedded provisioning profile when the app launches. Open the first such build on another Mac."
    exit 0
fi
(cd "$OUT" && shasum -a 256 "$NAME.dmg" >"$NAME.dmg.sha256")
SHA="$(cut -d' ' -f1 "$OUT/$NAME.dmg.sha256")"
DR="$({ codesign -d -r- "$APP" 2>&1 || true; } | sed -n 's/^designated => //p')"
{
    echo "version=$VERSION"
    echo "channel=$CHANNEL"
    echo "label=$LABEL"
    echo "prerelease=yes"
    echo "build=$BUILD_NUMBER"
    echo "commit=$STAMP"
    echo "bundle_id=$PREFIX.mail"
    if [[ "$UNSIGNED" == 1 ]]; then echo "signing=ad-hoc"; else echo "signing=developer-id"; fi
    if [[ "$ICLOUD" == 1 ]]; then echo "icloud=yes"; else echo "icloud=no"; fi
    if [[ "$ENABLE_UPDATES" == 1 ]]; then echo "updates=yes"; echo "update_feed=$FEED"; else echo "updates=no"; fi
    echo "team=${TEAM:-none}"
    if [[ "$SIGN_ONLY" == 0 && "$UNSIGNED" == 0 ]]; then echo "notarized=yes"; else echo "notarized=no"; fi
    echo "notary_app=$APP_SUBMISSION"
    echo "notary_dmg=$DMG_SUBMISSION"
    echo "dmg=$NAME.dmg"
    echo "sha256=$SHA"
    echo "designated_requirement=$DR"
    echo "xcode=$(xcodebuild -version 2>/dev/null | head -1)"
    echo "built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >"$OUT/release-info.txt"
{
    echo "$NOTICE"
    echo
    echo "Requires Apple silicon and macOS 26.0 or later. During onboarding you import your own Google Desktop OAuth client."
    if [[ "$UNSIGNED" == 1 ]]; then
        echo
        echo "## Opening an unsigned build"
        echo
        echo "macOS may block unsigned builds because they are not notarized by Apple. To open one, try to open the app once. Then open System Settings, click Privacy & Security, and scroll to Security. Click Open Anyway, enter your login password, and click OK. The Open Anyway button stays available for about an hour after you first try to open the app."
    fi
    echo
    echo "## Changes"
    echo
    echo "## Known limitations"
} >"$OUT/release-notes.md"
rm -rf "$WORK"
"$HERE/check-release.sh" "$OUT/release-info.txt" || die "release-info.txt or release-notes.md failed the checks above."

step "Done"
say "disk image: $DMG"
say "SHA-256:    $SHA"
say "folder:     $OUT"
say "notes:      finish $OUT/release-notes.md (changes, known limitations), keeping its first lines."
if [[ "$SIGN_ONLY" == 1 ]]; then
    say "NOT notarized: for your own tests only."
    exit 0
fi
if [[ "$UNSIGNED" == 1 ]]; then
    say "NOT signed with a Developer ID and NOT notarized: macOS blocks it at first open until the person allows it."
else
    say "next (yours): open it on another Mac first (RELEASE-HOWTO, 'Build the signed DMG without iCloud')."
fi
if [[ "$ENABLE_UPDATES" == 1 ]]; then
    say "To offer it to installed copies once it is published, add it to the update feed (docs/release/SPARKLE.md):"
    say "  Tools/release/update-appcast.py --dmg '$DMG' --version $VERSION --build $BUILD_NUMBER --notes-file '$OUT/release-notes.md' --download-url-prefix <where the DMG is published> --appcast <your appcast.xml>"
fi
say "To put it on a draft GitHub pre-release (every release is an early development build):"
say "  Tools/release/publish-github.sh --dmg '$DMG' $VERSION"
