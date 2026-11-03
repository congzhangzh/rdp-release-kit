FreeRDP's shadow server for Linux
=================================

Share this desktop's own screen with RDP clients: the kit's FreeRDP clients, FreeRDP Web,
mstsc. What the user sees is what the client sees. It shares the session that is already
there, like VNC or GNOME's own Desktop Sharing; it does not start sessions of its own.

  bin/freerdp-shadow-cli     the shadow server
  freerdp-shadow.service     a systemd user unit: starts it with your desktop session
  bin/winpr-hash             a line of a SAM file (not needed for the system's accounts)

One server for two kinds of desktop; it takes, at start, the first that finds a monitor:

  Mutter   GNOME, on Wayland or X11, through Mutter's own screen-cast and remote-desktop
           interfaces on the session bus (no portal, no permission dialog): the picture
           through PipeWire, the keyboard and mouse through libei (Mutter 45 or newer,
           GNOME 45: older GNOME shows the picture but takes no input)
  X11      any other X11 desktop (Xfce, MATE, KDE on X11...), the display in $DISPLAY

/subsystem lists them, the one it would take marked with *; /subsystem:x11 forces X11.

It needs from the system: glibc 2.34 or newer, PAM, libsystemd, PipeWire's
libpipewire-0.3 and the X11 libraries (libX11, Xext, Xdamage, Xfixes, Xinerama, Xtst), which
a desktop has. Everything else (FreeRDP, OpenSSL, the AV1, AV2 and Opus codecs, libei) is
inside. MANIFEST lists the sources and what the server takes from the system.

Install
-------

  tar -xJf freerdp-host-*-linux-x86_64.tar.xz
  mkdir -p ~/.local/opt ~/.config/systemd/user
  mv freerdp-host-*-linux-x86_64 ~/.local/opt/freerdp-host
  cp ~/.local/opt/freerdp-host/freerdp-shadow.service ~/.config/systemd/user/
  systemctl --user daemon-reload
  systemctl --user enable --now freerdp-shadow.service

Its log: journalctl --user -u freerdp-shadow. It starts with the desktop session (GNOME
starts graphical-session.target) and stops with it. A desktop that does not start that target
(Xfce, MATE...) gets it from its autostart instead, with the display:

  systemctl --user import-environment DISPLAY XAUTHORITY && systemctl --user start freerdp-shadow

GNOME shows its screen-sharing indicator in the top bar while the screen is shared. Stopping
the sharing there ends the server, with exit status 0, so Restart=on-failure does not start
it again: systemctl --user start freerdp-shadow when you want it back. A crash does restart it.

AV2 is on: the clients that offer it (the kit's FreeRDP clients and FreeRDP Web) get AV2,
the others AV1; AV2 costs this computer more processor time (libavm, AV2's reference
encoder). AV1 only: remove /gfx-av2 from the unit's ExecStart, then
systemctl --user daemon-reload && systemctl --user restart freerdp-shadow. There is no H.264
encoder in it: a client without AV1 or AV2 (Windows' own Remote Desktop client, most
others) gets RemoteFX or the older bitmap codecs.

Port 3389 may be taken already by GNOME's own Remote Desktop or Desktop Sharing
(gnome-remote-desktop): turn that off, or give this one /port:<another>, e.g. 3388.

Remove it with

  systemctl --user disable --now freerdp-shadow.service
  rm ~/.config/systemd/user/freerdp-shadow.service
  rm -r ~/.local/opt/freerdp-host

Connect
-------

The login is the account whose desktop it is (your own), checked by the system's PAM over TLS
security (/sec:tls in the unit; keep it there). Another account is refused: it would see
your screen. GNOME (Mutter) asks PAM's service freerdp-shadow when /etc/pam.d/freerdp-shadow
exists, else login. Keep the server on 127.0.0.1 as the unit has it, and reach it through SSH:

  ssh -L 13389:127.0.0.1:3389 <user>@<this computer>

then connect a client to 127.0.0.1:13389. FreeRDP Web: start a WebSocket gateway on this
computer (websockify 127.0.0.1:3390 127.0.0.1:3389) and forward 3390 instead.

The server makes its own TLS certificate on its first start, in ~/.config/freerdp/shadow/.

What it cannot do
-----------------

It runs in your session, after you have logged in: it cannot show the login screen, or
this computer before anyone logs in. A Wayland desktop other than GNOME (KDE Plasma, sway)
has no subsystem here yet; on X11 they work through the X11 one.

What is in it: MANIFEST (the sources and their versions), licenses/.
More: https://github.com/congzhangzh/rdp-release-kit
