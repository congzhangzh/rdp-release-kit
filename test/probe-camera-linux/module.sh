#!/bin/bash
# module.sh ubuntu|source <out dir>: loads v4l2loopback on this CI runner (never on a developer's
# machine: it loads a kernel module) with two devices:
#   /dev/video40 "Test Source"     the client's camera, fed by GStreamer (videotestsrc)
#   /dev/video41 "FreeRDP Camera"  the host's virtual camera, what an app on the host reads
# both with exclusive_caps=1, as Chrome needs it (capture offered once a writer is attached).
# The source has the lower number: the client's V4L2 backend announces every capture device in
# order, so the source is announced first and owns the host's camera; the FreeRDP Camera, which
# also offers capture once the host writes to it, comes second and is refused (no loop).
#   ubuntu: Ubuntu's own module: the running kernel's, else linux-modules-extra, else
#           v4l2loopback-dkms (0.12.7 on 24.04, built by DKMS); which one is logged
#   source: v4l2loopback built from its source tag (V4L2LOOPBACK_TAG, V4L2LOOPBACK_SHA), CI only:
#           a GPL module, never in an archive of ours
# shellcheck disable=SC2024  # the logs are the runner user's: only apt runs as root
set -euo pipefail
MODE=${1:?usage: module.sh ubuntu|source <out dir>}
OUT=${2:?usage: module.sh ubuntu|source <out dir>}
mkdir -p "$OUT"
KREL=$(uname -r)
# shellcheck disable=SC2054  # the commas belong to the module's parameters
PARAMS=(devices=2 video_nr=40,41 'card_label="Test Source","FreeRDP Camera"' exclusive_caps=1,1)

case $MODE in
    ubuntu)
        if modinfo v4l2loopback > /dev/null 2>&1; then
            from="already there for $KREL"
        elif sudo apt-get install -y -q "linux-modules-extra-$KREL" > "$OUT/apt-modules-extra.log" 2>&1 &&
            modinfo v4l2loopback > /dev/null 2>&1; then
            from="linux-modules-extra-$KREL"
        else
            sudo apt-get install -y -q "linux-headers-$KREL" v4l2loopback-dkms > "$OUT/apt-dkms.log" 2>&1
            from="v4l2loopback-dkms $(dpkg-query -W -f '${Version}' v4l2loopback-dkms)"
        fi
        ;;
    source)
        tag=${V4L2LOOPBACK_TAG:?} sha=${V4L2LOOPBACK_SHA:?}
        sudo modprobe -r v4l2loopback 2> /dev/null || true
        sudo apt-get install -y -q "linux-headers-$KREL" > "$OUT/apt-headers.log" 2>&1
        src=$RUNNER_TEMP/v4l2loopback
        rm -rf "$src"
        git clone -q --depth 1 --branch "$tag" https://github.com/v4l2loopback/v4l2loopback.git "$src"
        [ "$(git -C "$src" rev-parse HEAD)" = "$sha" ] ||
            { echo "v4l2loopback $tag is $(git -C "$src" rev-parse HEAD), not $sha" >&2; exit 1; }
        # from its directory: its Makefile passes M=$(PWD) to kbuild
        (cd "$src" && make KERNELRELEASE="$KREL" v4l2loopback.ko) > "$OUT/module-build.log" 2>&1
        # updates/ goes before the kernel's own directories (depmod.d's default search order)
        sudo install -D -m 644 "$src/v4l2loopback.ko" "/lib/modules/$KREL/updates/v4l2loopback.ko"
        sudo depmod -a "$KREL"
        from="source $tag ($sha)"
        ;;
    *) echo "usage: module.sh ubuntu|source <out dir>" >&2; exit 2 ;;
esac

sudo modprobe v4l2loopback "${PARAMS[@]}"
{
    echo "kernel: $KREL"
    echo "module from: $from"
    echo "loaded: $(modinfo -n v4l2loopback)"
    dpkg -S "$(modinfo -n v4l2loopback)" 2> /dev/null || echo "(no package owns it)"
    echo "/sys/module/v4l2loopback/version: $(cat /sys/module/v4l2loopback/version 2> /dev/null || echo none)"
    modinfo v4l2loopback | grep -E '^(filename|version|srcversion|vermagic|license):'
    v4l2-ctl --list-devices || true
} | tee "$OUT/module.txt"
# the runner's user reads and writes them without sudo
sudo chmod 666 /dev/video40 /dev/video41
for d in 40 41; do
    v4l2-ctl -d "/dev/video$d" --info | tee -a "$OUT/module.txt"
done
grep -q 'FreeRDP Camera' /sys/devices/virtual/video4linux/video41/name ||
    { echo "/dev/video41 is not the FreeRDP Camera" >&2; exit 1; }
