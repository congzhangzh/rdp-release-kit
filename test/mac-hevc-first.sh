#!/bin/bash
# B3b on the macOS host (FreeRDP feature-client-gfx-default-order: a client that names no codec
# prefers HEVC 4:2:0, then AV1, then AV2; /gfx: names the codecs in the order preferred; the
# shadow follows the client's order), with the kit's own macOS client. Two servers:
#  - plist: build/macos/org.freerdp.shadow.plist's arguments, now with /gfx-hevc:i420 (VideoToolbox);
#  - nohevc: the same without HEVC (the Mac host before B3b, and every host without an HEVC encoder).
# Sessions, each CHECKED (holds 20 s, the caps set confirmed, at least 30 frames of its codec):
#  plist  default (no codec option)          -> 11.x HEVC_ENABLE, HEVC420 frames
#  plist  tk-hevc  /gfx:HEVC:i420,AV1,AVC420 -> 11.x, HEVC420 (freerdp-tk's HEVC entry)
#  plist  hevc-only /gfx:HEVC:i420           -> 11.x, HEVC420 (HEVC alone, as /gfx:AV1 is AV1 alone)
#  plist  tk-av1   /gfx:AV1:i444             -> FRDP_1, AV1 (no FRDP_2 offered)
#  plist  av2-first /gfx:AV2,AV1             -> FRDP_2, AV1-id frames (AV2 only when asked first)
#  nohevc default                            -> FRDP_1, AV1 (not 11.x, not FRDP_2)
#  nohevc tk-hevc  /gfx:HEVC:i420,AV1,AVC420 -> FRDP_1, AV1
# RECORDED for every session: caps, frames per codec, failed decodes, server fps and CPU.
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
PLIST_ARGS="/sec:tls /gfx-av1 /gfx-av2 -gfx-avc444 /gfx-hevc:i420"
# and the Mac host before B3b, HEVC off
NOHEVC_ARGS="/sec:tls /gfx-av1 /gfx-av2 -gfx-avc444"
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
check "B3b: the host and the client are built with WITH_GFX_AZURE" $ok
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
session() {  # session <name> [client option]: 20 s; sets HELD; the client's log $OUT/<name>.wlog
    name=$1; opt=${2:-}
    stats_before=$(grep -cE "gfx [0-9.]+ s: captured" "$SLOG" 2> /dev/null || true)
    cpu_before=$(cpu_seconds)
    motion
    WLOG_FILEAPPENDER_OUTPUT_FILE_NAME="$name.wlog" "$CLIENT" /v:127.0.0.1:$PORT /u:probe /p:probe \
        /cert:ignore /sec:tls /size:1280x720 ${opt:+"$opt"} > "$OUT/$name.out" 2>&1 &
    c=$!
    sleep 20
    kill -0 $c 2> /dev/null && HELD=1 || HELD=0
    cpu_after=$(cpu_seconds)
    kill $c 2> /dev/null; sleep 2
    log="$OUT/$name.wlog"
    # the record of every session
    record "$name (${opt:-no codec option}): $(grep -m1 -oE 'RecvCapsConfirmPdu: version: RDPGFX_CAPVERSION_[A-Z0-9_]+ [^ ]+ flags: [^ ]+' "$log" 2> /dev/null || echo 'no caps confirmed')"
    record "$name: frames $(grep -oE 'Got GFX RDPGFX_CODECID_[A-Z0-9_]+' "$log" 2> /dev/null | sed 's/Got GFX RDPGFX_CODECID_//' | sort | uniq -c | tr -s ' ' | tr '\n' ' ')"
    record "$name: failed decodes $(grep -ciE 'decode[a-z]* failed|decoder requires a key picture' "$log" 2> /dev/null || true)"
    grep -ohE "gfx [0-9.]+ s: captured [0-9]+ \([0-9.]+/s\), sent [0-9]+ \([0-9.]+/s\)" "$SLOG" 2> /dev/null |
        tail -n +$(( ${stats_before:-0} + 1 )) | sed "s/^/RECORD  $name: server /"
    record "$name: server CPU $(awk -v a="${cpu_before:-0}" -v b="${cpu_after:-0}" 'BEGIN { printf "%.1f", (b - a) / 20 * 100 }') % of one core over 20 s"
    sleep 3
}
confirmed_hevc() { grep -qE "RecvCapsConfirmPdu: version: RDPGFX_CAPVERSION_11[0-9]+ .*[{|]HEVC_ENABLE[|}]" "$1" 2> /dev/null; }
frames() { n=$(grep -c "Got GFX RDPGFX_CODECID_$2\b" "$1" 2> /dev/null || true); echo "${n:-0}"; }

check_session() {  # check_session <name> <version: 11|FRDP_1|FRDP_2> <frame codec(s), | separated>
    name=$1; want=$2; codecs=$3; log="$OUT/$name.wlog"
    check "$name: the session holds 20 s" $HELD
    if [ "$want" = 11 ]; then
        confirmed_hevc "$log" && ok=1 || ok=0
    else
        grep -q "RecvCapsConfirmPdu: version: RDPGFX_CAPVERSION_$want " "$log" 2> /dev/null && ok=1 || ok=0
    fi
    check "$name: the Mac server confirms $want" $ok \
        "$(grep -m1 -oE 'RecvCapsConfirmPdu: version: RDPGFX_CAPVERSION_[A-Z0-9_]+' "$log" 2> /dev/null)"
    n=0; IFS='|'; for c in $codecs; do n=$((n + $(frames "$log" "$c"))); done; unset IFS
    [ "$n" -ge 30 ] && ok=1 || ok=0
    check "$name: at least 30 frames in $codecs" $ok "$n"
}

# shellcheck disable=SC2086 # the plist's arguments are words
server_start plist 4492 $PLIST_ARGS
session plist-default;                                     check_session plist-default 11 HEVC420
session plist-tk-hevc "/gfx:HEVC:i420,AV1,AVC420";         check_session plist-tk-hevc 11 HEVC420
session plist-hevc-only "/gfx:HEVC:i420";                  check_session plist-hevc-only 11 HEVC420
session plist-tk-av1 "/gfx:AV1:i444";                      check_session plist-tk-av1 FRDP_1 AV1
grep -q "Sending RDPGFX_CAPVERSION_FRDP_2 " "$OUT/plist-tk-av1.wlog" 2> /dev/null && ok=0 || ok=1
check "plist-tk-av1: the client does not offer FRDP_2" $ok
session plist-av2-first "/gfx:AV2,AV1";                    check_session plist-av2-first FRDP_2 AV1
server_stop

# shellcheck disable=SC2086 # the arguments are words
server_start nohevc 4493 $NOHEVC_ARGS
session nohevc-default;                                    check_session nohevc-default FRDP_1 AV1
session nohevc-tk-hevc "/gfx:HEVC:i420,AV1,AVC420";        check_session nohevc-tk-hevc FRDP_1 AV1
server_stop

# a run that made no check proves nothing: 1 + 2 servers + 7 sessions x 3 + 1
[ $checks -ge 25 ] || { echo "FAIL  B3b: only $checks checks ran"; fails=$((fails + 1)); }
echo "$fails failed"
[ $fails = 0 ]
