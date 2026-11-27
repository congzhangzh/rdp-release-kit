#!/bin/bash
# build-gst-client.sh <FreeRDP source dir> <out dir>: a CI-only client, never shipped, for the h264
# case of camera-e2e.sh: xfreerdp with the rdpecam GStreamer backend, natively on the Ubuntu runner
# against Ubuntu's packages. Its camera is a GStreamer pipeline, converted to I420 and encoded to
# H.264 by Ubuntu's FFmpeg (libx264, GPL: CI only, nothing of it leaves this job but the test's
# result). Packages: see DEPS below (the workflow installs them).
set -euo pipefail
SRC=$(realpath "${1:?usage: build-gst-client.sh <FreeRDP source dir> <out dir>}")
OUT=${2:?}
mkdir -p "$OUT"
OUT=$(realpath "$OUT")
B=${BUILD_DIR:-$OUT/build}
cmake -G Ninja -S "$SRC" -B "$B" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
    -DWITH_CLIENT=ON -DWITH_CLIENT_SDL=OFF -DWITH_X11=ON -DWITH_WAYLAND=OFF \
    -DWITH_SERVER=OFF -DWITH_SAMPLE=OFF -DWITH_PROXY=OFF -DBUILD_TESTING=OFF -DWITH_MANPAGES=OFF \
    -DWITH_PULSE=OFF -DWITH_ALSA=OFF -DWITH_OSS=OFF -DWITH_CUPS=OFF -DWITH_PCSC=OFF -DWITH_KRB5=OFF \
    -DWITH_FUSE=OFF -DCHANNEL_URBDRC=OFF -DWITH_SSO_MIB=OFF -DWITH_UNICODE_BUILTIN=ON \
    -DWITH_GFX_AV1=OFF -DWITH_GFX_AV2=OFF -DWITH_OPENH264=OFF \
    -DWITH_FFMPEG=ON -DWITH_VIDEO_FFMPEG=ON -DWITH_SWSCALE=ON -DWITH_SWSCALE_LOADING=OFF \
    -DWITH_DSP_FFMPEG=OFF -DWITH_FFMPEG_HWACCEL=OFF \
    -DCHANNEL_RDPECAM=ON -DCHANNEL_RDPECAM_CLIENT=ON -DWITH_RDPECAM_GSTREAMER=ON \
    -DWITH_RDPECAM_MOVIE=OFF -DWITH_RDPECAM_UVC_H264=OFF > "$OUT/configure.log" 2>&1 ||
    { tail -40 "$OUT/configure.log"; exit 1; }
grep -q -x 'WITH_RDPECAM_GSTREAMER:BOOL=ON' "$B/CMakeCache.txt" ||
    { echo "no GStreamer backend (configure.log)" >&2; exit 1; }
cmake --build "$B" --target xfreerdp > "$OUT/build.log" 2>&1 || { tail -40 "$OUT/build.log"; exit 1; }
exe=$(find "$B" -name xfreerdp -type f -perm -u+x | head -1)
cp "$exe" "$OUT/xfreerdp"
grep -a -q -F "rdpecam-gst.client" "$OUT/xfreerdp" || { echo "no gst backend in xfreerdp" >&2; exit 1; }
echo "== $OUT/xfreerdp"
