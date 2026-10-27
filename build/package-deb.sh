#!/bin/bash
# Packages the staged xrdp and xorgxrdp trees as .deb files:
#
#   package-deb.sh <stage> <out> <xrdp version> <xorgxrdp version> <arch>
#                  <xorg video ABI> <xrdp private lib dir>
#
# Dependencies come from dpkg-shlibdeps; xorgxrdp also depends on the
# Xorg video driver ABI it was built for. Host keys are made in postinst.
set -euo pipefail
# what the packages are built from, and the sessions they have (the
# release's marks, set by build-xrdp-pkg.sh)
FROM="from rdp-release-kit's release of its development branch"
WAYLAND=GNOME
[ -n "${NO_KDE:-}" ] || WAYLAND+=", KDE"
[ -n "${NO_SWAY:-}" ] || WAYLAND+=", sway"
EXTRAS=" Wayland sessions ($WAYLAND)${NO_AV1:+.}"
[ -n "${NO_AV1:-}" ] || EXTRAS+=" and AV1."

STAGE=$1
OUT=$2
XRDP_VERSION=$3
XORGXRDP_VERSION=$4
ARCH=$5
XORG_ABI=$6
PRIVLIBS=$7
MAINTAINER="Cong Zhang <13283869+congzhangzh@users.noreply.github.com>"

# shlibdeps <root> <private lib dir>: the Depends of the ELF files in <root>
shlibdeps() {
    local root=$1 dir
    dir=$(mktemp -d)
    mkdir -p "$dir/debian"
    printf 'Source: kit\n\nPackage: kit\nArchitecture: any\n' > "$dir/debian/control"
    mapfile -t elf < <(find "$root/usr" -type f -exec sh -c \
        'head -c4 "$1" | grep -q ELF' _ {} \; -print)
    (cd "$dir" && dpkg-shlibdeps -O -l"$root$PRIVLIBS" "${elf[@]}" 2> /dev/null |
        sed -n 's/^shlibs:Depends=//p')
    rm -rf "$dir"
}

# --- xrdp
ROOT=$STAGE/xrdp
mkdir -p "$ROOT/DEBIAN"
(cd "$ROOT" && find etc -type f | sed 's|^|/|' | sort) > "$ROOT/DEBIAN/conffiles"
cat > "$ROOT/DEBIAN/control" << EOF
Package: xrdp
Version: $XRDP_VERSION
Architecture: $ARCH
Maintainer: $MAINTAINER
Depends: $(shlibdeps "$ROOT"), openssl
Recommends: xorgxrdp
Section: net
Priority: optional
Installed-Size: $(du -sk --exclude=DEBIAN "$ROOT" | cut -f1)
Homepage: https://www.xrdp.org/
Description: Remote Desktop Protocol (RDP) server (rdp-release-kit build)
 xrdp $FROM, with H.264 (x264) and Opus built in.$EXTRAS
 Services are not started on install. Keep it off the network: listen on
 127.0.0.1 (port=tcp://.:3389 in /etc/xrdp/xrdp.ini) and connect through
 an SSH tunnel.
EOF
cat > "$ROOT/DEBIAN/postinst" << 'EOF'
#!/bin/sh
set -e
ETC=/etc/xrdp
if [ "$1" = configure ]; then
    [ -f $ETC/rsakeys.ini ] || xrdp-keygen xrdp $ETC/rsakeys.ini > /dev/null
    chmod 600 $ETC/rsakeys.ini
    if [ ! -f $ETC/cert.pem ]; then
        openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 \
            -subj "/CN=$(hostname -f 2>/dev/null || hostname)" \
            -keyout $ETC/key.pem -out $ETC/cert.pem > /dev/null 2>&1
        chmod 600 $ETC/key.pem
    fi
    ldconfig
    [ -d /run/systemd/system ] && systemctl daemon-reload || true
fi
exit 0
EOF
cat > "$ROOT/DEBIAN/prerm" << 'EOF'
#!/bin/sh
set -e
if [ -d /run/systemd/system ]; then
    systemctl stop xrdp.service xrdp-sesman.service > /dev/null 2>&1 || true
fi
exit 0
EOF
cat > "$ROOT/DEBIAN/postrm" << 'EOF'
#!/bin/sh
set -e
if [ "$1" = purge ]; then
    rm -f /etc/xrdp/rsakeys.ini /etc/xrdp/cert.pem /etc/xrdp/key.pem \
          /var/log/xrdp.log /var/log/xrdp-sesman.log
    rmdir --ignore-fail-on-non-empty /etc/xrdp/pulse /etc/xrdp 2>/dev/null || true
fi
ldconfig
[ -d /run/systemd/system ] && systemctl daemon-reload || true
exit 0
EOF
chmod 755 "$ROOT"/DEBIAN/{postinst,prerm,postrm}
# a build with a local source (OVERRIDES) compresses quickly: default xz
# takes 6 s for xrdp, -z1 0.4 s, for a package 15 % larger
ZXZ=(-Zxz)
[ -z "${OVERRIDES:-}" ] || ZXZ+=(-z1)
dpkg-deb --root-owner-group "${ZXZ[@]}" --build "$ROOT" "$OUT/xrdp_${XRDP_VERSION}_$ARCH.deb" > /dev/null

# --- xorgxrdp
ROOT=$STAGE/xorgxrdp
mkdir -p "$ROOT/DEBIAN"
(cd "$ROOT" && find etc -type f 2> /dev/null | sed 's|^|/|' | sort) > "$ROOT/DEBIAN/conffiles"
[ -s "$ROOT/DEBIAN/conffiles" ] || rm "$ROOT/DEBIAN/conffiles"
cat > "$ROOT/DEBIAN/control" << EOF
Package: xorgxrdp
Version: $XORGXRDP_VERSION
Architecture: $ARCH
Maintainer: $MAINTAINER
Depends: $(shlibdeps "$ROOT"), xrdp, xorg-video-abi-$XORG_ABI, xserver-xorg-core
Section: x11
Priority: optional
Installed-Size: $(du -sk --exclude=DEBIAN "$ROOT" | cut -f1)
Homepage: https://www.xrdp.org/
Description: Xorg drivers for xrdp (rdp-release-kit build)
 xorgxrdp $FROM, built for this distribution's Xorg
 server (video driver ABI $XORG_ABI).
EOF
dpkg-deb --root-owner-group "${ZXZ[@]}" --build "$ROOT" \
    "$OUT/xorgxrdp_${XORGXRDP_VERSION}_$ARCH.deb" > /dev/null
