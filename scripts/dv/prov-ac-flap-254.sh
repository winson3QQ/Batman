#!/bin/bash
# scripts/dv/prov-ac-flap-254.sh — #254 tier-B unit autocommit (9) (docs/design/254-h23-harness.md §6.2; F14, F42;
# the P3 rule: docs/design/254-v16-group4.md §1): a trial whose helper keeps exiting (wbox helper-flap: exit 5 s after
# serving, procd respawns it) is NOT commit-worthy — P3 (#324) made the helper running (a) and `provd-stable`
# written (b) part of health_ok (batman-autocommit `svc batman-provhelper down` / `batman-provd not stable for 60 s
# yet this boot`), and the deadline revert removes the trial even while it is held. The helper never lives the 60 s
# that provd-stable needs, so every poll's why is (a) or (b) and HELD cannot occur (deterministic).
#   precondition: ble-ok present (S0)
#   -wbox helper-flap hold into B -> every 10 s in the trial boot, until 30 s before the trial's own deadline
#   ($RUNDIR/autocommit.deadline), one autocommit.why sample, each logged -> the mutant is live (>= 2
#   "WBOX-helper-flap-f4703b1d: exiting" lines) and the helper's health file is this boot's and fresh (F14) ->
#   pr_wait_reverted (HELD = FAIL, a deferral renews the lease, a panic = INVALID; it finds the node again on A) ->
#   acflap_judge <samples> <revert line>: at least one sample contains (a), and the revert reason is (a) or (b) ->
#   pr_end revert (bad-slot checked and removed, restore, B back to V).
# The pre-P3 judgement (HELD + a dry run deciding COMMIT) is gone; its timed dry run (E-H5 #2) is in
# prov-autocommit-p3-254 (AC1, the healthy case). Offline test of the judge: scripts/dv/test-acflap-254.sh.
# Type: hold+revert / A. Side effects: 04 ~45 min, B rewritten twice (wbox, then V), ~4 reboots.
set -u
PR_UNIT=prov-ac-flap-254
W=WBOX-helper-flap-f4703b1d
ACF_A="svc batman-provhelper down"; ACF_B="batman-provd not stable"
# acflap_judge <samples, one why per line> <TRIAL-REVERTED line>: one line "ACFLAP PASS|FAIL: <why>"; rc 0 = PASS
acflap_judge(){
	local s=$1 r=$2 n
	n=$(printf '%s\n' "$s" | grep -c .)
	[ "$n" -gt 0 ] || { echo "ACFLAP FAIL: no autocommit.why sample — nothing observed in the trial"; return 1; }
	printf '%s\n' "$s" | grep -qF -- "$ACF_A" || { echo "ACFLAP FAIL: (a) never observed: no sample of $n contains '$ACF_A'"; return 1; }
	[ -n "$r" ] || { echo "ACFLAP FAIL: no TRIAL-REVERTED line"; return 1; }
	case "${r##*reason=}" in
		*"$ACF_A"*|*"$ACF_B"*) echo "ACFLAP PASS: (a) in $(printf '%s\n' "$s" | grep -cF -- "$ACF_A") of $n samples; revert reason: ${r##*reason=}"; return 0 ;;
		*) echo "ACFLAP FAIL: the revert reason is neither (a) nor (b): ${r##*reason=}"; return 1 ;;
	esac
}
# shellcheck source=scripts/dv/prov-254.sh
. "$(dirname "$0")/prov-254.sh"
SAMPLES=""
# sample: autocommit.why every 10 s in the trial boot until 30 s before its deadline; rc 1 when the trial ended early
sample(){
	local dl b0 o u w t0
	dl=$(qr '. /usr/lib/batman/rundir.sh; cat $RUNDIR/autocommit.deadline 2>/dev/null'); b0=$(field "$(qr "$ST")" boot)
	case "$dl" in ''|*[!0-9]*) no "no autocommit deadline in the trial [$dl]"; return 1 ;; esac
	say "sampling autocommit.why every 10 s until uptime $((dl - 30)) s (the trial's deadline: $dl s)"; t0=$(mono)
	while :; do
		o=$(timeout 30 ssh $SSHO root@$NODE '. /usr/lib/batman/rundir.sh; echo "BOOT=$(cut -c1-8 /proc/sys/kernel/random/boot_id) UP=$(cut -d. -f1 /proc/uptime) HR=$(/etc/init.d/batman-provhelper running && echo 1 || echo 0) WHY_MTIME=$(date -r $RUNDIR/autocommit.why +%s 2>/dev/null) NOW=$(date +%s)"; cat $RUNDIR/autocommit.why 2>/dev/null' 2>/dev/null | tr -d '\r')
		pr_trial_guard_tick "$b0"
		case "$o" in
			"BOOT=$b0 UP="*)
				u=$(head -1 <<< "$o"); DG=${u#* UP=}; u=${u#*UP=}; u=${u%% *}; w=$(tail -n +2 <<< "$o" | head -1)
				if [ -n "$w" ]; then SAMPLES="$SAMPLES$w"$'\n'; say "why @${u}s: $w [diag ${DG#* }]"; else say "why @${u}s: (none yet)"; fi
				[ "${u:-0}" -ge $((dl - 30)) ] 2>/dev/null && { [ -n "${DV_DIR:-}" ] && qr "logread | grep -E 'WBOX-helper-flap|batman-autocommit|provhelper' | tail -400" > "$DV_DIR/flap-logread.txt"; return 0; } ;;
			BOOT=*) no "the trial boot $b0 ended before uptime $((dl - 30)) s (now [$(head -1 <<< "$o")])"; return 1 ;;
		esac
		[ $(( $(mono) - t0 )) -gt $(( dl + 300 )) ] && { no "no sample at uptime >= $((dl - 30)) s within $((dl + 300)) s of host time"; return 1; }
		sleep 10
	done
}
flap(){
	local n h u r o
	[ "$(qr "[ -e /opt/batdata/state/ble-ok ] && echo present || echo absent")" = present ] || { no "precondition: no ble-ok at S0"; return 1; }
	pr_ota_b "$PR_V.dirty.wbox-helper-flap" B || return 1
	sample || { [ "$(field "$(qr "$ST")" slot)" = B ] && back_to_a; return 1; }
	# still in the trial, 30 s before its deadline: the mutant was live and the helper's health file is this boot's
	n=$(qr "logread | grep -c '$W: exiting'")
	[ "${n:-0}" -ge 2 ] && ok "mutant live: $n helper exits this boot" || { no "mutant had no effect: $n '$W: exiting' lines"; back_to_a; return 1; }
	h=$(qr '. /usr/lib/batman/rundir.sh; cat $RUNDIR/batman-prov.health 2>/dev/null'); u=$(qr 'cut -d. -f1 /proc/uptime'); say "health: $h (uptime $u)"
	case "$h" in "boot_id=$(qr 'cat /proc/sys/kernel/random/boot_id') ts="*) ;; *) no "health file not this boot's: [$h]"; back_to_a; return 1 ;; esac
	r=${h#*ts=}; r=${r%% *}
	[ $((u - r)) -le 60 ] 2>/dev/null && ok "health fresh: ts $r, uptime $u" || no "health stale: ts $r, uptime $u"
	if pr_wait_reverted; then
		o=$(acflap_judge "$SAMPLES" "$PR_REVERT_LINE") && ok "${o#ACFLAP PASS: }" || no "${o#ACFLAP FAIL: }"
		pr_end revert; return 0
	fi
	[ "$(field "$(qr "$ST")" slot)" = B ] && back_to_a
	return 1
}
pr_begin 3000 || { pr_result; exit 1; }
flap || { pr_abort "helper-flap"; pr_result; exit 1; }
pr_result
