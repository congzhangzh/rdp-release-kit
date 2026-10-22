#!/bin/bash
# Records the demo videos of a kit commit with what it published: its web
# client (web-* pre-release), its xrdp preview (xrdp-preview-*) and the newest
# pipewire-module-xrdp-*, each checked against its SHA256SUMS; then encodes
# each video at 720p with a poster, and writes demo.json (titles, captions
# naming those pre-releases) and SHA256SUMS:
#
#   test/record-demos.sh [server ...]   default: xrdp gnome xrdp-gnome xrdp-kde
#
# Out: dist/demo/ (OUT=<dir> for another). KIT_COMMIT=<sha> records another
# commit than HEAD; KIT_COMMIT=newest takes the newest pre-release of each
# kind (to work on the recordings from a commit that published none). The servers are wasm-session.sh's (SERVER=); xrdp-kde
# needs /dev/udmabuf (see there), PODMAN=<command> another podman. freerdp-web
# shows the videos in its splash: the demo workflow publishes them as a
# demo-* pre-release (docs/RELEASE.md).
set -euo pipefail
KIT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$KIT/dist/demo}
REPO=congzhangzh/rdp-release-kit
COMMIT=${KIT_COMMIT:-$(git -C "$KIT" rev-parse HEAD)}
SERVERS=("$@")
[ ${#SERVERS[@]} -gt 0 ] || SERVERS=(xrdp gnome xrdp-gnome xrdp-kde)
IN=$OUT/in
rm -rf "$OUT"
mkdir -p "$IN"

# the pre-release of a family this commit published, by its title's
# "(kit <commit, 12>)"; the newest of a family when the title names no commit
releases=$(gh api --paginate "repos/$REPO/releases?per_page=100" \
    -q '.[] | select(.draft | not) | [.published_at, .tag_name, .name] | @tsv' | sort -r)
of_commit() {
    [ "$COMMIT" != newest ] || { newest "$1"; return; }
    awk -F'\t' -v k="$1-" -v c="(kit ${COMMIT:0:12})" \
        'index($2, k) == 1 && substr($3, length($3) - length(c) + 1) == c { print $2; exit }' <<< "$releases"
}
newest() { awk -F'\t' -v k="$1-" 'index($2, k) == 1 { print $2; exit }' <<< "$releases"; }
# download <tag> <dir> <pattern>...: the files and SHA256SUMS, checked
download() {
    local tag=$1 dir=$2 args=()
    shift 2
    for p in "$@"; do args+=(-p "$p"); done
    mkdir -p "$dir"
    gh release download "$tag" -R "$REPO" -D "$dir" -p SHA256SUMS "${args[@]}"
    (cd "$dir" && sha256sum -c --ignore-missing --quiet SHA256SUMS) ||
        { echo "record-demos.sh: $tag: a file does not match its SHA256SUMS" >&2; exit 1; }
}

WEB=$(of_commit web) PREVIEW=$(of_commit xrdp-preview) PIPEWIRE=$(newest pipewire-module-xrdp)
[ -n "$WEB" ] && [ -n "$PREVIEW" ] ||
    { echo "record-demos.sh: kit ${COMMIT:0:12} published no web-* or xrdp-preview-* pre-release" >&2; exit 1; }
echo "== inputs: $WEB, $PREVIEW, ${PIPEWIRE:-no pipewire-module-xrdp}"
download "$WEB" "$IN/web" freerdp-web-page.zip '*.deb'
mkdir -p "$IN/client"
(cd "$IN/client" && python3 -m zipfile -e "$IN/web/freerdp-web-page.zip" .)
mkdir -p "$IN/xrdp" && mv "$IN"/web/*.deb "$IN/xrdp/"
download "$PREVIEW" "$IN/preview" '*fc45*'
[ -z "$PIPEWIRE" ] || { download "$PIPEWIRE" "$IN/pw" '*fc45*'; cp "$IN"/pw/*.rpm "$IN/preview/"; }
# the gateway script of the page this client was built with
page=$(sed -n 's/^page: freerdp-web //p' "$IN/client/MANIFEST")
curl -fsSL -o "$IN/rdp-gateway.sh" "https://raw.githubusercontent.com/congzhangzh/freerdp-web/$page/rdp-gateway.sh"
chmod +x "$IN/rdp-gateway.sh"

title() {
    case $1 in
        xrdp) echo "xrdp + Xfce" ;;
        gnome) echo "gnome-remote-desktop + GNOME Wayland" ;;
        xrdp-gnome) echo "xrdp preview + GNOME Wayland, AV1" ;;
        xrdp-kde) echo "xrdp preview + KDE Plasma Wayland, AV1" ;;
    esac
}
caption() {
    local credits="Big Buck Bunny © Blender Foundation, CC BY 3.0; WebGL Aquarium © Google, BSD."
    case $1 in
        xrdp) echo "xrdp with Xfce on Debian 13, reached over SSH and websockify: the page, a session, typing, then Firefox on the server with web video and WebGL, with sound. $credits" ;;
        gnome) echo "gnome-remote-desktop with GNOME Shell on Wayland, headless, on Debian 13: the same visit, with GNOME Console started from the search. $credits" ;;
        xrdp-gnome) echo "The xrdp preview with GNOME on Wayland, Fedora 45: sesman starts a GNOME session and xrdp sends it in AV1, decoded by the browser. The same visit, the terminal started from the search, then Firefox on the server with web video and WebGL, with sound. $credits" ;;
        xrdp-kde) echo "The xrdp preview with KDE Plasma on Wayland (KWin 6.8, Arch): sesman starts Plasma, KWin renders in software (no GPU) and xrdp sends it in AV1, decoded by the browser. The same visit, Konsole started from the launcher, then Firefox on the server with web video and WebGL, with sound. $credits" ;;
    esac
}

# the test's logs (the server's, the gateway's, the page's), with the demo
keep_logs() {
    local f
    for f in server gateway page; do
        [ ! -f "$KIT/dist/test/wasm/$f.log" ] || cp "$KIT/dist/test/wasm/$f.log" "$OUT/$1-$f.log"
    done
}

# record <server> <video> <packages>: the session, then its sound. The last
# 30 s show the web video, so they must be heard: a peak above -50 dB (a
# healthy recording peaks near -11 dB, silence is -91)
record() {
    local peak
    SERVER=$1 DEMO_VIDEO=$2 "$KIT/test/wasm-session.sh" "$IN/client" "$IN/rdp-gateway.sh" "$3" \
        > "$OUT/$1.log" 2>&1 || return 1
    peak=$(ffmpeg -hide_banner -sseof -30 -i "$2" -map 0:a -af volumedetect -f null - 2>&1 |
        sed -n 's/.*max_volume: \(-*[0-9.]*\) dB/\1/p')
    if ! awk -v p="${peak:--91}" 'BEGIN { exit !(p > -50) }'; then
        echo "FAIL  the web video is heard (its last 30 s peak at ${peak:-no sound} dB)" >> "$OUT/$1.log"
        return 1
    fi
    echo "PASS  the web video is heard (peak $peak dB)" >> "$OUT/$1.log"
}

status=0
for server in "${SERVERS[@]}"; do
    echo "== demo: $server"
    raw=$OUT/raw-$server.mp4
    pkgs=$IN/preview
    [ "$server" = xrdp ] && pkgs=$IN/xrdp
    # a demo is a recording, not a test of xrdp: one more try when the
    # machine's timing gets in the way (a CI runner now and then)
    if ! record "$server" "$raw" "$pkgs" && ! { mv "$OUT/$server.log" "$OUT/$server-try1.log"
            echo "== $server: a second try"; record "$server" "$raw" "$pkgs"; }; then
        grep -v -E '^\[|systemd|^ *$' "$OUT/$server.log" | tail -30
        keep_logs "$server"
        echo "FAIL  the $server demo"
        status=1
        continue
    fi
    grep -E '^(PASS|demo:)' "$OUT/$server.log"
    keep_logs "$server"
    # as the site's videos: 720p, H.264 CRF 28, AAC 96 kbit/s, a poster from 70 %
    ffmpeg -v error -y -i "$raw" -vf "scale=1280:720:flags=lanczos,format=yuv420p" -c:v libx264 -crf 28 \
        -preset slow -profile:v high -c:a aac -b:a 96k -movflags +faststart "$OUT/demo-$server.mp4"
    len=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$raw")
    ffmpeg -v error -y -ss "$(awk -v d="$len" 'BEGIN { printf "%.1f", d * 0.7 }')" -i "$raw" -frames:v 1 \
        -vf scale=1280:720:flags=lanczos -q:v 4 "$OUT/demo-$server.jpg"
    rm -f "$raw"
done

# demo.json, as freerdp-web's splash reads it: the recorded servers, in the
# splash's order, with what they were recorded with
for server in xrdp-gnome xrdp-kde xrdp gnome; do
    if [ -f "$OUT/demo-$server.mp4" ]; then
        printf '%s\t%s\t%s\n' "$server" "$(title "$server")" "$(caption "$server")"
    fi
done > "$OUT/videos.tsv"
python3 - "$OUT" "$COMMIT" "$WEB" "$PREVIEW" "${PIPEWIRE:-}" << 'EOF'
import json, sys
out, commit, web, preview, pw = sys.argv[1:6]
videos = []
for line in open(f"{out}/videos.tsv", encoding="utf-8"):
    server, title, caption = line.rstrip("\n").split("\t")
    videos.append({"title": title, "src": f"demo/demo-{server}.mp4",
                   "poster": f"demo/demo-{server}.jpg", "caption": caption})
recorded = {"kit": commit, "web": web, "xrdp-preview": preview}
if pw:
    recorded["pipewire-module-xrdp"] = pw
with open(f"{out}/demo.json", "w", encoding="utf-8") as f:
    json.dump({"recorded": recorded, "videos": videos}, f, indent=2, ensure_ascii=False)
EOF
rm -f "$OUT/videos.tsv"
rm -rf "$IN"
(cd "$OUT" && sha256sum -- demo.json demo-*.mp4 demo-*.jpg > SHA256SUMS && cat SHA256SUMS)
exit $status
