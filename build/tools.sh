#!/bin/bash
# Installs what one kind of build needs into its container:
#
#   tools.sh <kit dir> windows | wasm | xrdp
#
# It runs once, when the builder image is made (build/builder.sh), and the
# builds then start from that image. In a stock image (BUILDER=off) each
# build runs it itself. xrdp reads NO_AV1, as build/build-xrdp-pkg.sh does.
set -euo pipefail

KIT=$1
KIND=$2
# shellcheck source=/dev/null
. /etc/os-release
case " $ID ${ID_LIKE:-} " in
    *" debian "* | *" ubuntu "*) FAMILY=deb ;;
    *" fedora "*) FAMILY=rpm ;;
    *) echo "unsupported distribution: $PRETTY_NAME" >&2; exit 1 ;;
esac

case $KIND in
    windows)
        PACKAGES=(cmake ninja-build meson nasm pkg-config python3 zip file curl git gnupg
                  xz-utils ca-certificates ccache rsync) ;;
    wasm)
        PACKAGES=(ninja-build meson pkg-config zip ccache rsync) ;;
    xrdp)
        # the first word of each line in deps/<family>.txt
        mapfile -t PACKAGES < <(grep -h -v -E '^\s*(#|$)' "$KIT/deps/$FAMILY.txt" | awk '{print $1}' |
            if [ -n "${NO_AV1:-}" ]; then grep -v '^libaom-'; else cat; fi)
        PACKAGES+=(ccache rsync) ;;
    *)
        echo "tools.sh: unknown build $KIND" >&2
        exit 1 ;;
esac

echo "== build tools for $KIND ($PRETTY_NAME)"
if [ $FAMILY = deb ]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends "${PACKAGES[@]}" > /dev/null
    rm -rf /var/lib/apt/lists/*
else
    dnf -y -q install "${PACKAGES[@]}" > /dev/null
    dnf clean all > /dev/null
fi
