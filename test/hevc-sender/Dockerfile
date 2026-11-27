# The HEVC sender: a test tool of CI, never shipped. FreeRDP's shadow server (X11 subsystem)
# from the kit's own FreeRDP pin, linked against Debian's FFmpeg, which is GPL and encodes
# HEVC with libx265 (and H.264 with libx264): FreeRDP's HEVC encoder takes the first HEVC
# encoder libavcodec has (avcodec_find_encoder). The kit's client, whose FFmpeg is LGPL and
# decodes only, talks to it on Xvfb in the same container (test/hevc-session.sh).
#
# Nothing built here leaves the image: no file is copied out, test/hevc-session.sh writes
# logs and screenshots only, and the release's archives (build/check-no-ffmpeg.sh) never
# see it. AV1 through Debian's libaom as well, so a client that asks for nothing gets what
# a kit host gives it (AV1; no AV2, Debian has no libavm), the same before and after.
#
# Build context: this folder with freerdp.tar (git archive of the pinned commit, written
# by test/hevc-session.sh).
ARG BASE=docker.io/library/debian:testing
FROM ${BASE}
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        build-essential cmake ninja-build pkg-config \
        libssl-dev libcjson-dev zlib1g-dev \
        libavcodec-dev libavutil-dev libswscale-dev libaom-dev \
        libx11-dev libxext-dev libxdamage-dev libxfixes-dev libxinerama-dev libxtst-dev \
        xvfb xauth xdotool imagemagick xterm \
        libpulse0 libxcursor1 libxi6 libxrandr2 libxss1 libxkbcommon0 \
        procps xz-utils ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY freerdp.tar /tmp/freerdp.tar
# what the sender must have: the GPL libavcodec with libx265, else HEVC is never offered
RUN f=$(ls /usr/lib/*-linux-gnu/libavcodec.so.* | head -1) \
    && grep -a -q -e '--enable-libx265' "$f" && grep -a -q 'libavcodec license: GPL' "$f" \
    && mkdir /src && tar -xf /tmp/freerdp.tar -C /src --strip-components=1 \
    && cmake -G Ninja -S /src -B /build -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/opt/hevc-sender -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF \
        -DWITH_CLIENT=OFF -DWITH_CLIENT_COMMON=OFF -DWITH_CLIENT_CHANNELS=OFF \
        -DWITH_SERVER=ON -DWITH_SHADOW=ON -DWITH_SHADOW_X11=ON -DWITH_SHADOW_MUTTER=OFF \
        -DWITH_SHADOW_PIPEWIRE=OFF -DWITH_PROXY=OFF -DWITH_PLATFORM_SERVER=OFF -DWITH_SAMPLE=OFF \
        -DWITH_X11=ON -DWITH_WAYLAND=OFF -DWITH_PULSE=OFF -DWITH_ALSA=OFF -DWITH_OSS=OFF \
        -DWITH_CUPS=OFF -DWITH_PCSC=OFF -DWITH_KRB5=OFF -DWITH_FUSE=OFF -DWITH_SYSTEMD=OFF \
        -DWITH_FFMPEG=ON -DWITH_VIDEO_FFMPEG=ON -DWITH_DSP_FFMPEG=OFF -DWITH_SWSCALE=OFF \
        -DWITH_GFX_AZURE=ON -DWITH_OPENH264=OFF -DWITH_GFX_AV1=ON -DWITH_AOM=ON -DWITH_DAV1D=OFF \
        -DWITH_AV1_VAAPI=OFF -DWITH_GFX_AV2=OFF -DWITH_OPUS=OFF -DWITH_SOXR=OFF \
        -DWITH_UNICODE_BUILTIN=ON -DWITH_INTERNAL_MD4=ON -DWITH_INTERNAL_RC4=ON \
        -DCHANNEL_URBDRC=OFF -DWITH_MANPAGES=OFF > /build.log 2>&1 \
    && cmake --build /build >> /build.log 2>&1 \
    && cmake --install /build >> /build.log 2>&1 \
    && rm -rf /src /build /tmp/freerdp.tar \
    || { tail -40 /build.log; exit 1; }
RUN useradd -m -u 1000 -s /bin/bash tester
