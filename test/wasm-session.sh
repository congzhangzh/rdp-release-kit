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
# check() evaluates its second argument later, so it is single-quoted on purpose
# shellcheck disable=SC2016
set -uo pipefail

KIT=$(cd "$(dirname "$0")/.." && pwd)
PAGE=$(cd "$1" && pwd)
GATEWAY=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
PKGS=${3:-$KIT/dist/xrdp/debian-13}
ENGINE=${ENGINE:-$(command -v docker || command -v podman)}
OUT=$KIT/dist/test/wasm
NAME=kit-wasm-server
rm -rf "$OUT"; mkdir -p "$OUT/ssh"
ssh-keygen -q -t ed25519 -N '' -f "$OUT/ssh/key" -C wasm-session-test
SSH_OPTS="-p 2223 -i $OUT/ssh/key -o IdentitiesOnly=yes -o UserKnownHostsFile=$OUT/ssh/known_hosts -o StrictHostKeyChecking=accept-new"
export SSH_OPTS

cleanup() {
    [ -n "${GW:-}" ] && kill "$GW" 2> /dev/null
    [ -n "${HTTP:-}" ] && kill "$HTTP" 2> /dev/null
    "$ENGINE" rm -f "$NAME" > /dev/null 2>&1
    rm -rf "$OUT/ssh"
}
trap cleanup EXIT

echo "== server: sshd + xrdp on 127.0.0.1 only"
"$ENGINE" rm -f "$NAME" > /dev/null 2>&1
"$ENGINE" run -d --name "$NAME" -p 127.0.0.1:2223:22 -v "$OUT/ssh/key.pub":/key.pub:ro \
    -v "$PKGS":/pkgs:ro debian:13 sleep 3600 > /dev/null
ls "$PKGS"/xrdp_*.deb "$PKGS"/xorgxrdp_*.deb > /dev/null || { echo "no xrdp packages in $PKGS" >&2; exit 1; }
"$ENGINE" exec "$NAME" bash -c '
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq > /dev/null
    apt-get install -y -qq openssh-server websockify xterm /pkgs/*.deb > /tmp/apt.log 2>&1 ||
        { tail -20 /tmp/apt.log; exit 1; }
    useradd -m -s /bin/bash tester && echo tester:kit-test-pw | chpasswd
    install -d -m 700 -o tester -g tester /home/tester/.ssh
    install -m 600 -o tester -g tester /key.pub /home/tester/.ssh/authorized_keys
    printf "#!/bin/sh\nexec xterm\n" > /home/tester/.xsession; chmod +x /home/tester/.xsession
    sed -i "/^\[Globals\]/,/^\[/ s|^port=.*|port=tcp://.:3389|" /etc/xrdp/xrdp.ini
    mkdir -p /run/sshd && /usr/sbin/sshd
    (xrdp-sesman --nodaemon > /tmp/sesman.out 2>&1 &); (xrdp --nodaemon > /tmp/xrdp.out 2>&1 &)
    sleep 3' || { echo "the test server could not be set up" >&2; exit 1; }

echo "== gateway: rdp-gateway.sh tester@127.0.0.1 (one step)"
script -q -c "$GATEWAY tester@127.0.0.1" /dev/null > "$OUT/gateway.log" 2>&1 &
GW=$!
echo "== page: plain static server, no COOP/COEP"
(cd "$PAGE" && exec python3 -m http.server 8199 --bind 127.0.0.1) > "$OUT/http.log" 2>&1 &
HTTP=$!
sleep 6

node "$KIT/test/wasm-session.mjs" http://127.0.0.1:8199/index.html 127.0.0.1:6080 tester kit-test-pw "$OUT"
sleep 2
pass=0; fail=0
check() { if eval "$2"; then echo "PASS  $1"; pass=$((pass + 1)); else echo "FAIL  $1"; fail=$((fail + 1)); fi; }
check "an Xorg session started for tester" \
    '"$ENGINE" exec "$NAME" pgrep -u tester -f "Xorg .*xrdp/xorg.conf" > /dev/null'
check "the session runs its xterm" '"$ENGINE" exec "$NAME" pgrep -u tester xterm > /dev/null'
check "the screenshot shows more than one colour" \
    '[ "$(uvx -q --with pillow python -c "import sys; from PIL import Image; print(len(Image.open(sys.argv[1]).convert(\"RGB\").getcolors(1 << 24)))" "$OUT/wasm-session.png" 2> /dev/null || echo 0)" -gt 2 ]'
echo "passed $pass, failed $fail (screenshot, page log: $OUT)"
[ "$fail" = 0 ]
