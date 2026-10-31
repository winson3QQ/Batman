#!/bin/bash
# tests/prov-p1/autocommit-mesh-arm.sh <batman-autocommit> — #254 L38 / L42 / L43 / L51 (docs/design/254-stage1-impl.md
# :368,372,373,379; 254-h23 §17): the judgement half of each, on the REAL block of autocommit (from `PROV_V=""` to the
# `mesh join required` line), with its fixed paths pointed at fixtures and `sleep` stubbed (no 60 s wait):
#   L38  writer=99zz -> wait (<= 60 polls) for the helper's line; adopt it when it comes; else keep 99zz's; another
#        boot's line -> no prov (today's rule)
#   L42  member without ota-armed.mesh -> neighbours required (fail-closed)
#   L43  an arm file of another boot -> ignored (neighbours required); the arm boot's -> radio-only
#   L51  an arm file saying joined -> neighbours required
# The four misc-* wbox mutants each make this test FAIL (their negative control). A run with zero cases FAILs.
set -u
AC=$(readlink -f "${1:?usage: $0 <batman-autocommit>}"); [ -f "$AC" ] || { echo "FAIL no $AC"; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; fails=0; cases=0
blk=$(sed -n '/^PROV_V=""; PROV_ME=""; RADIO_REQ=0$/,/^log "mesh join required:/p' "$AC")
[ -n "$blk" ] && echo "$blk" | grep -q 'mesh join required' || { echo "FAIL prov / arm block not found in $AC"; echo "AUTOCOMMIT-MESH-ARM cases=0 fails=1"; exit 1; }
echo "$blk" | sed -e "s#/proc/sys/kernel/random/boot_id#$T/boot_id#g" -e "s#/opt/batdata/log/boot-reasons.log#$T/br.log#g" > "$T/blk.sh"
BOOT=11112222-3333-4444-5555-666677778888; ARM8=aaaa1111; OLD8=cccc3333
echo "$BOOT" > "$T/boot_id"
printf 'x boot_id=%s prev=CLEAN\ny boot_id=11112222 prev=CLEAN\n' "$ARM8" > "$T/br.log"
# run <prov-state line|-> <arm file content|-> [switch-at N: helper line written at sleep #N]
run(){
	rm -rf "$T/st"; mkdir -p "$T/st"
	[ "$1" != - ] && echo "$1" > "$T/st/prov-state"
	[ "$2" != - ] && echo "$2" > "$T/st/ota-armed.mesh"
	OUT=$(env -i PATH=/usr/bin:/bin ST="$T/st" SLOT=A NEED_MESH=1 SW="${3:-0}" HL="$BOOT helper - member - radio" G_T="$T" \
		bash -c 'sleeps=0; sleep(){ sleeps=$((sleeps + 1)); [ "$sleeps" = "$SW" ] && echo "$HL" > "$ST/prov-state"; return 0; }
			log(){ echo "log $*"; }
			. "$G_T/blk.sh"; echo "NEED_MESH=$NEED_MESH sleeps=$sleeps"' 2>&1)
}
expect(){ cases=$((cases+1)); if echo "$OUT" | grep -q -- "$2" && { [ -z "${3:-}" ] || ! echo "$OUT" | grep -q -- "$3"; }; then echo "ok   $1"; else echo "FAIL $1 — $(echo "$OUT" | tr '\n' ' ' | cut -c1-260)"; fails=$((fails+1)); fi; }
# L38
run "$BOOT 99zz - unclaimed - 0" - 5;  expect "L38 helper comes at poll 5 -> its member/radio is used" "NEED_MESH=1 sleeps=5" "prov=unclaimed"
run "$BOOT 99zz - unclaimed - 0" -;    expect "L38 helper never comes -> 60 polls, then 99zz's unclaimed" "NEED_MESH=0 sleeps=60"
run "$BOOT 99zz - unclaimed - 0" -;    expect "L38 helper never comes -> prov=unclaimed logged" "prov=unclaimed"
run "deadbeef-0000 helper - member - radio" -; expect "L38 another boot's line -> no prov (today's rule, NEED_MESH kept)" "prov=none" "member: "
# L42
run "$BOOT helper - member - radio" -; expect "L42 member without an arm file -> neighbours required (fail-closed)" "NEED_MESH=1" "armed in radio-only"
run "$BOOT helper - member - radio" -; expect "L42 the fail-closed log line" "no usable ota-armed.mesh — neighbours required"
# L43
run "$BOOT helper - member - radio" "$OLD8 A radio"; expect "L43 arm file of another boot -> ignored, neighbours required" "NEED_MESH=1" "armed in radio-only"
run "$BOOT helper - member - radio" "$ARM8 A radio"; expect "L43 control: the arm boot's radio file -> radio-only" "NEED_MESH=0" "no usable"
run "$BOOT helper - member - radio" "$ARM8 B radio"; expect "L43 control: arm file for the other slot -> neighbours required" "NEED_MESH=1"
# L51
run "$BOOT helper - member - radio" "$ARM8 A joined"; expect "L51 arm file saying joined -> neighbours required" "NEED_MESH=1" "armed in radio-only"
[ "$cases" -gt 0 ] || { echo "FAIL no case ran"; exit 1; }
echo "AUTOCOMMIT-MESH-ARM cases=$cases fails=$fails"; [ "$fails" = 0 ]
