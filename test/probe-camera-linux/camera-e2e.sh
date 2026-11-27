#!/bin/bash
# camera-e2e.sh <case> <host dir> <client> <out dir>: the Linux host's virtual camera, end to end,
# on this CI runner (never on a developer's machine: it uses the v4l2loopback devices
# module.sh loaded). Every program runs with the session's D-Bus, runtime dir, Wayland and X
# display unset, the host on its own Xvfb (:91, DISPLAY given explicitly, /subsystem:x11) and
# the client on another (:92), on 127.0.0.1:33891.
#
#   nodevice  no v4l2loopback at all: the host logs exactly the PO's line "camera: no v4l2loopback
#             device; no camera. Load the module: modprobe v4l2loopback card_label=..."
#             and runs (a client connects)
#   fallback  a module that can't tell its readers (Ubuntu's 0.12.7): exactly one line saying so,
#             the camera on while the client is connected, an app reads >= 60 changing frames
#   ondemand  a module with client usage events (0.13+): no Start Streams before an app reads,
#             Start Streams when it opens the camera, Stop Streams about 500 ms after it closes
#             it, twice; the client's log agrees (its Start/Stop Streams requests, its V4L2
#             capture started twice); >= 60 changing frames each time
#   mjpg      the client's camera offers MJPG only (jpegenc into the source device): the host
#             picks MJPG and decodes it with its LGPL FFmpeg (mjpeg); >= 60 changing frames
#   h264      a CI-only client (GStreamer backend, Ubuntu's FFmpeg encodes H.264) sends H.264:
#             the host picks H264 and decodes it with its LGPL FFmpeg (h264); >= 60 frames
#
# <client>: the kit's sdl-freerdp (V4L2 backend, /dev/video40 as its camera), or for h264 the
# CI-only xfreerdp. Results: <out dir>/result.txt (PASS/FAIL lines), logs beside it.
set -uo pipefail

CASE=${1:?usage: camera-e2e.sh <case> <host dir> <client> <out dir>}
HOSTDIR=$(realpath "${2:?}")
CLIENT=$(realpath "${3:?}")
OUT=${4:?}
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$OUT"
OUT=$(realpath "$OUT")
SRC_DEV=/dev/video40
CAM_DEV=/dev/video41
PORT=33891
WIDTH=1280
HEIGHT=720
SAFE=(env -u DBUS_SESSION_BUS_ADDRESS -u XDG_RUNTIME_DIR -u WAYLAND_DISPLAY -u DISPLAY)
FALLBACK="can't tell when an app reads it; the camera stays on while connected; 0.13+ fixes this"
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

# check <what> <command> [detail]: one PASS or FAIL line (a pipeline fails with any of its parts)
check() {
    if bash -o pipefail -c "$2"; then
        echo "PASS  $1${3:+ ($3)}" | tee -a "$OUT/result.txt"
    else
        echo "FAIL  $1${3:+ ($3)}" | tee -a "$OUT/result.txt"
        status=1
    fi
}
mark() { echo "$(date +%H:%M:%S.%3N) $*" | tee -a "$OUT/events.txt"; }
# wait_for <seconds> <command>: true once the command is
wait_for() {
    local i
    for ((i = 0; i < $1 * 5; i++)); do
        bash -c "$2" && return 0
        sleep 0.2
    done
    return 1
}
# the host's camera lines (WLog: "[HH:MM:SS:mmm] [pid:tid] [LEVEL][tag] - [function]: text")
camera_lines() { grep -F 'com.freerdp.server.shadow.camera' "$OUT/host.log" || true; }
count_host() { camera_lines | grep -c -F -- "$1" || true; }

xserver() {  # xserver <display number>
    "${SAFE[@]}" Xvfb ":$1" -screen 0 1024x768x24 -nolisten tcp -noreset > "$OUT/xvfb-$1.log" 2>&1 &
    PIDS+=($!)
    wait_for 20 "xdpyinfo -display :$1 > $OUT/xdpyinfo-$1.txt 2>&1" ||
        { echo "Xvfb :$1 did not start" >&2; exit 1; }
    grep -q 'dimensions: *1024x768 pixels' "$OUT/xdpyinfo-$1.txt" ||
        { echo ":$1 is not our 1024x768 Xvfb" >&2; exit 1; }
}

host() {
    "${SAFE[@]}" DISPLAY=:91 XDG_CONFIG_HOME="$OUT/host-config" WLOG_LEVEL=INFO \
        "$HOSTDIR/bin/freerdp-shadow-cli" /port:$PORT /bind-address:127.0.0.1 -auth /subsystem:x11 \
        > "$OUT/host.log" 2>&1 &
    HOST_PID=$!
    PIDS+=("$HOST_PID")
    wait_for 30 "ss -ltn | grep -q ':$PORT '" || { echo "the host does not listen" >&2; tail -20 "$OUT/host.log"; exit 1; }
    mark "host listening"
}

source_camera() {  # source_camera yuyv|mjpg: the test pattern into the client's camera device
    local caps='video/x-raw,format=YUY2,width=640,height=480,framerate=30/1'
    local tail=()
    [ "$1" = mjpg ] && { caps='video/x-raw,format=I420,width=640,height=480,framerate=30/1'; tail=(! jpegenc quality=85 ! image/jpeg); }
    gst-launch-1.0 -q videotestsrc is-live=true pattern=ball ! "$caps" "${tail[@]}" ! v4l2sink device=$SRC_DEV \
        > "$OUT/source.log" 2>&1 &
    PIDS+=($!)
    # exclusive_caps=1: the device offers capture once its writer is attached
    wait_for 15 "v4l2-ctl -d $SRC_DEV --all 2> /dev/null | grep -q 'Video Capture'" ||
        { echo "the source device has no writer" >&2; cat "$OUT/source.log"; exit 1; }
    v4l2-ctl -d $SRC_DEV --all > "$OUT/source-device.txt" 2>&1 || true
    mark "source camera ($1) on $SRC_DEV"
}

client() {  # client [extra /dvc options]: the kit's client with its V4L2 camera, or the gst one
    local dvc=/dvc:rdpecam
    [ -n "${1:-}" ] && dvc="/dvc:rdpecam,$1"
    "${SAFE[@]}" DISPLAY=:92 SDL_VIDEO_DRIVER=x11 SDL_AUDIO_DRIVER=dummy HOME="$OUT/client-home" \
        WLOG_LEVEL=INFO WLOG_FILTER=com.freerdp.channels.rdpecam-device.client:DEBUG \
        "$CLIENT" /v:127.0.0.1:$PORT /cert:ignore /u:camera /p:camera /size:800x600 -sound "$dvc" \
        > "$OUT/client.log" 2>&1 &
    CLIENT_PID=$!
    PIDS+=("$CLIENT_PID")
    mark "client started"
}

read_camera() {  # read_camera <frames> <file>: an app reads the host's camera
    mark "reader opens $CAM_DEV"
    v4l2-ctl -d $CAM_DEV --all > "$OUT/camera-device.txt" 2>&1 || true
    timeout 60 v4l2-ctl -d $CAM_DEV --stream-mmap=4 --stream-count="$1" --stream-to="$2" \
        > "$2.log" 2>&1
    local rc=$?
    mark "reader closed $CAM_DEV (rc $rc)"
    return $rc
}

# ms of the day: our marks (HH:MM:SS.mmm) and WLog's ([HH:MM:SS:mmm])
ms_of() { awk -F'[:.]' '{ printf "%d\n", (($1 * 60 + $2) * 60 + $3) * 1000 + $4 }' <<< "$1"; }
host_ms() {  # host_ms <text> <n>: when the host logged its n-th line with <text>
    local t
    t=$(camera_lines | grep -F -- "$1" | sed -n "${2}p" | sed -E 's/^\[([0-9:]+)\].*/\1/')
    [ -n "$t" ] && ms_of "$t"
}
event_ms() { ms_of "$(grep -F -- "$1" "$OUT/events.txt" | sed -n "${2}p" | cut -d' ' -f1)"; }

: > "$OUT/result.txt"
case $CASE in
    nodevice)
        check "no /dev/video* before the test" '! ls /dev/video* > /dev/null 2>&1'
        xserver 91
        xserver 92
        host
        client
        sleep 8
        check "the host logs exactly one line: camera: no v4l2loopback device; no camera. Load the module: ..." \
            "[ \"\$(grep -c -F 'camera: no v4l2loopback device; no camera. Load the module: modprobe v4l2loopback card_label=\"FreeRDP Camera\" exclusive_caps=1' '$OUT/host.log')\" = 1 ]"
        check "the host runs" "kill -0 $HOST_PID"
        check "a client connected" "grep -q -E 'resize requested|Gfx Pipeline Opened' '$OUT/host.log'"
        check "no other camera line" "[ \"\$(grep -c -F 'com.freerdp.server.shadow.camera' '$OUT/host.log')\" = 1 ]"
        ;;
    fallback | ondemand | mjpg)
        xserver 91
        xserver 92
        source_camera "$([ "$CASE" = mjpg ] && echo mjpg || echo yuyv)"
        host
        check "the host found the FreeRDP Camera" "grep -q 'camera: v4l2loopback /dev/video41' '$OUT/host.log'"
        client
        wait_for 30 "grep -q 'camera: \"Test Source\" of client .*: chose' '$OUT/host.log'"
        check "the client's Test Source owns the camera" "grep -q 'camera: \"Test Source\" of client .* owns the virtual camera' '$OUT/host.log'"
        check "the FreeRDP Camera, announced by the client too, is refused (no loop)" \
            "grep -q 'camera: \"FreeRDP Camera\" of client .* refused: another client owns the camera' '$OUT/host.log'"
        format=YUY2
        [ "$CASE" = mjpg ] && format=MJPG
        check "the host chose $format" "grep -q 'camera: \"Test Source\" of client .*: chose $format 640x480' '$OUT/host.log'"
        if [ "$CASE" = fallback ]; then
            check "exactly one line: the module can't tell its readers" \
                "[ \"\$(grep -c -F \"$FALLBACK\" '$OUT/host.log')\" = 1 ]" "$(grep -o -E 'v4l2loopback [^ ]+( 0\.13)? can.t tell' "$OUT/host.log" | head -1)"
            wait_for 20 "grep -q 'first frame from' '$OUT/host.log'"
            check "the camera runs while connected, no app reading" "grep -q 'Start Streams #1 (the sink can.t tell its readers)' '$OUT/host.log'"
            read_camera 150 "$OUT/read-1.yuyv"
            check "an app reads >= 60 changing frames" "python3 '$HERE/frames.py' '$OUT/read-1.yuyv' $WIDTH $HEIGHT 60 | tee '$OUT/frames-1.txt'"
        else
            check "no fallback line (the module tells its readers)" "! grep -q -F \"$FALLBACK\" '$OUT/host.log'"
            sleep 4
            check "no Start Streams while no app reads" "[ \"$(count_host 'Start Streams')\" = 0 ]" "$(camera_lines | wc -l) camera lines so far"
            cycles=2
            [ "$CASE" = mjpg ] && cycles=1
            for ((c = 1; c <= cycles; c++)); do
                read_camera 120 "$OUT/read-$c.yuyv"
                sleep 2.5
                check "cycle $c: an app reads >= 60 changing frames" \
                    "python3 '$HERE/frames.py' '$OUT/read-$c.yuyv' $WIDTH $HEIGHT 60 | tee '$OUT/frames-$c.txt'"
                open=$(event_ms 'reader opens' "$c")
                close=$(event_ms 'reader closed' "$c")
                start=$(host_ms "Start Streams #$c " 1 || echo 0)
                stop=$(host_ms 'Stop Streams (no app reads the camera)' "$c" || echo 0)
                check "cycle $c: Start Streams once the app opened the camera" \
                    "[ $start -ge $open ] && [ $((start - open)) -le 3000 ]" "$((start - open)) ms after the open"
                check "cycle $c: Stop Streams about 500 ms after the app closed it" \
                    "[ $stop -ge $((close + 300)) ] && [ $stop -le $((close + 2500)) ]" "$((stop - close)) ms after the close"
                sleep 2
            done
            check "Start and Stop Streams sent $cycles times each" \
                "[ \"$(count_host 'Start Streams #')\" = $cycles ] && [ \"$(count_host 'Stop Streams (no app')\" = $cycles ]"
            # the client's side: the requests it got (MessageId 0x0f Start Streams, 0x10 Stop
            # Streams) and its V4L2 capture started, as many times
            check "the client got $cycles Start and $cycles Stop Streams requests" \
                "[ \"\$(grep -c -E 'MessageId=0x0f' '$OUT/client.log')\" = $cycles ] && [ \"\$(grep -c -E 'MessageId=0x10' '$OUT/client.log')\" = $cycles ]" \
                "start $(grep -c -E 'MessageId=0x0f' "$OUT/client.log"), stop $(grep -c -E 'MessageId=0x10' "$OUT/client.log")"
            # its V4L2 backend logs "Camera format: ..." each time it starts capturing (it may also
            # restart a capture it released when the server went quiet: at least once per start)
            check "the client's V4L2 capture started for each Start Streams" \
                "[ \"\$(grep -c -F 'Camera format:' '$OUT/client.log')\" -ge $cycles ]" \
                "$(grep -c -F 'Camera format:' "$OUT/client.log")"
        fi
        ;;
    h264)
        xserver 91
        xserver 92
        host
        echo "videotestsrc is-live=true pattern=ball ! video/x-raw,width=640,height=480,framerate=30/1" > "$OUT/pipeline.txt"
        client "sys:gst,pipeline-file:$OUT/pipeline.txt,name:H264 Test"
        wait_for 30 "grep -q 'camera: \"H264 Test\" of client .*: chose' '$OUT/host.log'"
        check "the host chose H264" "grep -q 'camera: \"H264 Test\" of client .*: chose H264 640x480' '$OUT/host.log'"
        read_camera 150 "$OUT/read-1.yuyv"
        check "an app reads >= 60 changing frames, decoded by the host's FFmpeg" \
            "python3 '$HERE/frames.py' '$OUT/read-1.yuyv' $WIDTH $HEIGHT 60 | tee '$OUT/frames-1.txt'"
        ;;
    *) echo "unknown case $CASE" >&2; exit 2 ;;
esac

mark "stopping"
kill -TERM "$CLIENT_PID" 2> /dev/null
sleep 2
camera_lines > "$OUT/host-camera-lines.txt"
check "the host is still running" "kill -0 $HOST_PID"
rm -f "$OUT"/read-*.yuyv   # 1.8 MB a frame: the analysis is kept, not the frames
exit $status
