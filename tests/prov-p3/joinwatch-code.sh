#!/bin/bash
# tests/prov-p3/joinwatch-code.sh <joinwatch> — #254 P3 status (254-p3-impl §3.4): verdict_code() takes the same
# branch as verdict() for every radio state, and the code is the one the CDDL join-reason lists for that phrase.
# The two functions are extracted from the file under test and run under busybox ash (the node's shell) when present.
set -u
JW=${1:?usage: $0 <joinwatch>}
# #290: the harness holds this test; a product before P3 status has no verdict_code()
grep -q '^verdict_code(){' "$JW" || { echo "FAIL $JW predates P3 (no verdict_code()): expected red until feat/254-p3 lands (#254)"; echo "joinwatch-code: 0 cases, 1 failed"; exit 1; }
fails=0; cases=0
fns=$(sed -n '/^verdict(){/,/^}/p; /^verdict_code(){/,/^}/p' "$JW")
[ -n "$(printf '%s\n' "$fns" | grep '^verdict_code(){')" ] || { echo "FAIL verdict_code() not found in $JW"; exit 1; }
SH=sh; command -v busybox >/dev/null && SH="busybox ash"
# state: GUARD KEY RDIS RUP RTYPE M11 PLINK STA BAT | the phrase's start | the code
while IFS='|' read -r st phrase want; do
	[ -n "$st" ] || continue
	set -- $st
	out=$($SH -c "$fns
GUARD='$1' KEY='$2' RDIS='$3' RUP='$4' RTYPE='$(echo "$5" | tr _ ' ')' M11='$6' PLINK='$7' STA='$8' BAT='$9' CH=40 MID=m FWD=1 NOL=0
echo \"\$(verdict)|\$(verdict_code)\"")
	cases=$((cases + 1)); v=${out%|*}; c=${out##*|}
	case "$v" in "$phrase"*) ;; *) echo "FAIL [$st] verdict [$v], want [$phrase…]"; fails=$((fails + 1)); continue ;; esac
	[ "$c" = "$want" ] && echo "PASS [$st] $c ${phrase%% *}…" || { echo "FAIL [$st] code [$c] for [$v], want $want"; fails=$((fails + 1)); }
done <<'T'
default_radio1 SET 0 up mesh_point 1 1 1 1|KEY PLACEHOLDER|1
none PLACEHOLDER 0 up mesh_point 1 1 1 1|mesh key PLACEHOLDER|2
none NONE 0 up mesh_point 1 1 1 1|mesh key NONE|2
none SET 1 up mesh_point 1 1 1 1|radio disabled|3
none SET 0 down none 1 0 0 0|HaLow radio not up|4
none SET 0 up managed 1 0 0 0|radio up but not in mesh mode|5
none SET 0 up mesh_point 0 1 1 1|mesh11sd disabled|6
none SET 0 up mesh_point 1 0 0 0|radio meshing, NO PEER HEARD|7
none SET 0 up mesh_point 1 0 2 0|peers seen (2) but no plink|8
none SET 0 up mesh_point 1 1 1 0|802.11s linked but batman has no neighbour|9
none SET 0 up mesh_point 1 1 1 1|joined|0
T
echo "joinwatch-code: $cases cases, $fails failed ($SH)"
[ "$cases" -gt 0 ] && [ "$fails" = 0 ]
