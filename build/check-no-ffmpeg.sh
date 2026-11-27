#!/bin/bash
# check-no-ffmpeg.sh <dir>: fails if any archive in <dir> (the release's upload folder) holds
#  - an ffmpeg or ffprobe program: the demos record with a static GPL FFmpeg (build/ci-ffmpeg.sh,
#    choco or Homebrew on the other runners), a CI tool only, never part of what we ship;
#  - GPL FFmpeg code: some clients link FFmpeg's libraries to decode H.265/H.264 (Linux, Windows),
#    and those must be LGPL, decoders only (the product owner, 2026-11-27: "nothing GPL ships",
#    enforced here, not only promised). A file fails when it carries FFmpeg's GPL or nonfree
#    licence string ("libavcodec license: GPL ...", what avcodec_license() returns), a configure
#    line with --enable-gpl, --enable-nonfree, --enable-libx264 or --enable-libx265, or the x264/x265
#    encoder entry points or x264's own banner. Plain "x264" is not searched: the LGPL H.264 decoder
#    itself contains "x264 - core" (it reads x264's SEI version note).
# Every program and library is searched, so FFmpeg or x264 linked statically into another is caught too.
# build/gpl-allow.txt names the archives whose GPL code is a known, decided exception (a warning), and
# what the GPL asks for in return, which is checked here too: the source assets that must be in the
# same <dir> (sources=, e.g. gpl-source-x264-*.tar.xz for xrdp's static x264, the product owner's
# decision of 2026-11-27: we keep x264 and comply), else a failure, and the licence file the archive
# itself must hold (licence=, LICENSE.x264). Only code is searched (ELF, PE, Mach-O, wasm), so those
# source archives, GPL source text and nested .tar files, are no failure themselves.
set -euo pipefail
dir=${1:?usage: check-no-ffmpeg.sh <dir>}
status=0
shopt -s nullglob
gpl='libav[a-z]+ license: (GPL|nonfree)|--enable-(gpl|nonfree|libx264|libx265)\b|x264_encoder_open|x265_encoder_open|x265_api_get|H\.264/MPEG-4 AVC codec - Copy'
allow=$(dirname "$0")/gpl-allow.txt
base=${RUNNER_TEMP:-${TMPDIR:-$HOME/tmp}}
mkdir -p "$base"
tmp=$(mktemp -d "$base/check-no-ffmpeg.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
# the source assets the allowed GPL code needs ("<glob> <archive>", from sources= of its allow line)
needs=()
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
    why='' sources='' licence=''
    while read -r glob reason; do
        case $glob in ''|'#'*) continue ;; esac
        # shellcheck disable=SC2053  # the glob is meant to match
        [[ $(basename "$f") == $glob ]] || continue
        # the conditions (sources=, licence=) first, then the reason
        while :; do
            case $reason in
                sources=*) sources=${reason%% *}; sources=${sources#sources=} ;;
                licence=*) licence=${reason%% *}; licence=${licence#licence=} ;;
                *) break ;;
            esac
            if [[ $reason == *' '* ]]; then reason=${reason#* }; else reason=; fi
        done
        why=$reason   # no reason, no exception
        break
    done < "$allow"
    allowed=
    out="$tmp/$(basename "$f")"
    mkdir -p "$out"
    case $f in
        *.tar.xz) tar -xJf "$f" -C "$out" ;;
        *.zip) unzip -q "$f" -d "$out" ;;
        *.deb) dpkg-deb -x "$f" "$out" ;;
        *.rpm) if command -v rpm2cpio > /dev/null; then (abs=$(realpath "$f") && cd "$out" && rpm2cpio "$abs" | cpio -idm --quiet); else
                   echo "::error::check-no-ffmpeg: no rpm2cpio to look inside $(basename "$f")"; status=1; fi ;;
    esac
    while IFS= read -r -d '' bin; do
        # only code: ELF, PE, Mach-O (thin or fat) and wasm; a video encoded with x264 carries x264's
        # banner as data (freerdp-web's mascot.mp4), which is not code that ships
        case $(head -c 4 "$bin" | od -An -tx1 | tr -d ' \n') in
            7f454c46 | 4d5a* | cffaedfe | cefaedfe | cafebabe | 0061736d) ;;
            *) continue ;;
        esac
        what=$(grep -a -o -m 3 -E "$gpl" "$bin" | sort -u | tr '\n' ';' || true)
        if [ -n "$what" ] && [ -n "$why" ]; then
            echo "::warning::check-no-ffmpeg: $(basename "$f"): ${bin#"$out"/} has GPL code ($what), allowed: $why"
            allowed=1
        elif [ -n "$what" ]; then
            echo "::error::check-no-ffmpeg: $(basename "$f"): ${bin#"$out"/} has GPL code ($what)"
            status=1
        fi
        lgpl=$(grep -a -o -m 1 -E 'libav[a-z]+ license: LGPL[[:print:]]{0,24}' "$bin" | tr -d '\0' | head -1 || true)
        [ -n "$lgpl" ] && echo "check-no-ffmpeg: $(basename "$f"): ${bin#"$out"/}: $lgpl"
    done < <(find "$out" -type f -print0)
    # allowed GPL code: its licence in the archive now, its source beside it (after the loop)
    if [ -n "$allowed" ]; then
        if [ -n "$licence" ] && [ -z "$(find "$out" -type f -name "$licence" -print -quit)" ]; then
            echo "::error::check-no-ffmpeg: $(basename "$f") has allowed GPL code but no $licence in it (build/gpl-allow.txt)"
            status=1
        fi
        IFS=, read -r -a globs <<< "$sources"
        for g in "${globs[@]}"; do needs+=("$g $(basename "$f")"); done
    fi
    rm -rf "$out"
done
# each source asset the allowed GPL code needs, in the same upload
for need in "${needs[@]}"; do
    g=${need%% *}
    # shellcheck disable=SC2206  # the glob is meant to expand (nullglob)
    files=("$dir"/$g)
    if [ ${#files[@]} = 0 ]; then
        echo "::error::check-no-ffmpeg: ${need#* } has allowed GPL code, but $dir has no $g, its source (build/gpl-allow.txt)"
        status=1
    fi
done
if [ $status = 0 ]; then
    echo "check-no-ffmpeg: no ffmpeg/ffprobe program and no GPL code outside build/gpl-allow.txt in $dir"
    [ ${#needs[@]} = 0 ] || echo "check-no-ffmpeg: the allowed GPL code has its licence and its source (${#needs[@]} source assets found)"
fi
exit $status
