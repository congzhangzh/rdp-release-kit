# The GPL source of the xrdp packages already released

Every xrdp package this kit has built links **x264** (an H.264 encoder, GPL-2.0-or-later)
statically into xrdp. The product owner decided on 2026-11-27 that the packages keep x264 and
that we comply with the GPL. From then on, every release that ships xrdp packages also ships
their corresponding source as release assets (`build/gpl-sources.sh`), and each xrdp package
carries x264's licence and a notice saying where that source is
(`/usr/share/doc/xrdp/LICENSE.x264`, `/usr/share/doc/xrdp/NOTICE.x264`):

| Asset | What it is |
|---|---|
| `gpl-source-x264-<commit>.tar.xz` | x264's source, the pinned commit, exactly as the build fetched it (`git archive`), in xz |
| `gpl-source-xrdp-<version>.<commit8>.tar.xz` | the other sources in the xrdp packages' binaries, each archive as fetched: xrdp, librfxcodec, libpainter, xorgxrdp, Opus, with `SOURCES.txt` |
| `gpl-source-kit-build-<kit commit12>.tar.xz` | this kit at the commit that built the packages: the build scripts, the patches, `sources.lock`, all of it |
| `gpl-source-libavm-<commit>.tar.xz` | libavm, the AV2 encoder linked statically beside x264: the git archive of its commit without the TensorFlow Lite bundles and two analysis kits its build never reads (about 5 MB instead of 174) |

The release check (`build/check-no-ffmpeg.sh` with `build/gpl-allow.txt`) fails a release whose
xrdp packages have x264 code but lack the licence file or any of the four assets.

This page is for the releases published **before** that change: where the same source is, for
each of them. It is a one-time note; nothing here changes after it is written.

## x264: one commit for every release

x264 entered `sources.lock` on 2026-10-16 (kit commit `9367c36`, the first xrdp packages) and
has never moved since (`git log -G '^x264 ' -- sources.lock` lists only that commit). So every
xrdp package of every release of this repository contains the same x264:

- commit `b35605ace3ddf7c1a5d67a2eb553f034aef41d55`,
  https://code.videolan.org/videolan/x264/-/commit/b35605ace3ddf7c1a5d67a2eb553f034aef41d55
- the same archive the build used:
  `git clone https://code.videolan.org/videolan/x264.git && git -C x264 archive --prefix=x264/ -o x264-b35605ace3ddf7c1a5d67a2eb553f034aef41d55.tar b35605ace3ddf7c1a5d67a2eb553f034aef41d55`
  (`git get-tar-commit-id < x264-….tar` prints the commit), or the asset
  `gpl-source-x264-b35605ace3ddf7c1a5d67a2eb553f034aef41d55.tar.xz` of any release made after
  the change.

It is built with `--enable-static --enable-pic --disable-cli --disable-opencl` and no patch of
ours (`build/build-xrdp-pkg.sh`; the kit has no `build/patches/x264/`).

## Which xrdp, and which build scripts, for a given release

Every release's tag points at the kit commit that built it (`build/publish-prerelease.sh`
creates it with `--target` the workflow's commit), and the pre-releases also name it in the tag:
`xrdp-<date>.<N>-<kit commit12>`, `xrdp-preview-<date>.<N>-<kit commit12>`,
`web-<date>.<N>-<kit commit12>`. For any release `<tag>` of this repository:

- **the build scripts and patches** are the kit at that commit:
  `https://github.com/congzhangzh/rdp-release-kit/tree/<tag>` (or `git archive <tag>`);
- **the xrdp, xorgxrdp, librfxcodec, libpainter and Opus sources** are the lines of
  `sources.lock` at that commit (`git show <tag>:sources.lock`): a tarball with its SHA-256, or
  a git commit (`git+<repository>`, the last column).

The kit releases (tags `<YYYYMMDD>.<N>`, the rolling release), worked out from
`git tag --contains` on each commit that moved the xrdp pin (✅ for the ranges; the two
boundary releases 20261027.2 and 20261027.3 were also checked against their asset lists):

| Kit releases | xrdp in their packages | Set in kit commit |
|---|---|---|
| 20261025.1 … 20261027.2 (18) | xrdp's upstream release 0.10.6.1, `https://github.com/neutrinolabs/xrdp/releases/download/v0.10.6.1/xrdp-0.10.6.1.tar.gz` (SHA-256 `2f7beb5a3b2529c8d72dc0df9b8cdca31ab0e0c14d1e3421210f5e6ec0ab3b75`); xorgxrdp 0.10.5, `https://github.com/neutrinolabs/xorgxrdp/releases/download/v0.10.5/xorgxrdp-0.10.5.tar.gz` (SHA-256 `a5d03435f0ef48bf3d5010e63d9264f2334e7063cba3ecd8d4c0a15616a4f712`) | `9367c36` |
| 20261027.3 … 20261031.2 (15) | our fork's release 20261027.1, https://github.com/congzhangzh/xrdp/commit/8ef7574a72af69afe9135b0d67b7b4d2ee2745d4 | `ec6c8ca` |
| 20261031.3 … 20261107.4 (84) | 20261030.1, https://github.com/congzhangzh/xrdp/commit/4986f5c75272fd6c2746e606e9f9ea587fcf5942 | `b18b826` |
| 20261107.5 … 20261107.8 (4) | 20261107.1, https://github.com/congzhangzh/xrdp/commit/ed0192ba6ffddd6d1de077ee9ac57be1f62df2c5 | `c5831a2` |
| 20261107.9 … 20261110.2 (11) | 20261107.2, https://github.com/congzhangzh/xrdp/commit/b04ac0d8a93616db3e3acad0acd541dc4c3205fe | `983dd90` |
| 20261110.3 … 20261127.2 (79) | 20261110.1, https://github.com/congzhangzh/xrdp/commit/2e975a4ea8cee93b9563ce4950c98eb0af6e26e5 | `8aebbf1` |

From kit commit `ec6c8ca` (release 20261027.3) on, the other sources stayed the same:
xorgxrdp https://github.com/neutrinolabs/xorgxrdp/commit/59d0735c4321b5baff3feaa980a01f78a1c1e96f,
librfxcodec https://github.com/neutrinolabs/librfxcodec/commit/0badc062e96d170af57870480a4aa7cf469302b0
and libpainter https://github.com/neutrinolabs/libpainter/commit/379b8fbf40f309829364bf3414d721f9ba77766d
(xrdp's submodules, pinned since kit commit `d145803`). Opus was 1.5.2 until kit commit
`a851c8f` (2026-10-21) and 1.6.1 after it, the upstream tarballs
`https://downloads.xiph.org/releases/opus/opus-<version>.tar.gz` (SHA-256s in `sources.lock`).

The pre-releases:

- `xrdp-<date>.<N>-<kit commit12>` (from 2026-10-27): the packages built by that kit commit
  (the kit release of the same commit, if the round got that far, has the same ones); the xrdp
  pin by the kit commit, as in the table's last column (`ec6c8ca` and later).
- `web-<date>.<N>-<kit commit12>` (from 2026-10-21): the Debian 13 xrdp packages of that kit
  commit's build, the same rule.
- `xrdp-preview-*` (2026-10-18 to 2026-10-27, before the kit had one xrdp): the preview of our
  fork, the `xrdp_preview` and `xorgxrdp_preview` lines of `sources.lock` at the tag's commit
  (xrdp_preview 20261018.1 `bffad034`, 20261018.2 `53af799d`, 20261021.1 `bfba3d7f`,
  20261025.1 `94f7cf46`, 20261026.1 `816daad4`, 20261026.2 `a1c78563`, 20261026.3 `5f77b058`,
  20261026.4 `6b3df599`, 20261027.1 `8ef7574a`, all at https://github.com/congzhangzh/xrdp;
  xorgxrdp_preview `59d0735c`). The first four tags (`xrdp-preview-<xrdp commit12>[-<kit
  commit12>]`) name the xrdp commit itself.

Every commit of our xrdp fork named above (the five releases and the nine previews) also has a
lasting tag there, `gpl-source/xrdp-<commit>` (e.g.
https://github.com/congzhangzh/xrdp/tree/gpl-source/xrdp-2e975a4ea8cee93b9563ce4950c98eb0af6e26e5),
never moved or deleted (✅ thirteen, created 2026-11-27 and listed with the GitHub API). The first
preview's commit (`bffad034`, 20261018.1) had left the fork when its branch was rebuilt; it was
pushed back from a kept clone under its tag. xorgxrdp, librfxcodec and libpainter are upstream's
own commits at https://github.com/neutrinolabs, not branches of ours, so they need no tag.

## libavm: the AV2 encoder beside x264

libavm (BSD-3-Clause-Clear) is linked statically into xrdp beside x264 in the packages with AV2,
so it is part of the same work and its source is part of the corresponding source. xrdp has
AV2 from its fork release 20261030.1 (kit commit `b18b826`, release 20261031.3) on, in every
package whose release is not marked `no-av2` in `distros.list` (at that tag). The earlier libavm
pins (20261030.1 to 20261031.1, from kit commit `1cec070`) were in the clients only, which
contain no x264. Worked out from `git tag --contains` on each commit that moved the `avm` line
(✅); each commit sits on a branch `release-<version>` of https://github.com/congzhangzh/avm,
and since 2026-11-27 also has a lasting tag there, `gpl-source/libavm-<commit>` (✅ all eleven
created and listed with the GitHub API, 2026-11-27):

| Kit releases | libavm | Commit | Branch on the fork |
|---|---|---|---|
| 20261031.3 … 20261104.1 (46) | 20261031.2 | [`b132a0a6647d`](https://github.com/congzhangzh/avm/commit/b132a0a6647dc97e2e917fb9bae6f6c4335bfb54) | `release-20261031.2` |
| 20261104.2 … 20261104.4 (3) | 20261103.1 | [`55df12d6d759`](https://github.com/congzhangzh/avm/commit/55df12d6d759eb595e8f440a1a37039e31ab57dd) | `release-20261103.1` |
| 20261104.5 … 20261104.7 (3) | 20261103.2 | [`76a2133c270d`](https://github.com/congzhangzh/avm/commit/76a2133c270d150572e1a0ffa9dd8a554a907ece) | `release-20261103.2` |
| 20261104.8 … 20261104.9 (2) | 20261103.3 | [`5b965cfa4c62`](https://github.com/congzhangzh/avm/commit/5b965cfa4c62a5f149b8c4d217275defc335e0b4) | `release-20261103.3` |
| 20261104.10 … 20261104.13 (4) | 20261104.1 | [`9798cd4d8c7c`](https://github.com/congzhangzh/avm/commit/9798cd4d8c7c1457d072992209b62c93d6a25593) | `release-20261104.1` |
| 20261104.14 … 20261106.9 (16) | 20261104.2 | [`e2969605549d`](https://github.com/congzhangzh/avm/commit/e2969605549d11b9609b8f678fbb8de09ec4fc34) | `release-20261104.2` |
| 20261106.10 … 20261118.3 (57) | 20261106.1 | [`5bebfad2eef8`](https://github.com/congzhangzh/avm/commit/5bebfad2eef8918e8ff4f44d0d3cce87203c690d) | `release-20261106.1` |
| 20261118.4 (1) | 20261118.1 | [`d4fda5dad5ab`](https://github.com/congzhangzh/avm/commit/d4fda5dad5abc5f554a205c99cb0f3b9c8c69962) | `release-20261118.1` |
| none (pre-releases only) | 20261118.2 | [`567a8dcff713`](https://github.com/congzhangzh/avm/commit/567a8dcff713e2ec07e887d204bb0f52d0ab3674) | `release-20261118.2` |
| 20261119.1 … 20261120.2 (3) | 20261119.4 | [`01defdb0eb5a`](https://github.com/congzhangzh/avm/commit/01defdb0eb5a163da178ef79474fd61a8dde0e4b) | `release-20261119.4` |
| 20261120.3 … 20261127.2 (43) | 20261119.6 | [`060f61204513`](https://github.com/congzhangzh/avm/commit/060f612045132f2b0ba747dc74de6ba09f69386b) | `release-20261119.6` |

libavm 20261118.2 reached no kit release, only the pre-releases of kit commit `65313b1`
(`xrdp-20261118.6-65313b15361a`, ✅ by its tag name). Branches can move or go; the tags
`gpl-source/libavm-<commit>` (e.g.
https://github.com/congzhangzh/avm/tree/gpl-source/libavm-060f612045132f2b0ba747dc74de6ba09f69386b)
are never moved or deleted, so each commit keeps a lasting name.

## Building a past release again

Check out its tag and run `./build-xrdp.sh
<image>` (its header says how); it fetches the same sources by `sources.lock` and checks each
one's SHA-256 or commit.
