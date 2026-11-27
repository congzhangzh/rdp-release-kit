#!/bin/bash
# Signs a macOS package of the kit, inside out, ad hoc or with a Developer ID:
#
#   sign-mac.sh host   <package dir> -                           ad hoc (every build)
#   sign-mac.sh host   <package dir> <identity> <team id> <host profile> <camera profile>
#   sign-mac.sh client <package dir> -
#   sign-mac.sh client <package dir> <identity> <team id>
#
# <package dir> holds FreeRDP-Shadow.app (host) or FreeRDP.app (client), as
# build-macos-client.sh lays it out. The bundle ids are read from the apps' own Info.plists
# (built from KIT_MAC_ID_PREFIX), so there is one source for them:
#   host     <prefix>.freerdp-shadow         FreeRDP-Shadow.app, freerdp-shadow-cli
#            <prefix>.freerdp-shadow.agent   Contents/MacOS/freerdp-shadow-agent
#            <prefix>.freerdp-shadow.camera  the camera extension
#   client   <prefix>.freerdp                FreeRDP.app, sdl-freerdp
# Ad hoc (identity -): no hardened runtime, no timestamp, no restricted entitlement (as every
# kit build so far). With an identity (the SHA-1 of a "Developer ID Application" certificate
# in the keychain search list): --options runtime --timestamp on every Mach-O, the profiles
# embedded, the entitlements with com.apple.application-identifier and
# com.apple.developer.team-identifier, the extension's Mach service set to <team>.<app id>.camera.
# Bash 3.2 is enough.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
PB=/usr/libexec/PlistBuddy
die() { echo "sign-mac.sh: $*" >&2; exit 1; }

WHAT=${1:?host or client}
PKG=$(cd "${2:?package dir}" && pwd)
IDENTITY=${3:?identity, or - for ad hoc}
TEAM=${4:-}
TMP=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/sign-mac.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

FLAGS=(--force --sign "$IDENTITY")
if [ "$IDENTITY" != - ]; then
    [ -n "$TEAM" ] || die "a Developer ID signature needs the team id"
    case $TEAM in *[!A-Z0-9]* | '') die "not a team id: $TEAM" ;; esac
    FLAGS+=(--options runtime --timestamp)
fi

# entitlements <template> <bundle id> <app id for the group> <out>: @TEAM_ID@ and @BUNDLE_ID@
# filled in, plus the identifiers a profile is matched against (Developer ID only)
entitlements() {
    local team=${TEAM:-$ADHOC_TEAM}
    sed "s/@TEAM_ID@/$team/g; s/@BUNDLE_ID@/$3/g" "$1" > "$4"
    if [ "$IDENTITY" != - ]; then
        "$PB" -c "Add :com.apple.application-identifier string $TEAM.$2" "$4"
        "$PB" -c "Add :com.apple.developer.team-identifier string $TEAM" "$4"
    fi
    plutil -lint "$4" > /dev/null
}

# profile <file> <bundle id> <bundle>: the profile is for this team and app id, then embedded
profile() {
    [ -s "$1" ] || die "no provisioning profile $1"
    security cms -D -i "$1" > "$TMP/profile.plist" 2> /dev/null || die "$1 is not a provisioning profile"
    local appid team
    appid=$("$PB" -c "Print :Entitlements:com.apple.application-identifier" "$TMP/profile.plist")
    team=$("$PB" -c "Print :TeamIdentifier:0" "$TMP/profile.plist")
    [ "$team" = "$TEAM" ] || die "$1 is team $team's, not $TEAM's"
    [ "$appid" = "$TEAM.$2" ] || die "$1 is for $appid, not $TEAM.$2"
    echo "== profile for $appid: $("$PB" -c "Print :Name" "$TMP/profile.plist"), until $("$PB" -c "Print :ExpirationDate" "$TMP/profile.plist")"
    cp "$1" "$3/Contents/embedded.provisionprofile"
}

# a Mach-O by its content, not its name: the magic of a thin file (32 or 64 bit, either byte
# order), or of a fat one (cafebabe, also a Java class's: file tells them apart)
is_macho() {
    local magic
    magic=$(head -c 4 "$1" 2> /dev/null | od -An -tx1 | tr -d ' \n')
    case $magic in
        cffaedfe | cefaedfe | feedfacf | feedface) return 0 ;;
        cafebabe | bebafeca) file -b "$1" | grep -q '^Mach-O' ;;
        *) return 1 ;;
    esac
}

# the bundled Python's programs (freerdp-tk's python/bin): build/macos/python.entitlements,
# none by default (PYTHON_ENTITLEMENTS=<file> instead, for the probe that looks for the
# minimum); a file with no key is passed as no --entitlements at all
PYTHON_ENT=()
python_entitlements=${PYTHON_ENTITLEMENTS:-$HERE/python.entitlements}
if [ "$(plutil -convert json -o - "$python_entitlements")" != "{}" ]; then
    PYTHON_ENT=(--entitlements "$python_entitlements")
fi

# sign_loose: every Mach-O in the package that is not signed with its bundle, inside out (the
# deepest first): freerdp-tk's Python (python3, libpython, lib-dynload, Tcl/Tk and their
# packages), winpr-hash, the helpers in an app's Contents/MacOS. Not an app's main executable
# (signed with its app) and nothing in a .systemextension (signed with it). Ad hoc, only the
# programs that need their own identifier (as every kit build so far); with a Developer ID,
# every one, because notarization refuses an archive with one Mach-O that is not hardened.
sign_loose() {
    local f app main ident n=0
    while IFS= read -r f; do
        is_macho "$f" || continue
        case $f in *.systemextension/*) continue ;; esac
        case $f in
            */Contents/MacOS/*)
                app=${f%%/Contents/MacOS/*}
                main=$("$PB" -c "Print :CFBundleExecutable" "$app/Contents/Info.plist" 2> /dev/null || true)
                [ "$f" != "$app/Contents/MacOS/$main" ] || continue
                ;;
        esac
        ident=()
        case $f in
            */Contents/MacOS/freerdp-shadow-agent) ident=(--identifier "$ID.agent") ;;
            */Contents/MacOS/freerdp-shadow-camera) ident=(--identifier "$ID.camera-tool") ;;
            "$PKG/winpr-hash") ident=(--identifier "$ID.winpr-hash") ;;
        esac
        [ "$IDENTITY" != - ] || [ ${#ident[@]} -gt 0 ] || continue
        case $f in
            "$PKG"/python/bin/*)
                codesign "${FLAGS[@]}" ${PYTHON_ENT[@]+"${PYTHON_ENT[@]}"} "$f" ;;
            *)
                codesign "${FLAGS[@]}" ${ident[@]+"${ident[@]}"} "$f" ;;
        esac
        n=$((n + 1))
    done < <(find "$PKG" -type f | awk '{ d = gsub("/", "/"); print d, $0 }' | sort -rn | cut -d' ' -f2-)
    echo "== $n Mach-O file(s) outside the bundles' own signatures signed"
}

case $WHAT in
host)
    APP=$PKG/FreeRDP-Shadow.app
    ID=$("$PB" -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist")
    CAMERA_ID=$ID.camera
    EXT=$APP/Contents/Library/SystemExtensions/$CAMERA_ID.systemextension
    ADHOC_TEAM=UNSIGNED00
    if [ -d "$EXT" ]; then
        service=$("$PB" -c "Print :CMIOExtension:CMIOExtensionMachServiceName" "$EXT/Contents/Info.plist")
        ADHOC_TEAM=${service%%.*}
        if [ "$IDENTITY" != - ]; then
            "$PB" -c "Set :CMIOExtension:CMIOExtensionMachServiceName $TEAM.$ID.camera" "$EXT/Contents/Info.plist"
            profile "${6:?the profile of the camera extension}" "$CAMERA_ID" "$EXT"
        fi
        entitlements "$HERE/camera.entitlements.in" "$CAMERA_ID" "$ID" "$TMP/camera.entitlements"
        echo "== $CAMERA_ID"
        codesign "${FLAGS[@]}" --identifier "$CAMERA_ID" --entitlements "$TMP/camera.entitlements" "$EXT"
    fi
    # the helpers (the agent: Screen Recording and Accessibility list it by its identifier, the
    # camera commands) and winpr-hash beside the app
    sign_loose
    # the app last: its main executable freerdp-shadow-cli, its seal over all of the above
    host_entitlements=()
    if [ "$IDENTITY" != - ]; then
        profile "${5:?the profile of the app}" "$ID" "$APP"
        entitlements "$HERE/host.entitlements.in" "$ID" "$ID" "$TMP/host.entitlements"
        host_entitlements=(--entitlements "$TMP/host.entitlements")
    fi
    echo "== $ID (FreeRDP-Shadow.app)"
    codesign "${FLAGS[@]}" --identifier "$ID" ${host_entitlements[@]+"${host_entitlements[@]}"} "$APP"
    codesign --verify --strict --deep "$APP"
    ;;
client)
    APP=$PKG/FreeRDP.app
    ID=$("$PB" -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist")
    # freerdp-tk's Python and its modules (Developer ID only)
    sign_loose
    echo "== $ID (FreeRDP.app)"
    codesign "${FLAGS[@]}" --identifier "$ID" --entitlements "$HERE/client.entitlements" "$APP"
    codesign --verify --strict --deep "$APP"
    ;;
*) die "host or client, not $WHAT" ;;
esac
echo "== signed: $WHAT ($([ "$IDENTITY" = - ] && echo "ad hoc" || echo "Developer ID, team $TEAM"))"
