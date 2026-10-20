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
    tag=$3; shift 3; files=()
    while [ $# -gt 0 ]; do
        case $1 in
            --repo | --target | --title | --notes) shift 2 ;;
            --*) shift ;;
            *) files+=("$(basename "$1") sha256:$(sha256sum < "$1" | cut -d' ' -f1)"); shift ;;
        esac
    done
    [ -f "$S/drop" ] && unset 'files[-1]'
    [ -f "$S/corrupt" ] && files[-1]="${files[-1]% *} sha256:0000"
    id=$((100 + $(jq length "$S/releases.json")))
    jq --arg t "$tag" --argjson id "$id" \
        '. + [{id: $id, tag_name: $t, draft: true,
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
        GITHUB_REPOSITORY=o/r GITHUB_SHA=0123456789abcdef \
        "$KIT/build/publish-prerelease.sh" "$tag" title notes "$@" 2>&1)
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
publish web-a-b client.zip missing.deb
check "a missing file stops it before any call" '[ $rc != 0 ] && [ ! -s "$TMP/state/gh.log" ]'

echo "passed $pass, failed $fail"
[ "$fail" = 0 ]
