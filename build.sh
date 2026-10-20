#!/bin/bash
# Builds the portable SDL3 FreeRDP client for this machine's architecture
# in the build container (podman or docker):
#
#   ./build.sh [output dir, default ./dist]
#
# Sources are downloaded once into ~/.cache/rdp-release-kit/sources;
# compiled objects are kept by ccache in ~/.cache/rdp-release-kit/ccache.
# SRC_<name>=<dir> builds a source from a local checkout (see
# build/overrides.sh; not for releases).
set -euo pipefail

KIT=$(cd "$(dirname "$0")" && pwd)
OUT=$(mkdir -p "${1:-$KIT/dist}" && cd "${1:-$KIT/dist}" && pwd)
SOURCES=${SOURCES:-$HOME/.cache/rdp-release-kit/sources}
mkdir -p "$SOURCES"
# docker first: the builds are tested with it (podman: see README)
ENGINE=${ENGINE:-$(command -v docker || command -v podman)}
IMAGE=rdp-release-kit-build
# who the files the container writes should belong to: docker runs it as
# root, rootless podman already as this user (a chown would map the uid
# through the user namespace and lock this user out)
owner() { case "$ENGINE" in *docker) echo "$(id -u):$(id -g)" ;; esac; }
# the build tree stays on the host: logs survive a failure, and a rebuild
# can reuse it
WORK=${WORK:-$HOME/.cache/rdp-release-kit/work-$(uname -m)}
mkdir -p "$WORK"
# the compiler cache, shared by every run on this machine; CCACHE=off
# builds without it
CCACHE=${CCACHE:-$HOME/.cache/rdp-release-kit/ccache/linux-$(uname -m)}
CACHE=()
if [ "$CCACHE" != off ]; then
    mkdir -p "$CCACHE"
    CACHE=(-v "$CCACHE":/ccache -e CCACHE_DIR=/ccache)
fi

# SRC_<name>=<dir> or sources.local: a local source (development only)
# shellcheck source=build/overrides.sh
. "$KIT/build/overrides.sh"
overrides "$WORK"
# LTO=off: FreeRDP without link-time optimisation, for a local FreeRDP only
if [ -n "${LTO:-}" ]; then
    if [ "$LTO" != off ] || [[ $OVERRIDDEN != *" freerdp "* ]]; then
        echo "LTO=off is for a local FreeRDP only (SRC_freerdp=<dir>)" >&2
        exit 1
    fi
    OVERRIDE+=(-e LTO=off)
fi

"$ENGINE" build -q -t "$IMAGE" -f "$KIT/build/Containerfile" "$KIT/build" > /dev/null
# the single quotes are for the container's shell
# shellcheck disable=SC2016
"$ENGINE" run --rm -v "$KIT":/kit:ro -v "$SOURCES":/sources -v "$OUT":/out -v "$WORK":/work \
    "${CACHE[@]}" "${OVERRIDE[@]}" -e OWNER="$(owner)" "$IMAGE" \
    bash -c '/kit/build/build-sdl3-client.sh /kit /sources /out; rc=$?;
             [ -z "$OWNER" ] || chown -R "$OWNER" /out /work ${CCACHE_DIR:-}; exit $rc'
