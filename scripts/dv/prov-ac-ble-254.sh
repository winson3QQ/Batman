#!/bin/bash
# scripts/dv/prov-ac-ble-254.sh — #254 tier-B unit autocommit (8) (docs/design/254-h23-harness.md §6.2; F12 latch, F14):
# the trial's BLE health gate is WARN-only (P-U5) and keyed on p6 ble-ok. P1 helpers report adv_registered_once=0
# (no GATT yet), so with ble-ok present the health is never "good" and the trial must WARN once, never block.
#   arm A: ble-ok present (S0) -> OTA V hold -> exactly one "WARN ble:" line this boot (content recorded) + HELD
#   arm B: helper stopped -> state-set ble-ok absent -> kept stopped until sysupgrade -n is sent (the committed slot's
#     helper would write it back within 15 s, v4 B-m3) -> OTA V hold -> no WARN line + HELD; ble-ok still absent
#     (the trial never writes it, F14)
#   arm C: as B, then in the trial: `bluetoothctl power off` (the design names btmgmt; the image has no btmgmt) ->
#     the helper's health file reads hci0_powered=0 within one tick -> state-set ble-ok present (allowed in a trial)
#     -> the next poll prints "WARN ble: … hci0_powered=0 …" + HELD
#   the three arms are each other's controls (A vs B: ble-ok gates the WARN; C: the health content reaches it)
# Type: hold / A. Side effects: 04 ~45 min, B rewritten 3x, ~7 reboots; the helper is stopped on A for ~3 min (B, C).
set -u
PR_UNIT=prov-ac-ble-254
# shellcheck source=scripts/dv/prov-254.sh
. "$(dirname "$0")/prov-254.sh"
BOK=/opt/batdata/state/ble-ok
HF='. /usr/lib/batman/rundir.sh; cat $RUNDIR/batman-prov.health 2>/dev/null'
# autocommit's log() writes each line twice — logger (user.*) and /dev/kmsg (kernel:) — so count the syslog copy only
# (run 1, 2026-10-28: "2 WARN ble lines" in arms A and C)
nwarn(){ qr "logread | grep -v ' kernel: ' | grep -c 'batman-autocommit: WARN ble:'"; }
drop_bok(){
	q "/etc/init.d/batman-provhelper stop >/dev/null 2>&1; sleep 1; pidof batman-provhelper >/dev/null && echo STILL" | grep -q STILL && { no "the helper did not stop"; return 1; }
	o=$(nb state-set "$RUN" ble-ok absent); grep -q 'STATE-SET ble-ok=absent' <<< "$o" || { no "state-set absent: $o"; return 1; }
	[ "$(qr "[ -e $BOK ] && echo present || echo absent")" = absent ] && say "ble-ok dropped, helper stopped until the OTA reboot" || { no "ble-ok still there"; return 1; }
}
arm(){	# <A|B|C>
	local w=$1 n r h o t
	if [ "$w" = A ]; then [ "$(qr "[ -e $BOK ] && echo present || echo absent")" = present ] || { no "arm A precondition: no ble-ok at S0"; return 1; }
	else drop_bok || return 1; fi
	pr_ota_b "$PR_V" B || return 1
	if [ "$w" = C ]; then
		[ "$(qr "[ -e $BOK ] && echo present || echo absent")" = absent ] || { no "arm C: ble-ok present in the trial before the set"; back_to_a; return 1; }
		o=$(qr 'bluetoothctl power off 2>&1 | tail -1'); say "arm C: bluetoothctl power off: $o"
		t=0; h=""; while [ $t -lt 6 ]; do h=$(qr "$HF"); case "$h" in *hci0_powered=0*) break;; esac; sleep 5; t=$((t + 1)); done
		case "$h" in *hci0_powered=0*) ok "arm C: health reads hci0_powered=0";; *) no "arm C: health never read hci0_powered=0 ($h)"; back_to_a; return 1;; esac
		[ "$(nwarn)" = 0 ] || { no "arm C: a WARN line before ble-ok was placed"; back_to_a; return 1; }
		o=$(nb state-set "$RUN" ble-ok present); grep -q 'STATE-SET ble-ok=present' <<< "$o" || { no "arm C: state-set present in the trial: $o"; back_to_a; return 1; }
		t=0; while [ $t -lt 6 ] && [ "$(nwarn)" = 0 ]; do sleep 5; t=$((t + 1)); done
	fi
	pr_wait_held 480 && ok "arm $w: HELD" || no "arm $w: not HELD by uptime 480 s"
	[ "$w" = C ] || sleep 30   # A / B: a few more polls, so a late WARN would be seen
	n=$(nwarn); r=$(qr "logread | grep -m1 'autocommit.*WARN ble:'")
	case "$w" in
	A) [ "$n" = 1 ] && ok "arm A: one WARN ble line (${r##*WARN ble: })" || no "arm A: $n WARN ble lines (want 1)" ;;
	B) [ "$n" = 0 ] && ok "arm B: no WARN ble line" || no "arm B: $n WARN ble lines (want 0): $r"
	   [ "$(qr "[ -e $BOK ] && echo present || echo absent")" = absent ] && ok "arm B: the trial did not write ble-ok back" || no "arm B: ble-ok appeared in the trial" ;;
	C) case "$r" in *"WARN ble:"*hci0_powered=0*) ok "arm C: WARN ble names hci0_powered=0";; *) no "arm C: [$r] (want a WARN ble line with hci0_powered=0)";; esac
	   [ "$n" = 1 ] || no "arm C: $n WARN ble lines (want 1)" ;;
	esac
	back_to_a || return 1
}
pr_begin 3600 || { pr_result; exit 1; }
arm A || { pr_abort "arm A"; pr_result; exit 1; }
pr_restore || { pr_abort "restore after arm A"; pr_result; exit 1; }
arm B || { pr_abort "arm B"; pr_result; exit 1; }
pr_restore || { pr_abort "restore after arm B"; pr_result; exit 1; }
arm C || { pr_abort "arm C"; pr_result; exit 1; }
pr_end
pr_result
