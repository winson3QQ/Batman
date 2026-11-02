#!/bin/bash
# tests/prov-p1/gate-negatives.sh <batman-slot> <prov-lock.sh> — prov-unit-gate's negative controls (254-p1-impl §5.1):
# tests/prov-p1/batman-slot-stage-root.sh must FAIL, in exactly the expected cases, for
#   mutant "allow claimed": the product batman-slot with its L44 check also letting a valid CLAIMED record through
#     -> the unseeded + valid + claimed case fails, and nothing else;
#   the 1.5.12-wsl.9 batman-slot (tests/prov-p1/fixtures, pre-#254: no L44) -> the unseeded + valid + unclaimed cases
#     fail (L44 and the matrix's), and nothing else.
# Root (as the test). Zero runs -> FAIL.
set -u
BS=$(readlink -f "${1:?usage: $0 <batman-slot> <prov-lock.sh>}"); LIB=$(readlink -f "${2:?}")
D=$(cd "$(dirname "$0")" && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; fails=0; runs=0
no(){ echo "FAIL $*"; fails=$((fails + 1)); }
neg(){	# <label> <batman-slot> <ERE the failing case names must all match> <min failing cases>
	local o fl n
	runs=$((runs + 1)); o=$(bash "$D/batman-slot-stage-root.sh" "$2" "$LIB" 2>&1)
	fl=$(grep '^FAIL ' <<< "$o" | grep -v '^FAIL card build\|^FAIL p5 setup'); n=$(grep -c . <<< "$fl")
	[ -n "$fl" ] || { no "$1: the test passed — it does not discriminate"; return; }
	if grep -qvE "$3" <<< "$fl"; then no "$1: unexpected failing cases: $(grep -vE "$3" <<< "$fl" | head -3 | tr '\n' '|')"
	elif [ "$n" -lt "$4" ]; then no "$1: only $n failing case(s), want >= $4"
	else echo "ok   $1: caught, $n failing case(s), all of the expected kind"; fi
}
sed 's/= "ok unclaimed" \]/= "ok unclaimed" ] || [ "$(prov_meta_status "$m\/prov.meta" "$m\/prov.cbor")" = "ok claimed" ]/' "$BS" > "$T/bs-allow-claimed"
cmp -s "$BS" "$T/bs-allow-claimed" && { echo "FAIL the allow-claimed mutant did not apply"; exit 1; }
neg "mutant allow-claimed" "$T/bs-allow-claimed" 'claimed \+ unseeded|seeded=0 meta=ok state=claimed' 2
neg "1.5.12-wsl.9 batman-slot (no L44)" "$D/fixtures/batman-slot.1.5.12-wsl.9" 'L44|seeded=0 meta=ok state=unclaimed' 2
echo "GATE-NEGATIVES runs=$runs fails=$fails"; [ "$runs" -gt 0 ] && [ "$fails" = 0 ]
