#!/bin/bash
# Builds the portable SDL3 FreeRDP client for this machine's architecture
# in the build container (podman or docker):
#
#   ./build.sh [output dir, default ./dist]
#
# Sources are downloaded once into ~/.cache/rdp-release-kit/sources.
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

"$ENGINE" build -q -t "$IMAGE" -f "$KIT/build/Containerfile" "$KIT/build" > /dev/null
# the single quotes are for the container's shell
# shellcheck disable=SC2016
"$ENGINE" run --rm -v "$KIT":/kit:ro -v "$SOURCES":/sources -v "$OUT":/out -v "$WORK":/work \
    -e OWNER="$(owner)" "$IMAGE" \
    bash -c '/kit/build/build-sdl3-client.sh /kit /sources /out; rc=$?;
             [ -z "$OWNER" ] || chown -R "$OWNER" /out /work; exit $rc'
