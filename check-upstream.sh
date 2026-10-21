#!/usr/bin/env bash
# Compares every upstream source in sources.lock with the newest release
# upstream has tagged, reading the tags with git ls-remote (no API, no token).
#
#   ./check-upstream.sh          one line per source: name, pinned, newest, status
#
# Prints "update" where upstream is ahead; exits 0 either way (a person
# decides what to bump). Our own preview sources are not checked;
# freerdp-web is, because the kit takes it by its releases.
set -euo pipefail
cd "$(dirname "$0")"

# name  repository  tag pattern (ERE)  tag prefix to drop
# Lines follow the stable series the kit pins on purpose: OpenSSL's 3.5
# LTS, SDL's stable (even) minor releases, SDL 3.2 for the web client.
WATCH=(
	"freerdp     https://github.com/FreeRDP/FreeRDP.git           ^[0-9]+\.[0-9]+\.[0-9]+$             ''"
	"sdl3        https://github.com/libsdl-org/SDL.git            ^release-3\.[0-9]*[02468]\.[0-9]+$   release-"
	"sdl3_wasm   https://github.com/libsdl-org/SDL.git            ^release-3\.2\.[0-9]+$               release-"
	"sdl3_ttf    https://github.com/libsdl-org/SDL_ttf.git        ^release-3\.[0-9]*[02468]\.[0-9]+$   release-"
	"freetype    https://gitlab.freedesktop.org/freetype/freetype.git ^VER-[0-9]+-[0-9]+-[0-9]+$      VER-"
	"openssl     https://github.com/openssl/openssl.git           ^openssl-3\.5\.[0-9]+$               openssl-"
	"opus        https://github.com/xiph/opus.git                 ^v[0-9]+\.[0-9]+(\.[0-9]+)?$          v"
	"dav1d       https://code.videolan.org/videolan/dav1d.git     ^[0-9]+\.[0-9]+\.[0-9]+$             ''"
	"zlib        https://github.com/madler/zlib.git               ^v[0-9]+\.[0-9]+(\.[0-9]+)*$          v"
	"jansson     https://github.com/akheron/jansson.git           ^v[0-9]+\.[0-9]+(\.[0-9]+)?$          v"
	"xrdp        https://github.com/neutrinolabs/xrdp.git         ^v[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?$  v"
	"xorgxrdp    https://github.com/neutrinolabs/xorgxrdp.git     ^v[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?$  v"
	"libressl    https://github.com/libressl/portable.git         ^v[0-9]+\.[0-9]+\.[0-9]+$             v"
	"llvm_mingw  https://github.com/mstorsjo/llvm-mingw.git       ^[0-9]{8}$                           ''"
	"freerdp_web https://github.com/congzhangzh/freerdp-web.git   ^v[0-9]+\.[0-9]+(\.[0-9]+)?$         v"
	"pipewire_xrdp https://github.com/neutrinolabs/pipewire-module-xrdp.git ^v[0-9]+\.[0-9]+(\.[0-9]+)?$ v"
)

pinned() { awk -v n="$1" '$1 == n { print $2 }' sources.lock; }

newest() { # repo pattern prefix
	git ls-remote --tags --refs "$1" 2> /dev/null |
		sed 's|.*refs/tags/||' | grep -E "$2" | sed "s|^$3||; s|-|.|g" | sort -V | tail -1
}

printf '%-11s %-10s %-10s %s\n' source pinned newest status
for line in "${WATCH[@]}"; do
	read -r name repo pattern prefix <<< "$line"
	[ "$prefix" = "''" ] && prefix=
	have=$(pinned "$name")
	latest=$(newest "$repo" "$pattern" "$prefix") || latest=
	if [ -z "$latest" ]; then
		status="unknown (no tags read)"
	elif [ "$latest" = "$have" ]; then
		status=ok
	elif [ "$(printf '%s\n%s\n' "$have" "$latest" | sort -V | tail -1)" = "$latest" ]; then
		status=update
	else
		status="ok (pinned is newer)"
	fi
	printf '%-11s %-10s %-10s %s\n' "$name" "$have" "${latest:--}" "$status"
done

# x264 has no releases: the kit pins a commit of its stable branch
have=$(awk '$1 == "x264" { print $4 }' sources.lock)
head=$(git ls-remote https://code.videolan.org/videolan/x264.git refs/heads/stable 2> /dev/null | cut -f1) || head=
if [ -z "$head" ]; then status="unknown (no branch read)"
elif [ "$head" = "$have" ]; then status=ok
else status=update; fi
printf '%-11s %-10s %-10s %s\n' x264 "${have:0:7}" "${head:0:7}" "$status"
