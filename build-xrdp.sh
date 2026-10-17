#!/bin/bash
# Builds native xrdp + xorgxrdp packages for each distribution, each in a
# stock container of that distribution (podman or docker):
#
#   ./build-xrdp.sh [image ...]      default: every image in distros.list
#
# Packages go to dist/xrdp/<distro>/. Sources are downloaded once into
# ~/.cache/rdp-release-kit/sources; each distribution keeps its own work
# tree in ~/.cache/rdp-release-kit/xrdp-<image>.
set -euo pipefail

KIT=$(cd "$(dirname "$0")" && pwd)
OUT=$KIT/dist/xrdp
SOURCES=${SOURCES:-$HOME/.cache/rdp-release-kit/sources}
ENGINE=$(command -v podman || command -v docker)
mkdir -p "$OUT" "$SOURCES"

IMAGES=("$@")
if [ ${#IMAGES[@]} = 0 ]; then
    mapfile -t IMAGES < <(grep -v -E '^\s*(#|$)' "$KIT/distros.list")
fi

status=0
for image in "${IMAGES[@]}"; do
    work=$HOME/.cache/rdp-release-kit/xrdp-${image//[\/:]/-}
    mkdir -p "$work"
    echo "### $image"
    # the single quotes are for the container's shell
    # shellcheck disable=SC2016
    if ! "$ENGINE" run --rm -v "$KIT":/kit:ro -v "$SOURCES":/sources -v "$OUT":/out \
            -v "$work":/work -e OWNER="$(id -u):$(id -g)" "$image" \
            bash -c '/kit/build/build-xrdp-pkg.sh /kit /sources /out; rc=$?;
                     chown -R "$OWNER" /out /work /sources; exit $rc'; then
        echo "### $image: FAILED"
        status=1
    fi
done
exit $status
