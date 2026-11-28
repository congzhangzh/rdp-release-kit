#!/bin/bash
# linux-shadow.sh <host dir> <page dir> <out dir>: FreeRDP Web's camera into the Linux host's
# virtual camera, end to end, on this CI runner (never on a developer's machine: it loads a kernel
# module). The host is the released one (FreeRDP's shadow server, its camera on v4l2loopback),
# the page is the one under test with its client, served from http://localhost (a secure
# context), reached through websockify, in headless Chrome with Chrome's fake camera.
#
# Checks: the page offers the camera (Chrome encodes H.264), the browser allows it, the host
# chooses H264 for the browser's camera; then twice (on demand: Start, Stop, Start, Stop) an app
# on the host reads >= 60 changing frames that the host decoded, and after it closed the camera
# the client logs its counters (bit rate sent, first-sample delay, encode time) with exactly one
# key frame for that stream (no periodic key frame: the second stream decodes from its own);
# no camera error on either side. Results: <out dir>/result.txt (PASS/FAIL/INFO lines), logs
# beside it.
set -uo pipefail

HOSTDIR=$(realpath "${1:?usage: linux-shadow.sh <host dir> <page dir> <out dir>}")
PAGE=$(realpath "${2:?}")
OUT=${3:?}
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$OUT"
OUT=$(realpath "$OUT")
CAM_DEV=/dev/video41
PORT=33891
WS_PORT=13390
HTTP_PORT=8080
WIDTH=1280
HEIGHT=720
SAFE=(env -u DBUS_SESSION_BUS_ADDRESS -u XDG_RUNTIME_DIR -u WAYLAND_DISPLAY -u DISPLAY)
PIDS=()
status=0

# shellcheck disable=SC2329  # the EXIT trap runs it
cleanup() {
    for p in "${PIDS[@]}"; do kill -TERM "$p" 2> /dev/null; done
    sleep 1
    for p in "${PIDS[@]}"; do kill -KILL "$p" 2> /dev/null; done
    wait 2> /dev/null
}
trap cleanup EXIT

check() {
    if bash -o pipefail -c "$2"; then
        echo "PASS  $1${3:+ ($3)}" | tee -a "$OUT/result.txt"
    else
        echo "FAIL  $1${3:+ ($3)}" | tee -a "$OUT/result.txt"
        status=1
    fi
}
info() { echo "INFO  $*" | tee -a "$OUT/result.txt"; }
mark() { echo "$(date +%H:%M:%S.%3N) $*" | tee -a "$OUT/events.txt"; }
wait_for() {
    local i
    for ((i = 0; i < $1 * 5; i++)); do
        bash -c "$2" && return 0
        sleep 0.2
    done
    return 1
}
camera_lines() { grep -F 'com.freerdp.server.shadow.camera' "$OUT/host.log" || true; }

: > "$OUT/result.txt"
info "v4l2loopback $(cat /sys/module/v4l2loopback/version 2> /dev/null || echo '(no version)'), kernel $(uname -r)"
info "host: $(grep -m1 -E '^FreeRDP' "$HOSTDIR/MANIFEST" 2> /dev/null || echo '?')"
info "page: $(grep -m1 -E '^page:' "$PAGE/MANIFEST" 2> /dev/null || echo '?')"
check "the host's camera device is named exactly [FreeRDP Camera]" \
    "[ \"\$(cat /sys/devices/virtual/video4linux/video41/name)\" = 'FreeRDP Camera' ]"

# the host, on its own Xvfb, no authentication, 127.0.0.1 only
"${SAFE[@]}" Xvfb :91 -screen 0 1024x768x24 -nolisten tcp -noreset > "$OUT/xvfb.log" 2>&1 &
PIDS+=($!)
wait_for 20 "xdpyinfo -display :91 > /dev/null 2>&1" || { echo "Xvfb did not start" >&2; exit 1; }
"${SAFE[@]}" DISPLAY=:91 XDG_CONFIG_HOME="$OUT/host-config" WLOG_LEVEL=INFO \
    "$HOSTDIR/bin/freerdp-shadow-cli" /port:$PORT /bind-address:127.0.0.1 -auth /subsystem:x11 \
    > "$OUT/host.log" 2>&1 &
PIDS+=($!)
wait_for 30 "ss -ltn | grep -q ':$PORT '" || { echo "the host does not listen" >&2; tail -20 "$OUT/host.log"; exit 1; }
mark "host listening"

# the gateway and the page (localhost: a secure context, as the published https page)
websockify 127.0.0.1:$WS_PORT 127.0.0.1:$PORT > "$OUT/websockify.log" 2>&1 &
PIDS+=($!)
python3 -m http.server $HTTP_PORT --bind 127.0.0.1 -d "$PAGE" > "$OUT/http.log" 2>&1 &
PIDS+=($!)
wait_for 20 "ss -ltn | grep -q ':$WS_PORT ' && ss -ltn | grep -q ':$HTTP_PORT '" ||
    { echo "the gateway or the page server did not start" >&2; exit 1; }

# the browser: it ticks Camera, connects, keeps the counters until reader-done
node "$HERE/web-camera.mjs" "http://localhost:$HTTP_PORT/" "127.0.0.1:$WS_PORT" "$OUT" "$OUT/reader-done" \
    > "$OUT/browser.txt" 2>&1 &
BROWSER=$!
PIDS+=("$BROWSER")
mark "browser started"

if wait_for 90 "grep -q 'camera: \".*\" of client .*: chose' '$OUT/host.log'"; then
    mark "host chose: $(camera_lines | grep -m1 ': chose' | sed 's/.*camera: //')"
fi
check "the host chose H264 for the browser's camera" "camera_lines() { grep -F 'com.freerdp.server.shadow.camera' '$OUT/host.log'; }; camera_lines | grep -q ': chose H264 '"

# an app reads the host's camera: the host starts the browser's stream (on demand), stops it
# about 500 ms after the app closed it; the client releases the browser's camera then. Twice.
v4l2-ctl -d $CAM_DEV --all > "$OUT/camera-device.txt" 2>&1 || true
for n in 1 2; do
    mark "reader $n opens $CAM_DEV"
    timeout 90 v4l2-ctl -d $CAM_DEV --stream-mmap=4 --stream-count=240 --stream-to="$OUT/read-$n.yuyv" \
        > "$OUT/read-$n.log" 2>&1
    mark "reader $n closed $CAM_DEV (rc $?)"
    check "stream $n: an app reads >= 60 changing frames, the browser's H.264 decoded by the host" \
        "python3 '$HERE/camera-frames.py' '$OUT/read-$n.yuyv' $WIDTH $HEIGHT 60 | tee '$OUT/frames-$n.txt'"
    # the client stops its stream (Stop Streams, or 2 s without sample requests)
    wait_for 20 "[ \$(grep -c 'camera web0 stopped: H264 ' '$OUT/page-live.log' 2> /dev/null) -ge $n ]" ||
        mark "stream $n: the client's stop line did not come in 20 s"
done
touch "$OUT/reader-done"
wait "$BROWSER"
mark "browser done (rc $?)"

# what the browser and the client said; the client's lines from the page's own log (page.log
# carries the browser console's copy of each line after it)
sed '/^--- console ---$/q' "$OUT/page.log" > "$OUT/client.log"
check "the page's log ends where the console's copy begins (the counts below read it once)" \
    "grep -q -x -- '--- console ---' '$OUT/page.log'"
cat "$OUT/browser.txt"
check "the page offers Camera (the browser encodes H.264)" "grep -q '\"checkboxDisabled\":false' '$OUT/browser.txt'"
check "the browser allowed the camera after Camera was ticked" "grep -q '\"permission\":\"allowed\"' '$OUT/browser.txt'"
check "the session's options carry /dvc:rdpecam,sys:emscripten" "grep -q 'dvc:rdpecam,sys:emscripten' '$OUT/browser.txt'"
check "the client started H264 twice, a first sample each time" \
    "[ \$(grep -c 'camera web0: start H264 ' '$OUT/client.log') = 2 ] && [ \$(grep -c 'camera web0: first H264 sample' '$OUT/client.log') = 2 ]"
check "the client released the camera after each stream, with its counters" \
    "[ \$(grep -c 'camera web0 stopped: H264 ' '$OUT/client.log') = 2 ]"
check "exactly one key frame per stream (no periodic key frame)" \
    "[ \$(grep -o 'camera web0 stopped: H264 .*' '$OUT/client.log' | grep -c '(1 key)') = 2 ]"
check "no camera error in the client" \
    "! grep -E '\\[(ERROR|WARN)\\]\\[com\\.freerdp\\.channels\\.rdpecam|\\[rdpecam\\] camera .* failed|cannot be sent' '$OUT/client.log'"
check "no camera error in the host" \
    "! grep -E '\\[ERROR\\]\\[com\\.freerdp\\.server\\.shadow\\.camera' '$OUT/host.log'"
info "client: $(grep -o 'camera web0: start H264 [^\"]*' "$OUT/client.log" | head -1)"
grep -o 'camera web0: first H264 sample [^"]*' "$OUT/client.log" | while read -r l; do info "client: $l"; done
grep -o 'camera web0 stopped: H264 [^"]*' "$OUT/client.log" | while read -r l; do info "client: $l"; done
info "browser: $(grep -o '"browser":"[^"]*"' "$OUT/browser.txt")"
info "host: $(camera_lines | grep -m1 ': chose' | sed 's/.*camera: //')"
exit $status
