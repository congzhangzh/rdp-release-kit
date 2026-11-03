#!/bin/bash
# Removes old pre-releases from the release page, so it shows the kit's releases and the
# few pre-releases still in use (聪哥, 2026-11-02: the per-round xrdp-/web-/demo- pre-releases
# cluttered it):
#
#   prune-prereleases.sh [--dry-run] [keep]       keep: the newest per kind, default 3
#
# - Kinds: web, xrdp, pipewire-module-xrdp, mutter, demo (prerelease-tag.sh's names). The
#   newest <keep> of each stay: freerdp-web's kit-release.sh and record-demos.sh take the
#   newest of a kind.
# - An older one goes only if a kit release (<YYYYMMDD>.<N>, not a pre-release) was built
#   from the same kit commit: that release carries the same files. A pre-release of a round
#   that never made a release stays, since its files are nowhere else.
# - Only the release goes; its tag stays, so publish-prerelease.sh's rule holds (a name is
#   never used for a second build).
# - Nothing is lost (聪哥's rule: results are kept): before any deletion, each release's notes
#   and every file whose content (SHA-256) no kit release holds (demo.json, KIT_COMMIT,
#   checksum lists…) go into pruned-<UTC stamp>.tar.gz on the pre-release "prerelease-archive"
#   (made once, never pruned); the deletions start only once that upload checks out.
# Expects GH_TOKEN and GITHUB_REPOSITORY.
set -euo pipefail
DRY=0; [ "${1:-}" = --dry-run ] && { DRY=1; shift; }
KEEP=${1:-3}
REPO=${GITHUB_REPOSITORY:?}
all=$(gh api --paginate "repos/$REPO/releases?per_page=100" \
    -q '.[] | select(.draft | not) | [.tag_name, (.prerelease|tostring), .target_commitish, .published_at, (.id|tostring)] | @tsv')
# kit commits that have a kit release
released=$(awk -F'\t' '$1 ~ /^[0-9]{8}\.[0-9]+$/ && $2 == "false" { print $3 }' <<< "$all" | sort -u)
# the content of every kit release, to know which files are kept elsewhere
digests=$(for t in $(awk -F'\t' '$1 ~ /^[0-9]{8}\.[0-9]+$/ && $2 == "false" { print $1 }' <<< "$all"); do
    gh api "repos/$REPO/releases/tags/$t" -q '.assets[].digest'; done | sort -u)
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
STAMP=$(date -u +%Y%m%d-%H%M%S)
mkdir -p "$WORK/pruned-$STAMP"
todo=()
gone=0 kept=0
for kind in web xrdp pipewire-module-xrdp mutter demo; do
    # newest first; tags <kind>-<YYYYMMDD>.<N>-<kit commit, 12>
    list=$(awk -F'\t' -v k="$kind" '$2 == "true" && $1 ~ ("^" k "-[0-9]{8}\\.[0-9]+-[0-9a-f]{12}$")' <<< "$all" | sort -t$'\t' -k4,4r)
    n=0
    while IFS=$'\t' read -r tag pre commit published id; do
        [ -n "$tag" ] || continue
        n=$((n + 1))
        if [ $n -le "$KEEP" ]; then kept=$((kept + 1)); continue; fi
        short=${tag##*-}
        if grep -q "^$short" <<< "$released"; then
            echo "delete $tag (kit $short has a release)"
            d="$WORK/pruned-$STAMP/$tag"; mkdir -p "$d"
            gh api "repos/$REPO/releases/$id" -q '.body' > "$d/NOTES.md"
            gh api "repos/$REPO/releases/$id" -q '.assets[] | [.name, .digest, (.id|tostring)] | @tsv' |
            while IFS=$'\t' read -r name digest aid; do
                grep -qxF "$digest" <<< "$digests" && continue
                gh api -H "Accept: application/octet-stream" "repos/$REPO/releases/assets/$aid" > "$d/$name"
            done
            todo+=("$id")
            gone=$((gone + 1))
        else
            echo "keep   $tag (no kit release from $short)"
            kept=$((kept + 1))
        fi
    done <<< "$list"
done
tarball="$WORK/pruned-$STAMP.tar.gz"
tar -czf "$tarball" -C "$WORK" "pruned-$STAMP"
echo "leftovers of $gone pre-releases: $(du -h "$tarball" | cut -f1) in pruned-$STAMP.tar.gz"
if [ $DRY = 1 ]; then
    cp "$tarball" "${PRUNE_KEEP:-.}/" 2> /dev/null || true
    echo "would delete $gone pre-releases, kept $kept"
    exit 0
fi
[ $gone -gt 0 ] || { echo "nothing to prune; kept $kept"; exit 0; }
if ! gh api "repos/$REPO/releases/tags/prerelease-archive" --silent 2> /dev/null; then
    gh release create prerelease-archive --repo "$REPO" --prerelease --latest=false \
        --title "Archive of pruned pre-releases" \
        --notes "The notes and the files no kit release holds of the per-round pre-releases (web-, xrdp-, pipewire-module-xrdp-, mutter-, demo-) that build/prune-prereleases.sh took off the release page; one tarball per run. Never pruned itself." > /dev/null
fi
gh release upload prerelease-archive "$tarball" --repo "$REPO" > /dev/null
want=$(sha256sum < "$tarball" | cut -d' ' -f1)
have=$(gh api "repos/$REPO/releases/tags/prerelease-archive" -q ".assets[] | select(.name == \"pruned-$STAMP.tar.gz\") | .digest")
[ "$have" = "sha256:$want" ] || { echo "the archive upload doesn't check out ($have): nothing deleted" >&2; exit 1; }
for id in "${todo[@]}"; do gh api -X DELETE "repos/$REPO/releases/$id" --silent; done
echo "deleted $gone pre-releases (archived in prerelease-archive, pruned-$STAMP.tar.gz), kept $kept"
