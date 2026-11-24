# The two computers of the shadow multi-screen demo (test/demo-shadow-multimon.sh), one image:
# Debian 13 with Xvfb, xterm, feh (the server's background) and xdotool, weston (its X11
# backend gives the client two outputs, which an X server alone can't: SDL3 counts RandR
# outputs, and Xvfb has one) and the libraries of the kit's Linux host and client archives, which are unpacked at run time.
# Everything in it is synthetic: the user demo, the password.
FROM docker.io/library/debian:13
RUN apt-get update -qq \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
        xvfb xterm x11-utils xdotool weston feh dbus xz-utils ca-certificates fonts-dejavu-core \
        procps python3 \
        libpipewire-0.3-0t64 libxinerama1 libxdamage1 libxtst6 libxfixes3 libxext6 libpam0g libsystemd0 \
        libpulse0 libx11-xcb1 libwayland-client0 libwayland-cursor0 libwayland-egl1 libxkbcommon0 \
        libdecor-0-0 libegl1 libgles2 \
    && rm -rf /var/lib/apt/lists/*
