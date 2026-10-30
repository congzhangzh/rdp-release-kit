#!/bin/bash
# Builds the portable SDL3 FreeRDP client inside the build container:
#
#   build-sdl3-client.sh <kit dir> <sources dir> <output dir>
#
# Each source in sources.lock is checked against its SHA-256, built as a
# static library into /work/deps, and FreeRDP's SDL3 client is linked against
# them. The result is <output dir>/sdl3-freerdp-<version>-linux-<arch>.tar.xz
# with the client, the licences of everything inside it and a manifest.
set -Eeuo pipefail

KIT=$1
SOURCES=$2
OUT=$3
WORK=/work
STAGE=$WORK/stage
# shellcheck source=build/lib.sh
. "$KIT/build/lib.sh"
export PKG_CONFIG_PATH=$DEPS/lib/pkgconfig:$DEPS/lib64/pkgconfig
export CFLAGS="-O2 -fPIC"
export CXXFLAGS="-O2 -fPIC"
mkdir -p "$OUT"

if ! built zlib; then
    src=$(unpack zlib)
    (cd "$src" && ./configure --static --prefix="$DEPS" && make -j"$JOBS" install) \
        > "$WORK/log/zlib.log" 2>&1
    stamp zlib
fi

# The configuration and the CA certificates are the host's: /etc/ssl is
# where Debian, Ubuntu, Arch and SUSE keep them, and Fedora/RHEL link
# /etc/ssl/certs to theirs
if ! built openssl; then
    src=$(unpack openssl)
    (cd "$src" && ./Configure no-shared no-tests no-docs no-apps --prefix="$DEPS" --libdir=lib \
         --openssldir=/etc/ssl -fPIC && make -j"$JOBS" && make install_sw) \
        > "$WORK/log/openssl.log" 2>&1
    stamp openssl
fi

cmake_dep opus -DOPUS_BUILD_PROGRAMS=OFF -DOPUS_BUILD_TESTING=OFF
cmake_dep jansson -DJANSSON_BUILD_DOCS=OFF -DJANSSON_WITHOUT_TESTS=ON -DJANSSON_EXAMPLES=OFF
# libavm, AV2's reference (FreeRDP#13925 decodes with it), with the AVM
# release kit's options: its two ML encoder experiments off, which also keeps
# TensorFlow Lite and what it would download out of the build
cmake_dep avm -DENABLE_TESTS=0 -DENABLE_EXAMPLES=0 -DENABLE_DOCS=0 -DENABLE_TOOLS=0 \
    -DCONFIG_ML_PART_SPLIT=0 -DCONFIG_DIP_EXT_PRUNING=0

if ! built dav1d; then
    src=$(unpack dav1d)
    rm -rf "$WORK/build/dav1d"
    meson setup "$WORK/build/dav1d" "$src" --prefix="$DEPS" --libdir=lib --buildtype=release \
        --default-library=static -Denable_tools=false -Denable_tests=false \
        > "$WORK/log/dav1d.log" 2>&1
    meson install -C "$WORK/build/dav1d" >> "$WORK/log/dav1d.log" 2>&1
    stamp dav1d
fi

cmake_dep freetype -DFT_DISABLE_ZLIB=ON -DFT_DISABLE_BZIP2=ON -DFT_DISABLE_PNG=ON \
    -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_BROTLI=ON
cmake_dep sdl3 -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF
cmake_dep sdl3_ttf -DSDLTTF_VENDORED=OFF -DSDLTTF_HARFBUZZ=OFF -DSDLTTF_PLUTOSVG=OFF \
    -DSDLTTF_SAMPLES=OFF

# FreeRDP: only the SDL3 client. Its native X11/Wayland helpers would make
# libX11 and libwayland-client hard dependencies, so they are hidden (the
# client then uses SDL's own window handling for RAIL moves). MD4 and RC4
# are FreeRDP's own: OpenSSL 3 has them only in its legacy provider, and
# NTLM needs them. Sound plays through PulseAudio, the one library the
# client needs from the host besides glibc and libgcc_s. libgcc stays
# shared: linked statically, GCC's unwinder uses _dl_find_object, which
# RHEL 9 backports to glibc 2.34 but other glibc 2.34 systems lack.
echo "== freerdp ${VERSION[freerdp]}"
src=$(unpack freerdp)
# always a fresh configure: a kept CMake cache would keep options that
# were removed from this script, and the release must match a clean build.
# A local FreeRDP (build/overrides.sh) keeps its tree, for quick rebuilds.
rm -rf "$STAGE"
overridden freerdp || rm -rf "$WORK/build/freerdp"
# LTO=off (a local FreeRDP only): no link-time optimisation, whose code
# generation at the link ccache cannot keep, for the quickest rebuild.
# The kept build tree remembers that: without LTO=off the setting is
# dropped again (-U), and FreeRDP chooses, as for a release
DEV=()
if overridden freerdp; then
    if [ "${LTO:-}" = off ]; then
        DEV=(-DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF)
    else
        DEV=(-UCMAKE_INTERPROCEDURAL_OPTIMIZATION)
    fi
fi
# PKG_CONFIG_LIBDIR: pkg-config sees /deps only, so FreeRDP does not find
# the host's wayland-client either
configure "$WORK/build/freerdp" env PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig" \
    cmake -G Ninja -S "$src" -B "$WORK/build/freerdp" -DCMAKE_BUILD_TYPE=Release "${LAUNCHER[@]}" \
    -DCMAKE_INSTALL_PREFIX=/opt/freerdp -DCMAKE_PREFIX_PATH=$DEPS \
    -DCMAKE_SKIP_RPATH=ON -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF \
    -DCMAKE_EXE_LINKER_FLAGS="-static-libstdc++" \
    -DOPENSSL_ROOT_DIR=$DEPS -DOPENSSL_USE_STATIC_LIBS=ON \
    -DCMAKE_DISABLE_FIND_PACKAGE_X11=ON \
    -DWITH_CLIENT=ON -DWITH_CLIENT_SDL=ON -DWITH_CLIENT_SDL3=ON -DWITH_CLIENT_SDL2=OFF \
    -DWITH_SDL_LINK_SHARED=OFF -DWITH_X11=OFF -DWITH_WAYLAND=OFF \
    -DWITH_SERVER=OFF -DWITH_SAMPLE=OFF \
    -DWITH_PULSE=ON -DWITH_ALSA=OFF -DWITH_OSS=OFF -DWITH_CUPS=OFF -DWITH_PCSC=OFF \
    -DWITH_KRB5=OFF -DWITH_FUSE=OFF -DWITH_FFMPEG=OFF -DWITH_SWSCALE=OFF \
    -DWITH_OPENH264=OFF -DWITH_GFX_AV1=ON -DWITH_DAV1D=ON -DWITH_OPUS=ON \
    -DWITH_GFX_AV2=ON -DWITH_AVM=ON \
    -DWITH_SYSTEMD=OFF -DWITH_UNICODE_BUILTIN=ON -DWITH_INTERNAL_MD4=ON \
    -DWITH_INTERNAL_RC4=ON -DWITH_SSO_MIB=OFF -DCHANNEL_URBDRC=OFF \
    -DWITH_MANPAGES=OFF "${DEV[@]}" > "$WORK/log/freerdp.log" 2>&1
grep -q -e "AV1 decoder: dav1d" -e "configuration kept" "$WORK/log/freerdp.log"
cmake --build "$WORK/build/freerdp" >> "$WORK/log/freerdp.log" 2>&1
DESTDIR=$STAGE cmake --install "$WORK/build/freerdp" >> "$WORK/log/freerdp.log" 2>&1
ccache_stats

# --- package: the client, licences, manifest
ARCH=$(uname -m)
NAME=sdl3-freerdp-${VERSION[freerdp]}-linux-$ARCH${OVERRIDES:+-local}
PKG=$WORK/pkg/$NAME
rm -rf "$WORK/pkg"
mkdir -p "$PKG/bin" "$PKG/licenses"
cp "$STAGE/opt/freerdp/bin/sdl-freerdp" "$PKG/bin/"
strip --strip-debug "$PKG/bin/sdl-freerdp"
licenses "$PKG/licenses" freerdp sdl3 sdl3_ttf freetype openssl opus dav1d avm zlib jansson
# shellcheck source=build/launcher.sh
. "$KIT/build/launcher.sh"
add_launcher "$PKG" linux "$ARCH"
check_launcher "$PKG"
{
    echo "sdl3-freerdp ${VERSION[freerdp]} for Linux $ARCH, built $(date -u +%F)"
    # shellcheck source=/dev/null
    echo "build environment: $(. /etc/os-release && echo "$PRETTY_NAME"), $(ldd --version | head -1)"
    override_manifest
    [ "${DEV[0]:-}" != -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF ] || echo "LTO off (local build)"
    echo
    echo "sources (sources.lock):"
    for name in freerdp sdl3 sdl3_ttf freetype openssl opus dav1d avm zlib jansson; do
        printf '  %-9s %-8s %s\n' "$name" "${VERSION[$name]}" "${SHA[$name]}"
    done
    echo "$LAUNCHER_MANIFEST"
    echo
    "$PKG/bin/sdl-freerdp" /buildconfig 2> /dev/null | tr ' ' '\n' | grep -E '^WITH_' | sort
} > "$PKG/MANIFEST"
"$KIT/build/check-portable.sh" "$PKG/bin/sdl-freerdp"
# a local build is compressed quickly: 0.5 s instead of 9 s, 10 % larger
XZ_OPT=${OVERRIDES:+-1} tar -C "$WORK/pkg" -cJf "$OUT/$NAME.tar.xz" "$NAME"
(cd "$OUT" && sha256sum "$NAME.tar.xz" > "$NAME.tar.xz.sha256")
echo "== done: $OUT/$NAME.tar.xz"
