#!/bin/bash
# scripts/dv/prov-wbox-nocommit-254.sh — #254 tier-B unit prov-wbox-nocommit-254 (docs/design/254-h23-harness.md §18.1,
# §19.3, §20.3, §21.1): the node itself never makes a -wbox image its committed slot.
#   precondition: A's batman-slot carries the gate ("holds a -wbox test image"); else FAIL pre-gate, before any OTA
#   trial arm: OTA `-wbox 96-noprov` (built after the gate) into B WITHOUT a hold (the one listed exception, `nohold`
#     only for this unit, lint-wbox) -> the healthy trial logs otalog "AC WBOX-NOCOMMIT" and is reverted at its deadline
#     (judged by WBOX-NOCOMMIT, not by the last TRIAL-REVERTED reason; none + a mesh reason = INVALID) -> back on A.
#     Safety net: a COMMITTED in the trial (gate regression) -> at once `batman-slot rollback` (to A, allowed) +
#     `batman-slot reboot committed`; not back on A -> NEEDS-PERSON.
#   rollback arm (B still holds the wbox image, before the B rewrite): one detached node-side arm (survives an ssh drop):
#     `batman-slot rollback` (target = the wbox B) -> PASS only when rc != 0, the output names "holds a -wbox test
#     image" and bf_ab_all is unchanged; rc 0 or [all] changed -> `batman-slot commit` on A at once (3 tries, 5 s) ->
#     FAIL-RECOVERED / FAIL-NEEDS-PERSON; another refusal message -> INVALID.
# Type: revert / A. Side effects: 04 ~50 min (one deadline revert, B rewritten twice), bad-slot handled by pr_end revert.
set -u
PR_UNIT=prov-wbox-nocommit-254
# shellcheck source=scripts/dv/prov-254.sh
. "$(dirname "$0")/prov-254.sh"
W=/tmp/run/batman-dv/wbox/$RUN
WV=""
trial(){
	local s b0 t0 o dl
	[ "$(qr "grep -c 'holds a -wbox test image' /usr/sbin/batman-slot")" -ge 1 ] 2>/dev/null || { no "pre-gate image: A's batman-slot has no wbox gate"; return 1; }
	pr_ota_b "$PR_V.dirty.wbox-96-noprov" B nohold || return 1
	WV=$(field "$PR_STATE" ver); b0=$(field "$PR_STATE" boot)
	dl=$(qr '. /usr/lib/batman/rundir.sh; cat $RUNDIR/autocommit.deadline 2>/dev/null')
	case "$dl" in ''|*[!0-9]*) no "no autocommit deadline in the trial"; back_to_a; return 1 ;; esac
	say "B trial of $WV (no hold), deadline uptime ${dl}s"
	t0=$(mono)
	while :; do
		o=$(timeout 30 ssh $SSHO root@$NODE 'logread | grep -E "batman-autocommit.*slot B committed|revert deferred:" | tail -1' 2>/dev/null | tr -d '\r')
		case "$o" in *"slot B committed"*)
			no "GATE REGRESSION: the wbox trial was COMMITTED ($o)"
			o=$(q 'batman-slot rollback >/dev/null 2>&1 && { (batman-slot reboot committed prov-dv-254 </dev/null >/dev/null 2>&1 &); echo SENT; }')
			grep -q SENT <<< "$o" || { pr_needs_person "wbox slot B committed and the rollback to A was refused — run on 04: batman-slot rollback; batman-slot reboot committed"; return 1; }
			pr_find 900 "$b0" && [ "$(field "$PR_STATE" slot)" = A ] || { pr_needs_person "wbox slot B committed; not back on A after the rollback"; return 1; }
			return 1 ;;
		*"revert deferred:"*) pr_lease_renew +600 >/dev/null ;;
		esac
		s=$(timeout 30 ssh $SSHO root@$NODE "$ST" 2>/dev/null | tr -d '\r')
		[ -n "$s" ] && [ "$(field "$s" boot)" != "$b0" ] && break
		[ $(( $(mono) - t0 )) -gt $(( dl + 600 + 420 )) ] && { no "no revert within the budget"; return 1; }
		sleep 10
	done
	pr_find 900 "$b0" || return 1
	[ "$(field "$PR_STATE" slot)" = A ] && [ "$(field "$PR_STATE" trial_rc)" = 1 ] && ok "back on A committed after the deadline" || { no "after the trial: $PR_STATE"; return 1; }
	o=$(qr "grep 'boot=$b0 .*AC WBOX-NOCOMMIT' /opt/batdata/log/ota-trace.log | tail -1")
	r=$(qr "grep 'TRIAL-REVERTED boot=$b0 ' /opt/batdata/log/autocommit.log | tail -1")   # this trial boot only (§23.9)
	if [ -n "$o" ]; then ok "the trial logged ${o#* AC }"
	else case "$r" in *mesh*) inv "no WBOX-NOCOMMIT and a mesh revert reason ($r) — run again"; return 1 ;; *) no "no AC WBOX-NOCOMMIT in the trial boot ($r)"; return 1 ;; esac; fi
	case "$r" in *"reason=wbox test image"*) ok "TRIAL-REVERTED reason=wbox test image" ;; *) say "last TRIAL-REVERTED reason: ${r##*reason=} (judged by WBOX-NOCOMMIT)" ;; esac
}
rbarm(){
	local o rw
	[ -n "$WV" ] || { no "rollback arm: no wbox version"; return 1; }
	pw prep >/dev/null
	# the arm itself: scripts/node/prov-rbarm-254.sh (offline test tests/prov-p1/rbarm.sh)
	scp -q $SSHO "$REPO/scripts/node/prov-rbarm-254.sh" root@$NODE:$W/rbarm.sh || { no "push the rollback arm"; return 1; }
	[ "$(qr "sha256sum < $W/rbarm.sh | cut -c1-64")" = "$(sha256sum < "$REPO/scripts/node/prov-rbarm-254.sh" | cut -c1-64)" ] || { no "rollback arm on the node differs"; return 1; }
	# the arm's pid in /tmp/run/batman-dv/<run>/rbarm.pid: preflight P9 FAILs while it is alive (prov-p9-254.sh, p9-judge)
	q "chmod 700 $W/rbarm.sh; rm -f $W/rbarm.out; mkdir -p -m 0700 /tmp/run/batman-dv/$RUN; setsid sh $W/rbarm.sh '$WV' > $W/rbarm.out 2>&1 < /dev/null & echo \$! > /tmp/run/batman-dv/$RUN/rbarm.pid"
	# review B-m1: past 120 s it is waited for while alive (to 600 s), never killed, and the restore never runs beside it
	o=$(pr_wait_result "$W/rbarm.out" "/tmp/run/batman-dv/$RUN/rbarm.pid" 120 600); rw=$?
	say "rollback arm: ${o:-no result}"
	[ "$rw" = 2 ] || q "rm -f /tmp/run/batman-dv/$RUN/rbarm.pid"   # ALIVE = the arm may still run: P9 must see its pid
	case "$o" in
		RESULT=PASS*) ok "rollback to the wbox B refused, [all] unchanged (${o#RESULT=PASS })" ;;
		RESULT=FAIL-RECOVERED*) no "GATE REGRESSION: rollback to the wbox B was accepted — recovered to A (${o#RESULT=})" ;;
		RESULT=FAIL-NEEDS-PERSON*) pr_needs_person "rollback arm: [all] not back on A (${o#RESULT=}) — run on 04: batman-slot commit"; return 1 ;;
		RESULT=INVALID*) inv "rollback arm: ${o#RESULT=INVALID }" ;;
		ALIVE) pr_needs_person "rollback arm still running (or 04 silent) after 600 s — NOT killed: it may be between its rollback and its recovery. On 04: wait for $W/rbarm.out, check bf_ab_all = 1 and batman-slot active = A, then kill the pid in /tmp/run/batman-dv/$RUN/rbarm.pid"; return 1 ;;
		*)	o=$(qr '. /usr/lib/batman/bootfacts.sh; bf_ab_all')   # the arm ended without a RESULT line
			[ "$o" = 1 ] && no "rollback arm: ended without a RESULT line ([all]=1 unchanged)" || { pr_needs_person "rollback arm: no result and [all]=$o — run on 04: batman-slot commit"; return 1; } ;;
	esac
}
pr_begin 3600 || { pr_result; exit 1; }
trial || { pr_abort "trial"; pr_result; exit 1; }
rbarm || { pr_abort "rollback arm"; pr_result; exit 1; }
pr_end revert
pr_result
