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
#   fallback  a module that can't tell its readers (0.12.7): exactly one line saying so, with its
#             version ("before 0.13" when the module declares none, as 0.12.7), the camera on
#             while the client is connected, an app reads >= 60 changing frames
#   ubuntu-module  whatever v4l2loopback the runner's kernel or Ubuntu gave (module.sh kernel):
#             the ondemand checks for 0.13 or newer, the fallback checks for an older one
#   ondemand  a module with client usage events (0.13+): no Start Streams before an app reads,
#             Start Streams when it opens the camera, Stop Streams about 500 ms after it closes
#             it, twice; the client's log agrees (its Start/Stop Streams requests, its V4L2
#             capture started twice); >= 60 changing frames each time
#   mjpg      the client's camera offers MJPG only (jpegenc into the source device): the host
#             picks MJPG and decodes it with its LGPL FFmpeg (mjpeg); >= 60 changing frames
#   h264      a CI-only client (GStreamer backend, Ubuntu's FFmpeg encodes H.264) sends H.264:
#             the host picks H264 and decodes it with its LGPL FFmpeg (h264); >= 60 frames
#   owncamera the CI-only client offers a camera named "FreeRDP Camera": the host refuses it in
#             exactly one line ("it is a FreeRDP server's own camera") and it never streams
# The client's camera device (/dev/video40) is written by v4l2-writer.c, built here (CI only).
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
# the loaded module's version, from its MODULE_VERSION (0.12.x declares none)
MODULE_VERSION=$(cat /sys/module/v4l2loopback/version 2> /dev/null || true)
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
    # v4l2-writer.c (CI only): write(), which every v4l2loopback has. GStreamer's v4l2sink gave
    # 0.12.7 no frame and could not negotiate MJPEG with 0.15.3 (run 46079009433)
    gcc -O2 -Wall -Wextra -Werror -o "$OUT/v4l2-writer" "$HERE/v4l2-writer.c" > "$OUT/writer-build.log" 2>&1 ||
        { cat "$OUT/writer-build.log"; exit 1; }
    local frames=()
    if [ "$1" = mjpg ]; then
        # the JPEG frames, made beforehand by GStreamer's jpegenc (no device involved)
        mkdir -p "$OUT/jpeg"
        gst-launch-1.0 -q videotestsrc num-buffers=60 pattern=ball ! video/x-raw,width=640,height=480 \
            ! jpegenc quality=85 ! multifilesink location="$OUT/jpeg/frame%03d.jpg" > "$OUT/jpeg.log" 2>&1 ||
            { cat "$OUT/jpeg.log"; exit 1; }
        frames=("$OUT"/jpeg/frame*.jpg)
    fi
    "$OUT/v4l2-writer" $SRC_DEV "$1" 640 480 30 "${frames[@]}" > "$OUT/source.log" 2>&1 &
    PIDS+=($!)
    # exclusive_caps=1: the device offers capture once its writer wrote. Its Device Caps (not
    # "Streaming Parameters Video Capture", which v4l2-ctl --all always prints)
    wait_for 15 "grep -q 'frame 0 written' '$OUT/source.log' && v4l2-ctl -d $SRC_DEV --info 2> /dev/null | sed -n '/Device Caps/,\$p' | grep -q 'Video Capture'" ||
        { echo "FAIL  the source device $SRC_DEV offers no capture: its writer did not start" | tee -a "$OUT/result.txt"
          cat "$OUT/source.log"; v4l2-ctl -d $SRC_DEV --all; exit 1; }
    v4l2-ctl -d $SRC_DEV --all > "$OUT/source-device.txt" 2>&1 || true
    mark "source camera ($1) on $SRC_DEV: $(head -1 "$OUT/source.log")"
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
if [ "$CASE" = ubuntu-module ]; then
    if [ -n "$MODULE_VERSION" ] && [ "$(printf '%s\n0.13\n' "$MODULE_VERSION" | sort -V | head -1)" = 0.13 ]; then
        CASE=ondemand
    else
        CASE=fallback
    fi
    echo "INFO  ubuntu-module: v4l2loopback ${MODULE_VERSION:-without a version (older than 0.13)}: the $CASE checks" |
        tee -a "$OUT/result.txt"
fi
# the devices module.sh loaded, by their exact names (card_label), before anything else
labels() {
    local n want got
    for n in 40:"Test Source" 41:"FreeRDP Camera"; do
        want=${n#*:}
        got=$(cat "/sys/devices/virtual/video4linux/video${n%%:*}/name" 2> /dev/null || true)
        if [ "$got" != "$want" ]; then
            echo "FAIL  /dev/video${n%%:*} is named [$got], not [$want]: card_label went wrong" | tee -a "$OUT/result.txt"
            exit 1
        fi
    done
    echo "PASS  the loopback devices are named exactly [Test Source] and [FreeRDP Camera]" | tee -a "$OUT/result.txt"
}
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
        labels
        xserver 91
        xserver 92
        source_camera "$([ "$CASE" = mjpg ] && echo mjpg || echo yuyv)"
        host
        check "the host found the FreeRDP Camera" "grep -q 'camera: v4l2loopback /dev/video41' '$OUT/host.log'"
        client
        # a hard precondition: the client's camera is the Test Source, else nothing below means
        # anything (run 46079009433: with no source, the client offered the FreeRDP Camera alone)
        if ! wait_for 30 "grep -q 'camera: \"Test Source\" of client .* owns the virtual camera' '$OUT/host.log'"; then
            echo "FAIL  the client's Test Source does not own the camera; the client's cameras as the host saw them:" |
                tee -a "$OUT/result.txt"
            camera_lines | grep -F ' of client ' | sed 's/^.*\]: /      /' | tee -a "$OUT/result.txt"
            camera_lines > "$OUT/host-camera-lines.txt"
            exit 1
        fi
        echo "PASS  the client's Test Source owns the camera" | tee -a "$OUT/result.txt"
        wait_for 30 "grep -q 'camera: \"Test Source\" of client .*: chose' '$OUT/host.log'"
        # the client skips it (rdpecam_is_freerdp_camera); the host would refuse it too
        check "the FreeRDP Camera did not become the client's camera (no loop)" \
            "! grep -q 'camera: \"FreeRDP Camera\" of client .* owns the virtual camera' '$OUT/host.log'"
        format=YUY2
        [ "$CASE" = mjpg ] && format=MJPG
        check "the host chose $format" "grep -q 'camera: \"Test Source\" of client .*: chose $format 640x480' '$OUT/host.log'"
        if [ "$CASE" = fallback ]; then
            line="camera: v4l2loopback ${MODULE_VERSION:-before 0.13} $FALLBACK"
            check "exactly one line: $line" \
                "[ \"\$(grep -c -F \"$line\" '$OUT/host.log')\" = 1 ] && [ \"\$(grep -c -F \"$FALLBACK\" '$OUT/host.log')\" = 1 ]" \
                "$(grep -o -E 'v4l2loopback .* can.t tell' "$OUT/host.log" | head -1)"
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
        labels
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
    owncamera)
        # a client offering a camera named "FreeRDP Camera" (the CI-only client: a GStreamer camera
        # given that name): the host refuses it, it never owns the camera
        labels
        xserver 91
        xserver 92
        host
        echo "videotestsrc is-live=true pattern=ball ! video/x-raw,width=640,height=480,framerate=30/1" > "$OUT/pipeline.txt"
        client "sys:gst,pipeline-file:$OUT/pipeline.txt,name:FreeRDP Camera"
        wait_for 30 "grep -q 'camera: \"FreeRDP Camera\" of client' '$OUT/host.log'"
        check "the host refuses a camera named FreeRDP Camera: exactly one line" \
            "[ \"\$(grep -c -F 'camera: \"FreeRDP Camera\" of client 127.0.0.1 refused: it is a FreeRDP server'\"'\"'s own camera' '$OUT/host.log')\" = 1 ]"
        check "it never owns the camera, no Start Streams" \
            "! grep -q -E 'owns the virtual camera|Start Streams' '$OUT/host.log'"
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
