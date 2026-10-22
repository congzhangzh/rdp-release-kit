#!/bin/bash
# Publishes a pre-release once, complete, and never again
# (docs/RELEASE.md, "Frozen releases"):
#
#   publish-prerelease.sh <tag> <title> <notes> <file>...
#
# - A published release with this tag: left as it is; nothing is uploaded.
# - A tag without a release (its release was deleted): refused, because a
#   name is never used for a second build.
# - Otherwise any draft an earlier, failed run left is deleted, a new draft
#   gets every file, and only then is it published, at GITHUB_SHA. The
#   published release must then hold exactly these files: the same names,
#   and the same SHA-256 (GitHub's digest of each asset).
#
# Expects GH_TOKEN, GITHUB_REPOSITORY and GITHUB_SHA (or KIT_SHA, as
# prerelease-tag.sh).
set -euo pipefail

TAG=$1 TITLE=$2 NOTES=$3
shift 3
REPO=${GITHUB_REPOSITORY:?} SHA=${KIT_SHA:-${GITHUB_SHA:?}}
[ $# -gt 0 ] || { echo "publish-prerelease.sh: no files for $TAG" >&2; exit 1; }
for f in "$@"; do
    [ -f "$f" ] || { echo "publish-prerelease.sh: $f: no such file" >&2; exit 1; }
done

# the drafts of this tag, by id (drafts have no tag yet, only its name)
drafts() {
    gh api --paginate "repos/$REPO/releases?per_page=100" \
        -q ".[] | select(.draft and .tag_name == \"$TAG\") | .id"
}

# 0: it exists; 1: GitHub says 404. Any other failure (the network, the
# token) stops here, so it is never taken for "not published yet".
exists() {
    local err
    err=$(gh api "repos/$REPO/$1" --silent 2>&1) && return 0
    grep -q 'HTTP 404' <<< "$err" && return 1
    echo "publish-prerelease.sh: $1: $err" >&2
    exit 1
}

if exists "releases/tags/$TAG"; then
    echo "$TAG is published already: left as it is"
    exit 0
fi
if exists "git/ref/tags/$TAG"; then
    echo "$TAG: the tag exists without a release; a name is never used twice" >&2
    exit 1
fi

for id in $(drafts); do
    gh api -X DELETE "repos/$REPO/releases/$id" --silent
    echo "$TAG: deleted the draft $id an earlier run left"
done

gh release create "$TAG" --repo "$REPO" --draft --prerelease --target "$SHA" \
    --title "$TITLE" --notes "$NOTES" "$@" > /dev/null
# a list read right after a write can lag behind it: a few tries
for try in 1 2 3 4 5; do
    id=$(drafts)
    [ -z "$id" ] || break
    sleep "$try"
done
[ "$(wc -w <<< "$id")" = 1 ] || { echo "$TAG: expected one draft, found: ${id:-none}" >&2; exit 1; }
gh api -X PATCH "repos/$REPO/releases/$id" -F draft=false -f make_latest=false --silent

# what was published is what was meant: every file, byte for byte
want=$(for f in "$@"; do echo "$(basename "$f") sha256:$(sha256sum < "$f" | cut -d' ' -f1)"; done | sort)
for try in 1 2 3 4 5; do
    have=$(gh api "repos/$REPO/releases/tags/$TAG" -q '.assets[] | "\(.name) \(.digest)"' | sort)
    grep -q ' null$' <<< "$have" || break   # a digest not computed yet
    sleep "$try"
done
if [ "$want" != "$have" ]; then
    echo "$TAG: published, but its files differ from the ones given" >&2
    diff <(echo "$want") <(echo "$have") >&2 || true
    exit 1
fi
echo "$TAG: published with $# files, each checked against its SHA-256"
