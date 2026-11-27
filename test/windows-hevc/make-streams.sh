#!/bin/bash
# The HEVC pictures kit-hevc-decode.exe decodes, made on a Linux runner:
#
#   test/windows-hevc/make-streams.sh <ffmpeg> <out dir>
#
# writes <out dir>/quadrants-420.hevc and quadrants-444.hevc: one 256x256 key frame each, four
# flat quadrants (red, green, blue, yellow, as TestFreeRDPCodecHEVC.c), Annex B. The YUV planes are
# computed here with FreeRDP's own RGB to YUV (libfreerdp/primitives/prim_internal.h, RGB2Y/U/V),
# so FreeRDP's YUV to RGB gives the colours back; the encoder only compresses them (rawvideo in,
# no colour conversion). <ffmpeg> is the CI's GPL FFmpeg (build/ci-ffmpeg.sh) for its libx265:
# a CI tool, its output is test data in its own artifact, never in a zip that ships.
set -euo pipefail
ffmpeg=${1:?usage: make-streams.sh <ffmpeg> <out dir>}
out=${2:?usage: make-streams.sh <ffmpeg> <out dir>}
mkdir -p "$out"
python3 -I - "$out" << 'EOF'
import sys
W = H = 256
colours = [(230, 30, 30), (30, 200, 30), (30, 30, 230), (230, 220, 30)]
def yuv(r, g, b):
    # Python's >> floors like C's on these values (no negative sums reach it unshifted)
    return ((54 * r + 183 * g + 18 * b) >> 8,
            ((-29 * r - 99 * g + 128 * b) >> 8) + 128,
            ((128 * r - 116 * g - 12 * b) >> 8) + 128)
def quadrant(x, y, w, h):
    return (2 if y >= h // 2 else 0) + (1 if x >= w // 2 else 0)
def plane(k, w, h):
    return bytes(yuv(*colours[quadrant(x, y, w, h)])[k] for y in range(h) for x in range(w))
out = sys.argv[1]
with open(f"{out}/quadrants-420.yuv", "wb") as f:
    f.write(plane(0, W, H) + plane(1, W // 2, H // 2) + plane(2, W // 2, H // 2))
with open(f"{out}/quadrants-444.yuv", "wb") as f:
    f.write(plane(0, W, H) + plane(1, W, H) + plane(2, W, H))
EOF
# Main and Main 4:4:4 (keyint=1 would make it an intra-only RExt profile, which a Media Foundation
# decoder may refuse: one key frame is enough)
for p in 420 444; do
    profile=main
    [ $p = 420 ] || profile=main444-8
    "$ffmpeg" -hide_banner -loglevel error -y -f rawvideo -pix_fmt "yuv${p}p" -s 256x256 \
        -i "$out/quadrants-$p.yuv" -frames:v 1 -c:v libx265 -preset ultrafast -tune zerolatency \
        -profile:v $profile -x265-params "qp=4:log-level=error" -f hevc "$out/quadrants-$p.hevc"
    rm "$out/quadrants-$p.yuv"
    echo "quadrants-$p.hevc: $(stat -c %s "$out/quadrants-$p.hevc") bytes"
done
