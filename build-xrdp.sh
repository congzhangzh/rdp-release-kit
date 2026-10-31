#!/bin/bash
# Builds native xrdp + xorgxrdp packages for each distribution, each in a
# stock container of that distribution (podman or docker): xrdp from our
# release on the fork, with Xorg and Wayland sessions (sway, GNOME, KDE)
# and AV1, xorgxrdp from its development commit (sources.lock):
#
#   ./build-xrdp.sh [image ...]      default: every image in distros.list
#
# Packages go to dist/xrdp/<distro>/.
# Sources are downloaded once into ~/.cache/rdp-release-kit/sources; each
# distribution keeps its own work tree in ~/.cache/rdp-release-kit/xrdp-<image>
# (under KIT_CACHE=<dir> instead) and its compiled objects in its ccache
# directory, and builds in an image with its build dependencies already
# installed (build/builder.sh). SRC_xrdp=<dir> (or SRC_xorgxrdp ...)
# builds from a local checkout, and keeps that
# build for the next run (see build/overrides.sh; not for releases).
set -euo pipefail

KIT=$(cd "$(dirname "$0")" && pwd)
if [ "${1:-}" = --preview ]; then
    echo "build-xrdp.sh: --preview is gone: the kit builds one xrdp, ours (see distros.list)" >&2
    exit 2
fi
OUT=$KIT/dist/xrdp
SOURCES=${SOURCES:-$HOME/.cache/rdp-release-kit/sources}
KIT_CACHE=${KIT_CACHE:-$HOME/.cache/rdp-release-kit}
# docker first: the builds are tested with it (podman: see README)
ENGINE=${ENGINE:-$(command -v docker || command -v podman)}
mkdir -p "$OUT" "$SOURCES"
# who the files the container writes should belong to: docker runs it as
# root, rootless podman already as this user (a chown would map the uid
# through the user namespace and lock this user out)
owner() { case "$ENGINE" in *docker) echo "$(id -u):$(id -g)" ;; esac; }
# shellcheck source=build/overrides.sh
. "$KIT/build/overrides.sh"
# shellcheck source=build/builder.sh
. "$KIT/build/builder.sh"

IMAGES=("$@")
if [ ${#IMAGES[@]} = 0 ]; then
    mapfile -t IMAGES < <(grep -v -E '^\s*(#|$)' "$KIT/distros.list" | awk '{print $1}')
fi

# The packages' release is 0kit<N>, N the number of kit commits: every kit
# change gives a higher version, so one version is never two different
# packages (docs/RELEASE.md, "Frozen releases"). A shallow clone would
# count 1, so it is refused; a tree without git (git archive) gets 0.
if [ "$(git -C "$KIT" rev-parse --is-shallow-repository 2> /dev/null)" = true ]; then
    echo "build-xrdp.sh: a shallow clone cannot number the packages: fetch the whole history" >&2
    exit 1
fi
KIT_REV=$(git -C "$KIT" rev-list --count HEAD 2> /dev/null) || KIT_REV=0
echo "== packages: release 0kit$KIT_REV"

status=0
for image in "${IMAGES[@]}"; do
    work=$KIT_CACHE/xrdp-${image//[\/:]/-}
    mkdir -p "$work"
    # the compiler cache of this distribution (its own compiler); CCACHE=off
    # builds without it
    CACHE=()
    if [ "${CCACHE:-}" != off ]; then
        mkdir -p "$KIT_CACHE/ccache/xrdp-${image//[\/:]/-}"
        CACHE=(-v "$KIT_CACHE/ccache/xrdp-${image//[\/:]/-}":/ccache -e CCACHE_DIR=/ccache)
    fi
    # SRC_<name> or sources.local: a local source (development only)
    overrides "$work"
    # the release's marks in distros.list (see there)
    mark() { awk -v i="$image" -v m="$1" \
        '$1 == i { for (k = 2; k <= NF; k++) if ($k == m) f = 1 } END { exit !f }' "$KIT/distros.list"; }
    NO_AV1='' NO_AV2='' NO_SWAY='' NO_KDE=''
    mark no-av1 && NO_AV1=1
    mark no-av2 && NO_AV2=1
    mark no-sway && NO_SWAY=1
    mark no-kde && NO_KDE=1
    echo "### $image${NO_AV1:+ (no AV1)}${NO_AV2:+ (no AV2)}${NO_SWAY:+ (no sway)}${NO_KDE:+ (no KDE)}"
    if ! builder=$(NO_AV1=$NO_AV1 builder "$image" xrdp); then
        echo "### $image: FAILED"
        status=1
        continue
    fi
    # the single quotes are for the container's shell
    # shellcheck disable=SC2016
    if ! "$ENGINE" run --rm -v "$KIT":/kit:ro -v "$SOURCES":/sources -v "$OUT":/out \
            -v "$work":/work "${CACHE[@]}" "${OVERRIDE[@]}" -e OWNER="$(owner)" \
            -e NO_AV1="$NO_AV1" -e NO_AV2="$NO_AV2" -e NO_SWAY="$NO_SWAY" -e NO_KDE="$NO_KDE" -e KIT_REV="$KIT_REV" "$builder" \
            bash -c '/kit/build/build-xrdp-pkg.sh /kit /sources /out; rc=$?;
                     [ -z "$OWNER" ] || chown -R "$OWNER" /out /work /sources ${CCACHE_DIR:-}
                     exit $rc'; then
        echo "### $image: FAILED"
        status=1
    fi
done
exit $status
