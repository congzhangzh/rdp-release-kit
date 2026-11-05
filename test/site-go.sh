#!/bin/bash
# the checks are strings that check() evaluates
# shellcheck disable=SC2016,SC2034
# Tests build/site-go.sh (the go must name the pinned page, on main) and
# build/site-rollback.sh (on a throwaway gh-pages: the old files come back as a
# new commit, and a branch that moved is left alone).
#
#   test/site-go.sh
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

# The go
printf '# pins\nfreerdp_web 20261105.2  git+https://example.com/web.git %040d\n' 1 > "$TMP/lock"
go() { LOCK="$TMP/lock" GITHUB_REF=${REF-refs/heads/main} "$KIT/build/site-go.sh" "$@" > "$TMP/out" 2>&1; }
check "the pinned page on main is a go" 'go 20261105.2'
check "another page is refused" '! go 20261105.1'
check "the refusal names both pages" 'grep -q "names page 20261105.1, but this commit pins 20261105.2" "$TMP/out"'
check "an empty go is refused" '! go ""'
check "a plain true is refused" '! go true'
check "a release number that is not the pin is refused" '! go 20261105.3'
check "another branch is refused" '! REF=refs/heads/topic go 20261105.2'
check "no branch at all is refused" '! REF= go 20261105.2'
printf '# no page here\n' > "$TMP/nolock"
check "no pinned page is refused" '! LOCK="$TMP/nolock" GITHUB_REF=refs/heads/main "$KIT/build/site-go.sh" 20261105.2 2> /dev/null'

# The rollback
git init -q --bare -b gh-pages "$TMP/origin.git"
git clone -q "$TMP/origin.git" "$TMP/pages" 2> /dev/null
cd "$TMP/pages" || exit 1
git config user.email t@example.com && git config user.name t
git checkout -q -b gh-pages
site() { # release, a file only this site has
    git rm -rqf . 2> /dev/null; echo "$1" > RELEASE; echo "$1" > index.html; echo x > "$2"
    git add -A && git commit -q -m "Site: $1" && git push -q origin gh-pages && git rev-parse HEAD
}
before=$(site 20261105.3 old-only.txt)
after=$(site 20261105.4 new-only.txt)
live() { git -C "$TMP/origin.git" show "gh-pages:$1" 2> /dev/null; }
out=$("$KIT/build/site-rollback.sh" "$TMP/pages" "$before" "$after" 20261105.4)
check "it prints the release that is live again" '[ "$out" = 20261105.3 ]'
check "the old RELEASE is on gh-pages" '[ "$(live RELEASE)" = 20261105.3 ]'
check "the old file is back" 'live old-only.txt > /dev/null'
check "the failed site's own file is gone" '! live new-only.txt > /dev/null'
check "the tree is exactly the old site" '[ "$(git -C "$TMP/origin.git" rev-parse "gh-pages^{tree}")" = "$(git -C "$TMP/origin.git" rev-parse "$before^{tree}")" ]'
check "it is a new commit, the failed site stays in history" '[ "$(git -C "$TMP/origin.git" rev-parse gh-pages^)" = "$after" ]'
check "the commit says why" 'git -C "$TMP/origin.git" log -1 --format=%s gh-pages | grep -q "back to kit release 20261105.3, 20261105.4 failed"'

# gh-pages moved after the failed publish: hands off
newer=$(site 20261105.5 newer-only.txt)
tip=$(git -C "$TMP/origin.git" rev-parse gh-pages)
check "a branch that moved is refused" '! "$KIT/build/site-rollback.sh" "$TMP/pages" "$before" "$after" 20261105.4 > /dev/null 2>&1'
check "and left as it is" '[ "$(git -C "$TMP/origin.git" rev-parse gh-pages)" = "$tip" ]'

echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
