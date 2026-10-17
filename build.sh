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
ENGINE=$(command -v podman || command -v docker)
IMAGE=rdp-release-kit-build

"$ENGINE" build -q -t "$IMAGE" -f "$KIT/build/Containerfile" "$KIT/build" > /dev/null
"$ENGINE" run --rm -v "$KIT":/kit:ro -v "$SOURCES":/sources -v "$OUT":/out \
    "$IMAGE" bash -c '/kit/build/build-sdl3-client.sh /kit /sources /out; rc=$?;
                      chown -R '"$(id -u):$(id -g)"' /out; exit $rc'
