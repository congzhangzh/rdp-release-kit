#!/bin/bash
# Builds the SDL3 FreeRDP client for macOS, natively with Apple clang (no
# container: macOS has none that can build for itself):
#
#   ./build-macos.sh [arm64|x86_64 ...]     default: both
#
# Writes dist/sdl3-freerdp-<version>-macos-<arch>.tar.xz. An Apple Silicon
# Mac builds both: x86_64 with -arch x86_64, and its client is checked
# through Rosetta 2 (softwareupdate --install-rosetta). An Intel Mac builds
# x86_64 only. Needs Xcode or its command line tools, and from Homebrew:
#
#   brew install bash cmake ninja meson nasm pkgconf ccache
#
# The build itself (build/build-macos-client.sh, build/lib.sh) needs bash
# 4.4 or newer, for associative arrays and inherit_errexit; macOS ships
# bash 3.2, the last GPLv2 one, so this script, which runs under it, finds
# Homebrew's (or BASH4=<path>). Each architecture keeps its own work tree
# in ~/.cache/rdp-release-kit/macos-<arch> (under KIT_CACHE=<dir>
# instead), compiled objects in its ccache directory. Local sources
# (SRC_<name>, sources.local) are for the container builds only.
set -euo pipefail

KIT=$(cd "$(dirname "$0")" && pwd)
OUT=$KIT/dist
SOURCES=${SOURCES:-$HOME/.cache/rdp-release-kit/sources}
KIT_CACHE=${KIT_CACHE:-$HOME/.cache/rdp-release-kit}
mkdir -p "$OUT" "$SOURCES"

if [ "$(uname -s)" != Darwin ]; then
    echo "build-macos.sh builds on macOS only" >&2
    exit 1
fi
# overrides.sh mounts local sources into a container; there is none here
if [ -n "$(env | grep -E '^SRC_[a-z0-9_]+=' || true)" ] || [ -f "$KIT/sources.local" ]; then
    echo "local sources (SRC_<name>, sources.local) are not supported by the macOS build" >&2
    exit 1
fi

# Homebrew's tools, also from a shell that did not read a profile (ssh
# <host> ./build-macos.sh): /opt/homebrew on Apple Silicon, /usr/local on Intel
if ! command -v brew > /dev/null; then
    for prefix in /opt/homebrew /usr/local; do
        [ -x "$prefix/bin/brew" ] && PATH=$prefix/bin:$PATH && break
    done
fi

# a bash new enough for build/lib.sh: BASH4, else Homebrew's, else PATH's
newer_bash() {
    # the single quotes are for that bash
    # shellcheck disable=SC2016
    "$1" -c '[ $((BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1])) -ge 404 ]' 2> /dev/null
}
BASH4=${BASH4:-}
if [ -z "$BASH4" ]; then
    for candidate in "$(brew --prefix 2> /dev/null)/bin/bash" /opt/homebrew/bin/bash \
            /usr/local/bin/bash "$(command -v bash)"; do
        if [ -x "$candidate" ] && newer_bash "$candidate"; then
            BASH4=$candidate
            break
        fi
    done
fi
if [ -z "$BASH4" ] || ! newer_bash "$BASH4"; then
    echo "the build needs bash 4.4 or newer (macOS's is 3.2): brew install bash" >&2
    exit 1
fi

# the compiler cache, shared by both architectures (-arch is part of each
# object's hash); CCACHE=off builds without it
CCACHE=${CCACHE:-$KIT_CACHE/ccache/macos}
if [ "$CCACHE" != off ] && command -v ccache > /dev/null; then
    mkdir -p "$CCACHE"
    export CCACHE_DIR=$CCACHE
else
    unset CCACHE_DIR
fi

# Apple Silicon builds both architectures, an Intel Mac x86_64 only
if [ "$(sysctl -in hw.optional.arm64)" = 1 ]; then
    CAN=" arm64 x86_64 "
else
    CAN=" x86_64 "
fi
if [ $# = 0 ]; then
    # shellcheck disable=SC2086
    set -- $CAN
fi

status=0
for arch in "$@"; do
    if [[ $CAN != *" $arch "* ]]; then
        echo "### macos $arch: not buildable on this Mac (it builds:$CAN)" >&2
        status=1
        continue
    fi
    echo "### macos $arch"
    if ! WORK=$KIT_CACHE/macos-$arch "$BASH4" "$KIT/build/build-macos-client.sh" \
            "$KIT" "$SOURCES" "$OUT" "$arch"; then
        echo "### macos $arch: FAILED"
        status=1
    fi
done
exit $status
