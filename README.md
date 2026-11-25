# rdp-release-kit

**English** · [日本語](README.ja.md) · [Français](README.fr.md) · [中文](README.zh.md)

Reproducible, portable builds of open-source RDP software, pinned to
upstream release tags (the web client is a preview, built from upstream pull
requests until they are released). This is an unofficial community build
kit: it is not affiliated with the FreeRDP or xrdp projects, and it changes
no upstream source.

## Download

**[The latest release](https://github.com/congzhangzh/rdp-release-kit/releases/latest)**:
the newest build that passed every test, named by its date (`20261025.1`).
Unpack the client for your platform and start `freerdp-tk` (Windows:
double-click `freerdp-tk.cmd`; macOS: `freerdp-tk.command`, after clearing
the download's quarantine, see below), a window to save and open connections; it
brings its own Python and Tk, nothing to install. Or run the client
directly: `bin/sdl-freerdp /v:server /u:user` (Windows: `sdl-freerdp.exe`).
The release notes have a table per platform, the checksums and how to
verify a file's origin.

To share a computer's own screen (Windows, Linux or a Mac), take its
`freerdp-host-*` archive: see [Shadow server](#shadow-server-share-this-computers-own-screen).

## Shadow server: share this computer's own screen

The kit's first product, and its most tested one. FreeRDP's shadow server shares the
screen a computer already shows, the desktop of whoever is at it, with any RDP client:
the kit's FreeRDP clients and freerdp-tk, FreeRDP Web in a browser, or Windows' own Remote
Desktop Connection. It works like VNC or Remote Assistance, but over RDP, with the picture
in AV1 4:2:0, encoded on the graphics card where it has an AV1 encoder. It doesn't start
sessions of its own; for that, see [xrdp](#xrdp-packages).

| | Windows (first) | Linux | macOS (Apple Silicon) |
|---|---|---|---|
| File | `freerdp-host-<version>-windows-x86_64.zip`, `-windows-aarch64.zip` | `freerdp-host-<version>-linux-x86_64.tar.xz`, `-linux-aarch64.tar.xz` | `freerdp-host-<version>-macos-arm64.zip` |
| Runs as | a Windows service, `freerdp-shadow-service`, which runs the server as SYSTEM on the console session: the logon and lock screens, UAC prompts and Ctrl+Alt+Del too | the [session manager](#the-session-manager-runs-as-root), `freerdp-shadow-sesman`: a root system service that hands each user to a shadow server in their own GNOME session (Mutter, Wayland or X11), and starts a headless GNOME for a user who has none; or, without root, a systemd [user unit](#the-user-unit-your-own-desktop-no-root), `freerdp-shadow.service`, in the desktop session you're in: GNOME, or any other X11 desktop | a root LaunchDaemon, `org.freerdp.shadow.daemon`, with an agent (`freerdp-shadow-agent`) in the session on the console: the login window, then your desktop, on one connection; or, without root, a LaunchAgent in your login session (`FreeRDP-Shadow.app`) |
| AV1 4:2:0 | on the graphics card through Media Foundation when it has an AV1 encoder (tested: an NVIDIA laptop GPU), else libaom | on the graphics card through VA-API (not yet proven on a real GPU), else libaom | libaom (no Apple chip encodes AV1) |
| Also | AV2 (libavm), H.264 AVC420 from Media Foundation for clients without AV1, the PC's sound | AV2, the session's sound (PipeWire), keys through libei | AV2, H.264 from VideoToolbox, the Mac's sound |
| Login | a Windows account (Network Level Authentication) | your own account (PAM, over TLS): the session manager hands you to your own GNOME; the user unit lets in the desktop's owner only | a local macOS account (PAM, over TLS): through the daemon, any local user but root at the login window (then you log in on the login window, as at the Mac), or the user on the console; the LaunchAgent lets in its own user only |
| Tested in CI, every release | Windows Server 2025 (x86_64) and Windows 11 on ARM: AV1, Windows logins, Ctrl+Alt+Del, the lock screen, FreeRDP Web | GNOME headless and Xfce, on x86_64 and ARM64: the session manager (a logged-in and a headless GNOME), the user unit, AV1, AV2, keys, sound, another account refused | a GitHub macOS runner: an AV1 and an AV2 session against the LaunchAgent, and the daemon mode installed as below (the runner can't show its login window) |

### Install

**Windows**, in an administrator's PowerShell, in the unzipped folder:

```powershell
.\freerdp-shadow-service.exe install --allow-sas -- /bind-address:127.0.0.1 /port:3388 /gfx-av1 /gfx-av2 -gfx-avc444
```

It starts at once and with Windows, on port 3388: the shadow server listens on 3388 on every
OS, so 3389 stays free for Windows' own Remote Desktop. AV1 only: `/gfx-av2:off` instead of `/gfx-av2`.
`--allow-sas` lets the service send Ctrl+Alt+Del (the policy SoftwareSASGeneration); leave
it out if you don't want that. Remove it with `.\freerdp-shadow-service.exe uninstall`,
which also puts that policy back as install found it. Without a service, for the logged-on
user's desktop only: `.\freerdp-shadow-cli.exe /bind-address:127.0.0.1 /port:3388 /gfx-av1 /gfx-av2`.

**Linux** with GNOME, as root: the session manager. One service for every user of the
computer, there before anyone logs in; a user with no GNOME session can get a headless one
(details in [The session manager](#the-session-manager-runs-as-root)):

```sh
sudo tar -xJf freerdp-host-*-linux-$(uname -m).tar.xz -C /opt
sudo mv /opt/freerdp-host-*-linux-$(uname -m) /opt/freerdp-host
sudo chown -R root:root /opt/freerdp-host
sudo cp /opt/freerdp-host/freerdp-shadow-sesman.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now freerdp-shadow-sesman.service
```

Without root, or on another X11 desktop: the user unit, as yourself, in the desktop session
you want to share (details in [The user unit](#the-user-unit-your-own-desktop-no-root)):

```sh
tar -xJf freerdp-host-*-linux-$(uname -m).tar.xz
mkdir -p ~/.local/opt ~/.config/systemd/user
mv freerdp-host-*-linux-$(uname -m) ~/.local/opt/freerdp-host
cp ~/.local/opt/freerdp-host/freerdp-shadow.service ~/.config/systemd/user/
systemctl --user daemon-reload && systemctl --user enable --now freerdp-shadow.service
```

Both listen on 3388: install one or the other.

**macOS**, after unzipping, as an administrator: the daemon. One server for the Mac, there before
anyone logs in: it shows the login window and follows you into your desktop on the same connection:

```sh
sudo bash ./install-daemon.sh
```

It installs the app in /Applications, the server as a root LaunchDaemon on 127.0.0.1:3388, and its
agent as a LaunchAgent at the login window and in each session. Then allow `freerdp-shadow-agent`
(in /Applications/FreeRDP-Shadow.app/Contents/MacOS) in System Settings > Privacy & Security, under
both Screen & System Audio Recording and Accessibility, then restart the agent, as yourself (not sudo):
`launchctl kickstart -k gui/$(id -u)/org.freerdp.shadow.agent`. The grant holds at the login window too.
Logs: /var/log/freerdp-shadow/. Remove it with
`sudo bash /Applications/FreeRDP-Shadow.app/Contents/Resources/uninstall-daemon.sh`
(`--app` removes the
app too, `--logs` its logs).

Without root, for your own session only: the LaunchAgent app.

```sh
cp -R FreeRDP-Shadow.app /Applications/
xattr -dr com.apple.quarantine /Applications/FreeRDP-Shadow.app
cp org.freerdp.shadow.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/org.freerdp.shadow.plist
```

Then allow FreeRDP Shadow in System Settings > Privacy & Security, under both Screen & System
Audio Recording and Accessibility, and restart it:
`launchctl kickstart -k gui/$(id -u)/org.freerdp.shadow`.

Both listen on 3388: install one or the other (`install-daemon.sh` refuses while the app listens;
`launchctl bootout gui/$(id -u)/org.freerdp.shadow` stops it). Both are signed ad hoc, so macOS
asks for the two permissions again after each update.

Each archive's `README.txt` has the whole story for its platform: logs, options, removal.

### Connect

All three listen on 127.0.0.1:3388 only. Keep it that way, and reach the server over SSH (see
[Deploying a server](#deploying-a-server-keep-rdp-off-the-internet)):

```sh
ssh -N -L 13388:127.0.0.1:3388 user@host &
sdl-freerdp /v:127.0.0.1:13388 /u:user
```

Or use freerdp-tk with 127.0.0.1:13388. For FreeRDP Web, start a WebSocket gateway on the
host (`websockify 127.0.0.1:3390 127.0.0.1:3388`) and forward 3390 instead.
`freerdp-shadow-cli /codec-list` shows the encoders the computer has, and
`/codec-first:software` or `/codec-first:hardware:<id>` picks one. The log names the encoder
in use, e.g. `AV1 encoder: Media Foundation 0 NVIDIA AV1 Encoder MFT (hardware, …), libaom as fallback`.

### What it doesn't do

- **It keeps the screen's own size.** The monitors, their resolution and their scale stay as
  the computer has them, and the client's window shows that screen, scaled if it's smaller.
  A client's `/dynamic-resolution`, `/multimon` layout and HiDPI scale change nothing here.
- **It shares one monitor.** A computer with several monitors shares one of them
  (`/monitors:<N>` picks it; the default is the first).
- **A Mac restarted with FileVault on** shows the disk-unlock screen before macOS starts: no RDP
  server can show it (`sudo fdesetup authrestart` for planned restarts). The LaunchAgent app starts
  only once you've logged in; the daemon shows the login window.

For a session that follows the client's windows and monitors, HiDPI included, use a server
that starts sessions of its own: [xrdp](#xrdp-packages), or Windows' own Remote Desktop on
a Pro edition.

## What it builds

| Artifact | Channel | Runs on |
|---|---|---|
| `sdl-freerdp` (FreeRDP's SDL3 client), with AV1 (dav1d) and Opus, plus [freerdp-tk](https://github.com/congzhangzh/freerdp-tk) and its Python | preview: our FreeRDP preview, the same as the web client's (see the pins below) | Linux x86_64 / aarch64 with glibc ≥ 2.34 and PulseAudio's `libpulse.so.0`: RHEL/Rocky/Alma 9, Debian 12, Ubuntu 22.04, Fedora 35 and newer |
| `sdl-freerdp.exe`, the same client for Windows, with freerdp-tk and its Python | preview, the same | Windows 10 and 11, x86_64 and ARM64 |
| `sdl-freerdp`, the same client for macOS, with freerdp-tk and its Python | preview, the same | macOS 12 and newer, Apple Silicon (arm64); Intel Macs no longer (the last: release 20261122.6) |
| FreeRDP web client (WebAssembly) with the [freerdp-web](https://github.com/congzhangzh/freerdp-web) page | preview: FreeRDP master + open pull requests (see the pins below) | a current browser (tested: Chrome); served from GitHub Pages |
| FreeRDP's shadow server (`freerdp-shadow-cli`), with `freerdp-shadow-service` on Windows, the session manager or a systemd user unit on Linux, a LaunchDaemon with its agent, or a LaunchAgent app, on macOS: AV1 (GPU or libaom), AV2, H.264 on Windows and macOS, sound | preview, the same FreeRDP | Windows 10 and 11 x86_64 and ARM64; Linux x86_64 / aarch64 with glibc ≥ 2.34 (GNOME, or any X11 desktop); macOS on Apple Silicon |
| xrdp + xorgxrdp native packages (.deb / .rpm) | stable | x86_64 and ARM64: Debian testing, 13, 12; Ubuntu 26.10, 26.04, 24.04; Fedora 45, 44, 43 |

### What does not run, and why

Each limit below is a library or a feature that a platform lacks, not a
choice; "tested" means CI runs it there, anything else is what the builds
are made for.

| Where | Not supported | Why |
|---|---|---|
| Linux, older releases | RHEL/CentOS 8, Debian 11, Ubuntu 20.04 and older | Their glibc is older than 2.34. The client is built on AlmaLinux 9 against glibc 2.34's symbols (so it runs on everything newer), and an older loader refuses it: `version GLIBC_2.34 not found`. |
| Linux, musl | Alpine and other musl-based distributions | No glibc at all; the client is a glibc program. |
| Linux, minimal systems | a server or container image without sound libraries | The client links PulseAudio's `libpulse.so.0` (PipeWire provides it too): install `libpulse0` / `pulseaudio-libs`. Every desktop has it. |
| Linux, no display | freerdp-tk's window | Tk draws through X11 (on a Wayland desktop through XWayland), so it needs a desktop session. The client itself still runs from a terminal with `/v:`. |
| Linux on Arch, ARM64 | not tested | Arch publishes x86_64 images only, so the smoke test runs Arch on x86_64 alone. |
| Windows 7, 8, 8.1; 32-bit x86 | not supported; not built | The client uses the Universal C Runtime that is part of Windows 10 and later (llvm-mingw's UCRT target), and the bundled CPython 3.13 is built for Windows 10 and later. 32-bit Windows is not built. |
| macOS, a browser download | starts only after `xattr -dr com.apple.quarantine <folder>` | The client and its Python are signed ad hoc, not notarized by Apple (that needs a paid developer account), so Gatekeeper refuses a quarantined download. |
| macOS 11 and older | not supported | The client is built for macOS 12 (`MACOSX_DEPLOYMENT_TARGET`), the oldest release with security updates until 2024 that every Apple Silicon Mac and Intel Macs from 2015 run. |
| xrdp packages | RHEL/Alma/Rocky, openSUSE; releases older than those listed | Not built (the kit's lists, `distros.list` and `deps/`, cover Debian, Ubuntu and Fedora); EPEL has an xrdp for RHEL's family. xorgxrdp is an Xorg driver that must match its Xorg server exactly, so each release gets its own build. |
| xrdp packages | Debian 12 | Not built since the kit builds one xrdp, ours: its GNOME backend uses Mutter's remote desktop API of GNOME 46 and newer, and Debian 12 has GNOME 43. |
| xrdp: KDE | Debian 13, Ubuntu 26.04 and 24.04 (no KDE session) | The KWin backend needs KWin's output device registry (plasma-wayland-protocols 1.21 and newer); Debian 13 has 1.17, Ubuntu 26.04 1.20, Ubuntu 24.04 1.10. They are marked `no-kde`. |
| xrdp: sway | Debian 13, Ubuntu 24.04 (no sway session) | Sway sessions need sway 1.11 (wlroots 0.19) for the `ext-image-copy-capture` protocols; Debian 13 has sway 1.10, Ubuntu 24.04 sway 1.9. They are marked `no-sway`. |
| xrdp: AV1 | a release without libaom 3.0 | It is built without AV1 (`no-av1`); clients get H.264. |
| Web client | browsers other than Chrome: partly | What each browser lacks and what that turns off (video codecs, the passkey vault, the clipboard): [freerdp-web's docs/browsers.md](https://github.com/congzhangzh/freerdp-web/blob/main/docs/browsers.md). |

Every source is pinned in [`sources.lock`](sources.lock) with its SHA-256
and is built from source. FreeRDP's hash is the one upstream publishes with
its release.
`./check-upstream.sh` lists the sources upstream has released newer
versions of (a daily job opens an issue for each). How a change becomes a
release, and what each release guarantees: [`docs/RELEASE.md`](docs/RELEASE.md).
What changed in the kit, and why: [`CHANGELOG.md`](CHANGELOG.md).

### The pins at a glance

What each product is built from and how it is tested, and, for every pin
that is not a plain upstream release, what our change fixes, how that was
tested, and the pull requests and issues that carry it upstream (their
state: `./check-upstream.sh`). Generated from [`sources.lock`](sources.lock) and
[`pins.notes`](pins.notes) by `build/pins-table.sh --readme README.md`; the
same tables are in the notes of every release.

<!-- pins: generated by build/pins-table.sh from sources.lock and pins.notes -->
| Product | Built from (`sources.lock`) | Tested by |
|---|---|---|
| Linux client `sdl-freerdp` + `freerdp-tk` | freerdp 20261125.3, sdl3 3.4.18, sdl3_ttf 3.2.2, freetype 2.15.0, openssl 3.5.9, opus 1.6.1, dav1d 1.5.4, avm 20261119.6, zlib 1.3.2, jansson 2.15.1, libfuse 3.18.3, freerdp_tk 20261123.3, python_linux_x86_64 3.13.17+20261021, python_linux_aarch64 3.13.17+20261021 | `build/check-portable.sh` (only glibc ≥ 2.34, libgcc_s and libpulse from the host), `test/smoke.sh` (starts and finds its libraries on Alma 9, Rocky 10, Debian 12/13, Ubuntu 22.04/24.04, Fedora 43, Tumbleweed, Arch; there the bundled Python loads Tk and freerdp-tk) |
| Windows client `sdl-freerdp.exe` + `freerdp-tk` | freerdp 20261125.3, sdl3 3.4.18, sdl3_ttf 3.2.2, freetype 2.15.0, libressl 4.4.0, opus 1.6.1, dav1d 1.5.4, avm 20261119.6, zlib 1.3.2, jansson 2.15.1, llvm_mingw 20261020, freerdp_tk 20261123.3, python_windows_x86_64 3.13.17+20261021, python_windows_aarch64 3.13.17+20261021 | `build/check-windows.sh` (needs only Windows' own DLLs) |
| macOS client `sdl-freerdp` + `freerdp-tk` | freerdp 20261125.3, sdl3 3.4.18, sdl3_ttf 3.2.2, freetype 2.15.0, openssl 3.5.9, opus 1.6.1, dav1d 1.5.4, avm 20261119.6, zlib 1.3.2, jansson 2.15.1, freerdp_tk 20261123.3, python_macos_arm64 3.13.17+20261021 | `build/check-macos.sh` (only macOS's own libraries and frameworks, minimum macOS 12.0, an ad-hoc signature); the bundled Python loads Tk and freerdp-tk; arm64 on macos-15 (Intel Macs no longer, since 2026-11-23) |
| Windows host `freerdp-shadow-service` + `freerdp-shadow-cli` | freerdp_host 20261125.3, libressl 4.4.0, opus 1.6.1, dav1d 1.5.4, aom 3.15.2, avm 20261119.6, zlib 1.3.2, jansson 2.15.1, llvm_mingw 20261020 | `build/check-windows.sh`, then `test/windows-host.ps1` for x86_64 and ARM64, each natively on its own runner (Windows Server 2025, Windows 11 on ARM): the service runs the server as SYSTEM on the console session, Windows-account logins, AV1, Ctrl+Alt+Del and the lock screen followed, a Unix socket; and the web client logs in through websockify |
| Web client + freerdp-web page | freerdp 20261125.3, sdl3_wasm 3.4.18+timer, sdl3_ttf 3.2.2, freetype 2.15.0, libressl 4.4.0, opus 1.6.1, dav1d 1.5.4, avm 20261119.6, zlib 1.3.2, jansson 2.15.1, freerdp_web 20261117.2 | `test/wasm-session.sh`: a browser logs in to xrdp through SSH + websockify, the page served without COOP/COEP headers (as GitHub Pages) |
| xrdp packages (.deb, .rpm) | xrdp 20261110.1, librfxcodec 0badc06, libpainter 379b8fb, xorgxrdp 20261018.1, x264 b35605a, opus 1.6.1, pipewire_xrdp 0.2, mutter 51.0-1.fc45 | `check-deps.sh`, then `test/xrdp-session.sh`: install in a fresh container of each release, log in over RDP: an Xorg session (xorgxrdp) with an xterm, then a Wayland one (sway, unless the release is marked no-sway) captured at the client's size; the login screen lists GNOME, and KDE unless no-kde; the default is GNOME on Fedora (Wayland first), Xorg elsewhere |
| macOS host `FreeRDP-Shadow.app` | freerdp_mac_host 20261125.3, openssl 3.5.9, opus 1.6.1, dav1d 1.5.4, aom 3.15.2, avm 20261119.6, zlib 1.3.2, jansson 2.15.1 | `.github/workflows/kit.yml` builds and packages it on Apple Silicon (arm64; Intel no longer, since 2026-11-23); the capture is tested by hand on a Mac (CI cannot grant Screen Recording) |
| Linux host `freerdp-shadow-cli` (GNOME and X11) | freerdp_linux_host 20261125.3, openssl 3.5.9, opus 1.6.1, dav1d 1.5.4, aom 3.15.2, avm 20261119.6, libei 1.6.0, libpng 1.6.59, zlib 1.3.2, jansson 2.15.1 | `build/check-portable.sh` (glibc ≥ 2.34, and from the host only PAM, libsystemd, PipeWire and the X11 libraries), then `test/linux-host.sh` on x86_64 and aarch64, each natively on its own runner (the release waits for it): GNOME Shell 50 headless with the server as the package's systemd user unit (Mutter by default, `/subsystem` lists it first, AV1 and AV2 frames, idle CPU with a client under 20 %, keys through libei, the session's sound in Opus, also when it plays before the first client, the clipboard channel open, the owner's login only, the sharing stopped in GNOME ends it with 0, its lines in the unit's journal through WinPR's journald appender; the session manager as a root system unit on 127.0.0.1:3388: the owner handed to their GNOME's shadow server, logged in, AV1 frames, the clipboard channel open, a wrong password ending the client, an update reaching the next connection, a user with no GNOME session refused, then given a headless GNOME once in the group freerdp-headless, with its sound, its settings daemons, GNOME Software out of its autostart and gnome-software.service masked, following the client's window size), and Xfce on Xvfb with `/subsystem:x11` (AV1 frames, the owner's login only) |

Pins that are not a plain upstream release:

| Source | Pin | Base | What it changes or fixes | How the change is tested | Upstream |
|---|---|---|---|---|---|
| `freerdp` | 20261125.3 [`7a0c4a9e5`](https://github.com/congzhangzh/FreeRDP/commit/7a0c4a9e5fea56e04154cd912f862b99264a88bf) | FreeRDP master @ 86afecc0a8520ca0e0b34dda511ec6e2536f36f6 (2026-11-20) +138 | our release-20261125.3 (integration-all-next58): release-20261125.2 with the HEVC capability decision built only with WITH_GFX_AZURE (.2 did not build the Linux host, which has no HEVC). Release-20261125.2: release-20261123.11 plus a server that keeps its own system type in its capabilities (release-20261125.1), then HEVC on the Mac: VideoToolbox encodes HEVC 4:2:0 in hardware, HEVC 4:2:0 frames get 4:2:0 chroma and profile, and a server confirms HEVC only to a client that offered it. Before that, our release-20261123.11, picked from integration-all on the fork (integration-latest + integration-shadow-win + integration-shadow-mac, one commit for the clients and both hosts): every client, native and web, builds it, not an upstream release. release-20261123.10 is release-20261123.9 plus the SDL overlay naming a release by its name alone (a revision release-YYYYMMDD.N, which the kit writes into .source_version), not by the development version it is built from (3.33.2-dev0). release-20261122.4 is release-20261122.2 plus the Media Foundation encoder's settings set before its media types (NVIDIA's MFT ignores them after: with them first it keeps one key frame at the start instead of one every 30 frames, and honours its quality mode), so the shadow's default CQ runs on the GPU too: quality = 100 - cq-level x 5 / 8 (the default cq-level 16 is quality 90). release-20261122.2 is release-20261122.1 plus AV1 4:2:0 encoding on the GPU in the Windows shadow through Media Foundation (WITH_AV1_MF: the system's hardware AV1 encoder MFT, e.g. NVIDIA's; libaom takes over a stream it refuses or fails; used with the bit-rate modes, CBR/VBR, while the shadow's default CQ stays on libaom; its bit budget follows the real frame rate), and one choice on both the client and the shadow: `/codec-first:hardware[:<id>,...] | software` (default hardware) and `/codec-list`, which lists this machine's hardware codecs with their ids. release-20261122.1 is release-20261121.5 plus AV1 4:2:0 decoding on the GPU on Windows through D3D11VA (WITH_AV1_D3D11VA, any vendor: NVIDIA, AMD, Intel; av1_obu.c parses the frame headers from dav1d 1.5.4's logic, BSD-2-Clause), with dav1d taking over a stream the GPU refuses or fails; the overlay's AV1 decoder row says D3D11VA, hardware, and 10-bit and 4:4:4 stay on dav1d. release-20261114.2 is release-20261114.1 plus WITH_AOM_INTRABC_DV_FIX (default OFF): the kit's hosts build libaom with upstream's own fix b57fd44 as a patch (build/patches/aom/) and turn the option ON, so the encoder keeps intra block copy (2880x1440 key frames 121 KB instead of 277 KB); the patch and the option go in and out together, and both go when the pinned libaom release contains b57fd44. release-20261114.1 is release-20261113.2 plus one fix: the AV1 encoder turns intra block copy off with libaom 3.15 in real time at cpu-used 10 (libaom 3.15.2, which the kit builds, writes key frames with invalid block copy vectors on frames over about 2300 px wide, so nothing of the stream can be shown; upstream libaom main fixed it in b57fd44, in no release yet). Since release-20261113.2 it sits on master 6dddcd3e6, which has also merged six security fixes (static channels after a Soft-Sync migration, the clipboard's file offsets, the proxy's rdpdr locking and its static channel queue, SSPI's buffer table), the shadow server's HEVC #14144 (in place of our #14142, dropped), SDL's scale following the display #14148, audin's idle close #14167, SDL's exit codes #14168, and the runtime codec checks (f39068fe8, #14176), whose decoder check reported AV1 and AV2 as unsupported, so no client built on that master offered them (FreeRDP#14180; our fix, the last pick, sets the profile on encoders only). New on top: the reader woken when a write fails, so auto-reconnect starts in seconds (a dropped link took about 60 s before), the SDL client with no monitor layout to send, and TestRdpgfxSurfaceCommands for our surface command fixes. Before it, release-20261113.1 sat on master d9991b9fa, which had also merged the Mutter backend's part 4 #14141 (with Display Control's one-layout-at-a-time, on the resize path only so far), the AV encoder options #14143 and master's own fix for #14145's codec check (6500da7f0, b1b11c1c9, in place of our last pick); master now builds AV1 and AV2 only when asked (WITH_AOM, WITH_DAV1D, WITH_AVM default OFF), which every kit build does. Before it, release-20261111.4 sat on master b8bb13faf, which had also merged the shadow clipboard #14061 (a clipboard shared by all subsystems, the Mutter session's clipboard), our GNOME login fix #14124, the codec availability checks #14145 (its freerdp_codec_supported asks for WITH_AOM and WITH_LIBAVM in libfreerdp-core, where they are never defined, so AV1 and AV2 were off in every build; our fix, the last pick, asks the AV1 and AV2 codecs themselves), master's own parse of FREERDP_SHADOW_MUTTER_VIRTUAL (fc1384de0, in place of #14133's fix) and its lstat for links (357c2628c, in place of our #14121, closed), the Mutter backend's part 3 #14094, the resize by Reset Graphics #14129, several shadow subsystems #14021, RTT and bandwidth for the client #14125, the GDI clip by cropping #14126, the Mutter backend's part 2 #14042, the Windows clipboard build fix #14130, AV2 #13925, GFX flow control #14093, the sound thread #14092, held keys #13958, clipboard file paths only with FUSE #14096, the recursive delete #14075 (in its maintainer's version), the shadow man page #14095 and the GNOME (Mutter) backend #14006, so those are no longer picks; that last merge refused every GNOME login (getpwuid_r was given a pointer's size) until our #14124. From release-20261105.1 it sat on master a5d85a31f, which had merged our Windows host sound #13954, AVC420 for 10.x #13978, the I444 fast path #13982, the 8 MiB thread stack #14004, the /monitors errno fix #14005, the input race fix #14020 (as 903e1b145) and journald #14029, so those are no longer picks. Master already carries our merged AV1 #13731, sound #13732, H.264 through WebCodecs #13812, #13838, #13839, the Web Audio microphone #13811, the Emscripten clipboard #13733, MessageChannel yield #13864 and monitors #13865, no connection dialog window #13860, SDL3 clipboard events #13872 and hotkeys from the key event's own modifiers #13852. On top: the open pull requests' current heads (#14021, #14042 and #14094, the GNOME backend's next parts; #14076, the decoders' counters in the client stats), and our own commits not proposed yet (the Mac root daemon, sesman, sound and a microphone through PipeWire, the encoder tuning, several GNOME monitors, -sec-nla also turning extended NLA off). TLS 1.3 to Windows Server 2025's own Remote Desktop: the cause is LibreSSL's ClientHello (libressl/portable#1452), fixed by the kit's LibreSSL patch; the earlier TLS 1.2 retry (#13944, closed) is gone | [the#](https://github.com/the/issues/) [native#](https://github.com/native/issues/) [clients'#](https://github.com/clients'/issues/) [smoke#](https://github.com/smoke/issues/) [and#](https://github.com/and/issues/) [xrdp#](https://github.com/xrdp/issues/) [login#](https://github.com/login/issues/) [tests#](https://github.com/tests/issues/) [(with#](https://github.com/(with/issues/) [bpp:24#](https://github.com//bpp:24/issues/) [typing:#](https://github.com/typing:/issues/) [legacy#](https://github.com/legacy/issues/) [bitmaps),#](https://github.com/bitmaps),/issues/) [the#](https://github.com/the/issues/) [web#](https://github.com/web/issues/) [login#](https://github.com/login/issues/) [test,#](https://github.com/test,/issues/) [the#](https://github.com/the/issues/) [Windows#](https://github.com/Windows/issues/) [test#](https://github.com/test/issues/) [(the#](https://github.com/(the/issues/) [browser#](https://github.com/browser/issues/) [and#](https://github.com/and/issues/) [freerdp-tk#](https://github.com/freerdp-tk/issues/) [to#](https://github.com/to/issues/) [Windows'#](https://github.com/Windows'/issues/) [own#](https://github.com/own/issues/) [Remote#](https://github.com/Remote/issues/) [Desktop);#](https://github.com/Desktop);/issues/) [before#](https://github.com/before/issues/) [the#](https://github.com/the/issues/) [pick:#](https://github.com/pick:/issues/) [ctest#](https://github.com/ctest/issues/) [227#](https://github.com/227/227/issues/) [with#](https://github.com/with/issues/) [AV1#](https://github.com/AV1/issues/) [and#](https://github.com/and/issues/) [AV2,#](https://github.com/AV2,/issues/) [225#](https://github.com/225/225/issues/) [without,#](https://github.com/without,/issues/) [on#](https://github.com/on/issues/) [the#](https://github.com/the/issues/) [rebuilt#](https://github.com/rebuilt/issues/) [integration#](https://github.com/integration/issues/) [(freerdp-review-g2),#](https://github.com/(freerdp-review-g2),/issues/) [then#](https://github.com/then/issues/) [the#](https://github.com/the/issues/) [kit#](https://github.com/kit/issues/) [round#](https://github.com/round/issues/) |
| `freerdp_host` | 20261125.3 [`7a0c4a9e5`](https://github.com/congzhangzh/FreeRDP/commit/7a0c4a9e5fea56e04154cd912f862b99264a88bf) | FreeRDP master @ 86afecc0a8520ca0e0b34dda511ec6e2536f36f6 (2026-11-20) +138 | our release-20261125.3 (integration-all-next58): release-20261125.2 with the HEVC capability decision built only with WITH_GFX_AZURE (.2 did not build the Linux host, which has no HEVC). Release-20261125.2: release-20261123.11 plus a server that keeps its own system type in its capabilities (release-20261125.1), then HEVC on the Mac: VideoToolbox encodes HEVC 4:2:0 in hardware, HEVC 4:2:0 frames get 4:2:0 chroma and profile, and a server confirms HEVC only to a client that offered it. Before that, our release-20261123.11, picked from integration-all (the clients' and the Mac host's FreeRDP too), with integration-shadow-win's commits: the Windows shadow server's two build fixes, DXGI capture that follows the secure desktop, freerdp-shadow-service with Ctrl+Alt+Del, a Unix-socket listener on Windows, a refresh request answered with the whole screen, AV2 (FreeRDP#13925: libavm encodes, `/gfx-av2`), the sound the PC plays (WASAPI loopback; its rdpsnd fixes #13943), the screen's true size (a 1600 x 900 screen was 1601 x 901); uninstall puts back the Ctrl+Alt+Del policy as install found it; the keys a client leaves held are let go when it leaves or sends a Synchronize (#13958); H.264 (AVC420, `/gfx-avc420`) from Windows' own Media Foundation encoder, no OpenH264 (#13970) | `test/windows-host.ps1` (Windows Server 2025 runner) | [FreeRDP#13970](https://github.com/FreeRDP/FreeRDP/issues/13970) [FreeRDP#13931](https://github.com/FreeRDP/FreeRDP/issues/13931) [FreeRDP#13932](https://github.com/FreeRDP/FreeRDP/issues/13932) [FreeRDP#13933](https://github.com/FreeRDP/FreeRDP/issues/13933) [FreeRDP#13934](https://github.com/FreeRDP/FreeRDP/issues/13934) [FreeRDP#13935](https://github.com/FreeRDP/FreeRDP/issues/13935) [FreeRDP#13943](https://github.com/FreeRDP/FreeRDP/issues/13943) [FreeRDP#13954](https://github.com/FreeRDP/FreeRDP/issues/13954) [FreeRDP#13956](https://github.com/FreeRDP/FreeRDP/issues/13956) [FreeRDP#13958](https://github.com/FreeRDP/FreeRDP/issues/13958) |
| `freerdp_mac_host` | 20261125.3 [`7a0c4a9e5`](https://github.com/congzhangzh/FreeRDP/commit/7a0c4a9e5fea56e04154cd912f862b99264a88bf) | FreeRDP master @ 86afecc0a8520ca0e0b34dda511ec6e2536f36f6 (2026-11-20) +138 | our release-20261125.3 (integration-all-next58): release-20261125.2 with the HEVC capability decision built only with WITH_GFX_AZURE (.2 did not build the Linux host, which has no HEVC). Release-20261125.2: release-20261123.11 plus a server that keeps its own system type in its capabilities (release-20261125.1), then HEVC on the Mac: VideoToolbox encodes HEVC 4:2:0 in hardware, HEVC 4:2:0 frames get 4:2:0 chroma and profile, and a server confirms HEVC only to a client that offered it. Before that, our release-20261123.11, picked from integration-all (the clients' and the Windows host's FreeRDP too), with integration-shadow-mac's commits (freerdp-d0's): the shadow server built on macOS again, ScreenCaptureKit capture of every display with the sound the Mac plays, Quartz input, the cursor drawn by the client, capture again after the display sleeps; logins are the Mac's own (PAM, /sec:tls); with the AV2 extension and the shadow server's rdpsnd fixes; since release-20261031.10 the extended keys (both Command keys, arrows, Home/End, PgUp/PgDn, Forward Delete, keypad Enter, right Option) reach the Mac; since release-20261101.1 the right Control key too (WinPR mapped it to the right Windows key: "no key for scancode 0x011d", #13971) | a compile and package on GitHub's macOS runner (Apple Silicon; Intel no longer, since 2026-11-23); a live session on a Mac (login, cursor, Opus sound, input) | [FreeRDP#13925](https://github.com/FreeRDP/FreeRDP/issues/13925) [FreeRDP#13943](https://github.com/FreeRDP/FreeRDP/issues/13943) [FreeRDP#13948](https://github.com/FreeRDP/FreeRDP/issues/13948) [FreeRDP#13952](https://github.com/FreeRDP/FreeRDP/issues/13952) [FreeRDP#13953](https://github.com/FreeRDP/FreeRDP/issues/13953) |
| `freerdp_linux_host` | 20261125.3 [`7a0c4a9e5`](https://github.com/congzhangzh/FreeRDP/commit/7a0c4a9e5fea56e04154cd912f862b99264a88bf) | FreeRDP master @ 86afecc0a8520ca0e0b34dda511ec6e2536f36f6 (2026-11-20) +138 | our release-20261125.3 (integration-all-next58): release-20261125.2 with the HEVC capability decision built only with WITH_GFX_AZURE (.2 did not build the Linux host, which has no HEVC). Release-20261125.2: release-20261123.11 plus a server that keeps its own system type in its capabilities (release-20261125.1), then HEVC on the Mac: VideoToolbox encodes HEVC 4:2:0 in hardware, HEVC 4:2:0 frames get 4:2:0 chroma and profile, and a server confirms HEVC only to a client that offered it. Before that, our release-20261123.11, picked from integration-all (the clients' and the other hosts' FreeRDP too), with freerdp-ce's Linux GNOME shadow backend: Mutter's ScreenCast and RemoteDesktop APIs on the session bus (no portal), PipeWire frames, libei input (RemoteDesktop.ConnectToEIS, Mutter 45 and newer), the session's sound, PAM logins of the session's owner only, the server ends with 0 when GNOME stops the sharing, no busy loop while clients are connected; and c6d03209e: the X11 and Mutter subsystems in one build; since release-20261104.1 the picture of a fresh stream is never black (the cursor is drawn into it, GNOME/mutter#5179), a monitor's layout change is followed, the lock keys a Synchronize sets are kept, and WinPR's journald log appender builds (#14029), the first that finds a monitor wins, `/subsystem` lists or forces them; since release-20261106.1 the session's clipboard on Mutter (text, HTML, images, no files) and sound and a microphone through PipeWire on both subsystems | `test/linux-host.sh` (gnome, xorg) | [FreeRDP#14006](https://github.com/FreeRDP/FreeRDP/issues/14006) |
| `avm` | 20261119.6 [`060f61204`](https://github.com/congzhangzh/avm/commit/060f612045132f2b0ba747dc74de6ba09f69386b) | AVM (AV2 reference) main, our fork | its release {version} on congzhangzh/avm: libavm, AV2's reference encoder and decoder, with our realtime speed work (cpu-used 9 for screens, 10 for camera-like content, tiles packed on the encoder's threads); built with the two ML encoder experiments off (no TensorFlow Lite), as its release kit does | its release kit's gate (56/56 decode vectors on x86_64, aarch64, wasm), then here the AV2 session on the Windows host (`test/windows-host.ps1`) | — |
| `xrdp` | 20261110.1 [`2e975a4ea`](https://github.com/congzhangzh/xrdp/commit/2e975a4ea8cee93b9563ce4950c98eb0af6e26e5) | xrdp devel @ 5943357a (2026-10-14) | 132 commits on their way upstream: AV2 with libavm, 4 reference frames by default (`[AV2] dpb_size`), rate control q/cq/cbr/vbr for AV1 and AV2 (`rate_control`) (avm-6e's encoder; AV2 sent as FreeRDP merged it, under the AV1 codec ID with FRDP_2, since release-20261110.1; built with --enable-av2, off in the codec order until the server puts it first), Wayland sessions (wlup: sway, GNOME, KDE), GNOME and KDE with a monitor per RDP monitor and the client's primary as their own (branches feature-wlup-mutter-multimon, feature-wlup-kwin-multimon), and a max_fps setting for them, KWin 6.8's custom modes (kde_output_management_v2 22), AV1 with 4:4:4, encoder paced by the client's frame acknowledgements, Opus sound fixes (#3922: 2 of its 3 commits); plus the JPEG quality byte compared as unsigned, so it builds on ARM64 (branch caps-jpeg-quality-unsigned) | the login test, Xorg and Wayland, on x86_64 and ARM64; the ARM64 fix also by a build with -funsigned-char, which fails without it | [xrdp#3904](https://github.com/neutrinolabs/xrdp/issues/3904) [xrdp#3911](https://github.com/neutrinolabs/xrdp/issues/3911) [xrdp#3912](https://github.com/neutrinolabs/xrdp/issues/3912) [xrdp#3913](https://github.com/neutrinolabs/xrdp/issues/3913) [xrdp#3914](https://github.com/neutrinolabs/xrdp/issues/3914) [xrdp#3915](https://github.com/neutrinolabs/xrdp/issues/3915) [xrdp#3922](https://github.com/neutrinolabs/xrdp/issues/3922) |
| `mutter` | 51.0-1.fc45 | Fedora 45's 51.0-1.fc45 | an opt-in for Fedora 45: Fedora's own source package plus our fix for a Wayland window that lands on the wrong monitor when the monitor layout moves its monitor (2 commits, patches/mutter/0001-0002: the main monitor from the newest pending move after a layout change, also when the client acks an older configure; as of 2026-10-28) and upstream's open fix for touchpad scrolling through libei (3 commits, patches/mutter/0003-0005, merge request !5431 as of 2026-11-14: a scroll step smaller than a wheel notch was dropped, now it scrolls smoothly), release 1.0kit2, so Fedora's next update replaces it | 20 of 20 runs of the All screens check on the right monitor (stock 51.0: 1 of 10 wrong; 0 of 11 vs 5 of 7 with the server on one CPU); scrolling from the web client into a GTK app, on GNOME 50.5 with !5431: 50 touchpad steps worth 2 notches scroll 1.65 notches (2.01 with the SDL client's own fix), 0 without, the mouse wheel 3 of 3 either way; build/build-mutter.sh installs it with Fedora's gnome-shell | [mutter#5162](https://gitlab.gnome.org/GNOME/mutter/-/issues/5162) [mutter!5438](https://gitlab.gnome.org/GNOME/mutter/-/merge_requests/5438) [mutter!5431](https://gitlab.gnome.org/GNOME/mutter/-/merge_requests/5431) |
| `freerdp_tk` | 20261123.3 [`5316ff87e`](https://github.com/congzhangzh/freerdp-tk/commit/5316ff87ecd8ebb2d4e325c9f01f88c75d23e6cf) | its release 20261123.3 | our own connection window (Tkinter), shipped with the clients and their Python; `freerdp-tk` / `freerdp-tk.cmd` starts it. Since 0.3.0 it keeps passwords in the system's own store (Credential Manager, Keychain, Secret Service or KWallet) through keyring: the kit bundles keyring and what it needs on each OS, at the versions and SHA-256 of freerdp-tk's own uv.lock (`build/launcher.sh`, add_tk_deps) | the smoke test loads it with the bundled Python on every distribution; the build imports keyring and its backend's libraries with it (Linux, macOS) | — |
| `sdl3_wasm` | 3.4.18+timer [`1d615c14f`](https://github.com/congzhangzh/SDL/commit/1d615c14f95a3389bf0026e719144ad51378e40c) | SDL `release-3.4.18` | 1 commit: the Emscripten timers are safe to use from any thread. Since 4d8f84f161 (in 3.2.30 and 3.4) they run with pthreads too, but a timeout belongs to the thread that set it: a timer removed from another thread fired through a freed entry ("table index is out of bounds" in `SDL_Emscripten_TimerHelper`), in about 1 of 3 first sessions. 3.4.18 already has upstream's `FS.mkdir("/tmp/filedrop")` guard, which 3.2.30 needed backported (a second window, FreeRDP's retry dialog, threw `EEXIST` and hung a JSPI client after a network drop) | freerdp-web's whole suite on Asyncify and JSPI builds, 28 of 28 runs, `test-capture` and `test-reconnect` included, with the page's pointer-event fix (SDL 3.4 reads the mouse from pointer events); `SDL_timer.c` compiles with `-Werror` | [SDL#16587](https://github.com/libsdl-org/SDL/issues/16587) |
| `freerdp_web` | 20261117.2 [`42e849537`](https://github.com/congzhangzh/freerdp-web/commit/42e8495371acdd020c10a2f64bb25179c006caf4) | its release 20261117.2 | our own page, taken by its release tag | its unit tests and page checks (freerdp-web CI), then the web login test | — |
| `libei` | 1.6.0 `8a46bf3d4` | its release 1.6.0 | unchanged, pinned by its tag's commit; the client library alone, built static for the Linux host (AlmaLinux 9 has none) | the Linux host's GNOME test (keys typed through libei) | — |
| `libpng` | 1.6.59 [`cd952f49f`](https://github.com/pnggroup/libpng/commit/cd952f49f95bb27154ae77dbb103032d95f6e580) | its release 1.6.59 | unchanged, pinned by its tag's commit; built static for the Linux host: WinPR's PNG <-> bitmap for the clipboard (WINPR_UTILS_IMAGE_PNG) | `build/check-portable.sh` (no libpng from the system) | — |
| `librfxcodec` | [`0badc062e`](https://github.com/neutrinolabs/librfxcodec/commit/0badc062e96d170af57870480a4aa7cf469302b0) | xrdp's submodule | unchanged: the commit `xrdp` uses | built with xrdp | — |
| `libpainter` | [`379b8fbf4`](https://github.com/neutrinolabs/libpainter/commit/379b8fbf40f309829364bf3414d721f9ba77766d) | xrdp's submodule | unchanged: the commit `xrdp` uses | built with xrdp | — |
| `xorgxrdp` | 20261018.1 [`59d0735c4`](https://github.com/neutrinolabs/xorgxrdp/commit/59d0735c4321b5baff3feaa980a01f78a1c1e96f) | xorgxrdp devel | unchanged: the development commit whose module interface `xrdp` needs | the Xorg login | — |
| `x264` | `b35605ace` | x264 `stable` branch | unchanged: x264 has no releases | the xrdp login tests (H.264) | — |
| `pipewire_xrdp` | 0.2 [`748f562d6`](https://github.com/neutrinolabs/pipewire-module-xrdp/commit/748f562d616590c678d5b06722f3fe5ae9707465) | release v0.2 | unchanged, pinned by its tag's commit; built for Fedora only, which does not package it | built in the Fedora xrdp jobs | — |
<!-- pins: end -->

## Build

```sh
./build.sh            # needs podman or docker; writes dist/sdl3-freerdp-<version>-linux-<arch>.tar.xz
```

The build runs in an AlmaLinux 9 container (glibc 2.34), and links every
library statically except glibc, libgcc_s and libpulse. SDL3 opens X11, Wayland and
its audio backends at runtime, so the same binary works in X11 and Wayland
sessions. `build/check-portable.sh` fails the build if the client needs
any other host library, needs a newer glibc, or exports library symbols.

The archive contains the client, the licences of every component inside
it, and a `MANIFEST` with the versions, hashes and build options.

### Rebuilding quickly

Every build keeps what it can between runs:

| Kept | Where | Off with |
|---|---|---|
| downloads | `~/.cache/rdp-release-kit/sources` | (delete it) |
| built dependencies, rebuilt when their pin or compiler changes | each build's work tree | (delete it) |
| compiled objects (ccache) | `~/.cache/rdp-release-kit/ccache/<build>` | `CCACHE=off` |
| build tools: a builder image per build and distribution, made again after a week or when `build/tools.sh` or `deps/` change | `rdp-release-kit-<build>:<image>` | `BUILDER=off` |

The client and the packages are still configured and built from scratch
on every run, as a release must be; ccache makes that cheap, and a build
from the cache is byte for byte the build without it. `KIT_CACHE=<dir>`
moves the Windows and xrdp work trees and caches elsewhere.

To build a source from a local checkout instead of its pin, edits
included, set `SRC_<name>` for one run or list it in `sources.local`
(never committed):

```sh
SRC_freerdp=$HOME/src/FreeRDP ./build.sh                       # the Linux client
SRC_freerdp=$HOME/src/FreeRDP ./build-windows.sh x86_64        # the Windows client
SRC_freerdp=$HOME/src/FreeRDP ./build-wasm.sh                  # the web client
SRC_xrdp=$HOME/src/xrdp SRC_xorgxrdp=$HOME/src/xorgxrdp \
    ./build-xrdp.sh debian:13                                  # the xrdp packages
echo "freerdp dir $HOME/src/FreeRDP" > sources.local           # every run
```

The checkout's files (those git knows, tracked or new, its submodules'
too) are copied by content, so an unchanged file keeps its time stamp,
and the build tree of a local source is kept and not configured again
while the options stay the same: Ninja or make recompiles only what
changed. `LTO=off` (with a local FreeRDP) skips link-time optimisation;
the Windows and web clients keep ThinLTO's cache between links instead.
The result says so: `-local` in a client's name and an `OVERRIDE` line in
its `MANIFEST`, release `0local1` in an xrdp package's version. CI
refuses any override (`test/overrides.sh` checks that).

Measured with 8 build threads, before these changes → now (the edit: a
new function in one file, so it compiles and links for real):

| | rebuild, nothing changed | one file edited, local source |
|---|---|---|
| Linux client | 36 s → 26 s | 21 s → 5.5 s (`LTO=off`) |
| Windows client (x86_64) | 56 s → 15 s | 5.1 s (ThinLTO, cached), 3.3 s (`LTO=off`) |
| web client | 145 s → 124 s | 55 s → 46 s, of which Binaryen's post-link passes 22 s |
| xrdp packages (debian:13; measured on the preview, now the only xrdp) | 101 s → 43 s | 7 s (xrdp and xorgxrdp local) |

A local xrdp build installs xrdp with its files' time stamps (xorgxrdp
includes its headers from there) and compresses its packages with
`xz -1` (default xz: 6 s for xrdp's).

## Windows client

```sh
./build-windows.sh            # dist/sdl3-freerdp-<version>-windows-{x86_64,aarch64}.zip
```

Cross-compiled in a Debian container with
[llvm-mingw](https://github.com/mstorsjo/llvm-mingw) (clang, libc++, UCRT),
whose one toolchain covers x86_64 and native ARM64 Windows. Every library
is linked statically, with libc++, so the zip holds one `.exe` that needs
only Windows' own DLLs; `build/check-windows.sh` fails the build otherwise.
TLS comes from LibreSSL, as in FreeRDP's own Windows builds. The deprecated
3.x API is left out, as upstream's `scripts/mingw.sh` does.

Wine can not run it: Wine has no `_aligned_recalloc` in its UCRT yet.

## Web client (preview)

```sh
./build-wasm.sh                 # dist/wasm/web/ (the page) and dist/wasm/freerdp-web-<version>.zip
test/wasm-session.sh dist/wasm/web <freerdp-web>/rdp-gateway.sh   # log in from a browser
```

FreeRDP's SDL3 client compiled with Emscripten (6.0.13, pinned by digest),
with the [freerdp-web](https://github.com/congzhangzh/freerdp-web) page and
its passkey vault for saved hosts, both pinned by commit in `sources.lock`.
AV1 is decoded with the browser's WebCodecs, dav1d where those cannot. The
page works from a host that cannot send COOP/COEP headers, such as GitHub
Pages: a service worker adds them for the client's threads.

A browser cannot open TCP connections, so the page reaches the RDP server
through a WebSocket gateway, best in one step over SSH with websockify on
the server (nothing to install on your computer but ssh):

```sh
ssh -tt -L 127.0.0.1:3390:127.0.0.1:3390 user@server websockify 127.0.0.1:3390 127.0.0.1:3389
```

then connect the page to `127.0.0.1:3390`. For the kit's shadow server, use 3388
in place of 3389 (3389 is xrdp's and the system's own RDP server's). From the published page, Chrome
asks whether the site may access other apps and services on this device:
allow it, that is how the page reaches the gateway on 127.0.0.1 (Chrome's
Local Network Access protection). freerdp-web's `rdp-gateway.sh` runs that
line; its README explains each part and the risks: this is a hobby project,
and keeping your servers safe is up to you.

`test/wasm-session.sh` tests it the way a user runs it: the page from a
plain static server without COOP/COEP, the gateway from `rdp-gateway.sh`,
and an RDP server reachable only through SSH (the kit's xrdp in a
disposable container); it passes when the browser's login starts an Xorg
session on the server. With `PAGE_URL=` it tests the published page
instead, granting the local network permission as a user would; CI does
that after every deploy. The test's ssh ignores your `~/.ssh/config`, so
nothing of yours (agent, keys, proxies) reaches the throwaway server.

`SERVER=gnome test/wasm-session.sh …` logs in to GNOME on Wayland instead:
gnome-shell headless with gnome-remote-desktop, in an unprivileged container
(`test/gnome/`; no systemd: the session starts its own bus and PipeWire). Its
client connects without the clipboard channel, because gnome-remote-desktop
aborts when it cannot mount its FUSE clipboard, and a container has no
`/dev/fuse`.

`SERVER=xrdp-gnome` and `SERVER=xrdp-kde` log in through the kit's xrdp, in
AV1, to GNOME (Fedora 45, `test/xrdp-gnome/`) and to KDE Plasma (Arch with
KWin 6.8, `test/xrdp-kde/`, xrdp compiled there from the pinned sources). Both
run systemd as PID 1, so they need podman (rootless here; `PODMAN=` another).
KWin 6.8 renders in software with `/dev/udmabuf`, no GPU, DRM node or vgem;
the user running podman must be able to open it (group `kvm`).

**Several monitors: a ladder.** `test/screens.sh <page dir> <rdp-gateway.sh>
<tests dir> [server …]` runs, for each server, rung 1, the one-monitor login
above, and then, on a fresh server of the same kind, the rung above it:
freerdp-web's own All screens tests (`test-screens*.mjs` of the page; CI
takes the pinned page's), through `SCREENS=<tests dir> test/wasm-session.sh`.
Rung 2 is xrdp with Xorg, against xrdp's upstream release as Debian 13
ships it (`xrdp-original-xorg`; the packages dir `debian` makes
`wasm-session.sh` install Debian's own xrdp) and the kit's xrdp
(`xrdp-xorg`): two screens as a monitor each and as one
wide desktop, the second window's picture, mouse, keys, the captured cursor,
Reconnect, closing it. Rung 3 is GNOME and KDE on Wayland through the
kit's xrdp and its wlup module (`xrdp-gnome`, `xrdp-kde`): a desktop monitor
per screen, this window's the primary, the session's windows kept on it,
also after Reconnect. Its summary (`dist/test/screens/summary.md`) says at
once whether a failure is basic (rung 1 fails already) or one of several
monitors (rung 1 passes, the rung above fails). The CI's `screens` job runs
it for each server on a runner of its own; nothing waits for it, so a red
rung shows without holding a release back.
A rung whose only failures are known ones (`KNOWN` in `test/screens.sh`:
server, check, why) is marked KNOWN in the summary and stays green; any
other failed check still fails it. Known today: `xrdp-gnome`'s "the
session's windows stay on this window's screen", a race in Mutter (when
the layout moves the window's monitor, a pending Wayland move takes the
monitor under the window's old position, about half the time).

`DEMO_VIDEO=demo.mp4 test/wasm-session.sh …` (with any `SERVER=`)
records a demo instead, at 1920 × 1080 with sound: `test/wasm-demo.mjs`
plays a visit (the page, the SSH line, the form, the settings, a session,
typing in a terminal, then `webdemo`: Firefox on the server with web video
next to WebGL, Info, Disconnect), with a pointer, captions and a corner label
(`xrdp + Xfce`, `gnome-remote-desktop + GNOME Wayland`). Chrome's screencast
records the picture; a copy of the page's Web Audio output records the
sound; ffmpeg joins them. The media, Big Buck Bunny (© Blender Foundation,
CC BY 3.0) and the WebGL Aquarium (© Google, BSD), are fetched once by
`test/demo-assets.sh` into `~/.cache/rdp-release-kit/demo`, pinned, never
into the repository. Everything else is synthetic: the user, the password,
the throwaway server. Chrome runs muted, so nothing plays on this
computer's speakers; `KEEP=1` leaves the server running to look inside.
With `DEMO_SCREENS=1` (and `SERVER=xrdp-gnome`), `test/wasm-demo-screens.mjs`
records All screens instead: the page on the left of two 960 × 1080 screens,
Separate screens opens a window on the right one, and both windows' screencasts
are put side by side in one 1920 × 1080 video (no sound).

The demo videos are a kit product. `test/record-demos.sh [server …]` records
them with what a kit commit published (its web client and xrdp packages,
checked against their `SHA256SUMS`; `KIT_COMMIT=newest` for the newest),
encodes them at 720p, and writes `demo.json`. A recording passes only if
the session sent its picture, the remote desktop shows detail, and the web
video can be heard. Each is named for what it shows, the xrdp ones by which
xrdp: `xrdp-original-xfce` (xrdp's upstream release, Debian 13's own
packages), `xrdp-gnome`, `xrdp-gnome-screens` (two screens), `xrdp-kde`
(the kit's xrdp; `xrdp-preview-*` until 2026-10-27, which
`build/site-anchors.json` still knows), and `grd-gnome` (gnome-remote-desktop). After every green build on main, the
`demo` workflow records them, each on its own runner, and publishes them once as
`demo-<YYYYMMDD>.<N>-<kit commit>`; the rolling release carries them too, and
the site, published from a rolling release, shows that release's set. A push to the branch `demo-ci` records
without publishing.

To come: `test/fetch-release.sh <tag>`, fetching a release's web client and
xrdp packages (checked against `SHA256SUMS`), so the tests run on released
builds as easily as on local ones; xrdp with GNOME on Xorg.

**The site** (congzhangzh.github.io/freerdp-web/) is published from here,
by hand, from a kit release: *Run workflow* on `site` (the release, default
the latest; tick **publish**). `build/site.sh <release> <dir>` assembles it:
the release's web client and page, its demo videos with their lasting
addresses (`build/site-anchors.json`), `RELEASE`. Before it goes live,
freerdp-web's page test (`test-page.mjs` at the page's commit) and a browser
login from exactly those files to the release's xrdp, Asyncify and JSPI;
then it goes to freerdp-web's branch `gh-pages` as a commit of its own (a
deploy key for that repository, secret `FREERDP_WEB_PAGES_KEY`), which its
Pages serve, and a login from the published site checks it. Without
**publish**, every check runs and nothing goes live. freerdp-web holds the
page's source and its release tags, which the kit pins; until 2026-10-27 it
published the site itself, pulling the kit's pre-releases back, a cycle that
made every rename a two-repository dance. The pre-release
`web-<YYYYMMDD>.<N>-<kit commit>` (the tested client of the pinned page,
published once on each push) stays, for anyone who wants that client alone.
A pull request builds and tests only.

## Linux host

```sh
HOST=1 ./build.sh     # dist/freerdp-host-<version>-linux-<arch>.tar.xz
test/linux-host.sh gnome   # GNOME 50 headless (systemd, podman), the server as its user unit
test/linux-host.sh xorg    # Xfce on Xvfb, /subsystem:x11
```

FreeRDP's shadow server for a Linux desktop: it shares the session that is
already there, as the Windows and macOS hosts do. One binary has two
subsystems and takes, at start, the first that finds a monitor: Mutter (GNOME,
on Wayland or X11, through Mutter's own screen-cast and remote-desktop
interfaces: PipeWire for the picture, libei for the input, Mutter 45 and newer)
and X11 (any other X11 desktop); `/subsystem` lists them, `/subsystem:x11`
forces X11. It is built in the Linux client's AlmaLinux 9 image, with the
host's headers on top (`build/linux/host.Dockerfile`), and links FreeRDP,
OpenSSL, Opus, libaom (AV1), libavm (AV2), libei and libpng statically; from the
system it takes glibc 2.34 or newer, PAM, libsystemd, PipeWire and the X11
libraries (`build/check-portable.sh` checks that list). The archive holds a
systemd user unit, `freerdp-shadow.service`, on 127.0.0.1 only, restarted on
a failure but not after GNOME's Stop (the server then ends with 0), that logs
to the unit's journal through WinPR's journald appender (`WITH_SYSTEMD=ON`,
`WLOG_APPENDER=journald`, INFO), and a README (`build/linux/host-README.txt`):
install, reach it over SSH. Logins are the session owner's own account (PAM,
TLS security). The main way to install it on GNOME is the session manager
`freerdp-shadow-sesman` (FreeRDP's `WITH_SHADOW_SESMAN`) and its system unit
`freerdp-shadow-sesman.service`, which runs as root on 127.0.0.1:3388 and
hands each connection to the shadow server of the GNOME session of the user
it names (see [The session manager](#the-session-manager-runs-as-root)).

`test/linux-host.sh` runs it in a throwaway container with the kit's Linux
client on an Xvfb of its own. `gnome`: GNOME Shell headless with systemd as
PID 1 (podman `--systemd=always`), the package installed as its README says;
the checks read the server's lines from the unit's journal as its user would
(`journalctl --user -u freerdp-shadow`) and are the default subsystem
(Mutter), the `/subsystem` list, AV1 and AV2 frames once the screen changes
(an idle GNOME sends no full frame for a while, so a window with a clock
runs), the server's idle CPU with a client (under 20 %), keys typed through
libei, the session's sound (a 1 kHz tone played into WirePlumber's Dummy
Output, as there is no sound card) reaching the client in Opus as it plays,
another account refused, the sharing stopped from GNOME
(`org.gnome.Shell.Eval`, with GNOME Shell in `--unsafe-mode`) ending the unit
with 0 and no restart, those lines coming from WinPR's journald appender
(`_TRANSPORT=stdout`, identifier `freerdp-shadow-cli`, INFO at priority 6 and
WARN at 4), and the session manager installed as root as the README says: its
unit on 127.0.0.1:3388 only, tester handed to the shadow server of tester's
GNOME (logged in, AV1 frames), a user with no GNOME session refused, and,
once that user is in `freerdp-headless`, a headless GNOME started for them
(logged in, the shadow server's virtual monitor, frames with the screen
changing, its sound, still running after the client leaves). `xorg`: Xfce on
Xvfb, the unit's arguments with
`/subsystem:x11`, AV1 frames, another account refused. CI runs both, on an
x86_64 and an aarch64 runner, in a rootful podman container (`linux-host-test`); the release waits for them and
carries the archive.

### Installing the Linux host

Each release has `freerdp-host-<version>-linux-x86_64.tar.xz` and
`freerdp-host-<version>-linux-aarch64.tar.xz` for ARM64 (their checksums in the
release's `SHA256SUMS`). There are two ways to install it. Both listen on
127.0.0.1:3388, so install one or the other (or give the second a port of its
own, never 3389, which belongs to the system's own RDP servers: GNOME Remote
Desktop, xrdp):

- **[The session manager](#the-session-manager-runs-as-root)**, the main way on
  GNOME: one root service for every user of the computer, there before anyone
  logs in, headless sessions included.
- **[The user unit](#the-user-unit-your-own-desktop-no-root)**, without root, on
  GNOME or any other X11 desktop: it shares the desktop session you're in, for
  your own account only.

### The session manager (runs as root)

`freerdp-shadow-sesman` gives every user of the computer one port to their
own GNOME session, without the user unit; it is the way to install the Linux
host on GNOME. **It runs as root**, as a system service on 127.0.0.1:3388 (the
user unit's port too: install one or the other). It reads the client's first packet only (the user it
names, `Cookie: mstshash=<user>`), finds that user's GNOME Shell, starts the
shadow server in the user's own systemd manager (`freerdp-sesman-shadow`, on a
socket in `/run/user/<uid>`) unless it runs already, drops to the user and
relays the connection. It never sees a password: TLS and the login stay in
the shadow server (PAM, the session's owner only). A user with no GNOME
session gets a headless GNOME Shell with a monitor of its own if they are in
the group `freerdp-headless` (the unit's `--headless-group`; it does nothing
until you make the group: `sudo groupadd -f freerdp-headless`,
`sudo usermod -aG freerdp-headless <user>`), and is refused otherwise. The
headless session keeps running after the client leaves, so the next
connection finds the same desktop. As root and before any login, it reads
nothing but that first packet; still, keep the port on 127.0.0.1 (over SSH) or
private. Install it from the same archive,
as root, in `/opt/freerdp-host` (a root service must not run files a user can
change):

```sh
sudo rm -rf /opt/freerdp-host   # an earlier version, if any
sudo tar -xJf freerdp-host-*-linux-$(uname -m).tar.xz -C /opt
sudo mv /opt/freerdp-host-*-linux-$(uname -m) /opt/freerdp-host
sudo chown -R root:root /opt/freerdp-host
sudo cp /opt/freerdp-host/freerdp-shadow-sesman.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now freerdp-shadow-sesman.service
```

Reach it over SSH (`ssh -N -L 13388:127.0.0.1:3388 user@server`),
log in with your own account. Its log: `sudo journalctl -u freerdp-shadow-sesman`;
the shadow server's: `journalctl --user -u freerdp-sesman-shadow`. Remove it with
`sudo systemctl disable --now freerdp-shadow-sesman.service`, then delete
`/etc/systemd/system/freerdp-shadow-sesman.service` and `/opt/freerdp-host`.

### The user unit: your own desktop, no root

Install it for your own account, in the desktop session you want to share (the
archive's `README.txt` says the same):

```sh
tar -xJf freerdp-host-*-linux-$(uname -m).tar.xz
mkdir -p ~/.local/opt ~/.config/systemd/user
rm -rf ~/.local/opt/freerdp-host   # an earlier version, if any (your settings stay)
mv freerdp-host-*-linux-$(uname -m) ~/.local/opt/freerdp-host
cp ~/.local/opt/freerdp-host/freerdp-shadow.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now freerdp-shadow.service
```

It starts with the desktop session (GNOME starts `graphical-session.target`)
and logs to the unit's journal: `journalctl --user -u freerdp-shadow` (`-f`
to follow it) shows what it shares and who logs in. A desktop that does not
start that target (Xfce, MATE) starts it from its autostart:
`systemctl --user import-environment DISPLAY XAUTHORITY && systemctl --user start freerdp-shadow`.
Stopping the sharing from GNOME's top bar ends the server and it stays
stopped; `systemctl --user restart freerdp-shadow` brings it back.

**Keep it on 127.0.0.1 and reach it over SSH.** The unit binds the server to
the loopback interface only (`/bind-address:127.0.0.1`); do not change that
to open port 3388 to the network (see [Deploying a server](#deploying-a-server-keep-rdp-off-the-internet)).
From the client:

```sh
ssh -N -L 13388:127.0.0.1:3388 user@server &
sdl-freerdp /v:127.0.0.1:13388 /u:user
```

The login is the account whose desktop it is, checked by the system's PAM
over TLS; any other account is refused. Remove it with
`systemctl --user disable --now freerdp-shadow.service`, then delete
`~/.config/systemd/user/freerdp-shadow.service` and `~/.local/opt/freerdp-host`.

Where the journal is kept in memory only (no `/var/log/journal`), journald
keeps no file per user and `journalctl --user` may show nothing: read the
server's lines as root (`sudo journalctl -t freerdp-shadow-cli`), or set
`Storage=persistent` in `/etc/systemd/journald.conf`.

## xrdp packages

```sh
./check-deps.sh               # does each release have what the build needs?
./build-xrdp.sh               # dist/xrdp/<release>/*.deb or *.rpm, for every release in distros.list
./build-xrdp.sh debian:13     # or just one
test/xrdp-session.sh debian:13   # install in a fresh container, log in over RDP: Xorg, then Wayland
```

The kit builds one xrdp, ours: xrdp's development branch with the work
that is on its way upstream, picked on the fork as a release
(`release-<YYYYMMDD>.<N>`, `xrdp` in `sources.lock`, with its two
submodules): Wayland sessions (the wlup module: sway, GNOME through
Mutter's remote desktop API, KDE Plasma through KWin's protocols), GNOME
and KDE with a monitor per RDP monitor, AV1 (FreeRDP's GFX extension, with
4:4:4), smoother video on slow links (the encoder is paced by the client's
frame acknowledgements), Opus sound fixes. xorgxrdp is built from its
development branch, whose module interface it needs. Until 2026-10-27 the
kit also built xrdp's release, 0.10.6.1, as a second line, and this one as
a preview; the preview is now the release, and the pre-releases and
packages lost "preview" from their names (`xrdp-<YYYYMMDD>.<N>-<kit
commit>`).

The packages are built in a stock container of each release, against that
release's PAM, OpenSSL, X11 libraries and Xorg server (xorgxrdp is an Xorg
driver and must match its server exactly). x264 (H.264) and Opus are built
from `sources.lock` and linked statically, because not every release ships
them (Fedora has no x264); Fedora's packages come with PipeWire's xrdp
module (`pipewire-module-xrdp`, a session's sound), which Debian and Ubuntu
package themselves.

What each release needs is in two plain lists, one package per line with
the reason: [`deps/deb.txt`](deps/deb.txt) for Debian and Ubuntu,
[`deps/rpm.txt`](deps/rpm.txt) for Fedora. `check-deps.sh` prints, for each
release, every listed package with the version the release has, and every
run-time dependency of the built packages with the version that would be
installed, each line starting with `ok` or `MISSING`. Run it first when
adding a release to [`distros.list`](distros.list).

The packages are named `xrdp` and `xorgxrdp` and take the place of the
distribution's packages of the same name. Their version says what they
are built from, `0.10.80+<pin's version>.<commit>`, with a `0kit<N>`
release suffix (N: the number of kit commits, so every kit change sorts
higher): the `+` sorts it after 0.10.80 and after the kit's earlier
preview packages (`0.10.80~preview.<N>.<commit>`), which it upgrades, and
before xrdp's next release. Services are not started on install, and the
host keys are made on install, never shipped.

The login screen (`xrdp.ini`) lists `[Xorg]` and the Wayland sessions the
release has: `[GNOME]` (code 31), `[KDE]` (code 32) and `[Wayland]` (sway,
code 30); `sesman.ini` starts them. The first one is the default (xrdp
starts it for a client that sends a password). Fedora is Wayland first: its
desktops have no Xorg session, so the Wayland sessions come first, GNOME is
the default, and `xrdp` only suggests `xorgxrdp` (dnf installs recommended
packages, and Fedora's own xorgxrdp is built for xrdp 0.10). Debian and
Ubuntu list `[Xorg]` first, and `xrdp` recommends `xorgxrdp`. The releases in
`distros.list` are marked for what they cannot have: `no-sway` (sway older
than 1.11, wlroots 0.19: the module captures the screen through the
`ext-image-copy-capture` protocols), `no-kde` (plasma-wayland-protocols
older than 1.21: no output device registry, which the KWin backend needs;
built without it) and `no-av1` (no libaom 3.0: built without AV1, clients
fall back to H.264). Marks go after the image, as many as needed:
`debian:13  no-sway no-kde  <note>`. Debian 12 is not built: GNOME's
backend needs GNOME 46 or newer.

`test/xrdp-session.sh` logs in twice: to an Xorg session (xorgxrdp, an
xterm, picked with `autorun=Xorg`), then to a Wayland one (sway, headless, with a terminal), checking
that sesman starts sway for the user and that the module captures its
output at the client's size; a release marked `no-sway` skips the second.
It also checks that the package has the Wayland module and that the login
screen lists GNOME, and KDE unless the release is marked `no-kde`, and
which session is the default (GNOME on Fedora, Xorg elsewhere). The
GNOME and KDE logins themselves run in `test/wasm-session.sh`
(`SERVER=xrdp-gnome`, `SERVER=xrdp-kde`) and the demos.

How to install them, release by release, is in the notes of every rolling
release (`build/xrdp-install-notes.sh` writes that table).

## Container engine

The scripts use docker when it is installed, podman otherwise (or set
`ENGINE`). Every result above was tested with docker. With rootless podman
the builds work, but the xrdp login test fails on Fedora (no Xorg session
starts); that is not solved yet.

## Performance on different hardware

One build per CPU architecture is enough. The hot paths pick their code
at runtime for the CPU they run on: FreeRDP's primitives (colour
conversion, codecs) use SSE/AVX2 or NEON when present, and dav1d has
hand-written assembly with runtime CPU detection. The kit builds for the
architecture baseline, never `-march=native`, so the binary runs on any
CPU of the architecture. AV1 on the graphics card needs no FFmpeg: the
clients decode through D3D11VA (Windows), VA-API (Linux) and VideoToolbox
(macOS, M3 and newer), the shadow servers encode through Media Foundation
(Windows) and VA-API (Linux); dav1d and libaom take over where the card
can't. `/codec-list` shows what a computer has.

Not included yet: H.264 in the clients (OpenH264 is only usable through Cisco's binary,
which FreeRDP (3.32.2 and the preview) does not find under its current name
`libopenh264.so.8`; the Windows and macOS shadow servers encode H.264 with the
system's own encoder), smart cards, Kerberos, USB redirection, FUSE file
clipboard.

## Deploying a server: keep RDP off the internet

RDP servers are a frequent attack target, and xrdp in particular changes
quickly. Do not expose an RDP port (3389, or the shadow server's 3388) to
the network. Let the server listen on
the loopback interface only, and reach it through SSH, which already
handles authentication, keys and brute-force protection:

```ini
; /etc/xrdp/xrdp.ini
port=tcp://.:3389          ; 127.0.0.1:3389 only
```

```sh
# on the client
ssh -N -L 3389:127.0.0.1:3389 user@server &
sdl-freerdp /v:127.0.0.1:3389 /u:user
```

The same applies to gnome-remote-desktop and any other RDP server.

## Licences

The kit itself (its scripts, workflows and documents) is licensed under
the Apache License 2.0: see [LICENSE](LICENSE) and [NOTICE](NOTICE).

The client combines FreeRDP (Apache-2.0), SDL3 and SDL3_ttf (zlib),
FreeType (FTL), OpenSSL (Apache-2.0), Opus and dav1d (BSD), zlib and
jansson (MIT-style). Their licence texts are in each archive under
`licenses/`.
