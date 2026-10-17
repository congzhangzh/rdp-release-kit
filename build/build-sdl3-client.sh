#!/bin/bash
# Builds the portable SDL3 FreeRDP client inside the build container:
#
#   build-sdl3-client.sh <kit dir> <sources dir> <output dir>
#
# Each source in sources.lock is checked against its SHA-256, built as a
# static library into /deps, and FreeRDP's SDL3 client is linked against
# them. The result is <output dir>/sdl3-freerdp-<version>-linux-<arch>.tar.xz
# with the client, the licences of everything inside it and a manifest.
set -euo pipefail

KIT=$1
SOURCES=$2
OUT=$3
DEPS=/deps
WORK=/work
STAGE=$WORK/stage
JOBS=$(nproc)
export PKG_CONFIG_PATH=$DEPS/lib/pkgconfig:$DEPS/lib64/pkgconfig
export CFLAGS="-O2 -fPIC"
export CXXFLAGS="-O2 -fPIC"

declare -A VERSION URL SHA
while read -r name version url sha; do
    VERSION[$name]=$version
    URL[$name]=$url
    SHA[$name]=$sha
done < <(grep -v -E '^\s*(#|$)' "$KIT/sources.lock")

# unpack <name>: checks the tarball, extracts it, prints the source dir
unpack() {
    local name=$1 file
    file=$SOURCES/$(basename "${URL[$name]}")
    if [ ! -f "$file" ]; then
        curl -fsSL -o "$file.part" "${URL[$name]}"
        mv "$file.part" "$file"
    fi
    echo "${SHA[$name]}  $file" | sha256sum -c --quiet - >&2
    rm -rf "${WORK:?}/src/$name"
    mkdir -p "$WORK/src/$name"
    tar -xf "$file" --strip-components=1 -C "$WORK/src/$name"
    echo "$WORK/src/$name"
}

# cmake_dep <name> [cmake options]: a CMake project, static, into /deps
cmake_dep() {
    local name=$1 src
    shift
    echo "== $name ${VERSION[$name]}"
    src=$(unpack "$name")
    cmake -G Ninja -S "$src" -B "$WORK/build/$name" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=$DEPS -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_PREFIX_PATH=$DEPS -DBUILD_SHARED_LIBS=OFF \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON "$@" > "$WORK/log/$name.log" 2>&1
    cmake --build "$WORK/build/$name" >> "$WORK/log/$name.log" 2>&1
    cmake --install "$WORK/build/$name" >> "$WORK/log/$name.log" 2>&1
}

mkdir -p "$WORK/log" "$OUT"
trap 'echo "failed, the last log lines:" >&2; tail -20 "$(ls -t "$WORK"/log/*.log | head -1)" >&2' ERR

echo "== zlib ${VERSION[zlib]}"
src=$(unpack zlib)
(cd "$src" && ./configure --static --prefix=$DEPS && make -j"$JOBS" install) > "$WORK/log/zlib.log" 2>&1

echo "== openssl ${VERSION[openssl]}"
src=$(unpack openssl)
# The configuration and the CA certificates are the host's: /etc/ssl is
# where Debian, Ubuntu, Arch and SUSE keep them, and Fedora/RHEL link
# /etc/ssl/certs to theirs
(cd "$src" && ./Configure no-shared no-tests no-docs no-apps --prefix=$DEPS --libdir=lib \
     --openssldir=/etc/ssl -fPIC && make -j"$JOBS" && make install_sw) > "$WORK/log/openssl.log" 2>&1

cmake_dep opus -DOPUS_BUILD_PROGRAMS=OFF -DOPUS_BUILD_TESTING=OFF
cmake_dep jansson -DJANSSON_BUILD_DOCS=OFF -DJANSSON_WITHOUT_TESTS=ON -DJANSSON_EXAMPLES=OFF

echo "== dav1d ${VERSION[dav1d]}"
src=$(unpack dav1d)
meson setup "$WORK/build/dav1d" "$src" --prefix=$DEPS --libdir=lib --buildtype=release \
    --default-library=static -Denable_tools=false -Denable_tests=false \
    > "$WORK/log/dav1d.log" 2>&1
meson install -C "$WORK/build/dav1d" >> "$WORK/log/dav1d.log" 2>&1

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
# client needs from the host besides glibc.
echo "== freerdp ${VERSION[freerdp]}"
src=$(unpack freerdp)
# PKG_CONFIG_LIBDIR: pkg-config sees /deps only, so FreeRDP does not find
# the host's wayland-client either
PKG_CONFIG_LIBDIR=$DEPS/lib/pkgconfig \
    cmake -G Ninja -S "$src" -B "$WORK/build/freerdp" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/opt/freerdp -DCMAKE_PREFIX_PATH=$DEPS \
    -DCMAKE_SKIP_RPATH=ON -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF \
    -DCMAKE_EXE_LINKER_FLAGS="-static-libgcc -static-libstdc++" \
    -DOPENSSL_ROOT_DIR=$DEPS -DOPENSSL_USE_STATIC_LIBS=ON \
    -DCMAKE_DISABLE_FIND_PACKAGE_X11=ON \
    -DWITH_CLIENT=ON -DWITH_CLIENT_SDL=ON -DWITH_CLIENT_SDL3=ON -DWITH_CLIENT_SDL2=OFF \
    -DWITH_SDL_LINK_SHARED=OFF -DWITH_X11=OFF -DWITH_WAYLAND=OFF \
    -DWITH_SERVER=OFF -DWITH_SAMPLE=OFF -DWITH_PROXY=OFF -DWITH_SHADOW=OFF \
    -DWITH_PULSE=ON -DWITH_ALSA=OFF -DWITH_OSS=OFF -DWITH_CUPS=OFF -DWITH_PCSC=OFF \
    -DWITH_KRB5=OFF -DWITH_FUSE=OFF -DWITH_FFMPEG=OFF -DWITH_SWSCALE=OFF \
    -DWITH_OPENH264=OFF -DWITH_GFX_AV1=ON -DWITH_DAV1D=ON -DWITH_OPUS=ON \
    -DWITH_LIBSYSTEMD=OFF -DWITH_UNICODE_BUILTIN=ON -DWITH_INTERNAL_MD4=ON \
    -DWITH_INTERNAL_RC4=ON -DWITH_WEBVIEW=OFF -DWITH_SSO_MIB=OFF -DCHANNEL_URBDRC=OFF \
    -DWITH_MANPAGES=OFF > "$WORK/log/freerdp.log" 2>&1
grep -q "AV1 decoder: dav1d" "$WORK/log/freerdp.log"
cmake --build "$WORK/build/freerdp" >> "$WORK/log/freerdp.log" 2>&1
DESTDIR=$STAGE cmake --install "$WORK/build/freerdp" >> "$WORK/log/freerdp.log" 2>&1

# --- package: the client, licences, manifest
ARCH=$(uname -m)
NAME=sdl3-freerdp-${VERSION[freerdp]}-linux-$ARCH
PKG=$WORK/pkg/$NAME
rm -rf "$WORK/pkg"
mkdir -p "$PKG/bin" "$PKG/licenses"
cp "$STAGE/opt/freerdp/bin/sdl3-freerdp" "$PKG/bin/"
strip --strip-debug "$PKG/bin/sdl3-freerdp"
for name in "${!VERSION[@]}"; do
    dir=$WORK/src/$name
    mkdir -p "$PKG/licenses/$name"
    find "$dir" -maxdepth 2 -type f \( -iname 'LICENSE*' -o -iname 'COPYING*' \
        -o -iname 'LICENCE*' -o -iname 'FTL.TXT' -o -iname 'GPLv2.TXT' \) \
        -exec cp {} "$PKG/licenses/$name/" \;
done
{
    echo "sdl3-freerdp ${VERSION[freerdp]} for Linux $ARCH, built $(date -u +%F)"
    echo "build environment: $(. /etc/os-release && echo "$PRETTY_NAME"), $(ldd --version | head -1)"
    echo
    echo "sources (sources.lock):"
    for name in freerdp sdl3 sdl3_ttf freetype openssl opus dav1d zlib jansson; do
        printf '  %-9s %-8s %s\n' "$name" "${VERSION[$name]}" "${SHA[$name]}"
    done
    echo
    "$PKG/bin/sdl3-freerdp" /buildconfig 2> /dev/null | tr ' ' '\n' | grep -E '^WITH_' | sort
} > "$PKG/MANIFEST"
"$KIT/build/check-portable.sh" "$PKG/bin/sdl3-freerdp"
tar -C "$WORK/pkg" -cJf "$OUT/$NAME.tar.xz" "$NAME"
(cd "$OUT" && sha256sum "$NAME.tar.xz" > "$NAME.tar.xz.sha256")
echo "== done: $OUT/$NAME.tar.xz"
