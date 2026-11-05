#!/bin/bash
# Puts the site back after a publish that failed the login from the published site: the
# live site never stays broken (docs/RELEASE.md, "The site"). A new commit with the
# previous site's exact files, so gh-pages keeps every site that was ever live. It stops
# without touching anything if gh-pages is no longer at the commit that failed.
#
#   build/site-rollback.sh <gh-pages clone> <site before> <site that failed> <its release>
#
# Prints the kit release that is live again (empty if the old site has no RELEASE file).
set -euo pipefail
[ $# -eq 4 ] || { echo "usage: site-rollback.sh <clone> <before> <after> <release>" >&2; exit 2; }
pages=$1 before=$2 after=$3 release=$4
git -C "$pages" fetch -q origin gh-pages
tip=$(git -C "$pages" rev-parse FETCH_HEAD)
failed=$(git -C "$pages" rev-parse "$after^{commit}")
[ "$tip" = "$failed" ] || {
    echo "site-rollback: gh-pages is at $tip, not $failed: left as it is" >&2; exit 1; }
old=$(git -C "$pages" show "$before:RELEASE" 2> /dev/null || true)
git -C "$pages" checkout -q -B gh-pages "$tip"
git -C "$pages" read-tree -u --reset "$before"
git -C "$pages" commit -q -m "Site: back to kit release ${old:-before $release}, $release failed its check"
[ "$(git -C "$pages" rev-parse 'HEAD^{tree}')" = "$(git -C "$pages" rev-parse "$before^{tree}")" ] || {
    echo "site-rollback: the tree differs from the old site, not pushed" >&2; exit 1; }
git -C "$pages" push -q origin gh-pages
echo "$old"
