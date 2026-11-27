#!/bin/bash
# pin-freerdp.sh <log dir>: the job's copy of sources.lock builds FreeRDP from $FREERDP_REPO at
# $FREERDP_SHA, for the client (freerdp) and the Linux host (freerdp_linux_host) alike; overrides
# are refused on CI, sources.lock is its only input. The branch's head is logged beside it.
set -euo pipefail
LOGS=${1:?usage: pin-freerdp.sh <log dir>}
mkdir -p "$LOGS"
sha=${FREERDP_SHA:?} repo=${FREERDP_REPO:?}
git ls-remote "$repo" "refs/heads/${FREERDP_BRANCH:?}" | tee "$LOGS/freerdp-branch-head.txt"
for name in freerdp freerdp_linux_host; do
    sed -i -E "s|^$name +[^ ]+ +git\\+[^ ]+ +[0-9a-f]{40}\$|$name probe-${sha:0:9} git+$repo $sha|" sources.lock
done
grep -E '^freerdp(_linux_host)? ' sources.lock | tee "$LOGS/freerdp-probed.txt"
[ "$(grep -c -E " $sha\$" "$LOGS/freerdp-probed.txt")" = 2 ] ||
    { echo "sources.lock does not pin both FreeRDP lines to $sha" >&2; exit 1; }
