#!/bin/bash
# Cross-compiles the Windows SDL3 FreeRDP client with llvm-mingw in a
# Debian container (docker, or podman):
#
#   ./build-windows.sh [x86_64|aarch64 ...]     default: both
#
# Writes dist/sdl3-freerdp-<version>-windows-<arch>.zip. Each architecture
# keeps its own work tree in ~/.cache/rdp-release-kit/win-<arch> (under
# KIT_CACHE=<dir> instead), compiled objects in its ccache directory.
# HOST=1 builds the Windows host instead (dist/freerdp-host-<version>-windows-<arch>.zip:
# FreeRDP's shadow server and freerdp-shadow-service, build/build-windows-client.sh).
# HOST_CAMERA=1 (with HOST=1) adds the shadow server's virtual camera (WITH_SHADOW_CAMERA:
# freerdp-shadow-camera-source.dll beside freerdp-shadow-cli.exe in the package).
# CLIENT_CAMERA=1 (CI probes only, never a release): the client's camera redirection (the
# rdpecam client channel, its Media Foundation backend sys:mf).
# SRC_freerdp=<dir> builds FreeRDP from a local checkout, LTO=off then
# without link-time optimisation (see build/overrides.sh; not for releases).
set -euo pipefail

KIT=$(cd "$(dirname "$0")" && pwd)
OUT=$KIT/dist
SOURCES=${SOURCES:-$HOME/.cache/rdp-release-kit/sources}
KIT_CACHE=${KIT_CACHE:-$HOME/.cache/rdp-release-kit}
# docker first: the builds are tested with it (podman: see README)
ENGINE=${ENGINE:-$(command -v docker || command -v podman)}
mkdir -p "$OUT" "$SOURCES"
# who the files the container writes should belong to: docker runs it as
# root, rootless podman already as this user
owner() { case "$ENGINE" in *docker) echo "$(id -u):$(id -g)" ;; esac; }
# the compiler cache, shared by both architectures; CCACHE=off builds
# without it
CCACHE=${CCACHE:-$KIT_CACHE/ccache/windows}
CACHE=()
if [ "$CCACHE" != off ]; then
    mkdir -p "$CCACHE"
    CACHE=(-v "$CCACHE":/ccache -e CCACHE_DIR=/ccache)
fi
# shellcheck source=build/overrides.sh
. "$KIT/build/overrides.sh"
# shellcheck source=build/builder.sh
. "$KIT/build/builder.sh"
IMAGE=$(builder debian:13 windows)

ARCHES=("$@")
if [ ${#ARCHES[@]} = 0 ]; then
    ARCHES=(x86_64 aarch64)
fi

status=0
for arch in "${ARCHES[@]}"; do
    work=$KIT_CACHE/win-$arch${HOST:+-host}
    mkdir -p "$work"
    # SRC_<name> or sources.local: a local source (development only)
    overrides "$work"
    # LTO=off: FreeRDP without link-time optimisation, for a local FreeRDP only
    if [ -n "${LTO:-}" ]; then
        if [ "$LTO" != off ] || [[ $OVERRIDDEN != *" freerdp "* ]]; then
            echo "LTO=off is for a local FreeRDP only (SRC_freerdp=<dir>)" >&2
            exit 1
        fi
        OVERRIDE+=(-e LTO=off)
    fi
    echo "### windows $arch"
    # the single quotes are for the container's shell
    # shellcheck disable=SC2016
    if ! "$ENGINE" run --rm -e GITHUB_SHA="${GITHUB_SHA:-$(git -C "$KIT" rev-parse HEAD 2> /dev/null)}" -v "$KIT":/kit:ro -v "$SOURCES":/sources -v "$OUT":/out \
            -v "$work":/work "${CACHE[@]}" "${OVERRIDE[@]}" -e OWNER="$(owner)" -e ARCH="$arch" \
            -e HOST="${HOST:-}" -e HOST_CAMERA="${HOST_CAMERA:-}" -e CLIENT_CAMERA="${CLIENT_CAMERA:-}" \
            -e CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-}" \
            "$IMAGE" \
            bash -c '/kit/build/build-windows-client.sh /kit /sources /out "$ARCH"; rc=$?;
                     [ -z "$OWNER" ] || chown -R "$OWNER" /out /work /sources ${CCACHE_DIR:-}
                     exit $rc'; then
        echo "### windows $arch: FAILED"
        status=1
    fi
done
exit $status
