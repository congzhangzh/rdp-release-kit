# rdp-release-kit

Reproducible, portable builds of open-source RDP software, pinned to
upstream release tags. This is an unofficial community build kit: it is not
affiliated with the FreeRDP or xrdp projects, and it changes no upstream
source.

## What it builds

| Artifact | Status | Runs on |
|---|---|---|
| `sdl3-freerdp`, the FreeRDP SDL3 client, with AV1 (dav1d) and Opus | step 1 (this) | Linux x86_64 / aarch64 with glibc ≥ 2.34 and PulseAudio's `libpulse.so.0`: RHEL/Rocky/Alma 9, Debian 12, Ubuntu 22.04, Fedora 35 and newer |
| FreeRDP WebAssembly client | planned | any current browser |
| xrdp server packages per distribution | planned | — |

Every source is pinned in [`sources.lock`](sources.lock) with its SHA-256
and is built from source. FreeRDP's hash is the one upstream publishes with
its release.

## Build

```sh
./build.sh            # needs podman or docker; writes dist/sdl3-freerdp-<version>-linux-<arch>.tar.xz
```

The build runs in an AlmaLinux 9 container (glibc 2.34), and links every
library statically except glibc and libpulse. SDL3 opens X11, Wayland and
its audio backends at runtime, so the same binary works in X11 and Wayland
sessions. `build/check-portable.sh` fails the build if the client needs
any other host library, needs a newer glibc, or exports library symbols.

The archive contains the client, the licences of every component inside
it, and a `MANIFEST` with the versions, hashes and build options.

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
sdl3-freerdp /v:127.0.0.1:3389 /u:user
```

The same applies to gnome-remote-desktop and any other RDP server.

## Licences

The client combines FreeRDP (Apache-2.0), SDL3 and SDL3_ttf (zlib),
FreeType (FTL), OpenSSL (Apache-2.0), Opus and dav1d (BSD), zlib and
jansson (MIT-style). Their licence texts are in each archive under
`licenses/`.
