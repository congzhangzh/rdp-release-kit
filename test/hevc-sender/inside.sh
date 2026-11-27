#!/bin/bash
# The HEVC checks, inside the sender's image (test/hevc-sender/Dockerfile), as root:
#
#   inside.sh
#
# Mounted by test/hevc-session.sh: /after.tar.xz (the client under test), /before.tar.xz
# (optional: the client it replaces, e.g. main's), /out (logs, screenshots). The desktop is
# an xterm with a clock on Xvfb :1, shared by the sender as the user tester; each client runs
# as root on Xvfb :99.
#
#  1. The default is unchanged: a client given no codec offers the same capability sets with
#     the same flags as before (H.264 not offered: the 8.1 set without AVC420_ENABLED, every
#     10.x one with AVC_DISABLED but 10.1, which has no flags; no HEVC_ENABLE) and is confirmed
#     the same version.
#  2. HEVC on request (/gfx:AV2:off,AV1:off,HEVC:i420; H.264 left off): the sender confirms an
#     11.x set with HEVC_ENABLE, the frames come in HEVC 4:2:0, none in AVC, no decode fails,
#     and the client names its decoder: "HEVC decoder: libavcodec (software)".
#  3. H.264 still there on request (/gfx:AVC420): frames in H.264, AVC420 or AVC444 (a 10.x set
#     without AVC_DISABLED lets the server pick AVC444; kit probe run 46025089159), and
#     "H.264 decoder: libavcodec".
# check() evaluates its condition itself: single quotes, variables read only there
# shellcheck disable=SC2016,SC2034
set -u
OUT=/out
chmod 777 "$OUT"
pass=0
fail=0
check() {  # check <name> <condition> [detail]
    if eval "$2"; then
        echo "PASS  $1${3:+  ($3)}"; pass=$((pass + 1))
    else
        echo "FAIL  $1${3:+  ($3)}"; fail=$((fail + 1))
    fi
}

for c in after before avc-before; do
    [ -f "/$c.tar.xz" ] || continue
    mkdir -p "/opt/$c" && tar -xJf "/$c.tar.xz" -C "/opt/$c" --strip-components=1
done
Xvfb :99 -noreset -screen 0 1600x1000x24 > "$OUT/xvfb-client.log" 2>&1 &
Xvfb :1 -noreset -screen 0 1280x800x24 > "$OUT/xvfb-desktop.log" 2>&1 &
sleep 2
su tester -s /bin/bash -c "DISPLAY=:1 nohup xterm -geometry 80x24+100+100 \
    -e sh -c 'while :; do date +%T.%N; sleep 0.05; done' > /dev/null 2>&1 &"

# the sender: no login (-auth), TLS, HEVC 4:2:0 offered; its codec order as it comes (AV2, AV1,
# HEVC, the rest), so only a client without AV1 gets HEVC. FFmpeg's own lines (x265's banner)
# go to its stderr, server.out
su tester -s /bin/bash -c "DISPLAY=:1 WLOG_LEVEL=INFO WLOG_APPENDER=FILE WLOG_FILEAPPENDER_OUTPUT_FILE_PATH=$OUT \
    WLOG_FILEAPPENDER_OUTPUT_FILE_NAME=server.log nohup /opt/hevc-sender/bin/freerdp-shadow-cli \
    /bind-address:127.0.0.1 /port:3389 -auth /sec:tls /gfx-hevc:i420 > $OUT/server.out 2>&1 &"
for _ in $(seq 30); do grep -q "Listening on" "$OUT/server.log" 2> /dev/null && break; sleep 1; done
check "the sender listens" 'grep -q "Listening on" "$OUT/server.log"'

# session <client> <name> [options...]: 20 s of a session, its log in /out/<name>.wlog
session() {
    local client=$1 name=$2
    shift 2
    WLOG_LEVEL=DEBUG WLOG_APPENDER=FILE WLOG_FILEAPPENDER_OUTPUT_FILE_PATH="$OUT" \
        WLOG_FILEAPPENDER_OUTPUT_FILE_NAME="$name.wlog" DISPLAY=:99 \
        "/opt/$client/bin/sdl-freerdp" /v:127.0.0.1:3389 /u:tester /p:unused /cert:ignore /sec:tls \
        /size:1280x800 "$@" > "$OUT/$name.out" 2>&1 &
    CPID=$!
    sleep 20
    DISPLAY=:99 import -window root "$OUT/$name.png" 2> /dev/null
    check "$name: the session holds" 'kill -0 $CPID'
    kill $CPID 2> /dev/null
    sleep 2
}
frames() { grep -c "Got GFX RDPGFX_CODECID_$2\b" "$OUT/$1.wlog" 2> /dev/null || true; }
codecs() {
    grep -ohE "Got GFX RDPGFX_CODECID_[A-Z0-9_]+|RecvCapsConfirmPdu: version: RDPGFX_CAPVERSION_[A-Z0-9_]+" \
        "$OUT/$1.wlog" 2> /dev/null | sed 's/RecvCapsConfirmPdu: version: //' | sort | uniq -c | tr '\n' ' '
}
# the negotiation of a session: the sets the client offers with their flags (names and
# number), then what the server confirms
negotiation() {
    grep -oE "Sending RDPGFX_CAPVERSION_[A-Z0-9_]+ \[0x[0-9a-fA-F]+\] flags=.*|RecvCapsConfirmPdu: version: .*" \
        "$OUT/$1.wlog" 2> /dev/null
}

# 1. no codec asked for
for c in before after; do
    [ -d "/opt/$c" ] || continue
    session "$c" "default-$c"
    negotiation "default-$c" > "$OUT/default-$c.caps"
    echo "INFO  default-$c: $(codecs "default-$c")"
done
check "default-after: offers no H.264 (no AVC420_ENABLED, AVC_DISABLED in every 10.x set) and no HEVC" \
    '[ -s "$OUT/default-after.caps" ] && ! grep -qE "AVC420_ENABLED|HEVC_ENABLE" "$OUT/default-after.caps" &&
     ! grep -E "^Sending RDPGFX_CAPVERSION_10" "$OUT/default-after.caps" | grep -v "^Sending RDPGFX_CAPVERSION_101 " |
         grep -v -q AVC_DISABLED' \
    "$(grep -c '^Sending' "$OUT/default-after.caps" 2> /dev/null) sets offered"
check "default-after: frames, none in AVC or HEVC" \
    '[ "$(frames default-after AVC420)$(frames default-after AVC444)$(frames default-after AVC444v2)$(frames default-after HEVC420)" = 0000 ] &&
     grep -q "Got GFX RDPGFX_CODECID_" "$OUT/default-after.wlog"' "$(codecs default-after)"
if [ -d /opt/before ]; then
    check "default: the same capability sets and confirm as the client before (default-{before,after}.caps)" \
        'diff "$OUT/default-before.caps" "$OUT/default-after.caps" > "$OUT/default.diff"' \
        "$(wc -l < "$OUT/default.diff" 2> /dev/null) lines differ"
else
    echo "INFO  no /before.tar.xz: the default is checked against the rules above only"
fi

# 2. HEVC asked for, AV2 and AV1 off, H.264 not asked for
session after hevc /gfx:AV2:off,AV1:off,HEVC:i420
n=$(frames hevc HEVC420)
check "hevc: the client offers HEVC (an 11.x set with HEVC_ENABLE) with H.264 off (AVC_DISABLED)" \
    'grep -E "Sending RDPGFX_CAPVERSION_11[0-9]+ .*flags=.*HEVC_ENABLE" "$OUT/hevc.wlog" | grep -q AVC_DISABLED'
check "hevc: the sender confirms an 11.x set with HEVC_ENABLE" \
    'grep -qE "RecvCapsConfirmPdu: version: RDPGFX_CAPVERSION_11[0-9]+ .*HEVC_ENABLE" "$OUT/hevc.wlog"' \
    "$(grep -oE 'RecvCapsConfirmPdu: version: RDPGFX_CAPVERSION_[0-9A-Z_]+' "$OUT/hevc.wlog" | head -1)"
check "hevc: at least 30 frames in HEVC 4:2:0, none in AVC" \
    '[ "${n:-0}" -ge 30 ] && [ "$(frames hevc AVC420)$(frames hevc AVC444)$(frames hevc AVC444v2)" = 000 ]' "$(codecs hevc)"
check "hevc: no frame failed to decode" \
    '! grep -qE "freerdp_hevc_decompress failure|rdpgfx_decode failed|no HEVC .* decoder available" "$OUT/hevc.wlog"' \
    "$(grep -cE 'decompress failure|decode failed' "$OUT/hevc.wlog" 2> /dev/null) failures"
check "hevc: the client decodes with libavcodec, in software" \
    'grep -q "HEVC decoder: libavcodec (software)" "$OUT/hevc.wlog"'
check "hevc: the sender encodes with libx265 (GPL, the sender's only)" 'grep -q "x265 \[info\]" "$OUT/server.out"'
check "hevc: the client shows more than one colour" \
    '[ "$(convert "$OUT/hevc.png" -format "%k" info: 2> /dev/null)" -gt 1 ]'

# 3. H.264 asked for: still there
session after avc /gfx:AVC420
check "avc: frames in H.264 (AVC420 or AVC444), decoded by libavcodec" \
    '[ $(($(frames avc AVC420) + $(frames avc AVC444) + $(frames avc AVC444v2))) -ge 30 ] &&
     grep -q "H.264 decoder: libavcodec (software)" "$OUT/avc.wlog" &&
     ! grep -qE "decompress failure|rdpgfx_decode failed" "$OUT/avc.wlog"' "$(codecs avc)"

# 3b. with /avc-before.tar.xz: the same /gfx:AVC420 session with that client (e.g. FreeRDP
# before WITH_GFX_H264_DEFAULT): the same sets offered, the same confirm, the same codec ids
if [ -d /opt/avc-before ]; then
    session avc-before avc-before /gfx:AVC420
    negotiation avc > "$OUT/avc.caps"
    negotiation avc-before > "$OUT/avc-before.caps"
    echo "INFO  avc:        $(codecs avc)"
    echo "INFO  avc-before: $(codecs avc-before)"
    ids() { grep -ohE "Got GFX RDPGFX_CODECID_[A-Z0-9_]+" "$OUT/$1.wlog" 2> /dev/null | sort -u | tr '\n' ' '; }
    check "avc: the same capability sets and confirm as avc-before (avc{-before,}.caps)" \
        '[ -s "$OUT/avc.caps" ] && diff "$OUT/avc-before.caps" "$OUT/avc.caps" > "$OUT/avc.diff"' \
        "$(grep -c '^Sending' "$OUT/avc.caps" 2> /dev/null) sets offered"
    check "avc: the same codec ids as avc-before" '[ -n "$(ids avc)" ] && [ "$(ids avc)" = "$(ids avc-before)" ]' \
        "$(ids avc)| before: $(ids avc-before)"
fi

kill "$(pgrep -u tester -f freerdp-shadow-cli | head -1)" 2> /dev/null
chmod -R a+rX "$OUT"
echo "passed $pass, failed $fail"
[ $fail = 0 ]
