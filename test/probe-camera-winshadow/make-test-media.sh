#!/bin/bash
# The camera probes' media (copied from probe-camera-win), made on the Linux build job with the CI's FFmpeg (build/ci-ffmpeg.sh,
# a GPL build: test data only, uploaded as a 1-day artifact, never put into a zip):
#
#   make-test-media.sh <ffmpeg> <out dir>
#
# test.mp4: 20 s of FFmpeg's testsrc2 (a moving picture with a counter), H.264 constrained
# baseline, 640x360, 30 fps, faststart: what Windows' MPEG-4 source and H.264 decoder read, and
# what the client's rdpecam mf backend (file:) plays as the camera.
# test.jpg: one 640x360 baseline JPEG, 4:2:2 as webcams send MJPG, for the MJPEG decoder check.
set -euo pipefail
ffmpeg=${1:?usage: make-test-media.sh <ffmpeg> <out dir>}
out=${2:?usage: make-test-media.sh <ffmpeg> <out dir>}
mkdir -p "$out"
"$ffmpeg" -hide_banner -loglevel error -y -f lavfi -i testsrc2=size=640x360:rate=30 -t 20 \
    -c:v libx264 -profile:v baseline -pix_fmt yuv420p -g 30 -movflags +faststart "$out/test.mp4"
"$ffmpeg" -hide_banner -loglevel error -y -f lavfi -i testsrc2=size=640x360:rate=1 -frames:v 1 \
    -c:v mjpeg -pix_fmt yuvj422p -q:v 3 "$out/test.jpg"
ls -l "$out"
