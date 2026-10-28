#!/bin/bash
# The web client's site, from one kit release: what goes live at
# freerdp-web's Pages when the site workflow (.github/workflows/site.yml)
# publishes that release:
#
#   build/site.sh <kit release> <site dir>     e.g. build/site.sh 20261027.3 site
#
# A rolling release passed every gate together: its web client (built with
# the freerdp-web page it pins, logged in to from a browser), its demo
# videos, its xrdp packages. The site is that client and page
# (freerdp-web-<version>.zip), the videos in demo/ with demo.json, each video
# given its lasting address from build/site-anchors.json ("id", "aliases"),
# RELEASE, the release's tag, which the published site's check reads, and
# install.json, what the page's "Get a server" shows (releases from
# 2026-10-28 on; without it the page links to the kit's releases).
# Every file is checked against the release's SHA256SUMS. Prints the page's
# freerdp-web commit (its MANIFEST), whose test-page.mjs checks the files.
#
# Expects GH_TOKEN (gh) and GITHUB_REPOSITORY (default
# congzhangzh/rdp-release-kit).
set -euo pipefail

KIT=$(cd "$(dirname "$0")/.." && pwd)
TAG=${1:?usage: build/site.sh <kit release> <site dir>}
SITE=${2:?usage: build/site.sh <kit release> <site dir>}
REPO=${GITHUB_REPOSITORY:-congzhangzh/rdp-release-kit}
[ ! -e "$SITE" ] || { echo "site.sh: $SITE exists; a site is assembled into a new directory" >&2; exit 1; }

DL=$(mktemp -d)
trap 'rm -rf "$DL"' EXIT
gh release download "$TAG" -R "$REPO" -D "$DL" -p SHA256SUMS -p 'freerdp-web-*.zip' \
    -p demo.json -p '*.mp4' -p '*.jpg' -p install.json > /dev/null
(cd "$DL" && sha256sum -c --ignore-missing --quiet SHA256SUMS) ||
    { echo "site.sh: $TAG: a file does not match its SHA256SUMS" >&2; exit 1; }
zip=$(find "$DL" -maxdepth 1 -name 'freerdp-web-*.zip' | head -1)
[ -n "$zip" ] || { echo "site.sh: $TAG has no web client (freerdp-web-*.zip)" >&2; exit 1; }

mkdir -p "$SITE/demo"
(cd "$SITE" && python3 -m zipfile -e "$zip" .)
page=$(sed -n 's/^page: freerdp-web \([0-9a-f]\{40\}\).*/\1/p' "$SITE/MANIFEST")
[ -n "$page" ] || { echo "site.sh: $TAG's client names no freerdp-web commit in its MANIFEST" >&2; exit 1; }
# GitHub's Pages from a branch run Jekyll, which leaves out hidden
# directories such as the page's .well-known/
touch "$SITE/.nojekyll"
echo "$TAG" > "$SITE/RELEASE"
[ ! -f "$DL/install.json" ] || cp "$DL/install.json" "$SITE/"

python3 - "$DL" "$SITE/demo" "$KIT/build/site-anchors.json" << 'EOF'
import json, os, shutil, sys
dl, out, anchors_file = sys.argv[1:4]
demo = json.load(open(f"{dl}/demo.json", encoding="utf-8"))
anchors = {k: v for k, v in json.load(open(anchors_file, encoding="utf-8")).items() if not k.startswith("_")}
for v in demo["videos"]:
    name = os.path.splitext(os.path.basename(v["src"]))[0]
    for key, names in anchors.items():
        if name in names:
            v["id"], v["aliases"] = key, names
    if "id" not in v:
        sys.exit(f"site.sh: the video {name} has no address in build/site-anchors.json: add it")
    for k in ("src", "poster"):
        shutil.copy(f"{dl}/{os.path.basename(v[k])}", out)
json.dump(demo, open(f"{out}/demo.json", "w", encoding="utf-8"), indent=2, ensure_ascii=False)
print(f"site.sh: {len(demo['videos'])} demo videos", file=sys.stderr)
EOF
echo "site.sh: $TAG, page freerdp-web ${page:0:12}, in $SITE" >&2
echo "$page"
