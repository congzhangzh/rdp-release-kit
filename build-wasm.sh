#!/bin/bash
# Builds the FreeRDP web client and its page in the Emscripten container
# (docker, or podman):
#
#   ./build-wasm.sh              dist/wasm/web/ (serve it) and dist/wasm/freerdp-web-<version>.zip
#
# PAGE_SRC=<dir> uses a local freerdp-web checkout for the page (not for
# releases). The work tree is kept in ~/.cache/rdp-release-kit/wasm.
set -euo pipefail

KIT=$(cd "$(dirname "$0")" && pwd)
OUT=$KIT/dist/wasm
SOURCES=${SOURCES:-$HOME/.cache/rdp-release-kit/sources}
# docker first: the builds are tested with it (podman: see README)
ENGINE=${ENGINE:-$(command -v docker || command -v podman)}
# Emscripten 6.0.11, as FreeRDP's Emscripten CI job uses it
IMAGE=emscripten/emsdk:6.0.11@sha256:cdefec943f04fd4b2b2fe23b0a1a346be9fc560ef5784a83faa27dd351381372
WORK=$HOME/.cache/rdp-release-kit/wasm
mkdir -p "$OUT" "$SOURCES" "$WORK"
# who the files the container writes should belong to: docker runs it as
# root, rootless podman already as this user
owner() { case "$ENGINE" in *docker) echo "$(id -u):$(id -g)" ;; esac; }

PAGE=()
if [ -n "${PAGE_SRC:-}" ]; then
    PAGE=(-v "$(cd "$PAGE_SRC" && pwd)":/page:ro -e PAGE_SRC=/page)
fi
# the single quotes are for the container's shell
# shellcheck disable=SC2016
"$ENGINE" run --rm -v "$KIT":/kit:ro -v "$SOURCES":/sources -v "$OUT":/out -v "$WORK":/work \
    "${PAGE[@]}" -e OWNER="$(owner)" "$IMAGE" \
    bash -c 'apt-get update -qq && apt-get install -y -qq --no-install-recommends ninja-build \
                 meson pkg-config zip > /dev/null
             /kit/build/build-wasm-client.sh /kit /sources /out; rc=$?
             [ -z "$OWNER" ] || chown -R "$OWNER" /out /work /sources; exit $rc'
