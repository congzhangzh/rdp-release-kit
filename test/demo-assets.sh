#!/bin/bash
# The media the demo shows on the remote desktop, fetched once into the cache
# (never into the repository), pinned:
#
#   test/demo-assets.sh            prints the directory, ~/.cache/rdp-release-kit/demo
#
#   bunny.webm 26 seconds of Big Buck Bunny, (c) Blender Foundation, CC BY 3.0
#              (www.bigbuckbunny.org), VP9 and Opus as in Wikimedia Commons' 720p copy
#   webgl/     the WebGL Aquarium of WebGL Samples, (c) Google, BSD 3-clause
#              (github.com/WebGLSamples), only the files it needs
set -euo pipefail

DIR=${DEMO_ASSETS:-$HOME/.cache/rdp-release-kit/demo}
BBB_URL=https://upload.wikimedia.org/wikipedia/commons/transcoded/c/c0/Big_Buck_Bunny_4K.webm/Big_Buck_Bunny_4K.webm.720p.vp9.webm
BBB_SHA256=139b7ba2f424e76ba8db850812a0fa6fa3de6cad64e77e622ad84c97a0ebf07e
WEBGL_REPO=https://github.com/WebGLSamples/WebGLSamples.github.io.git
WEBGL_COMMIT=4c87dfea3cff6bf9f351c5ed4a191f86ceed8bbc
mkdir -p "$DIR"

if [ ! -s "$DIR/bunny.webm" ]; then
    if ! echo "$BBB_SHA256  $DIR/bbb-720p.webm" | sha256sum -c --quiet 2> /dev/null; then
        echo "== Big Buck Bunny (160 MB, once)" >&2
        curl -fL --retry 3 -A rdp-release-kit -o "$DIR/bbb-720p.webm.part" "$BBB_URL"
        echo "$BBB_SHA256  $DIR/bbb-720p.webm.part" | sha256sum -c --quiet
        mv "$DIR/bbb-720p.webm.part" "$DIR/bbb-720p.webm"
    fi
    # the bunny leaves his burrow and stretches, with the music; the streams as they are
    ffmpeg -v error -y -ss 58 -t 26 -i "$DIR/bbb-720p.webm" -c copy "$DIR/bunny.webm"
fi

if [ "$(git -C "$DIR/webgl" rev-parse HEAD 2> /dev/null)" != "$WEBGL_COMMIT" ]; then
    echo "== WebGL Aquarium" >&2
    rm -rf "${DIR:?}/webgl"
    git clone -q --filter=blob:none --no-checkout "$WEBGL_REPO" "$DIR/webgl"
    git -C "$DIR/webgl" sparse-checkout set --no-cone /aquarium/ '!/aquarium/source_assets/' \
        /tdl/ /jquery-ui-1.8.2.custom/ /khronos/ /LICENSE.md
    git -C "$DIR/webgl" checkout -q "$WEBGL_COMMIT"
fi
echo "$DIR"
