#!/bin/bash
# Prints the tag of a pre-release (docs/RELEASE.md, "Frozen releases"):
#
#   prerelease-tag.sh <kind> <key>        kind: web, xrdp, pipewire-module-xrdp, mutter, demo, release
#
# - The key names the inputs and the kit commit. A release with this key,
#   published or a draft an earlier run left, keeps its tag, so a second
#   run of one commit publishes nothing new. The key is the marker
#   "<!-- kit-key: <key> -->" in the notes (the workflows add it), the title
#   then being "<name> <tag>"; releases from before 2026-10-28 have it as
#   their title.
# - Otherwise <kind>-<YYYYMMDD>.<N>-<kit commit, 12>: the UTC date, and N
#   one more than the highest N of that kind and day among the releases
#   (drafts too) and the tags (a tag can outlive its release). The date
#   says how new a build is; N orders the builds of one day.
# - The kit's own rolling release (kind release) is <YYYYMMDD>.<N> alone:
#   no kind, and the kit commit only in its title.
#
# Expects GH_TOKEN, GITHUB_REPOSITORY and GITHUB_SHA (KIT_SHA instead: a
# workflow started by another run builds that run's commit, and GitHub keeps
# GITHUB_SHA its own); DAY=<YYYYMMDD> replaces today (tests).
set -euo pipefail

KIND=$1 TITLE=$2
REPO=${GITHUB_REPOSITORY:?} SHA=${KIT_SHA:-${GITHUB_SHA:?}}
case $KIND in
    web | xrdp | pipewire-module-xrdp | mutter | demo | release) ;;
    *) echo "prerelease-tag.sh: unknown kind: $KIND" >&2; exit 1 ;;
esac

# a release's key: the marker line in its notes (kit-key: <key>), which
# publishes it under a title that ends with its tag; before 2026-10-28 the
# title itself was the key
releases=$(gh api --paginate "repos/$REPO/releases?per_page=100" \
    -q '.[] | [.tag_name, .name, (((.body // "") | capture("<!-- kit-key: (?<k>.*?) -->") | .k) // "")] | @tsv')
earlier=$(awk -F'\t' -v t="$TITLE" '$2 == t || $3 == t { print $1; exit }' <<< "$releases")
if [ -n "$earlier" ]; then
    echo "$earlier"
    exit 0
fi

day=${DAY:-$(date -u +%Y%m%d)}
# matching-refs answers [] when nothing matches; any failure stops here
prefix=$KIND- suffix=-${SHA:0:12} pattern="-[0-9a-f]{12}"
[ "$KIND" = release ] && prefix='' suffix='' pattern=''
tags=$(gh api "repos/$REPO/git/matching-refs/tags/$prefix$day." -q '.[].ref | sub("^refs/tags/"; "")')
n=$({ cut -f1 <<< "$releases"; echo "$tags"; } |
    sed -nE "s/^$prefix$day\.([0-9]+)$pattern\$/\1/p" | sort -n | tail -1)
echo "$prefix$day.$((${n:-0} + 1))$suffix"
