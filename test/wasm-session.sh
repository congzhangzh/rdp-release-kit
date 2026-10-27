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
# page's gateway 127.0.0.1:13390 and, for a native client, 127.0.0.1:13389
# (LOCAL_WS_PORT, LOCAL_RDP_PORT: others, when something else holds these).
#
# PAGE_URL=<url> tests a published page instead (e.g. the GitHub Pages
# site); the page dir is then not served.
#
# SERVER=gnome uses GNOME instead of xrdp: gnome-shell headless on Wayland,
# reached through gnome-remote-desktop, in a container
# (test/gnome/, unprivileged); the RDP and websockify ports stay 3389 and 3390.
#
# SERVER=xrdp-gnome: GNOME on Wayland through the kit's xrdp preview, with
# AV1 (test/xrdp-gnome/: Fedora 45, systemd under rootless podman). The
# packages dir then holds the preview's Fedora 45 packages (default
# dist/xrdp-preview/fedora-45). MUTTER_DEBUG=<topics> (Mutter's, e.g.
# geometry,window-state) turns them on in the session; the session's whole
# journal is then kept as session.journal.
#
# SERVER=xrdp-kde: KDE Plasma on Wayland through the xrdp preview, with AV1
# (test/xrdp-kde/: Arch with KWin 6.8, xrdp compiled there from the pinned
# sources). KWin renders in software with the host's /dev/udmabuf: no GPU,
# no DRM node, no vgem; the user running podman must be able to open it
# (group kvm). XRDP_PREVIEW_TAR=<tar> compiles an xrdp tree under test
# there instead of the pinned one (git archive --prefix=xrdp_preview/
# <commit>). PODMAN=<command> runs another podman for both, e.g. a
# rootful one on a CI runner; SERVER_RUN_OPTS=<options> adds options to
# their container (e.g. what an older podman's defaults need).
#
# WASM_ENGINE=jspi logs in with the page dir's jspi/ build (JSPI, Chrome
# 137+) instead of its Asyncify one; output then in dist/test/wasm-jspi/.
#
# SCREENS=<dir> runs freerdp-web's All screens tests from <dir> (that page's
# test-screens*.mjs, test-connect.mjs, test-keymap.py) instead of the plain
# login: the same server, the remote desktop on two screens. SERVER=xrdp:
# test-screens.mjs, once with a monitor per screen (MODE=separate) and once
# with one as wide as both (span), as the user "test" (password "test") in an
# X session with only an xterm; it runs "docker" itself. With CAPTURE=1 the
# page's test-capture.mjs (mouse and keyboard capture) runs there too, if
# <dir> has it, and with RECONNECT=1 its test-reconnect.mjs. SERVER=xrdp-gnome or
# xrdp-kde: test-screens-wlup.mjs (a desktop monitor per screen, this
# window's primary, its windows kept there). A page without the test is a
# SKIP. Output then in dist/test/wasm-screens/. These are the ladder's upper
# rungs; test/screens.sh runs the whole ladder.
#
# DEMO_VIDEO=<file.mp4> records a demo instead of the plain login: the server
# gets a desktop (Xfce for xrdp) and test/wasm-demo.mjs plays a user's visit,
# with a pointer, captions and the sound. Everything in it is synthetic: the
# user "tester", the throwaway server, the password. With DEMO_SCREENS=1 it
# records All screens instead (test/wasm-demo-screens.mjs; SERVER=xrdp-gnome).
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
# GNOME and KDE through the xrdp preview need systemd in their container:
# podman, which runs it without privileges
case ${SERVER:-} in
xrdp-gnome | xrdp-kde)
    ENGINE=${PODMAN:-$(command -v podman)} ||
        { echo "SERVER=$SERVER needs podman (systemd without privileges)" >&2; exit 1; }
    PKGS=${3:-$KIT/dist/xrdp-preview/fedora-45} ;;
esac
OUT=$KIT/dist/test/wasm${WASM_ENGINE:+-$WASM_ENGINE}${SCREENS:+-screens}
NAME=kit-wasm-server
rm -rf "$OUT"; mkdir -p "$OUT/ssh"
# WASM_ENGINE=jspi: the client linked for JSPI (the page dir's jspi/) in place
# of the Asyncify one, whichever the page itself loads
case ${WASM_ENGINE:-asyncify} in
asyncify) ;;
jspi)
    [ -z "${PAGE_URL:-}" ] || { echo "WASM_ENGINE=jspi needs a page dir, not PAGE_URL" >&2; exit 1; }
    grep -q 'WebAssembly.Suspending' "$PAGE/jspi/sdl-freerdp.js" 2> /dev/null ||
        { echo "no JSPI build in $PAGE/jspi" >&2; exit 1; }
    cp -r "$PAGE/." "$OUT/page/"
    cp "$PAGE/jspi/sdl-freerdp.js" "$PAGE/jspi/sdl-freerdp.wasm" "$OUT/page/"
    PAGE=$OUT/page
    echo "== client: the JSPI build" ;;
*) echo "WASM_ENGINE: asyncify or jspi" >&2; exit 1 ;;
esac
ssh-keygen -q -t ed25519 -N '' -f "$OUT/ssh/key" -C wasm-session-test
# -F none: the test's ssh ignores the user's ~/.ssh/config, so nothing of
# the user's (agent or X11 forwarding, other keys, proxies, shared
# connections) reaches the throwaway server
LOCAL_WS_PORT=${LOCAL_WS_PORT:-13390} LOCAL_RDP_PORT=${LOCAL_RDP_PORT:-13389}
SSH_OPTS="-F none -L 127.0.0.1:$LOCAL_RDP_PORT:127.0.0.1:3389 -p 2223 -i $OUT/ssh/key -o IdentitiesOnly=yes -o ForwardAgent=no -o ForwardX11=no -o UserKnownHostsFile=$OUT/ssh/known_hosts -o StrictHostKeyChecking=accept-new"
export SSH_OPTS
export WS_PORT=$LOCAL_WS_PORT SERVER_WS_PORT=3390   # rdp-gateway.sh: the page's port, websockify's on the server

# This test listens on fixed local ports; if anything else holds one, the
# page would reach that instead and the checks would fail for no visible
# reason. Stop first, saying which port.
"$ENGINE" rm -f "$NAME" > /dev/null 2>&1   # this test's own server from a kept run
ports=(2223 "$LOCAL_RDP_PORT" "$LOCAL_WS_PORT")
[ -n "${PAGE_URL:-}" ] || ports+=(8199)
for port in "${ports[@]}"; do
    if ss -Hltn "sport = :$port" | grep -q .; then
        echo "port 127.0.0.1:$port is already in use (by: $("$ENGINE" ps --filter "publish=$port" \
            --format '{{.Names}}' 2> /dev/null | head -1)); this test needs it free" >&2
        exit 1
    fi
done

cleanup() {
    [ -n "${GW:-}" ] && kill "$GW" 2> /dev/null
    [ -n "${HTTP:-}" ] && kill "$HTTP" 2> /dev/null
    if [ -n "${KEEP:-}" ]; then   # KEEP=1: leave the server running, to look inside
        echo "server kept: $ENGINE exec -it $NAME bash; $ENGINE rm -f $NAME when done"
    else
        "$ENGINE" rm -f "$NAME" > /dev/null 2>&1
    fi
    rm -rf "$OUT/ssh"
    [ -z "${TESTS:-}" ] || rm -rf "$TESTS"
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
# test-screens.mjs asks the X server through python3 (Xlib by ctypes) and xrandr
[ -z "${SCREENS:-}" ] || DESKTOP="python3 x11-xserver-utils"

SERVER=${SERVER:-xrdp}
if [ "$SERVER" = gnome ]; then
echo "== server: GNOME on Wayland (headless) + gnome-remote-desktop, unprivileged, sshd on 127.0.0.1 only"
"$ENGINE" rm -f "$NAME" > /dev/null 2>&1
"$ENGINE" build -q -t kit-gnome-server "$KIT/test/gnome" > "$OUT/gnome-build.log" 2>&1 ||
    { tail -20 "$OUT/gnome-build.log" >&2; echo "the GNOME image did not build" >&2; exit 1; }
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
elif [ "$SERVER" = xrdp-gnome ] || [ "$SERVER" = xrdp-kde ]; then
"$ENGINE" rm -f "$NAME" > /dev/null 2>&1
ctx=$OUT/$SERVER
mkdir -p "$ctx"
cp "$KIT/test/$SERVER/Dockerfile" "$ctx/"
DEVICES=()
read -r -a RUN_OPTS <<< "${SERVER_RUN_OPTS:-}"
if [ "$SERVER" = xrdp-gnome ]; then
    echo "== server: GNOME on Wayland through the xrdp preview (AV1), Fedora 45, systemd under podman"
    IMAGE=kit-xrdp-gnome:f45 HOST=rdp-gnome
    ls "$PKGS"/xrdp-*.fc45.x86_64.rpm > /dev/null 2>&1 || { echo "no Fedora 45 xrdp preview packages in $PKGS" \
        "(./build-xrdp.sh --preview fedora:45, or the *fc45* files of an xrdp-preview-* pre-release)" >&2; exit 1; }
    mkdir -p "$ctx/pkgs"
    cp "$PKGS"/xrdp-*.fc45.x86_64.rpm "$ctx/pkgs/"
    # PipeWire's xrdp module, the session's sound (the kit's package; Fedora has none)
    cp "$PKGS"/pipewire-module-xrdp-*.fc45.x86_64.rpm "$ctx/pkgs/" 2> /dev/null ||
        { echo "no pipewire-module-xrdp *fc45* package in $PKGS (a pipewire-module-xrdp-* pre-release)" >&2; exit 1; }
    # the user's systemd hands environment.d to the session, gnome-shell too
    [ -z "${MUTTER_DEBUG:-}" ] || printf 'RUN mkdir -p /etc/environment.d && echo MUTTER_DEBUG=%s > /etc/environment.d/90-mutter-debug.conf\n' \
        "$MUTTER_DEBUG" >> "$ctx/Dockerfile"
else
    echo "== server: KDE Plasma on Wayland through the xrdp preview (AV1), Arch (KWin 6.8), systemd under podman"
    IMAGE=kit-xrdp-kde:arch HOST=rdp-kde
    # KWin 6.8 renders in software with /dev/udmabuf (no GPU, no DRM, no vgem);
    # a rootless podman opens it as this user
    if [ -z "${PODMAN:-}" ] && ! { [ -r /dev/udmabuf ] && [ -w /dev/udmabuf ]; }; then
        echo "SERVER=xrdp-kde: this user cannot open /dev/udmabuf (KWin 6.8 renders with it); add it to" \
            "the device's group ($(stat -c %G /dev/udmabuf 2> /dev/null || echo "no /dev/udmabuf"))" >&2
        exit 1
    fi
    DEVICES=(--device /dev/udmabuf)
    # xrdp is compiled in the image from the pinned sources, checked as every build's are
    mkdir -p "$ctx/src"
    for src in xrdp_preview librfxcodec libpainter pipewire_xrdp; do
        if [ "$src" = xrdp_preview ] && [ -n "${XRDP_PREVIEW_TAR:-}" ]; then
            cp "$XRDP_PREVIEW_TAR" "$ctx/src/$src.tar" || exit 1
            continue
        fi
        # shellcheck disable=SC2016 # for the inner shell
        file=$(KIT=$KIT SOURCES=${SOURCES:-$HOME/.cache/rdp-release-kit/sources} WORK=$ctx/work SRC=$src \
            bash -c '. "$KIT/build/lib.sh" && fetch "$SRC"') || { echo "$src: no checked source" >&2; exit 1; }
        cp "$file" "$ctx/src/$src.tar"
    done
fi
"$ENGINE" build -q -t "$IMAGE" "$ctx" > "$OUT/$SERVER-build.log" 2>&1 ||
    { tail -20 "$OUT/$SERVER-build.log" >&2; echo "the $SERVER image did not build" >&2; exit 1; }
# room for a whole desktop session with Firefox playing video next to WebGL:
# tasks (podman's default is 2048; see the Dockerfiles) and the shared
# memory of Firefox's processes (default 64 MB)
# systemd's own messages on the console too, and a terminal for that console
# (-t: without one podman logs never sees it): when it stops, podman logs says why
"$ENGINE" run -d -t --name "$NAME" --hostname "$HOST" --systemd=always --cap-add SYS_ADMIN,SYS_NICE \
    --pids-limit 4096 --shm-size=1g "${DEVICES[@]}" -e SYSTEMD_LOG_TARGET=console \
    -e SYSTEMD_LOG_LEVEL="${SYSTEMD_LOG_LEVEL:-info}" "${RUN_OPTS[@]}" \
    -p 127.0.0.1:2223:22 -v "$OUT/ssh/key.pub":/key.pub:ro "${DEMO_MOUNTS[@]}" "$IMAGE" > /dev/null
# shellcheck disable=SC2016 # for the container's shell
"$ENGINE" exec "$NAME" bash -c '
    install -d -m 700 -o tester -g tester /home/tester/.ssh
    install -m 600 -o tester -g tester /key.pub /home/tester/.ssh/authorized_keys
    [ ! -d /demo-setup ] || install -m 755 /demo-setup/webdemo /usr/local/bin/
    # the session opens it as its user: a session without a seat gets no
    # device access from logind (a rootful podman made this node for the
    # container alone; a rootless one shows the host'"'"'s, unchanged)
    [ ! -e /dev/udmabuf ] || chmod 666 /dev/udmabuf 2> /dev/null || true
    # xrdp listens on 3389 (0D3D) and sshd runs once systemd has started them
    for _ in $(seq 60); do
        grep -qiE ":0D3D [0:]+ 0A" /proc/net/tcp /proc/net/tcp6 && systemctl -q is-active sshd && exit 0
        sleep 1
    done
    exit 1' || { echo "xrdp or sshd did not start:" >&2
                 "$ENGINE" inspect -f 'container: {{.State.Status}}, exit code {{.State.ExitCode}} {{.State.Error}}' \
                     "$NAME" >&2
                 "$ENGINE" logs --tail 40 "$NAME" >&2
                 "$ENGINE" exec "$NAME" journalctl -b --no-pager -n 30 >&2; exit 1; }
else
echo "== server: sshd + xrdp on 127.0.0.1 only"
"$ENGINE" rm -f "$NAME" > /dev/null 2>&1
# a fixed host name: the remote desktop shows nothing of the machine running the test
"$ENGINE" run -d --name "$NAME" --hostname rdp-test -p 127.0.0.1:2223:22 -v "$OUT/ssh/key.pub":/key.pub:ro \
    -v "$PKGS":/pkgs:ro "${DEMO_MOUNTS[@]}" -e DESKTOP="$DESKTOP" -e SCREENS="${SCREENS:+1}" debian:13 sleep 3600 > /dev/null
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
    if [ -n "$SCREENS" ]; then   # the All screens test logs in as test, with an xterm too
        useradd -m -s /bin/bash test && echo test:test | chpasswd
        install -m 755 -o test -g test /home/tester/.xsession /home/test/.xsession
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

# SCREENS: the ladder's upper rungs, freerdp-web's All screens tests, in
# place of the plain login's checks
if [ -n "${SCREENS:-}" ]; then
    # a copy in a short path: the tests keep Chrome's profile next to them, and
    # its SingletonSocket must fit a Unix socket's 108 bytes (Chrome aborts
    # with "Socket path too long" from a CI runner's workspace)
    TESTS=$(mktemp -d /tmp/screens-XXXXXX)
    cp "$SCREENS"/test-*.mjs "$SCREENS"/test-*.py "$TESTS/" 2> /dev/null
    mkdir -p "$TESTS/.chrome"   # test-capture.mjs makes its profile in it, but not the folder
    page=${PAGE_URL:-http://127.0.0.1:8199/index.html}
    status=0
    # run <name> <script> <env>...: the test's own lines, and one verdict line
    run() {
        local name=$1 script=$2 out=$OUT/$1
        shift 2
        if [ ! -f "$TESTS/$script" ]; then
            echo "SKIP  $name: this page has no $script"
            return
        fi
        echo "== $name ($script)"
        mkdir -p "$out"
        env GATEWAY=127.0.0.1:"$LOCAL_WS_PORT" PAGE="$page" "$@" node "$TESTS/$script" "$out" 2>&1 | tee "$out.log"
        if [ "${PIPESTATUS[0]}" = 0 ]; then
            echo "PASS  $name: $(grep -c '^PASS ' "$out.log") checks"
        else
            echo "FAIL  $name: $(grep -c '^FAIL ' "$out.log") of $(grep -cE '^(PASS|FAIL) ' "$out.log") checks failed"
            status=1
        fi
    }
    case $SERVER in
    xrdp)
        run screens-separate test-screens.mjs MODE=separate XRDP="$NAME"
        run screens-span test-screens.mjs MODE=span XRDP="$NAME"
        # CAPTURE=1: the page's mouse and keyboard capture test too, on the same server
        [ -z "${CAPTURE:-}" ] || run capture test-capture.mjs XRDP="$NAME"
        # RECONNECT=1: the page's reconnect test, with a websockify of its own (6082) to
        # the RDP port; the session ends when its xterm does; WebAuthn wants localhost
        [ -z "${RECONNECT:-}" ] || run reconnect test-reconnect.mjs XRDP="$NAME" \
            XRDP_ADDR=127.0.0.1:"$LOCAL_RDP_PORT" SESSION_PROC=xterm PAGE="${page/127.0.0.1/localhost}" ;;
    xrdp-gnome | xrdp-kde)
        run "screens-${SERVER#xrdp-}" test-screens-wlup.mjs DESKTOP="${SERVER#xrdp-}" CONTAINER="$NAME" \
            ENGINE="$ENGINE" PASSWORD=kit-test-pw ;;
    *) echo "SCREENS: no All screens test for SERVER=$SERVER" >&2; exit 1 ;;
    esac
    if [ "$SERVER" = xrdp ]; then
        "$ENGINE" exec "$NAME" sh -c 'tail -n 300 /var/log/xrdp.log /var/log/xrdp-sesman.log' > "$OUT/server.log" 2>&1
    else
        "$ENGINE" exec "$NAME" sh -c 'tail -n 200 /var/log/xrdp.log /var/log/xrdp-sesman.log;
            echo "== the session"; journalctl -b --no-pager -n 300 _UID=1000' > "$OUT/server.log" 2>&1
    fi
    [ -z "${MUTTER_DEBUG:-}" ] ||
        "$ENGINE" exec "$NAME" journalctl -b --no-pager -o short-precise _UID=1000 > "$OUT/session.journal" 2>&1
    echo "All screens: $([ $status = 0 ] && echo passed || echo FAILED) (logs, screenshots: $OUT)"
    exit $status
fi

# gnome-remote-desktop aborts when it cannot mount its FUSE clipboard (no /dev/fuse in an
# unprivileged container): the client connects to GNOME without the clipboard channel
QUERY=""
[ "$SERVER" != gnome ] || QUERY="?extra=-clipboard"
DRIVER=$KIT/test/wasm-session.mjs
[ -z "${DEMO_VIDEO:-}" ] || DRIVER=$KIT/test/wasm-demo.mjs
# DEMO_SCREENS=1: the All screens demo, two screens side by side
[ -z "${DEMO_VIDEO:-}" ] || [ -z "${DEMO_SCREENS:-}" ] || DRIVER=$KIT/test/wasm-demo-screens.mjs
DRIVER=${WASM_DRIVER:-$DRIVER}   # another driver, e.g. while debugging
# what xrdp says it encodes, for the demo's caption: the web client reports no
# codec of its own yet (its build has no codec statistics)
[ "$SERVER" != xrdp-gnome ] && [ "$SERVER" != xrdp-kde ] ||
    export DEMO_CODEC_CMD="$ENGINE exec $NAME grep -h 'xrdp_encoder_av1: encoder for' /var/log/xrdp.log"
node "$DRIVER" "${PAGE_URL:-http://127.0.0.1:8199/index.html}$QUERY" 127.0.0.1:"$LOCAL_WS_PORT" \
    tester kit-test-pw "$OUT" ${DEMO_VIDEO:+"$DEMO_VIDEO"}
sleep 2
pass=0; fail=0
check() { if eval "$2"; then echo "PASS  $1"; pass=$((pass + 1)); else echo "FAIL  $1"; fail=$((fail + 1)); fi; }
check "the page started the client as tester" 'grep -q -- " /u:tester " "$OUT/page.log"'
if [ "$SERVER" = xrdp-gnome ]; then
check "sesman started GNOME for tester (gnome-session, GNOME Shell)" \
    '"$ENGINE" exec "$NAME" pgrep -u tester -f "gnome-session-service --session=gnome" > /dev/null &&
     "$ENGINE" exec "$NAME" pgrep -u tester -x gnome-shell > /dev/null'
check "xrdp encodes the session in AV1" \
    '"$ENGINE" exec "$NAME" grep -q "starting AV1 codec session" /var/log/xrdp.log'
elif [ "$SERVER" = xrdp-kde ]; then
check "sesman started Plasma for tester (KWin, the Plasma shell)" \
    '"$ENGINE" exec "$NAME" pgrep -u tester -x kwin_wayland > /dev/null &&
     "$ENGINE" exec "$NAME" pgrep -u tester -x plasmashell > /dev/null'
check "xrdp encodes the session in AV1" \
    '"$ENGINE" exec "$NAME" grep -q "starting AV1 codec session" /var/log/xrdp.log'
elif [ "$SERVER" = gnome ]; then
check "GNOME Shell runs headless for tester" '"$ENGINE" exec "$NAME" pgrep -u tester -f "gnome-shell --headless" > /dev/null'
check "gnome-remote-desktop runs for tester" '"$ENGINE" exec "$NAME" pgrep -u tester -f "gnome-remote-desktop-daemon --headless" > /dev/null'
else
check "an Xorg session started for tester" \
    '"$ENGINE" exec "$NAME" pgrep -u tester -f "Xorg .*xrdp/xorg.conf" > /dev/null'
fi
check "RDP for a native client on 127.0.0.1:$LOCAL_RDP_PORT" 'timeout 3 bash -c "exec 3<> /dev/tcp/127.0.0.1/$LOCAL_RDP_PORT"'
[ "$SERVER" != xrdp ] || check "the session runs its $SHELL_PROC" '"$ENGINE" exec "$NAME" pgrep -u tester "$SHELL_PROC" > /dev/null'
# a demo's screenshot has a terminal with typed text on the remote desktop:
# a session that never connected has sent nothing by then (a healthy one,
# about 1 MB), and a picture that froze (one flat colour) has next to no
# colours there (a healthy one, thousands)
[ -z "${DEMO_VIDEO:-}" ] || check "the session sent its picture (at least 100 KB by the screenshot)" \
    '[ "$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get(\"rx\", 0))" "$OUT/canvas.json" 2> /dev/null || echo 0)" -ge 100000 ]'
[ -z "${DEMO_VIDEO:-}" ] || check "the remote desktop shows detail (at least 64 colours)" \
    '[ "$(uvx -q --with pillow python -c "import json, sys; from PIL import Image; c = json.load(open(sys.argv[2])); print(len(Image.open(sys.argv[1]).convert(\"RGB\").crop((c[\"x\"], c[\"y\"], c[\"x\"] + c[\"w\"], c[\"y\"] + c[\"h\"])).getcolors(1 << 24)))" "$OUT/wasm-session.png" "$OUT/canvas.json" 2> /dev/null || echo 0)" -ge 64 ]'
check "the screenshot shows more than one colour" \
    '[ "$(uvx -q --with pillow python -c "import sys; from PIL import Image; print(len(Image.open(sys.argv[1]).convert(\"RGB\").getcolors(1 << 24)))" "$OUT/wasm-session.png" 2> /dev/null || echo 0)" -gt 2 ]'
if [ "$SERVER" = gnome ] && [ "$fail" != 0 ]; then
    echo "== GNOME logs"; "$ENGINE" exec "$NAME" sh -c 'tail -n 25 /tmp/grd.log /tmp/gnome-shell.log; cat /tmp/session-ended 2> /dev/null'
fi
if [ "$SERVER" = xrdp-gnome ] || [ "$SERVER" = xrdp-kde ]; then
    # kept with the test's output (a CI run's artifact): what the server did
    "$ENGINE" exec "$NAME" sh -c 'tail -n 200 /var/log/xrdp.log /var/log/xrdp-sesman.log; echo "== the session";
        journalctl -b --no-pager -n 300 _UID=1000; echo "== the system"; journalctl -b --no-pager -n 300
        echo "== the sound, as the user sees it (wpctl status)"
        su tester -c "XDG_RUNTIME_DIR=/run/user/1000 wpctl status" 2>&1 | head -60
        echo "== the demo'"'"'s Firefox (webdemo)"; tail -n 80 /tmp/firefox.log 2> /dev/null
        echo "== processes"; ps -eo user,pid,etime,rss,args --sort=-rss | head -25
        # why a login is refused: the account as each side sees it
        echo "== the user tester"; getent passwd tester; getent shadow tester | cut -d: -f1,3-
        getent shadow tester | cut -d: -f2 | cut -c1-3 | sed "s/^/hash starts: /"; passwd -S tester
        grep -E "^(passwd|shadow|group):" /etc/nsswitch.conf; ls -l /etc/passwd /etc/shadow /usr/sbin/unix_chkpwd
        getcap /usr/sbin/unix_chkpwd 2> /dev/null; rpm -q openssh-server pam systemd shadow-utils authselect
        systemctl show sshd -p CapabilityBoundingSet -p AmbientCapabilities -p NoNewPrivileges \
            -p ProtectSystem -p ProtectHome -p PrivateUsers -p RestrictSUIDSGID
        for p in $(pgrep -x sshd); do grep -E "^(Cap(Eff|Bnd)|NoNewPrivs)" /proc/$p/status; done' \
        > "$OUT/server.log" 2>&1
    if [ "$fail" != 0 ]; then echo "== xrdp and the session's logs (all: $OUT/server.log)"; tail -n 40 "$OUT/server.log"; fi
fi
echo "passed $pass, failed $fail (screenshot, page log: $OUT)"
[ "$fail" = 0 ]
