# rdp-release-kit

Reproducible, portable builds of open-source RDP software, pinned to
upstream release tags (the web client is a preview, built from upstream pull
requests until they are released). This is an unofficial community build
kit: it is not affiliated with the FreeRDP or xrdp projects, and it changes
no upstream source.

## What it builds

| Artifact | Status | Runs on |
|---|---|---|
| `sdl-freerdp` (FreeRDP's SDL3 client), with AV1 (dav1d) and Opus | step 1 (this) | Linux x86_64 / aarch64 with glibc ≥ 2.34 and PulseAudio's `libpulse.so.0`: RHEL/Rocky/Alma 9, Debian 12, Ubuntu 22.04, Fedora 35 and newer |
| `sdl-freerdp.exe`, the same client for Windows, with AV1 and Opus | step 3 | Windows 10 and 11, x86_64 and ARM64 |
| FreeRDP web client (WebAssembly) with the [freerdp-web](https://github.com/congzhangzh/freerdp-web) page | preview: FreeRDP master + the open Emscripten pull requests #13728, #13731, #13732, #13733 | a current browser (tested: Chrome); served from GitHub Pages |
| xrdp + xorgxrdp native packages (.deb / .rpm) | step 2 | Debian testing, 13, 12; Ubuntu 26.10, 26.04, 24.04; Fedora 45, 44, 43 |

Every source is pinned in [`sources.lock`](sources.lock) with its SHA-256
and is built from source. FreeRDP's hash is the one upstream publishes with
its release.
`./check-upstream.sh` lists the sources upstream has released newer
versions of (a daily job opens an issue for each). How a change becomes a
release, and what each release guarantees: [`docs/RELEASE.md`](docs/RELEASE.md).

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

Downloads are kept in `~/.cache/rdp-release-kit/sources`, each built
dependency in the work tree (rebuilt only when its pin or compiler
changes), and compiled objects by ccache in `~/.cache/rdp-release-kit/ccache`
(`CCACHE=off` builds without it). FreeRDP is configured from scratch on
every build, as a release must be; ccache makes that rebuild cheap.

To build a source from a local checkout instead of its pin, edits
included, set `SRC_<name>` for one run or list it in `sources.local`
(never committed):

```sh
SRC_freerdp=$HOME/src/FreeRDP ./build.sh               # the Linux client
SRC_freerdp_preview=$HOME/src/FreeRDP ./build-wasm.sh  # the web client
echo "freerdp dir $HOME/src/FreeRDP" > sources.local   # every run
```

The checkout's files (those git knows, tracked or new) are copied by
content, so an unchanged file keeps its time stamp, and the build tree of
a local source is kept and not configured again while the options stay
the same: Ninja recompiles only what changed. `LTO=off` (with a local
FreeRDP) skips link-time optimisation for the quickest Linux rebuild; a
local web client keeps ThinLTO's cache between links. The result says
so: `-local` in its name and an `OVERRIDE` line in its `MANIFEST`. CI and
`v*` tags refuse any override (`test/overrides.sh` checks that).

An edit to one FreeRDP file, measured with 8 build threads: the Linux
client in 5.5 s with `LTO=off` (21 s before: 8.5 s for the LTO link, 9 s
for xz), the web client in about 46 s (55 s before), most of it
Emscripten's post-link optimisation (Binaryen, 22 s).

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

FreeRDP's SDL3 client compiled with Emscripten (6.0.12, pinned by digest),
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

then connect the page to `127.0.0.1:3390`. From the published page, Chrome
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

`DEMO_VIDEO=demo.mp4 test/wasm-session.sh …` (with or without `SERVER=gnome`)
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

To come: `test/fetch-release.sh <tag>`, fetching a release's web client and
xrdp packages (checked against `SHA256SUMS`), so the tests and the demos
run on released builds as easily as on local ones; and the demo videos as a
kit product, recorded here and handed to freerdp-web with the client (until
then freerdp-web pins its own copies, in its `demo-media-1` release). Demos to come: xrdp with GNOME on Xorg (its session needs systemd as PID 1:
Podman, or more privileges than these containers get), and the next xrdp,
with Xfce and with GNOME headless (gnome-shell without changes), next to
today's gnome-remote-desktop baseline.

The web client is published on freerdp-web's own GitHub Pages; this kit
builds and tests it. On each push the wasm job hands the tested client of
the pinned page over as a pre-release `web-<page commit>` (with the xrdp
packages for the published site's login check); freerdp-web's workflow
downloads it and publishes it, only on purpose (a `v*` tag there, or *Run
workflow* with **publish**). This repository's Pages only redirect there, to
the same origin, so saved hosts come along. A pull request builds and tests
only.

## xrdp packages

```sh
./check-deps.sh               # does each release have what the build needs?
./build-xrdp.sh               # dist/xrdp/<release>/*.deb or *.rpm, for every release in distros.list
./build-xrdp.sh debian:13     # or just one
test/xrdp-session.sh debian:13   # install in a fresh container, log in over RDP, check the session
```

The packages are built in a stock container of each release, against that
release's PAM, OpenSSL, X11 libraries and Xorg server (xorgxrdp is an Xorg
driver and must match its server exactly). x264 (H.264) and Opus are built
from `sources.lock` and linked statically, because not every release ships
them (Fedora has no x264). The xrdp and xorgxrdp tarballs must carry a
valid signature from xrdp's release key ([`signed.lock`](signed.lock),
[`keys/`](keys)).

What each release needs is in two plain lists, one package per line with
the reason: [`deps/deb.txt`](deps/deb.txt) for Debian and Ubuntu,
[`deps/rpm.txt`](deps/rpm.txt) for Fedora. `check-deps.sh` prints, for each
release, every listed package with the version the release has, and every
run-time dependency of the built packages with the version that would be
installed, each line starting with `ok` or `MISSING`. Run it first when
adding a release to [`distros.list`](distros.list).

The packages are named `xrdp` and `xorgxrdp`, with a `0kit1` release
suffix, and take the place of the distribution's packages of the same
name. Services are not started on install, and the host keys are made on
install, never shipped.

### Preview: the next xrdp

```sh
./build-xrdp.sh --preview debian:testing          # dist/xrdp-preview/<release>/
test/xrdp-session.sh --preview debian:testing     # the Xorg login above, then a Wayland one
```

The preview packages xrdp's development branch with the work that is on
its way upstream: Wayland sessions (the wlup module: sway, and GNOME
through Mutter's remote desktop API), AV1 (FreeRDP's GFX extension, with
4:4:4), smoother video on slow links (the encoder is paced by the client's
frame acknowledgements), Opus sound fixes. It is built from one fixed
commit (`xrdp_preview` in `sources.lock`, with its two submodules) and
xorgxrdp's development branch, whose module interface it needs. The
version says what it is, `0.10.80~preview.<preview number>.<commit>`
(the number is the pin's version column in `sources.lock`, raised with
every new pin, so newer previews upgrade older ones), and sorts before the
release, which replaces it. It is a preview: test it, don't run it
where a broken session costs you. The releases are in
[`distros-preview.list`](distros-preview.list) (GNOME's backend needs
GNOME 46 or newer, so not Debian 12); the extra build dependencies are in
`deps/deb-preview.txt` and `deps/rpm-preview.txt`.

`test/xrdp-session.sh --preview` logs in twice: to an Xorg session as for
the release, then to a Wayland one (sway, headless, with a terminal),
checking that sesman starts sway for the user and that the module
captures its output at the client's size.

Sway sessions need sway 1.11 or newer (wlroots 0.19): the module captures
the screen through the `ext-image-copy-capture` protocols, which older
wlroots lack. Debian 13 (sway 1.10) and Ubuntu 24.04 (sway 1.9) get the
preview for Xorg sessions; they are marked `no-sway` in the list, and the
test skips their sway login.

AV1 needs libaom 3.0 or newer from the release. Every release in the list
has it today (Debian 13: 3.12, Ubuntu 24.04: 3.8, Fedora 43: 3.13). Before
adding a release, run `./check-deps.sh --preview <image>`: if libaom is
MISSING, mark the release `no-av1` in the list. Its preview is then built
without AV1 (no libaom build or run-time dependency, and the package
description leaves AV1 out), and clients fall back to H.264. Marks go
after the image, as many as needed: `debian:13  no-sway no-av1  <note>`.

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
CPU of the architecture. Hardware video decoding (VA-API) would need FFmpeg
and is not part of these builds.

Not included yet: H.264 (OpenH264 is only usable through Cisco's binary,
which FreeRDP 3.32.2 does not find under its current name
`libopenh264.so.8`), smart cards, Kerberos, USB redirection, FUSE file
clipboard.

## Deploying a server: keep RDP off the internet

RDP servers are a frequent attack target, and xrdp in particular changes
quickly. Do not expose port 3389 to the network. Let the server listen on
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

The client combines FreeRDP (Apache-2.0), SDL3 and SDL3_ttf (zlib),
FreeType (FTL), OpenSSL (Apache-2.0), Opus and dav1d (BSD), zlib and
jansson (MIT-style). Their licence texts are in each archive under
`licenses/`.
