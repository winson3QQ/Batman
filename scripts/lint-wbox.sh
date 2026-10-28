#!/bin/bash
# lint-wbox.sh [REPO] — the #254 -wbox variants (docs/design/254-h23-harness.md §4.2, §16.15, §16.23) are well formed:
#   every tests/wbox/<name>.patch
#     - carries "# wbox <name>: <what>" and "# wbox-witness: WBOX-<name>-<8 hex>"; the witness appears >= 2 times, and
#       in a .go hunk only inside a string literal (so it is in the binary the gate greps);
#     - applies to this tree (git apply --check);
#     - touches only feed/batman-prov/ and feed/batman-provision/ (the packages the build cleans), and renames / copies
#       nothing (a rename's source would escape that check);
#     - names a new uci-defaults file 99zz-wbox-* (runs after 99zz-batman-prov-state) and a new init script wbox-*;
#   tests/wbox/helpers.list == the list derived from the patches: "<name> <tag> <kind>", tag prov_test when the patch
#   touches feed/batman-prov/src/ (and for `test`), else release; kind helper when it touches feed/batman-prov/src/ or
#   replaces the helper install (GoPackage/Package/Install/Bin removed), else same; plus "test prov_test helper".
# No patch at all is a FAIL, never a pass.
set -u
R=$(cd "${1:-$(dirname "$0")/..}" && pwd)
D=$R/tests/wbox
bad=0; n=0
say(){ echo "lint-wbox: $*"; }
err(){ say "FAIL: $*"; bad=$((bad+1)); }
[ -f "$D/helpers.list" ] || { say "FAIL: no $D/helpers.list"; exit 1; }
want=$(mktemp); trap 'rm -f "$want"' EXIT
echo "test prov_test helper" > "$want"
for p in "$D"/*.patch; do
	[ -f "$p" ] || continue
	n=$((n+1)); name=$(basename "$p" .patch)
	case "$name" in *[!a-z0-9-]*|test) err "$name: bad variant name"; continue ;; esac
	head -1 "$p" | grep -q "^# wbox $name: ." || err "$name: first line is not '# wbox $name: <what>'"
	wit=$(sed -n 's/^# wbox-witness: //p' "$p" | head -1)
	case "$wit" in WBOX-"$name"-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;; *) err "$name: witness '$wit' is not WBOX-$name-<8 hex>"; wit="" ;; esac
	if [ -n "$wit" ]; then
		[ "$(grep -c -- "$wit" "$p")" -ge 2 ] || err "$name: witness appears < 2 times"
		# inside a string literal = an odd number of unescaped double quotes before the witness on that line
		gobad=$(awk -v w="$wit" '/^\+\+\+ /{f=$2} f ~ /\.go$/ && /^\+/ && (i = index($0, w)) {
			pre = substr($0, 1, i - 1); gsub(/\\\\/, "", pre); gsub(/\\"/, "", pre); q = gsub(/"/, "", pre); if (q % 2 == 0) print }' "$p")
		[ -z "$gobad" ] || err "$name: witness outside a string literal in a .go hunk: $gobad"
		goany=$(awk -v w="$wit" '/^\+\+\+ /{f=$2} f ~ /\.go$/ && /^\+/ && index($0, w) {c++} END{print c+0}' "$p")
		if grep -q '^+++ b/.*\.go$' "$p" && [ "$goany" = 0 ]; then err "$name: touches .go files but no .go line carries the witness"; fi
	fi
	git -C "$R" apply --check "$p" 2>/dev/null || err "$name: does not apply to this tree"
	git -C "$R" apply --numstat --summary "$p" > /tmp/lint-wbox.$$ 2>/dev/null || { err "$name: git apply cannot read it"; continue; }
	grep -qE '^(rename|copy) (from|to) ' "$p" && err "$name: renames / copies a file (not allowed: a rename's source escapes the scope check)"
	paths=$(awk -F'\t' 'NF >= 3 {print $3}' /tmp/lint-wbox.$$); rm -f /tmp/lint-wbox.$$
	[ -n "$paths" ] || err "$name: changes no file"
	for f in $paths; do
		case "$f" in feed/batman-prov/*|feed/batman-provision/*) ;; *) err "$name: touches $f (only feed/batman-prov{,ision}/)" ;; esac
	done
	for f in $(grep '^+++ b/' "$p" | sed 's#^+++ b/##'); do
		grep -q -- "^--- /dev/null" <(grep -B1 -F "+++ b/$f" "$p") || continue   # only NEW files
		case "$f" in
			*/files/etc/uci-defaults/*) case "${f##*/}" in 99zz-wbox-*) ;; *) err "$name: new uci-defaults file ${f##*/} (want 99zz-wbox-*)" ;; esac ;;
			*/files/etc/init.d/*) case "${f##*/}" in wbox-*) ;; *) err "$name: new init script ${f##*/} (want wbox-*)" ;; esac ;;
		esac
	done
	tag=release; kind=same
	echo "$paths" | grep -q '^feed/batman-prov/src/' && { tag=prov_test; kind=helper; }
	grep -q '^-.*GoPackage/Package/Install/Bin' "$p" && kind=helper
	echo "$name $tag $kind" >> "$want"
done
[ "$n" -gt 0 ] || err "no tests/wbox/*.patch at all"
have=$(grep -v '^[[:space:]]*#' "$D/helpers.list" | sed '/^[[:space:]]*$/d' | awk '{print $1, $2, $3}' | sort)
exp=$(sort "$want")
if [ "$have" != "$exp" ]; then err "tests/wbox/helpers.list differs from the patches:"; diff <(echo "$exp") <(echo "$have") | sed 's/^/  /'; fi
if [ $bad = 0 ]; then say "ok ($n patches + test; helpers.list matches)"; exit 0; fi
say "$bad problem(s)"; exit 1
