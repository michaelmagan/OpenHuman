#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TAG="pr-screenshots"
usage() {
    cat <<'EOF'
Usage: Tools/ci/publish-render-sweep.sh <render folder> <pull request number> <head sha>

Uploads up to 60 PNGs of a render-sweep folder to the pr-screenshots release as pr-<number>-<file>, removes that
pull request's older uploads and those of closed pull requests, and creates or updates one comment on the pull
request that shows them. Run by the Render Sweep workflows with GH_REPO, GH_TOKEN (contents and pull-requests
write) and RUN_ID set; needs gh and python3.
EOF
}
[[ "${1-}" == -h || "${1-}" == --help ]] && { usage; exit 0; }
[[ $# -eq 3 ]] || { usage >&2; exit 2; }
renders="$1"; pr="$2"; sha="$3"
[[ "$pr" =~ ^[0-9]+$ ]] || { echo "publish-render-sweep: invalid pull request number" >&2; exit 2; }
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo "publish-render-sweep: invalid head sha" >&2; exit 2; }
: "${GH_REPO:?}" "${RUN_ID:?}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
python3 "$ROOT/Tools/ci/render-sweep-comment.py" --renders "$renders" --staging "$work/assets" --pr "$pr" --sha "$sha" \
    --repo "$GH_REPO" --run-id "$RUN_ID" --tag "$TAG" >"$work/body.md"

if ! gh release view "$TAG" >/dev/null 2>&1; then
    gh release create "$TAG" --title "PR screenshots (auto-generated)" --prerelease --target main \
        --notes "Render-sweep PNGs per open pull request, on sample data. Assets are replaced on every sweep; safe to delete after the pull requests close."
fi
shopt -s nullglob
assets=("$work"/assets/*.png)
# Upload first and delete leftovers after, so the comment never points at a deleted image
if (( ${#assets[@]} )); then
    gh release upload "$TAG" "${assets[@]}" --clobber
fi
release_id="$(gh api "repos/$GH_REPO/releases/tags/$TAG" --jq .id)"
open_prs=" $(gh pr list --state open --limit 1000 --json number --jq '.[].number' | tr '\n' ' ') "
keep=" "
for asset in "${assets[@]}"; do keep+="$(basename "$asset") "; done
# Why: one release holds every pull request's PNGs, and a release takes at most 1000 assets
gh api --paginate "repos/$GH_REPO/releases/$release_id/assets" --jq '.[].name' | while read -r name; do
    [[ "$name" =~ ^pr-([0-9]+)- ]] || continue
    owner="${BASH_REMATCH[1]}"
    if [[ "$owner" == "$pr" && "$keep" != *" $name "* ]] || [[ "$owner" != "$pr" && "$open_prs" != *" $owner "* ]]; then
        gh release delete-asset "$TAG" "$name" --yes || echo "publish-render-sweep: could not delete $name"
    fi
done

ids="$(gh api "repos/$GH_REPO/issues/$pr/comments" --paginate \
    --jq '.[] | select(.user.login == "github-actions[bot]" and (.body | startswith("<!-- render-sweep -->"))) | .id')"
comment="${ids%%$'\n'*}"
if [[ -n "$comment" ]]; then
    gh api -X PATCH "repos/$GH_REPO/issues/comments/$comment" -F "body=@$work/body.md" >/dev/null
    echo "publish-render-sweep: updated comment $comment on #$pr with ${#assets[@]} PNGs"
else
    gh pr comment "$pr" --body-file "$work/body.md"
    echo "publish-render-sweep: commented on #$pr with ${#assets[@]} PNGs"
fi
