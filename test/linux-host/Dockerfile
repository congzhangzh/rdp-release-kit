# The Linux host's test bed (test/linux-host.sh): GNOME 50 headless on
# Wayland for the Mutter subsystem, Xfce on Xvfb for the X11 one, and what the
# kit's Linux client needs to run on Xvfb next to them.
#
# GNOME Shell needs logind and a user manager (the session bus, PipeWire and
# WirePlumber as user units), so this image runs systemd as PID 1; the test
# starts it with podman --systemd=always (rootless here, rootful on a CI
# runner), and the Xfce test as a plain process. Everything in it is
# synthetic: the user tester, its password set by the test.
#
# Debian testing: GNOME Shell 50 as of 2026-11 (Mutter 45 or newer has
# RemoteDesktop.ConnectToEIS, the libei input); the test prints the version
# it ran.
ARG BASE=docker.io/library/debian:testing
FROM ${BASE}
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        systemd systemd-sysv libpam-systemd dbus dbus-user-session \
        gnome-shell xwayland gsettings-desktop-schemas adwaita-icon-theme fonts-dejavu-core \
        pipewire pipewire-bin wireplumber foot \
        xvfb xauth xdotool imagemagick xterm \
        xfce4-session xfwm4 xfdesktop4 xfce4-panel xfce4-settings dbus-x11 \
        libpulse0 libxcursor1 libxi6 libxrandr2 libxss1 libxkbcommon0 \
        libxdamage1 libxinerama1 libxtst6 libxfixes3 libxext6 \
        procps psmisc iproute2 xz-utils ca-certificates \
    && rm -rf /var/lib/apt/lists/*
# what a container has no use for, and what would fail in one
RUN systemctl mask systemd-udev-trigger.service systemd-networkd.service \
        systemd-resolved.service systemd-firstboot.service > /dev/null 2>&1; \
    useradd -m -u 1000 -s /bin/bash tester
CMD ["/usr/lib/systemd/systemd"]
