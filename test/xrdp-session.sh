#!/bin/bash
# Installs the built xrdp packages (dist/xrdp/<release>/) in a fresh
# container of their release, logs in through RDP with the kit's portable
# client, and checks that an Xorg session (xorgxrdp) with an xterm comes
# up, then a Wayland one (sway) unless the release is marked no-sway in
# distros.list; and that the login screen lists the Wayland sessions the
# release has (GNOME; KDE unless no-kde):
#
#   test/xrdp-session.sh <image> [client archive]
#
# The client defaults to the newest dist/sdl3-freerdp-*-linux-<arch>.tar.xz.
# Logs and a screenshot go to dist/test/<release>/.
set -uo pipefail

KIT=$(cd "$(dirname "$0")/.." && pwd)
if [ "${1:-}" = --preview ]; then
    echo "xrdp-session.sh: --preview is gone: the kit builds one xrdp, with Xorg and Wayland sessions" >&2
    exit 2
fi
IMAGE=$1
CLIENT=${2:-$(find "$KIT/dist" -maxdepth 1 -name "sdl3-freerdp-*-linux-$(uname -m).tar.xz" | sort -V | tail -1)}
# docker first: the builds are tested with it (podman: see README)
ENGINE=${ENGINE:-$(command -v docker || command -v podman)}
# shellcheck disable=SC2016 # expanded by the container shell
DISTRO=$("$ENGINE" run --rm "$IMAGE" sh -c '. /etc/os-release; echo "$ID-${VERSION_ID:-$VERSION_CODENAME}"')
PKGS=$KIT/dist/xrdp/$DISTRO
# the release's marks in distros.list: no-sway skips the sway login, no-kde
# the KDE session on the login screen
mark() { awk -v i="$IMAGE" -v m="$1" \
    '$1 == i { for (k = 2; k <= NF; k++) if ($k == m) f = 1 } END { exit !f }' "$KIT/distros.list"; }
NO_SWAY='' NO_KDE=''
mark no-sway && NO_SWAY=1
mark no-kde && NO_KDE=1
# Fedora's sway carries the file capability cap_sys_nice (to raise its
# own priority); a container lacking it in its bounding set cannot exec it
CAPS=()
# (NO_SYS_NICE=1 leaves it out, to see how sesman reports the failure)
[ -z "${NO_SYS_NICE:-}" ] && CAPS=(--cap-add SYS_NICE)
# FORCE_SWAY=1 tries it anyway (to see how the module reports the failure)
[ -n "${FORCE_SWAY:-}" ] && NO_SWAY=
# outside the packages' directory, which the build container made
OUT=$KIT/dist/test/$DISTRO
rm -rf "$OUT"
mkdir -p "$OUT"

INSIDE=$(mktemp)
cat > "$INSIDE" << 'EOF'
set -u
pass=0
fail=0
check() {
    if eval "$2"; then
        echo "PASS  $1"; pass=$((pass + 1))
    else
        echo "FAIL  $1"; fail=$((fail + 1))
    fi
}

echo "== install"
if command -v apt-get > /dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq > /dev/null
    apt-get install -y -qq /pkgs/*.deb xterm xvfb imagemagick libpulse0 xz-utils \
        procps > /out/install.log 2>&1
else
    dnf -y -q install /pkgs/*.rpm xterm xorg-x11-server-Xvfb ImageMagick pulseaudio-libs \
        xorg-x11-xinit xz procps-ng > /out/install.log 2>&1
fi
check "the packages install" '[ -x /usr/sbin/xrdp ] && [ -x /usr/sbin/xrdp-sesman ]'
check "host keys were made on install" '[ -s /etc/xrdp/cert.pem ] && [ -s /etc/xrdp/rsakeys.ini ]'
# the Wayland module, and the login screen's sessions (Xorg stays first, the default)
check "the package has the Wayland module (libwlup)" 'ls /usr/lib*/xrdp/libwlup.so > /dev/null 2>&1'
check "the login screen lists GNOME (code 31)" 'grep -q "^\[GNOME\]$" /etc/xrdp/xrdp.ini'
if [ -n "$NO_KDE" ]; then
    check "the login screen lists no KDE (this release is marked no-kde)" '! grep -q "^\[KDE\]$" /etc/xrdp/xrdp.ini'
else
    check "the login screen lists KDE (code 32)" 'grep -q "^\[KDE\]$" /etc/xrdp/xrdp.ini'
fi
check "Xorg is still the first session" \
    '[ "$(sed -n "s/^\[\(.*\)\]$/\1/p" /etc/xrdp/xrdp.ini | grep -v -x -E "Globals|Logging|LoggingPerLogger|Channels" | head -1)" = Xorg ]'
# Fedora: the kit's own build of PipeWire's xrdp module (Debian and Ubuntu
# package it), where PipeWire looks for modules, and its session autostart
if command -v rpm > /dev/null; then
    check "PipeWire's xrdp module installs (pipewire-module-xrdp)" \
        'rpm -q pipewire-module-xrdp > /dev/null &&
         [ -f "$(pkg-config --variable=moduledir libpipewire-0.3 2> /dev/null || echo /usr/lib64/pipewire-0.3)/libpipewire-module-xrdp.so" ] &&
         ls /etc/xdg/autostart/*xrdp*.desktop > /dev/null 2>&1'
fi

# a user whose session is an xterm, and xrdp on the loopback only
useradd -m tester
echo 'tester:kit-test-pw' | chpasswd
printf '#!/bin/sh\nexec xterm -geometry 100x30+50+50\n' > /home/tester/.xsession
chmod +x /home/tester/.xsession
sed -i '/^\[Globals\]/,/^\[/ s|^port=.*|port=tcp://.:3389|' /etc/xrdp/xrdp.ini
xrdp-sesman --nodaemon > /out/sesman.out 2>&1 &
xrdp --nodaemon > /out/xrdp.out 2>&1 &
sleep 3
# listening sockets on port 3389 (0D3D) from /proc/net/tcp, whose
# addresses are hex: 0100007F is 127.0.0.1, 00000000 is any address
listeners() { awk '$4 == "0A" && $2 ~ /:0D3D$/ { print $2 }' /proc/net/tcp; }
check "xrdp listens on 127.0.0.1:3389 only" '[ "$(listeners)" = "0100007F:0D3D" ]'

echo "== connect"
tar -xJf /client -C /tmp
client=$(ls /tmp/*/bin/sdl-freerdp)
Xvfb :9 -screen 0 1280x800x24 > /dev/null 2>&1 &
sleep 2
DISPLAY=:9 "$client" /v:127.0.0.1 /u:tester /p:kit-test-pw /cert:ignore /size:1024x768 \
    > /out/client.log 2>&1 &
CLIENT=$!
sleep 20
DISPLAY=:9 import -window root /out/screen.png 2> /dev/null
check "the client is still connected" 'kill -0 $CLIENT'
check "sesman started an Xorg session for tester" 'pgrep -u tester -f "Xorg .*xrdp/xorg.conf" > /dev/null'
check "Xorg loaded the xorgxrdp drivers" \
    'grep -q -E "Loading .*(xrdpdev|libxorgxrdp)" /home/tester/.local/share/xrdp/*.log /home/tester/.xorgxrdp.*.log 2> /dev/null'
check "the session runs its xterm" 'pgrep -u tester xterm > /dev/null'
# the black desktop and the white xterm are two colours: a lossless or
# clean codec (AV1) shows exactly those, H.264 adds a few around the text
check "the client shows more than one colour" \
    '[ "$(convert /out/screen.png -format "%k" info: 2> /dev/null)" -gt 1 ]'

# The Wayland session (wlup): sway, headless, for a second user,
# picked with autorun; /bpp:24, because at 32 xrdp sends planar, which
# FreeRDP cannot resize
if [ -n "$NO_SWAY" ]; then
    echo "SKIP  the Wayland (sway) login: this release's sway is older than 1.11"
elif ls /usr/lib*/xrdp/libwlup.so > /dev/null 2>&1; then
    echo "== Wayland session (sway)"
    kill $CLIENT 2> /dev/null
    if command -v apt-get > /dev/null; then
        apt-get install -y -qq sway foot > /out/install-sway.log 2>&1
    else
        dnf -y -q install sway foot > /out/install-sway.log 2>&1
    fi
    useradd -m wayuser
    echo 'wayuser:kit-test-pw' | chpasswd
    mkdir -p /home/wayuser/.config/sway
    printf 'exec foot\n' > /home/wayuser/.config/sway/config
    chown -R wayuser: /home/wayuser/.config
    # the package lists it (an older one did not: add it then)
    check "the package lists the Wayland (sway) session" 'grep -q "^\[Wayland\]$" /etc/xrdp/xrdp.ini'
    grep -q '^\[Wayland\]$' /etc/xrdp/xrdp.ini ||
        printf '\n[Wayland]\nname=Wayland\nlib=libwlup.so\nusername=ask\npassword=ask\nport=-1\ncode=30\nxkb_layout=us\n' \
            >> /etc/xrdp/xrdp.ini
    sed -i '/^\[Globals\]/,/^\[/ s|^#\?autorun=.*|autorun=Wayland|' /etc/xrdp/xrdp.ini
    pkill -x xrdp; sleep 1
    xrdp --nodaemon > /out/xrdp-wayland.out 2>&1 &
    sleep 3
    DISPLAY=:9 "$client" /v:127.0.0.1 /u:wayuser /p:kit-test-pw /cert:ignore /size:1024x768 \
        /bpp:24 > /out/client-wayland.log 2>&1 &
    CLIENT=$!
    sleep 20
    DISPLAY=:9 import -window root /out/screen-wayland.png 2> /dev/null
    check "the Wayland client is still connected" 'kill -0 $CLIENT'
    check "sesman started sway for wayuser" 'pgrep -u wayuser -x sway > /dev/null'
    check "wlup captures sway's output at the client's 1024x768" \
        'grep -q "wlup: capture buffer 1024x768" /var/log/xrdp.log'
    check "the session runs its foot terminal" 'pgrep -u wayuser -x foot > /dev/null'
fi

cp /home/tester/.local/share/xrdp/*.log /out/ 2> /dev/null
cp /var/log/xrdp*.log /out/ 2> /dev/null
# readable by the host user (some logs are written with mode 600)
chmod -R a+rX /out
echo "passed $pass, failed $fail"
[ $fail = 0 ]
EOF

"$ENGINE" run --rm "${CAPS[@]}" -e NO_SWAY="$NO_SWAY" -e NO_KDE="$NO_KDE" -v "$PKGS":/pkgs:ro -v "$CLIENT":/client:ro -v "$OUT":/out \
    -v "$INSIDE":/test.sh:ro "$IMAGE" bash /test.sh
status=$?
rm -f "$INSIDE"
echo "($DISTRO: logs and screenshot in $OUT)"
exit $status
