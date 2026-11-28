#!/bin/bash
# pin.sh <log dir>: the job's copy of sources.lock builds FreeRDP from $FREERDP_REPO at
# $FREERDP_SHA and the page from $WEB_REPO at $WEB_SHA; overrides are refused on CI, sources.lock
# is its only input. The branches' heads are logged beside it.
set -euo pipefail
LOGS=${1:?usage: pin.sh <log dir>}
mkdir -p "$LOGS"
pin() {  # pin <sources.lock name> <repo> <branch> <sha>
    git ls-remote "$2" "refs/heads/$3" | tee -a "$LOGS/branch-heads.txt"
    sed -i -E "s|^$1( +)[^ ]+( +)git\\+[^ ]+( +)[0-9a-f]{40}\$|$1\\1probe-${4:0:9}\\2git+$2\\3$4|" sources.lock
    grep -E "^$1 " sources.lock | tee -a "$LOGS/probed.txt"
    grep -q -E "^$1 .* $4\$" sources.lock || { echo "sources.lock does not pin $1 to $4" >&2; exit 1; }
}
pin freerdp "${FREERDP_REPO:?}" "${FREERDP_BRANCH:?}" "${FREERDP_SHA:?}"
pin freerdp_web "${WEB_REPO:?}" "${WEB_BRANCH:?}" "${WEB_SHA:?}"
