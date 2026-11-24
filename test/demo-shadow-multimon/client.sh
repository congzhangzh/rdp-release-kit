#!/bin/bash
# The client of the demo: an X display for the recording (Xvfb, 2560x720), on it weston with
# two outputs of 1280x720 side by side (its X11 backend), and in weston the kit's Linux client
# from its archive, as released, with /multimon on those two screens, its overlay on, its
# numbers on /sdl-stats-ipc. ffmpeg (build/ci-ffmpeg.sh, mounted at /ffmpeg) records the display.
#   client.sh <client archive> <server host> <seconds>      everything in /out
set -euo pipefail
mkdir -p /opt/client && tar -xJf "$1" -C /opt/client --strip-components=1
server=$2 seconds=$3
export XDG_RUNTIME_DIR=/tmp/xdg HOME=/tmp/home
mkdir -p "$XDG_RUNTIME_DIR" "$HOME" && chmod 700 "$XDG_RUNTIME_DIR" "$HOME"
Xvfb :1 -screen 0 2560x720x24 -nolisten tcp > /out/client-xvfb.log 2>&1 &
for _ in $(seq 50); do DISPLAY=:1 xdpyinfo > /dev/null 2>&1 && break; sleep 0.2; done
export DISPLAY=:1
weston --backend=x11 --width=1280 --height=720 --output-count=2 --use-pixman --socket=wayland-demo \
    --idle-time=0 > /out/weston.log 2>&1 &
for _ in $(seq 50); do [ -S "$XDG_RUNTIME_DIR/wayland-demo" ] && break; sleep 0.2; done
# no window manager: weston's two output windows both open at 0,0; the second goes beside the
# first (xdotool search does not find them by name: weston names them in _NET_WM_NAME only)
w=
for _ in $(seq 50); do
    w=$(xwininfo -root -tree | awk '/"Weston Compositor - screen1"/ { print $1; exit }')
    [ -n "$w" ] && break
    sleep 0.2
done
[ -n "$w" ] || { echo "weston's second output did not open" >&2; exit 1; }
xdotool windowmove "$w" 1280 0
export WAYLAND_DISPLAY=wayland-demo SDL_VIDEO_DRIVER=wayland
/opt/client/bin/sdl-freerdp /list:monitor > /out/client-monitors.txt 2>&1
WLOG_LEVEL=INFO WLOG_FILTER='com.freerdp.codec.av1:DEBUG' /opt/client/bin/sdl-freerdp \
    /v:"$server":3389 /sec:tls /cert:ignore /u:demo /p:demo /multimon /gfx:AV2:off,AV1:i420 \
    +sdl-info /sdl-stats-ipc:/tmp/stats.sock > /out/client.log 2>&1 &
client=$!
# the overlay's numbers each second, as a line of JSON
python3 - > /out/stats.jsonl 2> /out/stats.err << 'PY' &
import socket, sys, time
for _ in range(100):
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect("/tmp/stats.sock")
        break
    except OSError:
        time.sleep(0.2)
else:
    sys.exit("no /sdl-stats-ipc socket")
f = s.makefile("r", encoding="utf-8", errors="replace")
for line in f:
    sys.stdout.write(line)
    sys.stdout.flush()
PY
sleep 8
/ffmpeg/bin/ffmpeg -v error -y -f x11grab -framerate 30 -video_size 2560x720 -i :1 -t "$seconds" \
    -c:v libx264 -preset veryfast -crf 18 -pix_fmt yuv420p /out/raw.mp4
kill "$client" 2> /dev/null || true
wait "$client" 2> /dev/null || true
