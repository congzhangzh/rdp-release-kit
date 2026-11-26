#!/bin/bash
# A record, not a kit test (.github/workflows/probe-web-browsers-rec.yml): one short video per
# browser (Chrome, Firefox, Safari) of FreeRDP Web in AV1 4:2:0 to the kit's macOS host, each
# ending on the page's Info at its "AV1 decoder" row (test/web-av1-i420.mjs with RECORD).
#   test/probe-web-browsers-rec.sh <host dir (holds FreeRDP-Shadow.app)> <web client dir (holds index.html)>
#                                  <demo media dir (test/demo-assets.sh's)> <out dir>
# Only the web part of test/mac-host.sh, its own lines: the server with -auth on 127.0.0.1:4490
# (WLOG_LEVEL=DEBUG, which web-av1-i420.mjs reads), websockify on 3390, the page on 8082 and the
# media page on 8000, in Firefox full-size behind every session (Safari's window takes half the
# screen over it). DEMO_KIT names the kit release in each video's overlay. Exits 1 when a
# browser's video is missing; the checks' PASS/FAIL lines are recorded, not judged.
# Bash 3.2 (macOS's own) is enough here.
set -u
HOSTDIR=$1; WEBDIR=$2; MEDIA=$3; OUT=$4
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
    SERVER_LOG="$OUT/server-web.wlog" OUT="$OUT/web-i420" CHROME="$CHROME_BIN" FIREFOX="$FIREFOX" \
        RECORD="$OUT/web-av1-i420-$b.mp4" DEMO_KIT="${DEMO_KIT:-}" env SECONDS=30 \
        node "$KIT_TEST/web-av1-i420.mjs" http://127.0.0.1:8082/index.html 127.0.0.1:3390 $b \
        > "$OUT/web-i420-$b.log" 2>&1
    echo "$b: exit $?"
    grep -E '^(PASS|FAIL|INFO|RESULT|RECORD-VERDICT) ' "$OUT/web-i420-$b.log"
    [ -s "$OUT/web-av1-i420-$b.mp4" ] || { echo "MISSING  $b: no video"; missing=$((missing + 1)); }
    grep -h '^RECORD-VERDICT ' "$OUT/web-i420-$b.log" >> "$OUT/verdicts.txt"
done
kill $MF 2> /dev/null; pkill -x firefox 2> /dev/null; kill $MH $COI $GW $SRV 2> /dev/null; sleep 1
mkdir -p "$OUT/crash"
cp "$HOME"/Library/Logs/DiagnosticReports/freerdp-shadow-cli* "$OUT/crash/" 2> /dev/null || true
rm -rf "$W"
cat "$OUT/verdicts.txt" 2> /dev/null
[ $missing = 0 ]
