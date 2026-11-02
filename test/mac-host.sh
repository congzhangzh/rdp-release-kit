#!/bin/bash
# The macOS host (FreeRDP-Shadow.app) on a GitHub macOS runner, with the kit's own macOS
# client: an AV1 session and an AV2 session against the server as its LaunchAgent starts it.
#   test/mac-host.sh <host dir (holds FreeRDP-Shadow.app)> <client dir (holds bin/sdl-freerdp)> <out dir>
# What the runner allows, found by the mac-capture-probe branch (2026-11-01):
#  - Screen Recording is granted to /bin/bash on GitHub's macOS images, so the server can
#    capture when this script starts it;
#  - the in-session server takes only the screen owner's login, and the runner account's
#    password can't be set (Secure Token): so -auth (no login), on 127.0.0.1 only, on a runner
#    thrown away after the job;
#  - ScreenCaptureKit hands over a frame only when the screen changes: apps open and close
#    during each session (not Chrome through `open -a`, which hung the job).
# Bash 3.2 (macOS's own) is enough here.
set -u
HOSTDIR=$1; CLIENTDIR=$2; OUT=$3
mkdir -p "$OUT"
SERVER="$HOSTDIR/FreeRDP-Shadow.app/Contents/MacOS/freerdp-shadow-cli"
CLIENT="$CLIENTDIR/bin/sdl-freerdp"
fails=0
check() {  # check <name> <0|1> [detail]
    if [ "$2" = 1 ]; then echo "PASS  $1${3:+  ($3)}"; else echo "FAIL  $1${3:+  ($3)}"; fails=$((fails + 1)); fi
}
listening() { nc -z 127.0.0.1 "$1" 2> /dev/null; }
motion() {  # something on screen changes during a session
    ( sleep 4; open -a Calculator; sleep 3; open -a "System Settings"; sleep 3
      osascript -e 'quit app "Calculator"'; sleep 2; open -a Calculator; sleep 3
      osascript -e 'quit app "System Settings"' ) > /dev/null 2>&1 &
}

{ sw_vers; uname -m; } > "$OUT/system.txt" 2>&1
# the arguments of build/macos/org.freerdp.shadow.plist, plus -auth and a test port
export WLOG_LEVEL=DEBUG WLOG_APPENDER=FILE WLOG_FILEAPPENDER_OUTPUT_FILE_PATH="$OUT"
WLOG_FILEAPPENDER_OUTPUT_FILE_NAME=server.wlog "$SERVER" /bind-address:127.0.0.1 /port:4489 \
    /sec:tls /gfx-av1 /gfx-av2 -gfx-avc444 -auth > "$OUT/server.out" 2>&1 &
SRV=$!
for i in $(seq 1 30); do listening 4489 && break; sleep 1; done
listening 4489 && ok=1 || ok=0
check "the host listens on 127.0.0.1:4489" $ok

session() {  # session <name> <codec expected> [client options...]
    name=$1; want=$2; shift 2
    motion
    WLOG_FILEAPPENDER_OUTPUT_FILE_NAME="$name.wlog" "$CLIENT" /v:127.0.0.1:4489 /u:probe /p:probe \
        /cert:ignore /sec:tls /size:1280x720 "$@" > "$OUT/$name.out" 2>&1 &
    c=$!
    sleep 20
    screencapture -x "$OUT/$name.png" 2> /dev/null || true
    kill -0 $c 2> /dev/null && held=1 || held=0
    kill $c 2> /dev/null; sleep 2
    check "$name: the session holds 20 s" $held
    n=$(grep -c "Got GFX RDPGFX_CODECID_$want\b" "$OUT/$name.wlog" 2> /dev/null || true)
    all=$(grep -ohE "Got GFX RDPGFX_CODECID_[A-Z0-9_]+" "$OUT/$name.wlog" 2> /dev/null | sort | uniq -c | tr '\n' ' ')
    # AV2 is libavm, AV2's reference encoder: about 1 frame a second on the runner's 3 cores
    # at 1024x768 (kit run 41393786845: 20 in 20 s), AV1 25-30
    min=30; [ "$want" = AV2 ] && min=10
    [ "${n:-0}" -ge $min ] && ok=1 || ok=0
    check "$name: at least $min frames in $want" $ok "${all:-none}"
    # no frames: where the server's threads wait (the host has frozen after a client's
    # Synchronize, kit runs 41366524328 to 41372917597); macOS's own sampler, 3 s
    if [ $ok = 0 ] && kill -0 $SRV 2> /dev/null; then
        sample $SRV 3 -file "$OUT/$name-server-sample.txt" > /dev/null 2>&1 || true
    fi
    sleep 3
}
# AV1 with AV2 off on the client (it offers both by default, and the server takes AV2 first;
# /gfx:AV1 alone still advertised FRDP_2, kit run 41366524328); AV2 last, since that run's AV2
# session took the server down (its log ends at the caps confirm 0x20000)
session av1 AV1 /gfx:AV2:off
alive() { kill -0 $SRV 2> /dev/null; }
alive && ok=1 || ok=0
check "the host is still running after the AV1 session" $ok
if alive; then
    # a client that offers AV2 (the kit's own, by default) gets AV2; before FreeRDP
    # 20261101.20's 8 MiB client thread stack, that crashed the host (kit run 41370598608)
    session av2 AV2
    alive && ok=1 || ok=0
    check "the host is still running after the AV2 session" $ok
else
    echo "SKIP  av2: the host is gone"
fi
# macOS's own crash reports of the server, if any
mkdir -p "$OUT/crash"
cp "$HOME"/Library/Logs/DiagnosticReports/freerdp-shadow-cli* "$OUT/crash/" 2> /dev/null || true
ls "$OUT/crash"

kill $SRV 2> /dev/null; sleep 1
grep -ohE "AV[12] [0-9]+x[0-9]+ (I420|I444): [0-9]+ frames in .*" "$OUT/server.wlog" > "$OUT/encoder-stats.txt" 2> /dev/null || true
cat "$OUT/encoder-stats.txt"
echo "$fails failed"
[ $fails = 0 ]
