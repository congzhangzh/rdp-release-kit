#!/bin/bash
# Packages the staged xrdp and xorgxrdp trees as .rpm files:
#
#   package-rpm.sh <stage> <out> <xrdp version> <xorgxrdp version> <release> <libdir>
#
# rpmbuild adds the shared-library Requires on its own; xorgxrdp also
# requires the Xorg video driver ABI it was built for. Host keys are made
# in %post.
set -euo pipefail
# what the packages are built from (FLAVOUR is set by build-xrdp-pkg.sh)
if [ "${FLAVOUR:-stable}" = preview ]; then
    FROM="as a PREVIEW of its development branch, not a release"
    EXTRAS=" Wayland sessions (sway, GNOME) and AV1."
    [ -n "${NO_AV1:-}" ] && EXTRAS=" Wayland sessions (sway, GNOME)."
else
    FROM="from the upstream release"
    EXTRAS=
fi

STAGE=$1
OUT=$2
XRDP_VERSION=$3
XORGXRDP_VERSION=$4
RELEASE=$5
LIBDIR=$6
TOP=$(mktemp -d)
XORG_ABI_REQ=$(xserver-sdk-abi-requires videodrv)

# files <root>: an rpm %files list of the tree, /etc as noreplace config;
# man pages end in * because rpmbuild compresses them after %install
files() {
    (cd "$1" && find . \( -type f -o -type l \) | sed 's|^\.||' | sort |
        sed 's|^/etc/.*|%config(noreplace) &|; s|^/usr/share/man/.*|&*|')
}

cat > "$TOP/kit.spec" << EOF
%global debug_package %{nil}
%global __brp_strip /bin/true
Name: xrdp
Version: $XRDP_VERSION
Release: $RELEASE
Summary: Remote Desktop Protocol (RDP) server (rdp-release-kit build)
License: Apache-2.0 AND GPL-2.0-or-later
URL: https://www.xrdp.org/
Requires: openssl
Recommends: xorgxrdp

%description
xrdp $FROM, with H.264 (x264) and Opus built in.$EXTRAS
Services are not started on install. Keep it off the network: listen on
127.0.0.1 (port=tcp://.:3389 in /etc/xrdp/xrdp.ini) and connect through
an SSH tunnel.

%package -n xorgxrdp
Version: $XORGXRDP_VERSION
Summary: Xorg drivers for xrdp (rdp-release-kit build)
License: MIT
Requires: xrdp, xorg-x11-server-Xorg, $XORG_ABI_REQ

%description -n xorgxrdp
xorgxrdp $FROM, built for this distribution's Xorg
server ($XORG_ABI_REQ).

%install
cp -a $STAGE/xrdp/. %{buildroot}/
cp -a $STAGE/xorgxrdp/. %{buildroot}/

%post
ETC=/etc/xrdp
[ -f \$ETC/rsakeys.ini ] || xrdp-keygen xrdp \$ETC/rsakeys.ini > /dev/null
chmod 600 \$ETC/rsakeys.ini
if [ ! -f \$ETC/cert.pem ]; then
    openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 \\
        -subj "/CN=\$(hostname -f 2>/dev/null || hostname)" \\
        -keyout \$ETC/key.pem -out \$ETC/cert.pem > /dev/null 2>&1
    chmod 600 \$ETC/key.pem
fi
/sbin/ldconfig
[ -d /run/systemd/system ] && systemctl daemon-reload || :

%preun
if [ \$1 -eq 0 ] && [ -d /run/systemd/system ]; then
    systemctl stop xrdp.service xrdp-sesman.service > /dev/null 2>&1 || :
fi

%postun
/sbin/ldconfig

%files
$(files "$STAGE/xrdp")
%ghost %config(noreplace) /etc/xrdp/rsakeys.ini
%ghost %config(noreplace) /etc/xrdp/cert.pem
%ghost %config(noreplace) /etc/xrdp/key.pem

%files -n xorgxrdp
$(files "$STAGE/xorgxrdp")
EOF

rpmbuild -bb --define "_topdir $TOP" --define "_libdir $LIBDIR" "$TOP/kit.spec" \
    > "$TOP/rpmbuild.log" 2>&1 || { tail -30 "$TOP/rpmbuild.log" >&2; exit 1; }
find "$TOP/RPMS" -name '*.rpm' -exec cp {} "$OUT/" \;
rm -rf "$TOP"
