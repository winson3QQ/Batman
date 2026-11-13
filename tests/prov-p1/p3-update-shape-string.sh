#!/bin/bash
# tests/prov-p1/p3-update-shape-string.sh [repo root] — #254 P3 (harness review r2 A m5 / B m8): the harness tells the
# node's network/update helper apart by c15fb54's error text "update shape" inside /usr/bin/batman-provhelper
# (scripts/dv/prov-254.sh pr_cddl_nu: 0 hits = a pre-CDDL helper, its three network/update units INVALID). A product that
# renames that text would turn those units INVALID on every image, silently. This ties both ends offline:
#  - netUpdate() in feed/batman-prov/src/node/node.go returns fail(EBadObject, "update shape") at its CDDL shape checks;
#  - pr_cddl_nu still greps the helper for that same text.
# A netUpdate without CDDL steps (main before c15fb54: a chain of bare net_configs) FAILs "predates": expected red
# until feat/254-p3 lands (#254).
# Negative control (built in): the string renamed in a copy of node.go must FAIL. Nothing found = FAIL.
set -u
ROOT=$(readlink -f "${1:-.}")
NG=$ROOT/feed/batman-prov/src/node/node.go; DV=$ROOT/scripts/dv/prov-254.sh; NEEDLE='update shape'
n=0; fail=0
ok(){ n=$((n + 1)); echo "ok   $*"; }; bad(){ n=$((n + 1)); fail=$((fail + 1)); echo "FAIL $*"; }
# judge <node.go>: prints one verdict line, rc 0 = the shape checks carry the text
judge(){ local body c
	[ -s "$1" ] || { echo "no $1"; return 1; }
	body=$(awk '/^func \(n \*Node\) netUpdate\(/{f=1} f{print} f && /^}/{exit}' "$1")
	[ -n "$body" ] || { echo "no netUpdate() in $1 — the network/update handler moved: re-point this check and pr_cddl_nu"; return 1; }
	c=$(printf '%s\n' "$body" | grep -c "fail(EBadObject, \"$NEEDLE\")")
	if [ "$c" -ge 1 ]; then echo "netUpdate() returns fail(EBadObject, \"$NEEDLE\") at $c shape check(s)"; return 0; fi
	if ! printf '%s\n' "$body" | grep -q 'item\.(cbor\.Map)'; then   # c15fb54: each step is a map
		echo "$1 predates c15fb54 (netUpdate reads a chain of bare net_configs, not CDDL steps {1: net_config, 2: member_list, ?3: net_secrets}): expected red until feat/254-p3 lands (#254)"; return 1; fi
	echo "netUpdate() checks the CDDL shape but no longer says \"$NEEDLE\" — pr_cddl_nu would call every helper pre-CDDL (three network/update units INVALID forever): keep the text or move pr_cddl_nu to the new one"
	return 1
}
if v=$(judge "$NG"); then ok "$v"; else bad "$v"; fi
if grep -q "grep -c \"$NEEDLE\"" "$DV" 2>/dev/null; then ok "pr_cddl_nu ($DV) greps the helper for \"$NEEDLE\""
else bad "pr_cddl_nu in $DV no longer greps the helper for \"$NEEDLE\" — re-point this check to what it reads now"; fi
# negative control: the same product with the text renamed
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
if [ -s "$NG" ]; then
	sed "s/\"$NEEDLE\"/\"update-shape\"/g" "$NG" > "$T/node.go"
	if cmp -s "$NG" "$T/node.go"; then ok "(negative control) nothing to rename in this node.go: the verdict above already FAILs"
	elif v=$(judge "$T/node.go"); then bad "(negative control) renamed text still PASSes: $v"
	else ok "(negative control) renamed text FAILs as it must: $v"; fi
fi
echo "P3-UPDATE-SHAPE checks=$n fail=$fail"
[ "$n" -gt 0 ] && [ "$fail" = 0 ]
