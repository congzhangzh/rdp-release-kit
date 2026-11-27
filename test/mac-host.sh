#!/bin/bash
# The macOS host (FreeRDP-Shadow.app) on a GitHub macOS runner, with the kit's own macOS
# client: an AV1 session and an AV2 session against the server as its LaunchAgent starts it.
#   test/mac-host.sh <host dir (holds FreeRDP-Shadow.app)> <client dir (holds bin/sdl-freerdp)> <out dir>
#                    [<web client dir (holds index.html)> <demo media dir (test/demo-assets.sh's)>]
# With the last two, the demo video is made as on the Windows host: FreeRDP Web in headless
# Chrome (test/wasm-demo.mjs, SERVER=mac), through websockify, so the Mac's screen shows the
# desktop and Firefox playing the media page, not a client showing itself.
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
HOSTDIR=$1; CLIENTDIR=$2; OUT=$3; WEBDIR=${4:-}; MEDIA=${5:-}
KIT_TEST=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$OUT"
# absolute: wasm-demo.mjs writes its frame list with these paths, and ffmpeg's concat reads
# them relative to the list (kit run 41627099963: "Impossible to open out/web/demo-frames/out/...")
OUT=$(cd "$OUT" && pwd)
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
"$KIT_TEST/../build/cpu-line.sh" | tee -a "$OUT/system.txt"   # which AV2 kernels libavm runs here
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
    # the demo video: macOS's own screen recorder, 15 s of this session (the client showing
    # this Mac's screen); the first session only
    if [ "$name" = av1 ]; then
        ( sleep 3; screencapture -x -V 15 "$OUT/mac-host.mov" ) > "$OUT/mac-host-video.log" 2>&1 &
        REC=$!
    fi
    WLOG_FILEAPPENDER_OUTPUT_FILE_NAME="$name.wlog" "$CLIENT" /v:127.0.0.1:${PORT:-4489} /u:probe /p:probe \
        /cert:ignore /sec:tls /size:1280x720 "$@" > "$OUT/$name.out" 2>&1 &
    c=$!
    sleep 20
    screencapture -x "$OUT/$name.png" 2> /dev/null || true
    kill -0 $c 2> /dev/null && held=1 || held=0
    kill $c 2> /dev/null; sleep 2
    check "$name: the session holds 20 s" $held
    # since FreeRDP's AV2 as merged (#13925, aa9940f24) AV2 comes under the AV1 codec ID; the
    # confirmed caps version tells them apart: FRDP_2 = AV2 (kit run 42827825178 counted 0 AV2)
    id=$want
    if grep -q "RecvCapsConfirmPdu: version: RDPGFX_CAPVERSION_FRDP_2" "$OUT/$name.wlog" 2> /dev/null; then
        case $want in AV2) id=AV1 ;; AV1) id=NONE ;; esac
    fi
    n=$(grep -c "Got GFX RDPGFX_CODECID_$id\b" "$OUT/$name.wlog" 2> /dev/null || true)
    all=$(grep -ohE "Got GFX RDPGFX_CODECID_[A-Z0-9_]+|RecvCapsConfirmPdu: version: RDPGFX_CAPVERSION_[A-Z0-9_]+" \
        "$OUT/$name.wlog" 2> /dev/null | sed 's/RecvCapsConfirmPdu: version: //' | sort | uniq -c | tr '\n' ' ')
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
wait $REC 2> /dev/null || true
if [ -s "$OUT/mac-host.mov" ]; then
    check "the demo video was recorded" 1 "$(du -h "$OUT/mac-host.mov" | cut -f1)"
    if command -v ffmpeg > /dev/null; then
        ffmpeg -loglevel error -y -i "$OUT/mac-host.mov" -c:v libx264 -pix_fmt yuv420p -movflags +faststart \
            -an "$OUT/mac-host.mp4" && ffmpeg -loglevel error -y -ss 7 -i "$OUT/mac-host.mp4" -frames:v 1 "$OUT/mac-host.jpg"
    fi
else
    echo "SKIP  the demo video: screencapture -V made nothing ($(tail -1 "$OUT/mac-host-video.log" 2> /dev/null))"
fi
alive() { kill -0 $SRV 2> /dev/null; }
alive && ok=1 || ok=0
check "the host is still running after the AV1 session" $ok
# AV1 4:2:0 (AV1 profile 0): the client asks for it (/gfx:AV1:i420: FRDP_1 with
# AV1_I444_DISABLED), the server confirms 4:4:4 off and encodes I420; its encoder's own
# numbers at the end name it ("AV1 WxH I420: N frames", every other session is 4:4:4 or AV2)
if alive; then
    session av1-i420 AV1 /gfx:AV2:off,AV1:i420
    grep -q "RecvCapsConfirmPdu: version: RDPGFX_CAPVERSION_FRDP_1 .*AV1_I444_DISABLED" "$OUT/av1-i420.wlog" \
        2> /dev/null && ok=1 || ok=0
    check "av1-i420: the server confirms 4:4:4 off (AV1_I444_DISABLED)" $ok
else
    echo "SKIP  av1-i420: the host is gone"
fi
if alive; then
    # a client that offers AV2 (the kit's own, by default) gets AV2; before FreeRDP
    # 20261101.20's 8 MiB client thread stack, that crashed the host (kit run 41370598608)
    session av2 AV2
    alive && ok=1 || ok=0
    check "the host is still running after the AV2 session" $ok
else
    echo "SKIP  av2: the host is gone"
fi
# HEVC 4:2:0 in the kit's own macOS client: the host encodes it with VideoToolbox, the client
# decodes it with VideoToolbox (both WITH_GFX_AZURE). HEVC is opt-in on both sides: a server of
# its own with /gfx-hevc:i420 on 4491, and two sessions:
#  - hevc: /gfx-codec-order:HEVC,AVC420, AVC on as the fallback (what a user types);
#  - hevc-avc-off: /gfx:AV2:off,AV1:off,HEVC:i420, no AVC asked for, so the caps say
#    AVC_DISABLED (the path of a client whose H.264 is off, FreeRDP 7dca5d051); AV1 and AV2 off,
#    or the server takes them first (HEVC in /gfx: turns no other codec off)
# Each one: 11.x confirmed with HEVC_ENABLE, HEVC420 frames, no failed decode, and the client's
# log names its decoder ("HEVC decoder: VideoToolbox (hardware)", FreeRDP's h264.c)
hevc_ok=1
for b in "$SERVER" "$CLIENT"; do
    "$b" /buildconfig 2> /dev/null | tr " " "\n" | grep -qx "WITH_GFX_AZURE=ON" || hevc_ok=0
done
check "native HEVC: the host and the client are built with WITH_GFX_AZURE" $hevc_ok
if [ $hevc_ok = 1 ]; then
    WLOG_FILEAPPENDER_OUTPUT_FILE_NAME=server-hevc.wlog "$SERVER" /bind-address:127.0.0.1 /port:4491 \
        /sec:tls /gfx-av1 /gfx-av2:off -gfx-avc444 /gfx-hevc:i420 -auth > "$OUT/server-hevc.out" 2>&1 &
    HSRV=$!
    for i in $(seq 1 30); do listening 4491 && break; sleep 1; done
    listening 4491 && ok=1 || ok=0
    check "native HEVC: the server with /gfx-hevc:i420 listens" $ok
    for s in "hevc /gfx-codec-order:HEVC,AVC420" "hevc-avc-off /gfx:AV2:off,AV1:off,HEVC:i420"; do
        name=${s%% *}
        PORT=4491 session "$name" HEVC420 "${s#* }"
        log="$OUT/$name.wlog"
        grep -E "RecvCapsConfirmPdu: version: RDPGFX_CAPVERSION_11[0-9]+ .*[{|]HEVC_ENABLE[|}]" "$log" \
            2> /dev/null > /dev/null && ok=1 || ok=0
        check "$name: the server confirms 11.x with HEVC_ENABLE" $ok \
            "$(grep -m1 -oE 'RecvCapsConfirmPdu: version: .*' "$log" 2> /dev/null)"
        if [ "$name" = hevc-avc-off ]; then
            grep -qE "RecvCapsConfirmPdu: version: .*[{|]AVC_DISABLED[|}]" "$log" 2> /dev/null && ok=1 || ok=0
            check "$name: AVC_DISABLED in the confirm" $ok
        fi
        n=$(grep -cE "VideoToolbox HEVC decode failed|VideoToolbox HEVC decoder requires a key picture" "$log" 2> /dev/null || true)
        [ "${n:-0}" = 0 ] && ok=1 || ok=0
        check "$name: no failed HEVC decode" $ok "${n:-0} failed"
        dec=$(grep -m1 -oE "HEVC decoder: [^ ]+ \([a-z]+\)" "$log" 2> /dev/null)
        case "$dec" in "HEVC decoder: VideoToolbox ("*) ok=1 ;; *) ok=0 ;; esac
        check "$name: the client names its decoder" $ok "${dec:-no decoder line}"
    done
    grep -ohE "VideoToolbox HEVC encoder: [0-9]+x[0-9]+.*" "$OUT/server-hevc.wlog" 2> /dev/null | grep -v ": 256x256 " | tail -2
    kill $HSRV 2> /dev/null; sleep 2
fi
# the demo video, the Windows host's way (test/windows-host.ps1): FreeRDP Web in headless
# Chrome, which no screen shows, to a server of its own with AV1 only (the page takes AV2
# when offered: libavm, about a frame a second here)
FIREFOX=/Applications/Firefox.app/Contents/MacOS/firefox
CHROME_BIN="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
if [ -z "$WEBDIR" ] || [ ! -f "$WEBDIR/index.html" ]; then
    echo "SKIP  the web demo: no web client given"
elif [ ! -x "$FIREFOX" ] || [ ! -x "$CHROME_BIN" ] || ! command -v ffmpeg > /dev/null || [ ! -s "$MEDIA/bunny.webm" ]; then
    echo "SKIP  the web demo: needs Firefox, Chrome, ffmpeg and the media ($(ls -d "$FIREFOX" "$CHROME_BIN" 2>&1 | tr '\n' ' '))"
else
    kill $SRV 2> /dev/null; sleep 2
    # a bigger screen first, before the server reads it (test/mac/display-mode.swift): the
    # largest mode up to 1600 wide, if the runner's display has one
    swift "$KIT_TEST/mac/display-mode.swift" 1600 > "$OUT/web-display.txt" 2>&1 || true
    tail -n 2 "$OUT/web-display.txt"
    size=$(awk '/^now / { print $2 }' "$OUT/web-display.txt"); SW=${size%x*}; SH=${size#*x}
    case "$SW$SH" in *[!0-9]* | "") SW=1024; SH=768 ;; esac
    WLOG_FILEAPPENDER_OUTPUT_FILE_NAME=server-web.wlog "$SERVER" /bind-address:127.0.0.1 /port:4490 \
        /sec:tls /gfx-av1 /gfx-av2:off -gfx-avc444 -auth > "$OUT/server-web.out" 2>&1 &
    SRV=$!
    W=$(mktemp -d); mkdir -p "$OUT/web" "$W/site" "$W/ff"
    python3 -m venv "$W/venv" && "$W/venv/bin/pip" install --quiet websockify > "$OUT/web/pip.log" 2>&1
    "$W/venv/bin/websockify" 127.0.0.1:3390 127.0.0.1:4490 > "$OUT/web/websockify.log" 2>&1 &
    GW=$!
    python3 "$KIT_TEST/coi-http.py" 8082 "$WEBDIR" > "$OUT/web/coi-http.log" 2>&1 &
    COI=$!
    # the media page, served from this Mac's 127.0.0.1 (as webdemo does on the Linux servers)
    cp "$KIT_TEST/demo/media.html" "$W/site/index.html"
    ln -s "$MEDIA/bunny.webm" "$W/site/bunny.webm"; ln -s "$MEDIA/webgl" "$W/site/webgl"
    cp "$KIT_TEST/demo/user.js" "$W/ff/"
    # Firefox's first start on this Mac, out of the video: macOS checks a new app on its first
    # launch, and the profile is made (kit run 41630233301: the window came ~20 s late)
    "$FIREFOX" --headless -no-remote -profile "$W/ff" about:blank > "$OUT/web/firefox-warm.log" 2>&1 &
    FW=$!; sleep 15; kill $FW 2> /dev/null; sleep 2; pkill -x firefox 2> /dev/null
    python3 -m http.server 8000 --bind 127.0.0.1 --directory "$W/site" > "$OUT/web/media-http.log" 2>&1 &
    MH=$!
    for i in $(seq 1 30); do listening 4490 && listening 3390 && listening 8082 && listening 8000 && break; sleep 1; done
    listening 4490 && listening 3390 && listening 8082 && listening 8000 && ok=1 || ok=0
    check "web demo: the server, websockify and the pages are up" $ok
    # ScreenCaptureKit sends only what changes: once the page is connected, an app opens and
    # closes, so the first picture comes before Firefox does
    ( for i in $(seq 1 180); do lsof -nP -iTCP:4490 -sTCP:ESTABLISHED > /dev/null 2>&1 && break; sleep 1; done
      sleep 1; open -a Calculator; sleep 6; osascript -e 'quit app "Calculator"' ) > /dev/null 2>&1 &
    MOT=$!
    SERVER=mac CHROME="$CHROME_BIN" \
    DEMO_WEBDEMO_CMD="'$FIREFOX' -no-remote -profile '$W/ff' -width $((SW - 24)) -height $((SH - 120)) http://127.0.0.1:8000/ > '$OUT/web/firefox.log' 2>&1 &" \
        node "$KIT_TEST/wasm-demo.mjs" http://127.0.0.1:8082/index.html 127.0.0.1:3390 probe probe \
        "$OUT/web" "$OUT/web/raw.mp4" > "$OUT/web/driver.log" 2>&1
    echo "web demo driver: exit $?"; tail -n 8 "$OUT/web/driver.log"
    pkill -x firefox 2> /dev/null; kill $MOT $MH 2> /dev/null
    # AV1 4:2:0 in each browser (backlog row C): Safari itself (safaridriver), Chrome and Firefox
    # (their WebDriver, headless), one session each to this server; the server's own log proves
    # 4:4:4 off and I420 per session, the page names its decoder (WebCodecs or dav1d)
    sudo -n safaridriver --enable > "$OUT/web/safaridriver-enable.log" 2>&1 ||
        echo "INFO  safaridriver --enable: $(tail -1 "$OUT/web/safaridriver-enable.log")"
    for b in chrome firefox safari; do
        SERVER_LOG="$OUT/server-web.wlog" OUT="$OUT/web-i420" CHROME="$CHROME_BIN" FIREFOX="$FIREFOX" \
            node "$KIT_TEST/web-av1-i420.mjs" http://127.0.0.1:8082/index.html 127.0.0.1:3390 $b \
            > "$OUT/web-i420-$b.log" 2>&1 && ok=1 || ok=0
        # a run that made no check proves nothing, whatever its exit code
        grep -qE '^(PASS|FAIL) ' "$OUT/web-i420-$b.log" || ok=0
        grep -E '^(PASS|FAIL|INFO|RESULT) ' "$OUT/web-i420-$b.log"
        check "web AV1 4:2:0 in $b: $(grep -m1 '^RESULT ' "$OUT/web-i420-$b.log" | cut -d: -f2- | sed 's/^ //')" $ok \
            "$(grep -c '^PASS ' "$OUT/web-i420-$b.log") of $(grep -cE '^(PASS|FAIL) ' "$OUT/web-i420-$b.log") checks"
    done
    # HEVC 4:2:0 in FreeRDP Web: the host encodes it with VideoToolbox (WITH_GFX_AZURE), the page
    # decodes it through WebCodecs. A server of its own with /gfx-hevc:i420 (HEVC is opt-in), on the
    # same port behind the same websockify; the page asks as a user does, in Extra options
    # (/gfx-codec-order:HEVC,AVC420, test/web-hevc.mjs). Safari is the check (WebCodecs HEVC through
    # VideoToolbox); Chrome is only recorded, whether this runner's Chrome decodes HEVC or not.
    kill $SRV 2> /dev/null; sleep 2
    "$SERVER" /buildconfig 2> /dev/null | tr " " "\n" | grep -qx "WITH_GFX_AZURE=ON" && ok=1 || ok=0
    check "web HEVC: the host is built with WITH_GFX_AZURE" $ok
    WLOG_FILEAPPENDER_OUTPUT_FILE_NAME=server-web-hevc.wlog "$SERVER" /bind-address:127.0.0.1 /port:4490 \
        /sec:tls /gfx-av1 /gfx-av2:off -gfx-avc444 /gfx-hevc:i420 -auth > "$OUT/server-web-hevc.out" 2>&1 &
    SRV=$!
    for i in $(seq 1 30); do listening 4490 && break; sleep 1; done
    listening 4490 && ok=1 || ok=0
    check "web HEVC: the server with /gfx-hevc:i420 listens" $ok
    for b in safari chrome; do
        SERVER_LOG="$OUT/server-web-hevc.wlog" OUT="$OUT/web-hevc" CHROME="$CHROME_BIN" \
            node "$KIT_TEST/web-hevc.mjs" http://127.0.0.1:8082/index.html 127.0.0.1:3390 $b \
            > "$OUT/web-hevc-$b.log" 2>&1 && ok=1 || ok=0
        # a run that made no check proves nothing, whatever its exit code
        grep -qE '^(PASS|FAIL) ' "$OUT/web-hevc-$b.log" || ok=0
        grep -E '^(PASS|FAIL|INFO|RESULT) ' "$OUT/web-hevc-$b.log"
        result=$(grep -m1 '^RESULT ' "$OUT/web-hevc-$b.log" | cut -d: -f2- | sed 's/^ //')
        if [ $b = safari ]; then
            check "web HEVC 4:2:0 in safari: ${result:-no result}" $ok \
                "$(grep -c '^PASS ' "$OUT/web-hevc-$b.log") of $(grep -cE '^(PASS|FAIL) ' "$OUT/web-hevc-$b.log") checks"
        else
            echo "INFO  web HEVC 4:2:0 in $b (a record, not a check): $([ $ok = 1 ] && echo passed || echo failed): ${result:-no result}"
        fi
    done
    pkill -x firefox 2> /dev/null; kill $COI $GW 2> /dev/null
    if [ -s "$OUT/web/raw.mp4" ]; then
        # as the site's other videos (test/record-demos.sh): 720p, H.264 CRF 28, AAC 96 kbit/s,
        # a poster from 70 %
        len=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT/web/raw.mp4")
        ffmpeg -v error -y -i "$OUT/web/raw.mp4" -vf "scale=1280:720:flags=lanczos,format=yuv420p" -c:v libx264 \
            -crf 28 -preset slow -c:a aac -b:a 96k -movflags +faststart "$OUT/mac-host-web.mp4"
        ffmpeg -v error -y -ss "$(echo "$len * 0.7" | bc)" -i "$OUT/web/raw.mp4" -frames:v 1 \
            -vf "scale=1280:720:flags=lanczos" -q:v 4 "$OUT/mac-host-web.jpg"
        rm -f "$OUT/web/raw.mp4"
    fi
    [ -s "$OUT/mac-host-web.mp4" ] && [ -s "$OUT/mac-host-web.jpg" ] && ok=1 || ok=0
    check "web demo: a video of FreeRDP Web on this Mac" $ok "$(du -h "$OUT/mac-host-web.mp4" 2> /dev/null | cut -f1)"
    # what the server encoded for the page (its 5-second AV1 statistics lines); the page's Info
    # panel said "0 total" in kit run 41627099963 while the picture came, so it is only noted
    n=$(grep -ohE "AV1 [0-9]+x[0-9]+ I4[24][04]: [0-9]+ frames" "$OUT/server-web.wlog" 2> /dev/null |
        awk '{ s += $4 } END { print s + 0 }')
    [ "$n" -ge 30 ] && ok=1 || ok=0
    check "web demo: the server sent the page AV1" $ok "$n frames encoded"
    grep -E "Video codecs|AV1 frames" "$OUT/web/driver.log" > "$OUT/web/info-at-end.txt" 2> /dev/null || true
    rm -rf "$W"
fi
# macOS's own crash reports of the server, if any
mkdir -p "$OUT/crash"
cp "$HOME"/Library/Logs/DiagnosticReports/freerdp-shadow-cli* "$OUT/crash/" 2> /dev/null || true
ls "$OUT/crash"

kill $SRV 2> /dev/null; sleep 1
grep -ohE "AV[12] [0-9]+x[0-9]+ (I420|I444): [0-9]+ frames in .*" "$OUT/server.wlog" > "$OUT/encoder-stats.txt" 2> /dev/null || true
cat "$OUT/encoder-stats.txt"
grep -qE "^AV1 [0-9]+x[0-9]+ I420: [0-9]+ frames" "$OUT/encoder-stats.txt" && ok=1 || ok=0
check "av1-i420: the server encodes AV1 4:2:0 (its log: AV1 WxH I420)" $ok \
    "$(grep -E '^AV1 [0-9]+x[0-9]+ I420' "$OUT/encoder-stats.txt" | tail -1 | cut -d, -f1)"
echo "$fails failed"
[ $fails = 0 ]
