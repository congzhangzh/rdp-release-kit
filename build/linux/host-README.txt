FreeRDP's shadow server for Linux
=================================

Share this desktop's own screen with RDP clients: the kit's FreeRDP clients, FreeRDP Web,
mstsc. What the user sees is what the client sees. It shares the session that is already
there, like VNC or GNOME's own Desktop Sharing; it does not start sessions of its own.

  bin/freerdp-shadow-cli     the shadow server
  freerdp-shadow.service     a systemd user unit: starts it with your desktop session
  bin/winpr-hash             a line of a SAM file (not needed for the system's accounts)

Optional, off unless you install it (see "The session manager" below; it runs as root):

  bin/freerdp-shadow-sesman      one port for every user of this computer: each
                                 connection goes to the GNOME session of the user it names
  freerdp-shadow-sesman.service  its systemd system unit, on 127.0.0.1:3391

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

  tar -xJf freerdp-host-*-linux-$(uname -m).tar.xz
  mkdir -p ~/.local/opt ~/.config/systemd/user
  rm -rf ~/.local/opt/freerdp-host   # an earlier version, if any (your settings stay)
  mv freerdp-host-*-linux-$(uname -m) ~/.local/opt/freerdp-host
  cp ~/.local/opt/freerdp-host/freerdp-shadow.service ~/.config/systemd/user/
  systemctl --user daemon-reload
  systemctl --user enable --now freerdp-shadow.service

Its log is the unit's journal: journalctl --user -u freerdp-shadow (-f to follow it) shows
what it shares and who logs in. Where the journal is kept in memory only (no
/var/log/journal, as on some distributions), journald keeps no file of your own and
journalctl --user may show nothing: read it as root (sudo journalctl -t freerdp-shadow-cli),
or keep the journal on disk (Storage=persistent in /etc/systemd/journald.conf, then
sudo systemctl restart systemd-journald). It starts with the desktop session (GNOME
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

The session manager (optional, runs as root)
--------------------------------------------

freerdp-shadow-sesman lets every user of this computer reach their own GNOME session on one
port, without installing the user unit above: it runs as root, as a system service, on a port
of its own, 127.0.0.1:3391 (the user unit keeps 3389, so both can be installed). For each
connection it reads the client's first packet and nothing else, takes the user it names
(the client's user name, "Cookie: mstshash=<user>"), finds that user's GNOME Shell, starts
the shadow server in the user's own systemd manager if it is not running yet (the unit
freerdp-sesman-shadow, on a socket in /run/user/<uid>), drops to the user and hands the
connection over. It never sees a password: TLS and the login (PAM, the session's owner only)
happen in that shadow server, as with the user unit. A user with no GNOME session gets a
headless one if they are in the group freerdp-headless (below), and is refused otherwise.

Install it as root, in /opt/freerdp-host (a root service must not run programs a user can
change, so not from ~/.local):

  sudo rm -rf /opt/freerdp-host   # an earlier version, if any
  sudo tar -xJf freerdp-host-*-linux-$(uname -m).tar.xz -C /opt
  sudo mv /opt/freerdp-host-*-linux-$(uname -m) /opt/freerdp-host
  sudo chown -R root:root /opt/freerdp-host
  sudo cp /opt/freerdp-host/freerdp-shadow-sesman.service /etc/systemd/system/
  sudo systemctl daemon-reload
  sudo systemctl enable --now freerdp-shadow-sesman.service

Connect as with the user unit, through SSH, to port 3391 this time:

  ssh -L 13391:127.0.0.1:3391 <user>@<this computer>

then a client to 127.0.0.1:13391 with your own user name and password. Its log:
sudo journalctl -u freerdp-shadow-sesman (who connects, to whose session); the shadow
server's own lines are in your journal, journalctl --user -u freerdp-sesman-shadow.

Headless sessions: a user of the group freerdp-headless who has no GNOME session gets a
headless GNOME Shell, with a monitor of its own (1920x1080; --headless-size in the unit's
ExecStart changes it), started by the first connection that names them. The group does not
exist until you make it, so this is off until then:

  sudo groupadd -f freerdp-headless
  sudo usermod -aG freerdp-headless <user>

The first connection waits for GNOME and the shadow server to start (about half a minute in
our tests, two at most; a client that gives up
earlier connects on its next try). The session keeps running when the client leaves, so the
next connection finds the same desktop, until the user logs out in it or
sudo systemctl stop freerdp-sesman-gnome-<user>. It is started before the login (the login
happens in the shadow server, once GNOME is up): anyone who reaches the port can make it
start for a member of the group, so keep the port on 127.0.0.1 (reached over SSH, as the unit
has it) or a private network. Log out of a headless session before logging in on this
computer's own screen as the same user: two GNOME sessions of one user at once are not
supported.

Remove it with

  sudo systemctl disable --now freerdp-shadow-sesman.service
  sudo rm /etc/systemd/system/freerdp-shadow-sesman.service
  sudo rm -r /opt/freerdp-host

What it cannot do
-----------------

It runs in your session, after you have logged in: it cannot show the login screen. Before
anyone logs in, only the session manager's headless sessions reach this computer. A Wayland
desktop other than GNOME (KDE Plasma, sway) has no subsystem here yet; on X11 they work
through the X11 one (not through the session manager, which finds GNOME sessions only).

What is in it: MANIFEST (the sources and their versions), licenses/.
More: https://github.com/congzhangzh/rdp-release-kit
