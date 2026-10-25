#!/bin/bash
# Builds the FreeRDP web client (SDL3, WebAssembly) and its page, inside the
# Emscripten container:
#
#   build-wasm-client.sh <kit dir> <sources dir> <output dir>
#
# Every library is built from sources.lock with -pthread (the client shares
# memory between threads) and linked statically. FreeRDP is the preview
# branch with the open Emscripten pull requests; the page is freerdp-web.
# The result is <output dir>/web/, the page ready to serve, and
# <output dir>/freerdp-web-<version>.zip.
#
# PAGE_SRC=<dir> takes the page from a local checkout instead of the pinned
# commit, while the page is being changed (not for releases); a local
# FreeRDP comes the same way, as SRC_freerdp (build/overrides.sh).
set -Eeuo pipefail

KIT=$1
SOURCES=$2
OUT=$3
WORK=/work

# shellcheck source=build/lib.sh
. "$KIT/build/lib.sh"
export CFLAGS="-pthread -O2"
export CXXFLAGS="-pthread -O2"
export LDFLAGS="-pthread"
export PKG_CONFIG_PATH=$DEPS/lib/pkgconfig
export PKG_CONFIG_LIBDIR=$DEPS/lib/pkgconfig
mkdir -p "$OUT"
# ccache wraps the clang that emcc runs, not emcc itself
if [ ${#LAUNCHER[@]} != 0 ]; then
    export EM_COMPILER_WRAPPER=ccache
    LAUNCHER=()
fi

# emcmake points CMake at Emscripten's toolchain
wasm_dep() {
    local name=$1 src
    shift
    built "$name" && return 0
    src=$(unpack "$name")
    overridden "$name" || rm -rf "${WORK:?}/build/$name"
    emcmake cmake -G Ninja -S "$src" -B "$WORK/build/$name" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$DEPS" -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_PREFIX_PATH="$DEPS" \
        -DCMAKE_FIND_ROOT_PATH="$DEPS" -DBUILD_SHARED_LIBS=OFF "$@" > "$WORK/log/$name.log" 2>&1
    cmake --build "$WORK/build/$name" >> "$WORK/log/$name.log" 2>&1
    cmake --install "$WORK/build/$name" >> "$WORK/log/$name.log" 2>&1
    stamp "$name"
}

wasm_dep zlib -DZLIB_BUILD_TESTING=OFF -DZLIB_BUILD_SHARED=OFF
wasm_dep libressl -DLIBRESSL_APPS=OFF -DLIBRESSL_TESTS=OFF
wasm_dep opus -DOPUS_BUILD_PROGRAMS=OFF -DOPUS_BUILD_TESTING=OFF -DOPUS_DISABLE_INTRINSICS=ON
wasm_dep jansson -DJANSSON_BUILD_DOCS=OFF -DJANSSON_WITHOUT_TESTS=ON -DJANSSON_EXAMPLES=OFF
wasm_dep freetype -DFT_DISABLE_ZLIB=ON -DFT_DISABLE_BZIP2=ON -DFT_DISABLE_PNG=ON \
    -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_BROTLI=ON
wasm_dep sdl3_wasm -DSDL_TEST_LIBRARY=OFF -DSDL_TESTS=OFF -DSDL_PTHREADS=ON
wasm_dep sdl3_ttf -DSDLTTF_VENDORED=OFF -DSDLTTF_HARFBUZZ=OFF -DSDLTTF_PLUTOSVG=OFF \
    -DSDLTTF_SAMPLES=OFF

# dav1d decodes AV1 where the browser's WebCodecs cannot
if ! built dav1d; then
    src=$(unpack dav1d)
    rm -rf "$WORK/build/dav1d"
    meson setup "$WORK/build/dav1d" "$src" --cross-file "$KIT/build/wasm/meson-emscripten.conf" \
        --prefix="$DEPS" --libdir=lib --buildtype=release --default-library=static \
        -Denable_asm=false -Denable_tools=false -Denable_tests=false > "$WORK/log/dav1d.log" 2>&1
    meson install -C "$WORK/build/dav1d" >> "$WORK/log/dav1d.log" 2>&1
    stamp dav1d
fi

# The client runs on the browser's main thread and yields to its event loop
# while it waits (ASYNCIFY); the page starts it with callMain() and calls
# into it with ccall, _malloc, _free and HEAPU8. MODULARIZE: the script
# defines createFreeRDP(), and each call is a new runtime (memory, threads,
# C globals), so the page reconnects with a fresh client instead of a reload
# (freerdp-web 20261024.1 and later; older pages expect the global Module)
echo "== freerdp ${VERSION[freerdp]} (preview)"
src=$(unpack freerdp)
overridden freerdp || rm -rf "$WORK/build/freerdp"
# a kept build tree configured from another source directory (the pin was
# freerdp_preview until 2026-10-25) is one CMake refuses: start it again
grep -qx "CMAKE_HOME_DIRECTORY:INTERNAL=$src" "$WORK/build/freerdp/CMakeCache.txt" 2> /dev/null ||
    rm -rf "$WORK/build/freerdp"
# a local FreeRDP keeps ThinLTO's code generation between links: a relink
# redoes only the changed modules
DEV=()
if overridden freerdp; then
    DEV=(-DCMAKE_EXE_LINKER_FLAGS_RELEASE="-Wl,--thinlto-cache-dir=$WORK/thinlto")
fi
# freerdp_link <engine's link flags>: the client linked for one way of
# suspending WebAssembly (both are link options: the objects are the same)
freerdp_link() {
configure "$WORK/build/freerdp" \
    emcmake cmake -G Ninja -S "$src" -B "$WORK/build/freerdp" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_PREFIX_PATH="$DEPS" -DCMAKE_FIND_ROOT_PATH="$DEPS" -DBUILD_SHARED_LIBS=OFF \
    -DOPENSSL_ROOT_DIR="$DEPS" -DWITH_LIBRESSL=ON \
    -DWITH_CLIENT_SDL=ON -DWITH_CLIENT_SDL3=ON -DWITH_CLIENT_SDL2=OFF \
    -DWITH_SDL_LINK_SHARED=OFF -DWITH_SDL_IMAGE_DIALOGS=OFF \
    -DWITHOUT_WINPR_3x_DEPRECATED=ON -DWITHOUT_FREERDP_3x_DEPRECATED=ON \
    -DWITH_SERVER=OFF -DWITH_SHADOW=OFF -DWITH_PROXY=OFF -DWITH_SAMPLE=OFF \
    -DWITH_PLATFORM_SERVER=OFF -DWITH_X11=OFF -DWITH_WAYLAND=OFF -DWITH_ALSA=OFF \
    -DWITH_PULSE=OFF -DWITH_OSS=OFF -DWITH_CUPS=OFF -DWITH_PCSC=OFF -DWITH_KRB5=OFF \
    -DWITH_FUSE=OFF -DWITH_SYSTEMD=OFF -DWITH_FFMPEG=OFF -DWITH_SWSCALE=OFF \
    -DWITH_DSP_FFMPEG=OFF -DWITH_OPENH264=OFF -DCHANNEL_URBDRC=OFF -DCHANNEL_RDPECAM=OFF \
    -DWITH_SIMD=OFF -DWITH_MANPAGES=OFF -DWITH_TIMEZONE_ICU=OFF -DWITH_UNICODE_BUILTIN=ON \
    -DUSE_UNWIND=OFF -DWITH_OPUS=ON -DWITH_GFX_AV1=ON -DWITH_DAV1D=ON \
    -DCMAKE_EXE_LINKER_FLAGS="-pthread $1 \
-sALLOW_MEMORY_GROWTH=1 -sINITIAL_MEMORY=134217728 -sMAXIMUM_MEMORY=1073741824 \
-sSTACK_SIZE=1048576 -sPTHREAD_POOL_SIZE=32 -sWEBSOCKET_SUBPROTOCOL=binary \
-sENVIRONMENT=web,worker -sINVOKE_RUN=0 -sEXIT_RUNTIME=1 -sFORCE_FILESYSTEM=1 \
-sMODULARIZE=1 -sEXPORT_NAME=createFreeRDP \
-sEXPORTED_RUNTIME_METHODS=callMain,FS,ENV,ccall,HEAPU8 -sEXPORTED_FUNCTIONS=_main,_malloc,_free" \
    "${DEV[@]}" >> "$WORK/log/freerdp.log" 2>&1
grep -q -e "AV1 decoder: dav1d" -e "configuration kept" "$WORK/log/freerdp.log"
cmake --build "$WORK/build/freerdp" --target sdl3-freerdp >> "$WORK/log/freerdp.log" 2>&1
}
# Asyncify, which every browser with WebAssembly runs, in dist/wasm/web; JSPI
# (smaller and faster, no Asyncify rewrite, in Chrome 137+ for now) in its
# jspi/ folder, linked from the same objects. The page picks one.
: > "$WORK/log/freerdp.log"
CLIENT_DIR=$WORK/build/freerdp/client/SDL/SDL3
mkdir -p "$WORK/client/jspi"
freerdp_link "-sJSPI"
cp "$CLIENT_DIR/sdl-freerdp.js" "$CLIENT_DIR/sdl-freerdp.wasm" "$WORK/client/jspi/"
freerdp_link "-sASYNCIFY -sASYNCIFY_STACK_SIZE=131072"
cp "$CLIENT_DIR/sdl-freerdp.js" "$CLIENT_DIR/sdl-freerdp.wasm" "$WORK/client/"
ccache_stats

# --- the page: freerdp-web's web/ plus the client
if [ -n "${PAGE_SRC:-}" ]; then
    page=$PAGE_SRC
    page_rev=${PAGE_REV:-"local checkout (not pinned)"}
else
    page=$(unpack freerdp_web)
    page_rev=${SHA[freerdp_web]}
fi
NAME=freerdp-web-${VERSION[freerdp]}${OVERRIDES:+-local}
rm -rf "$OUT/web" "$OUT/$NAME.zip"
mkdir -p "$OUT/web/licenses"
cp -r "$page/web/." "$OUT/web/"
rm -rf "$OUT/web/tests"
cp "$WORK/client/sdl-freerdp.js" "$WORK/client/sdl-freerdp.wasm" "$OUT/web/"
mkdir -p "$OUT/web/jspi"
cp "$WORK/client/jspi/sdl-freerdp.js" "$WORK/client/jspi/sdl-freerdp.wasm" "$OUT/web/jspi/"
licenses "$OUT/web/licenses" freerdp sdl3_wasm sdl3_ttf freetype libressl opus dav1d \
    zlib jansson
{
    echo "FreeRDP web client (preview), built $(date -u +%F) with $(emcc --version | head -1)"
    echo "page: freerdp-web $page_rev"
    override_manifest
    echo
    echo "sources (sources.lock):"
    for name in freerdp sdl3_wasm sdl3_ttf freetype libressl opus dav1d zlib jansson; do
        printf '  %-16s %-9s %s\n' "$name" "${VERSION[$name]}" "${SHA[$name]}"
    done
} > "$OUT/web/MANIFEST"
(cd "$OUT/web" && zip -qr "$OUT/$NAME.zip" .)
(cd "$OUT" && sha256sum "$NAME.zip" > "$NAME.zip.sha256")
echo "== done: $OUT/web ($(du -sh --apparent-size "$OUT/web" | cut -f1)), $OUT/$NAME.zip"
