# KDE Plasma on Wayland through the kit's xrdp preview: sesman starts Plasma
# for the user (xrdp.ini code=32, the wlup module's KWin backend), and xrdp
# encodes it with AV1. KWin 6.8 composites in software (Mesa llvmpipe) with
# the host's /dev/udmabuf: no GPU, no DRM node, no vgem. Plasma, like GNOME,
# needs systemd as PID 1:
#
#   podman run --systemd=always --device /dev/udmabuf --cap-add SYS_ADMIN,SYS_NICE ...
#
# Arch Linux, the distribution with KWin 6.8 (Debian has 6.7, Fedora 45
# 6.7.5). xrdp is no kit package here: the build stage compiles the kit's
# pinned sources (sources.lock: xrdp_preview, librfxcodec, libpainter,
# pipewire_xrdp) with the kit packages' configure options, plus the KWin
# backend. Used by wasm-session.sh with SERVER=xrdp-kde. Everything in it
# is synthetic: user tester, password kit-test-pw, a TLS key made here.
#
# Build context: this directory and, in src/, the four source archives
# (wasm-session.sh puts them there, checked).
FROM docker.io/library/archlinux:base-devel AS build
RUN pacman -Syu --noconfirm --needed nasm autoconf automake libtool pkgconf openssl pam fuse3 \
        pixman libjpeg-turbo opus x264 aom wayland wayland-protocols libxkbcommon libxkbfile \
        systemd-libs pipewire libei plasma-wayland-protocols libx11 libxfixes libxrandr \
        > /dev/null
COPY src/ /src/
RUN set -e; cd /src; for t in *.tar; do tar -xf "$t"; done; \
    for sub in librfxcodec libpainter; do rm -rf "xrdp_preview/$sub"; cp -a "$sub" "xrdp_preview/$sub"; done; \
    cd /src/xrdp_preview; ./bootstrap > /tmp/bootstrap.log 2>&1; \
    # Arch's layout: /usr/sbin is a link to /usr/bin, and a real sbin in the
    # copy below would replace it (and lose what is reached through it)
    ./configure --prefix=/usr --sbindir=/usr/bin --sysconfdir=/etc --localstatedir=/var --libdir=/usr/lib \
        --with-systemdsystemunitdir=/usr/lib/systemd/system --enable-pam-config=arch \
        --enable-fuse --enable-pixman --enable-jpeg --enable-opus --enable-x264 \
        --enable-ipv6 --enable-vsock --enable-wlup --enable-av1 --enable-wlup-kwin \
        CFLAGS="-O2 -Wno-error=nonnull" > /tmp/configure.log 2>&1 \
        || { tail -30 /tmp/configure.log; exit 1; }; \
    grep -i -E 'kwin|av1' /tmp/configure.log | tail -4; \
    make -j"$(nproc)" > /tmp/make.log 2>&1 || { tail -30 /tmp/make.log; exit 1; }; \
    make install DESTDIR=/out > /dev/null; \
    cd /src/pipewire_xrdp; ./bootstrap > /dev/null 2>&1; \
    ./configure --prefix=/usr --sysconfdir=/etc > /dev/null; \
    make -j"$(nproc)" > /dev/null; make install DESTDIR=/out > /dev/null

FROM docker.io/library/archlinux:base
# Plasma (KWin 6.8, the shell, a terminal, a file manager), Mesa for the
# software renderer, Xwayland, PipeWire, Firefox and sshd + websockify for
# the demo; and what the build stage's xrdp links against
RUN pacman -Syu --noconfirm --needed systemd polkit openssh openssl inetutils procps-ng \
        kwin plasma-workspace plasma-desktop konsole dolphin breeze breeze-icons noto-fonts \
        mesa xorg-xwayland pipewire pipewire-pulse wireplumber firefox python \
        pam fuse3 pixman libjpeg-turbo opus x264 aom wayland libxkbcommon libxkbfile libei \
        libx11 libxfixes libxrandr python-numpy python-requests foot > /dev/null \
    && pacman -Scc --noconfirm > /dev/null
# websockify, which Arch does not package: the PyPI wheel, pinned by its
# SHA-256 (its numpy and requests from Arch; its token plugins' jwcrypto and
# redis are not used here)
RUN python -m venv --system-site-packages /opt/websockify \
    && echo "websockify==0.13.0 --hash=sha256:ac497a8dafc7f51d28ca989f01cdf5f8add663a497d425a56b159dcb8d6a314c" \
        > /tmp/req.txt \
    && /opt/websockify/bin/pip install -q --no-deps --require-hashes -r /tmp/req.txt \
    && ln -s /opt/websockify/bin/websockify /usr/local/bin/websockify && rm /tmp/req.txt \
    && websockify --help > /dev/null
COPY --from=build /out/ /
RUN test -L /usr/sbin && test -L /bin && command -v xrdp xrdp-sesman > /dev/null && websockify --help > /dev/null
# what a container has no use for; udev's coldplug would replay the host's
# device events
RUN systemctl mask systemd-udev-trigger.service systemd-udevd.service systemd-oomd.service \
        systemd-oomd.socket systemd-resolved.service systemd-networkd.service \
        systemd-homed.service rtkit-daemon.service systemd-firstboot.service > /dev/null 2>&1; \
    useradd -m tester && echo tester:kit-test-pw | chpasswd
# systemd sizes its task limits from the container's: the user's slice
# would get a third (see test/xrdp-gnome/Dockerfile)
RUN mkdir -p /etc/systemd/system/user-.slice.d /etc/systemd/user.conf.d \
    && printf '[Slice]\nTasksMax=infinity\n' > /etc/systemd/system/user-.slice.d/10-tasks.conf \
    && printf '[Manager]\nDefaultTasksMax=infinity\n' > /etc/systemd/user.conf.d/10-tasks.conf
# a KDE login, the one xrdp starts (code=32: sesman's [KDE], startplasma.sh),
# AV1 first; xrdp's keys (synthetic); sshd for the gateway
RUN printf '\n[KDE]\nname=KDE\nlib=libwlup.so\nusername=ask\npassword=ask\nport=-1\ncode=32\nbackend=kwin\n' \
        >> /etc/xrdp/xrdp.ini \
    && sed -i 's/^autorun=.*/autorun=KDE/' /etc/xrdp/xrdp.ini \
    && sed -i 's/^order = .*/order = [ "AV1", "H.264", "RFX" ]/' /etc/xrdp/gfx.toml \
    && grep -q '^order = \[ "AV1", "H.264", "RFX" \]' /etc/xrdp/gfx.toml \
    && openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj /CN=rdp-kde \
        -keyout /etc/xrdp/key.pem -out /etc/xrdp/cert.pem 2> /dev/null \
    && xrdp-keygen xrdp /etc/xrdp/rsakeys.ini > /dev/null \
    && systemctl enable xrdp.service sshd.service > /dev/null 2>&1
CMD ["/usr/lib/systemd/systemd"]
