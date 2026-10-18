# Release process

How the kit turns pinned upstream sources into tested, published builds,
and what other projects may rely on. The kit is the one place that builds:
consumers (for example the freerdp-web site) download its releases and
verify them; they never compile.

## Products and channels

| Product | Source | Channel | Release name |
|---|---|---|---|
| `sdl-freerdp`, Linux x86_64 / aarch64 | FreeRDP release tag | stable | `v<YYYY>.<MM>.<N>` |
| `sdl-freerdp.exe`, Windows x86_64 / ARM64 | FreeRDP release tag | stable | `v<YYYY>.<MM>.<N>` |
| xrdp + xorgxrdp, `.deb` / `.rpm` for every release in `distros.list` | xrdp, xorgxrdp signed release tags | stable | `v<YYYY>.<MM>.<N>` |
| Web client (WebAssembly) + the freerdp-web page | FreeRDP master + open pull requests, frozen on a fork branch; the page by commit | preview | `web-<page commit, 12>` on every push to main; also inside `v*` |
| xrdp preview packages: Wayland sessions, AV1, pacing | a frozen xrdp development commit + xorgxrdp devel | preview | `xrdp-preview-<commit, 12>` |
| Demo videos (planned) | recorded by `test/wasm-session.sh` | with the web client | `web-<page commit, 12>` |

**Stable** means: upstream release tags only, hashes (and signatures where
upstream signs) checked, no patches. **Preview** means: a fixed commit of
a public branch that is never rewritten, labelled preview everywhere it
appears, never mixed into a stable package's name or version.

A stable release is named by date, `v2026.10.0`, because it bundles
several upstream versions; each archive's `MANIFEST` and the release notes
list them. Packages keep the upstream version with a `0kit<N>` suffix.

## Inputs

- [`sources.lock`](../sources.lock): `name version url sha256`, or
  `name short-commit git+url full-commit` for a git source. Every build
  reads its sources from here and nowhere else.
- [`signed.lock`](../signed.lock) and [`keys/`](../keys): the release key
  each signed tarball must verify against.
- [`distros.list`](../distros.list): the distribution releases to package
  for (testing, stable and old stable of Debian, Ubuntu and Fedora).
- Container images are pinned by digest where the toolchain matters
  (Emscripten).

A change to an input is one commit, whose message names what moved and
why (`xrdp 0.10.6.1 → 0.10.7`). A preview pin's version column is a preview
number (`20261018.1`), raised with every new pin: package versions are
ordered by it, never by a commit hash or date. A preview source moves only to a new frozen
commit; the old one stays reachable, so every old build can be rebuilt.

## Gates

Nothing is uploaded unless every gate of its product passes in CI.

| Product | Gate | Script |
|---|---|---|
| Linux client | only glibc, libgcc_s, libpulse needed; glibc ≤ 2.34; no exported symbols | `build/check-portable.sh` |
| | starts on every supported distribution | `test/smoke.sh` |
| Windows client | only Windows' own DLLs and the UCRT | `build/check-windows.sh` |
| xrdp packages | every build and run-time dependency available on the release | `check-deps.sh` |
| | install in a fresh container, log in over RDP with the kit's client, an Xorg session and its xterm run | `test/xrdp-session.sh` |
| xrdp preview | the same, then a Wayland login: sway starts for the user, wlup captures it at the client's size | `test/xrdp-session.sh --preview` |
| Web client | page served without COOP/COEP, gateway over SSH, browser login starts a session | `test/wasm-session.sh` |
| Published page | the same login from the live site | freerdp-web's `check` job |
| Every push | no private details in the history | `privacy-scan` (pre-push hook) |

Sources failing their SHA-256 or signature stop the build; each guard has
a negative test (a wrong hash, a wrong key, a tampered tarball).

## Flow

```
upstream tag / frozen branch
  → bump commit in sources.lock (a pull request: build + all gates)
  → main: CI again; the web client goes to pre-release web-<page commit>
  → tag v<YYYY>.<MM>.<N> on a green main commit
  → release: every artifact, SHA256SUMS, build provenance attestations
  → consumers download and verify (freerdp-web publishes on purpose)
```

- **Watching upstream**: [`check-upstream.sh`](../check-upstream.sh)
  compares each `sources.lock` entry with the newest upstream release of
  the series the kit follows (`git ls-remote`, no token); the daily
  `upstream` workflow opens one issue per update found. A person decides;
  nothing bumps itself.
- **The web client**: the kit pins a page commit, its CI makes
  `web-<page commit>`; freerdp-web publishes either that exact build (always
  for a freerdp-web `v*` tag; the client's `MANIFEST` must name the page
  commit) or, for page-only changes, its page over the newest tested client.
- **Pages**: the kit's own Pages only redirect to the freerdp-web site and
  are published by hand.
- **Releases are never automatic**: a push builds and tests; publishing
  needs a tag or a manual run.

## Consuming a release

```sh
gh release download v2026.10.0 -R congzhangzh/rdp-release-kit -p SHA256SUMS -p '*.deb'
sha256sum -c --ignore-missing SHA256SUMS
gh attestation verify <file> -R congzhangzh/rdp-release-kit
```

`test/fetch-release.sh <tag>` (planned) does the same for the tests, so
they and the demo recordings can run on released builds as easily as on
local ones.

## Speed

A run took about 19 minutes while the web client's 8 minute build waited
for the xrdp packages, which only its login test needs. Now the build
(`wasm-build`) starts at once and only the test (`wasm`) waits. Next, in
order of effect:

1. Skip the runs a change cannot affect (documentation only).
2. Keep compiler caches between runs (ccache through the CI cache) for
   FreeRDP and its dependencies.
