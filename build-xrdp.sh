#!/bin/bash
# Builds native xrdp + xorgxrdp packages for each distribution, each in a
# stock container of that distribution (podman or docker):
#
#   ./build-xrdp.sh [image ...]      default: every image in distros.list
#   ./build-xrdp.sh --preview [image ...]   the xrdp preview, default: every
#                                    image in distros-preview.list
#
# Packages go to dist/xrdp/<distro>/ (the preview: dist/xrdp-preview/). Sources are downloaded once into
# ~/.cache/rdp-release-kit/sources; each distribution keeps its own work
# tree in ~/.cache/rdp-release-kit/xrdp-<image>.
set -euo pipefail

KIT=$(cd "$(dirname "$0")" && pwd)
FLAVOUR=stable LIST=distros.list SUFFIX=
if [ "${1:-}" = --preview ]; then
    shift
    FLAVOUR=preview LIST=distros-preview.list SUFFIX=-preview
fi
OUT=$KIT/dist/xrdp$SUFFIX
SOURCES=${SOURCES:-$HOME/.cache/rdp-release-kit/sources}
# docker first: the builds are tested with it (podman: see README)
ENGINE=${ENGINE:-$(command -v docker || command -v podman)}
mkdir -p "$OUT" "$SOURCES"
# who the files the container writes should belong to: docker runs it as
# root, rootless podman already as this user (a chown would map the uid
# through the user namespace and lock this user out)
owner() { case "$ENGINE" in *docker) echo "$(id -u):$(id -g)" ;; esac; }

IMAGES=("$@")
if [ ${#IMAGES[@]} = 0 ]; then
    mapfile -t IMAGES < <(grep -v -E '^\s*(#|$)' "$KIT/$LIST" | awk '{print $1}')
fi

status=0
for image in "${IMAGES[@]}"; do
    work=$HOME/.cache/rdp-release-kit/xrdp$SUFFIX-${image//[\/:]/-}
    mkdir -p "$work"
    # the release's marks in distros-preview.list (see there)
    NO_AV1=
    [ $FLAVOUR = preview ] && awk -v i="$image" \
        '$1 == i { for (k = 2; k <= NF; k++) if ($k == "no-av1") f = 1 } END { exit !f }' \
        "$KIT/$LIST" && NO_AV1=1
    echo "### $image${NO_AV1:+ (no AV1)}"
    # the single quotes are for the container's shell
    # shellcheck disable=SC2016
    if ! "$ENGINE" run --rm -v "$KIT":/kit:ro -v "$SOURCES":/sources -v "$OUT":/out \
            -v "$work":/work -e OWNER="$(owner)" -e FLAVOUR="$FLAVOUR" -e NO_AV1="$NO_AV1" "$image" \
            bash -c '/kit/build/build-xrdp-pkg.sh /kit /sources /out; rc=$?;
                     [ -z "$OWNER" ] || chown -R "$OWNER" /out /work /sources; exit $rc'; then
        echo "### $image: FAILED"
        status=1
    fi
done
exit $status
