# rdp-release-kit

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

## What it builds

| Artifact | Channel | Runs on |
|---|---|---|
| `sdl-freerdp` (FreeRDP's SDL3 client), with AV1 (dav1d) and Opus, plus [freerdp-tk](https://github.com/congzhangzh/freerdp-tk) and its Python | preview: our FreeRDP preview, the same as the web client's (see the pins below) | Linux x86_64 / aarch64 with glibc ≥ 2.34 and PulseAudio's `libpulse.so.0`: RHEL/Rocky/Alma 9, Debian 12, Ubuntu 22.04, Fedora 35 and newer |
| `sdl-freerdp.exe`, the same client for Windows, with freerdp-tk and its Python | preview, the same | Windows 10 and 11, x86_64 and ARM64 |
| `sdl-freerdp`, the same client for macOS, with freerdp-tk and its Python | preview, the same | macOS 12 and newer, Apple Silicon (arm64) and Intel (x86_64) |
| FreeRDP web client (WebAssembly) with the [freerdp-web](https://github.com/congzhangzh/freerdp-web) page | preview: FreeRDP master + open pull requests (see the pins below) | a current browser (tested: Chrome); served from GitHub Pages |
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
| Linux client `sdl-freerdp` + `freerdp-tk` | freerdp 20261031.1, sdl3 3.4.18, sdl3_ttf 3.2.2, freetype 2.15.0, openssl 3.5.9, opus 1.6.1, dav1d 1.5.4, avm 20261030.4, zlib 1.3.2, jansson 2.15.1, freerdp_tk 0.3.2, python_linux_x86_64 3.13.17+20261021, python_linux_aarch64 3.13.17+20261021 | `build/check-portable.sh` (only glibc ≥ 2.34, libgcc_s and libpulse from the host), `test/smoke.sh` (starts and finds its libraries on Alma 9, Rocky 10, Debian 12/13, Ubuntu 22.04/24.04, Fedora 43, Tumbleweed, Arch; there the bundled Python loads Tk and freerdp-tk) |
| Windows client `sdl-freerdp.exe` + `freerdp-tk` | freerdp 20261031.1, sdl3 3.4.18, sdl3_ttf 3.2.2, freetype 2.15.0, libressl 4.4.0, opus 1.6.1, dav1d 1.5.4, avm 20261030.4, zlib 1.3.2, jansson 2.15.1, llvm_mingw 20261020, freerdp_tk 0.3.2, python_windows_x86_64 3.13.17+20261021, python_windows_aarch64 3.13.17+20261021 | `build/check-windows.sh` (needs only Windows' own DLLs) |
| macOS client `sdl-freerdp` + `freerdp-tk` | freerdp 20261031.1, sdl3 3.4.18, sdl3_ttf 3.2.2, freetype 2.15.0, openssl 3.5.9, opus 1.6.1, dav1d 1.5.4, avm 20261030.4, zlib 1.3.2, jansson 2.15.1, freerdp_tk 0.3.2, python_macos_arm64 3.13.17+20261021, python_macos_x86_64 3.13.17+20261021 | `build/check-macos.sh` (only macOS's own libraries and frameworks, minimum macOS 12.0, an ad-hoc signature); the bundled Python loads Tk and freerdp-tk; arm64 on macos-15, x86_64 on macos-15-intel |
| Windows host `freerdp-shadow-service` + `freerdp-shadow-cli` | freerdp_host 20261031.2, libressl 4.4.0, opus 1.6.1, dav1d 1.5.4, aom 3.15.2, avm 20261030.4, zlib 1.3.2, jansson 2.15.1, llvm_mingw 20261020 | `build/check-windows.sh`, then `test/windows-host.ps1` on a Windows Server 2025 runner: the service runs the server as SYSTEM on the console session, Windows-account logins, AV1, Ctrl+Alt+Del and the lock screen followed, a Unix socket; and the web client logs in through websockify |
| Web client + freerdp-web page | freerdp 20261031.1, sdl3_wasm 3.4.18+timer, sdl3_ttf 3.2.2, freetype 2.15.0, libressl 4.4.0, opus 1.6.1, dav1d 1.5.4, avm 20261030.4, zlib 1.3.2, jansson 2.15.1, freerdp_web 20261030.7 | `test/wasm-session.sh`: a browser logs in to xrdp through SSH + websockify, the page served without COOP/COEP headers (as GitHub Pages) |
| xrdp packages (.deb, .rpm) | xrdp 20261030.1, librfxcodec 0badc06, libpainter 379b8fb, xorgxrdp 20261018.1, x264 b35605a, opus 1.6.1, pipewire_xrdp 0.2, mutter 51.0-1.fc45 | `check-deps.sh`, then `test/xrdp-session.sh`: install in a fresh container of each release, log in over RDP: an Xorg session (xorgxrdp) with an xterm, then a Wayland one (sway, unless the release is marked no-sway) captured at the client's size; the login screen lists GNOME, and KDE unless no-kde; the default is GNOME on Fedora (Wayland first), Xorg elsewhere |

Pins that are not a plain upstream release:

| Source | Pin | Base | What it changes or fixes | How the change is tested | Upstream |
|---|---|---|---|---|---|
| `freerdp` | 20261031.1 [`b646cb806`](https://github.com/congzhangzh/FreeRDP/commit/b646cb806567af03436d309246021e1d34cc4a20) | FreeRDP master @ 670e10b29 (2026-10-28) | our release, picked from integration-latest-av2 on the fork (integration-latest plus the AV2 extension, FreeRDP#13925: the clients decode AV2 with libavm and offer it; the web client with a decoder-only libavm, through our av2-decoder-only commit); every client, native and web, builds it, not an upstream release; master has the Opus microphone fix #13810 that 3.32.2 lacks, upstream's hardening of 2026-10-28 (invalid order bounds, messages and fastpath input before activation, the brush cache, H.264 reset bounds, smartcard strings), and our merged AV1 #13731, sound #13732, H.264 through WebCodecs #13812, #13838, #13839, the Web Audio microphone #13811, no connection dialog window #13860, SDL3 clipboard events with every field set #13872 and hotkeys from the key event's own modifiers #13852. 4 commits of open pull requests for Emscripten builds (not compiled natively): clipboard #13733 (as of 2026-10-25), the MessageChannel yield #13864 (pollset_poll's yield waits on a MessageChannel task, not setTimeout's clamped 4 ms; as of 2026-10-26) and the page's monitors #13865 (the page splits the one canvas into a monitor per screen for the display layout; as of 2026-10-26). 1 commit of an open pull request for every client: the physical monitor size in millimetres #13805, and a fix of ours not yet proposed: a legacy bitmap wider than its rectangle is accepted again (xrdp pads bitmaps to a multiple of 4; master 343f23134, #13884, rejected them and dropped the session) (SDL3 sent pixels, so a 2880-pixel window was a 2.88 m monitor; now 0, "not given"; as of 2026-10-21) | the native clients' smoke and xrdp login tests (with /bpp:24 typing: legacy bitmaps), the web login test; before the pick: Linux and Windows clients built, xrdp logins on Fedora 45 (19/19) and Debian 13 (12/12), browser logins with Asyncify and JSPI (5/5 each); each pull request's own CI upstream | [FreeRDP#13733](https://github.com/FreeRDP/FreeRDP/issues/13733) [FreeRDP#13864](https://github.com/FreeRDP/FreeRDP/issues/13864) [FreeRDP#13865](https://github.com/FreeRDP/FreeRDP/issues/13865) [FreeRDP#13805](https://github.com/FreeRDP/FreeRDP/issues/13805) [FreeRDP#13925](https://github.com/FreeRDP/FreeRDP/issues/13925) |
| `freerdp_host` | 20261031.2 [`39bc96a1a`](https://github.com/congzhangzh/FreeRDP/commit/39bc96a1aff9ca6339ac47de6174a6df147a1f9e) | FreeRDP master @ 472f1901f (2026-10-30) | our release-20261030.2, picked from integration-shadow-win: the Windows shadow server's two build fixes, DXGI capture that follows the secure desktop, freerdp-shadow-service with Ctrl+Alt+Del, a Unix-socket listener on Windows, a refresh request answered with the whole screen, AV2 (FreeRDP#13925: libavm encodes, `/gfx-av2`) | `test/windows-host.ps1` (Windows Server 2025 runner) | [FreeRDP#13931](https://github.com/FreeRDP/FreeRDP/issues/13931) [FreeRDP#13932](https://github.com/FreeRDP/FreeRDP/issues/13932) [FreeRDP#13933](https://github.com/FreeRDP/FreeRDP/issues/13933) [FreeRDP#13934](https://github.com/FreeRDP/FreeRDP/issues/13934) [FreeRDP#13935](https://github.com/FreeRDP/FreeRDP/issues/13935) |
| `avm` | 20261030.4 [`caea56916`](https://github.com/congzhangzh/avm/commit/caea56916edcb3160c2f8cb8b89e99b8b12f28ab) | AVM (AV2 reference) main, our fork | its release {version} on congzhangzh/avm: libavm, AV2's reference encoder and decoder, with our realtime speed work (cpu-used 9 for screens, 10 for camera-like content, tiles packed on the encoder's threads); built with the two ML encoder experiments off (no TensorFlow Lite), as its release kit does | its release kit's gate (56/56 decode vectors on x86_64, aarch64, wasm), then here the AV2 session on the Windows host (`test/windows-host.ps1`) | [—#](https://github.com/—/issues/) |
| `xrdp` | 20261030.1 [`4986f5c75`](https://github.com/congzhangzh/xrdp/commit/4986f5c75272fd6c2746e606e9f9ea587fcf5942) | xrdp devel @ 5943357a (2026-10-14) | 128 commits on their way upstream: AV2 with libavm (avm-6e's encoder, FreeRDP's FRDP_2 / AV2 codec id; built with --enable-av2, off in the codec order until the server puts it first), Wayland sessions (wlup: sway, GNOME, KDE), GNOME and KDE with a monitor per RDP monitor and the client's primary as their own (branches feature-wlup-mutter-multimon, feature-wlup-kwin-multimon), and a max_fps setting for them, KWin 6.8's custom modes (kde_output_management_v2 22), AV1 with 4:4:4, encoder paced by the client's frame acknowledgements, Opus sound fixes (#3922: 2 of its 3 commits); plus the JPEG quality byte compared as unsigned, so it builds on ARM64 (branch caps-jpeg-quality-unsigned) | the login test, Xorg and Wayland, on x86_64 and ARM64; the ARM64 fix also by a build with -funsigned-char, which fails without it | [xrdp#3904](https://github.com/neutrinolabs/xrdp/issues/3904) [xrdp#3911](https://github.com/neutrinolabs/xrdp/issues/3911) [xrdp#3912](https://github.com/neutrinolabs/xrdp/issues/3912) [xrdp#3913](https://github.com/neutrinolabs/xrdp/issues/3913) [xrdp#3914](https://github.com/neutrinolabs/xrdp/issues/3914) [xrdp#3915](https://github.com/neutrinolabs/xrdp/issues/3915) [xrdp#3922](https://github.com/neutrinolabs/xrdp/issues/3922) |
| `mutter` | 51.0-1.fc45 | Fedora 45's 51.0-1.fc45 | an opt-in for Fedora 45: Fedora's own source package plus our fix for a Wayland window that lands on the wrong monitor when the monitor layout moves its monitor (2 commits, patches/mutter/: the main monitor from the newest pending move after a layout change, also when the client acks an older configure; as of 2026-10-28), release 1.0kit1, so Fedora's next update replaces it | 20 of 20 runs of the All screens check on the right monitor (stock 51.0: 1 of 10 wrong; 0 of 11 vs 5 of 7 with the server on one CPU); build/build-mutter.sh installs it with Fedora's gnome-shell | [mutter#5162](https://github.com/GNOME/mutter/issues/5162) [mutter!5438#](https://github.com/GNOME/mutter!5438/issues/) |
| `freerdp_tk` | 0.3.2 [`2f9058845`](https://github.com/congzhangzh/freerdp-tk/commit/2f9058845517f3a761575fa01635f56e5013dc0e) | its release 0.3.2 | our own connection window (Tkinter), shipped with the clients and their Python; `freerdp-tk` / `freerdp-tk.cmd` starts it. Since 0.3.0 it keeps passwords in the system's own store (Credential Manager, Keychain, Secret Service or KWallet) through keyring: the kit bundles keyring and what it needs on each OS, at the versions and SHA-256 of freerdp-tk's own uv.lock (`build/launcher.sh`, add_tk_deps) | the smoke test loads it with the bundled Python on every distribution; the build imports keyring and its backend's libraries with it (Linux, macOS) | — |
| `sdl3_wasm` | 3.4.18+timer [`1d615c14f`](https://github.com/congzhangzh/SDL/commit/1d615c14f95a3389bf0026e719144ad51378e40c) | SDL `release-3.4.18` | 1 commit: the Emscripten timers are safe to use from any thread. Since 4d8f84f161 (in 3.2.30 and 3.4) they run with pthreads too, but a timeout belongs to the thread that set it: a timer removed from another thread fired through a freed entry ("table index is out of bounds" in `SDL_Emscripten_TimerHelper`), in about 1 of 3 first sessions. 3.4.18 already has upstream's `FS.mkdir("/tmp/filedrop")` guard, which 3.2.30 needed backported (a second window, FreeRDP's retry dialog, threw `EEXIST` and hung a JSPI client after a network drop) | freerdp-web's whole suite on Asyncify and JSPI builds, 28 of 28 runs, `test-capture` and `test-reconnect` included, with the page's pointer-event fix (SDL 3.4 reads the mouse from pointer events); `SDL_timer.c` compiles with `-Werror` | [SDL#16587](https://github.com/libsdl-org/SDL/issues/16587) |
| `freerdp_web` | 20261030.7 [`6423b856f`](https://github.com/congzhangzh/freerdp-web/commit/6423b856f47fc73f59444d953697ee390e2e0e38) | its release 20261030.7 | our own page, taken by its release tag | its unit tests and page checks (freerdp-web CI), then the web login test | — |
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
CPU of the architecture. Hardware video decoding (VA-API) would need FFmpeg
and is not part of these builds.

Not included yet: H.264 (OpenH264 is only usable through Cisco's binary,
which FreeRDP (3.32.2 and the preview) does not find under its current name
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

The kit itself (its scripts, workflows and documents) is licensed under
the Apache License 2.0: see [LICENSE](LICENSE) and [NOTICE](NOTICE).

The client combines FreeRDP (Apache-2.0), SDL3 and SDL3_ttf (zlib),
FreeType (FTL), OpenSSL (Apache-2.0), Opus and dav1d (BSD), zlib and
jansson (MIT-style). Their licence texts are in each archive under
`licenses/`.
