#!/bin/bash
# Demo 1.2 of the product plan: the kit's FreeRDP shadow server on Linux (X11), seen by the
# kit's Linux client with /multimon on two screens, in AV1 4:2:0. Both from a release, as
# released (no stubs), each in a container of its own on a private network
# (test/demo-shadow-multimon/): the server's X screen is 2560x720 with a ticking clock on each
# half; the client's two screens are weston's two outputs of 1280x720, side by side. The video
# is the client's display, ~30 s, with the client's overlay (decoder, frames, bandwidth):
#
#   test/demo-shadow-multimon.sh [host archive] [client archive]
#
# Without archives it takes freerdp-host-*-linux-x86_64.tar.xz and
# sdl3-freerdp-*-linux-x86_64.tar.xz of the kit release KIT_TAG (default: the newest), each
# checked against its SHA256SUMS. Out: dist/demo-shadow-multimon/ (OUT=<dir> for another):
# shadow-multimon.mp4 (2560x720, H.264 CRF 28) and .jpg (a poster from 70 %), its caption and
# numbers (shadow-multimon.txt), the logs, the overlay's numbers each second (stats.jsonl).
# DEMO_SECONDS=<n> records another length. NAME=<prefix> names the containers and the network
# (default kit-demo-shadow-mm). The recorder is build/ci-ffmpeg.sh's (FFMPEG_DIR=<dir> for
# its folder). PODMAN or docker: ENGINE=<command>. FONT=<ttf> the titles' font (default
# DejaVu Sans). KIT_VERSION=<name> names the kit in the title (default: KIT_TAG, else the
# kit commit in the client's MANIFEST).
#
# The video's own text, drawn at the encode below the recording's content: a lower third (the
# kit and FreeRDP release, the caption's first sentence, the limit). The client's own overlay
# is shown as it is: a client built with the kit's .source_version (build/lib.sh) names its
# release there, an older one its development version.
#
# What it shows, and what not (the plan's caption, word for word): the shadow shares one X
# screen as one desktop, and the client spreads it over its two screens. A server with two
# monitors shares only one (/monitors:N). The shadow doesn't resize (no Display Control).
set -euo pipefail
KIT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$KIT/dist/demo-shadow-multimon}
REPO=congzhangzh/rdp-release-kit
NAME=${NAME:-kit-demo-shadow-mm}
SECONDS_REC=${DEMO_SECONDS:-30}
ENGINE=${ENGINE:-$(command -v docker || command -v podman)}
FFMPEG_DIR=${FFMPEG_DIR:-$HOME/.cache/rdp-release-kit/ci-ffmpeg}
FONT=${FONT:-/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf}
[ -f "$FONT" ] || { echo "no font for the titles: $FONT (FONT=<ttf>)" >&2; exit 1; }
CAPTION="The shadow shares one X screen as one desktop, and the client spreads it over its two screens. A server with two monitors shares only one (/monitors:N). The shadow doesn't resize. Real multi-monitor and resizing: see the xrdp demo."

rm -rf "$OUT"
mkdir -p "$OUT/in" "$OUT/run"
HOST=${1:-} CLIENT=${2:-}
if [ -z "$HOST" ] || [ -z "$CLIENT" ]; then
    tag=${KIT_TAG:-$(gh release view -R "$REPO" --json tagName -q .tagName)}
    echo "== the archives of kit release $tag"
    gh release download "$tag" -R "$REPO" -D "$OUT/in" -p SHA256SUMS \
        -p 'freerdp-host-*-linux-x86_64.tar.xz' -p 'sdl3-freerdp-*-linux-x86_64.tar.xz'
    (cd "$OUT/in" && sha256sum -c --ignore-missing --quiet SHA256SUMS) ||
        { echo "the archives don't match the release's SHA256SUMS" >&2; exit 1; }
    HOST=$(ls "$OUT"/in/freerdp-host-*-linux-x86_64.tar.xz)
    CLIENT=$(ls "$OUT"/in/sdl3-freerdp-*-linux-x86_64.tar.xz)
else
    cp "$HOST" "$CLIENT" "$OUT/in/"
    HOST=$OUT/in/$(basename "$HOST") CLIENT=$OUT/in/$(basename "$CLIENT")
fi
echo "== server: $(basename "$HOST"); client: $(basename "$CLIENT")"
# the names in the titles: FreeRDP's release and the kit, from the client's MANIFEST
manifest=$(tar -xJOf "$CLIENT" --wildcards '*/MANIFEST')
FREERDP=release-$(sed -n 's/^sdl3-freerdp \([^ ]*\) .*/\1/p' <<< "$manifest" | head -1)
KIT_NAME=${KIT_VERSION:-${tag:-}}
[ -n "$KIT_NAME" ] || KIT_NAME="commit $(sed -n 's/^kit: rdp-release-kit \([0-9a-f]\{12\}\).*/\1/p' <<< "$manifest")"

"$KIT/build/ci-ffmpeg.sh" "$FFMPEG_DIR" > "$OUT/ffmpeg-version.txt"
export PATH=$FFMPEG_DIR/bin:$PATH

# the server's background: one gradient across the whole X screen, each half labelled, so one
# desktop spread over two screens shows at a glance
printf 'server screen, left half' > "$OUT/in/left.txt"
printf 'server screen, right half' > "$OUT/in/right.txt"
ffmpeg -v error -y -f lavfi -i "gradients=s=2560x720:c0=0x1d3557:c1=0x2a9d8f:x0=0:y0=360:x1=2559:y1=360:nb_colors=2" \
    -frames:v 1 -vf "drawtext=fontfile=$FONT:textfile=$OUT/in/left.txt:expansion=none:fontsize=30:fontcolor=white@0.85:x=(1280-tw)/2:y=292,drawtext=fontfile=$FONT:textfile=$OUT/in/right.txt:expansion=none:fontsize=30:fontcolor=white@0.85:x=1280+(1280-tw)/2:y=292" \
    "$OUT/in/background.png"

IMAGE=kit-demo-shadow-mm:debian-13
"$ENGINE" build -q -t "$IMAGE" "$KIT/test/demo-shadow-multimon" > "$OUT/image-build.log" 2>&1 ||
    { tail -20 "$OUT/image-build.log" >&2; echo "the demo image did not build" >&2; exit 1; }

cleanup() {
    "$ENGINE" rm -f "$NAME-server" "$NAME-client" > /dev/null 2>&1 || true
    "$ENGINE" network rm "$NAME-net" > /dev/null 2>&1 || true
}
trap cleanup EXIT
# mean brightness (Y, 16 = black) of one half of the recording, a frame from its middle
half() {
    local len
    len=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$1")
    ffmpeg -v error -ss "$(awk -v d="$len" 'BEGIN { printf "%.1f", d / 2 }')" -i "$1" -frames:v 1 \
        -vf "crop=1280:720:$2:0,signalstats,metadata=print:key=lavfi.signalstats.YAVG:file=-" -f null - 2>&1 |
        sed -n 's/.*YAVG=\([0-9.]*\).*/\1/p' | head -1
}

# record: the two containers, the client's display in $OUT/run
record() {
    cleanup
    mkdir -p "$OUT/run"
    "$ENGINE" network create "$NAME-net" > /dev/null
    local mounts=(-v "$KIT/test/demo-shadow-multimon":/demo:ro -v "$OUT/in":/in:ro -v "$OUT/run":/out)
    echo "== server: the shadow on a 2560x720 X screen"
    "$ENGINE" run -d --name "$NAME-server" --network "$NAME-net" --network-alias shadow "${mounts[@]}" \
        "$IMAGE" /demo/server.sh "/in/$(basename "$HOST")" /in/background.png > /dev/null
    for _ in $(seq 60); do
        "$ENGINE" exec "$NAME-server" sh -c 'grep -q ":0D3D .* 0A " /proc/net/tcp' 2> /dev/null && break
        sleep 0.5
    done
    echo "== client: /multimon on weston's two outputs, recorded for $SECONDS_REC s"
    "$ENGINE" run --name "$NAME-client" --network "$NAME-net" "${mounts[@]}" -v "$FFMPEG_DIR":/ffmpeg:ro \
        "$IMAGE" /demo/client.sh "/in/$(basename "$CLIENT")" shadow "$SECONDS_REC" > "$OUT/run/client-run.log" 2>&1 ||
        { tail -20 "$OUT/run/client-run.log" >&2; echo "the client run failed" >&2; return 1; }
    "$ENGINE" stop -t 3 "$NAME-server" > /dev/null 2>&1 || true
    # both screens drawn: now and then the client's second window stays black for a whole
    # session (seen once in four runs, 2026-11-24; under investigation in the SDL client)
    LEFT=$(half "$OUT/run/raw.mp4" 0) RIGHT=$(half "$OUT/run/raw.mp4" 1280)
    awk -v l="${LEFT:-0}" -v r="${RIGHT:-0}" 'BEGIN { exit !(l > 20 && r > 20) }'
}

# a demo is a recording: one more try when a screen stayed black
if ! record; then
    echo "NOTE  a screen stayed black (left Y ${LEFT:-?}, right Y ${RIGHT:-?}): a second try"
    mv "$OUT/run" "$OUT/run-try1"
    record || true
fi

# the checks: what the demo claims must be in its logs
status=0
check() { if eval "$2"; then echo "PASS  $1"; else echo "FAIL  $1"; status=1; fi; }
L=$OUT/run
check "both screens are drawn (mean Y left $LEFT, right $RIGHT; black is 16)" \
    'awk -v l="${LEFT:-0}" -v r="${RIGHT:-0}" "BEGIN { exit !(l > 20 && r > 20) }"'
check "the client has two screens" '[ "$(grep -c "^ *[* ] \[" "$L/client-monitors.txt")" = 2 ]'
check "the shadow shares one desktop of 2560x720" 'grep -qE "(activated|resize requested) \(2560x720" "$L/server.log"'
check "AV1 4:2:0 was agreed (no AV2, no 4:4:4)" 'grep -q "AV1_I444_DISABLED" "$L/server.log"'
check "the server encoded AV1 4:2:0" 'grep -q "I420: [0-9]* frames" "$L/server.log"'
check "the client decoded AV1" 'grep -q "AV1 decoder: " "$L/client.log"'
check "the overlay's numbers came" '[ -s "$L/stats.jsonl" ]'
check "the video was recorded" '[ -s "$L/raw.mp4" ]'

# the numbers, from the logs and the last reading of the overlay
encoder=$(grep -o "AV1 encoder: .*" "$L/server.log" | head -1 || true)
[ -n "$encoder" ] || encoder=$(grep -o "AV1 [0-9]*x[0-9]* I420: .*" "$L/server.log" | tail -1 || true)
decoder=$(grep -o "AV1 decoder: .*" "$L/client.log" | head -1 || true)
# the server's own encoder reading, every 5 s: the last one
encoded=$(grep -o "AV1 [0-9]*x[0-9]* I420: .*" "$L/server.log" | tail -1 || true)
numbers=$(python3 - "$L/stats.jsonl" << 'PY'
import json, sys
# the overlay's rows of the last reading: [label, value], a row without a label goes on the one before
rows = {}
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    try:
        snap = json.loads(line)
    except ValueError:
        continue
    rows = {}
    for side in ("client", "server", "realtime"):
        last = None
        for label, value in (snap.get("rows") or {}).get(side) or []:
            if label:
                rows[label] = value
                last = label
            elif last:
                rows[last] += "; " + value
for label in ("Resolution", "Surface 1", "AV1 decoder", "Video codecs", "AV1 4:2:0 results", "Frames",
              "Network in", "Network in (RDP)", "Session"):
    if label in rows:
        print(f"{label}: {rows[label]}")
PY
)
{
    echo "$CAPTION"
    echo
    echo "Kit: $KIT_NAME; FreeRDP: $FREERDP"
    echo "Server: $(basename "$HOST"), freerdp-shadow-cli /subsystem:x11 /gfx-av1 /gfx-av2:off -gfx-avc444, one X screen 2560x720."
    echo "Client: $(basename "$CLIENT"), sdl-freerdp /multimon /gfx:AV2:off,AV1:i420 +sdl-info on two 1280x720 screens (weston)."
    echo "Encoder: ${encoder:-not logged}"
    echo "Encoded (server): ${encoded:-not logged}"
    echo "Decoder: ${decoder:-not logged}"
    echo "$numbers"
} > "$OUT/shadow-multimon.txt"
cat "$OUT/shadow-multimon.txt"

if [ -s "$L/raw.mp4" ]; then
    # the titles: a lower third across both screens, where the recording has only the background
    printf 'rdp-release-kit %s  ·  FreeRDP %s  ·  AV1 4:2:0, the Linux shadow (X11) and client' "$KIT_NAME" "$FREERDP" > "$L/title-1.txt"
    printf '%s' "The shadow shares one X screen as one desktop, and the client spreads it over its two screens." > "$L/title-2.txt"
    printf '%s' "A server with two monitors shares only one (/monitors:N). It doesn't resize: resizing, see the xrdp demo." > "$L/title-3.txt"
    t="fontfile=$FONT:expansion=none"
    titles="drawbox=x=0:y=624:w=2560:h=96:color=black@0.62:t=fill"
    titles+=",drawtext=$t:textfile=$L/title-1.txt:fontsize=22:fontcolor=0xFFD166:x=40:y=634"
    titles+=",drawtext=$t:textfile=$L/title-2.txt:fontsize=24:fontcolor=white:x=40:y=662"
    titles+=",drawtext=$t:textfile=$L/title-3.txt:fontsize=24:fontcolor=white:x=40:y=692"
    if ffmpeg -v error -y -i "$L/raw.mp4" -vf "$titles,format=yuv420p" -c:v libx264 -crf 28 \
        -preset slow -profile:v high -movflags +faststart "$OUT/shadow-multimon.mp4"; then
        # read by the check below, in the string it evaluates
        # shellcheck disable=SC2034
        titled=yes
    fi
    len=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT/shadow-multimon.mp4")
    ffmpeg -v error -y -ss "$(awk -v d="$len" 'BEGIN { printf "%.1f", d * 0.7 }')" -i "$OUT/shadow-multimon.mp4" \
        -frames:v 1 -q:v 4 "$OUT/shadow-multimon.jpg"
    # the titles are in the frames: the lower third's text is bright where the recording has none
    third=$(ffmpeg -v error -ss 5 -i "$OUT/shadow-multimon.mp4" -frames:v 1 \
        -vf "crop=2560:90:0:628,signalstats,metadata=print:key=lavfi.signalstats.YMAX:file=-" -f null - 2>&1 |
        sed -n 's/.*YMAX=\([0-9.]*\).*/\1/p' | head -1)
fi
check "the titles were drawn (lower third YMAX ${third:-none})" \
    '[ "${titled:-}" = yes ] && awk -v m="${third:-0}" "BEGIN { exit !(m > 200) }"'
echo "demo: $OUT/shadow-multimon.mp4 ($([ $status = 0 ] && echo passed || echo FAILED))"
exit $status
