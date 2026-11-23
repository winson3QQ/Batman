#!/bin/bash
# scripts/dv/test-acflap-254.sh [<prov-ac-flap-254.sh>] — offline test of acflap_judge (docs/design/254-v16-group4.md
# §1): the P3 judgement of prov-ac-flap-254, taken from the unit's text (its ACF_ strings and the function), fed with
# SYNTHETIC inputs (labelled as such; the real why / revert strings are those of batman-autocommit health_ok and
# its TRIAL-REVERTED aclog line):
#   (i)   (a) samples + an (a) revert line            -> PASS
#   (ii)  (b)-only samples (+ a (b) revert line)       -> FAIL "(a) never observed"
#   (iii) (a) samples + a revert reason "mesh not joined" -> FAIL "neither (a) nor (b)"
#   (iv)  no samples                                   -> FAIL "no autocommit.why sample"
#   plus (v) (a) samples + a (b) revert line -> PASS, (vi) no revert line -> FAIL.
# Negative control: main's unit has no acflap_judge -> every case FAILs.   -> "TEST-ACFLAP: N passed, M failed"
set -u
U=${1:-$(cd "$(dirname "$0")" && pwd)/prov-ac-flap-254.sh}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
P=0; F=0
awk '/^ACF_A=/ { print } /^acflap_judge\(\)/ { on = 1 } on { print } on && /^}/ { exit }' "$U" > "$T/j.sh"
# shellcheck disable=SC1091
. "$T/j.sh" 2>/dev/null
command -v acflap_judge >/dev/null 2>&1 || echo "no acflap_judge in $U"
A="svc batman-provhelper down"; B="batman-provd not stable for 60 s yet this boot"
RL(){ echo "2026-11-22T10:00:00 TRIAL-REVERTED boot=395990f8 slot=B version=1.5.14-wsl.36+b885a2c.fw302c80b.dirty.wbox-helper-flap waited=571s reason=$1"; }
c(){ local l=$1 want=$2 e=$3 s=$4 r=$5 o rc
	o=$(acflap_judge "$s" "$r" 2>&1); rc=$?
	if { [ "$want" = PASS ] && [ "$rc" = 0 ] && grep -q '^ACFLAP PASS: ' <<< "$o"; } || { [ "$want" = FAIL ] && [ "$rc" != 0 ] && grep -qF -- "ACFLAP FAIL: $e" <<< "$o"; }
	then echo "ok   $l [synthetic] -> $want: $o"; P=$((P + 1)); else echo "FAIL $l [synthetic]: want $want [$e], rc $rc: $o"; F=$((F + 1)); fi; }
c "(i) (a) samples + (a) revert" PASS "" "$B
$A
$A
$B" "$(RL "$A")"
c "(ii) (b)-only samples" FAIL "(a) never observed" "$B
$B
$B" "$(RL "$B")"
c "(iii) revert reason mesh not joined" FAIL "the revert reason is neither (a) nor (b)" "$A
$B" "$(RL "mesh not joined/reachable (0/3 samples: plink=0 batman(wlh0)=0)")"
c "(iv) no samples" FAIL "no autocommit.why sample" "" "$(RL "$A")"
c "(v) (a) samples + (b) revert" PASS "" "$A
$B" "$(RL "$B")"
c "(vi) no revert line" FAIL "no TRIAL-REVERTED line" "$A" ""
echo "TEST-ACFLAP: $P passed, $F failed"; [ "$F" = 0 ] && [ "$P" -gt 0 ]
