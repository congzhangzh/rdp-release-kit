#!/bin/bash
# Prints which builds a push needs, from what changed between two commits:
#
#   changes.sh <before> <after>     "web" or "all"
#
# - web: the only change a build reads is the freerdp_web line of sources.lock
#   (a new freerdp-web release). Only the web client depends on the page, so
#   only it is built and tested again; the native clients, the xrdp packages,
#   the demos and the rolling release wait for a change that touches them.
# - all: anything else, and whenever <before> is unknown (a new branch, a
#   force-push, a commit this clone does not have).
#
# "A change a build reads" leaves out what kit.yml's paths-ignore leaves out:
# the docs, the pins tables and the upstream check (docs/RELEASE.md, "Flow").
set -euo pipefail
before=${1:-} after=${2:-HEAD}

all() { echo all; exit 0; }
[[ $before =~ ^[0-9a-f]{7,40}$ ]] && [[ ! $before =~ ^0+$ ]] || all
git cat-file -e "$before^{commit}" 2> /dev/null || all

ignored() { # path -> true if no build reads it (kit.yml's paths-ignore)
    case $1 in
    *.md | docs/* | .github/workflows/upstream.yml | .github/workflows/pins.yml | check-upstream.sh | \
        pins.notes | build/pins-table.sh | build/release-notes.sh | LICENSE | NOTICE) return 0 ;;
    esac
    return 1
}

while IFS= read -r path; do
    ignored "$path" && continue
    [ "$path" = sources.lock ] || all
done < <(git diff --name-only "$before" "$after")

# sources.lock: every pin line that differs (comments and blank lines aside)
pins() { git show "$1:sources.lock" | grep -v -E '^\s*(#|$)' | sort; }
changed=$({ diff <(pins "$before") <(pins "$after") || true; } | sed -n 's/^[<>] //p' | awk '{print $1}' | sort -u)
[ "$changed" = freerdp_web ] && { echo web; exit 0; }
all
