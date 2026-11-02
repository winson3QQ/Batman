#!/bin/bash
# tests/prov-p1/99zz-mesh-expect.sh <99zz-batman-prov-state> — #254 round-7 A-M7: the shell fallback's claimed
# mesh_expect matches boot.MeshExpect: only an explicit placeholder key -> 0; empty / unreadable / real -> today.
blk=$(sed -n '/^	case "\$v" in/,/^	esac/p' "$1")
[ -n "$blk" ] || { echo "FAIL case block not found in $1"; exit 1; }
T=$(mktemp -d); mkdir -p "$T/bin"; fails=0
for c in "EMPTY today" "CHANGE-ME-NOW 0" "realkey today"; do
	set -- $c; key=$1; [ "$key" = EMPTY ] && key=""
	printf '#!/bin/sh\ncase "$*" in\n "-q show wireless") echo "wireless.mesh0.mode='"'"'mesh'"'"'";;\n "-q get wireless.mesh0.key") [ -n "%s" ] && echo "%s";;\nesac\n' "$key" "$key" > "$T/bin/uci"; chmod +x "$T/bin/uci"
	me=$(PATH=$T/bin:$PATH sh -c "PLACEHOLDER=CHANGE-ME-NOW; v=claimed; $blk
echo \$me")
	if [ "$me" = "$2" ]; then echo "ok   key=[$key] -> $me"; else echo "FAIL key=[$key] -> $me want $2"; fails=$((fails+1)); fi
done
rm -rf "$T"; echo "99ZZ fails=$fails"; [ $fails = 0 ]
