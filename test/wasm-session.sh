#!/bin/bash
# The web client the way a user runs it: the page from a plain static server
# without COOP/COEP headers (as GitHub Pages), the gateway from
# rdp-gateway.sh in its default one-step mode (ssh + websockify on the
# server), and an RDP server reachable only through SSH (xrdp on 127.0.0.1,
# in a disposable container with sshd and the kit's xrdp packages).
#
#   test/wasm-session.sh <page dir> <rdp-gateway.sh> [xrdp packages dir]
#
# Checks that the browser logs in: an Xorg session with an xterm starts for
# the user on the server. Output in dist/test/wasm/.
#
# Ports: on the server, RDP 3389 and websockify 3390; on this side, the
# page's gateway 127.0.0.1:13390 and, for a native client, 127.0.0.1:13389.
#
# PAGE_URL=<url> tests a published page instead (e.g. the GitHub Pages
# site); the page dir is then not served.
#
# SERVER=gnome uses GNOME instead of xrdp: gnome-shell headless on Wayland,
# reached through gnome-remote-desktop, in a container
# (test/gnome/, unprivileged); the RDP and websockify ports stay 3389 and 3390.
#
# DEMO_VIDEO=<file.mp4> records a demo instead of the plain login: the server
# gets a desktop (Xfce for xrdp) and test/wasm-demo.mjs plays a user's visit,
# with a pointer, captions and the sound. Everything in it is synthetic: the
# user "tester", the throwaway server, the password.
# check() evaluates its second argument later, so it is single-quoted on purpose
# shellcheck disable=SC2016
set -uo pipefail

KIT=$(cd "$(dirname "$0")/.." && pwd)
# the page dir is served unless a published page is tested (PAGE_URL)
PAGE=$1
[ -n "${PAGE_URL:-}" ] || PAGE=$(cd "$PAGE" && pwd)
GATEWAY=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
PKGS=${3:-$KIT/dist/xrdp/debian-13}
ENGINE=${ENGINE:-$(command -v docker || command -v podman)}
OUT=$KIT/dist/test/wasm
NAME=kit-wasm-server
rm -rf "$OUT"; mkdir -p "$OUT/ssh"
ssh-keygen -q -t ed25519 -N '' -f "$OUT/ssh/key" -C wasm-session-test
# -F none: the test's ssh ignores the user's ~/.ssh/config, so nothing of
# the user's (agent or X11 forwarding, other keys, proxies, shared
# connections) reaches the throwaway server
SSH_OPTS="-F none -L 127.0.0.1:13389:127.0.0.1:3389 -p 2223 -i $OUT/ssh/key -o IdentitiesOnly=yes -o ForwardAgent=no -o ForwardX11=no -o UserKnownHostsFile=$OUT/ssh/known_hosts -o StrictHostKeyChecking=accept-new"
export SSH_OPTS
export WS_PORT=13390 SERVER_WS_PORT=3390   # rdp-gateway.sh: the page's port, websockify's on the server

cleanup() {
    [ -n "${GW:-}" ] && kill "$GW" 2> /dev/null
    [ -n "${HTTP:-}" ] && kill "$HTTP" 2> /dev/null
    if [ -n "${KEEP:-}" ]; then   # KEEP=1: leave the server running, to look inside
        echo "server kept: $ENGINE exec -it $NAME bash; $ENGINE rm -f $NAME when done"
    else
        "$ENGINE" rm -f "$NAME" > /dev/null 2>&1
    fi
    rm -rf "$OUT/ssh"
}
trap cleanup EXIT

# the demo's desktop (test/demo/): Xfce with a terminal, sound through
# PipeWire's xrdp module, mpv and Firefox for the media of demo-assets.sh;
# the test needs only xterm
DESKTOP=""; DEMO_MOUNTS=(); SHELL_PROC=xterm
if [ -n "${DEMO_VIDEO:-}" ]; then
    DESKTOP="xfce4 xfce4-terminal dbus-x11 pipewire pipewire-pulse wireplumber pipewire-module-xrdp firefox-esr"
    DEMO_MOUNTS=(-v "$KIT/test/demo":/demo-setup:ro -v "$("$KIT/test/demo-assets.sh")":/demo:ro)
    SHELL_PROC=xfce4-terminal
fi

SERVER=${SERVER:-xrdp}
if [ "$SERVER" = gnome ]; then
echo "== server: GNOME on Wayland (headless) + gnome-remote-desktop, unprivileged, sshd on 127.0.0.1 only"
"$ENGINE" rm -f "$NAME" > /dev/null 2>&1
"$ENGINE" build -q -t kit-gnome-server "$KIT/test/gnome" > /dev/null || { echo "the GNOME image did not build" >&2; exit 1; }
"$ENGINE" run -d --name "$NAME" --hostname rdp-gnome -p 127.0.0.1:2223:22 --tmpfs /run --tmpfs /run/lock \
    -v "$OUT/ssh/key.pub":/key.pub:ro "${DEMO_MOUNTS[@]}" kit-gnome-server > /dev/null
# shellcheck disable=SC2016 # for the container's shell
"$ENGINE" exec "$NAME" bash -c '
    install -d -m 700 -o tester -g tester /home/tester/.ssh
    install -m 600 -o tester -g tester /key.pub /home/tester/.ssh/authorized_keys
    [ ! -d /demo-setup ] || install -m 755 /demo-setup/webdemo /usr/local/bin/
    # gnome-remote-desktop listens on 3389 (0D3D) once the headless shell runs
    for _ in $(seq 90); do grep -qiE ":0D3D [0:]+ 0A" /proc/net/tcp /proc/net/tcp6 && exit 0; sleep 1; done
    exit 1' || { echo "gnome-remote-desktop did not start:" >&2
                 "$ENGINE" exec "$NAME" sh -c "tail -n 20 /tmp/gnome-shell.log /tmp/grd.log" >&2; exit 1; }
else
echo "== server: sshd + xrdp on 127.0.0.1 only"
"$ENGINE" rm -f "$NAME" > /dev/null 2>&1
# a fixed host name: the remote desktop shows nothing of the machine running the test
"$ENGINE" run -d --name "$NAME" --hostname rdp-test -p 127.0.0.1:2223:22 -v "$OUT/ssh/key.pub":/key.pub:ro \
    -v "$PKGS":/pkgs:ro "${DEMO_MOUNTS[@]}" -e DESKTOP="$DESKTOP" debian:13 sleep 3600 > /dev/null
ls "$PKGS"/xrdp_*.deb "$PKGS"/xorgxrdp_*.deb > /dev/null || { echo "no xrdp packages in $PKGS" >&2; exit 1; }
"$ENGINE" exec "$NAME" bash -c '
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq > /dev/null
    # shellcheck disable=SC2086 # DESKTOP is a list of packages
    apt-get install -y -qq openssh-server websockify xterm $DESKTOP /pkgs/*.deb > /tmp/apt.log 2>&1 ||
        { tail -20 /tmp/apt.log; exit 1; }
    useradd -m -s /bin/bash tester && echo tester:kit-test-pw | chpasswd
    install -d -m 700 -o tester -g tester /home/tester/.ssh
    install -m 600 -o tester -g tester /key.pub /home/tester/.ssh/authorized_keys
    if [ -d /demo-setup ]; then
        install -m 755 -o tester -g tester /demo-setup/xsession /home/tester/.xsession
        install -m 755 /demo-setup/webdemo /usr/local/bin/
        rm -f /etc/xdg/autostart/pipewire-xrdp.desktop   # the session loads the module itself
    else
        printf "#!/bin/sh\nexec xterm\n" > /home/tester/.xsession; chmod +x /home/tester/.xsession
    fi
    sed -i "/^\[Globals\]/,/^\[/ s|^port=.*|port=tcp://.:3389|" /etc/xrdp/xrdp.ini
    mkdir -p /run/sshd && /usr/sbin/sshd
    (xrdp-sesman --nodaemon > /tmp/sesman.out 2>&1 &); (xrdp --nodaemon > /tmp/xrdp.out 2>&1 &)
    sleep 3' || { echo "the test server could not be set up" >&2; exit 1; }
fi

echo "== gateway: rdp-gateway.sh tester@127.0.0.1 (one step)"
script -q -c "$GATEWAY tester@127.0.0.1" /dev/null > "$OUT/gateway.log" 2>&1 &
GW=$!
if [ -n "${PAGE_URL:-}" ]; then
    echo "== page: $PAGE_URL"
else
    echo "== page: plain static server, no COOP/COEP"
    (cd "$PAGE" && exec python3 -m http.server 8199 --bind 127.0.0.1) > "$OUT/http.log" 2>&1 &
    HTTP=$!
fi
sleep 6

# gnome-remote-desktop aborts when it cannot mount its FUSE clipboard (no /dev/fuse in an
# unprivileged container): the client connects to GNOME without the clipboard channel
QUERY=""
[ "$SERVER" != gnome ] || QUERY="?extra=-clipboard"
DRIVER=$KIT/test/wasm-session.mjs
[ -z "${DEMO_VIDEO:-}" ] || DRIVER=$KIT/test/wasm-demo.mjs
DRIVER=${WASM_DRIVER:-$DRIVER}   # another driver, e.g. while debugging
node "$DRIVER" "${PAGE_URL:-http://127.0.0.1:8199/index.html}$QUERY" 127.0.0.1:13390 \
    tester kit-test-pw "$OUT" ${DEMO_VIDEO:+"$DEMO_VIDEO"}
sleep 2
pass=0; fail=0
check() { if eval "$2"; then echo "PASS  $1"; pass=$((pass + 1)); else echo "FAIL  $1"; fail=$((fail + 1)); fi; }
if [ "$SERVER" = gnome ]; then
check "GNOME Shell runs headless for tester" '"$ENGINE" exec "$NAME" pgrep -u tester -f "gnome-shell --headless" > /dev/null'
check "gnome-remote-desktop runs for tester" '"$ENGINE" exec "$NAME" pgrep -u tester -f "gnome-remote-desktop-daemon --headless" > /dev/null'
else
check "an Xorg session started for tester" \
    '"$ENGINE" exec "$NAME" pgrep -u tester -f "Xorg .*xrdp/xorg.conf" > /dev/null'
fi
check "RDP for a native client on 127.0.0.1:13389" 'timeout 3 bash -c "exec 3<> /dev/tcp/127.0.0.1/13389"'
[ "$SERVER" = gnome ] || check "the session runs its $SHELL_PROC" '"$ENGINE" exec "$NAME" pgrep -u tester "$SHELL_PROC" > /dev/null'
check "the screenshot shows more than one colour" \
    '[ "$(uvx -q --with pillow python -c "import sys; from PIL import Image; print(len(Image.open(sys.argv[1]).convert(\"RGB\").getcolors(1 << 24)))" "$OUT/wasm-session.png" 2> /dev/null || echo 0)" -gt 2 ]'
if [ "$SERVER" = gnome ] && [ "$fail" != 0 ]; then
    echo "== GNOME logs"; "$ENGINE" exec "$NAME" sh -c 'tail -n 25 /tmp/grd.log /tmp/gnome-shell.log; cat /tmp/session-ended 2> /dev/null'
fi
echo "passed $pass, failed $fail (screenshot, page log: $OUT)"
[ "$fail" = 0 ]
