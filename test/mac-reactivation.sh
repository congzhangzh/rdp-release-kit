#!/bin/bash
# The resize reactivation on the macOS host (FreeRDP fix-shadow-reactivation-svc: the shadow holds
# the channel data from the Deactivate All to the next activation). Kit round 46157207304 lost a
# session to it: the rdpsnd Server Audio Formats PDU reached the client between the Deactivate All
# and the new Demand Active, and the client dropped the connection ("unexpected MCS channel id
# 03ed received"). Here: one server with the plist's arguments, N connects (default 40) of the
# kit's client at 1280x720, which is not the runner's desktop (1024x768), so every connect goes
# through the resize reactivation. Each holds 6 s.
# CHECKS: every connect that reached the server is resized ("resize requested" in the server
# log) and holds; no client log says "unexpected MCS channel id"; GFX frames arrive.
# A client that never connects (the runner's display without a size at a slow app start, the
# backlog row from round 46161035628) is RECORDED and not counted as a connect.
#   test/mac-reactivation.sh <host dir (holds FreeRDP-Shadow.app)> <client dir (holds bin/sdl-freerdp)> <out dir> [N]
# Prints PASS/FAIL/RECORD lines; exits 0 only when every check passed. Bash 3.2 is enough here.
set -u
HOSTDIR=$1; CLIENTDIR=$2; OUT=$3; N=${4:-40}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
SERVER="$HOSTDIR/FreeRDP-Shadow.app/Contents/MacOS/freerdp-shadow-cli"
CLIENT="$CLIENTDIR/bin/sdl-freerdp"
# the plist's arguments, without its address and port (build/macos/org.freerdp.shadow.plist)
PLIST_ARGS="/sec:tls /gfx-av1 /gfx-av2 -gfx-avc444 /gfx-hevc:i420"
PORT=4496
fails=0
checks=0
check() {  # check <name> <0|1> [detail]
    checks=$((checks + 1))
    if [ "$2" = 1 ]; then echo "PASS  $1${3:+  ($3)}"; else echo "FAIL  $1${3:+  ($3)}"; fails=$((fails + 1)); fi
}
record() { echo "RECORD  $*"; }
listening() { nc -z 127.0.0.1 "$1" 2> /dev/null; }

export WLOG_LEVEL=DEBUG WLOG_APPENDER=FILE WLOG_FILEAPPENDER_OUTPUT_FILE_PATH="$OUT"
SLOG="$OUT/server.wlog"
# shellcheck disable=SC2086 # the plist's arguments are words
WLOG_FILEAPPENDER_OUTPUT_FILE_NAME="server.wlog" "$SERVER" /bind-address:127.0.0.1 /port:$PORT \
    $PLIST_ARGS -auth > "$OUT/server.out" 2>&1 &
SRV=$!
for _ in $(seq 1 30); do listening $PORT && break; sleep 1; done
listening $PORT && ok=1 || ok=0
check "server ($PLIST_ARGS) listens on $PORT" $ok
[ $ok = 1 ] || { echo "$fails failed"; exit 1; }

connected=0; held=0; unexpected=0; framed=0; noconnect=0
for i in $(seq 1 "$N"); do
    name=$(printf "connect-%02d" "$i")
    WLOG_FILEAPPENDER_OUTPUT_FILE_NAME="$name.wlog" "$CLIENT" /v:127.0.0.1:$PORT /u:probe /p:probe \
        /cert:ignore /sec:tls /size:1280x720 > "$OUT/$name.out" 2>&1 &
    c=$!
    sleep 6
    kill -0 $c 2> /dev/null && h=1 || h=0
    kill $c 2> /dev/null; sleep 1
    log="$OUT/$name.wlog"
    if ! grep -q "CONNECTION_STATE_" "$log" 2> /dev/null; then
        noconnect=$((noconnect + 1))
        record "$name: never connected: $(grep -m1 -oE 'usable size|ERROR\]\[[^]]+\] - \[[^]]+\]: [^[]{0,80}' "$log" 2> /dev/null | head -1)"
        continue
    fi
    connected=$((connected + 1))
    held=$((held + h))
    u=$(grep -c "unexpected MCS channel id" "$log" 2> /dev/null || true)
    unexpected=$((unexpected + ${u:-0}))
    f=$(grep -c "Got GFX RDPGFX_CODECID_" "$log" 2> /dev/null || true)
    [ "${f:-0}" -gt 0 ] && framed=$((framed + 1))
    record "$name: held $h, unexpected $u, frames ${f:-0}"
done
kill $SRV 2> /dev/null; sleep 2
resized=$(grep -c "resize requested" "$SLOG" 2> /dev/null || true)

record "connects $connected of $N, never connected $noconnect, resized $resized"
[ "$connected" -ge $((N * 3 / 4)) ] && ok=1 || ok=0
check "at least 3/4 of the $N clients connected" $ok "$connected"
[ "${resized:-0}" -ge "$connected" ] && ok=1 || ok=0
check "every connect went through the resize reactivation" $ok "resized ${resized:-0}, connects $connected"
[ "$unexpected" = 0 ] && ok=1 || ok=0
check "no client says \"unexpected MCS channel id\"" $ok "$unexpected"
[ "$held" = "$connected" ] && ok=1 || ok=0
check "every connect holds 6 s" $ok "$held of $connected"
[ "$framed" = "$connected" ] && ok=1 || ok=0
check "every connect gets GFX frames" $ok "$framed of $connected"
echo "$fails failed"
[ $fails = 0 ]
