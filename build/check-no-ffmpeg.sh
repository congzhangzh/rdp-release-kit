#!/bin/bash
# check-no-ffmpeg.sh <dir>: fails if any archive in <dir> (the release's upload folder) holds an
# ffmpeg or ffprobe program. The demos record with a static GPL FFmpeg (build/ci-ffmpeg.sh,
# choco or Homebrew on the other runners): a CI tool only, never part of what we ship. Our
# clients and hosts are built without FFmpeg (WITH_FFMPEG=OFF), so any hit is a packaging slip.
set -euo pipefail
dir=${1:?usage: check-no-ffmpeg.sh <dir>}
status=0
shopt -s nullglob
for f in "$dir"/*.tar.xz "$dir"/*.zip "$dir"/*.deb "$dir"/*.rpm; do
    case $f in
        *.tar.xz) list=$(tar -tJf "$f") ;;
        *.zip) list=$(unzip -Z1 "$f") ;;
        *.deb) list=$(dpkg-deb -c "$f" | awk '{print $NF}') ;;
        *.rpm) list=$(rpm -qlp "$f" 2> /dev/null || true) ;;
    esac
    hits=$(printf '%s\n' "$list" | grep -E '(^|/)(ffmpeg|ffprobe)(\.exe)?$' || true)
    if [ -n "$hits" ]; then
        echo "::error::check-no-ffmpeg: $(basename "$f") holds $(echo "$hits" | tr '\n' ' ')"
        status=1
    fi
done
[ $status = 0 ] && echo "check-no-ffmpeg: no ffmpeg or ffprobe in any archive of $dir"
exit $status
