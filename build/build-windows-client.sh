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

# The host's FreeRDP and its AV1 encoder (libaom keeps its decoder: FreeRDP's
# av1.c includes aom_decoder.h whenever libaom is there; dav1d still decodes)
FREERDP=freerdp
WHAT=(-DWITH_CLIENT=ON -DWITH_CLIENT_SDL=ON -DWITH_CLIENT_SDL3=ON -DWITH_CLIENT_SDL2=OFF
      -DWITH_SERVER=OFF -DWITH_GFX_AV2=ON -DWITH_AVM=ON)
if [ -n "${HOST:-}" ]; then
    FREERDP=freerdp_host
    cmake_dep aom "${CROSS[@]}" -DENABLE_TESTS=OFF -DENABLE_EXAMPLES=OFF -DENABLE_DOCS=OFF \
        -DENABLE_TOOLS=OFF
    WHAT=(-DWITH_CLIENT=OFF -DWITH_SERVER=ON -DWITH_SHADOW=ON -DWITH_PROXY=OFF
          -DWITH_PLATFORM_SERVER=OFF -DWITH_SHADOW_WIN_DXGI=ON -DWITH_SHADOW_WIN_SERVICE=ON
          -DWITH_AOM=ON -DWITH_WINPR_TOOLS=ON -DWITH_GFX_AV2=ON -DWITH_AVM=ON)
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
configure "$WORK/build/$FREERDP" \
    cmake -G Ninja -S "$src" -B "$WORK/build/$FREERDP" "${CROSS[@]}" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/freerdp -DCMAKE_PREFIX_PATH="$DEPS" \
    -DCMAKE_EXE_LINKER_FLAGS="-static" -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF \
    -DOPENSSL_ROOT_DIR="$DEPS" -DWITH_LIBRESSL=ON -DZLIB_LIBRARY="$DEPS/lib/libzs.a" \
    "${WHAT[@]}" -DWITH_SDL_LINK_SHARED=OFF -DSDL_USE_COMPILED_RESOURCES=ON \
    -DWITH_SAMPLE=OFF -DWITH_FFMPEG=OFF -DWITH_SWSCALE=OFF \
    -DWITH_OPENH264=OFF -DWITH_GFX_AV1=ON -DWITH_DAV1D=ON -DWITH_OPUS=ON -DWITH_SIMD=ON \
    -DWITH_INTERNAL_MD4=ON -DWITH_INTERNAL_RC4=ON -DCHANNEL_URBDRC=OFF -DUSE_UNWIND=OFF \
    -DWITHOUT_WINPR_3x_DEPRECATED=ON -DWITHOUT_FREERDP_3x_DEPRECATED=ON \
    -DWITH_MANPAGES=OFF "${LAUNCHER[@]}" "${DEV[@]}" > "$WORK/log/freerdp.log" 2>&1
grep -q -e "AV1 decoder: dav1d" -e "configuration kept" "$WORK/log/freerdp.log"
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
    licenses "$PKG/licenses" freerdp_host libressl opus dav1d aom avm zlib jansson llvm_mingw
    cp "$KIT/build/windows/host-README.txt" "$PKG/README.txt"
    {
        echo "FreeRDP's shadow server for Windows ${VERSION[freerdp_host]}, $ARCH, built $(date -u +%F)"
        echo "toolchain: llvm-mingw ${VERSION[llvm_mingw]} (clang, libc++, UCRT)"
        echo
        echo "sources (sources.lock):"
        for name in freerdp_host libressl opus dav1d aom avm zlib jansson llvm_mingw; do
            printf '  %-12s %-10s %s\n' "$name" "${VERSION[$name]}" "${SHA[$name]}"
        done
        override_manifest
    } > "$PKG/MANIFEST"
    rm -f "$OUT/$NAME.zip"
    (cd "$WORK/pkg" && zip -qr "$OUT/$NAME.zip" "$NAME")
    (cd "$OUT" && sha256sum "$NAME.zip" > "$NAME.zip.sha256")
    echo "== done: $OUT/$NAME.zip"
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
# shellcheck source=build/launcher.sh
. "$KIT/build/launcher.sh"
add_launcher "$PKG" windows "$ARCH"
{
    echo "$(basename "$EXE") ${VERSION[freerdp]} for Windows $ARCH, built $(date -u +%F)"
    echo "toolchain: llvm-mingw ${VERSION[llvm_mingw]} (clang, libc++, UCRT)"
    echo
    echo "sources (sources.lock):"
    for name in freerdp sdl3 sdl3_ttf freetype libressl opus dav1d avm zlib jansson llvm_mingw; do
        printf '  %-10s %-8s %s\n' "$name" "${VERSION[$name]}" "${SHA[$name]}"
    done
    echo "$LAUNCHER_MANIFEST"
    override_manifest
    [ "${DEV[0]:-}" != -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF ] || echo "LTO off (local build)"
} > "$PKG/MANIFEST"
"$KIT/build/check-windows.sh" "$PKG/$(basename "$EXE")"
# zip adds to an existing archive: start a new one
rm -f "$OUT/$NAME.zip"
(cd "$WORK/pkg" && zip -qr "$OUT/$NAME.zip" "$NAME")
(cd "$OUT" && sha256sum "$NAME.zip" > "$NAME.zip.sha256")
echo "== done: $OUT/$NAME.zip"
