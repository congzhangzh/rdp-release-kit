#!/bin/bash
# The Linux client's HEVC against a CI-only HEVC sender, in a throwaway container:
#
#   test/hevc-session.sh <client archive> [<client archive before> | -] [out dir]
#
# The sender (test/hevc-sender/Dockerfile) is FreeRDP's shadow server built from the
# FreeRDP pin of sources.lock against Debian's GPL FFmpeg with libx265: a test tool, never
# shipped; it lives in its image only, and nothing of it is written to the out dir or near
# the release's archives. The checks (test/hevc-sender/inside.sh): a client given no codec
# negotiates as before (and as <client archive before>, when given: the same capability sets
# and confirm), HEVC 4:2:0 on request with H.264 off, decoded by libavcodec in software with
# no failed frame, and H.264 still there on request.
#
# Logs and screenshots go to dist/test/hevc-session/ by default. ENGINE=<docker|podman>
# picks the container engine (as build.sh: docker first), RUN_OPTS=<options> adds options.
set -uo pipefail

KIT=$(cd "$(dirname "$0")/.." && pwd)
AFTER=${1:?usage: $0 <client archive> [<client archive before> | -] [out dir]}
BEFORE=${2:--}
OUT=${3:-$KIT/dist/test/hevc-session}
[ -f "$AFTER" ] || { echo "no archive: '$AFTER'" >&2; exit 2; }
[ "$BEFORE" = - ] || [ -f "$BEFORE" ] || { echo "no archive: '$BEFORE'" >&2; exit 2; }
ENGINE=${ENGINE:-$(command -v docker || command -v podman)}
read -r -a RUN_OPTS <<< "${RUN_OPTS:-}"
rm -rf "$OUT"
mkdir -p "$OUT"
OUT=$(realpath "$OUT")
IMAGE=kit-hevc-sender

# the sender's FreeRDP: the commit sources.lock pins for the clients (freerdp), so the
# encoder side is the FreeRDP the client was built from
read -r _ version url sha < <(awk '$1 == "freerdp"' "$KIT/sources.lock")
[[ $url == git+* ]] || { echo "sources.lock: freerdp is not a git pin" >&2; exit 2; }
ctx=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-$HOME/tmp}}/hevc-sender.XXXXXX")
trap 'rm -rf "$ctx"' EXIT
cp "$KIT/test/hevc-sender/Dockerfile" "$ctx/"
if ! { git -C "$ctx" init -q src &&
    git -C "$ctx/src" fetch -q --depth 1 "${url#git+}" "$sha" &&
    [ "$(git -C "$ctx/src" rev-parse FETCH_HEAD)" = "$sha" ] &&
    git -C "$ctx/src" archive --prefix=freerdp/ -o "$ctx/freerdp.tar" FETCH_HEAD; }; then
    echo "freerdp $sha: fetch failed" >&2
    exit 1
fi
rm -rf "$ctx/src"
echo "== the HEVC sender (CI only, GPL FFmpeg + libx265): freerdp $version ${sha:0:9}"
"$ENGINE" build -q -t "$IMAGE" "$ctx" > "$OUT/image-build.log" 2>&1 ||
    { tail -40 "$OUT/image-build.log"; exit 1; }

MOUNTS=(-v "$(realpath "$AFTER")":/after.tar.xz:ro -v "$OUT":/out -v "$KIT/test/hevc-sender":/t:ro)
[ "$BEFORE" = - ] || MOUNTS+=(-v "$(realpath "$BEFORE")":/before.tar.xz:ro)
if [ "$BEFORE" = - ]; then
    echo "== client $(basename "$AFTER")"
else
    echo "== client $(basename "$AFTER"), before: $(basename "$BEFORE")"
fi
"$ENGINE" run --rm "${RUN_OPTS[@]}" "${MOUNTS[@]}" "$IMAGE" bash /t/inside.sh
status=$?
echo "(logs and screenshots in $OUT)"
exit $status
