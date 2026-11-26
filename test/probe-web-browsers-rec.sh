#!/bin/bash
# A record, not a kit test (.github/workflows/probe-web-browsers-rec.yml): one short video per
# browser (Chrome, Firefox, Safari) of FreeRDP Web in AV1 4:2:0 to the kit's macOS host, each
# ending on the page's Info at its "AV1 decoder" row (test/web-av1-i420.mjs with RECORD).
#   test/probe-web-browsers-rec.sh <host dir (holds FreeRDP-Shadow.app)> <web client dir (holds index.html)>
#                                  <demo media dir (test/demo-assets.sh's)> <out dir>
#                                  [<native client dir (holds bin/sdl-freerdp)>]
# Only the web part of test/mac-host.sh, its own lines: the server with -auth on 127.0.0.1:4490
# (WLOG_LEVEL=DEBUG, which web-av1-i420.mjs reads), websockify on 3390, the page on 8082 and the
# media page on 8000, in Firefox full-size behind every session (each browser, windowed, takes
# half the screen over it; macOS's screencapture records the screen). DEMO_KIT names the kit
# release in each video's overlay. With a native client dir, then the kit's own macOS client
# (demo 1.3's probe) the same way: a half-size window over the media page, its own log, the
# server's encoder rate (NATIVE-VERDICT); no overlay in a native window, the facts are printed.
# Exits 1 when a video is missing; the checks' PASS/FAIL lines are recorded, not judged.
# Bash 3.2 (macOS's own) is enough here.
set -u
HOSTDIR=$1; WEBDIR=$2; MEDIA=$3; OUT=$4; CLIENTDIR=${5:-}
KIT_TEST=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
SERVER="$HOSTDIR/FreeRDP-Shadow.app/Contents/MacOS/freerdp-shadow-cli"
FIREFOX=/Applications/Firefox.app/Contents/MacOS/firefox
CHROME_BIN="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
listening() { nc -z 127.0.0.1 "$1" 2> /dev/null; }

{ sw_vers; uname -m; } > "$OUT/system.txt" 2>&1
[ -x "$SERVER" ] && [ -f "$WEBDIR/index.html" ] && [ -s "$MEDIA/bunny.webm" ] && [ -x "$FIREFOX" ] && [ -x "$CHROME_BIN" ] &&
    command -v ffmpeg > /dev/null || { echo "needs the host, the web client, the media, Firefox, Chrome and ffmpeg" >&2; exit 1; }
# a bigger screen first, before the server reads it (as mac-host.sh)
swift "$KIT_TEST/mac/display-mode.swift" 1600 > "$OUT/web-display.txt" 2>&1 || true
tail -n 2 "$OUT/web-display.txt"
size=$(awk '/^now / { print $2 }' "$OUT/web-display.txt"); SW=${size%x*}; SH=${size#*x}
case "$SW$SH" in *[!0-9]* | "") SW=1024; SH=768 ;; esac
export WLOG_LEVEL=DEBUG WLOG_APPENDER=FILE WLOG_FILEAPPENDER_OUTPUT_FILE_PATH="$OUT"
WLOG_FILEAPPENDER_OUTPUT_FILE_NAME=server-web.wlog "$SERVER" /bind-address:127.0.0.1 /port:4490 \
    /sec:tls /gfx-av1 /gfx-av2:off -gfx-avc444 -auth > "$OUT/server-web.out" 2>&1 &
SRV=$!
W=$(mktemp -d); mkdir -p "$OUT/web" "$W/site" "$W/ff"
python3 -m venv "$W/venv" && "$W/venv/bin/pip" install --quiet websockify > "$OUT/web/pip.log" 2>&1
"$W/venv/bin/websockify" 127.0.0.1:3390 127.0.0.1:4490 > "$OUT/web/websockify.log" 2>&1 &
GW=$!
python3 "$KIT_TEST/coi-http.py" 8082 "$WEBDIR" > "$OUT/web/coi-http.log" 2>&1 &
COI=$!
cp "$KIT_TEST/demo/media.html" "$W/site/index.html"
ln -s "$MEDIA/bunny.webm" "$W/site/bunny.webm"; ln -s "$MEDIA/webgl" "$W/site/webgl"
cp "$KIT_TEST/demo/user.js" "$W/ff/"
# Firefox's first start on this Mac, out of the videos (macOS checks a new app on its first launch)
"$FIREFOX" --headless -no-remote -profile "$W/ff" about:blank > "$OUT/web/firefox-warm.log" 2>&1 &
FW=$!; sleep 15; kill $FW 2> /dev/null; sleep 2; pkill -x firefox 2> /dev/null
python3 -m http.server 8000 --bind 127.0.0.1 --directory "$W/site" > "$OUT/web/media-http.log" 2>&1 &
MH=$!
for i in $(seq 1 30); do listening 4490 && listening 3390 && listening 8082 && listening 8000 && break; sleep 1; done
listening 4490 && listening 3390 && listening 8082 && listening 8000 &&
    echo "INFO  the server, websockify and the pages are up" || echo "INFO  not all up: 4490 3390 8082 8000"
# the media page behind every session, full-size, as mac-host.sh opens it for the web demo
"$FIREFOX" -no-remote -profile "$W/ff" -width $((SW - 24)) -height $((SH - 120)) http://127.0.0.1:8000/ \
    > "$OUT/web/firefox.log" 2>&1 &
MF=$!
sleep 10
sudo -n safaridriver --enable > "$OUT/web/safaridriver-enable.log" 2>&1 ||
    echo "INFO  safaridriver --enable: $(tail -1 "$OUT/web/safaridriver-enable.log")"
missing=0
for b in chrome firefox safari; do
    # nothing over the media page but the browser: the runner's System Settings ("Software Update
    # Available", probe v1's Firefox frames) and any Calculator closed; no motion step
    osascript -e 'quit app "System Settings"' > /dev/null 2>&1 || true
    osascript -e 'quit app "Calculator"' > /dev/null 2>&1 || true
    SERVER_LOG="$OUT/server-web.wlog" OUT="$OUT/web-i420" CHROME="$CHROME_BIN" FIREFOX="$FIREFOX" \
        RECORD="$OUT/web-av1-i420-$b.mp4" DEMO_KIT="${DEMO_KIT:-}" env SECONDS=30 \
        node "$KIT_TEST/web-av1-i420.mjs" http://127.0.0.1:8082/index.html 127.0.0.1:3390 $b \
        > "$OUT/web-i420-$b.log" 2>&1
    echo "$b: exit $?"
    grep -E '^(PASS|FAIL|INFO|RESULT|RECORD-VERDICT) ' "$OUT/web-i420-$b.log"
    [ -s "$OUT/web-av1-i420-$b.mp4" ] || { echo "MISSING  $b: no video"; missing=$((missing + 1)); }
    grep -h '^RECORD-VERDICT ' "$OUT/web-i420-$b.log" >> "$OUT/verdicts.txt"
done
# the kit's native macOS client to the same server, over the same media page (demo 1.3's probe):
# mac-host.sh's session() options with AV1 4:2:0, a half-size window, screencapture once connected
CLIENT="$CLIENTDIR/bin/sdl-freerdp"
if [ -n "$CLIENTDIR" ] && [ -x "$CLIENT" ]; then
    osascript -e 'quit app "System Settings"' > /dev/null 2>&1 || true
    osascript -e 'quit app "Calculator"' > /dev/null 2>&1 || true
    off=$(wc -c < "$OUT/server-web.wlog" | tr -d ' ')
    # WLOG_LEVEL=DEBUG and the file appender are exported above: the client's log is native.wlog
    WLOG_FILEAPPENDER_OUTPUT_FILE_NAME=native.wlog "$CLIENT" /v:127.0.0.1:4490 /u:probe /p:probe \
        /cert:ignore /sec:tls /size:800x450 /gfx:AV2:off,AV1:i420 > "$OUT/native.out" 2>&1 &
    NC=$!
    for i in $(seq 1 45); do lsof -nP -a -p $NC -iTCP:4490 -sTCP:ESTABLISHED > /dev/null 2>&1 && break; sleep 1; done
    sleep 3   # the first picture, and the window in place
    # the client's window, in screen points (needs System Events, i.e. Accessibility, for osascript)
    rect=""
    for i in 1 2 3 4 5; do
        rect=$(osascript -e "tell application \"System Events\" to tell (first process whose unix id is $NC) to get {position, size} of front window" 2> "$OUT/native-bounds.err" | tr -d ' ')
        [ -n "$rect" ] && break; sleep 1
    done
    # the screen's width in points (the desktop's bounds), for the .mov's backing scale
    pw=$(osascript -e 'tell application "Finder" to get item 3 of (get bounds of window of desktop)' 2> /dev/null || echo "$SW")
    echo "INFO  native: window ${rect:-unknown} (x,y,w,h in points; $(tail -1 "$OUT/native-bounds.err" 2> /dev/null)), screen $pw points wide"
    screencapture -x -V 35 "$W/native.mov" > "$OUT/native-video.log" 2>&1
    kill -0 $NC 2> /dev/null && held=1 || held=0
    kill $NC 2> /dev/null; sleep 2
    echo "INFO  native: the client held the 35 s: $held"
    V="$OUT/native-av1-i420.mp4"
    if [ -s "$W/native.mov" ]; then
        mw=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$W/native.mov")
        mh=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$W/native.mov")
        # points to the .mov's pixels, even values, kept inside the frame (as web-av1-i420.mjs crops)
        crop=$(echo "$rect" | awk -F, -v mw="$mw" -v mh="$mh" -v pw="$pw" 'NF == 4 && pw > 0 && mw > 0 {
            k = mw / pw
            x = 2 * int($1 * k / 2); y = 2 * int($2 * k / 2); if (x < 0) x = 0; if (y < 0) y = 0
            w = $3 * k; if (w > mw - x) w = mw - x; h = $4 * k; if (h > mh - y) h = mh - y
            w = 2 * int(w / 2); h = 2 * int(h / 2)
            if (w > 0 && h > 0) printf "crop=%d:%d:%d:%d,", w, h, x, y }')
        echo "INFO  native: the .mov ${mw}x${mh}, ${crop:-no crop}"
        ffmpeg -y -loglevel error -i "$W/native.mov" -vf "${crop}scale=1280:720:force_original_aspect_ratio=decrease:flags=lanczos,pad=1280:720:(ow-iw)/2:(oh-ih)/2,format=yuv420p" \
            -c:v libx264 -crf 28 -preset slow -an -movflags +faststart "$V"
        n=$(ffprobe -v error -select_streams v:0 -show_entries stream=nb_frames -of csv=p=0 "$V")
        len=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$V")
        echo "INFO  native: the video: $n frames in $len s ($(awk -v n="$n" -v l="$len" 'BEGIN { if (l > 0) printf "%.1f", n / l }') fps written)"
        # a poster from 70 %, a mid and a late frame
        for s in ":0.7" "-mid:0.5" "-late:0.95"; do
            ffmpeg -y -loglevel error -ss "$(awk -v l="$len" -v k="${s#*:}" 'BEGIN { printf "%.2f", l * k }')" -i "$V" \
                -frames:v 1 -q:v 4 "${V%.mp4}${s%%:*}.jpg"
        done
    fi
    [ -s "$V" ] || { echo "MISSING  native: no video ($(tail -1 "$OUT/native-video.log" 2> /dev/null))"; missing=$((missing + 1)); }
    # the session's rate: the server's AV1 encoder lines of this session ("AV1 WxH I420: N frames in
    # T s (F fps)", every few seconds, the media page playing throughout)
    tail -c +$((off + 1)) "$OUT/server-web.wlog" > "$OUT/native-server.wlog"
    grep -oE "AV1 [0-9]+x[0-9]+ I4[24][04]: [0-9]+ frames in [^,]*" "$OUT/native-server.wlog" > "$OUT/native-encoder.txt" || true
    sed 's/^/INFO  native: server /' "$OUT/native-encoder.txt"
    awk '{ f = ""; if (match($0, /\(([0-9.]+) fps\)/)) f = substr($0, RSTART + 1, RLENGTH - 6) + 0
           else if (match($0, /: [0-9]+ frames in [0-9.]+/)) { split(substr($0, RSTART + 2, RLENGTH - 2), a, " "); if (a[4] > 0) f = a[1] / a[4] }
           if (f != "") { s += f; c++ } }
         END { if (c) printf "NATIVE-VERDICT  %s/s (the server encoded a mean %.1f fps over %d lines)\n", (s / c >= 15 ? ">= 15" : "< 15"), s / c, c
               else print "NATIVE-VERDICT  unknown (no AV1 encoder line in this session: WLOG_LEVEL=DEBUG?)" }' \
        "$OUT/native-encoder.txt" | tee -a "$OUT/verdicts.txt"
    # which AV1 decoder the client used, and its decode times if it logs any
    echo "INFO  native: decoder lines:"
    grep -E "AV1 decoder|VideoToolbox|dav1d|-12906" "$OUT/native.wlog" "$OUT/native.out" 2> /dev/null | head -n 12
    echo "INFO  native: $(cat "$OUT/native.wlog" "$OUT/native.out" 2> /dev/null | grep -ic decode) lines name decode; the last ones:"
    grep -ih "decode" "$OUT/native.wlog" "$OUT/native.out" 2> /dev/null | tail -n 8
else
    echo "INFO  native: no client given (${CLIENTDIR:-none})"
fi
kill $MF 2> /dev/null; pkill -x firefox 2> /dev/null; kill $MH $COI $GW $SRV 2> /dev/null; sleep 1
mkdir -p "$OUT/crash"
cp "$HOME"/Library/Logs/DiagnosticReports/freerdp-shadow-cli* "$OUT/crash/" 2> /dev/null || true
rm -rf "$W"
cat "$OUT/verdicts.txt" 2> /dev/null
[ $missing = 0 ]
