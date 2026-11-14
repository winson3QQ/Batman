#!/bin/bash
# tests/judges/sd6-judge.sh — offline cases for prov-status-diag-254's SD6 (#254 whole-team status, review r1 A-M2 /
# B-M1..M3): the REAL sd6_judge, f and code cut out of the unit, fed canned provclient RESULT lines. Each case states
# whether SD6 must PASS, and every FAIL line is matched against the unit's known-failure entries: ONLY the "image without
# whole-team status" case may be fully known; every other failing case must print at least one NEW line.
# Prints "ok"/"FAIL" per case and "sd6-judge: <n> passed, <m> failed"; exit 1 on any failure; zero cases = FAIL.
set -u
REPO=${REPO:-$(cd "$(dirname "$0")/../.." && pwd)}
U=$REPO/scripts/dv/prov-status-diag-254.sh
pass=0; bad=0
tok(){ echo "ok   $*"; pass=$((pass + 1)); }; tbad(){ echo "FAIL $*"; bad=$((bad + 1)); }
fn(){ awk -v n="$2" '!p && $0 ~ "^"n"\(\)" {p=1; print; if ($0 ~ /; }[[:space:]]*(#.*)?$/) exit; next} p {print} p && /^}/ {exit}' "$1"; }
src="$(fn "$U" code)
$(fn "$U" f)
$(fn "$U" sd6_judge)"
grep -q '^sd6_judge()' <<< "$src" && grep -q '^code()' <<< "$src" && grep -q '^f()' <<< "$src" || { tbad "sd6_judge / f / code not found in $U"; echo "sd6-judge: $pass passed, $bad failed"; exit 1; }
eval "$src"
mapfile -t KF < <(awk -F'\t' '$1 == "prov-status-diag-254" {print $2}' "$REPO/scripts/validation-known-failures.txt")
[ ${#KF[@]} -ge 1 ] || { tbad "no known-failure entry for prov-status-diag-254"; exit 1; }
known(){ local l=$1 e; for e in "${KF[@]}"; do grep -Eq -- "$e" <<< "$l" && return 0; done; return 1; }
PR_UNIT=prov-status-diag-254
ok(){ echo "PASS $PR_UNIT: $*"; }; no(){ echo "FAIL $PR_UNIT: $*"; }
FT='docker-in-image(#159),memcg,whole-team-status(#254),payload-config'; FO='docker-in-image(#159),memcg,payload-config'
VO=1.5.14-wsl.28+5079b47.fw108f016; VT=1.5.14-wsl.29+141a018.fw7781d66.bench
ME=a8:dd:9f:4d:c6:10; PEER=a8:dd:9f:4d:c7:60
SD6_PRE=$REPO/scripts/dv/pre-team-status-versions.txt; grep -qxF "$VO" "$SD6_PRE" || { tbad "$VO not on $SD6_PRE"; exit 1; }
R(){ echo "RESULT status.get(full true) code=$1 state=3 verdict=0 neighbours=1 p5_saved=true f15=image self=$2 peers=$3 bytes=$4"; }
# <name> <want: pass | known | new> <result line> <features> <version> [this node's wlh0 MAC as sysfs gives it]
case_(){ local o fails newn=0 l me=${6:-$ME}
	o=$(sd6_judge "$3" "$4" "$5" "$me" "$PEER"); fails=$(grep -c '^FAIL' <<< "$o")
	while IFS= read -r l; do [ -n "$l" ] && ! known "$l" && newn=$((newn + 1)); done < <(grep '^FAIL' <<< "$o")
	case "$2" in
		pass)  [ "$fails" = 0 ] && grep -q '^PASS' <<< "$o" && tok "$1: PASS" || tbad "$1: want PASS, got: $(tr '\n' '|' <<< "$o")" ;;
		known) [ "$fails" -ge 1 ] && [ "$newn" = 0 ] && tok "$1: FAIL, all known" || tbad "$1: want only known FAILs, got fails=$fails new=$newn: $(tr '\n' '|' <<< "$o")" ;;
		new)   [ "$newn" -ge 1 ] && tok "$1: FAIL, $newn NEW line(s)" || tbad "$1: want a NEW FAIL, got fails=$fails new=$newn: $(tr '\n' '|' <<< "$o")" ;;
	esac; }
case_ "team image, live peer"                  pass  "$(R 0 $ME "$PEER/2" 120)" "$FT" "$VT"
case_ "team image, peer among others"          pass  "$(R 0 $ME "a8:dd:9f:4d:c6:d3/1,$PEER/0" 160)" "$FT" "$VT"
case_ "upper-case self from sysfs"             pass  "$(R 0 $ME "$PEER/2" 120)" "$FT" "$VT" A8:DD:9F:4D:C6:10
case_ "listed image without team status"       known "$(R 0 - - 90)" "$FO" "$VO"
case_ "unlisted version without the marker"    new   "$(R 0 - - 90)" "$FO" "$VT"
case_ "empty BATMAN_FEATURES (unreadable)"     new   "$(R 0 - - 90)" "" "$VO"
case_ "marker lost, keys 8 / 9 present"        new   "$(R 0 $ME "$PEER/2" 120)" "$FO" "$VO"
case_ "marker lost, key 8 only"                new   "$(R 0 $ME - 90)" "$FO" "$VO"
case_ "listed, no marker, code 20"             new   "RESULT status.get(full true) code=20" "$FO" "$VO"
case_ "team image, code 20"                    new   "RESULT status.get(full true) code=20" "$FT" "$VT"
case_ "team image, key 9 absent"               new   "$(R 0 $ME - 90)" "$FT" "$VT"
case_ "team image, keys 8 and 9 absent"        new   "$(R 0 - - 90)" "$FT" "$VT"
case_ "team image, key 9 bad"                  new   "$(R 0 $ME bad 90)" "$FT" "$VT"
case_ "team image, key 9 empty"                new   "$(R 0 $ME none 90)" "$FT" "$VT"
case_ "team image, other peers only"           new   "$(R 0 $ME "a8:dd:9f:4d:c6:d3/1" 120)" "$FT" "$VT"
case_ "team image, peer stale (31 s)"          new   "$(R 0 $ME "$PEER/31" 120)" "$FT" "$VT"
case_ "team image, peer at 30 s"               pass  "$(R 0 $ME "$PEER/30" 120)" "$FT" "$VT"
case_ "team image, a suffix of PEER"           new   "$(R 0 $ME "ff:dd:9f:4d:c7:60/0" 120)" "$FT" "$VT"
case_ "team image, wrong key 8"                new   "$(R 0 02:11:22:33:44:55 "$PEER/2" 120)" "$FT" "$VT"
case_ "team image, answer 8113 B"              new   "$(R 0 $ME "$PEER/2" 8113)" "$FT" "$VT"
case_ "team image, answer 8112 B"              pass  "$(R 0 $ME "$PEER/2" 8112)" "$FT" "$VT"
case_ "team image, bytes missing"              new   "RESULT status.get(full true) code=0 state=3 self=$ME peers=$PEER/2" "$FT" "$VT"
case_ "marker as a substring only, listed"     known "$(R 0 - - 90)" "docker,whole-team-status(#254)x,memcg" "$VO"
case_ "empty RESULT (provclient not run)"      new   "" "$FT" "$VT"
[ $((pass + bad)) -gt 0 ] || { echo "FAIL zero cases"; exit 1; }
echo "sd6-judge: $pass passed, $bad failed"; [ "$bad" = 0 ]
