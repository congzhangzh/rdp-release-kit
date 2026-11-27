#!/bin/bash
# module.sh kernel|source|readme <out dir>: loads v4l2loopback on this CI runner (never on a
# developer's machine: it loads a kernel module). Whatever was loaded is unloaded first.
#
#   kernel  the module the runner's kernel or Ubuntu provides: the kernel's own (Ubuntu's 7.0
#           kernels ship 0.15.3 in linux-modules), else linux-modules-extra, else
#           v4l2loopback-dkms; which one, and its version, are logged (version.txt)
#   source  v4l2loopback built from its source tag (V4L2LOOPBACK_TAG, V4L2LOOPBACK_SHA, checked
#           after the clone), CI only: a GPL module, never in an archive of ours
#   dkms    Ubuntu's own v4l2loopback-dkms from the archive (0.12.7 on 24.04), as a user installs
#           it, no patch: the kernel, Secure Boot state, the DKMS build and its log, dkms status
#           are logged first; if it does not build or load, the exact error is recorded and the
#           step stops (DKMS's module goes to updates/dkms, before the kernel's own 0.15.3)
#   readme  the command host-README.txt gives, typed as a user would in bash:
#             sudo modprobe v4l2loopback exclusive_caps=1 card_label="FreeRDP Camera"
#           then the device's name must be exactly "FreeRDP Camera"; unloaded again. Then its
#           every-boot form, the options line in /etc/modprobe.d/freerdp-camera.conf (removed
#           after), with a plain "modprobe v4l2loopback": the same name
#
# kernel and source load two devices, both with exclusive_caps=1, as Chrome needs it (capture is
# offered once a writer is attached):
#   /dev/video40 "Test Source"     the client's camera, fed by GStreamer (videotestsrc)
#   /dev/video41 "FreeRDP Camera"  the host's virtual camera, what an app on the host reads
# card_label is one argument, "Test Source,FreeRDP Camera", without quotes of its own: modprobe
# quotes a value with spaces for the kernel itself, and v4l2loopback splits the array on commas
# (quotes inside the argument reach the kernel as part of the names: run 46066070526). The
# source has the lower number: the client's V4L2 backend announces every capture device in
# order, so the source is announced first and owns the host's camera; the FreeRDP Camera, which
# also offers capture once the host writes to it, comes second and is refused (no loop).
# shellcheck disable=SC2024  # the logs are the runner user's: only apt runs as root
set -euo pipefail
MODE=${1:?usage: module.sh kernel|source|dkms|readme <out dir>}
OUT=${2:?usage: module.sh kernel|source|dkms|readme <out dir>}
mkdir -p "$OUT"
KREL=$(uname -r)

# name_of <video number>: the device's name as the kernel has it
name_of() { cat "/sys/devices/virtual/video4linux/video$1/name" 2> /dev/null || true; }
# expect_name <video number> <name>: exactly, or stop with a line saying what it is
expect_name() {
    local got
    got=$(name_of "$1")
    if [ "$got" != "$2" ]; then
        echo "::error::/dev/video$1 is named [$got], not [$2] (card_label)" | tee -a "$OUT/module.txt"
        exit 1
    fi
    echo "ok    /dev/video$1 is named [$got]" | tee -a "$OUT/module.txt"
}

sudo modprobe -r v4l2loopback 2> /dev/null || true

case $MODE in
    kernel)
        if modinfo v4l2loopback > /dev/null 2>&1; then
            from="the kernel's own ($KREL)"
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
        sudo apt-get install -y -q "linux-headers-$KREL" > "$OUT/apt-headers.log" 2>&1
        src=$RUNNER_TEMP/v4l2loopback-$tag
        rm -rf "$src"
        git clone -q --depth 1 --branch "$tag" https://github.com/v4l2loopback/v4l2loopback.git "$src"
        [ "$(git -C "$src" rev-parse HEAD)" = "$sha" ] ||
            { echo "v4l2loopback $tag is $(git -C "$src" rev-parse HEAD), not $sha" >&2; exit 1; }
        from="source $tag ($sha)"
        # from its directory: its Makefile passes M=$(PWD) to kbuild
        (cd "$src" && make KERNELRELEASE="$KREL" v4l2loopback.ko) > "$OUT/module-build.log" 2>&1 ||
            { tail -30 "$OUT/module-build.log"; exit 1; }
        # updates/ goes before the kernel's own directories (depmod.d's default search order)
        sudo install -D -m 644 "$src/v4l2loopback.ko" "/lib/modules/$KREL/updates/v4l2loopback.ko"
        sudo depmod -a "$KREL"
        ;;
    dkms)
        {
            echo "kernel: $KREL"
            echo "Secure Boot: $(mokutil --sb-state 2>&1 || true)"
        } | tee "$OUT/dkms.txt"
        # as a user would; a failed DKMS build fails the package's configuration, which is a
        # result here, not an error of this script
        set +e
        sudo apt-get install -y -q "linux-headers-$KREL" v4l2loopback-dkms > "$OUT/apt-dkms.log" 2>&1
        rc=$?
        set -e
        {
            echo "apt-get install linux-headers-$KREL v4l2loopback-dkms: rc $rc"
            echo "v4l2loopback-dkms: $(dpkg-query -W -f '${Version} ${db:Status-Abbrev}' v4l2loopback-dkms 2>&1)"
            echo "dkms status: $(dkms status 2>&1 | tr '\n' ';')"
        } | tee -a "$OUT/dkms.txt"
        for log in /var/lib/dkms/v4l2loopback/*/build/make.log; do
            [ -f "$log" ] && { echo "== $log"; cat "$log"; }
        done > "$OUT/dkms-make.log" 2>&1
        if ! modinfo -n v4l2loopback 2> /dev/null | grep -q '/updates/dkms/'; then
            err=$(grep -m1 -E 'error:|Error [0-9]|Bad return status' "$OUT/dkms-make.log" "$OUT/apt-dkms.log" 2> /dev/null || true)
            echo "::error::v4l2loopback-dkms did not give a module for $KREL (apt rc $rc): ${err:-see apt-dkms.log}" |
                tee -a "$OUT/dkms.txt"
            grep -E 'error:' "$OUT/dkms-make.log" | head -20 | tee -a "$OUT/dkms.txt" || true
            exit 1
        fi
        from="v4l2loopback-dkms $(dpkg-query -W -f '${Version}' v4l2loopback-dkms) (Ubuntu's archive, built by DKMS)"
        if ! sudo modprobe v4l2loopback devices=2 video_nr=40,41 "card_label=Test Source,FreeRDP Camera" exclusive_caps=1,1 \
            > "$OUT/modprobe.log" 2>&1; then
            echo "::error::modprobe of the DKMS module failed: $(cat "$OUT/modprobe.log")" | tee -a "$OUT/dkms.txt"
            sudo dmesg | tail -20 | tee -a "$OUT/dkms.txt"
            exit 1
        fi
        sudo modprobe -r v4l2loopback
        ;;
    readme)
        # exactly as host-README.txt has it, through bash's own quoting
        sudo bash -c 'modprobe v4l2loopback exclusive_caps=1 card_label="FreeRDP Camera"'
        dev=
        for n in /sys/devices/virtual/video4linux/video*; do
            [ -e "$n" ] && dev=${n##*/video} && break
        done
        [ -n "$dev" ] || { echo "::error::no device after the README's modprobe" | tee "$OUT/module.txt"; exit 1; }
        {
            echo "the README's command: modprobe v4l2loopback exclusive_caps=1 card_label=\"FreeRDP Camera\""
            echo "version: $(cat /sys/module/v4l2loopback/version 2> /dev/null || echo none)"
            echo "exclusive_caps: $(cat /sys/module/v4l2loopback/parameters/exclusive_caps 2> /dev/null || echo '?')"
            v4l2-ctl -d "/dev/video$dev" --info 2> /dev/null | grep -E 'Driver name|Card type' || true
        } | tee "$OUT/module.txt"
        expect_name "$dev" "FreeRDP Camera"
        sudo modprobe -r v4l2loopback
        # the every-boot form, as host-README.txt writes it
        # (removed on any exit: the later loads must not get its options)
        trap 'sudo rm -f /etc/modprobe.d/freerdp-camera.conf' EXIT
        echo 'options v4l2loopback exclusive_caps=1 card_label="FreeRDP Camera"' |
            sudo tee /etc/modprobe.d/freerdp-camera.conf > /dev/null
        sudo modprobe v4l2loopback
        dev=
        for n in /sys/devices/virtual/video4linux/video*; do
            [ -e "$n" ] && dev=${n##*/video} && break
        done
        echo "modprobe.d: $(cat /etc/modprobe.d/freerdp-camera.conf)" | tee -a "$OUT/module.txt"
        [ -n "$dev" ] || { echo "::error::no device after modprobe with the modprobe.d line" | tee -a "$OUT/module.txt"; exit 1; }
        expect_name "$dev" "FreeRDP Camera"
        sudo modprobe -r v4l2loopback
        exit 0
        ;;
    *) echo "usage: module.sh kernel|source|dkms|readme <out dir>" >&2; exit 2 ;;
esac

sudo modprobe v4l2loopback devices=2 video_nr=40,41 "card_label=Test Source,FreeRDP Camera" exclusive_caps=1,1
if [ "$MODE" = dkms ]; then
    loaded=$(modinfo -n v4l2loopback)
    case $loaded in */updates/dkms/*) ;; *) echo "::error::loaded $loaded, not DKMS's module" | tee -a "$OUT/dkms.txt"; exit 1 ;; esac
fi
version=$(cat /sys/module/v4l2loopback/version 2> /dev/null || true)
echo "${version:-none}" > "$OUT/version.txt"
{
    echo "kernel: $KREL"
    echo "module from: $from"
    echo "loaded: $(modinfo -n v4l2loopback)"
    dpkg -S "$(modinfo -n v4l2loopback)" 2> /dev/null || echo "(no package owns it)"
    echo "/sys/module/v4l2loopback/version: ${version:-none (no MODULE_VERSION: older than 0.13)}"
    modinfo v4l2loopback | grep -E '^(filename|version|srcversion|vermagic|license):' || true
    v4l2-ctl --list-devices || true
} | tee "$OUT/module.txt"
# the runner's user reads and writes them without sudo
sudo chmod 666 /dev/video40 /dev/video41
for d in 40 41; do
    v4l2-ctl -d "/dev/video$d" --info | tee -a "$OUT/module.txt"
done
expect_name 40 "Test Source"
expect_name 41 "FreeRDP Camera"
