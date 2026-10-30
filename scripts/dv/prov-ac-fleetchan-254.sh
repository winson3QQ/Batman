#!/bin/bash
# scripts/dv/prov-ac-fleetchan-254.sh — #254 tier-B unit autocommit (7) (incl. (4); docs/design/254-h23-harness.md §6.2):
# the mesh-join gate both ways on the real two-node fleet.
#   part 1 (4): 04 on A in the mesh; 02 OTA V into B (hold) -> 02's trial is HELD (it joined 04) -> 02 back to A.
#     02 has no harness lease: a host death leaves at most a held trial, which its own deadline reverts.
#   part 2: 04 `-wbox chan` (hold) into B -> precondition, the three-sample rule (§4.2, v5 A-m2): from uptime 120 s,
#     3 samples 10 s apart, the radio's channel != p5's (= A's channel at S0) and `batctl n` empty; otherwise FAIL
#     "mutant had no effect" + back to A -> TRIAL-REVERTED (pr_wait_reverted) and the arm boot's otalog
#     "S1 ARMED-MESH slot=B m=joined" (04 was in the mesh when it armed) -> bad-slot checked by pr_end revert.
#   02 is committed on A at the end and was rebooted only by part 1.
# Type: 02 hold+back / 04 hold+revert / both A. Side effects: 02 ~15 min (2 reboots), 04 ~45 min off the mesh.
set -u
PR_UNIT=prov-ac-fleetchan-254
# shellcheck source=scripts/dv/prov-254.sh
. "$(dirname "$0")/prov-254.sh"
TRACE=/opt/batdata/log/ota-trace.log
CH='iw dev wlh0 info 2>/dev/null | awk "/channel/ {print \$2; exit}"'
pwait(){	# <secs> <boot to leave>: 02 back with another boot id -> PS
	local t0; t0=$(mono); PS=""
	while [ $(( $(mono) - t0 )) -lt "$1" ]; do sleep 15; PS=$(qp "$ST"); [ -n "$PS" ] && [ "$(field "$PS" boot)" != "$2" ] && return 0; done
	return 1
}
part1(){
	local s b0 hv t
	s=$(qp "$ST"); say "02 before: $s"
	[ "$(field "$s" slot)" = A ] && [ "$(field "$s" trial_rc)" = 1 ] && [ "$(field "$s" ver)" = "$PR_V" ] || { no "02 precondition: A committed on V ($s)"; return 1; }
	b0=$(field "$s" boot)
	pr_payload "$PR_V" >/dev/null || { no "payload $PR_V"; return 1; }
	hv=$(sed -n 's/^BATMAN_VERSION=//p' <<< "$PSTAMP")
	scp -q $SSHO "$PAYF" root@$PEER:$PR_PAY.part && qp "mv $PR_PAY.part $PR_PAY" || { no "payload upload to 02"; return 1; }
	[ "$(qp "sha256sum < $PR_PAY | cut -c1-64")" = "$PSHA" ] || { no "payload sha on 02"; return 1; }
	qp "printf '%s\n' '$hv' > $HOLDF; sync"; [ "$(qp "cat $HOLDF")" = "$hv" ] || { no "02 hold read-back"; return 1; }
	qp "setsid sh -c 'sysupgrade -n $PR_PAY >/opt/batdata/dv-prov-sysup.log 2>&1' </dev/null >/dev/null 2>&1 &"; say "02: sysupgrade -n sent (hold)"
	pwait 900 "$b0" || { pr_needs_person "02 not back after its OTA reboot"; return 1; }
	say "02 landed: $PS"
	[ "$(field "$PS" slot)" = B ] && [ "$(field "$PS" trial_rc)" = 0 ] && [ "$(field "$PS" held)" = 1 ] || { no "02 landing ($PS)"; }
	t=0; while [ $t -lt 40 ]; do qp 'logread | grep -q "is healthy and HELD"' && break; sleep 10; t=$((t + 1)); done
	if qp 'logread | grep -q "is healthy and HELD"'; then ok "02 B trial HELD ($(qp "logread | grep -m1 'mesh join required:'" | sed 's/.*autocommit[^:]*: //'))"
	else no "02 B trial not HELD: $(qp '. /usr/lib/batman/rundir.sh; cat $RUNDIR/autocommit.why 2>/dev/null')"; fi
	b0=$(field "$PS" boot)
	qp 'batman-slot rollback >/dev/null 2>&1 && { (batman-slot reboot committed prov-dv-254 </dev/null >/dev/null 2>&1 &); echo SENT; }' | grep -q SENT || { pr_needs_person "02: rollback refused (in its B trial)"; return 1; }
	pwait 900 "$b0" || { pr_needs_person "02 not back after back-to-A"; return 1; }
	qp "rm -f $HOLDF $PR_PAY; sync"
	[ "$(field "$PS" slot)" = A ] && [ "$(field "$PS" trial_rc)" = 1 ] && [ "$(field "$PS" badslot)" = "[]" ] && ok "02 back on A committed" || { pr_needs_person "02 not A committed after the back-to-A ($PS)"; return 1; }
	PR_PEER_BOOT=$(field "$PS" boot)   # pr_peer_after: 02 must not reboot again from here
	t=0; while [ $t -lt 18 ] && ! nb02; do sleep 10; t=$((t + 1)); done
	nb02 && ok "02 a neighbour of 04 again" || { no "02 not a neighbour of 04 after part 1"; return 1; }
}
part2(){
	local c0 s b0 i c n bad=0 l
	c0=$(qr "$CH"); s=$(qr "$ST"); b0=$(field "$s" boot); say "04 A channel (p5's) = $c0"
	case "$c0" in ''|*[!0-9]*) no "no channel on 04's A ($c0)"; return 1 ;; esac
	pr_ota_b "$PR_V.dirty.wbox-chan" B || return 1
	while [ "$(qr 'cut -d. -f1 /proc/uptime')" -lt 120 ]; do sleep 5; done
	for i in 1 2 3; do
		c=$(qr "$CH"); n=$(qr 'batctl n 2>/dev/null | tail -n +3 | grep -c .'); say "sample $i: channel=$c neighbours=$n"
		[ -n "$c" ] && [ "$c" != "$c0" ] && [ "${n:-1}" = 0 ] || bad=1
		[ $i -lt 3 ] && sleep 10
	done
	l=$(qr "logread | grep -m1 'WBOX-chan-2ac9e47f'"); say "mutant: ${l##*wbox-chan: }"
	[ $bad = 0 ] && ok "three samples: off the p5 channel $c0, no neighbours" || { no "mutant had no effect (three-sample rule)"; back_to_a; return 1; }
	l=$(qr "grep 'boot=$b0 .*S1 ARMED-MESH slot=B' $TRACE | tail -1")
	case "$l" in *"m=joined"*) ok "arm boot: ${l#* S1 }";; *) no "arm boot ARMED-MESH: [$l] (want m=joined)";; esac
	pr_wait_reverted || { [ "$(field "$(qr "$ST")" slot)" = B ] && back_to_a; return 1; }
	r=$PR_REVERT_LINE   # this trial boot's line only (pr_wait_reverted, §23.9)
	case "$r" in *"mesh not joined/reachable"*) ok "revert reason: ${r##*reason=}";; *) no "revert reason: [$r]";; esac
}
pr_begin 3600 || { pr_result; exit 1; }
part1 || { pr_abort "part 1 (02)"; pr_result; exit 1; }
part2 || { pr_abort "part 2 (04 chan)"; pr_result; exit 1; }
s=$(qp "$ST"); [ "$(field "$s" slot)" = A ] && [ "$(field "$s" trial_rc)" = 1 ] && ok "02 committed on A at the end" || no "02 at the end: $s"
pr_end revert
pr_result
