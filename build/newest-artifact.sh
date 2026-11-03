#!/usr/bin/env bash
# build/newest-artifact.sh <name> <dir> [--optional]: this run's newest artifact called
# <name>, unpacked into <dir>. After `gh run rerun --failed` a run holds one artifact per
# attempt under the same name, and actions/download-artifact by name took the first
# attempt's: in kit run 41714694578 the release got demo-release from 21:09 (no KDE video,
# its job had failed) instead of the rerun's from 21:39, and 20261103.11 shipped without it.
# Needs GH_TOKEN with actions: read.
set -euo pipefail
name=$1 dir=$2 optional=${3:-}
repo=${GITHUB_REPOSITORY:?} run=${GITHUB_RUN_ID:?}
all=$(gh api "repos/$repo/actions/runs/$run/artifacts?name=$name&per_page=100" \
    -q '[.artifacts[] | select(.expired | not)] | sort_by(.created_at)')
n=$(jq length <<< "$all")
id=$(jq -r 'last | .id // empty' <<< "$all")
if [ -z "$id" ]; then
    echo "$name: no artifact in this run" >&2
    [ "$optional" = --optional ] && exit 0
    exit 1
fi
mkdir -p "$dir"
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
gh api "repos/$repo/actions/artifacts/$id/zip" > "$tmp"
unzip -q -o "$tmp" -d "$dir"
echo "$name: artifact $id, the newest of $n, $(jq -r 'last | .created_at' <<< "$all") -> $dir"
