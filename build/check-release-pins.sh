#!/bin/bash
# The sources the kit takes only as their own releases, as a whole
# (docs/RELEASE.md, "Inputs"): freerdp-web, whose GitHub point releases
# the kit pins (its GitHub Pages are freerdp-web's own business), and
# freerdp-tk, the clients' connection window. Each line of sources.lock
# must name a release (a version YYYYMMDD.N or X.Y.Z) and pin the commit its
# tag points to: the version itself, no prefix (since 2026-10-25), or
# v<version> for the releases before.
#
#   build/check-release-pins.sh        LOCK=<file> checks another sources.lock
set -euo pipefail
cd "$(dirname "$0")/.."
LOCK=${LOCK:-sources.lock}

# the sources taken only as their releases
RELEASE_PINNED=(freerdp_web freerdp_tk)

status=0
for name in "${RELEASE_PINNED[@]}"; do
    read -r version url sha < <(awk -v n="$name" '$1 == n { print $2, $3, $4 }' "$LOCK")
    if ! [[ $version =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        echo "FAIL  $name: pins $version, not a release (YYYYMMDD.N or X.Y.Z, its tag <version>)"
        status=1
        continue
    fi
    tag='' name_of_tag=''
    for t in "$version" "v$version"; do
        if ! tags=$(git ls-remote "${url#git+}" "refs/tags/$t" "refs/tags/$t^{}"); then
            echo "FAIL  $name $version: could not read the tags of ${url#git+}"
            status=1
            continue 2
        fi
        # an annotated tag's commit is on its ^{} line, which sorts last
        tag=$(sort -k2 <<< "$tags" | tail -1 | cut -f1)
        name_of_tag=$t
        [ -z "$tag" ] || break
    done
    if [ -z "$tag" ]; then
        echo "FAIL  $name $version: there is no tag $version (or v$version)"
        status=1
    elif [ "$tag" != "$sha" ]; then
        echo "FAIL  $name $version: the tag $name_of_tag is ${tag:0:12}, sources.lock pins ${sha:0:12}"
        status=1
    else
        echo "ok    $name $version: the release $name_of_tag (${sha:0:12})"
    fi
done
exit $status
