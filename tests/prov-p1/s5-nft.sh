#!/bin/bash
# tests/prov-p1/s5-nft.sh <feed/batman-prov/files/batman-http.nft> — #254 P3 S5 (254-p3-impl §3.8.1): the include fw4
# loads must be valid nft, since an error there fails the whole firewall (F70): `nft -c` on both tables, every rule the
# helper looks for (by its comment) present, and a broken rule rejected by the same check (negative control). Root + nft.
# A kernel without bridge nf_tables (WSL) can check the inet table only: S5_NFT_INET_ONLY=1 says so loudly; CI never
# sets it. Nothing checked = FAIL.
exec </dev/null
N=$(readlink -f "${1:?usage: $0 <batman-http.nft>}")
[ -f "$N" ] || { echo "FAIL no $N: expected red until feat/254-p3 S5 lands (#254)"; exit 1; }
[ "$(id -u)" = 0 ] && command -v nft >/dev/null || { echo "FAIL needs root and nft"; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0; n=0
ck() { n=$((n + 1)); if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got [$2] want [$3]"; fail=1; fi; }
for c in "batman-http: clear" "batman-http: mark" "batman-http: iif" "batman-http: mark-drop"; do
	ck "rule '$c' in the include" "$(grep -c "comment \"$c\"" "$N")" 1
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
nft -c -f $T/bad.nft >/dev/null 2>&1; ck "negative control: a broken rule is rejected" "$?" 1
echo "S5-NFT checks=$n fail=$fail"
[ $fail = 0 ] && [ $n -gt 0 ]
