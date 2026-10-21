#!/bin/bash
# The sources the kit takes only as their own releases, as a whole
# (docs/RELEASE.md, "Inputs"): freerdp-web, whose GitHub point releases
# the kit pins; its GitHub Pages are freerdp-web's own business. Each line
# of sources.lock must name a release (version YYYYMMDD.N, before
# 2026-10-21 X.Y.Z) and pin the commit that the tag v<version> points to.
#
#   build/check-release-pins.sh        LOCK=<file> checks another sources.lock
set -euo pipefail
cd "$(dirname "$0")/.."
LOCK=${LOCK:-sources.lock}

# the sources taken only as their releases
RELEASE_PINNED=(freerdp_web)

status=0
for name in "${RELEASE_PINNED[@]}"; do
    read -r version url sha < <(awk -v n="$name" '$1 == n { print $2, $3, $4 }' "$LOCK")
    if ! [[ $version =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        echo "FAIL  $name: pins $version, not a release (YYYYMMDD.N or X.Y.Z, its tag v<version>)"
        status=1
        continue
    fi
    if ! tags=$(git ls-remote "${url#git+}" "refs/tags/v$version" "refs/tags/v$version^{}"); then
        echo "FAIL  $name $version: could not read the tags of ${url#git+}"
        status=1
        continue
    fi
    # an annotated tag's commit is on its ^{} line, which sorts last
    tag=$(sort -k2 <<< "$tags" | tail -1 | cut -f1)
    if [ -z "$tag" ]; then
        echo "FAIL  $name $version: there is no tag v$version"
        status=1
    elif [ "$tag" != "$sha" ]; then
        echo "FAIL  $name $version: the tag v$version is ${tag:0:12}, sources.lock pins ${sha:0:12}"
        status=1
    else
        echo "ok    $name $version: the release v$version (${sha:0:12})"
    fi
done
exit $status
