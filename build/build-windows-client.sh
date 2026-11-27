#!/bin/bash
# Cross-compiles the SDL3 FreeRDP client for Windows with llvm-mingw
# (clang, libc++, UCRT), inside a Debian container:
#
#   build-windows-client.sh <kit dir> <sources dir> <output dir> <x86_64|aarch64>
#
# HOST=1 builds the Windows host instead: FreeRDP's shadow server
# (freerdp-shadow-cli, DXGI capture, AV1 with libaom), freerdp-shadow-service,
# which runs it as SYSTEM on the console session (logon and lock screens,
# UAC, Ctrl+Alt+Del), and winpr-hash, from freerdp_host: our FreeRDP release
# with the Windows shadow work (FreeRDP#13931-#13935). The result is then
# <output dir>/freerdp-host-<version>-windows-<arch>.zip.
#
# One toolchain covers both architectures; aarch64 is native Windows on
# ARM64 (GCC's mingw-w64 has no aarch64 target). Every library is built
# from sources.lock and linked statically, together with libc++ and
# libunwind, so the client is one .exe that needs only Windows' own DLLs.
# The result is <output dir>/sdl3-freerdp-<version>-windows-<arch>.zip.
set -Eeuo pipefail

KIT=$1
SOURCES=$2
OUT=$3
ARCH=$4
WORK=/work
STAGE=$WORK/stage

# a stock image: the tools are not in it yet (build/builder.sh)
[ -n "${KIT_TOOLS:-}" ] || "$KIT/build/tools.sh" "$KIT" windows

# shellcheck source=build/lib.sh
. "$KIT/build/lib.sh"
# the compiler is behind the CMake toolchain file: name it for the stamps
TOOLCHAIN_ID="llvm-mingw ${VERSION[llvm_mingw]}"
mkdir -p "$OUT"

if ! built llvm_mingw; then
    unpack llvm_mingw > /dev/null
    stamp llvm_mingw
fi
# the toolchain files expect it at /llvm-mingw
ln -sfn "$WORK/src/llvm_mingw" /llvm-mingw
TC=$KIT/build/windows/llvm-mingw-$ARCH.cmake
CROSS=(-DCMAKE_TOOLCHAIN_FILE="$TC")
# pkg-config must see the Windows libraries only, never the container's
export PKG_CONFIG_LIBDIR=$DEPS/lib/pkgconfig
unset PKG_CONFIG_PATH

cmake_dep zlib "${CROSS[@]}" -DZLIB_BUILD_TESTING=OFF -DZLIB_BUILD_SHARED=OFF

# clang >= 23 brings its own <endian.h>: LibreSSL then skips its Windows
# fallback, so the probe is forced off. On ARM64 Windows (LLP64) LibreSSL's
# aarch64 bignum assembly assumes 64-bit BN_ULONG and breaks TLS: no asm
LIBRESSL_ARCH=()
if [ "$ARCH" = aarch64 ]; then
    LIBRESSL_ARCH=(-DCMAKE_C_FLAGS=-DOPENSSL_NO_ASM)
fi
cmake_dep libressl "${CROSS[@]}" -DLIBRESSL_TESTS=OFF -DLIBRESSL_APPS=OFF \
    -DHAVE_ENDIAN_H=OFF "${LIBRESSL_ARCH[@]}"

# Opus has no runtime NEON detection for MinGW on ARM64; AArch64 always has
# NEON, so it is used unconditionally, as autotools --disable-rtcd does
OPUS_ARCH=()
if [ "$ARCH" = aarch64 ]; then
    OPUS_ARCH=(-DOPUS_MAY_HAVE_NEON=OFF
               "-DCMAKE_C_FLAGS=-DOPUS_ARM_MAY_HAVE_NEON -DOPUS_ARM_MAY_HAVE_NEON_INTR")
fi
cmake_dep opus "${CROSS[@]}" -DOPUS_BUILD_PROGRAMS=OFF -DOPUS_BUILD_TESTING=OFF "${OPUS_ARCH[@]}"

if ! built dav1d; then
    src=$(unpack dav1d)
    rm -rf "$WORK/build/dav1d"
    meson setup "$WORK/build/dav1d" "$src" --cross-file "$KIT/build/windows/meson-$ARCH.conf" \
        --prefix="$DEPS" --libdir=lib --buildtype=release --default-library=static \
        -Denable_tools=false -Denable_tests=false > "$WORK/log/dav1d.log" 2>&1
    meson install -C "$WORK/build/dav1d" >> "$WORK/log/dav1d.log" 2>&1
    stamp dav1d
fi

cmake_dep jansson "${CROSS[@]}" -DJANSSON_BUILD_DOCS=OFF -DJANSSON_WITHOUT_TESTS=ON \
    -DJANSSON_EXAMPLES=OFF
cmake_dep freetype "${CROSS[@]}" -DFT_DISABLE_ZLIB=ON -DFT_DISABLE_BZIP2=ON -DFT_DISABLE_PNG=ON \
    -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_BROTLI=ON
cmake_dep sdl3 "${CROSS[@]}" -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF
cmake_dep sdl3_ttf "${CROSS[@]}" -DSDLTTF_VENDORED=OFF -DSDLTTF_HARFBUZZ=OFF \
    -DSDLTTF_PLUTOSVG=OFF -DSDLTTF_SAMPLES=OFF

# libavm, AV2's reference (FreeRDP#13925 decodes with it), with the AVM
# release kit's options: its two ML encoder experiments off, which also keeps
# TensorFlow Lite and what it would download out of the build
# (since 20261030.3 libavm asks an ARM64 Windows CPU what it has with mingw
# too, so the aarch64 build keeps its run-time CPU check)
cmake_dep avm "${CROSS[@]}" -DENABLE_TESTS=0 -DENABLE_EXAMPLES=0 -DENABLE_DOCS=0 -DENABLE_TOOLS=0 \
    -DCONFIG_ML_PART_SPLIT=0 -DCONFIG_DIP_EXT_PRUNING=0

# FFmpeg, for the client only: its HEVC (and H.264) decoder when Windows has no Media
# Foundation one (the HEVC Video Extensions are not installed: every CI runner, many PCs).
# LGPL 2.1 only, nothing GPL or nonfree; libavcodec with the hevc and h264 decoders and
# parsers (h264_ffmpeg.c calls av_parser_init), libavutil, and libswscale, which
# h264_ffmpeg.c includes and calls; no programs, no other component. Its SIMD assembly
# stays on (nasm on x86_64, NEON on aarch64): the configure summary of what it picked is
# printed and kept in log/ffmpeg.log. Threads: Win32 (requested, so a missing one fails).
FFMPEG_SYSLIBS=
if [ -z "${HOST:-}" ]; then
    if ! built ffmpeg; then
        src=$(unpack ffmpeg)
        rm -rf "$WORK/build/ffmpeg"
        mkdir -p "$WORK/build/ffmpeg"
        ffcc=/llvm-mingw/bin/$ARCH-w64-mingw32-clang
        [ ${#LAUNCHER[@]} = 0 ] || ffcc="ccache $ffcc"
        (cd "$WORK/build/ffmpeg" &&
            "$src/configure" --prefix="$DEPS" --libdir="$DEPS/lib" \
                --enable-cross-compile --target-os=mingw32 --arch="$ARCH" \
                --cc="$ffcc" --ar=/llvm-mingw/bin/llvm-ar --ranlib=/llvm-mingw/bin/llvm-ranlib \
                --nm=/llvm-mingw/bin/llvm-nm --strip=/llvm-mingw/bin/llvm-strip \
                --enable-static --disable-shared --disable-debug \
                --disable-gpl --disable-version3 --disable-nonfree \
                --disable-everything --disable-programs --disable-doc --disable-network \
                --disable-autodetect --enable-w32threads \
                --disable-avformat --disable-avdevice --disable-avfilter --disable-swresample \
                --enable-avcodec --enable-avutil --enable-swscale \
                --enable-decoder=hevc,h264 --enable-parser=hevc,h264) > "$WORK/log/ffmpeg.log" 2>&1
        # LGPL or nothing: configure names the licence it built for
        if ! grep -qx "License: LGPL version 2.1 or later" "$WORK/log/ffmpeg.log"; then
            echo "ffmpeg: configure did not say LGPL 2.1: $(grep '^License:' "$WORK/log/ffmpeg.log")" >&2
            exit 1
        fi
        # the SIMD it picked, on screen and in the log; none at all is a failure
        grep -E '^(ARCH|x86 assembler|[A-Z0-9 -]+ enabled|threading support) ' "$WORK/log/ffmpeg.log" || true
        case $ARCH in
            x86_64) simd=HAVE_X86ASM ;;
            aarch64) simd=HAVE_NEON ;;
        esac
        grep -q "^#define $simd 1" "$WORK/build/ffmpeg/config.h" ||
            { echo "ffmpeg: built without its SIMD assembly ($simd)" >&2; exit 1; }
        make -C "$WORK/build/ffmpeg" -j"$JOBS" >> "$WORK/log/ffmpeg.log" 2>&1
        make -C "$WORK/build/ffmpeg" install >> "$WORK/log/ffmpeg.log" 2>&1
        stamp ffmpeg
    fi
    # FreeRDP's FindFFmpeg skips pkg-config on Windows: the Windows libraries FFmpeg's own
    # need (bcrypt for libavutil's random seed, ...) come from its pkg-config files
    FFMPEG_SYSLIBS=$(pkg-config --static --libs-only-l libavcodec libswscale | tr ' ' '\n' |
        { grep -v -x -E -e '-l(avcodec|swscale|avutil)' -e '' || true; } | sort -u | tr '\n' ' ')
    echo "== ffmpeg: Windows libraries ${FFMPEG_SYSLIBS:-none}"
fi

# The host's FreeRDP and its AV1 encoder (libaom keeps its decoder: FreeRDP's
# av1.c includes aom_decoder.h whenever libaom is there; dav1d still decodes)
FREERDP=freerdp
WHAT=(-DWITH_CLIENT=ON -DWITH_CLIENT_SDL=ON -DWITH_CLIENT_SDL3=ON -DWITH_CLIENT_SDL2=OFF
      -DWITH_SERVER=OFF -DWITH_GFX_AV2=ON -DWITH_AVM=ON)
if [ -n "${HOST:-}" ]; then
    FREERDP=freerdp_host
    host_source "$FREERDP"
    cmake_dep aom "${CROSS[@]}" -DENABLE_TESTS=OFF -DENABLE_EXAMPLES=OFF -DENABLE_DOCS=OFF \
        -DENABLE_TOOLS=OFF
    # H.264 (AVC420) from Windows' own Media Foundation encoder (FreeRDP#13970), no
    # OpenH264; CMake calls it experimental. The SDL3 client built along with it
    # decodes H.264 through Media Foundation too: it is only the host test's client
    # (h264-test-client-*.exe), never shipped; the kit's Windows client keeps H.264
    # off, or it would ask Windows' own Remote Desktop for AVC444 by default
    WHAT=(-DWITH_CLIENT=ON -DWITH_CLIENT_SDL=ON -DWITH_CLIENT_SDL3=ON -DWITH_CLIENT_SDL2=OFF
          -DWITH_SERVER=ON -DWITH_SHADOW=ON -DWITH_PROXY=OFF
          -DWITH_PLATFORM_SERVER=OFF -DWITH_SHADOW_WIN_DXGI=ON -DWITH_SHADOW_WIN_SERVICE=ON
          -DWITH_AOM=ON -DWITH_AOM_INTRABC_DV_FIX=ON -DWITH_WINPR_TOOLS=ON -DWITH_GFX_AV2=ON -DWITH_AVM=ON
          -DWITH_MEDIA_FOUNDATION=ON)
    # the virtual camera: a client's camera (MS-RDPECAM) as "FreeRDP Camera" on the host
    # (Windows build 22000 and later; MJPG with Windows' own decoder, H.264 with Media
    # Foundation's), its media source freerdp-shadow-camera-source.dll in the package
    # (OFF said, not left out: a local FreeRDP's kept build tree remembers an earlier ON)
    if [ -n "${HOST_CAMERA:-}" ]; then
        WHAT+=(-DWITH_SHADOW_CAMERA=ON -DCHANNEL_RDPECAM=ON)
    else
        WHAT+=(-DWITH_SHADOW_CAMERA=OFF)
    fi
fi

# CLIENT_CAMERA=1 (CI probes only, never a release): camera redirection in the client, the
# rdpecam client channel and its Media Foundation backend (sys:mf, loaded at run time, so
# check-windows.sh still passes); the probe's test client plays a file as its camera
if [ -z "${HOST:-}" ] && [ -n "${CLIENT_CAMERA:-}" ]; then
    WHAT+=(-DCHANNEL_RDPECAM=ON -DCHANNEL_RDPECAM_CLIENT=ON)
fi

# FreeRDP: the SDL3 client only, static. Its fonts and icons are compiled
# into the .exe (a resource path would point into this container). zlib's
# static library is named explicitly: zlib 1.3.2 calls it libzs.a, which
# the FindZLIB of Debian 13's CMake (3.31) does not look for. Without the
# deprecated 3.x API, as upstream's scripts/mingw.sh: on Windows its
# freerdp_keyboard_init_ex passes DWORD* as UINT32* and does not compile
# with clang (3.32.2, and master as of the preview).
# A local FreeRDP (SRC_freerdp) keeps its build tree, so Ninja rebuilds
# only what changed; its link reuses the ThinLTO cache (clang's IPO is
# ThinLTO), or LTO=off leaves link-time optimisation out.
if overridden "$FREERDP"; then
    echo "== $FREERDP (local)"
else
    echo "== $FREERDP ${VERSION[$FREERDP]}"
fi
src=$(unpack "$FREERDP")
rm -rf "$STAGE"
overridden "$FREERDP" || rm -rf "$WORK/build/$FREERDP"
DEV=()
if overridden "$FREERDP"; then
    if [ "${LTO:-}" = off ]; then
        DEV=(-DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF)
    else
        # the kept build tree remembers an earlier LTO=off: drop it (-U)
        DEV=(-UCMAKE_INTERPROCEDURAL_OPTIMIZATION
             -DCMAKE_EXE_LINKER_FLAGS_RELEASE="-Wl,--thinlto-cache-dir=$WORK/thinlto")
    fi
fi
# The client decodes HEVC 4:2:0 with Media Foundation when Windows has the HEVC Video
# Extensions, else (and HEVC 4:4:4 always) with the LGPL FFmpeg above; AV1 stays what it
# offers first, HEVC only when asked for (/gfx-codec-order). H.264 comes with both
# decoders but stays off unless asked for (/gfx:AVC420, /gfx:AVC444): offered by default it
# would get AVC444 from Windows' own Remote Desktop (WITH_GFX_H264_DEFAULT=OFF). The host
# keeps its options. test/windows-hevc/inject.cmake adds the CI's HEVC decode test to the
# same build tree, outside "all": the client and its zip do not change with it.
EXE_LDFLAGS=-static
CODECS=(-DWITH_FFMPEG=OFF -DWITH_SWSCALE=OFF)
if [ -z "${HOST:-}" ]; then
    EXE_LDFLAGS="-static${FFMPEG_SYSLIBS:+ ${FFMPEG_SYSLIBS% }}"
    CODECS=(-DWITH_GFX_AZURE=ON -DWITH_MEDIA_FOUNDATION=ON -DWITH_FFMPEG=ON -DWITH_VIDEO_FFMPEG=ON
            -DWITH_DSP_FFMPEG=OFF -DWITH_SWSCALE=OFF -DWITH_GFX_H264_DEFAULT=OFF
            -DCMAKE_PROJECT_FreeRDP_INCLUDE="$KIT/test/windows-hevc/inject.cmake")
fi
configure "$WORK/build/$FREERDP" \
    cmake -G Ninja -S "$src" -B "$WORK/build/$FREERDP" "${CROSS[@]}" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/freerdp -DCMAKE_PREFIX_PATH="$DEPS" \
    -DCMAKE_EXE_LINKER_FLAGS="$EXE_LDFLAGS" -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF \
    -DOPENSSL_ROOT_DIR="$DEPS" -DWITH_LIBRESSL=ON -DZLIB_LIBRARY="$DEPS/lib/libzs.a" \
    "${WHAT[@]}" -DWITH_SDL_LINK_SHARED=OFF -DSDL_USE_COMPILED_RESOURCES=ON \
    -DWITH_SAMPLE=OFF "${CODECS[@]}" \
    -DWITH_OPENH264=OFF -DWITH_GFX_AV1=ON -DWITH_DAV1D=ON -DWITH_OPUS=ON -DWITH_SIMD=ON \
    -DWITH_INTERNAL_MD4=ON -DWITH_INTERNAL_RC4=ON -DCHANNEL_URBDRC=OFF -DUSE_UNWIND=OFF \
    -DWITHOUT_WINPR_3x_DEPRECATED=ON -DWITHOUT_FREERDP_3x_DEPRECATED=ON \
    -DWITH_MANPAGES=OFF "${LAUNCHER[@]}" "${DEV[@]}" > "$WORK/log/freerdp.log" 2>&1
grep -q -e "AV1 decoder: dav1d" -e "configuration kept" "$WORK/log/freerdp.log"
[ -n "${HOST:-}" ] || grep -q -e "Found FFmpeg" -e "configuration kept" "$WORK/log/freerdp.log"
cmake --build "$WORK/build/$FREERDP" >> "$WORK/log/freerdp.log" 2>&1
DESTDIR=$STAGE cmake --install "$WORK/build/$FREERDP" >> "$WORK/log/freerdp.log" 2>&1
ccache_stats

# --- the host's package: its three programs, licences, manifest, a README
if [ -n "${HOST:-}" ]; then
    NAME=freerdp-host-${VERSION[freerdp_host]}-windows-$ARCH${OVERRIDES:+-local}
    PKG=$WORK/pkg/$NAME
    rm -rf "$WORK/pkg"
    mkdir -p "$PKG/licenses"
    for tool in freerdp-shadow-cli freerdp-shadow-service winpr-hash; do
        f=$(find "$STAGE" -name "$tool.exe" | head -1)
        [ -n "$f" ] || { echo "HOST=1: no $tool.exe in the build" >&2; exit 1; }
        cp "$f" "$PKG/"
        /llvm-mingw/bin/llvm-strip --strip-debug "$PKG/$tool.exe"
        "$KIT/build/check-windows.sh" "$PKG/$tool.exe"
    done
    if [ -n "${HOST_CAMERA:-}" ]; then
        # Frame Server loads it, where Media Foundation is (mfplat.dll is Windows' own)
        f=$(find "$STAGE" -name "freerdp-shadow-camera-source.dll" | head -1)
        [ -n "$f" ] || { echo "HOST_CAMERA=1: no freerdp-shadow-camera-source.dll in the build" >&2; exit 1; }
        cp "$f" "$PKG/"
        /llvm-mingw/bin/llvm-strip --strip-debug "$PKG/freerdp-shadow-camera-source.dll"
        CHECK_WINDOWS_ALSO=mfplat "$KIT/build/check-windows.sh" "$PKG/freerdp-shadow-camera-source.dll"
    fi
    licenses "$PKG/licenses" freerdp_host libressl opus dav1d aom avm zlib jansson llvm_mingw
    cp "$KIT/build/windows/host-README.txt" "$PKG/README.txt"
    {
        echo "FreeRDP's shadow server for Windows ${VERSION[freerdp_host]}, $ARCH, built $(date -u +%F)"
        echo "toolchain: llvm-mingw ${VERSION[llvm_mingw]} (clang, libc++, UCRT)"
        echo
        manifest_kit_line
        manifest_upstream_line
        echo "sources (sources.lock):"
        for name in freerdp_host libressl opus dav1d aom avm zlib jansson llvm_mingw; do
            printf '  %-12s %-10s %s %s\n' "$name" "${VERSION[$name]}" "${SHA[$name]}" "$(manifest_url "$name")"
        done
        override_manifest
    } > "$PKG/MANIFEST"
    rm -f "$OUT/$NAME.zip"
    (cd "$WORK/pkg" && zip -qr "$OUT/$NAME.zip" "$NAME")
    (cd "$OUT" && sha256sum "$NAME.zip" > "$NAME.zip.sha256")
    # the H.264 test client (Media Foundation decoder), for test/windows-host.ps1 only
    f=$(find "$STAGE" -name "sdl-freerdp.exe" | head -1)
    [ -n "$f" ] || { echo "HOST=1: no sdl-freerdp.exe (the H.264 test client) in the build" >&2; exit 1; }
    cp "$f" "$OUT/h264-test-client-windows-$ARCH.exe"
    /llvm-mingw/bin/llvm-strip --strip-debug "$OUT/h264-test-client-windows-$ARCH.exe"
    echo "== done: $OUT/$NAME.zip (and $OUT/h264-test-client-windows-$ARCH.exe)"
    exit 0
fi

# --- package: the client, licences, manifest
# a local build says so in its name
NAME=sdl3-freerdp-${VERSION[freerdp]}-windows-$ARCH${OVERRIDES:+-local}
PKG=$WORK/pkg/$NAME
rm -rf "$WORK/pkg"
mkdir -p "$PKG/licenses"
EXE=$(find "$STAGE" -name 'sdl*-freerdp.exe' | head -1)
cp "$EXE" "$PKG/"
/llvm-mingw/bin/llvm-strip --strip-debug "$PKG/$(basename "$EXE")"
licenses "$PKG/licenses" freerdp sdl3 sdl3_ttf freetype libressl opus dav1d avm zlib jansson \
    llvm_mingw
# FFmpeg's LGPL texts only: its tarball also carries the GPL ones, for code not built here
mkdir -p "$PKG/licenses/ffmpeg"
cp "$WORK/src/ffmpeg/LICENSE.md" "$WORK/src/ffmpeg/COPYING.LGPLv2.1" "$PKG/licenses/ffmpeg/"
# shellcheck source=build/launcher.sh
. "$KIT/build/launcher.sh"
add_launcher "$PKG" windows "$ARCH"
{
    echo "$(basename "$EXE") ${VERSION[freerdp]} for Windows $ARCH, built $(date -u +%F)"
    echo "toolchain: llvm-mingw ${VERSION[llvm_mingw]} (clang, libc++, UCRT)"
    echo
    manifest_kit_line
    manifest_upstream_line
    echo "sources (sources.lock):"
    for name in freerdp sdl3 sdl3_ttf freetype libressl opus dav1d avm ffmpeg zlib jansson llvm_mingw; do
        printf '  %-10s %-8s %s %s\n' "$name" "${VERSION[$name]}" "${SHA[$name]}" "$(manifest_url "$name")"
    done
    echo "ffmpeg: LGPL 2.1, the hevc and h264 decoders and parsers, libavcodec libavutil libswscale"
    echo "$LAUNCHER_MANIFEST"
    override_manifest
    [ "${DEV[0]:-}" != -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF ] || echo "LTO off (local build)"
} > "$PKG/MANIFEST"
"$KIT/build/check-windows.sh" "$PKG/$(basename "$EXE")"
# zip adds to an existing archive: start a new one
rm -f "$OUT/$NAME.zip"
(cd "$WORK/pkg" && zip -qr "$OUT/$NAME.zip" "$NAME")
(cd "$OUT" && sha256sum "$NAME.zip" > "$NAME.zip.sha256")

# the CI's HEVC decode test (test/windows-hevc), from this build tree's own libraries: FreeRDP's
# and FFmpeg's, the ones the client above links. Not in the zip and never released: its own file
# beside it, which kit.yml's windows job leaves out (it uploads dist/*.zip)
cmake --build "$WORK/build/$FREERDP" --target kit-hevc-decode >> "$WORK/log/freerdp.log" 2>&1
cp "$WORK/build/$FREERDP/kit-hevc-decode/kit-hevc-decode.exe" "$OUT/hevc-decode-test-windows-$ARCH.exe"
/llvm-mingw/bin/llvm-strip --strip-debug "$OUT/hevc-decode-test-windows-$ARCH.exe"
echo "== done: $OUT/$NAME.zip (and $OUT/hevc-decode-test-windows-$ARCH.exe, CI only)"
