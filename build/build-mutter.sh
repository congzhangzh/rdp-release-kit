#!/bin/bash
# GNOME's Mutter for Fedora 45 with our fix for a Wayland window that lands
# on the wrong monitor when the monitor layout moves its monitor
# (GNOME/mutter#5162, merge request !5438): Fedora's own source package (the
# mutter line of sources.lock, checked against its SHA-256), the patches in
# patches/mutter/, rebuilt for this machine's architecture as release
# <Fedora's>.0kit<N>, which sorts after Fedora's own and before its next
# update (an update of Fedora's replaces ours, and the fix with it):
#
#   build/build-mutter.sh <out dir>     mutter and mutter-common rpms into <out dir>
#   build/build-mutter.sh --key         the key that names the inputs
#
# Then, in a fresh Fedora 45 container: the two packages install over
# Fedora's, Fedora's gnome-shell of the same version (an update in testing
# may be newer) installs with them, keeps them and starts (--version);
# libmutter needs no library it lacks.
# ENGINE (docker first, else podman); CONTAINER_OPTS are passed to every
# container (e.g. --memory=3g); MUTTER_JOBS caps the build's jobs (a link
# with LTO takes about 1 GB each).
set -euo pipefail

KIT=$(cd "$(dirname "$0")/.." && pwd)
# the kit's build number of one Fedora release: up when the patches or this
# build change what is built
N=1
read -r version url sha < <(awk '$1 == "mutter" { print $2, $3, $4 }' "$KIT/sources.lock")
# Fedora's release number (51.0-1.fc45: 1); its spec computes it (%autorelease)
rel=${version#*-}
rel=${rel%%.*}
key() {
    { echo "$version $sha 0kit$N"; cat "$KIT"/patches/mutter/*.patch "$KIT/build/build-mutter.sh"; } |
        sha256sum | cut -c1-12
}
if [ "${1:-}" = --key ]; then
    echo "mutter ${version%%-*}-$rel.0kit$N.fc45 (inputs $(key))"
    exit 0
fi
OUT=${1:?usage: build/build-mutter.sh <out dir> | --key}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
# docker first: the builds are tested with it (podman: see README)
ENGINE=${ENGINE:-$(command -v docker || command -v podman)}
# shellcheck disable=SC2206 # options, split on purpose
opts=(${CONTAINER_OPTS:-})

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
curl -fsSL --retry 3 -o "$W/mutter.src.rpm" "$url"
echo "$sha  $W/mutter.src.rpm" | sha256sum -c --quiet
cp "$KIT"/patches/mutter/*.patch "$W/"

# shellcheck disable=SC2016 # expanded by the container shell
"$ENGINE" run --rm "${opts[@]}" -v "$W:/w:Z" -v "$OUT:/out:Z" -e REL="$rel" -e N="$N" -e JOBS="${MUTTER_JOBS:-}" \
    fedora:45 bash -euo pipefail -c '
dnf -y -q install rpm-build dnf-plugins-core
rpm -i /w/mutter.src.rpm
spec=~/rpmbuild/SPECS/mutter.spec
dnf -y -q builddep "$spec"
i=9900
for p in /w/*.patch; do
    i=$((i + 1))
    cp "$p" ~/rpmbuild/SOURCES/kit-$i.patch
    patches+="Patch$i: kit-$i.patch\n"
done
# our release after Fedora'"'"'s; the patches after its last Source or
# Patch line, applied by its %autosetup
sed -i "0,/^Release:.*/s//Release: $REL.0kit$N%{?dist}/" "$spec"
last=$(grep -n "^\(Patch\|Source\)[0-9]*:" "$spec" | tail -1 | cut -d: -f1)
sed -i "${last}a $patches" "$spec"
grep -q "^%autosetup" "$spec"
grep "^Release:\|^Patch99" "$spec"
rpmbuild -bb --nocheck ${JOBS:+--define "_smp_ncpus_max $JOBS"} "$spec"
cp ~/rpmbuild/RPMS/*/mutter-[0-9]*.rpm ~/rpmbuild/RPMS/noarch/mutter-common-*.rpm /out/
'
ls "$OUT"/mutter-[0-9]*.rpm "$OUT"/mutter-common-*.rpm > /dev/null

# shellcheck disable=SC2016 # expanded by the container shell
"$ENGINE" run --rm "${opts[@]}" -v "$OUT:/out:ro,Z" -e SHELL_VERSION="${version%%-*}" fedora:45 bash -euo pipefail -c '
dnf -y -q install /out/mutter-[0-9]*.rpm /out/mutter-common-*.rpm
dnf -y -q --setopt=install_weak_deps=False install "gnome-shell-$SHELL_VERSION"
# both ours still (no grep -q in a pipe: under pipefail, rpm dies of SIGPIPE)
q=$(rpm -q mutter mutter-common)
[ "$(grep -c 0kit <<< "$q")" = 2 ] || { echo "$q"; echo "gnome-shell replaced our mutter" >&2; exit 1; }
! ldd /usr/lib64/libmutter-*.so.0 | grep "not found"
gnome-shell --version
rpm -q mutter mutter-common
'
echo "build-mutter.sh: $(cd "$OUT" && ls mutter-[0-9]*.rpm mutter-common-*.rpm | tr '\n' ' ')"
