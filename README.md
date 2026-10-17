# rdp-release-kit

Reproducible, portable builds of open-source RDP software, pinned to
upstream release tags. This is an unofficial community build kit: it is not
affiliated with the FreeRDP or xrdp projects, and it changes no upstream
source.

## What it builds

| Artifact | Status | Runs on |
|---|---|---|
| `sdl-freerdp` (FreeRDP's SDL3 client), with AV1 (dav1d) and Opus | step 1 (this) | Linux x86_64 / aarch64 with glibc ≥ 2.34 and PulseAudio's `libpulse.so.0`: RHEL/Rocky/Alma 9, Debian 12, Ubuntu 22.04, Fedora 35 and newer |
| `sdl-freerdp.exe`, the same client for Windows, with AV1 and Opus | step 3 | Windows 10 and 11, x86_64 and ARM64 |
| FreeRDP WebAssembly client | waiting for upstream: the Emscripten build is not in a FreeRDP release yet | any current browser |
| xrdp + xorgxrdp native packages (.deb / .rpm) | step 2 | Debian testing, 13, 12; Ubuntu 26.10, 26.04, 24.04; Fedora 45, 44, 43 |

Every source is pinned in [`sources.lock`](sources.lock) with its SHA-256
and is built from source. FreeRDP's hash is the one upstream publishes with
its release.

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
