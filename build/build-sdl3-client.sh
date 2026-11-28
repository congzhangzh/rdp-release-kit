#!/bin/bash
# Builds the portable SDL3 FreeRDP client inside the build container:
#
#   build-sdl3-client.sh <kit dir> <sources dir> <output dir>
#
# Each source in sources.lock is checked against its SHA-256, built as a
# static library into /work/deps, and FreeRDP's SDL3 client is linked against
# them. The result is <output dir>/sdl3-freerdp-<version>-linux-<arch>.tar.xz
# with the client, the licences of everything inside it and a manifest.
# It redirects the local camera (MS-RDPECAM, the rdpecam channel with its V4L2 backend).
#
# HOST=1 builds the Linux host instead: FreeRDP's shadow server
# (freerdp-shadow-cli) from freerdp_linux_host, with two subsystems, Mutter
# (GNOME, X11 or Wayland: Mutter's ScreenCast and RemoteDesktop APIs, PipeWire,
# libei) and X11 (any other X11 desktop); the server takes, at start, the first
# that finds a monitor. AV1 with libaom, AV2 with libavm, Opus sound; the
# session's clipboard (Mutter), its sound and a microphone (PipeWire, both
# subsystems); a client's camera as a v4l2loopback device (with a decoder-only LGPL FFmpeg:
# h264, mjpeg); logins through PAM. FreeRDP and every codec are linked statically; from the host it
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

    # The shadow server's virtual camera (WITH_SHADOW_CAMERA, FreeRDP's server/shadow/camera): a
    # client's camera (MS-RDPECAM) written to a v4l2loopback device. It decodes H.264 with
    # FreeRDP's H.264 decoder and MJPG with freerdp_video_sample_convert, both through a static
    # FFmpeg of its own, with the client's guards: LGPL 2.1, the h264 and mjpeg decoders and the
    # h264 parser alone, no encoder (so the host still offers no H.264: freerdp_codec_supported()
    # probes the encoder at run time), avcodec, avutil and swscale, no programs
    if ! built ffmpeg; then
        src=$(unpack ffmpeg)
        rm -rf "$WORK/build/ffmpeg"
        mkdir -p "$WORK/build/ffmpeg"
        FFCC=()
        [ ${#LAUNCHER[@]} = 0 ] || FFCC=(--cc="ccache ${CC:-gcc}")
        (cd "$WORK/build/ffmpeg" && "$src/configure" --prefix="$DEPS" --libdir="$DEPS/lib" "${FFCC[@]}" \
            --enable-static --disable-shared --enable-pic \
            --disable-gpl --disable-nonfree --disable-version3 \
            --disable-autodetect --enable-pthreads --disable-everything \
            --disable-programs --disable-doc --disable-network \
            --disable-avformat --disable-avdevice --disable-avfilter --disable-swresample \
            --enable-avcodec --enable-avutil --enable-swscale \
            --enable-decoder=h264,mjpeg --enable-parser=h264) > "$WORK/log/ffmpeg.log" 2>&1
        ffcheck() {  # ffcheck <what> <ERE that a line of configure's summary must match>
            grep -q -E "$2" "$WORK/log/ffmpeg.log" ||
                { echo "ffmpeg: configure does not say $1 (log/ffmpeg.log)" >&2; exit 1; }
        }
        ffcheck "LGPL 2.1" '^License: LGPL version 2\.1 or later$'
        ffcheck pthreads '^threading support +pthreads$'
        case $(uname -m) in
            x86_64) ffcheck "nasm" '^x86 assembler +nasm$' ;;
            aarch64) ffcheck "NEON" '^NEON enabled +yes$' ;;
        esac
        ffsection() { sed -n "/^Enabled $1:\$/,/^\$/p" "$WORK/log/ffmpeg.log" | sed 1d | xargs; }
        [ "$(ffsection decoders)" = "h264 mjpeg" ] ||
            { echo "ffmpeg: decoders: '$(ffsection decoders)', not h264 and mjpeg alone (log/ffmpeg.log)" >&2; exit 1; }
        [ "$(ffsection parsers)" = "h264" ] ||
            { echo "ffmpeg: parsers: '$(ffsection parsers)', not h264 alone (log/ffmpeg.log)" >&2; exit 1; }
        [ -z "$(ffsection encoders)" ] || { echo "ffmpeg: encoders enabled: $(ffsection encoders)" >&2; exit 1; }
        echo "== ffmpeg (camera): LGPL 2.1, decoders $(ffsection decoders), parsers $(ffsection parsers)"
        make -C "$WORK/build/ffmpeg" -j"$JOBS" install >> "$WORK/log/ffmpeg.log" 2>&1
        stamp ffmpeg
    fi
    # as the client: libavutil.a after libswscale.a, and libm, at the end of every link line
    FFLIBS="$DEPS/lib/libavutil.a -lm -pthread"
    CAMERA_OPTS=(-DCMAKE_C_STANDARD_LIBRARIES="$FFLIBS" -DCMAKE_CXX_STANDARD_LIBRARIES="$FFLIBS"
        -DWITH_SHADOW_CAMERA=ON -DCHANNEL_RDPECAM=ON -DCHANNEL_RDPECAM_SERVER=ON
        -DWITH_FFMPEG=ON -DWITH_VIDEO_FFMPEG=ON -DWITH_SWSCALE=ON -DWITH_SWSCALE_LOADING=OFF
        -DWITH_DSP_FFMPEG=OFF -DWITH_FFMPEG_HWACCEL=OFF)

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
        -DWITH_KRB5=OFF -DWITH_FUSE=OFF -DWITH_SOXR=OFF \
        -DWITH_OPENH264=OFF -DWITH_GFX_AV1=ON -DWITH_AOM=ON -DWITH_AOM_INTRABC_DV_FIX=ON -DWITH_DAV1D=ON -DWITH_AV1_VAAPI=ON -DWITH_OPUS=ON \
        -DWITH_GFX_AV2=ON -DWITH_AVM=ON -DWITH_SIMD=ON \
        -DWITH_SYSTEMD=ON -DWITH_UNICODE_BUILTIN=ON -DWITH_INTERNAL_MD4=ON \
        -DWITH_INTERNAL_RC4=ON -DWITH_SSO_MIB=OFF -DCHANNEL_URBDRC=OFF \
        -DWITHOUT_WINPR_3x_DEPRECATED=ON -DWITHOUT_FREERDP_3x_DEPRECATED=ON \
        -DWITH_MANPAGES=OFF "${CAMERA_OPTS[@]}" "${DEV[@]}" > "$WORK/log/freerdp.log" 2>&1
    # the camera is in, with our static LGPL FFmpeg and never a library of the image
    for found in "WITH_SHADOW_CAMERA:BOOL=ON" "CHANNEL_RDPECAM_SERVER:BOOL=ON" \
        "WITH_SHADOW_MUTTER:BOOL=ON" "WITH_VIDEO_FFMPEG:BOOL=ON" "WITH_SWSCALE:BOOL=ON" \
        "AVCODEC_LIBRARIES:FILEPATH=$DEPS/lib/libavcodec.a" "AVUTIL_LIBRARIES:FILEPATH=$DEPS/lib/libavutil.a" \
        "SWSCALE_LIBRARIES:FILEPATH=$DEPS/lib/libswscale.a"; do
        grep -q -x -F "$found" "$WORK/build/$FREERDP/CMakeCache.txt" ||
            { echo "HOST=1: no $found in the CMake cache, no camera (log/freerdp.log)" >&2; exit 1; }
    done
    # what the host must have found: both subsystems' libraries and the encoders
    for found in PIPEWIRE SYSTEMD LIBEI PC_AOM PC_AVM; do
        grep -q "^${found}_FOUND:INTERNAL=1" "$WORK/build/$FREERDP/CMakeCache.txt" ||
            { echo "HOST=1: $found not found (log/freerdp.log)" >&2; exit 1; }
    done
    # AV1 4:2:0 encoded on the GPU through VA-API (libva loaded at run time), libaom as the fallback
    grep -q '^WITH_AV1_VAAPI:BOOL=ON' "$WORK/build/$FREERDP/CMakeCache.txt" ||
        { echo "HOST=1: WITH_AV1_VAAPI is not on (log/freerdp.log)" >&2; exit 1; }
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
    # the camera's code is in the server, the FFmpeg it links says LGPL 2.1, and its licence
    # goes with it (LICENSE.md and the LGPL 2.1 only, as the client's)
    grep -a -q -F "camera: no v4l2loopback device" "$PKG/bin/freerdp-shadow-cli" ||
        { echo "HOST=1: no camera in freerdp-shadow-cli" >&2; exit 1; }
    for lib in avcodec avutil swscale; do
        grep -a -q -F "lib$lib license: LGPL version 2.1 or later" "$DEPS/lib/lib$lib.a" ||
            { echo "ffmpeg: lib$lib.a does not say LGPL 2.1" >&2; exit 1; }
    done
    mkdir -p "$PKG/licenses/ffmpeg"
    cp "$WORK/src/ffmpeg/LICENSE.md" "$WORK/src/ffmpeg/COPYING.LGPLv2.1" "$PKG/licenses/ffmpeg/"
    cp "$KIT/build/linux/freerdp-shadow.service" "$KIT/build/linux/freerdp-shadow-sesman.service" "$PKG/"
    cp "$KIT/build/linux/host-README.txt" "$PKG/README.txt"
    licenses "$PKG/licenses" "$FREERDP" openssl opus dav1d aom avm libei libpng zlib jansson
    {
        echo "FreeRDP's shadow server for Linux ${VERSION[$FREERDP]}, $ARCH, built $(date -u +%F)"
        # shellcheck source=/dev/null
        echo "build environment: $(. /etc/os-release && echo "$PRETTY_NAME"), $(ldd --version | head -1)"
        override_manifest
        [ "${DEV[0]:-}" != -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF ] || echo "LTO off (local build)"
        echo
        manifest_kit_line
        manifest_upstream_line
        echo "sources (sources.lock):"
        for name in "$FREERDP" openssl opus dav1d aom avm libei libpng zlib jansson ffmpeg; do
            printf '  %-18s %-10s %s %s\n' "$name" "${VERSION[$name]}" "${SHA[$name]}" "$(manifest_url "$name")"
        done
        echo "ffmpeg configuration: $(sed -n 's/^#define FFMPEG_CONFIGURATION "\(.*\)"$/\1/p' "$WORK/build/ffmpeg/config.h")"
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

# libfuse, for pasting a server's files: the library alone. Symbol versions off: a
# static library has no version script to resolve them. fusermount3 comes from the
# host: libfuse tries its bindir, then the PATH (--bindir, so no build path of ours
# is run on a user's machine); with none, or no /dev/fuse, the client logs it and
# offers no files
if ! built libfuse; then
    src=$(unpack libfuse)
    rm -rf "$WORK/build/libfuse"
    {
        meson setup "$WORK/build/libfuse" "$src" --prefix="$DEPS" --libdir=lib --bindir=/usr/bin \
            --buildtype=release \
            --default-library=static -Dutils=false -Dexamples=false -Dtests=false \
            -Denable-io-uring=false -Ddisable-libc-symbol-version=true
        ninja -C "$WORK/build/libfuse" -j"$JOBS" install
    } > "$WORK/log/libfuse.log" 2>&1
    stamp libfuse
fi

# FFmpeg, the client's HEVC decoder (software; /gfx:HEVC asks for it, AV1 stays the default)
# and its H.264 one (AVC, offered only when asked: WITH_GFX_H264_DEFAULT=OFF below). LGPL 2.1
# only, never GPL, nonfree or version 3; the decoders and parsers of the two codecs alone,
# static, no programs. libswscale too: FreeRDP's h264_ffmpeg.c needs it (WITH_SWSCALE stays
# OFF, that is FreeRDP's own image scaling). Its SIMD code stays on: nasm on x86_64 (in the
# image), NEON on aarch64, picked at run time for the CPU. --disable-autodetect also turns
# the threads off, so pthreads by name: HEVC decodes on several cores. The build stops
# unless configure says LGPL 2.1, pthreads, the assembly, these two decoders and no encoder;
# its summary (the CPU extensions compiled in) stays at the top of log/ffmpeg.log
if ! built ffmpeg; then
    src=$(unpack ffmpeg)
    rm -rf "$WORK/build/ffmpeg"
    mkdir -p "$WORK/build/ffmpeg"
    FFCC=()
    [ ${#LAUNCHER[@]} = 0 ] || FFCC=(--cc="ccache ${CC:-gcc}")
    (cd "$WORK/build/ffmpeg" && "$src/configure" --prefix="$DEPS" --libdir="$DEPS/lib" "${FFCC[@]}" \
        --enable-static --disable-shared --enable-pic \
        --disable-gpl --disable-nonfree --disable-version3 \
        --disable-autodetect --enable-pthreads --disable-everything \
        --disable-programs --disable-doc --disable-network \
        --disable-avformat --disable-avdevice --disable-avfilter --disable-swresample \
        --enable-avcodec --enable-avutil --enable-swscale \
        --enable-decoder=hevc,h264 --enable-parser=hevc,h264) > "$WORK/log/ffmpeg.log" 2>&1
    ffcheck() {  # ffcheck <what> <ERE that a line of configure's summary must match>
        grep -q -E "$2" "$WORK/log/ffmpeg.log" ||
            { echo "ffmpeg: configure does not say $1 (log/ffmpeg.log)" >&2; exit 1; }
    }
    ffcheck "LGPL 2.1" '^License: LGPL version 2\.1 or later$'
    ffcheck pthreads '^threading support +pthreads$'
    case $(uname -m) in
        x86_64) ffcheck "nasm" '^x86 assembler +nasm$' ;;
        aarch64) ffcheck "NEON" '^NEON enabled +yes$' ;;
    esac
    ffsection() { sed -n "/^Enabled $1:\$/,/^\$/p" "$WORK/log/ffmpeg.log" | sed 1d | xargs; }
    [ "$(ffsection decoders)" = "h264 hevc" ] ||
        { echo "ffmpeg: decoders: '$(ffsection decoders)', not h264 and hevc alone (log/ffmpeg.log)" >&2; exit 1; }
    [ -z "$(ffsection encoders)" ] || { echo "ffmpeg: encoders enabled: $(ffsection encoders)" >&2; exit 1; }
    echo "== ffmpeg: LGPL 2.1, $(grep -E '^(runtime cpu detection|x86 assembler|AVX2 enabled|AVX-512 enabled|NEON enabled) ' \
        "$WORK/log/ffmpeg.log" | sed -E 's/  +/ /' | paste -sd, -)"
    make -C "$WORK/build/ffmpeg" -j"$JOBS" install >> "$WORK/log/ffmpeg.log" 2>&1
    stamp ffmpeg
fi

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
# the host's wayland-client either.
# FFmpeg: HEVC through the GFX channel's Azure extension (WITH_GFX_AZURE), decoded by
# libavcodec (WITH_VIDEO_FFMPEG; no sound through it, WITH_DSP_FFMPEG=OFF, which would also
# want libswresample). H.264 is built but offered only when asked for (/gfx:AVC420 or AVC444,
# /gfx:HEVC:i420,AVC420): WITH_GFX_H264_DEFAULT=OFF, so a client given no codec offers what it did
# before FFmpeg came in. FreeRDP's FindFFmpeg finds the static libraries by name, in the order
# avcodec, avutil, swscale, and libswscale.a needs libavutil.a after it, and libm: both go at
# the end of every link line (CMAKE_<LANG>_STANDARD_LIBRARIES; without it the link misses
# av_csp_* in libswscale's format.o)
FFLIBS="$DEPS/lib/libavutil.a -lm -pthread"
# Camera redirection (MS-RDPECAM): the rdpecam client channel with its V4L2 backend (only the
# kernel's videodev2.h), without libusb (WITH_RDPECAM_UVC_H264=OFF: no libusb-1.0.so to need;
# the formats V4L2 lists, MJPG and H.264 included, are passed through as they are). The movie
# and GStreamer backends are off by name: neither would be found (no avformat, no GStreamer
# under /deps), but their options would stay ON in the cache and in /buildconfig
CAMERA_CLIENT_OPTS=(-DCHANNEL_RDPECAM=ON -DCHANNEL_RDPECAM_CLIENT=ON -DWITH_RDPECAM_UVC_H264=OFF
    -DWITH_RDPECAM_MOVIE=OFF -DWITH_RDPECAM_GSTREAMER=OFF)
configure "$WORK/build/freerdp" env PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig" \
    cmake -G Ninja -S "$src" -B "$WORK/build/freerdp" -DCMAKE_BUILD_TYPE=Release "${LAUNCHER[@]}" \
    -DCMAKE_INSTALL_PREFIX=/opt/freerdp -DCMAKE_PREFIX_PATH=$DEPS \
    -DCMAKE_SKIP_RPATH=ON -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF \
    -DCMAKE_EXE_LINKER_FLAGS="-static-libstdc++" \
    -DCMAKE_C_STANDARD_LIBRARIES="$FFLIBS" -DCMAKE_CXX_STANDARD_LIBRARIES="$FFLIBS" \
    -DOPENSSL_ROOT_DIR=$DEPS -DOPENSSL_USE_STATIC_LIBS=ON \
    -DCMAKE_DISABLE_FIND_PACKAGE_X11=ON \
    -DWITH_CLIENT=ON -DWITH_CLIENT_SDL=ON -DWITH_CLIENT_SDL3=ON -DWITH_CLIENT_SDL2=OFF \
    -DWITH_SDL_LINK_SHARED=OFF -DWITH_X11=OFF -DWITH_WAYLAND=OFF \
    -DWITH_SERVER=OFF -DWITH_SAMPLE=OFF \
    -DWITH_PULSE=ON -DWITH_ALSA=OFF -DWITH_OSS=OFF -DWITH_CUPS=OFF -DWITH_PCSC=OFF \
    -DWITH_KRB5=OFF -DWITH_FUSE=ON -DWITH_SWSCALE=OFF \
    -DWITH_FFMPEG=ON -DWITH_VIDEO_FFMPEG=ON -DWITH_DSP_FFMPEG=OFF -DWITH_FFMPEG_HWACCEL=OFF \
    -DWITH_GFX_AZURE=ON -DWITH_GFX_H264_DEFAULT=OFF \
    -DWITH_OPENH264=OFF -DWITH_GFX_AV1=ON -DWITH_DAV1D=ON -DWITH_AV1_VAAPI=ON -DWITH_OPUS=ON \
    -DWITH_GFX_AV2=ON -DWITH_AVM=ON \
    -DWITH_SYSTEMD=OFF -DWITH_UNICODE_BUILTIN=ON -DWITH_INTERNAL_MD4=ON \
    -DWITH_INTERNAL_RC4=ON -DWITH_SSO_MIB=OFF -DCHANNEL_URBDRC=OFF \
    -DWITH_MANPAGES=OFF "${CAMERA_CLIENT_OPTS[@]}" "${DEV[@]}" > "$WORK/log/freerdp.log" 2>&1
grep -q -e "AV1 decoder: dav1d" -e "configuration kept" "$WORK/log/freerdp.log"
# the camera channel and its V4L2 backend; no libusb, movie or GStreamer backend (a FreeRDP
# without these options would build no camera: CMake only warns about an option it does not know)
for found in "CHANNEL_RDPECAM_CLIENT:BOOL=ON" "WITH_RDPECAM_UVC_H264:BOOL=OFF" \
    "WITH_RDPECAM_MOVIE:BOOL=OFF" "WITH_RDPECAM_GSTREAMER:BOOL=OFF"; do
    grep -q -x -F "$found" "$WORK/build/freerdp/CMakeCache.txt" ||
        { echo "freerdp: no $found in its CMake cache, no camera (log/freerdp.log)" >&2; exit 1; }
done
# AV1 4:2:0 on the GPU through VA-API (libva loaded at run time: only its headers here, from
# the image's libva-devel), dav1d as the fallback per stream
grep -q -e "AV1 decoder: VA-API first" -e "configuration kept" "$WORK/log/freerdp.log"
# HEVC and H.264 through our static LGPL FFmpeg, never a library of the image; H.264 not
# offered by default (a FreeRDP without WITH_GFX_H264_DEFAULT would offer it: CMake only
# warns about an option it does not know, so the cache must have it)
for found in "AVCODEC_LIBRARIES:FILEPATH=$DEPS/lib/libavcodec.a" "AVUTIL_LIBRARIES:FILEPATH=$DEPS/lib/libavutil.a" \
    "SWSCALE_LIBRARIES:FILEPATH=$DEPS/lib/libswscale.a" "WITH_GFX_AZURE:BOOL=ON" "WITH_VIDEO_FFMPEG:BOOL=ON" \
    "WITH_GFX_H264_DEFAULT:BOOL=OFF"; do
    grep -q -x -F "$found" "$WORK/build/freerdp/CMakeCache.txt" ||
        { echo "freerdp: no $found in its CMake cache (log/freerdp.log)" >&2; exit 1; }
done
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
# the camera's V4L2 backend is in the client
grep -a -q -F "rdpecam-v4l.client" "$PKG/bin/sdl-freerdp" ||
    { echo "freerdp: no rdpecam V4L2 backend in sdl-freerdp" >&2; exit 1; }
# the libavcodec it links (ours, by the CMake cache check above) is LGPL: what avcodec_license()
# returns. Looked for in the library, not the client: a static link takes only what is called,
# and FreeRDP calls neither avcodec_license() nor avcodec_configuration(), so their strings are
# not in the client
for lib in avcodec avutil swscale; do
    grep -a -q -F "lib$lib license: LGPL version 2.1 or later" "$DEPS/lib/lib$lib.a" ||
        { echo "ffmpeg: lib$lib.a does not say LGPL 2.1" >&2; exit 1; }
done
licenses "$PKG/licenses" freerdp sdl3 sdl3_ttf freetype openssl opus dav1d avm zlib jansson libfuse
# its LICENSE points at this file, which licenses() does not match
cp "$WORK/src/libfuse/LGPL2.txt" "$PKG/licenses/libfuse/"
# FFmpeg: its LICENSE.md and the LGPL 2.1 it is built under; the GPL and LGPL 3 texts of its
# source tree are left out (licenses() would take every COPYING*), none of that code is in
mkdir -p "$PKG/licenses/ffmpeg"
cp "$WORK/src/ffmpeg/LICENSE.md" "$WORK/src/ffmpeg/COPYING.LGPLv2.1" "$PKG/licenses/ffmpeg/"
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
    manifest_kit_line
    manifest_upstream_line
    echo "sources (sources.lock):"
    for name in freerdp sdl3 sdl3_ttf freetype openssl opus dav1d avm zlib jansson libfuse ffmpeg; do
        printf '  %-9s %-8s %s %s\n' "$name" "${VERSION[$name]}" "${SHA[$name]}" "$(manifest_url "$name")"
    done
    echo "ffmpeg configuration: $(sed -n 's/^#define FFMPEG_CONFIGURATION "\(.*\)"$/\1/p' "$WORK/build/ffmpeg/config.h")"
    echo "$LAUNCHER_MANIFEST"
    echo
    "$PKG/bin/sdl-freerdp" /buildconfig 2> /dev/null | tr ' ' '\n' | grep -E '^WITH_' | sort
} > "$PKG/MANIFEST"
"$KIT/build/check-portable.sh" "$PKG/bin/sdl-freerdp"
# a local build is compressed quickly: 0.5 s instead of 9 s, 10 % larger
XZ_OPT=${OVERRIDES:+-1} tar -C "$WORK/pkg" -cJf "$OUT/$NAME.tar.xz" "$NAME"
(cd "$OUT" && sha256sum "$NAME.tar.xz" > "$NAME.tar.xz.sha256")
echo "== done: $OUT/$NAME.tar.xz"
