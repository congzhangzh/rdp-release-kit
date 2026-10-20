#!/bin/bash
# Builds the FreeRDP web client and its page in the Emscripten container
# (docker, or podman):
#
#   ./build-wasm.sh              dist/wasm/web/ (serve it) and dist/wasm/freerdp-web-<version>.zip
#
# PAGE_SRC=<dir> uses a local freerdp-web checkout for the page (PAGE_REV=<commit>
# names it in the MANIFEST; freerdp-web's own Pages build does that) (not for
# releases); SRC_freerdp_preview=<dir> does the same for FreeRDP (see
# build/overrides.sh). The work tree is kept in ~/.cache/rdp-release-kit/wasm
# (WORK=<dir> for another one), compiled objects in its ccache directory.
set -euo pipefail

KIT=$(cd "$(dirname "$0")" && pwd)
OUT=$KIT/dist/wasm
SOURCES=${SOURCES:-$HOME/.cache/rdp-release-kit/sources}
# docker first: the builds are tested with it (podman: see README)
ENGINE=${ENGINE:-$(command -v docker || command -v podman)}
# Emscripten 6.0.12, as FreeRDP's Emscripten CI job uses it (#13728)
IMAGE=emscripten/emsdk:6.0.12@sha256:77638e6c215a65f25a704c0c831d5c2463a8c0468a58c6cb82489dbe621dfa05
WORK=${WORK:-$HOME/.cache/rdp-release-kit/wasm}
mkdir -p "$OUT" "$SOURCES" "$WORK"
# the compiler cache, shared by every run on this machine; CCACHE=off
# builds without it
CCACHE=${CCACHE:-$HOME/.cache/rdp-release-kit/ccache/wasm}
CACHE=()
if [ "$CCACHE" != off ]; then
    mkdir -p "$CCACHE"
    CACHE=(-v "$CCACHE":/ccache -e CCACHE_DIR=/ccache)
fi
# shellcheck source=build/overrides.sh
. "$KIT/build/overrides.sh"
overrides "$WORK"
# who the files the container writes should belong to: docker runs it as
# root, rootless podman already as this user
owner() { case "$ENGINE" in *docker) echo "$(id -u):$(id -g)" ;; esac; }
# the image with the build tools already installed (build/builder.sh)
# shellcheck source=build/builder.sh
. "$KIT/build/builder.sh"
IMAGE=$(builder "$IMAGE" wasm)

PAGE=()
if [ -n "${PAGE_SRC:-}" ]; then
    PAGE=(-v "$(cd "$PAGE_SRC" && pwd)":/page:ro -e PAGE_SRC=/page -e PAGE_REV="${PAGE_REV:-}")
fi
# the single quotes are for the container's shell
# shellcheck disable=SC2016
"$ENGINE" run --rm -v "$KIT":/kit:ro -v "$SOURCES":/sources -v "$OUT":/out -v "$WORK":/work \
    "${PAGE[@]}" "${CACHE[@]}" "${OVERRIDE[@]}" -e OWNER="$(owner)" "$IMAGE" \
    bash -c '[ -n "${KIT_TOOLS:-}" ] || /kit/build/tools.sh /kit wasm
             /kit/build/build-wasm-client.sh /kit /sources /out; rc=$?
             [ -z "$OWNER" ] || chown -R "$OWNER" /out /work /sources ${CCACHE_DIR:-}; exit $rc'
