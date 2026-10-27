#!/usr/bin/env bash
# Compares every upstream source in sources.lock with the newest release
# upstream has tagged, reading the tags with git ls-remote (no API, no token).
#
#   ./check-upstream.sh          one line per source: name, pinned, newest, status
#
# Prints "update" where upstream is ahead; exits 0 either way (a person
# decides what to bump). Our own preview sources are not checked (FreeRDP
# among them: every client builds our frozen preview of its master; xrdp
# and xorgxrdp too: the packages build our xrdp release and xorgxrdp's
# development commit);
# freerdp-web and freerdp-tk are, because the kit takes them by their releases.
set -euo pipefail
cd "$(dirname "$0")"

# name  repository  tag pattern (ERE)  tag prefix to drop
# Lines follow the stable series the kit pins on purpose: OpenSSL's 3.5
# LTS, SDL's stable (even) minor releases, for the native and the web client alike.
WATCH=(
	"sdl3        https://github.com/libsdl-org/SDL.git            ^release-3\.[0-9]*[02468]\.[0-9]+$   release-"
	"sdl3_wasm   https://github.com/libsdl-org/SDL.git            ^release-3\.[0-9]*[02468]\.[0-9]+$   release-"
	"sdl3_ttf    https://github.com/libsdl-org/SDL_ttf.git        ^release-3\.[0-9]*[02468]\.[0-9]+$   release-"
	"freetype    https://gitlab.freedesktop.org/freetype/freetype.git ^VER-[0-9]+-[0-9]+-[0-9]+$      VER-"
	"openssl     https://github.com/openssl/openssl.git           ^openssl-3\.5\.[0-9]+$               openssl-"
	"opus        https://github.com/xiph/opus.git                 ^v[0-9]+\.[0-9]+(\.[0-9]+)?$          v"
	"dav1d       https://code.videolan.org/videolan/dav1d.git     ^[0-9]+\.[0-9]+\.[0-9]+$             ''"
	"zlib        https://github.com/madler/zlib.git               ^v[0-9]+\.[0-9]+(\.[0-9]+)*$          v"
	"jansson     https://github.com/akheron/jansson.git           ^v[0-9]+\.[0-9]+(\.[0-9]+)?$          v"
	"libressl    https://github.com/libressl/portable.git         ^v[0-9]+\.[0-9]+\.[0-9]+$             v"
	"llvm_mingw  https://github.com/mstorsjo/llvm-mingw.git       ^[0-9]{8}$                           ''"
	# ours: release tags have no prefix since 2026-10-25, v<version> before
	"freerdp_web https://github.com/congzhangzh/freerdp-web.git   ^v?[0-9]+\.[0-9]+(\.[0-9]+)?$        v"
	"freerdp_tk  https://github.com/congzhangzh/freerdp-tk.git    ^v?[0-9]+\.[0-9]+(\.[0-9]+)?$        v"
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

# Our changes on their way upstream: the state of every pull request and
# issue a pin's change line in pins.notes names (GitHub's API, through gh).
# "all-upstream" on a pin's last line: every one is merged or fixed, so the
# pin can go back to an upstream release.
echo
printf '%-15s %-34s %s\n' ours upstream state
awk -F'|' '/^change / { split($1, n, " "); if ($5 ~ /[^ \t]/) print n[2], $5 }' pins.notes |
	while read -r name refs; do
		done_all=yes
		for ref in $refs; do
			repo=${ref%#*} number=${ref#*#}
			state=$(gh api "repos/$repo/issues/$number" -q \
				'if .pull_request then (if .pull_request.merged_at then "merged" else .state end) + " (PR)"
				 else .state + (if .state_reason then " " + .state_reason else "" end) + " (issue)" end' \
				2> /dev/null) || state=unknown
			case $state in "merged (PR)" | "closed completed (issue)") ;; *) done_all=no ;; esac
			printf '%-15s %-34s %s\n' "$name" "$ref" "$state"
		done
		[ $done_all = yes ] && printf '%-15s %-34s %s\n' "$name" all-upstream "move the pin back to an upstream release"
	done
