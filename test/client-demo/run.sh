#!/bin/bash
# The freerdp-tk demo, inside its client container (Dockerfile here), which
# shares the server's network: rdp-gnome is the server's own 127.0.0.1.
#
#   run.sh release <client archive>    unpack the kit's client, ./freerdp-tk
#   run.sh uvx                         uvx --managed-python freerdp-tk, with Debian's client
#
# As root it names the server and, for release, takes Debian's client away
# (freerdp-tk's "(auto)" would take sdl-freerdp3 before sdl-freerdp); then,
# as the user demo, a display of 1920x1080 with Openbox, the keyring, sound
# and a terminal, recorded to /out/raw.mp4. The terminal's commands are
# typed here; freerdp-tk's window is worked by hook/drive.py from inside its
# process. Out: /out/raw.mp4 and /out/driver.log.
set -euo pipefail
MODE=$1 ARCHIVE=${2:-}
HERE=$(cd "$(dirname "$0")" && pwd)

if [ "$(id -u)" = 0 ]; then
    echo "127.0.0.1 rdp-gnome" >> /etc/hosts
    [ "$MODE" != release ] || rm -f /usr/bin/sdl-freerdp3
    [ -z "$ARCHIVE" ] || install -o demo -g demo -m 644 "$ARCHIVE" /home/demo/
    chown demo: /out
    exec runuser -u demo -- dbus-run-session -- "$0" "$MODE" "${ARCHIVE:+/home/demo/$(basename "$ARCHIVE")}"
fi

# UTF-8: Tk draws freerdp-tk's "…" and the like (with LANG unset, C, it drew garbage)
export LANG=C.UTF-8 DISPLAY=:1 XDG_RUNTIME_DIR=/tmp/xdg-demo CLIENT_DEMO_DIR=/tmp/demo CLIENT_DEMO_MODE=$MODE
install -d -m 700 "$XDG_RUNTIME_DIR"
mkdir -p "$CLIENT_DEMO_DIR"
echo 1 > "$CLIENT_DEMO_DIR/phase"
Xvfb :1 -screen 0 1920x1080x24 -nolisten tcp > /tmp/xvfb.log 2>&1 &
for _ in $(seq 50); do [ -S /tmp/.X11-unix/X1 ] && break; sleep 0.1; done
openbox > /tmp/openbox.log 2>&1 &
sleep 1   # Openbox paints the background black when it starts: the colour after it
xsetroot -solid '#203040'
# the login keyring, unlocked with its (synthetic) password, as a desktop login does
eval "$(printf 'kit-demo-keyring' | gnome-keyring-daemon --unlock --components=secrets)"
export GNOME_KEYRING_CONTROL
pulseaudio --start --exit-idle-time=-1 > /tmp/pulse.log 2>&1 || true
cd ~
# the hook reaches the uvx freerdp-tk through PYTHONPATH; the release's
# launcher sets its own, so the hook goes into its folder below
export PYTHONPATH=$HERE/hook PS1='\u@laptop:\w\$ '
xterm -T Terminal -geometry 96x16+60+700 -fa 'DejaVu Sans Mono' -fs 12 -bg '#1d1f21' -fg '#e0e0e0' \
    -e bash --norc > /dev/null 2>&1 &
for _ in $(seq 50); do xdotool search --name '^Terminal$' > /dev/null 2>&1 && break; sleep 0.1; done
sleep 1
ffmpeg -hide_banner -loglevel error -y -f x11grab -draw_mouse 1 -framerate 30 -video_size 1920x1080 -i :1 \
    -c:v libx264 -preset veryfast -crf 16 -pix_fmt yuv420p /out/raw.mp4 &
REC=$!
# the terminal has the focus (and a moment to take it: the first key went missing)
term() { xdotool search --name '^Terminal$' windowactivate --sync > /dev/null 2>&1; sleep 0.5; }
typed() { term; xdotool type --delay 75 "$1"; sleep 0.3; xdotool key Return; }
# what is left in /out belongs to this container's user: the host's user may remove it
# (under a rootless podman that is another uid than its own)
out() { cp "$CLIENT_DEMO_DIR"/driver.log /out/ 2> /dev/null; chmod -R a+rwX /out; }
fail() { echo "run.sh: $*" >&2; kill -INT $REC; wait $REC || true; out; exit 1; }
# until <file> <seconds>: waits for the driver's mark, or its failure
until_mark() {
    for _ in $(seq $(($2 * 4))); do
        [ ! -e "$CLIENT_DEMO_DIR/failed" ] || fail "the driver failed: $(cat "$CLIENT_DEMO_DIR/failed")"
        [ ! -e "$CLIENT_DEMO_DIR/$1" ] || return 0
        sleep 0.25
    done
    fail "no $1 after $2 s"
}
sleep 1.5

if [ "$MODE" = release ]; then
    name=$(basename "$ARCHIVE" .tar.xz)
    typed "ls"
    sleep 1.5
    typed "tar -xf $name.tar.xz"
    for _ in $(seq 120); do [ -x "$name/freerdp-tk" ] && ! pgrep -x tar > /dev/null && break; sleep 0.25; done
    cp "$HERE"/hook/*.py "$name/lib/freerdp-tk/"
    sleep 1
    start="./$name/freerdp-tk"
else
    # uv's own Python, which has Tk: the system's here (Openbox needs it) has
    # none, and plain uvx would take it (No module named 'tkinter')
    start="uvx --managed-python freerdp-tk"
fi
typed "$start"
until_mark phase1-done 240
# freerdp-tk quits; started again, it lists the saved connection
for _ in $(seq 40); do pgrep -f 'freerdp[-_]tk' > /dev/null || break; sleep 0.25; done
sleep 1.5
term; xdotool key Up; sleep 0.8; xdotool key Return
until_mark "done" 120
sleep 1
kill -INT $REC
wait $REC || true
out
echo "run.sh: recorded /out/raw.mp4 ($MODE)"
