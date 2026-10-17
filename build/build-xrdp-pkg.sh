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
# the build dependencies: the first word of each line in deps/<family>.txt
mapfile -t BUILD_DEPS < <(grep -v -E '^\s*(#|$)' "$KIT/deps/$FAMILY.txt" | awk '{print $1}')

echo "== build dependencies ($PRETTY_NAME)"
if [ $FAMILY = deb ]; then
    PAM_CONFIG=debian
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends "${BUILD_DEPS[@]}" > /dev/null
else
    PAM_CONFIG=redhat
    dnf -y -q install "${BUILD_DEPS[@]}" > /dev/null
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

if ! built x264; then
    src=$(unpack x264)
    (cd "$src" && ./configure --prefix="$DEPS" --libdir="$DEPS/lib" --enable-static \
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

echo "== xrdp ${VERSION[xrdp]}"
src=$(unpack xrdp)
rm -rf "$STAGE"
(cd "$src" &&
 ./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var --libdir=$LIBDIR \
     --with-systemdsystemunitdir=/usr/lib/systemd/system --enable-pam-config=$PAM_CONFIG \
     --enable-fuse --enable-pixman --enable-jpeg --enable-opus --enable-x264 \
     --enable-ipv6 --enable-vsock &&
 make -j"$JOBS" && make install DESTDIR="$STAGE/xrdp") > "$WORK/log/xrdp.log" 2>&1
grep -q -E "x264 +yes" "$WORK/log/xrdp.log"

# xorgxrdp builds against the xrdp just staged: a copy of its .pc file
# that points into the staging tree
echo "== xorgxrdp ${VERSION[xorgxrdp]}"
src=$(unpack xorgxrdp)
mkdir -p "$WORK/pc"
sed "s|^prefix=.*|prefix=$STAGE/xrdp/usr|" "$STAGE/xrdp$LIBDIR/pkgconfig/xrdp.pc" > "$WORK/pc/xrdp.pc"
(cd "$src" &&
 PKG_CONFIG_PATH=$WORK/pc ./configure --prefix=/usr --sysconfdir=/etc --libdir=$LIBDIR &&
 make -j"$JOBS" && make install DESTDIR="$STAGE/xorgxrdp") > "$WORK/log/xorgxrdp.log" 2>&1

# Nothing for development, no keys: those are made per host on install
rm -rf "$STAGE"/xrdp/usr/include "$STAGE"/*$LIBDIR/pkgconfig
find "$STAGE" \( -name '*.la' -o -name '*.a' \) -delete
rm -f "$STAGE"/xrdp/etc/xrdp/{rsakeys.ini,cert.pem,key.pem}
sed -i "/^\[Xorg\]/,/^\[/ s|^param=Xorg\$|param=$XORG|" "$STAGE/xrdp/etc/xrdp/sesman.ini"
grep -q "^param=$XORG\$" "$STAGE/xrdp/etc/xrdp/sesman.ini"
XORG_ABI=$(pkg-config --variable=abi_videodrv xorg-server | cut -d. -f1)
ARCH_DEB=$(dpkg --print-architecture 2> /dev/null || true)
REL=0kit1

echo "== package"
mkdir -p "$OUT/$DISTRO"
if [ $FAMILY = deb ]; then
    "$KIT/build/package-deb.sh" "$STAGE" "$OUT/$DISTRO" "${VERSION[xrdp]}-$REL~$DISTRO" \
        "${VERSION[xorgxrdp]}-$REL~$DISTRO" "$ARCH_DEB" "$XORG_ABI" "$LIBDIR/xrdp" \
        > "$WORK/log/package.log" 2>&1
else
    # an rpm Release may not contain '-': Fedora's dist tag, as in .fc44
    "$KIT/build/package-rpm.sh" "$STAGE" "$OUT/$DISTRO" "${VERSION[xrdp]}" \
        "${VERSION[xorgxrdp]}" "$REL.fc$VERSION_ID" "$LIBDIR" > "$WORK/log/package.log" 2>&1
fi
licenses "$OUT/$DISTRO/licenses" xrdp xorgxrdp x264 opus
(cd "$OUT/$DISTRO" && sha256sum ./*.deb ./*.rpm 2> /dev/null > SHA256SUMS || true)
echo "== done: $OUT/$DISTRO"
ls "$OUT/$DISTRO"
