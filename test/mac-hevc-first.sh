#!/bin/bash
# HEVC first on the macOS host (FreeRDP feature-shadow-mac-hevc-first: the shadow's default codec
# order on macOS is HEVC, AV2, AV1, ...; VideoToolbox encodes HEVC in hardware), with the kit's own
# macOS client. One run, every answer:
#  A. CHECKS, a server with AV1, AV2 and HEVC 4:2:0 on (/gfx-hevc:i420):
#     - hevc-first-av1: AV2 off in the client, so it offers FRDP_1 + 11.x;
#     - hevc-first-all: the client's default and HEVC, so it offers FRDP_2, FRDP_1 + 11.x;
#     each: the session holds 20 s, the client offered what the case is about (its "Sending <caps>"
#     lines), 11.x confirmed with HEVC_ENABLE, at least 30 HEVC 4:2:0 frames.
#  B. freerdp-tk's entries, what a user picks: "H.265 (HEVC) 4:2:0" sends
#     /gfx-codec-order:HEVC,AV1,AVC420 (no :i420: naming HEVC there turns HEVC 4:4:4 on in the client
#     too), "AV1" sends /gfx-codec-order:AV1,AVC420; each against three servers:
#     - plist: the arguments of build/macos/org.freerdp.shadow.plist (HEVC not given: what the Mac
#       host does today);
#     - hevc: the same plus /gfx-hevc (no value: 4:2:0 and 4:4:4 allowed);
#     - hevc-i420: the same plus /gfx-hevc:i420.
#     CHECKED where the server has HEVC on: tk's HEVC session holds 20 s, 11.x confirmed with
#     HEVC_ENABLE, at least 30 HEVC frames (4:2:0 or 4:4:4). RECORDED for every session (RECORD lines,
#     the product owner's call): the caps confirmed, frames per codec, failed decodes, the server's
#     sent frames per second (its 5-second lines) and its CPU over the session.
#   test/mac-hevc-first.sh <host dir (holds FreeRDP-Shadow.app)> <client dir (holds bin/sdl-freerdp)> <out dir>
# Prints PASS/FAIL/RECORD lines; exits 0 only when every check passed. test/mac-host.sh runs it too.
# Bash 3.2 (macOS's own) is enough here.
set -u
HOSTDIR=$1; CLIENTDIR=$2; OUT=$3
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
SERVER="$HOSTDIR/FreeRDP-Shadow.app/Contents/MacOS/freerdp-shadow-cli"
CLIENT="$CLIENTDIR/bin/sdl-freerdp"
# the plist's arguments, without its address and port (build/macos/org.freerdp.shadow.plist)
PLIST_ARGS="/sec:tls /gfx-av1 /gfx-av2 -gfx-avc444"
fails=0
checks=0
check() {  # check <name> <0|1> [detail]
    checks=$((checks + 1))
    if [ "$2" = 1 ]; then echo "PASS  $1${3:+  ($3)}"; else echo "FAIL  $1${3:+  ($3)}"; fails=$((fails + 1)); fi
}
record() { echo "RECORD  $*"; }
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

SRV=; SLOG=; PORT=
server_start() {  # server_start <name> <port> [arguments...]: the server, its log $OUT/server-<name>.wlog
    sname=$1; PORT=$2; shift 2
    SLOG="$OUT/server-$sname.wlog"
    WLOG_FILEAPPENDER_OUTPUT_FILE_NAME="server-$sname.wlog" "$SERVER" /bind-address:127.0.0.1 /port:$PORT \
        "$@" -auth > "$OUT/server-$sname.out" 2>&1 &
    SRV=$!
    for i in $(seq 1 30); do listening $PORT && break; sleep 1; done
    listening $PORT && ok=1 || ok=0
    check "server $sname ($*) listens on $PORT" $ok
}
server_stop() { kill $SRV 2> /dev/null; sleep 2; }
cpu_seconds() {  # the server's CPU time so far, in seconds (ps: [[dd-]hh:]mm:ss.ss)
    ps -o time= -p $SRV 2> /dev/null | awk -F'[-:]' '{ s = 0; for (i = 1; i <= NF; i++) s = s * 60 + $i; printf "%.2f", s }'
}
HELD=0
session() {  # session <name> <client option>: 20 s; sets HELD; the client's log $OUT/<name>.wlog
    name=$1; opt=$2
    stats_before=$(grep -cE "gfx [0-9.]+ s: captured" "$SLOG" 2> /dev/null || true)
    cpu_before=$(cpu_seconds)
    motion
    WLOG_FILEAPPENDER_OUTPUT_FILE_NAME="$name.wlog" "$CLIENT" /v:127.0.0.1:$PORT /u:probe /p:probe \
        /cert:ignore /sec:tls /size:1280x720 "$opt" > "$OUT/$name.out" 2>&1 &
    c=$!
    sleep 20
    kill -0 $c 2> /dev/null && HELD=1 || HELD=0
    cpu_after=$(cpu_seconds)
    kill $c 2> /dev/null; sleep 2
    log="$OUT/$name.wlog"
    # the record of every session
    record "$name ($opt): $(grep -m1 -oE 'RecvCapsConfirmPdu: version: RDPGFX_CAPVERSION_[A-Z0-9_]+ [^ ]+ flags: [^ ]+' "$log" 2> /dev/null || echo 'no caps confirmed')"
    record "$name: frames $(grep -oE 'Got GFX RDPGFX_CODECID_[A-Z0-9_]+' "$log" 2> /dev/null | sed 's/Got GFX RDPGFX_CODECID_//' | sort | uniq -c | tr -s ' ' | tr '\n' ' ')"
    record "$name: failed decodes $(grep -ciE 'decode[a-z]* failed|decoder requires a key picture' "$log" 2> /dev/null || true)"
    grep -ohE "gfx [0-9.]+ s: captured [0-9]+ \([0-9.]+/s\), sent [0-9]+ \([0-9.]+/s\)" "$SLOG" 2> /dev/null |
        tail -n +$(( ${stats_before:-0} + 1 )) | sed "s/^/RECORD  $name: server /"
    record "$name: server CPU $(awk -v a="${cpu_before:-0}" -v b="${cpu_after:-0}" 'BEGIN { printf "%.1f", (b - a) / 20 * 100 }') % of one core over 20 s"
    sleep 3
}
confirmed_hevc() { grep -qE "RecvCapsConfirmPdu: version: RDPGFX_CAPVERSION_11[0-9]+ .*[{|]HEVC_ENABLE[|}]" "$1" 2> /dev/null; }
frames() { n=$(grep -c "Got GFX RDPGFX_CODECID_$2\b" "$1" 2> /dev/null || true); echo "${n:-0}"; }

# A. the checks of HEVC first
# shellcheck disable=SC2086 # the plist's arguments are words
server_start checks 4492 $PLIST_ARGS /gfx-hevc:i420
for s in "hevc-first-av1 FRDP_1 /gfx:AV2:off,HEVC:i420" "hevc-first-all FRDP_2 /gfx:HEVC:i420"; do
    name=${s%% *}; rest=${s#* }; other=${rest%% *}; opt=${rest#* }
    session "$name" "$opt"
    log="$OUT/$name.wlog"
    check "$name: the session holds 20 s" $HELD
    grep -q "Sending RDPGFX_CAPVERSION_$other " "$log" 2> /dev/null && a=1 || a=0
    grep -qE "Sending RDPGFX_CAPVERSION_11[0-9]+ " "$log" 2> /dev/null && b=1 || b=0
    [ $a = 1 ] && [ $b = 1 ] && ok=1 || ok=0
    check "$name: the client offered $other and 11.x" $ok \
        "$(grep -oE 'Sending RDPGFX_CAPVERSION_[A-Z0-9_]+' "$log" 2> /dev/null | sed 's/Sending RDPGFX_CAPVERSION_//' | tr '\n' ' ')"
    confirmed_hevc "$log" && ok=1 || ok=0
    check "$name: the Mac server confirms 11.x (HEVC) before $other" $ok
    n=$(frames "$log" HEVC420)
    [ "$n" -ge 30 ] && ok=1 || ok=0
    check "$name: at least 30 frames in HEVC420" $ok "$n"
done
server_stop

# B. freerdp-tk's HEVC and AV1 entries against the plist's server, with /gfx-hevc, with /gfx-hevc:i420
for v in "plist 4493" "hevc 4494 /gfx-hevc" "hevc-i420 4495 /gfx-hevc:i420"; do
    sname=${v%% *}; rest=${v#* }; port=${rest%% *}; extra=; [ "$rest" = "$port" ] || extra=${rest#* }
    # shellcheck disable=SC2086 # the plist's arguments are words, $extra one word or none
    server_start "$sname" "$port" $PLIST_ARGS $extra
    session "tk-hevc-$sname" "/gfx-codec-order:HEVC,AV1,AVC420"
    log="$OUT/tk-hevc-$sname.wlog"
    if [ -n "$extra" ]; then
        check "tk-hevc-$sname: the session holds 20 s" $HELD
        confirmed_hevc "$log" && ok=1 || ok=0
        check "tk-hevc-$sname: the Mac server confirms 11.x (HEVC)" $ok
        n=$(( $(frames "$log" HEVC420) + $(frames "$log" HEVC444) ))
        [ "$n" -ge 30 ] && ok=1 || ok=0
        check "tk-hevc-$sname: at least 30 HEVC frames (4:2:0 or 4:4:4)" $ok "$n"
    fi
    session "tk-av1-$sname" "/gfx-codec-order:AV1,AVC420"
    server_stop
done
# a run that made no check proves nothing: 1 + (1 + 2 x 4) for A + (3 + 2 x 3) for B
[ $checks -ge 19 ] || { echo "FAIL  HEVC first: only $checks checks ran"; fails=$((fails + 1)); }
echo "$fails failed"
[ $fails = 0 ]
