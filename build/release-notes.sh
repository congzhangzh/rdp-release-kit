#!/bin/bash
# The notes of a release or pre-release: its summary, the pins tables of the
# products it holds (build/pins-table.sh), and the kit's CHANGELOG.md at the
# commit it was built from:
#
#   release-notes.sh <summary> [product ...]     no product: all of them
#
# Uses GITHUB_SHA (or KIT_SHA) and GITHUB_REPOSITORY when set, as
# publish-prerelease.sh.
set -euo pipefail

KIT=$(cd "$(dirname "$0")/.." && pwd)
SUMMARY=$1
shift
SHA=${KIT_SHA:-${GITHUB_SHA:-$(git -C "$KIT" rev-parse HEAD)}}
REPO=${GITHUB_REPOSITORY:-congzhangzh/rdp-release-kit}

printf '%s\n\n## What it is built from\n\n' "$SUMMARY"
"$KIT/build/pins-table.sh" "$@"
printf '\nWhat changed in the kit, and why: [CHANGELOG.md](https://github.com/%s/blob/%s/CHANGELOG.md).\n' \
    "$REPO" "$SHA"
