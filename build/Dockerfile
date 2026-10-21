# The build environment: AlmaLinux 9, glibc 2.34. glibc only runs programs
# built against the same or an older version, so building here makes the
# client run on RHEL/Rocky/Alma 9, Debian 12, Ubuntu 22.04, Fedora 35 and
# anything newer.
#
# Only headers and build tools come from here: every library the client
# links is built from sources.lock and linked statically. SDL3 opens X11,
# Wayland, libdecor and its audio backends with dlopen() at runtime, so it
# needs their headers but no link dependency on them.
FROM almalinux:9

# Three tries: a mirror in the middle of a sync serves metadata that does
# not match its packages (CI failed so twice on 2026-10-21, both times here)
RUN for try in 1 2 3; do \
        dnf -y install dnf-plugins-core epel-release \
        && dnf config-manager --set-enabled crb \
        && dnf -y install \
            gcc gcc-c++ make cmake ninja-build meson nasm pkgconf-pkg-config ccache \
            perl-core python3 xz bzip2 file diffutils binutils rsync \
            libX11-devel libXext-devel libXrandr-devel libXcursor-devel libXi-devel \
            libXfixes-devel libXrender-devel libXScrnSaver-devel libXtst-devel \
            libxkbcommon-devel ibus-devel systemd-devel libusb1-devel vulkan-headers \
            mesa-libGLES-devel libstdc++-static \
            wayland-devel wayland-protocols-devel libdecor-devel \
            mesa-libGL-devel mesa-libEGL-devel libdrm-devel mesa-libgbm-devel \
            pulseaudio-libs-devel alsa-lib-devel pipewire-devel dbus-devel \
        && break; \
        [ "$try" = 3 ] && exit 1; \
        dnf clean all; sleep 30; \
    done \
    && dnf clean all
