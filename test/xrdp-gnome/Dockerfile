# GNOME on Wayland through the kit's xrdp preview: sesman starts GNOME for
# the user (xrdp.ini code=31, the wlup module's Mutter backend), and xrdp
# encodes it with AV1. GNOME is led by gnome-session through the user's
# systemd, so systemd is PID 1 here, which Docker allows only with
# --privileged. Rootless podman runs it unprivileged:
#
#   podman run --systemd=always --cap-add SYS_ADMIN,SYS_NICE ...
#
# The capabilities hold inside the user namespace only (the container's
# root is the user who runs it); systemd needs CAP_SYS_ADMIN to start
# polkit, which GNOME asks. Used by wasm-session.sh with SERVER=xrdp-gnome.
# Everything in it is synthetic: user tester, password kit-test-pw, the
# TLS key xrdp's package made when the image was built.
#
# Build context: this directory and, in pkgs/, the kit's Fedora 45
# packages: the xrdp preview and PipeWire's xrdp module, the session's
# sound to the client (wasm-session.sh puts them there).
FROM fedora:45
RUN dnf -y -q install --setopt=install_weak_deps=False \
        systemd systemd-pam dbus-broker polkit openssh-server python3-websockify openssl \
        gnome-shell gnome-session gnome-settings-daemon mutter xorg-x11-server-Xwayland \
        mesa-dri-drivers pipewire pipewire-utils wireplumber pipewire-pulseaudio xdg-desktop-portal-gnome \
        ptyxis nautilus gnome-text-editor adwaita-sans-fonts adwaita-mono-fonts \
        adwaita-icon-theme gnome-backgrounds glibc-langpack-en procps-ng hostname \
        firefox \
    && dnf clean all > /dev/null
COPY pkgs/ /pkgs/
RUN dnf -y -q install /pkgs/*.rpm && dnf clean all > /dev/null && rm -rf /pkgs
# what a container has no use for, and what would fail in one
RUN systemctl mask systemd-oomd.service systemd-oomd.socket systemd-resolved.service \
        systemd-resolved-varlink.socket systemd-resolved-monitor.socket systemd-networkd.service \
        systemd-homed.service rtkit-daemon.service systemd-firstboot.service > /dev/null 2>&1; \
    useradd -m tester && echo tester:kit-test-pw | chpasswd
# systemd sizes its task limits from the container's (podman: 2048): the
# user's slice would get 33 %, 675 tasks, too few for a GNOME session with
# Firefox playing video next to WebGL (its threads fail with EAGAIN and its
# content processes crash). The container's own limit is the bound instead.
RUN mkdir -p /etc/systemd/system/user-.slice.d /etc/systemd/user.conf.d \
    && printf '[Slice]\nTasksMax=infinity\n' > /etc/systemd/system/user-.slice.d/10-tasks.conf \
    && printf '[Manager]\nDefaultTasksMax=infinity\n' > /etc/systemd/user.conf.d/10-tasks.conf
# a GNOME login, the one xrdp starts (code=31: sesman's [GNOME], gnome-session), and AV1
# first for the clients that offer it (the others get H.264); sshd for the gateway
RUN printf '\n[GNOME]\nname=GNOME\nlib=libwlup.so\nusername=ask\npassword=ask\nport=-1\ncode=31\nbackend=mutter\n' \
        >> /etc/xrdp/xrdp.ini \
    && sed -i 's/^autorun=.*/autorun=GNOME/' /etc/xrdp/xrdp.ini \
    && sed -i 's/^order = \[ "H.264", "RFX" \]/order = [ "AV1", "H.264", "RFX" ]/' /etc/xrdp/gfx.toml \
    && grep -q '^order = \[ "AV1", "H.264", "RFX" \]' /etc/xrdp/gfx.toml \
    && systemctl enable xrdp.service sshd.service > /dev/null 2>&1
CMD ["/usr/lib/systemd/systemd"]
