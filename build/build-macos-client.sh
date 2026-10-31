#!/usr/bin/env bash
# Builds the portable SDL3 FreeRDP client for macOS, natively with Apple
# clang (build-macos.sh runs it; it needs bash 4.4+, see there):
#
#   build-macos-client.sh <kit dir> <sources dir> <output dir> <arm64|x86_64>
#
# Each source in sources.lock is checked against its SHA-256, built as a
# static library into $WORK/deps (WORK: ~/.cache/rdp-release-kit/macos-<arch>
# by default) for the one architecture, and FreeRDP's SDL3 client is linked
# against them. The client needs only macOS's own libraries and frameworks.
# The result is <output dir>/sdl3-freerdp-<version>-macos-<arch>.tar.xz with
# the client, the licences of everything inside it and a manifest.
#
# HOST=1 builds the macOS host instead: FreeRDP's shadow server
# (ScreenCaptureKit capture, AV1 with libaom, AV2 with libavm, the sound the
# Mac plays) from freerdp_mac_host, our FreeRDP release with the macOS
# shadow work, as an app: FreeRDP-Shadow.app with a fixed bundle id, so
# macOS keeps its Screen Recording and Accessibility permissions across
# updates (TCC grants them to a code identity), a LaunchAgent that starts it
# in the user's session at login, and a README
# (freerdp-host-<version>-macos-<arch>.zip).
set -Eeuo pipefail

KIT=$1
SOURCES=$2
OUT=$3
ARCH=$4
WORK=${WORK:-$HOME/.cache/rdp-release-kit/macos-$ARCH}
STAGE=$WORK/stage

if ((BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] < 404)); then
    echo "build-macos-client.sh needs bash 4.4 or newer (brew install bash)" >&2
    exit 1
fi
case $ARCH in
    arm64 | x86_64) ;;
    *) echo "build-macos-client.sh: unknown architecture $ARCH" >&2; exit 1 ;;
esac
# the tools from Homebrew (build-macos.sh); nasm for dav1d's x86 code
for tool in cmake ninja meson pkg-config $([ "$ARCH" = x86_64 ] && echo nasm); do
    if ! command -v "$tool" > /dev/null; then
        echo "$tool is missing: brew install bash cmake ninja meson nasm pkgconf ccache" >&2
        exit 1
    fi
done

# macOS 12 (Monterey, 2021) as the oldest system: it is the oldest macOS
# that received security updates until recently (to September 2024), it
# runs on every Apple Silicon Mac and on Intel Macs from 2015 on, and
# today's Xcode still targets it. FreeRDP's SDL client needs 10.15 at the
# least (C++17 <filesystem> in libc++). Every object is compiled for it:
# Apple's headers then reject an API that is newer, and the linker warns
# about an object built for a newer macOS (checked below).
MACOS_MIN=12.0
export MACOSX_DEPLOYMENT_TARGET=$MACOS_MIN

# GNU tools lib.sh uses, with the same output. sha256sum is always
# shasum: macOS 14+ has a sha256sum of its own, but its -c passes (exit 0)
# when the checksum line is malformed, a sources.lock typo say; shasum
# fails then, as GNU's does
sha256sum() { shasum -a 256 "$@"; }
command -v nproc > /dev/null || nproc() { sysctl -n hw.logicalcpu; }

# Apple clang, whatever else is on PATH (Homebrew's llvm, say)
export CC=/usr/bin/clang CXX=/usr/bin/clang++
# shellcheck source=build/lib.sh
. "$KIT/build/lib.sh"
mkdir -p "$OUT"

# lib.sh's on_error finds the newest log with GNU find's -printf
on_error() {
    local log
    if [ "$BASH_SUBSHELL" = 0 ]; then
        log=$(stat -f '%m %N' "$WORK"/log/*.log | sort -n | tail -1 | cut -d' ' -f2-)
        echo "failed, the end of $log:" >&2
        tail -30 "$log" >&2
    fi
}

# pkg-config sees $DEPS only, and CMake ignores Homebrew's and MacPorts'
# prefixes (found through PATH): a library installed there must not end
# up in the client, which would then need it on every Mac.
# CMAKE_APPLE_SILICON_PROCESSOR makes CMake treat an Apple Silicon Mac as
# a host of <arch>: x86_64 is then an ordinary build with -arch x86_64,
# not a cross build, and the projects that pick their SIMD code from
# CMAKE_SYSTEM_PROCESSOR (Opus, FreeRDP) pick x86's. An Intel Mac ignores it.
export PKG_CONFIG_LIBDIR=$DEPS/lib/pkgconfig
unset PKG_CONFIG_PATH
MAC=(-DCMAKE_OSX_ARCHITECTURES="$ARCH" -DCMAKE_APPLE_SILICON_PROCESSOR="$ARCH"
     -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MIN"
     -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local;/opt/local"
     -DPKG_CONFIG_EXECUTABLE="$(command -v pkg-config)")
# what compiles the dependencies, for the stamps: Apple clang and the
# architecture (both share $SOURCES, not their work trees)
TOOLCHAIN_ID="$("$CC" --version | head -1) $ARCH macOS $MACOS_MIN"

# zlib and OpenSSL are not CMake projects: -arch and the target name the
# architecture. Code on macOS is always position independent (no -fPIC).
if ! built zlib; then
    src=$(unpack zlib)
    (cd "$src" && CFLAGS="-O2 -arch $ARCH" ./configure --static --prefix="$DEPS" &&
         make -j"$JOBS" install) > "$WORK/log/zlib.log" 2>&1
    stamp zlib
fi

# macOS keeps a CA bundle at /etc/ssl/cert.pem (and its LibreSSL's
# openssl.cnf next to it), the place OpenSSL looks with --openssldir=/etc/ssl,
# as on Linux
if ! built openssl; then
    src=$(unpack openssl)
    (cd "$src" && ./Configure "darwin64-$ARCH-cc" no-shared no-tests no-docs no-apps \
         --prefix="$DEPS" --libdir=lib --openssldir=/etc/ssl && make -j"$JOBS" &&
         make install_sw) > "$WORK/log/openssl.log" 2>&1
    stamp openssl
fi

cmake_dep opus "${MAC[@]}" -DOPUS_BUILD_PROGRAMS=OFF -DOPUS_BUILD_TESTING=OFF
cmake_dep jansson "${MAC[@]}" -DJANSSON_BUILD_DOCS=OFF -DJANSSON_WITHOUT_TESTS=ON \
    -DJANSSON_EXAMPLES=OFF
# libavm, AV2's reference (FreeRDP#13925 decodes with it), with the AVM
# release kit's options: its two ML encoder experiments off, which also keeps
# TensorFlow Lite and what it would download out of the build
cmake_dep avm "${MAC[@]}" -DAVM_TARGET_CPU="$ARCH" -DENABLE_TESTS=0 -DENABLE_EXAMPLES=0 \
    -DENABLE_DOCS=0 -DENABLE_TOOLS=0 \
    -DCONFIG_ML_PART_SPLIT=0 -DCONFIG_DIP_EXT_PRUNING=0

# x86_64 on Apple Silicon: a meson cross file names the target (meson has
# no -arch of its own); nasm assembles the x86 code natively or crossed
if ! built dav1d; then
    src=$(unpack dav1d)
    rm -rf "$WORK/build/dav1d"
    CROSS=()
    if [ "$(uname -m)" != "$ARCH" ]; then
        CROSS=(--cross-file "$KIT/build/macos/meson-$ARCH.conf")
    fi
    meson setup "$WORK/build/dav1d" "$src" "${CROSS[@]}" --prefix="$DEPS" --libdir=lib \
        --buildtype=release --default-library=static -Denable_tools=false \
        -Denable_tests=false > "$WORK/log/dav1d.log" 2>&1
    meson install -C "$WORK/build/dav1d" >> "$WORK/log/dav1d.log" 2>&1
    stamp dav1d
fi

# No HVF: FreeType 2.15 turns its HVF driver on when the SDK has Apple's
# libhvf (the macOS 26 SDK does), a recent system library with no plain
# arm64 slice (arm64e only), which the static library does not pass on to
# the client's link either
cmake_dep freetype "${MAC[@]}" -DFT_DISABLE_ZLIB=ON -DFT_DISABLE_BZIP2=ON -DFT_DISABLE_PNG=ON \
    -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_BROTLI=ON -DFT_DISABLE_HVF=ON
cmake_dep sdl3 "${MAC[@]}" -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF
cmake_dep sdl3_ttf "${MAC[@]}" -DSDLTTF_VENDORED=OFF -DSDLTTF_HARFBUZZ=OFF \
    -DSDLTTF_PLUTOSVG=OFF -DSDLTTF_SAMPLES=OFF

# FreeRDP: only the SDL3 client, with the Linux client's options where
# macOS has the same choice. Sound plays and the microphone records
# through Core Audio (WITH_MACAUDIO), a system framework, where Linux uses
# PulseAudio. libc++ is part of macOS, so C++ needs no static runtime.
# The native Mac client (MacFreeRDP) stays off; so do CUPS and PC/SC,
# which macOS has as system libraries, as on Linux. JSON must be our
# jansson, never one CMake finds elsewhere. MD4 and RC4 are FreeRDP's own:
# OpenSSL 3 has them only in its legacy provider, and NTLM needs them.
# HOST=1: the shadow server instead of the client, and libaom to encode AV1
# (its decoder stays: FreeRDP's av1.c includes aom_decoder.h with libaom; dav1d
# still decodes), as the Windows host is built
FREERDP=freerdp
WHAT=(-DWITH_CLIENT=ON -DWITH_CLIENT_SDL=ON -DWITH_CLIENT_SDL3=ON -DWITH_CLIENT_SDL2=OFF
      -DWITH_CLIENT_MAC=OFF -DWITH_SERVER=OFF)
if [ -n "${HOST:-}" ]; then
    FREERDP=freerdp_mac_host
    cmake_dep aom "${MAC[@]}" -DENABLE_TESTS=OFF -DENABLE_EXAMPLES=OFF -DENABLE_DOCS=OFF \
        -DENABLE_TOOLS=OFF
    WHAT=(-DWITH_CLIENT=OFF -DWITH_SERVER=ON -DWITH_SHADOW=ON -DWITH_PROXY=OFF
          -DWITH_PLATFORM_SERVER=OFF -DWITH_AOM=ON -DWITH_WINPR_TOOLS=ON)
fi
echo "== $FREERDP ${VERSION[$FREERDP]}"
src=$(unpack "$FREERDP")
# always a fresh configure: a kept CMake cache would keep options that
# were removed from this script, and the release must match a clean build
rm -rf "$STAGE" "$WORK/build/freerdp"
configure "$WORK/build/freerdp" \
    cmake -G Ninja -S "$src" -B "$WORK/build/freerdp" -DCMAKE_BUILD_TYPE=Release "${LAUNCHER[@]}" \
    "${MAC[@]}" -DCMAKE_INSTALL_PREFIX=/opt/freerdp -DCMAKE_PREFIX_PATH="$DEPS" \
    -DCMAKE_SKIP_RPATH=ON -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF \
    -DOPENSSL_ROOT_DIR="$DEPS" -DOPENSSL_USE_STATIC_LIBS=ON \
    -DCMAKE_DISABLE_FIND_PACKAGE_X11=ON \
    "${WHAT[@]}" -DWITH_SDL_LINK_SHARED=OFF -DWITH_X11=OFF -DWITH_WAYLAND=OFF \
    -DWITH_SAMPLE=OFF \
    -DWITH_MACAUDIO=ON -DWITH_PULSE=OFF -DWITH_ALSA=OFF -DWITH_OSS=OFF -DWITH_CUPS=OFF \
    -DWITH_PCSC=OFF -DWITH_KRB5=OFF -DWITH_FUSE=OFF -DWITH_FFMPEG=OFF -DWITH_SWSCALE=OFF \
    -DWITH_OPENH264=OFF -DWITH_GFX_AV1=ON -DWITH_DAV1D=ON -DWITH_OPUS=ON \
    -DWITH_GFX_AV2=ON -DWITH_AVM=ON \
    -DWITH_JANSSON_REQUIRED=ON \
    -DWITH_SYSTEMD=OFF -DWITH_UNICODE_BUILTIN=ON -DWITH_INTERNAL_MD4=ON \
    -DWITH_INTERNAL_RC4=ON -DWITH_SSO_MIB=OFF -DCHANNEL_URBDRC=OFF \
    -DWITH_MANPAGES=OFF > "$WORK/log/freerdp.log" 2>&1
grep -q -e "AV1 decoder: dav1d" -e "configuration kept" "$WORK/log/freerdp.log"
cmake --build "$WORK/build/freerdp" >> "$WORK/log/freerdp.log" 2>&1
# an object built for a newer macOS than MACOS_MIN may call what an older
# one lacks; ld only warns
if grep -i "built for newer" "$WORK/log/freerdp.log" >&2; then
    echo "objects built for a newer macOS than $MACOS_MIN" >&2
    exit 1
fi
DESTDIR=$STAGE cmake --install "$WORK/build/freerdp" >> "$WORK/log/freerdp.log" 2>&1
ccache_stats

# --- HOST=1: the host's app, LaunchAgent, README, licences, manifest; then done
if [ -n "${HOST:-}" ]; then
    NAME=freerdp-host-${VERSION[$FREERDP]}-macos-$ARCH
    PKG=$WORK/pkg/$NAME
    APP=$PKG/FreeRDP-Shadow.app
    rm -rf "$WORK/pkg"
    mkdir -p "$APP/Contents/MacOS" "$PKG/licenses"
    for tool in freerdp-shadow-cli winpr-hash; do
        f=$(find "$STAGE/opt/freerdp/bin" -name "$tool" | head -1)
        [ -n "$f" ] || { echo "HOST=1: no $tool in the build" >&2; exit 1; }
        dest=$APP/Contents/MacOS
        [ "$tool" = freerdp-shadow-cli ] || dest=$PKG
        cp "$f" "$dest/"
        strip -S "$dest/$tool"
    done
    sed "s/@VERSION@/${VERSION[$FREERDP]}/; s/@MACOS_MIN@/$MACOS_MIN/" \
        "$KIT/build/macos/host-Info.plist" > "$APP/Contents/Info.plist"
    cp "$KIT/build/macos/org.freerdp.shadow.plist" "$KIT/build/macos/host-README.txt" "$PKG/"
    mv "$PKG/host-README.txt" "$PKG/README.txt"
    # the bundle id is the code identity TCC remembers (ad hoc, no certificate)
    codesign --force --sign - "$PKG/winpr-hash"
    codesign --force --sign - --identifier org.freerdp.shadow "$APP"
    codesign --verify --strict "$APP"
    licenses "$PKG/licenses" freerdp_mac_host openssl opus dav1d aom avm zlib jansson
    {
        echo "FreeRDP's shadow server for macOS ${VERSION[$FREERDP]}, $ARCH, built $(date -u +%F)"
        echo "build environment: macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))," \
            "$("$CC" --version | head -1), SDK $(xcrun --show-sdk-version)"
        echo "minimum macOS: $MACOS_MIN"
        echo
        echo "sources (sources.lock):"
        for name in freerdp_mac_host openssl opus dav1d aom avm zlib jansson; do
            printf '  %-16s %-10s %s\n' "$name" "${VERSION[$name]}" "${SHA[$name]}"
        done
    } > "$PKG/MANIFEST"
    "$KIT/build/check-macos.sh" "$APP/Contents/MacOS/freerdp-shadow-cli" "$MACOS_MIN"
    # ditto keeps the app's signature and attributes as macOS's own zips do
    (cd "$WORK/pkg" && ditto -c -k --keepParent "$NAME" "$OUT/$NAME.zip")
    (cd "$OUT" && sha256sum "$NAME.zip" > "$NAME.zip.sha256")
    echo "== done: $OUT/$NAME.zip"
    exit 0
fi

# --- package: the client, licences, manifest
NAME=sdl3-freerdp-${VERSION[freerdp]}-macos-$ARCH
PKG=$WORK/pkg/$NAME
rm -rf "$WORK/pkg"
mkdir -p "$PKG/bin" "$PKG/licenses"
cp "$STAGE/opt/freerdp/bin/sdl-freerdp" "$PKG/bin/"
# strip invalidates the linker's ad-hoc signature, without which Apple
# Silicon does not start the binary: sign it again (ad hoc, no identity)
strip -S "$PKG/bin/sdl-freerdp"
codesign --force --sign - "$PKG/bin/sdl-freerdp"
licenses "$PKG/licenses" freerdp sdl3 sdl3_ttf freetype openssl opus dav1d avm zlib jansson
# the connection window: freerdp-tk and its Python (build/launcher.sh)
# shellcheck source=build/launcher.sh
. "$KIT/build/launcher.sh"
add_launcher "$PKG" macos "$ARCH"
check_launcher "$PKG"
# the manifest runs the client: x86_64 on Apple Silicon needs Rosetta 2
if ! "$PKG/bin/sdl-freerdp" --version > /dev/null 2>&1; then
    echo "the $ARCH client does not run here (for x86_64 on Apple Silicon:" \
        "softwareupdate --install-rosetta)" >&2
    exit 1
fi
{
    echo "sdl3-freerdp ${VERSION[freerdp]} for macOS $ARCH, built $(date -u +%F)"
    echo "build environment: macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))," \
        "$("$CC" --version | head -1), SDK $(xcrun --show-sdk-version)"
    echo "minimum macOS: $MACOS_MIN"
    echo
    echo "sources (sources.lock):"
    for name in freerdp sdl3 sdl3_ttf freetype openssl opus dav1d avm zlib jansson; do
        printf '  %-9s %-8s %s\n' "$name" "${VERSION[$name]}" "${SHA[$name]}"
    done
    echo "$LAUNCHER_MANIFEST"
    echo
    # LC_ALL=C: the order of the Linux manifest (macOS's sort skips the
    # punctuation in a UTF-8 locale), so the two compare line by line
    "$PKG/bin/sdl-freerdp" /buildconfig 2> /dev/null | tr ' ' '\n' | grep -E '^WITH_' |
        LC_ALL=C sort
} > "$PKG/MANIFEST"
"$KIT/build/check-macos.sh" "$PKG/bin/sdl-freerdp" "$MACOS_MIN"
# macOS's tar (bsdtar): no AppleDouble ._ files or extended attributes in
# the archive, and the files belong to root as in the Linux one
COPYFILE_DISABLE=1 /usr/bin/tar -cJf "$OUT/$NAME.tar.xz" --no-mac-metadata --uid 0 --gid 0 \
    -C "$WORK/pkg" "$NAME"
(cd "$OUT" && sha256sum "$NAME.tar.xz" > "$NAME.tar.xz.sha256")
echo "== done: $OUT/$NAME.tar.xz"
