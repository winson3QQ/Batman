#!/bin/bash
# tests/prov-p1/autocommit-prov-case.sh <batman-autocommit> — #254: the prov-state case block decides NEED_MESH
# (round-7 B-M2: claimed + placeholder needs no neighbours ONLY when p6 has no mesh-joined / mesh-expected marker).
# Extracts the block and runs it with stubbed state; no node needed.
blk=$(sed -n '/^	case "\$PROV_V:\$PROV_ME" in/,/^	esac/p' "$1")
[ -n "$blk" ] || { echo "FAIL case block not found in $1"; exit 1; }
fails=0
for c in "claimed 0 none 0" "claimed 0 mesh-joined 1" "claimed 0 mesh-expected 1" "claimed today none 1" "unclaimed 0 mesh-joined 0" "legacy today none 1"; do
	set -- $c; T=$(mktemp -d); [ "$3" != none ] && : > "$T/$3"
	r=$(bash -c "ST=$T; NEED_MESH=1; RADIO_REQ=0; SLOT=A; PROV_V=$1; PROV_ME=$2; log(){ :; }; $blk
echo \$NEED_MESH"); rm -rf "$T"
	if [ "$r" = "$4" ]; then echo "ok   $1:$2 marker=$3 -> NEED_MESH=$r"; else echo "FAIL $1:$2 marker=$3 -> NEED_MESH=$r want $4"; fails=$((fails+1)); fi
done
echo "AUTOCOMMIT-PROV fails=$fails"; [ $fails = 0 ]
