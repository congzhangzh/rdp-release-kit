#!/bin/bash
# Installs the built xrdp packages in a fresh container of their release,
# logs in through RDP with the kit's portable client, and checks that an
# Xorg session (xorgxrdp) with an xterm comes up:
#
#   test/xrdp-session.sh <image> [client archive]
#
# The client defaults to the newest dist/sdl3-freerdp-*-linux-<arch>.tar.xz.
# Logs and a screenshot go to dist/xrdp/<release>/test/.
set -uo pipefail

KIT=$(cd "$(dirname "$0")/.." && pwd)
IMAGE=$1
CLIENT=${2:-$(find "$KIT/dist" -maxdepth 1 -name "sdl3-freerdp-*-linux-$(uname -m).tar.xz" | sort -V | tail -1)}
ENGINE=$(command -v podman || command -v docker)
# shellcheck disable=SC2016 # expanded by the container shell
DISTRO=$("$ENGINE" run --rm "$IMAGE" sh -c '. /etc/os-release; echo "$ID-${VERSION_ID:-$VERSION_CODENAME}"')
PKGS=$KIT/dist/xrdp/$DISTRO
OUT=$PKGS/test
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
check "the client shows more than one colour" \
    '[ "$(convert /out/screen.png -format "%k" info: 2> /dev/null)" -gt 2 ]'
cp /home/tester/.local/share/xrdp/*.log /out/ 2> /dev/null
cp /var/log/xrdp*.log /out/ 2> /dev/null
echo "passed $pass, failed $fail"
[ $fail = 0 ]
EOF

"$ENGINE" run --rm -v "$PKGS":/pkgs:ro -v "$CLIENT":/client:ro -v "$OUT":/out \
    -v "$INSIDE":/test.sh:ro "$IMAGE" bash /test.sh
status=$?
rm -f "$INSIDE"
echo "($DISTRO: logs and screenshot in $OUT)"
exit $status
