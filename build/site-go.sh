#!/bin/bash
# Checks the go for publishing the site from a kit run: the page tag 聪哥 named when he
# started the run must be the page this commit pins, on main (docs/RELEASE.md, "The site").
# The go names a tag, not a plain yes, so it can't publish a page nobody chose: if the pin
# moved, the run stops. kit.yml runs this first, so a wrong go fails in seconds, and again
# just before it starts the site workflow.
#
#   build/site-go.sh <page tag>      LOCK=<file> reads another sources.lock
set -euo pipefail
cd "$(dirname "$0")/.."
page=${1:-}
[[ $page =~ ^[0-9]{8}\.[0-9]+$|^v?[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo "site-go: '$page' is not a page tag" >&2; exit 1; }
[ "${GITHUB_REF:-}" = refs/heads/main ] || {
    echo "site-go: the site is published only from main, not ${GITHUB_REF:-an unknown ref}" >&2; exit 1; }
pinned=$(awk '$1 == "freerdp_web" { print $2 }' "${LOCK:-sources.lock}")
[ "$pinned" = "$page" ] || {
    echo "site-go: the go names page $page, but this commit pins ${pinned:-no page}" >&2; exit 1; }
echo "site-go: page $page is the pinned page"
