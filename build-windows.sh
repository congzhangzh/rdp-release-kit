#!/bin/bash
# Cross-compiles the Windows SDL3 FreeRDP client with llvm-mingw in a
# Debian container (docker, or podman):
#
#   ./build-windows.sh [x86_64|aarch64 ...]     default: both
#
# Writes dist/sdl3-freerdp-<version>-windows-<arch>.zip. Each architecture
# keeps its own work tree in ~/.cache/rdp-release-kit/win-<arch>.
set -euo pipefail

KIT=$(cd "$(dirname "$0")" && pwd)
OUT=$KIT/dist
SOURCES=${SOURCES:-$HOME/.cache/rdp-release-kit/sources}
# docker first: the builds are tested with it (podman: see README)
ENGINE=${ENGINE:-$(command -v docker || command -v podman)}
IMAGE=debian:13
mkdir -p "$OUT" "$SOURCES"
# who the files the container writes should belong to: docker runs it as
# root, rootless podman already as this user
owner() { case "$ENGINE" in *docker) echo "$(id -u):$(id -g)" ;; esac; }

ARCHES=("$@")
if [ ${#ARCHES[@]} = 0 ]; then
    ARCHES=(x86_64 aarch64)
fi

status=0
for arch in "${ARCHES[@]}"; do
    work=$HOME/.cache/rdp-release-kit/win-$arch
    mkdir -p "$work"
    echo "### windows $arch"
    # the single quotes are for the container's shell
    # shellcheck disable=SC2016
    if ! "$ENGINE" run --rm -v "$KIT":/kit:ro -v "$SOURCES":/sources -v "$OUT":/out \
            -v "$work":/work -e OWNER="$(owner)" -e ARCH="$arch" "$IMAGE" \
            bash -c '/kit/build/build-windows-client.sh /kit /sources /out "$ARCH"; rc=$?;
                     [ -z "$OWNER" ] || chown -R "$OWNER" /out /work /sources; exit $rc'; then
        echo "### windows $arch: FAILED"
        status=1
    fi
done
exit $status
