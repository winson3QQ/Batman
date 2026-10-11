#!/bin/sh
# check-eudhandler-264.sh — prove the shipped #264 file is exactly "pinned upstream + this patch, as the
# generator makes it", and that it passes the offline handle() tests. Needs no docker image (CI-safe).
#
#   check-eudhandler-264.sh                 # CI: committed files only
#   check-eudhandler-264.sh --image <ref>   # dev/node: also the image's OWN EudHandler.py == pinned upstream
#                                           # (a re-built image under the same tag must not silently get
#                                           # the overlay — review 5d). docker create + cp; nothing executes.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
F="$HERE/EudHandler-264.py"; P="$HERE/eudhandler-264.patch"
want=$(tr -d ' \r\n' < "$HERE/UPSTREAM_SHA256")
SP=/app/venv/lib/python3.13/site-packages/opentakserver/eud_handler/EudHandler.py
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $*"; exit 1; }

# 1. reverse-apply the patch to the shipped file -> must be byte-identical to the pinned upstream
cp "$F" "$T/up.py"
patch -s -R "$T/up.py" < "$P" || fail "eudhandler-264.patch does not reverse-apply to EudHandler-264.py"
got=$(sha256sum < "$T/up.py" | cut -d' ' -f1)
[ "$got" = "$want" ] || fail "reconstructed upstream sha256 $got != UPSTREAM_SHA256 $want"
echo "ok   upstream reconstructed (sha256 $want)"

# 2. the generator, run on that upstream, reproduces the shipped file exactly (generator not stale)
python3 "$HERE/make-eudhandler-264.py" "$T/up.py" "$T/gen.py" >/dev/null || fail "make-eudhandler-264.py failed"
cmp -s "$T/gen.py" "$F" || fail "EudHandler-264.py is not what make-eudhandler-264.py generates — regenerate"
echo "ok   generator reproduces EudHandler-264.py"

# 3. the committed patch is exactly diff -u upstream -> shipped (header lines aside)
{ diff -u "$T/up.py" "$F" || true; } | tail -n +3 > "$T/gen.body"
tail -n +3 "$P" > "$T/repo.body"
cmp -s "$T/gen.body" "$T/repo.body" || fail "eudhandler-264.patch is stale — regenerate"
echo "ok   patch == diff -u upstream EudHandler-264.py"

# 4. offline handle() tests on the shipped file
python3 "$HERE/test-eudhandler-264.py" "$F" > "$T/test.out" 2>&1 || true
tail -1 "$T/test.out" | grep -qx "ALL PASS" || { cat "$T/test.out"; fail "offline handle() tests"; }
echo "ok   offline handle() tests ($(grep -c '^PASS' "$T/test.out") cases)"

# 5. optional: the image's own file (no mount) is the pinned upstream
if [ "${1:-}" = --image ]; then
	img=${2:?--image needs a ref}
	c=$(docker create --pull=never --platform linux/arm64 "$img") || fail "docker create $img"
	docker cp "$c:$SP" "$T/img.py" >/dev/null 2>&1; docker rm "$c" >/dev/null 2>&1 || true
	[ -f "$T/img.py" ] || fail "could not copy $SP out of $img"
	got=$(sha256sum < "$T/img.py" | cut -d' ' -f1)
	[ "$got" = "$want" ] || fail "$img's own EudHandler.py sha256 $got != pinned upstream $want — the overlay was made for a different file"
	echo "ok   $img EudHandler.py == pinned upstream"
fi
echo "ALL OK"
