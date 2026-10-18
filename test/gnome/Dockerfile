# GNOME on Wayland, reached through gnome-remote-desktop, in a throwaway,
# unprivileged container. Used by wasm-session.sh with SERVER=gnome. No
# systemd: start-server starts sshd, then the user's session (a bus,
# PipeWire, gnome-shell --headless, gnome-remote-desktop --headless).
# Everything in it is synthetic: user tester, password kit-test-pw, a
# self-signed TLS key made at build time.
FROM debian:13
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        dbus dbus-bin dbus-daemon openssh-server websockify xwayland \
        gnome-shell gnome-remote-desktop gnome-console mutter-common gsettings-desktop-schemas \
        dconf-service adwaita-icon-theme fonts-cantarell fonts-dejavu-core \
        pipewire pipewire-pulse wireplumber firefox-esr python3 openssl ca-certificates \
    && rm -rf /var/lib/apt/lists/*
RUN useradd -m -s /bin/bash tester && echo tester:kit-test-pw | chpasswd
# GRD's headless configuration: RDP on 3389, a synthetic TLS key, the synthetic credentials.
# It keeps its settings in GSettings (dconf: a session bus) and, without a TPM, the
# credentials in a file; the build prints the result.
USER tester
RUN mkdir -p ~/.local/share/gnome-remote-desktop && cd ~/.local/share/gnome-remote-desktop \
    && openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj /CN=rdp-gnome \
        -keyout tls.key -out tls.crt 2> /dev/null \
    && dbus-run-session -- sh -c 'grdctl --headless rdp set-tls-key "$PWD/tls.key" \
        && grdctl --headless rdp set-tls-cert "$PWD/tls.crt" && grdctl --headless rdp set-port 3389 \
        && grdctl --headless rdp disable-view-only && grdctl --headless rdp set-credentials tester kit-test-pw \
        && grdctl --headless rdp enable && grdctl --headless status'
USER root
COPY start-server session /usr/local/bin/
CMD ["/usr/local/bin/start-server"]
