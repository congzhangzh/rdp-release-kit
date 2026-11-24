#!/bin/bash
# The demos' recorder for CI, Linux x86_64 or aarch64:
#
#   build/ci-ffmpeg.sh <dir>      ffmpeg and ffprobe in <dir>/bin, their version on stdout
#
# A static FFmpeg 8.1 build (BtbN/FFmpeg-Builds, its rolling "latest" release) from GitHub's
# own download servers, checked against that release's checksums.sha256. Not apt: on an AWS
# runner (us-east-2.ec2.archive.ubuntu.com) apt fetched ffmpeg's 70 packages at a trickle until
# the step's 15-minute limit, three attempts running (kit run 45308427234), and the old
# fallback only knew Azure's mirror. It is a GPL build and a CI tool only: it never goes into
# a release asset, which build/check-no-ffmpeg.sh checks before every upload. It fails loudly,
# never leaves a demo without its recorder.
set -euo pipefail
dir=${1:?usage: ci-ffmpeg.sh <dir>}
case "$(uname -s)-$(uname -m)" in
    Linux-x86_64) arch=linux64 ;;
    Linux-aarch64) arch=linuxarm64 ;;
    *) echo "::error::ci-ffmpeg: no static build for $(uname -sm)" >&2; exit 1 ;;
esac
name=ffmpeg-n8.1-latest-$arch-gpl-8.1.tar.xz
base=https://github.com/BtbN/FFmpeg-Builds/releases/download/latest
mkdir -p "$dir/bin"
if [ ! -x "$dir/bin/ffmpeg" ]; then
    tmp=$(mktemp -d)
    curl -fsSL --retry 5 --retry-all-errors --connect-timeout 30 --max-time 300 -o "$tmp/$name" "$base/$name"
    curl -fsSL --retry 5 --retry-all-errors --connect-timeout 30 -o "$tmp/checksums.sha256" "$base/checksums.sha256"
    line=$(grep "  $name\$" "$tmp/checksums.sha256") ||
        { echo "::error::ci-ffmpeg: $name is not in the release's checksums.sha256" >&2; exit 1; }
    (cd "$tmp" && echo "$line" | sha256sum -c --quiet -) ||
        { echo "::error::ci-ffmpeg: $name does not match its checksum" >&2; exit 1; }
    tar -xJf "$tmp/$name" -C "$tmp" --wildcards '*/bin/ffmpeg' '*/bin/ffprobe'
    mv "$tmp"/ffmpeg-*/bin/ffmpeg "$tmp"/ffmpeg-*/bin/ffprobe "$dir/bin/"
    rm -rf "$tmp"
fi
"$dir/bin/ffmpeg" -hide_banner -version | head -1
