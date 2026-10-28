#!/bin/bash
# scripts/dv/prov-wbox-nocommit-254.sh — #254 tier-B unit prov-wbox-nocommit-254 (docs/design/254-h23-harness.md §18.1,
# §19.3, §20.3, §21.1): the node itself never makes a -wbox image its committed slot.
#   precondition: A's batman-slot carries the gate ("holds a -wbox test image"); else FAIL pre-gate, before any OTA
#   trial arm: OTA `-wbox 96-noprov` (built after the gate) into B WITHOUT a hold (the one listed exception, `nohold`
#     only for this unit, lint-wbox) -> the healthy trial logs otalog "AC WBOX-NOCOMMIT" and is reverted at its deadline
#     (judged by WBOX-NOCOMMIT, not by the last TRIAL-REVERTED reason; none + a mesh reason = INVALID) -> back on A.
#     Safety net: a COMMITTED in the trial (gate regression) -> at once `batman-slot rollback` (to A, allowed) +
#     `batman-slot reboot committed`; not back on A -> NEEDS-PERSON.
#   rollback arm (B still holds the wbox image, before the B rewrite): scripts/node/prov-rbarm-254.sh, started detached
#     by prov-rbarm-launch-254.sh over `ssh -tt` (§23.1): 3 s in, the session's process group gets SIGHUP and the ssh
#     client is killed; the arm (asleep 10 s first) then runs `batman-slot rollback` (target = the wbox B) -> PASS only
#     when rc != 0, the output names "holds a -wbox test image" and bf_ab_all is unchanged; rc 0 or [all] changed ->
#     `batman-slot commit` on A at once (3 tries, 5 s) -> FAIL-RECOVERED / FAIL-NEEDS-PERSON; another refusal -> INVALID.
#     Negative control first, same path and window: a harmless arm (no batman-slot) started with a plain `&` must die;
#     it survives -> the drop proof is INVALID (the arm's own verdict still counts). Proof: the kill (node uptime) is
#     earlier than the arm's "T rollback". Waiting (§23.2): 120 s, then up to 60 s more while the pid is alive with
#     rbarm.sh in its cmdline; still alive -> NEEDS-PERSON (never killed, nothing started beside it); gone without a
#     RESULT and [all] != fw-part A -> prov-rbfix-254.sh (recovery only, its own preconditions) + NEEDS-PERSON.
# Type: revert / A. Side effects: 04 ~50 min (one deadline revert, B rewritten twice), bad-slot handled by pr_end revert.
set -u
PR_UNIT=prov-wbox-nocommit-254
# shellcheck source=scripts/dv/prov-254.sh
. "$(dirname "$0")/prov-254.sh"
W=/tmp/run/batman-dv/wbox/$RUN
# the arm, its launcher, the recovery script, their out and pid files: one level under /tmp/run/batman-dv, where
# preflight P9 looks for a live rbarm.pid / rbfix.pid (prov-p9-254.sh)
RD=/tmp/run/batman-dv/$RUN
WV=""
NL='
'
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
		# logread is this boot's ring only: the boot id comes with it, and a line of another boot is not this trial's (§23.9)
		o=$(timeout 30 ssh $SSHO root@$NODE 'echo "BOOT=$(cut -c1-8 /proc/sys/kernel/random/boot_id)"; logread | grep -E "batman-autocommit.*slot B committed|revert deferred:" | tail -1' 2>/dev/null | tr -d '\r')
		case "$o" in "BOOT=$b0"*) o=${o#*$NL} ;; *) o="" ;; esac
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
	local o rw ab0 fa g kt tr x f
	[ -n "$WV" ] || { no "rollback arm: no wbox version"; return 1; }
	pw prep >/dev/null
	q "mkdir -p -m 0700 $RD; rm -f $RD/rbarm.out $RD/rbarm.pid $RD/harm.out $RD/rbfix.out $RD/rbfix.pid"
	for f in rbarm rbarm-launch rbfix; do
		scp -q $SSHO "$REPO/scripts/node/prov-$f-254.sh" root@$NODE:$RD/$f.sh || { no "push prov-$f-254.sh"; return 1; }
		[ "$(qr "sha256sum < $RD/$f.sh | cut -c1-64")" = "$(sha256sum < "$REPO/scripts/node/prov-$f-254.sh" | cut -c1-64)" ] || { no "$f.sh on the node differs"; return 1; }
	done
	q "chmod 700 $RD/*.sh; echo 'sleep 10; echo RESULT=PASS harmless' > $RD/harm.sh"
	ab0=$(qr 'cut -c1-8 /proc/sys/kernel/random/boot_id'); fa=$(qr 'batman-slot fw-part A')
	# §23.1: start over `ssh -tt`, 3 s later SIGHUP the session's process group (worst case of the hangup) and kill the
	# client; returns the node uptime right after the kill in kt and the session's pgid in g
	ptyrun(){
		local lf sp; lf=$(mktemp -t rblaunch.XXXXXX)   # host side (TMPDIR)
		timeout 60 ssh -tt $SSHO root@$NODE "sh $RD/rbarm-launch.sh $1 $RD; sleep 30" > "$lf" 2>&1 < /dev/null & sp=$!
		sleep 3
		g=$(tr -d '\r' < "$lf" | sed -n 's/.*LAUNCH pid=[0-9]* pgid=\([0-9]*\).*/\1/p'); rm -f "$lf"
		[ -n "$g" ] && q "kill -HUP -- -$g" >/dev/null
		kill "$sp" 2>/dev/null; wait "$sp" 2>/dev/null
		kt=$(qr 'cut -d" " -f1 /proc/uptime')
		[ -n "$g" ]
	}
	# negative control: a harmless arm with a plain `&` through the same path and window must die
	if ptyrun neg; then
		sleep 12
		x=$(qr "grep '^RESULT=' $RD/harm.out 2>/dev/null")
		if [ -z "$x" ]; then ok "drop proof negative control: a plain & arm died with the session (pgid $g)"
		else inv "drop proof: the harmless plain & arm survived ($x) — the drop proof does not discriminate on this node (§23.1)"; fi
	else inv "drop proof negative control: the launcher printed no pgid"; fi
	ptyrun "$WV" || inv "drop proof: the launcher printed no pgid (the arm still runs; its verdict counts)"
	say "ssh -tt killed at node uptime $kt (session pgid ${g:-?})"
	o=$(pr_wait_result "$RD/rbarm.out" "$RD/rbarm.pid" 120 180 rbarm.sh); rw=$?
	say "rollback arm: ${o:-no result}"
	[ "$rw" = 2 ] || q "rm -f $RD/rbarm.pid"   # ALIVE = the arm may still run: P9 must see its pid
	if [ -n "$g" ]; then
		[ "$(qr "kill -0 $g 2>/dev/null && echo alive || echo gone")" = gone ] && ok "the ssh session shell (pgid $g) is gone" || inv "drop proof: the session shell $g is still alive"
	fi
	tr=$(qr "sed -n 's/^T rollback=//p' $RD/rbarm.out")
	if [ -n "$tr" ] && [ -n "$kt" ] && awk -v a="$kt" -v b="$tr" 'BEGIN { exit !(a < b) }'; then ok "the session was killed (uptime $kt) before the arm's rollback ($tr): the arm outlived it"
	elif [ -n "$tr" ]; then inv "drop proof: kill at $kt is not before the arm's rollback at $tr"; fi
	case "$o" in
		RESULT=PASS*) ok "rollback to the wbox B refused, [all] unchanged (${o#RESULT=PASS })" ;;
		RESULT=FAIL-RECOVERED*) no "GATE REGRESSION: rollback to the wbox B was accepted — recovered to A (${o#RESULT=})" ;;
		RESULT=FAIL-NEEDS-PERSON*) pr_needs_person "rollback arm: ${o#RESULT=}"; return 1 ;;
		RESULT=INVALID*) inv "rollback arm: ${o#RESULT=INVALID }" ;;
		ALIVE) pr_needs_person "rollback arm still running (or 04 silent) 180 s after its start — NOT killed, nothing started beside it (slot_lock). On 04: $(qr ". /usr/lib/batman/bootfacts.sh; echo \"[all]=\$(bf_ab_all)\"; sed -n '/^\[tryboot\]/,/^\[/p' /boot/autoboot.txt | tr '\n' ' '; ps w | grep -E '[r]barm|[b]atman-slot' | tr '\n' ';'") — wait for $RD/rbarm.out; [all] must be fw-part A ($fa)"; return 1 ;;
		*)	o=$(qr '. /usr/lib/batman/bootfacts.sh; bf_ab_all')   # the arm ended without a RESULT line
			if [ "$o" = "$fa" ]; then no "rollback arm: ended without a RESULT line ([all]=$o = fw-part A, unchanged)"
			else
				# §23.2: the recovery only, with its own preconditions (A, same boot, no batman-slot running)
				q "trap '' HUP PIPE; setsid sh $RD/rbfix.sh $ab0 $RD > $RD/rbfix.out 2>&1 < /dev/null &"
				x=$(pr_wait_result "$RD/rbfix.out" "$RD/rbfix.pid" 30 60 rbfix.sh)
				pr_needs_person "rollback arm ended without a RESULT and [all]=$o != fw-part A ($fa); rbfix: ${x:-no result}"; return 1
			fi ;;
	esac
	[ "$rw" = 2 ] || q "rm -f $RD/rbfix.pid"
}
pr_begin 3600 || { pr_result; exit 1; }
trial || { pr_abort "trial"; pr_result; exit 1; }
rbarm || { pr_abort "rollback arm"; pr_result; exit 1; }
pr_end revert
pr_result
