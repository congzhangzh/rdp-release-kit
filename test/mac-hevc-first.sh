#!/bin/bash
# HEVC first on the macOS host (FreeRDP feature-shadow-mac-hevc-first: the shadow's default codec
# order on macOS is HEVC, AV2, AV1, ...; VideoToolbox encodes HEVC in hardware). A server with AV1,
# AV2 and HEVC all on, and two sessions of the kit's own macOS client:
#  - hevc-first-av1: AV2 off in the client, so it offers FRDP_1 + 11.x;
#  - hevc-first-all: the client's default and HEVC, so it offers FRDP_2, FRDP_1 + 11.x.
# Each first proves the client offered what it is about (its "Sending <caps>" lines), then that the
# server confirmed 11.x with HEVC_ENABLE and sent HEVC 4:2:0 frames.
#   test/mac-hevc-first.sh <host dir (holds FreeRDP-Shadow.app)> <client dir (holds bin/sdl-freerdp)> <out dir> [port]
# Prints PASS/FAIL lines; exits 0 only when every check passed. test/mac-host.sh runs it too.
# Bash 3.2 (macOS's own) is enough here.
set -u
HOSTDIR=$1; CLIENTDIR=$2; OUT=$3; PORT=${4:-4492}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
SERVER="$HOSTDIR/FreeRDP-Shadow.app/Contents/MacOS/freerdp-shadow-cli"
CLIENT="$CLIENTDIR/bin/sdl-freerdp"
fails=0
checks=0
check() {  # check <name> <0|1> [detail]
    checks=$((checks + 1))
    if [ "$2" = 1 ]; then echo "PASS  $1${3:+  ($3)}"; else echo "FAIL  $1${3:+  ($3)}"; fails=$((fails + 1)); fi
}
listening() { nc -z 127.0.0.1 "$1" 2> /dev/null; }
motion() {  # something on screen changes during a session (ScreenCaptureKit sends only changes)
    ( sleep 4; open -a Calculator; sleep 3; open -a "System Settings"; sleep 3
      osascript -e 'quit app "Calculator"'; sleep 2; open -a Calculator; sleep 3
      osascript -e 'quit app "System Settings"' ) > /dev/null 2>&1 &
}

ok=1
for b in "$SERVER" "$CLIENT"; do
    "$b" /buildconfig 2> /dev/null | tr " " "\n" | grep -qx "WITH_GFX_AZURE=ON" || ok=0
done
check "HEVC first: the host and the client are built with WITH_GFX_AZURE" $ok
[ $ok = 1 ] || { echo "$fails failed"; exit 1; }

export WLOG_LEVEL=DEBUG WLOG_APPENDER=FILE WLOG_FILEAPPENDER_OUTPUT_FILE_PATH="$OUT"
WLOG_FILEAPPENDER_OUTPUT_FILE_NAME=server-hevc-first.wlog "$SERVER" /bind-address:127.0.0.1 /port:$PORT \
    /sec:tls /gfx-av1 /gfx-av2 -gfx-avc444 /gfx-hevc:i420 -auth > "$OUT/server-hevc-first.out" 2>&1 &
SRV=$!
for i in $(seq 1 30); do listening $PORT && break; sleep 1; done
listening $PORT && ok=1 || ok=0
check "HEVC first: the server with AV1, AV2 and HEVC listens on $PORT" $ok

for s in "hevc-first-av1 FRDP_1 /gfx:AV2:off,HEVC:i420" "hevc-first-all FRDP_2 /gfx:HEVC:i420"; do
    name=${s%% *}; rest=${s#* }; other=${rest%% *}; opts=${rest#* }
    log="$OUT/$name.wlog"
    motion
    WLOG_FILEAPPENDER_OUTPUT_FILE_NAME="$name.wlog" "$CLIENT" /v:127.0.0.1:$PORT /u:probe /p:probe \
        /cert:ignore /sec:tls /size:1280x720 "$opts" > "$OUT/$name.out" 2>&1 &
    c=$!
    sleep 20
    kill -0 $c 2> /dev/null && held=1 || held=0
    kill $c 2> /dev/null; sleep 2
    check "$name: the session holds 20 s" $held
    grep -q "Sending RDPGFX_CAPVERSION_$other " "$log" 2> /dev/null && a=1 || a=0
    grep -qE "Sending RDPGFX_CAPVERSION_11[0-9]+ " "$log" 2> /dev/null && b=1 || b=0
    [ $a = 1 ] && [ $b = 1 ] && ok=1 || ok=0
    check "$name: the client offered $other and 11.x" $ok \
        "$(grep -oE 'Sending RDPGFX_CAPVERSION_[A-Z0-9_]+' "$log" 2> /dev/null | sed 's/Sending RDPGFX_CAPVERSION_//' | tr '\n' ' ')"
    grep -E "RecvCapsConfirmPdu: version: RDPGFX_CAPVERSION_11[0-9]+ .*[{|]HEVC_ENABLE[|}]" "$log" \
        2> /dev/null > /dev/null && ok=1 || ok=0
    check "$name: the Mac server confirms 11.x (HEVC) before $other" $ok \
        "$(grep -m1 -oE 'RecvCapsConfirmPdu: version: .*' "$log" 2> /dev/null)"
    # the hevc sessions of mac-host.sh ask for 30 HEVC 4:2:0 frames in 20 s too
    n=$(grep -c "Got GFX RDPGFX_CODECID_HEVC420\b" "$log" 2> /dev/null || true)
    [ "${n:-0}" -ge 30 ] && ok=1 || ok=0
    check "$name: at least 30 frames in HEVC420" $ok "${n:-0}"
    sleep 3
done
kill $SRV 2> /dev/null; sleep 1
# a run that made no check proves nothing
[ $checks -ge 10 ] || { echo "FAIL  HEVC first: only $checks checks ran"; fails=$((fails + 1)); }
echo "$fails failed"
[ $fails = 0 ]
