#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
DEFAULT_ENTITLEMENTS="$ROOT/Apps/Mail/Entitlements/Mail.entitlements"
ICLOUD_SOURCE="$ROOT/Apps/Mail/Entitlements/Mail-iCloud.entitlements"

usage() {
    cat <<'EOF'
Usage: Tools/release/check-release.sh [options] <path.app | path.dmg | path/release-info.txt>...

Checks a release build of OpenHuman Mail: the early development marker, signature, hardened
runtime, entitlements, no baked-in OAuth client, no developer switches or sample-data launch
arguments anywhere in the app, notarization ticket and Gatekeeper (docs/release/RELEASE-HOWTO.md).
An entitlement that needs a provisioning profile (iCloud, push, keychain groups) must be granted
by the profile embedded in the app, for the app's team, App ID and signing certificate.
Updates: an app carries an update feed and key (SUFeedURL, SUPublicEDKey) only as a Developer ID
build without iCloud entitlements, and Sparkle's XPC services are never in the bundle.
Read-only: it never signs, submits or changes what it checks.
A .dmg is attached read-only and hidden from Finder, checked (with the app inside it), then
detached. A release-info.txt (written by make-dmg.sh) is checked for the marker, and so are the
release-notes.md beside it.

  --pre-notarization     skip the notarization checks (stapled ticket, Gatekeeper). make-dmg.sh
                         uses this before it sends anything to Apple
  --unsigned             an unsigned build (make-dmg.sh --unsigned): the app is ad-hoc signed
                         and nothing is notarized, so skip the Developer ID, timestamp,
                         hardened runtime and notarization checks. Everything else still runs
  --icloud               the app must be signed with the iCloud entitlements
                         (Apps/Mail/Entitlements/Mail-iCloud.entitlements) and embed the
                         provisioning profile that grants them. make-dmg.sh passes it unless it
                         builds with --unsigned or --no-icloud
  --team <TEAMID>        the signatures must carry this team id (default: any Developer ID
                         team, the same everywhere)
  --expect-commit <sha>  Info.plist OHGitCommit must equal this (make-dmg.sh passes the commit
                         it built)
  --allow-dirty          accept an OHGitCommit ending in +dirty (rehearsals only, never a build
                         you hand out)
  --updates <feed|off>   Info.plist SUFeedURL must equal this feed, or with off carry no feed or
                         key (make-dmg.sh passes it)
  --update-key <key>     Info.plist SUPublicEDKey must equal this public key
  --github-release <tag> the published GitHub release must be marked as a pre-release and say
                         "(early development)" in its title (asks GitHub through the gh
                         command)
  -h, --help             show this help

Exit status: 0 when every check passes, 1 when any check fails, 2 for bad arguments.
EOF
}

RELEASE_CHANNEL="early-development"
NOTES_MARKER="Early development build"

# Only Mail-iCloud.entitlements may ask for these, and only with an embedded profile that grants them
ICLOUD_ENTITLEMENTS="com.apple.developer.aps-environment com.apple.developer.icloud-container-environment"
ICLOUD_ENTITLEMENTS+=" com.apple.developer.icloud-container-identifiers com.apple.developer.icloud-services"
ICLOUD_ENTITLEMENTS+=" keychain-access-groups"
ALLOWED_ENTITLEMENTS="$ICLOUD_ENTITLEMENTS"
IDENTITY_ENTITLEMENTS="com.apple.application-identifier com.apple.developer.team-identifier"

# Only Debug and DevTools builds may carry these; a Release build compiles them out
DEVELOPER_NAMES="-UseFakeGmail -UseFakeData -UseFixtureStore -UseFakeCalendar -FakeGmailNotifications
OPENHUMAN_SAFE_MODE write-allowlist OPENHUMAN_DEV_FEEDBACK OPENHUMAN_DEVELOPER OPENHUMAN_HOME
OPENHUMAN_OAUTH_CLIENT_JSON OPENHUMAN_INSECURE_FILE_TOKENS OPENHUMAN_STORE_POLL_ONLY OPENHUMAN_FEEDBACK_DIR
fake-gmail-access-token OpenHumanMail-FakeGmail-"

PRE=0; UNSIGNED=0; EXPECT_ICLOUD=0; TEAM=""; EXPECT_COMMIT=""; ALLOW_DIRTY=0; TARGETS=(); RELEASES=()
EXPECT_FEED=""; EXPECT_KEY=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --pre-notarization) PRE=1; shift ;;
        --unsigned) UNSIGNED=1; PRE=1; shift ;;
        --icloud) EXPECT_ICLOUD=1; shift ;;
        --team) TEAM="${2:-}"; shift 2 ;;
        --expect-commit) EXPECT_COMMIT="${2:-}"; shift 2 ;;
        --allow-dirty) ALLOW_DIRTY=1; shift ;;
        --updates) [[ -n "${2:-}" ]] || { echo "check-release: --updates needs a feed address or off" >&2; exit 2; }
                   EXPECT_FEED="$2"; shift 2 ;;
        --update-key) [[ -n "${2:-}" ]] || { echo "check-release: --update-key needs a public key" >&2; exit 2; }
                      EXPECT_KEY="$2"; shift 2 ;;
        --github-release) [[ -n "${2:-}" ]] || { echo "check-release: --github-release needs a tag" >&2; exit 2; }
                          RELEASES+=("$2"); shift 2 ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "check-release: unknown option $1 (see --help)" >&2; exit 2 ;;
        *) TARGETS+=("$1"); shift ;;
    esac
done
[[ ${#TARGETS[@]} -gt 0 || ${#RELEASES[@]} -gt 0 ]] \
    || { echo "check-release: give a .app, .dmg or release-info.txt to check, or --github-release (see --help)" >&2; exit 2; }
[[ "$UNSIGNED" == 0 || -z "$TEAM" ]] || { echo "check-release: --unsigned builds carry no team, so --team does not apply" >&2; exit 2; }
[[ "$UNSIGNED" == 0 || "$EXPECT_ICLOUD" == 0 ]] \
    || { echo "check-release: --unsigned builds carry no iCloud entitlements, so --icloud does not apply" >&2; exit 2; }
[[ -z "$EXPECT_KEY" || ( -n "$EXPECT_FEED" && "$EXPECT_FEED" != off ) ]] \
    || { echo "check-release: --update-key goes with --updates <feed>" >&2; exit 2; }
if [[ -n "$EXPECT_FEED" && "$EXPECT_FEED" != off ]]; then
    [[ "$UNSIGNED" == 0 ]] || { echo "check-release: --unsigned builds never update, so --updates <feed> does not apply" >&2; exit 2; }
    [[ "$EXPECT_ICLOUD" == 0 ]] || { echo "check-release: updating builds are made without iCloud, so --updates <feed> and --icloud do not go together" >&2; exit 2; }
fi

FAILS=0; WARNS=0; MOUNTS=""
ok()   { printf '  ok    %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; FAILS=$((FAILS + 1)); }
warn() { printf '  warn  %s\n' "$*"; WARNS=$((WARNS + 1)); }
note() { printf '        %s\n' "$*"; }
has_word() { case " $1 " in *" $2 "*) return 0 ;; *) return 1 ;; esac; }

cleanup() {
    local m
    for m in $MOUNTS; do hdiutil detach "$m" -quiet >/dev/null 2>&1 || hdiutil detach "$m" -force -quiet >/dev/null 2>&1 || true; done
}
trap cleanup EXIT

plist_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true; }

plist_keys() { { plutil -p "$1" 2>/dev/null || true; } | sed -n 's/^  "\([^"]*\)" =>.*/\1/p'; }

signed_entitlement_keys() {
    local tmp; tmp="$(mktemp)"
    codesign -d --entitlements - --xml "$1" >"$tmp" 2>/dev/null || true
    if [[ -s "$tmp" ]]; then plist_keys "$tmp"; fi
    rm -f "$tmp"
    return 0
}

needs_profile() { [[ "$1" != com.apple.security.* ]]; }

check_entitlements_source() {
    local keys key before
    if [[ -f "$DEFAULT_ENTITLEMENTS" ]]; then
        keys="$(plist_keys "$DEFAULT_ENTITLEMENTS")"
        for key in $keys; do
            bad "entitlements file Apps/Mail/Entitlements/Mail.entitlements asks for $key. It must stay empty: ad-hoc, CI and contributor builds sign with it and have no provisioning profile"
        done
        [[ -n "$keys" ]] || ok "entitlements file Apps/Mail/Entitlements/Mail.entitlements: no keys"
    fi
    [[ -f "$ICLOUD_SOURCE" ]] || return 0
    before="$FAILS"
    for key in $(plist_keys "$ICLOUD_SOURCE"); do
        has_word "$ALLOWED_ENTITLEMENTS $IDENTITY_ENTITLEMENTS" "$key" \
            || bad "entitlements file Apps/Mail/Entitlements/Mail-iCloud.entitlements asks for $key, which ALLOWED_ENTITLEMENTS in $0 does not allow"
    done
    [[ "$FAILS" != "$before" ]] || ok "entitlements file Apps/Mail/Entitlements/Mail-iCloud.entitlements: only allowed keys"
}

APP_KEYS=""
check_signed_entitlements() {
    local code="$1" label="$2" main="$3" keys key
    keys="$(signed_entitlement_keys "$code")"
    [[ "$main" == 0 ]] || APP_KEYS=" $(printf '%s ' $keys)"
    if [[ -z "$keys" ]]; then ok "$label: no entitlements in the signature"; return 0; fi
    for key in $keys; do
        if [[ "$key" == com.apple.security.get-task-allow ]]; then
            bad "$label: signed with com.apple.security.get-task-allow (debugger attach). Never in a release. Apple's notary service refuses it"
        elif has_word "$ALLOWED_ENTITLEMENTS" "$key"; then
            if [[ "$main" == 1 ]]; then ok "$label: entitlement $key (allowed)"
            else bad "$label: entitlement $key needs a provisioning profile; only the app itself may carry it"; fi
        elif has_word "$IDENTITY_ENTITLEMENTS" "$key"; then note "$label: identity entry $key (ties the signature to its provisioning profile)"
        else bad "$label: entitlement $key is broader than this app needs (ALLOWED_ENTITLEMENTS in $0)"; fi
    done
}

check_profile() {
    local app="$1" plist="$1/Contents/Info.plist" profile="$1/Contents/embedded.provisionprofile" needs="" key
    local team tmp out rc=0 line group granted cert=()
    for key in $APP_KEYS; do
        if needs_profile "$key"; then needs="$needs $key"; fi
    done
    if [[ "$EXPECT_ICLOUD" == 1 ]]; then
        for key in $ICLOUD_ENTITLEMENTS $IDENTITY_ENTITLEMENTS; do
            has_word "$APP_KEYS" "$key" || bad "app: built for iCloud, but the signature lacks $key"
        done
        [[ -f "$profile" ]] || bad "app: built for iCloud, but Contents/embedded.provisionprofile is missing"
    fi
    if [[ -z "$needs" ]]; then
        if [[ -f "$profile" ]]; then warn "app: embeds a provisioning profile that no entitlement needs (macOS still checks it at every launch)"
        else ok "app: no entitlement needs a provisioning profile"; fi
        return 0
    fi
    if [[ "$UNSIGNED" == 1 ]]; then
        bad "app: signed with${needs}, which need a provisioning profile. An ad-hoc signed app cannot have one: leave them out (make-dmg.sh --unsigned does)"
        return 0
    fi
    if [[ ! -f "$profile" ]]; then
        [[ "$EXPECT_ICLOUD" == 1 ]] || bad "app: signed with${needs}, which need a provisioning profile, but Contents/embedded.provisionprofile is missing. macOS would refuse to launch it"
        return 0
    fi
    team="$TEAM"
    [[ -n "$team" ]] || team="$({ codesign -dvvv "$app" 2>&1 || true; } | sed -n 's/^TeamIdentifier=//p' | head -1)"
    if [[ -z "$team" || "$team" == "not set" ]]; then bad "app: the provisioning profile cannot be compared: the signature names no team"; return 0; fi
    command -v python3 >/dev/null 2>&1 || { bad "app: python3 is needed to compare the provisioning profile"; return 0; }
    tmp="$(mktemp -d)"
    codesign -d --entitlements - --xml "$app" >"$tmp/entitlements.plist" 2>/dev/null || true
    codesign -d --extract-certificates="$tmp/certificate" "$app" >/dev/null 2>&1 || true
    if [[ -f "$tmp/certificate0" ]]; then cert=(--certificate "$tmp/certificate0")
    else note "app: signing certificate not compared with the profile (the signature has none)"; fi
    out="$(python3 -B "$HERE/provisioning.py" --profile "$profile" --entitlements "$tmp/entitlements.plist" --team "$team" \
        --bundle-id "$(plist_value "$plist" CFBundleIdentifier)" ${cert[@]+"${cert[@]}"} 2>&1)" || rc=$?
    if [[ "$rc" == 0 ]]; then ok "app: embedded $out"
    else
        while IFS= read -r line; do [[ -z "$line" ]] || bad "app: provisioning profile: $line"; done <<<"$out"
    fi
    if has_word "$APP_KEYS" keychain-access-groups; then
        group="$(plist_value "$plist" OHKeychainAccessGroup)"
        granted="$(plutil -extract keychain-access-groups json -o - "$tmp/entitlements.plist" 2>/dev/null || true)"
        if [[ -n "$group" && "$granted" == *"\"$group\""* ]]; then ok "app: Info.plist OHKeychainAccessGroup $group is granted by the signature"
        else bad "app: Info.plist OHKeychainAccessGroup is '${group:-missing}', which keychain-access-groups ($granted) does not grant. The app would keep its Keychain items unshared"; fi
    fi
    rm -rf "$tmp"
}

check_developer_names() {
    local app="$1" patterns found f hits
    patterns="$(mktemp)"; found="$(mktemp)"
    printf '%s\n' $DEVELOPER_NAMES >"$patterns"
    while IFS= read -r -d '' f; do
        hits="$(LC_ALL=C grep -a -o -F -f "$patterns" "$f" 2>/dev/null | LC_ALL=C sort -u | tr '\n' ' ' || true)"
        [[ -z "$hits" ]] || printf '%s: %s\n' "${f#"$app"/}" "${hits% }" >>"$found"
    done < <(find "$app/Contents" -type f -print0 2>/dev/null)
    if [[ -s "$found" ]]; then
        bad "developer switches or sample-data launch arguments in the app. Only Debug and DevTools builds may carry them; hand out a Release build:"
        sed 's/^/          /' "$found"
    else
        ok "no developer switches or sample-data launch arguments in the app"
    fi
    rm -f "$patterns" "$found"
}

is_public_key() {
    python3 -I -c 'import base64, sys; sys.exit(0 if len(base64.b64decode(sys.argv[1], validate=True)) == 32 else 1)' "$1" \
        >/dev/null 2>&1
}

# Why: Mail is not sandboxed, so Sparkle installs through Autoupdate. Its XPC services would only add sandboxed helpers
# with entitlements of their own, and a feed in any build but a Developer ID one would offer updates nobody can verify
check_updates() {
    local app="$1" plist="$1/Contents/Info.plist" sparkle="$1/Contents/Frameworks/Sparkle.framework" feed key flag services
    if [[ -d "$sparkle" ]]; then
        services="$(find "$sparkle" -name '*.xpc' -prune -print 2>/dev/null | sed "s|^$app/||")"
        if [[ -n "$services" ]]; then
            bad "Sparkle's XPC services are in the app ($(printf '%s ' $services)). Mail is not sandboxed and never uses them; make-dmg.sh leaves them out"
        else
            ok "Sparkle.framework without XPC services"
        fi
    fi
    for flag in SUEnableDownloaderService SUEnableInstallerLauncherService; do
        case "$(plist_value "$plist" "$flag")" in
            true|YES|1) bad "Info.plist turns on $flag, which needs the XPC services a non-sandboxed app leaves out" ;;
        esac
    done
    feed="$(plist_value "$plist" SUFeedURL)"; key="$(plist_value "$plist" SUPublicEDKey)"
    if [[ -z "$feed" && -z "$key" ]]; then
        if [[ -n "$EXPECT_FEED" && "$EXPECT_FEED" != off ]]; then bad "built with --enable-updates, but Info.plist has no SUFeedURL or SUPublicEDKey"
        else ok "updates off: no SUFeedURL or SUPublicEDKey, so the app never checks for updates"; fi
        return 0
    fi
    if [[ "$EXPECT_FEED" == off ]]; then
        bad "Info.plist carries an update feed or key (SUFeedURL '$feed'), but this build was made without --enable-updates"
    elif [[ -n "$EXPECT_FEED" && "$feed" != "$EXPECT_FEED" ]]; then
        bad "Info.plist SUFeedURL is '$feed', expected $EXPECT_FEED"
    fi
    if [[ -n "$EXPECT_KEY" && "$key" != "$EXPECT_KEY" ]]; then bad "Info.plist SUPublicEDKey is '$key', expected $EXPECT_KEY"; fi
    [[ -d "$sparkle" ]] || bad "Info.plist names an update feed, but the app has no Sparkle.framework"
    if [[ -z "$key" ]] || ! is_public_key "$key"; then bad "Info.plist SUPublicEDKey is '${key:-empty}', not a base64 EdDSA public key of 32 bytes"; fi
    case "$feed" in
        https://?*) ok "update feed $feed" ;;
        http://127.0.0.1[:/]*|http://localhost[:/]*)
            if [[ "$PRE" == 1 && "$UNSIGNED" == 0 ]]; then warn "update feed $feed is on this Mac: a staged update test only, never hand this build out"
            else bad "update feed $feed is on this Mac; a notarized build must read an https:// feed"; fi ;;
        "") bad "Info.plist has SUPublicEDKey but no SUFeedURL" ;;
        *) bad "update feed '$feed' is not https://" ;;
    esac
    if [[ "$UNSIGNED" == 1 ]]; then bad "an unsigned build carries an update feed; only Developer ID builds may update"; fi
    for flag in $ICLOUD_ENTITLEMENTS; do
        if has_word "$APP_KEYS" "$flag"; then
            bad "the app updates itself and is signed with $flag. Updating builds are made with --no-icloud, so every update keeps the entitlements of the first installed build"
            break
        fi
    done
}

FIRST_TEAM=""
check_signature() {
    local path="$1" label="$2" needs_runtime="$3" out authority team
    if ! out="$(codesign -dvvv "$path" 2>&1)"; then
        bad "$label: not signed ($(printf '%s\n' "$out" | tail -1))"; return 0
    fi
    authority="$(printf '%s\n' "$out" | sed -n 's/^Authority=//p' | head -1)"
    team="$(printf '%s\n' "$out" | sed -n 's/^TeamIdentifier=//p' | head -1)"
    if [[ "$UNSIGNED" == 1 ]]; then
        if printf '%s\n' "$out" | grep -q '^Signature=adhoc'; then ok "$label: ad-hoc signature (unsigned build: no Developer ID, not notarized)"
        else note "$label: signed by '${authority:-unknown}' (checked as an unsigned build)"; fi
        return 0
    fi
    case "$authority" in
        "Developer ID Application: "*) ok "$label: signed with a Developer ID Application certificate (team $team)" ;;
        "") bad "$label: ad-hoc signature, not Developer ID (Apple only notarizes Developer ID builds)" ;;
        *) bad "$label: signed with '${authority%%:*}', not 'Developer ID Application' (Apple only notarizes Developer ID builds)" ;;
    esac
    if [[ -n "$TEAM" && "$team" != "$TEAM" ]]; then bad "$label: team $team, expected $TEAM"; fi
    if [[ -z "$FIRST_TEAM" ]]; then FIRST_TEAM="$team"
    elif [[ "$team" != "$FIRST_TEAM" ]]; then bad "$label: team $team differs from $FIRST_TEAM elsewhere in this release"; fi
    if printf '%s\n' "$out" | grep -q '^Timestamp='; then ok "$label: secure timestamp"
    else bad "$label: no secure timestamp (sign with --timestamp, the notary service requires it)"; fi
    if [[ "$needs_runtime" == 1 ]]; then
        if printf '%s\n' "$out" | grep -q '^CodeDirectory .*flags=[^ ]*runtime'; then ok "$label: hardened runtime on"
        else bad "$label: hardened runtime off (sign with --options runtime / ENABLE_HARDENED_RUNTIME=YES)"; fi
    fi
}

check_app() {
    local app="${1%/}" plist exe id ver build commit channel nested f desc rel count=0 dr out rc
    echo "check-release: app $app"
    plist="$app/Contents/Info.plist"
    [[ -f "$plist" ]] || { bad "no Contents/Info.plist: not an app bundle"; return 0; }
    exe="$app/Contents/MacOS/$(plist_value "$plist" CFBundleExecutable)"
    [[ -f "$exe" ]] || { bad "main executable missing ($exe)"; return 0; }

    id="$(plist_value "$plist" CFBundleIdentifier)"; ver="$(plist_value "$plist" CFBundleShortVersionString)"
    build="$(plist_value "$plist" CFBundleVersion)"; commit="$(plist_value "$plist" OHGitCommit)"
    channel="$(plist_value "$plist" OHReleaseChannel)"
    note "bundle id $id, version $ver ($build), commit ${commit:-none}, architectures $(lipo -archs "$exe" 2>/dev/null || echo unknown)"

    if [[ "$channel" == "$RELEASE_CHANNEL" ]]; then
        ok "early development build (OHReleaseChannel $channel)"
    else
        bad "OHReleaseChannel is '${channel:-missing}': every release must be marked as an early development build (OH_RELEASE_CHANNEL = $RELEASE_CHANNEL in Apps/Mail/Config/Version.xcconfig)"
    fi

    # A build that leaves this Mac never carries an OAuth client; values are never printed
    if [[ -n "$(plist_value "$plist" OHGoogleClientID)" || -n "$(plist_value "$plist" OHGoogleClientSecret)" ]]; then
        bad "Info.plist carries a Google OAuth client (OHGoogleClientID/OHGoogleClientSecret not empty). A shared build must not: people import their own client in onboarding. Build with Tools/release/make-dmg.sh, which forces both empty"
    else
        ok "no Google OAuth client in Info.plist (people import their own in onboarding)"
    fi
    check_developer_names "$app"

    case "$commit" in
        ""|unknown) bad "OHGitCommit is '${commit:-empty}': the build does not say which commit it is" ;;
        *+dirty) if [[ "$ALLOW_DIRTY" == 1 ]]; then warn "built from uncommitted changes ($commit): rehearsal only, do not hand it out"
                 else bad "built from uncommitted changes ($commit). Commit first, or pass --allow-dirty for a rehearsal"; fi ;;
        *) ok "built from commit $commit" ;;
    esac
    if [[ -n "$EXPECT_COMMIT" && "$commit" != "$EXPECT_COMMIT" ]]; then bad "OHGitCommit $commit, expected $EXPECT_COMMIT"; fi

    if out="$(codesign --verify --deep --strict --verbose=2 "$app" 2>&1)"; then ok "codesign --verify --deep --strict"
    else bad "codesign --verify --deep --strict failed:"; printf '%s\n' "$out" | sed 's/^/          /' | tail -8; fi

    check_signature "$app" "app" 1
    check_entitlements_source
    check_signed_entitlements "$app" "app" 1
    check_profile "$app"
    check_updates "$app"

    nested="$(mktemp)"
    find "$app/Contents" -type f \( -perm -u+x -o -name '*.dylib' -o -name '*.so' \) ! -path "$exe" >"$nested" 2>/dev/null || true
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        desc="$(file -b "$f" 2>/dev/null || true)"
        case "$desc" in *Mach-O*) ;; *) continue ;; esac
        count=$((count + 1)); rel="${f#"$app"/}"
        case "$desc" in *executable*) check_signature "$f" "$rel" 1 ;; *) check_signature "$f" "$rel" 0 ;; esac
        check_signed_entitlements "$f" "$rel" 0
    done <"$nested"
    rm -f "$nested"
    if [[ "$count" == 0 ]]; then ok "no nested code besides the main executable (the packages link statically)"
    else note "$count nested piece(s) of code checked"; fi

    dr="$({ codesign -d -r- "$app" 2>&1 || true; } | sed -n 's/^designated => //p')"
    note "designated requirement (should match the previous release, or Keychain access is asked again):"
    note "  ${dr:-unknown}"

    if [[ "$PRE" == 1 ]]; then note "notarization checks skipped ($([[ "$UNSIGNED" == 1 ]] && echo --unsigned || echo --pre-notarization))"; return 0; fi
    if xcrun stapler validate -q "$app" >/dev/null 2>&1; then ok "notarization ticket stapled (stapler validate)"
    else bad "no valid stapled ticket (xcrun stapler validate failed: no ticket, or no internet access)"; fi
    rc=0; out="$(spctl --assess --type execute --verbose=4 "$app" 2>&1)" || rc=$?
    if [[ "$rc" == 0 ]] && printf '%s\n' "$out" | grep -q 'source=Notarized Developer ID'; then
        ok "Gatekeeper accepts it (source=Notarized Developer ID)"
    else
        bad "Gatekeeper does not accept it as notarized (spctl exit $rc):"; printf '%s\n' "$out" | sed 's/^/          /' | tail -4
    fi
}

check_dmg() {
    local dmg="$1" out rc mnt apps link
    echo "check-release: disk image $dmg"
    [[ -f "$dmg" ]] || { bad "no such file"; return 0; }
    if [[ "$UNSIGNED" == 1 ]]; then
        note "disk image not signed (unsigned build)"
    else
        if out="$(codesign --verify --strict --verbose=2 "$dmg" 2>&1)"; then ok "codesign --verify --strict"
        else bad "codesign --verify --strict failed:"; printf '%s\n' "$out" | sed 's/^/          /' | tail -6; fi
        check_signature "$dmg" "dmg" 0
    fi
    if [[ "$PRE" == 0 ]]; then
        if xcrun stapler validate -q "$dmg" >/dev/null 2>&1; then ok "notarization ticket stapled to the dmg (stapler validate)"
        else bad "no valid stapled ticket on the dmg (xcrun stapler validate failed: no ticket, or no internet access)"; fi
        rc=0; out="$(spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg" 2>&1)" || rc=$?
        if [[ "$rc" == 0 ]] && printf '%s\n' "$out" | grep -q 'source=Notarized Developer ID'; then ok "Gatekeeper accepts the dmg (source=Notarized Developer ID)"
        elif [[ "$rc" == 2 ]]; then warn "spctl did not accept the disk-image arguments on this macOS. Open the dmg on another Mac instead (RELEASE-HOWTO, 'Build the signed DMG without iCloud')"
        else bad "Gatekeeper does not accept the dmg as notarized (spctl exit $rc):"; printf '%s\n' "$out" | sed 's/^/          /' | tail -4; fi
    fi

    mnt="$(mktemp -d)"
    if ! hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$dmg" >/dev/null 2>&1; then
        bad "could not attach the dmg read-only"; rmdir "$mnt" 2>/dev/null || true; return 0
    fi
    MOUNTS="$MOUNTS $mnt"
    link="$(readlink "$mnt/Applications" 2>/dev/null || true)"
    if [[ "$link" == /Applications ]]; then ok "dmg has the Applications shortcut"; else warn "dmg has no Applications shortcut"; fi
    apps="$(find "$mnt" -maxdepth 1 -name '*.app' -type d)"
    case "$(printf '%s\n' "$apps" | grep -c . || true)" in
        1) check_app "$apps" ;;
        0) bad "no .app at the top of the dmg" ;;
        *) bad "more than one .app at the top of the dmg" ;;
    esac
    hdiutil detach "$mnt" -quiet >/dev/null 2>&1 || hdiutil detach "$mnt" -force -quiet >/dev/null 2>&1 || true
    MOUNTS="${MOUNTS/ $mnt/}"
    rmdir "$mnt" 2>/dev/null || true
}

check_release_info() {
    local info="$1" version channel prerelease label expected notes
    echo "check-release: release record $info"
    [[ -f "$info" ]] || { bad "no such file"; return 0; }
    version="$(sed -n 's/^version=//p' "$info" | head -1)"
    channel="$(sed -n 's/^channel=//p' "$info" | head -1)"
    prerelease="$(sed -n 's/^prerelease=//p' "$info" | head -1)"
    label="$(sed -n 's/^label=//p' "$info" | head -1)"
    if [[ "$(sed -n 's/^updates=//p' "$info" | head -1)" == yes ]]; then
        if grep -qx 'signing=developer-id' "$info" && grep -qx 'icloud=no' "$info"; then ok "updates on: a Developer ID build without iCloud"
        else bad "updates=yes needs signing=developer-id and icloud=no"; fi
    fi
    if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then ok "version $version"
    else bad "version is '${version:-missing}', not three numbers such as 0.1.0"; fi
    if [[ "$channel" == "$RELEASE_CHANNEL" ]]; then ok "channel $channel"
    else bad "channel is '${channel:-missing}': every release is an early development build (channel=$RELEASE_CHANNEL)"; fi
    if [[ "$prerelease" == yes ]]; then ok "marked as a pre-release (prerelease=yes)"
    else bad "prerelease is '${prerelease:-missing}': every release is published as a GitHub pre-release (prerelease=yes)"; fi
    expected="$version (${RELEASE_CHANNEL//-/ })"
    if [[ "$label" == "$expected" ]]; then ok "label $label"
    else bad "label is '${label:-missing}', expected '$expected'"; fi
    notes="$(dirname "$info")/release-notes.md"
    if [[ ! -f "$notes" ]]; then warn "no release-notes.md beside it. The notes you publish must say \"$NOTES_MARKER\""
    elif grep -qF "$NOTES_MARKER" "$notes"; then ok "release notes say it is an early development build"
    else bad "release-notes.md does not say \"$NOTES_MARKER\""; fi
}

check_github_release() {
    local tag="$1" out prerelease title
    echo "check-release: GitHub release $tag"
    command -v gh >/dev/null 2>&1 || { bad "the gh command (GitHub CLI) is not installed"; return 0; }
    if ! out="$(gh release view "$tag" --json isPrerelease,name --jq '[.isPrerelease, .name] | @tsv' 2>&1)"; then
        bad "gh release view $tag failed: $(printf '%s\n' "$out" | tail -1)"; return 0
    fi
    prerelease="${out%%$'\t'*}"; title="${out#*$'\t'}"
    if [[ "$prerelease" == true ]]; then ok "GitHub release $tag is marked as a pre-release"
    else bad "GitHub release $tag is not marked as a pre-release (fix: gh release edit $tag --prerelease)"; fi
    case "$title" in
        *"(${RELEASE_CHANNEL//-/ })"*) ok "GitHub release $tag title: $title" ;;
        *) bad "GitHub release $tag title '$title' does not say (${RELEASE_CHANNEL//-/ })" ;;
    esac
}

for t in ${TARGETS[@]+"${TARGETS[@]}"}; do
    case "$t" in
        *.app|*.app/) [[ -d "$t" ]] || { echo "check-release: no such app: $t" >&2; exit 2; }; check_app "$t" ;;
        *.dmg) check_dmg "$t" ;;
        *release-info.txt) check_release_info "$t" ;;
        *) echo "check-release: expected a .app, a .dmg or a release-info.txt: $t" >&2; exit 2 ;;
    esac
done
for r in ${RELEASES[@]+"${RELEASES[@]}"}; do check_github_release "$r"; done

if [[ "$FAILS" -gt 0 ]]; then echo "check-release: $FAILS check(s) failed, $WARNS warning(s)"; exit 1; fi
echo "check-release: all checks passed ($WARNS warning(s))"
