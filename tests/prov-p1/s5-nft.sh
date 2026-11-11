#!/bin/bash
# tests/prov-p1/s5-nft.sh <feed/batman-prov/files/batman-http.nft> [<batman-provhelper bulk.go>] — #254 P3 S5
# (254-p3-impl §3.8.1): the include fw4 loads must be valid nft, since an error there fails the whole firewall (F70):
# `nft -c` on both tables; the rule comments the helper looks for (read from its source, nftRules in
# src/cmd/batman-provhelper/bulk.go, review r1 A-m4) are exactly the ones in the include, each once and in its own
# table; two negative controls run through the same check: a syntax error (parser) and a jump to a chain that does not
# exist (passes the parser, refused by the kernel: "Could not process rule"). Root + nft.
# A kernel without bridge nf_tables (WSL) can check the inet table only: S5_NFT_INET_ONLY=1 says so loudly; the CI step
# asserts it is unset. Nothing checked = FAIL.
exec </dev/null
N=$(readlink -f "${1:?usage: $0 <batman-http.nft> [bulk.go]}")
[ -f "$N" ] || { echo "FAIL no $N: expected red until feat/254-p3 S5 lands (#254)"; exit 1; }
G=$(readlink -f "${2:-$(dirname "$N")/../src/cmd/batman-provhelper/bulk.go}")
[ -f "$G" ] && grep -q '^var nftRules' "$G" || { echo "FAIL no nftRules in [$G] (the helper's list of rule comments)"; exit 1; }
[ "$(id -u)" = 0 ] && command -v nft >/dev/null || { echo "FAIL needs root and nft"; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0; n=0
ck() { n=$((n + 1)); if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got [$2] want [$3]"; fail=1; fi; }
# the helper's list, per table: `nftBridge: {"…", "…"},` / `nftInet: {…}` inside `var nftRules = …{ … }`
gl() { awk '/^var nftRules/{f=1} f && /^}/{exit} f' "$G" | grep -E "^[[:space:]]*$1:" | grep -o '"[^"]*"' | tr -d '"'; }
# the include's comments, per table: the body of `table <family> <name> {` … `}`
nl_() { awk -v h="table $1 {" '$0 == h {f=1; next} f && /^}/{exit} f' "$N" | grep -o 'comment "[^"]*"' | sed 's/^comment "//; s/"$//'; }
for tb in "nftBridge|bridge batman_http" "nftInet|inet batman_http_in"; do
	k=${tb%%|*}; t=${tb#*|}
	want=$(gl "$k" | sort); have=$(nl_ "$t" | sort)
	[ -n "$want" ] || { echo "FAIL no comments for $k in $G"; exit 1; }
	ck "table $t: the include's rule comments = the helper's $k list" "$(echo $have)" "$(echo $want)"
	while IFS= read -r c; do
		ck "rule '$c' exactly once in the include" "$(grep -c "comment \"$c\"" "$N")" 1
	done <<< "$want"
done
if [ "${S5_NFT_INET_ONLY:-0}" = 1 ]; then
	echo "WARN S5_NFT_INET_ONLY=1: the bridge table is NOT checked here (this kernel has no bridge nf_tables)"
	sed -n '/^add table inet/,$p' "$N" > $T/n.nft
else
	cp "$N" $T/n.nft
fi
grep -q 'mark-drop' $T/n.nft || { echo "FAIL nothing extracted"; exit 1; }
nft -c -f $T/n.nft > $T/out 2>&1; ck "nft -c accepts it" "$?" 0
[ -s $T/out ] && sed 's/^/     /' $T/out | head -5
sed 's/== 0 counter drop/== zz counter drop/' $T/n.nft > $T/bad.nft
cmp -s $T/n.nft $T/bad.nft && { echo "FAIL the syntax mutant changed nothing"; exit 1; }
nft -c -f $T/bad.nft >/dev/null 2>&1; ck "negative control: a broken rule is rejected" "$?" 1
sed 's/counter drop comment "batman-http: iif"/counter jump batman_nosuch comment "batman-http: iif"/' $T/n.nft > $T/sem.nft
cmp -s $T/n.nft $T/sem.nft && { echo "FAIL the semantic mutant changed nothing"; exit 1; }
nft -c -f $T/sem.nft > $T/sem.out 2>&1; ck "negative control: a jump to a missing chain (kernel check) is rejected" "$?" 1
grep -q 'Could not process rule' $T/sem.out && ck "  ... by the kernel (Could not process rule)" ok ok || ck "  ... by the kernel" "$(head -1 $T/sem.out)" "Could not process rule"
echo "S5-NFT checks=$n fail=$fail"
[ $fail = 0 ] && [ $n -gt 0 ]
