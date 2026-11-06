#!/bin/bash
# Builds the portable SDL3 FreeRDP client inside the build container:
#
#   build-sdl3-client.sh <kit dir> <sources dir> <output dir>
#
# Each source in sources.lock is checked against its SHA-256, built as a
# static library into /work/deps, and FreeRDP's SDL3 client is linked against
# them. The result is <output dir>/sdl3-freerdp-<version>-linux-<arch>.tar.xz
# with the client, the licences of everything inside it and a manifest.
#
# HOST=1 builds the Linux host instead: FreeRDP's shadow server
# (freerdp-shadow-cli) from freerdp_linux_host, with two subsystems, Mutter
# (GNOME, X11 or Wayland: Mutter's ScreenCast and RemoteDesktop APIs, PipeWire,
# libei) and X11 (any other X11 desktop); the server takes, at start, the first
# that finds a monitor. AV1 with libaom, AV2 with libavm, Opus sound; the
# session's clipboard (Mutter), its sound and a microphone (PipeWire, both
# subsystems); logins through PAM. FreeRDP and every codec are linked statically; from the host it
# needs glibc, libgcc_s, PAM, libsystemd, PipeWire and the X11 libraries a
# desktop has (build/check-portable.sh checks that list). The result is
# <output dir>/freerdp-host-<version>-linux-<arch>.tar.xz, with a systemd user
# unit and a README (build/linux/). Also in it, off unless installed: the
# session manager freerdp-shadow-sesman (WITH_SHADOW_SESMAN), a root system
# unit on a port of its own that hands each connection to the shadow server of
# the GNOME session of the user it names.
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

# --- HOST=1: the shadow server, its package; then done
if [ -n "${HOST:-}" ]; then
    # libaom, the AV1 encoder (its decoder stays: FreeRDP's av1.c includes
    # aom_decoder.h whenever libaom is there; dav1d still decodes), as the
    # Windows and macOS hosts build it
    cmake_dep aom -DENABLE_TESTS=OFF -DENABLE_EXAMPLES=OFF -DENABLE_DOCS=OFF -DENABLE_TOOLS=OFF
    # libei, the Mutter subsystem's input (RemoteDesktop.ConnectToEIS): the
    # client library alone, static, since AlmaLinux 9 has none and a desktop
    # without GNOME 45 or newer may not have it either
    if ! built libei; then
        src=$(unpack libei)
        rm -rf "$WORK/build/libei"
        meson setup "$WORK/build/libei" "$src" --prefix="$DEPS" --libdir=lib --buildtype=release \
            --default-library=static -Dlibei=enabled -Dlibeis=disabled -Dliboeffis=disabled \
            -Dtests=disabled > "$WORK/log/libei.log" 2>&1
        meson install -C "$WORK/build/libei" >> "$WORK/log/libei.log" 2>&1
        stamp libei
    fi

    # libpng, for the clipboard's images (WINPR_UTILS_IMAGE_PNG): a desktop's
    # applications copy PNG, an RDP client asks for a bitmap
    cmake_dep libpng -DPNG_SHARED=OFF -DPNG_STATIC=ON -DPNG_TESTS=OFF -DPNG_TOOLS=OFF

    FREERDP=freerdp_linux_host
    host_source "$FREERDP"
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
            DEV=(-UCMAKE_INTERPROCEDURAL_OPTIMIZATION)
        fi
    fi
    # pkg-config sees /deps first, then the host's PipeWire and libsystemd
    # (sd-bus, and the journal for WLog's journald appender, WITH_SYSTEMD);
    # every other library FreeRDP could pick up from the image is turned off
    # below. The deprecated 3.x API is left out, as on Windows.
    configure "$WORK/build/$FREERDP" \
        env PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig:/usr/lib64/pkgconfig:/usr/share/pkgconfig" \
        cmake -G Ninja -S "$src" -B "$WORK/build/$FREERDP" -DCMAKE_BUILD_TYPE=Release "${LAUNCHER[@]}" \
        -DCMAKE_INSTALL_PREFIX=/opt/freerdp -DCMAKE_PREFIX_PATH=$DEPS \
        -DCMAKE_SKIP_RPATH=ON -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF \
        -DCMAKE_EXE_LINKER_FLAGS="-static-libstdc++" \
        -DOPENSSL_ROOT_DIR=$DEPS -DOPENSSL_USE_STATIC_LIBS=ON \
        -DWITH_CLIENT=OFF -DWITH_CLIENT_COMMON=OFF -DWITH_CLIENT_CHANNELS=OFF \
        -DWITH_SERVER=ON -DWITH_SHADOW=ON -DWITH_SHADOW_X11=ON -DWITH_SHADOW_MUTTER=ON \
        -DWITH_SHADOW_SESMAN=ON -DWITH_SHADOW_PIPEWIRE=ON -DWINPR_UTILS_IMAGE_PNG=ON \
        -DWITH_PROXY=OFF -DWITH_PLATFORM_SERVER=OFF -DWITH_SAMPLE=OFF -DWITH_WINPR_TOOLS=ON \
        -DWITH_X11=ON -DWITH_WAYLAND=OFF -DWITH_XCURSOR=OFF -DWITH_XRANDR=OFF \
        -DWITH_PULSE=OFF -DWITH_ALSA=OFF -DWITH_OSS=OFF -DWITH_CUPS=OFF -DWITH_PCSC=OFF \
        -DWITH_KRB5=OFF -DWITH_FUSE=OFF -DWITH_FFMPEG=OFF -DWITH_SWSCALE=OFF -DWITH_SOXR=OFF \
        -DWITH_OPENH264=OFF -DWITH_GFX_AV1=ON -DWITH_AOM=ON -DWITH_DAV1D=ON -DWITH_OPUS=ON \
        -DWITH_GFX_AV2=ON -DWITH_AVM=ON -DWITH_SIMD=ON \
        -DWITH_SYSTEMD=ON -DWITH_UNICODE_BUILTIN=ON -DWITH_INTERNAL_MD4=ON \
        -DWITH_INTERNAL_RC4=ON -DWITH_SSO_MIB=OFF -DCHANNEL_URBDRC=OFF \
        -DWITHOUT_WINPR_3x_DEPRECATED=ON -DWITHOUT_FREERDP_3x_DEPRECATED=ON \
        -DWITH_MANPAGES=OFF "${DEV[@]}" > "$WORK/log/freerdp.log" 2>&1
    # what the host must have found: both subsystems' libraries and the encoders
    for found in PIPEWIRE SYSTEMD LIBEI PC_AOM PC_AVM; do
        grep -q "^${found}_FOUND:INTERNAL=1" "$WORK/build/$FREERDP/CMakeCache.txt" ||
            { echo "HOST=1: $found not found (log/freerdp.log)" >&2; exit 1; }
    done
    grep -q -E '^PAM_LIBRARY:FILEPATH=/' "$WORK/build/$FREERDP/CMakeCache.txt" ||
        { echo "HOST=1: PAM not found (log/freerdp.log)" >&2; exit 1; }
    grep -q -E "^PNG_LIBRARY[A-Z_]*:FILEPATH=$DEPS/" "$WORK/build/$FREERDP/CMakeCache.txt" ||
        { echo "HOST=1: not our static libpng (log/freerdp.log)" >&2; exit 1; }
    cmake --build "$WORK/build/$FREERDP" >> "$WORK/log/freerdp.log" 2>&1
    DESTDIR=$STAGE cmake --install "$WORK/build/$FREERDP" >> "$WORK/log/freerdp.log" 2>&1
    ccache_stats

    ARCH=$(uname -m)
    NAME=freerdp-host-${VERSION[$FREERDP]}-linux-$ARCH${OVERRIDES:+-local}
    PKG=$WORK/pkg/$NAME
    rm -rf "$WORK/pkg"
    mkdir -p "$PKG/bin" "$PKG/licenses"
    # what a desktop has: PAM, libsystemd (sd-bus, the journal), PipeWire, X11
    # and its extensions
    HOST_LIBS='libpam\.so\.0|libsystemd\.so\.0|libpipewire-0\.3\.so\.0|libX11\.so\.6|libXext\.so\.6|libXdamage\.so\.1|libXfixes\.so\.3|libXinerama\.so\.1|libXtst\.so\.6'
    # freerdp-shadow-sesman: its own README section and unit; the unit names the
    # shadow server's path (/opt/freerdp-host/bin), so its built-in default
    # (the install prefix) does not count
    for tool in freerdp-shadow-cli freerdp-shadow-sesman winpr-hash; do
        f=$(find "$STAGE" -type f -name "$tool*" -perm -u+x | head -1)
        [ -n "$f" ] || { echo "HOST=1: no $tool in the build" >&2; exit 1; }
        cp "$f" "$PKG/bin/$tool"
        strip --strip-debug "$PKG/bin/$tool"
        "$KIT/build/check-portable.sh" "$PKG/bin/$tool" 2.34 "$HOST_LIBS"
    done
    # the unit logs with WLOG_APPENDER=journald: WinPR's journald appender must be
    # in it (before FreeRDP#14029 WITH_SYSTEMD=ON left it out without a word).
    # -W: names not cut short; grep without -q reads it all (pipefail)
    readelf -W --dyn-syms "$PKG/bin/freerdp-shadow-cli" | grep ' sd_journal_stream_fd' > /dev/null ||
        { echo "HOST=1: no journald appender in freerdp-shadow-cli (sd_journal_stream_fd)" >&2; exit 1; }
    cp "$KIT/build/linux/freerdp-shadow.service" "$KIT/build/linux/freerdp-shadow-sesman.service" "$PKG/"
    # polkit reads no rule under /opt: the README's opt-in step copies it to /etc
    f=$(find "$STAGE" -type f -name freerdp-shadow-sesman.rules | head -1)
    [ -n "$f" ] || { echo "HOST=1: no freerdp-shadow-sesman.rules in the build" >&2; exit 1; }
    cp "$f" "$PKG/"
    cp "$KIT/build/linux/host-README.txt" "$PKG/README.txt"
    licenses "$PKG/licenses" "$FREERDP" openssl opus dav1d aom avm libei libpng zlib jansson
    {
        echo "FreeRDP's shadow server for Linux ${VERSION[$FREERDP]}, $ARCH, built $(date -u +%F)"
        # shellcheck source=/dev/null
        echo "build environment: $(. /etc/os-release && echo "$PRETTY_NAME"), $(ldd --version | head -1)"
        override_manifest
        [ "${DEV[0]:-}" != -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF ] || echo "LTO off (local build)"
        echo
        echo "sources (sources.lock):"
        for name in "$FREERDP" openssl opus dav1d aom avm libei libpng zlib jansson; do
            printf '  %-18s %-10s %s\n' "$name" "${VERSION[$name]}" "${SHA[$name]}"
        done
        echo
        echo "from the host (readelf -d bin/freerdp-shadow-cli):"
        readelf -d "$PKG/bin/freerdp-shadow-cli" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/  \1/p'
    } > "$PKG/MANIFEST"
    XZ_OPT=${OVERRIDES:+-1} tar -C "$WORK/pkg" -cJf "$OUT/$NAME.tar.xz" "$NAME"
    (cd "$OUT" && sha256sum "$NAME.tar.xz" > "$NAME.tar.xz.sha256")
    echo "== done: $OUT/$NAME.tar.xz"
    exit 0
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
