#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 1
EXCEPTIONS_FILE="Tools/ci/import-exceptions.txt"
violations=0
fail() { echo "check-imports: $*"; violations=$((violations + 1)); }

is_exception() {
    [[ -f "$EXCEPTIONS_FILE" ]] || return 1
    local glob module
    while read -r glob module; do
        [[ -z "$glob" || "$glob" == \#* ]] && continue
        # shellcheck disable=SC2053
        [[ "$1" == $glob && "$2" == "$module" ]] && return 0
    done < "$EXCEPTIONS_FILE"
    return 1
}

DATA_LAYER="OpenHumanCore OpenHumanLinks OpenHumanStore OpenHumanGmail OpenHumanSync OpenHumanCLI OpenHumanCloudSync"
for manifest in Packages/*/Package.swift; do
    pkg="$(basename "$(dirname "$manifest")")"
    head -1 "$manifest" | grep -qx '// swift-tools-version: 6.4' || fail "$manifest: first line must be '// swift-tools-version: 6.4'"
    grep -q '\.macOS(\.v26)' "$manifest" || fail "$manifest: platforms must include .macOS(.v26)"
    if [[ "$pkg" != "OpenHumanCLI" ]]; then
        grep -q '\.iOS(\.v27)' "$manifest" || fail "$manifest: platforms must include .iOS(.v27)"
    fi
    if [[ " $DATA_LAYER " == *" $pkg "* ]]; then
        grep -nE 'OpenHumanMail(Core|UI)|OpenHumanAI' "$manifest" | sed "s|^|$manifest:|" | while read -r line; do
            echo "check-imports: data-layer manifest references an app-layer package: $line"
        done | grep -q . && fail "$manifest: data-layer packages never depend on app-layer packages"
    fi
    case "$pkg" in
        OpenHumanCore|OpenHumanLinks)
            grep -q '\.package(' "$manifest" && fail "$manifest: $pkg must have no package dependencies" ;;
    esac
done

APPLE_SYSTEM="Foundation Synchronization os Dispatch Darwin Glibc"
SYSTEM_SERVICES="CoreSpotlight Security UniformTypeIdentifiers UserNotifications"
allowed_imports() {
    local pkg="$1" target="$2"
    case "$pkg/$target" in
        OpenHumanCore/OpenHumanCore)            echo "$APPLE_SYSTEM" ;;
        OpenHumanCore/OpenHumanCoreTests)       echo "$APPLE_SYSTEM Testing XCTest OpenHumanCore" ;;
        OpenHumanLinks/OpenHumanLinks)          echo "Foundation" ;;
        OpenHumanLinks/OpenHumanLinksTests)     echo "Foundation Testing XCTest OpenHumanLinks" ;;
        OpenHumanMailCore/MailModel)            echo "$APPLE_SYSTEM Observation OpenHumanCore" ;;
        OpenHumanMailCore/MailTheme)            echo "$APPLE_SYSTEM" ;;
        OpenHumanCloudSync/OpenHumanCloudSync)  echo "$APPLE_SYSTEM SQLite3 Crypto OpenHumanCore" ;;
        OpenHumanCloudSync/OpenHumanCloudSyncTesting) echo "$APPLE_SYSTEM OpenHumanCore OpenHumanCloudSync" ;;
        OpenHumanMailLive/MailSystem)           echo "$APPLE_SYSTEM $SYSTEM_SERVICES MailModel OpenHumanCore" ;;
        OpenHumanMailLive/MailSystemTests)      echo "$APPLE_SYSTEM $SYSTEM_SERVICES Testing MailModel MailSystem" ;;
        *)                                      echo "*" ;;
    esac
}
forbidden_imports() {
    local pkg="$1" target="$2"
    local data="OpenHumanStore OpenHumanStoreTesting OpenHumanGmail OpenHumanMIME OpenHumanGmailApple OpenHumanGmailTesting OpenHumanSync GRDB"
    local app="MailModel MailActions MailFeatures MailRender MailTheme MailFakes MailUI MailUIMac OpenHumanAI OpenHumanAIApple OpenHumanAIMLX OpenHumanAITesting"
    case "$pkg" in
        OpenHumanStore)  echo "OpenHumanGmail OpenHumanMIME OpenHumanGmailApple OpenHumanGmailTesting OpenHumanSync $app" ;;
        OpenHumanGmail)
            case "$target" in
                OpenHumanMIME|OpenHumanMIMETests) echo "OpenHumanGmail OpenHumanGmailApple OpenHumanGmailTesting OpenHumanStore OpenHumanSync $app" ;;
                *) echo "OpenHumanStore OpenHumanStoreTesting OpenHumanSync $app" ;;
            esac ;;
        OpenHumanSync)   echo "OpenHumanGmailApple $app" ;;
        OpenHumanCLI)    echo "OpenHumanGmailApple $app" ;;
        OpenHumanMailCore|OpenHumanMailUI)
            if [[ "$target" == "MailFakes" ]]; then echo "$data MailFeatures MailUI MailUIMac"; else echo "$data"; fi ;;
        OpenHumanAI|OpenHumanAIMLX) echo "$data" ;;
        OpenHumanSemanticIndex) echo "$data" ;;
        OpenHumanCloudSync) echo "$data $app" ;;
        OpenHumanMailLive)
            case "$target" in
                *Tests) echo "AppKit UIKit MailUIMac" ;;
                *) echo "AppKit UIKit MailUIMac OpenHumanGmailTesting OpenHumanStoreTesting OpenHumanSemanticIndexTesting" ;;
            esac ;;
        *) echo "" ;;
    esac
}

MLX_MODULES="MLX MLXNN MLXOptimizers MLXRandom MLXFast MLXFFT MLXLinalg Cmlx MLXLLM MLXVLM MLXLMCommon MLXEmbedders MLXRerankers MLXFoundationModels MLXGuidedGeneration MLXCXGrammar BenchmarkHelpers IntegrationTestHelpers"
NETWORK_MODEL_MODULES="MLXHuggingFace HuggingFace Hub Tokenizers Transformers"
while IFS= read -r file; do
    rel="${file#./}"
    pkg="$(echo "$rel" | cut -d/ -f2)"
    target="$(echo "$rel" | cut -d/ -f4)"
    allowed="$(allowed_imports "$pkg" "$target")"
    forbidden="$(forbidden_imports "$pkg" "$target") $NETWORK_MODEL_MODULES"
    if [[ "$pkg/$target" != "OpenHumanAIMLX/OpenHumanAIMLXRuntime" ]]; then forbidden="$forbidden $MLX_MODULES"; fi
    while IFS= read -r line; do
        module="$(echo "$line" | sed -E 's/^[[:space:]]*(@testable[[:space:]]+|@_exported[[:space:]]+|(public|package|internal|private|fileprivate)[[:space:]]+)*import[[:space:]]+((struct|class|enum|protocol|func|var|let|typealias)[[:space:]]+)?([A-Za-z0-9_]+).*/\5/')"
        [[ -z "$module" ]] && continue
        if [[ "$module" == "GRDB" && "$pkg" != "OpenHumanStore" ]] && ! is_exception "$rel" GRDB; then
            fail "$rel: imports GRDB; only OpenHumanStore may (add a documented exception to $EXCEPTIONS_FILE if truly needed)"
            continue
        fi
        if [[ " $forbidden " == *" $module "* ]] && ! is_exception "$rel" "$module"; then
            fail "$rel: $pkg/$target must not import $module"
        fi
        if [[ "$allowed" != "*" && " $allowed " != *" $module "* ]] && ! is_exception "$rel" "$module"; then
            fail "$rel: $pkg/$target may import only: $allowed (found $module)"
        fi
    done < <(grep -E '^[[:space:]]*(@testable[[:space:]]+|@_exported[[:space:]]+|(public|package|internal|private|fileprivate)[[:space:]]+)*import[[:space:]]' "$file")
done < <(find ./Packages -path '*/.build' -prune -o -name '*.swift' -path '*/Sources/*' -print -o -name '*.swift' -path '*/Tests/*' -print)

# Why: the shared app glue builds for iOS, which has no Process to run an assistant CLI
while IFS= read -r file; do
    awk '/^[[:space:]]*import[[:space:]]+OpenHumanAIAgentCLI/ && prev != "#if os(macOS)" { bad = 1 } { prev = $0 } END { exit bad }' \
        "$file" || fail "$file: import OpenHumanAIAgentCLI only directly inside #if os(macOS)"
done < <(grep -rlE --include='*.swift' '^[[:space:]]*import[[:space:]]+OpenHumanAIAgentCLI' Packages/OpenHumanMailLive/Sources)

if command -v python3 >/dev/null 2>&1; then
    python3 Tools/ci/gen-public-inits.py --check || fail "contract public inits are stale: run Tools/ci/gen-public-inits.py"
else
    echo "check-imports: python3 not found; skipping the generated-init check"
fi

if (( violations > 0 )); then
    echo "check-imports: $violations violation(s)"
    exit 1
fi
echo "check-imports: OK"
