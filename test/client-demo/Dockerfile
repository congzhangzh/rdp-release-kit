# The computer of the freerdp-tk demo (test/client-demo/run.sh): Debian 13
# with an X display of its own (Xvfb) and a plain window manager (Openbox),
# a terminal, the Secret Service (GNOME Keyring, where freerdp-tk keeps the
# password), PulseAudio for the client's sound, xdotool for the pointer and
# the keys, ffmpeg to record the display. For the uvx video: uv, and
# Debian's own FreeRDP 3 SDL client, since uvx brings only the window; the
# release video unpacks the kit's client archive instead, beside Debian's
# client. Its Python is Debian's (Openbox needs one) without Tk, as on many
# desktops: uvx takes it, and freerdp-tk starts again with uv's own Python,
# which has Tk. Everything in it is synthetic:
# the user demo, the host name laptop, the keyring's password.
FROM docker.io/library/debian:13
RUN apt-get update -qq \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
        xvfb openbox xterm x11-xserver-utils xdotool ffmpeg \
        dbus dbus-x11 gnome-keyring libsecret-1-0 pulseaudio libpulse0 \
        freerdp3-sdl xz-utils ca-certificates fonts-dejavu-core procps \
    && rm -rf /var/lib/apt/lists/* \
    && useradd -m -s /bin/bash demo
COPY --from=ghcr.io/astral-sh/uv:0.11.6 /uv /uvx /usr/local/bin/
