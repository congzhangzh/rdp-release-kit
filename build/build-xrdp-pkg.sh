#!/bin/bash
# Builds native xrdp and xorgxrdp packages inside a stock image of the
# target distribution:
#
#   build-xrdp-pkg.sh <kit dir> <sources dir> <output dir>
#
# The parts that must match the distribution come from it: PAM, OpenSSL,
# X11, FUSE, pixman, libjpeg, and the Xorg server whose module ABI
# xorgxrdp is built for. The codecs whose availability differs between
# distributions (x264 is not in Fedora, for one) are built from
# sources.lock and linked statically, so every package has the same
# features. The result is <output dir>/<distro>/ with .deb or .rpm files.
#
# xrdp is our release on the fork, a git commit (sources.lock): xrdp devel
# with the Wayland sessions (the wlup module: sway, GNOME, KDE) and AV1;
# xorgxrdp its development commit. Their version says which:
# <version in configure.ac>+<pin's version>.<commit>, e.g.
# 0.10.80+20261027.1.8ef7574a. The '+' sorts it after 0.10.80 and after the
# kit's earlier preview packages (0.10.80~preview.<N>.<commit>), which it
# upgrades, but before xrdp's next release (0.10.81, 0.11.0). The pin's
# version is the date of its pick (release-<YYYYMMDD>.<N>), so newer picks
# sort higher (a commit's date cannot: rebuilt stacks keep them).
# A release's marks in distros.list leave out what it cannot have:
# NO_AV1=1 (no-av1) AV1 and libaom, NO_SWAY=1 (no-sway) the sway session
# on the login screen, NO_KDE=1 (no-kde) the KWin backend and its session.
#
# A local source (SRC_xrdp=<dir>, see build/overrides.sh) is built
# in place and kept: the next run regenerates and configures only when
# that is needed, and make recompiles what changed. Its packages are
# marked: release 0local1 instead of 0kit<N>.
# the autotools subshells set their own PATH on purpose (ccache, below)
# shellcheck disable=SC2030,SC2031
set -Eeuo pipefail

KIT=$1
SOURCES=$2
OUT=$3
WORK=/work
STAGE=$WORK/stage

# shellcheck source=/dev/null
. /etc/os-release
# debian-13, ubuntu-26.04, fedora-44; Debian testing has no version: forky
DISTRO=$ID-${VERSION_ID:-$VERSION_CODENAME}
case " $ID ${ID_LIKE:-} " in
    *" debian "* | *" ubuntu "*) FAMILY=deb ;;
    *" fedora "*) FAMILY=rpm ;;
    *) echo "unsupported distribution: $PRETTY_NAME" >&2; exit 1 ;;
esac
export NO_AV1=${NO_AV1:-} NO_SWAY=${NO_SWAY:-} NO_KDE=${NO_KDE:-}
# the build dependencies (deps/<family>.txt), unless the image has them
# (build/builder.sh)
[ -n "${KIT_TOOLS:-}" ] || "$KIT/build/tools.sh" "$KIT" xrdp
if [ $FAMILY = deb ]; then
    PAM_CONFIG=debian
else
    PAM_CONFIG=redhat
fi

# shellcheck source=build/lib.sh
. "$KIT/build/lib.sh"
# x264 and Opus come from $DEPS, as static libraries only: xrdp's
# configure finds x264 with pkg-config and Opus by its header
export PKG_CONFIG_PATH=$DEPS/lib/pkgconfig
export CFLAGS="-O2 -g -fPIC"
export CPPFLAGS="-I$DEPS/include"
export LDFLAGS="-L$DEPS/lib"
# what the static libraries need, which their shared versions bring along
export LIBS="-lm -lpthread -ldl"
# ccache for the autotools builds: its gcc wrapper first in PATH. CC
# stays unset: xrdp records its configure options and CC/CFLAGS in its
# binaries (xrdp --version), and CC="ccache gcc" would change them. Only
# for those builds: CMake has the launcher, and ccache behind ccache fails
CCPATH=$PATH
if [ ${#LAUNCHER[@]} != 0 ]; then
    for dir in /usr/lib/ccache /usr/lib64/ccache; do
        [ -x "$dir/gcc" ] && CCPATH=$dir:$PATH
    done
fi

# bootstrap <src>: generates configure for a git commit; a kept local
# source only when configure.ac changed (make regenerates the rest)
bootstrap() {
    [ -f "$1/configure" ] && [ "$1/configure" -nt "$1/configure.ac" ] && return 0
    (cd "$1" && ./bootstrap) >> "$WORK/log/bootstrap.log" 2>&1
}
rm -f "$WORK/log/bootstrap.log"

if ! built x264; then
    src=$(unpack x264)
    (cd "$src" && export PATH=$CCPATH && ./configure --prefix="$DEPS" --libdir="$DEPS/lib" --enable-static \
         --enable-pic --disable-cli --disable-opencl && make -j"$JOBS" && make install) \
        > "$WORK/log/x264.log" 2>&1
    stamp x264
fi
cmake_dep opus -DOPUS_BUILD_PROGRAMS=OFF -DOPUS_BUILD_TESTING=OFF

# where each family keeps libraries, and its non-suid Xorg (sesman.ini
# lists both paths, and asks the packager to pick one)
if [ $FAMILY = deb ]; then
    LIBDIR=/usr/lib
    XORG=/usr/lib/xorg/Xorg
else
    LIBDIR=/usr/lib64
    XORG=/usr/libexec/Xorg
fi

XRDP=xrdp
XORGXRDP=xorgxrdp
# a git commit, not a release tarball: the submodules come separately
# and the configure scripts are generated
src=$(unpack $XRDP)
# a local checkout brings its own, if it has them checked out
for sub in librfxcodec libpainter; do
    overridden $XRDP && [ -f "$src/$sub/configure.ac" ] && continue
    rm -rf "${src:?}/$sub"
    cp -a "$(unpack $sub)" "$src/$sub"
done
bootstrap "$src"
base=$(sed -n 's/^AC_INIT(\[xrdp\], \[\([^]]*\)\].*/\1/p' "$src/configure.ac")
XRDP_VERSION=$base+${VERSION[$XRDP]}.${SHA[$XRDP]:0:8}
EXTRA=(--enable-wlup)
[ -z "$NO_AV1" ] && EXTRA+=(--enable-av1)
# the GNOME backend needs libei and PipeWire (GNOME 46 and newer)
WLUP_GNOME=
if pkg-config --exists libei-1.0 libpipewire-0.3 libsystemd; then
    EXTRA+=(--enable-wlup-mutter)
    WLUP_GNOME=1
fi
# the KDE backend needs KWin's protocol files with the output device
# registry (plasma-wayland-protocols 1.21 and newer), unless marked no-kde
WLUP_KDE=
if [ -z "$NO_KDE" ]; then
    EXTRA+=(--enable-wlup-kwin)
    WLUP_KDE=1
fi
# an old warning in xrdp_mm.c, an error with -O2 on devel
CFLAGS="$CFLAGS -Wno-error=nonnull"

overridden $XRDP && echo "== $XRDP (local)"
# a local build installs xrdp with the time stamps of its files: xorgxrdp
# includes its headers from the stage, and new times on unchanged headers
# would make all of xorgxrdp recompile
KEEP_TIME=()
[ -z "${OVERRIDES:-}" ] || KEEP_TIME=(INSTALL="install -p")
echo "== $XRDP $XRDP_VERSION"
rm -rf "$STAGE"
(cd "$src" && export PATH=$CCPATH &&
 configure "$src" ./configure \
     --prefix=/usr --sysconfdir=/etc --localstatedir=/var --libdir=$LIBDIR \
     --with-systemdsystemunitdir=/usr/lib/systemd/system --enable-pam-config=$PAM_CONFIG \
     --enable-fuse --enable-pixman --enable-jpeg --enable-opus --enable-x264 \
     --enable-ipv6 --enable-vsock "${EXTRA[@]}" &&
 make -j"$JOBS" && make install DESTDIR="$STAGE/xrdp" "${KEEP_TIME[@]}") > "$WORK/log/xrdp.log" 2>&1
# configure's summary; a kept configuration passed these checks before
grep -q -E -e "x264 +yes" -e "configuration kept" "$WORK/log/xrdp.log"
# AV1 is in unless the release is marked no-av1
if [ -z "$NO_AV1" ]; then
    grep -q -E -e "av1 \(libaom\) +yes" -e "configuration kept" "$WORK/log/xrdp.log"
fi

# xorgxrdp builds against the xrdp just staged: a copy of its .pc file
# that points into the staging tree
src=$(unpack $XORGXRDP)
bootstrap "$src"
XORGXRDP_VERSION=$(sed -n 's/^AC_INIT(\[xorgxrdp\], \[\([^]]*\)\].*/\1/p' "$src/configure.ac")
XORGXRDP_VERSION=$XORGXRDP_VERSION+${VERSION[$XORGXRDP]}.${SHA[$XORGXRDP]:0:8}
echo "== $XORGXRDP $XORGXRDP_VERSION"
mkdir -p "$WORK/pc"
sed "s|^prefix=.*|prefix=$STAGE/xrdp/usr|" "$STAGE/xrdp$LIBDIR/pkgconfig/xrdp.pc" > "$WORK/pc/xrdp.pc"
(cd "$src" && export PATH=$CCPATH PKG_CONFIG_PATH=$WORK/pc &&
 configure "$src" ./configure --prefix=/usr --sysconfdir=/etc --libdir=$LIBDIR &&
 make -j"$JOBS" && make install DESTDIR="$STAGE/xorgxrdp") > "$WORK/log/xorgxrdp.log" 2>&1

# PipeWire's xrdp module, a session's sound and microphone: Debian and
# Ubuntu package it, Fedora does not, so the rpm builds ship it (as its
# own package, pipewire-module-xrdp)
if [ $FAMILY = rpm ]; then
    src=$(unpack pipewire_xrdp)
    bootstrap "$src"
    echo "== pipewire_xrdp ${VERSION[pipewire_xrdp]}"
    (cd "$src" && export PATH=$CCPATH &&
     configure "$src" ./configure --prefix=/usr --libdir=$LIBDIR --sysconfdir=/etc &&
     make -j"$JOBS" && make install DESTDIR="$STAGE/pipewire-module-xrdp") \
        > "$WORK/log/pipewire_xrdp.log" 2>&1
fi
ccache_stats

# Nothing for development, no keys: those are made per host on install
rm -rf "$STAGE"/xrdp/usr/include "$STAGE"/*$LIBDIR/pkgconfig
find "$STAGE" \( -name '*.la' -o -name '*.a' \) -delete
rm -f "$STAGE"/xrdp/etc/xrdp/{rsakeys.ini,cert.pem,key.pem}
sed -i "/^\[Xorg\]/,/^\[/ s|^param=Xorg\$|param=$XORG|" "$STAGE/xrdp/etc/xrdp/sesman.ini"
grep -q "^param=$XORG\$" "$STAGE/xrdp/etc/xrdp/sesman.ini"
# With AV1, xrdp offers it first: FreeRDP clients built with AV1 take
# it, the others fall back to H.264, then RFX (xrdp ships H.264 first)
if [ -z "$NO_AV1" ]; then
    sed -i 's/^order = \[ "H\.264", "RFX" \]$/order = [ "AV1", "H.264", "RFX" ]/' \
        "$STAGE/xrdp/etc/xrdp/gfx.toml"
    grep -q '^order = \[ "AV1", "H\.264", "RFX" \]$' "$STAGE/xrdp/etc/xrdp/gfx.toml"
fi
# The Wayland sessions are on the login screen's list (xrdp.ini only has
# them commented out): GNOME and KDE when their backends were built, sway
# unless the release's sway is too old (NO_SWAY=1, a release marked
# no-sway). They go after [Xorg], which stays the default: with no
# autorun=, xrdp starts the first session for a client that sends a
# password. sesman.ini has the [GNOME], [KDE] and [Wayland] sections that
# start them
INI=$STAGE/xrdp/etc/xrdp/xrdp.ini
SESSIONS=$(mktemp)
if [ -n "$WLUP_GNOME" ]; then
    printf '%s\n' '[GNOME]' 'name=GNOME (Wayland)' 'lib=libwlup.so' 'username=ask' \
        'password=ask' 'port=-1' 'code=31' 'backend=mutter' '' >> "$SESSIONS"
fi
if [ -n "$WLUP_KDE" ]; then
    printf '%s\n' '[KDE]' 'name=KDE Plasma (Wayland)' 'lib=libwlup.so' 'username=ask' \
        'password=ask' 'port=-1' 'code=32' 'backend=kwin' '' >> "$SESSIONS"
fi
if [ -z "$NO_SWAY" ]; then
    printf '%s\n' '[Wayland]' 'name=Sway (Wayland)' 'lib=libwlup.so' 'username=ask' \
        'password=ask' 'port=-1' 'code=30' 'xkb_layout=us' '' >> "$SESSIONS"
fi
awk -v f="$SESSIONS" '
    /^\[Xvnc\]/ && !done { while ((getline l < f) > 0) print l; done = 1 }
    { print }
    END { if (!done) exit 1 }' "$INI" > "$INI.new"
mv "$INI.new" "$INI"
rm -f "$SESSIONS"
[ -z "$WLUP_GNOME" ] || grep -q '^\[GNOME\]$' "$INI"
[ -z "$WLUP_KDE" ] || grep -q '^\[KDE\]$' "$INI"
[ -n "$NO_SWAY" ] || grep -q '^\[Wayland\]$' "$INI"
XORG_ABI=$(pkg-config --variable=abi_videodrv xorg-server | cut -d. -f1)
ARCH_DEB=$(dpkg --print-architecture 2> /dev/null || true)
# N counts the kit's commits (build-xrdp.sh); a build with a local source
# is marked as one
REL=0kit${KIT_REV:-0}
[ -z "${OVERRIDES:-}" ] || REL=0local1

echo "== package"
# only this build's packages: an old build's would be installed with them
rm -rf "${OUT:?}/$DISTRO"
mkdir -p "$OUT/$DISTRO"
if [ $FAMILY = deb ]; then
    "$KIT/build/package-deb.sh" "$STAGE" "$OUT/$DISTRO" "$XRDP_VERSION-$REL~$DISTRO" \
        "$XORGXRDP_VERSION-$REL~$DISTRO" "$ARCH_DEB" "$XORG_ABI" "$LIBDIR/xrdp" \
        > "$WORK/log/package.log" 2>&1
else
    # an rpm Release may not contain '-': Fedora's dist tag, as in .fc44
    "$KIT/build/package-rpm.sh" "$STAGE" "$OUT/$DISTRO" "$XRDP_VERSION" \
        "$XORGXRDP_VERSION" "$REL.fc$VERSION_ID" "$LIBDIR" "${VERSION[pipewire_xrdp]}" \
        > "$WORK/log/package.log" 2>&1
fi
licenses "$OUT/$DISTRO/licenses" $XRDP $XORGXRDP x264 opus
[ $FAMILY = deb ] || licenses "$OUT/$DISTRO/licenses" pipewire_xrdp
(cd "$OUT/$DISTRO" && sha256sum ./*.deb ./*.rpm 2> /dev/null > SHA256SUMS || true)
echo "== done: $OUT/$DISTRO"
ls "$OUT/$DISTRO"
