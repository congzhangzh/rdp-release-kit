#!/bin/bash
# the checks are strings that check() evaluates
# shellcheck disable=SC2016,SC2034
# Tests build/publish-prerelease.sh against a fake gh that keeps the
# releases in a JSON file: a pre-release is published once, complete,
# and never replaced (docs/RELEASE.md, "Frozen releases").
#
#   test/publish.sh
set -uo pipefail

KIT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
check() {
    if eval "$2"; then
        echo "PASS  $1"; pass=$((pass + 1))
    else
        echo "FAIL  $1"; fail=$((fail + 1))
    fi
}

# the fake gh: releases.json holds the releases (drafts too), each asset
# with its digest, as GitHub's; tags holds the tags. offline makes every
# call fail as without a network; drop loses the last file of an upload,
# corrupt changes its bytes
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" << 'EOF'
#!/bin/bash
S=$STATE
echo "$*" >> "$S/gh.log"
[ -f "$S/offline" ] && { echo "error connecting to api.github.com" >&2; exit 1; }
notfound() { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
if [ "$1 $2" = "release create" ]; then
    tag=$3; shift 3; files=() title= pre=false
    while [ $# -gt 0 ]; do
        case $1 in
            --title) title=$2; shift 2 ;;
            --prerelease) pre=true; shift ;;
            --repo | --target | --notes) shift 2 ;;
            --*) shift ;;
            *) files+=("$(basename "$1") sha256:$(sha256sum < "$1" | cut -d' ' -f1)"); shift ;;
        esac
    done
    [ -f "$S/drop" ] && unset 'files[-1]'
    [ -f "$S/corrupt" ] && files[-1]="${files[-1]% *} sha256:0000"
    id=$((100 + $(jq length "$S/releases.json")))
    jq --arg t "$tag" --arg n "$title" --argjson id "$id" --argjson pre "$pre" \
        '. + [{id: $id, tag_name: $t, name: $n, draft: true, prerelease: $pre,
               assets: [$ARGS.positional[] | split(" ") | {name: .[0], digest: .[1]}]}]' \
        "$S/releases.json" --args "${files[@]}" > "$S/r" && mv "$S/r" "$S/releases.json"
    exit 0
fi
[ "$1" = api ] || { echo "fake gh: $*" >&2; exit 2; }
shift
method=GET q= path= fields=()
while [ $# -gt 0 ]; do
    case $1 in
        -X) method=$2; shift 2 ;;
        -q) q=$2; shift 2 ;;
        -F | -f) fields+=("$2"); shift 2 ;;
        --*) shift ;;
        *) path=$(sed -E 's|^repos/[^/]+/[^/]+/||' <<< "$1"); shift ;;
    esac
done
case "$method $path" in
    "GET releases/tags/"*)
        out=$(jq --arg t "${path#releases/tags/}" '.[] | select(.tag_name == $t and (.draft | not))' "$S/releases.json")
        [ -n "$out" ] || notfound ;;
    "GET git/ref/tags/"*)
        grep -qx -- "${path#git/ref/tags/}" "$S/tags" || notfound
        out='{}' ;;
    "GET releases?per_page=100")
        out=$(cat "$S/releases.json") ;;
    "GET git/matching-refs/tags/"*)
        out=$(grep -- "^${path#git/matching-refs/tags/}" "$S/tags" | jq -R '{ref: ("refs/tags/" + .)}' | jq -s .) ;;
    "DELETE releases/"*)
        jq --argjson id "${path#releases/}" 'map(select(.id != $id))' "$S/releases.json" > "$S/r" &&
            mv "$S/r" "$S/releases.json"
        out='{}' ;;
    "PATCH releases/"*)
        [[ " ${fields[*]} " = *" draft=false "* ]] || { echo "fake gh: PATCH without draft=false" >&2; exit 2; }
        id=${path#releases/}
        jq -r --argjson id "$id" '.[] | select(.id == $id) | .tag_name' "$S/releases.json" >> "$S/tags"
        jq --argjson id "$id" 'map(if .id == $id then .draft = false else . end)' "$S/releases.json" > "$S/r" &&
            mv "$S/r" "$S/releases.json"
        out='{}' ;;
    *) echo "fake gh: $method $path" >&2; exit 2 ;;
esac
[ -z "$q" ] || jq -r "$q" <<< "$out"
EOF
chmod +x "$TMP/bin/gh"

fresh() { # an empty repository: no releases, no tags
    rm -rf "$TMP/state"
    mkdir -p "$TMP/state"
    echo '[]' > "$TMP/state/releases.json"
    : > "$TMP/state/tags"
    : > "$TMP/state/gh.log"
}
publish() { # <tag> <file>...; output in $out, exit status in $rc
    local tag=$1
    shift
    out=$(cd "$TMP" && PATH="$TMP/bin:$PATH" STATE="$TMP/state" GH_TOKEN=x \
        GITHUB_REPOSITORY=o/r GITHUB_SHA=0123456789abcdef LATEST=${LATEST:-} \
        "$KIT/build/publish-prerelease.sh" "$tag" "${TITLE:-title}" notes "$@" 2>&1)
    rc=$?
}
published() { jq -r --arg t "$1" '[.[] | select(.tag_name == $t and (.draft | not))] | length' "$TMP/state/releases.json"; }
drafts() { jq -r '[.[] | select(.draft)] | length' "$TMP/state/releases.json"; }
assets() { jq -r --arg t "$1" '.[] | select(.tag_name == $t) | .assets[].name' "$TMP/state/releases.json" | LC_ALL=C sort | tr '\n' ' '; }

echo zip > "$TMP/client.zip"
echo sums > "$TMP/SHA256SUMS"

fresh
publish web-a-b client.zip SHA256SUMS
check "a new tag is published" '[ $rc = 0 ] && [ "$(published web-a-b)" = 1 ] && [ "$(drafts)" = 0 ]'
check "with every file" '[ "$(assets web-a-b)" = "SHA256SUMS client.zip " ]'
check "as a draft first, then published" \
    'grep -q -- "release create web-a-b .*--draft" "$TMP/state/gh.log" && grep -q "PATCH .*draft=false" "$TMP/state/gh.log"'
check "its tag is made" 'grep -qx web-a-b "$TMP/state/tags"'

calls=$(wc -l < "$TMP/state/gh.log")
echo other > "$TMP/client.zip"
publish web-a-b client.zip SHA256SUMS
check "a published tag is left as it is" '[ $rc = 0 ] && grep -q "published already" <<< "$out"'
check "and nothing is uploaded or changed" \
    '[ "$(tail -n +$((calls + 1)) "$TMP/state/gh.log" | grep -c -v "^api repos/o/r/releases/tags/")" = 0 ]'

publish web-c-d client.zip
check "another tag next to it is published too" '[ $rc = 0 ] && [ "$(published web-c-d)" = 1 ] && [ "$(published web-a-b)" = 1 ]'

fresh
echo web-a-b > "$TMP/state/tags"
publish web-a-b client.zip
check "a tag without a release is refused" '[ $rc != 0 ] && grep -q "never used twice" <<< "$out"'
check "and nothing is created" '! grep -q "release create" "$TMP/state/gh.log"'

fresh
echo '[{"id": 7, "tag_name": "web-a-b", "draft": true, "assets": [{"name": "half.zip"}]}]' > "$TMP/state/releases.json"
publish web-a-b client.zip SHA256SUMS
check "a draft a failed run left is deleted" '[ $rc = 0 ] && grep -q "DELETE repos/o/r/releases/7" "$TMP/state/gh.log"'
check "and the release has only this run's files" \
    '[ "$(published web-a-b)" = 1 ] && [ "$(drafts)" = 0 ] && [ "$(assets web-a-b)" = "SHA256SUMS client.zip " ]'

fresh
touch "$TMP/state/offline"
publish web-a-b client.zip
check "no network: an error, not taken for 'not published'" \
    '[ $rc != 0 ] && grep -q "error connecting" <<< "$out" && ! grep -q "release create" "$TMP/state/gh.log"'

fresh
touch "$TMP/state/drop"
publish web-a-b client.zip SHA256SUMS
check "a file missing after the upload fails the step" '[ $rc != 0 ] && grep -q "differ" <<< "$out"'

fresh
touch "$TMP/state/corrupt"
publish web-a-b client.zip SHA256SUMS
check "a file whose bytes changed on the way fails the step" '[ $rc != 0 ] && grep -q "differ" <<< "$out"'

fresh
publish web-a-b client.zip
check "a pre-release is marked so, and never made latest" \
    '[ "$(jq -r ".[0].prerelease" "$TMP/state/releases.json")" = true ] && grep -q "PATCH .*make_latest=false" "$TMP/state/gh.log"'
fresh
LATEST=1 publish 20261021.1 client.zip
check "LATEST=1: a release, not a pre-release, made latest" \
    '[ $rc = 0 ] && [ "$(jq -r ".[0].prerelease" "$TMP/state/releases.json")" = false ] && grep -q "PATCH .*make_latest=true" "$TMP/state/gh.log"'

fresh
publish web-a-b client.zip missing.deb
check "a missing file stops it before any call" '[ $rc != 0 ] && [ ! -s "$TMP/state/gh.log" ]'

# the names: <kind>-<YYYYMMDD>.<N>-<kit commit, 12> (build/prerelease-tag.sh)
name() { # <kind> <title> [kit commit]; the tag in $out, exit status in $rc
    out=$(cd "$TMP" && PATH="$TMP/bin:$PATH" STATE="$TMP/state" GH_TOKEN=x DAY=20261021 \
        GITHUB_REPOSITORY=o/r GITHUB_SHA=${3:-0123456789abcdef} \
        "$KIT/build/prerelease-tag.sh" "$1" "$2" 2>&1)
    rc=$?
}
fresh
name web "Web client for freerdp-web p1 (kit k1)"
check "the first build of a day is .1" '[ $rc = 0 ] && [ "$out" = web-20261021.1-0123456789ab ]'
TITLE="Web client for freerdp-web p1 (kit k1)" publish "$out" client.zip
name web "Web client for freerdp-web p1 (kit k1)"
check "a second run of the same build gets the same name" '[ "$out" = web-20261021.1-0123456789ab ]'
TITLE="Web client for freerdp-web p1 (kit k1)" publish "$out" client.zip
check "and publishes nothing new" '[ $rc = 0 ] && grep -q "published already" <<< "$out"'
name web "Web client for freerdp-web p1 (kit k2)" fedcba9876543210
check "the next build that day is .2, with its kit commit" '[ "$out" = web-20261021.2-fedcba987654 ]'
name xrdp-preview "xrdp preview x1 (kit k2)" fedcba9876543210
check "each kind counts on its own" '[ "$out" = xrdp-preview-20261021.1-fedcba987654 ]'
name pipewire-module-xrdp "pipewire-module-xrdp 0.2 (748f562d6165) for Fedora 43,44,45 (inputs i1)" fedcba9876543210
check "PipeWire's xrdp module is a kind of its own" '[ "$out" = pipewire-module-xrdp-20261021.1-fedcba987654 ]'
echo '[{"id": 9, "tag_name": "web-20261021.4-aaaaaaaaaaaa", "name": "Web client for freerdp-web p0 (kit k0)", "draft": true}]' \
    > "$TMP/state/releases.json"
echo web-20261021.6-bbbbbbbbbbbb >> "$TMP/state/tags"
name web "Web client for freerdp-web p2 (kit k3)"
check "drafts and tags without a release count too: never a name twice" '[ "$out" = web-20261021.7-0123456789ab ]'
name web "Web client for freerdp-web p0 (kit k0)"
check "a draft an earlier run left keeps its name" '[ "$out" = web-20261021.4-aaaaaaaaaaaa ]'
fresh
echo '[{"id": 3, "tag_name": "web-06593c161e5d-68feb5b6f42a", "name": "Web client for freerdp-web 06593c161e5d (kit 68feb5b6f42a)", "draft": false}]' \
    > "$TMP/state/releases.json"
name web "Web client for freerdp-web 06593c161e5d (kit 68feb5b6f42a)"
check "a build published under the older name keeps it" '[ "$out" = web-06593c161e5d-68feb5b6f42a ]'
name web "Web client for freerdp-web 06593c161e5d (kit k9)"
check "older names don't count for N" '[ "$out" = web-20261021.1-0123456789ab ]'
fresh
name release "FreeRDP 3.32.2 clients, xrdp 0.10.6.1 (kit k1)"
check "the kit's release is <YYYYMMDD>.<N> alone" '[ $rc = 0 ] && [ "$out" = 20261021.1 ]'
echo 20261021.1 >> "$TMP/state/tags"
echo web-20261021.5-aaaaaaaaaaaa >> "$TMP/state/tags"
name release "FreeRDP 3.32.2 clients, xrdp 0.10.6.1 (kit k2)" fedcba9876543210
check "the next one that day is .2; other kinds don't count" '[ "$out" = 20261021.2 ]'
name stable "x"
check "an unknown kind is refused" '[ $rc != 0 ]'
fresh
touch "$TMP/state/offline"
name web "Web client for freerdp-web p1 (kit k1)"
check "no network: an error, not a name" '[ $rc != 0 ] && ! grep -q "^web-" <<< "$out"'

echo "passed $pass, failed $fail"
[ "$fail" = 0 ]
