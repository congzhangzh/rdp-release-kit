#!/bin/bash
# runner-setup.sh <out dir>: the test jobs' tools (Xvfb, v4l2-ctl, GStreamer's videotestsrc,
# jpegenc and v4l2sink), the libraries the packages need from the system, and the downloaded
# packages unpacked: dl/host/pkg, dl/client/pkg
# shellcheck disable=SC2024  # the logs are the runner user's: only apt runs as root
set -euo pipefail
OUT=${1:?usage: runner-setup.sh <out dir>}
mkdir -p "$OUT"
sudo apt-get update -q > "$OUT/apt-update.log" 2>&1
# what the host needs from the system (check-portable.sh's list: PAM, libsystemd, PipeWire, X11),
# what the client needs (libpulse, and the X11 libraries SDL opens), as test/linux-host/Dockerfile
sudo apt-get install -y -q --no-install-recommends xvfb x11-utils v4l-utils gstreamer1.0-tools \
    gstreamer1.0-plugins-base gstreamer1.0-plugins-good python3 iproute2 \
    libpam0g libsystemd0 libpipewire-0.3-0t64 libx11-6 libxext6 libxdamage1 libxfixes3 libxinerama1 \
    libxtst6 libpulse0 libxcursor1 libxi6 libxrandr2 libxss1 libxkbcommon0 > "$OUT/apt-tools.log" 2>&1
for p in host client; do
    mkdir -p "dl/$p/pkg"
    tar -C "dl/$p/pkg" --strip-components=1 -xJf "$(ls dl/$p/*.tar.xz)"
done
{
    echo "kernel: $(uname -r)"
    grep -m1 -E '^(FreeRDP|sdl3-freerdp)' dl/host/pkg/MANIFEST dl/client/pkg/MANIFEST || true
    gst-inspect-1.0 --version | head -1
    v4l2-ctl --version
    ls -l /dev/video* 2> /dev/null || echo "no /dev/video*"
} | tee "$OUT/runner.txt"
