# shellcheck shell=bash
# Builder images, sourced by the host build scripts: a stock image with
# one build's tools already installed (build/tools.sh), made once and
# kept, so a build no longer starts with a round of apt or dnf.
#
#   image=$(builder <stock image> <windows|wasm|xrdp>)
#
# The image is rdp-release-kit-<kind>:<stock image as a tag>, labelled
# with a hash of what goes into it: the stock image's name, tools.sh, the
# dependency lists, FLAVOUR and NO_AV1. It is made again when that hash
# changes, or when it is older than BUILDER_DAYS (default 7, for the
# distributions' security updates). BUILDER=off runs the stock image, and
# the build installs its tools itself. Expects KIT and ENGINE.
builder() {
    local base=$1 kind=$2 name hash made old ctx
    if [ "${BUILDER:-}" = off ]; then
        echo "$base"
        return 0
    fi
    [ "$kind" = xrdp ] && kind+=-${FLAVOUR:-stable}${NO_AV1:+-noav1}
    # a tag: letters, digits, _ . -, at most 128
    name=rdp-release-kit-$kind:$(printf '%s' "$base" | tr -c 'A-Za-z0-9_.-' - | cut -c1-128)
    hash=$({ echo "$base $kind"; cat "$KIT/build/tools.sh" "$KIT"/deps/*.txt; } |
        sha256sum | cut -c1-16)
    if made=$("$ENGINE" image inspect \
            -f '{{index .Config.Labels "rdp-release-kit.tools"}} {{index .Config.Labels "rdp-release-kit.made"}}' \
            "$name" 2> /dev/null); then
        if [ "${made% *}" = "$hash" ] && [[ ${made#* } =~ ^[0-9]+$ ]] &&
            [ $(($(date +%s) - ${made#* })) -lt $((${BUILDER_DAYS:-7} * 86400)) ]; then
            echo "$name"
            return 0
        fi
        old=$("$ENGINE" image inspect -f '{{.Id}}' "$name")
    fi

    echo "== builder image $name (made once, kept for ${BUILDER_DAYS:-7} days)" >&2
    ctx=$(mktemp -d)
    mkdir -p "$ctx/build"
    cp "$KIT/build/tools.sh" "$ctx/build/"
    cp -r "$KIT/deps" "$ctx/"
    cat > "$ctx/Dockerfile" << EOF
FROM $base
COPY . /tools
RUN FLAVOUR=${FLAVOUR:-stable} NO_AV1=${NO_AV1:-} bash /tools/build/tools.sh /tools ${kind%%-*} \\
    && rm -rf /tools
ENV KIT_TOOLS=$hash
LABEL rdp-release-kit.tools=$hash rdp-release-kit.made=$(date +%s)
EOF
    if ! "$ENGINE" build -q -f "$ctx/Dockerfile" -t "$name" "$ctx" > /dev/null; then
        rm -rf "$ctx"
        echo "builder image $name: failed" >&2
        return 1
    fi
    rm -rf "$ctx"
    # the image it replaces, unless a container still uses it
    [ -z "${old:-}" ] || "$ENGINE" rmi "$old" > /dev/null 2>&1 || true
    echo "$name"
}
