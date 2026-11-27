#!/bin/bash
# The corresponding source of the xrdp packages, as release assets beside them:
#
#   build/gpl-sources.sh <out dir> [kit commit]      (default: the kit's HEAD)
#
# xrdp links x264 (GPL-2.0-or-later) statically, and the product owner decided (2026-11-27) that
# we keep it and comply with the GPL: whoever downloads an xrdp package finds, in the same
# release, the source of what it was built from and the scripts that built it. The names come
# from gpl_source_names (build/lib.sh), which build-xrdp-pkg.sh also writes into every xrdp
# package (/usr/share/doc/xrdp/NOTICE.x264):
#
#   gpl-source-x264-<commit>.tar.xz             x264's source exactly as the build fetched it (the
#                                               git archive of the commit in sources.lock), in xz
#   gpl-source-xrdp-<version>.<commit8>.tar.xz  the other sources in the xrdp packages' binaries,
#                                               each archive exactly as fetched: xrdp, its
#                                               submodules librfxcodec and libpainter, xorgxrdp and
#                                               Opus (static, BSD), with SOURCES.txt
#   gpl-source-kit-build-<kit commit12>.tar.xz  the kit at the commit that built them (git
#                                               archive): build-xrdp.sh, build/build-xrdp-pkg.sh,
#                                               build/lib.sh, build/package-*.sh, build/patches/,
#                                               sources.lock, deps/, distros.list, all of it
#   gpl-source-libavm-<commit>.tar.xz           libavm, the AV2 encoder (BSD-3-Clause-Clear, static
#                                               beside x264 where AV2 is on), the git archive of
#                                               its commit without what its build never reads
#                                               (build/tar-without.py, AVM_TRIM below): 5 MB, not
#                                               174 (the product owner, 2026-11-27: ship it if
#                                               it is 30 MB or less; more fails here)
#
# Every archive is checked first: a tarball's SHA-256 against sources.lock (fetch), a git
# archive's embedded commit id against the pinned commit. Old gpl-source-*.tar.xz in <out dir>
# are replaced, so only this build's assets are there.
set -euo pipefail
OUTDIR=${1:?usage: gpl-sources.sh <out dir> [kit commit]}
KIT=$(cd "$(dirname "$0")/.." && pwd)
KITSHA=${2:-$(git -C "$KIT" rev-parse HEAD)}
git -C "$KIT" cat-file -e "$KITSHA^{commit}" || { echo "gpl-sources.sh: no kit commit $KITSHA" >&2; exit 1; }
KITSHA=$(git -C "$KIT" rev-parse "$KITSHA^{commit}")
SOURCES=${SOURCES:-$HOME/.cache/rdp-release-kit/sources}
WORK=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-$HOME/tmp}}/gpl-sources.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
unset CCACHE_DIR   # lib.sh would reset a ccache's statistics
export KIT SOURCES WORK
# shellcheck source=build/lib.sh
. "$KIT/build/lib.sh"
# xz single-threaded: the same bytes on every runner (a threaded xz splits by core count)
XZ=(xz -T1 -6 -c)
# what libavm's asset leaves out, none of it read by the build with the kit's options
# (build-xrdp-pkg.sh: no tests, examples, docs or tools, both ML experiments off): the
# TensorFlow Lite bundles, which its CMakeLists.txt unpacks only with CONFIG_TENSORFLOW_LITE
# (147 MB), and two analysis kits of Python, CSV and spreadsheets (47 MB). Built from the
# trimmed tree: 2026-11-27, libavm 060f6120, the same CMake options, a static libavm.a
AVM_TRIM=('avm/third_party/*.tar.gz' avm/tools/convexhull_framework avm/tools/py_stats)
AVM_MAX=$((30 * 1024 * 1024))

# archive <name>: the source archive as fetched, checked, path on stdout
archive() {
    local file id
    file=$(fetch "$1") || return 1
    if [[ ${URL[$1]} == git+* ]]; then
        id=$(git get-tar-commit-id < "$file") || true
        [ "$id" = "${SHA[$1]}" ] || { echo "gpl-sources.sh: $(basename "$file") is not commit ${SHA[$1]}" >&2; return 1; }
    fi
    echo "$file"
}

read -r X264 XRDP KITTAR AVM < <(gpl_source_names "$KITSHA")
mkdir -p "$OUTDIR"
rm -f "$OUTDIR"/gpl-source-*.tar.xz

# x264: the fetched tar itself
file=$(archive x264)
"${XZ[@]}" "$file" > "$OUTDIR/$X264.part"
mv "$OUTDIR/$X264.part" "$OUTDIR/$X264"

# xrdp and the rest, one directory of the fetched archives and what they are
dir=$WORK/${XRDP%.tar.xz}
mkdir -p "$dir"
{
    echo "The sources of the xrdp and xorgxrdp packages of rdp-release-kit $KITSHA, each archive"
    echo "exactly as the build fetched it (sources.lock: name, version, URL, SHA-256 or git commit)."
    echo "x264's is the release asset $X264, libavm's $AVM, the build scripts $KITTAR."
    echo "To build the same packages without the network: unpack $KITTAR, put these"
    echo "archives, x264's (xz -dc $X264 > x264-${SHA[x264]}.tar) and libavm's (the same way, as"
    echo "avm-${SHA[avm]}.tar) in"
    # shellcheck disable=SC2088  # the reader's home, written out
    echo "~/.cache/rdp-release-kit/sources (the build takes what it finds there, checked against"
    echo "sources.lock) and run ./build-xrdp.sh <image> in the kit (its header says how)."
    echo
} > "$dir/SOURCES.txt"
for name in xrdp librfxcodec libpainter xorgxrdp opus; do
    file=$(archive "$name")
    cp "$file" "$dir/"
    printf '%s %s %s %s\n    %s sha256 %s\n' "$name" "${VERSION[$name]}" "${URL[$name]}" "${SHA[$name]}" \
        "$(basename "$file")" "$(sha256sum "$file" | cut -d' ' -f1)" >> "$dir/SOURCES.txt"
done
{
    echo
    echo "Not in this archive:"
    echo "x264 ${SHA[x264]} (GPL-2.0-or-later): $X264"
    echo "libavm ${VERSION[avm]} ${URL[avm]#git+} commit ${SHA[avm]} (BSD-3-Clause-Clear; static in the packages"
    echo "    with AV2): $AVM, its git archive without ${AVM_TRIM[*]}"
    echo "    (none of it read by the build: TensorFlow Lite bundles, analysis scripts)"
    [ -z "${SHA[pipewire_xrdp]:-}" ] ||
        echo "pipewire-module-xrdp ${VERSION[pipewire_xrdp]} ${URL[pipewire_xrdp]#git+} commit ${SHA[pipewire_xrdp]} (MIT; its own Fedora package, no x264)"
} >> "$dir/SOURCES.txt"
tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -C "$WORK" -cf - "${XRDP%.tar.xz}" |
    "${XZ[@]}" > "$OUTDIR/$XRDP.part"
mv "$OUTDIR/$XRDP.part" "$OUTDIR/$XRDP"

# libavm: its git archive without what the build never reads, still naming its commit
file=$(archive avm)
PYTHONUTF8=1 python3 -I "$KIT/build/tar-without.py" "$file" "$WORK/avm.tar" "${AVM_TRIM[@]}"
id=$(git get-tar-commit-id < "$WORK/avm.tar") || true
[ "$id" = "${SHA[avm]}" ] || { echo "gpl-sources.sh: the trimmed libavm archive lost its commit" >&2; exit 1; }
"${XZ[@]}" "$WORK/avm.tar" > "$OUTDIR/$AVM.part"
if [ "$(stat -c %s "$OUTDIR/$AVM.part")" -gt $AVM_MAX ]; then
    echo "gpl-sources.sh: $AVM is $(stat -c %s "$OUTDIR/$AVM.part") bytes, over the product owner's 30 MB: trim more (AVM_TRIM) or ask" >&2
    exit 1
fi
mv "$OUTDIR/$AVM.part" "$OUTDIR/$AVM"

# the kit at its commit
git -C "$KIT" archive --format=tar --prefix="rdp-release-kit-${KITSHA:0:12}/" "$KITSHA" |
    "${XZ[@]}" > "$OUTDIR/$KITTAR.part"
mv "$OUTDIR/$KITTAR.part" "$OUTDIR/$KITTAR"

ls -l "$OUTDIR"/gpl-source-*.tar.xz
