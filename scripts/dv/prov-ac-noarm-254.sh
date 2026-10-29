#!/bin/bash
# scripts/dv/prov-ac-noarm-254.sh — #254 tier-B unit autocommit (6) (replaces (5); docs/design/254-h23-harness.md §6.2,
# §19.2, F12): a MEMBER whose trial was not armed by the OTA path needs its neighbours (fail-closed), and an arm file of
# another boot does not count.
#   precondition: 04 = member (only the member:* branch reads ota-armed.mesh, autocommit :416-421)
#   arm a: payload V extracted, `sysupgrade -T` OK, hold written + cmp BEFORE the apply (apply arms tryboot), the arm
#     file removed, `batman-slot apply` -> still no arm file after the apply -> plain reboot -> the B trial logs
#     "member: no usable ota-armed.mesh — neighbours required (fail-closed)" and "mesh join required: 1"
#   arm b: the same with a hand-written arm file whose boot id is NOT this boot's -> no "no usable" line,
#     "mesh join required: 1"
#   both: ota-trace "AC UNHEALTHY first_why=" names "mesh not joined/reachable" (the test mesh has no neighbour) ->
#     back to A within uptime 480 s. (3) / prov-ota-254 is the counterpart (the real OTA arms radio-only).
# Type: hold + back_to_a / A. Side effects: 04 ~70 min off the mesh, B's boot files rewritten twice, ~8 reboots.
set -u
PR_UNIT=prov-ac-noarm-254
# shellcheck source=scripts/dv/prov-254.sh
. "$(dirname "$0")/prov-254.sh"
PDIR=/opt/batdata/dv-prov/payload-$RUN
ARM=/opt/batdata/state/ota-armed.mesh
arm(){	# <a|b>
	local w=$1 s b0 o r hv
	pr_member || return 1
	pr_payload "$PR_V" >/dev/null || { no "payload $PR_V"; return 1; }
	hv=$(sed -n 's/^BATMAN_VERSION=//p' <<< "$PSTAMP")
	scp -q $SSHO "$PAYF" root@$NODE:$PR_PAY.part && q "mv $PR_PAY.part $PR_PAY" || { no "payload upload"; return 1; }
	[ "$(qr "sha256sum < $PR_PAY | cut -c1-64")" = "$PSHA" ] || { no "payload sha on the node"; return 1; }
	o=$(q "rm -rf $PDIR; mkdir -p -m 0700 $PDIR && tar -xzf $PR_PAY -C $PDIR && echo EXTRACTED; sysupgrade -T $PR_PAY >/dev/null 2>&1; echo T=\$?")
	grep -q EXTRACTED <<< "$o" && grep -q 'T=0' <<< "$o" || { no "extract / sysupgrade -T: $(echo $o)"; return 1; }
	q "printf '%s\n' '$hv' > $HOLDF; sync"; [ "$(qr "cat $HOLDF")" = "$hv" ] || { no "hold read-back"; return 1; }
	if [ "$w" = a ]; then q "rm -f $ARM; sync"
	else q "printf '%s B radio\n' \$(head -c 4 /dev/urandom | hexdump -v -e '1/1 \"%02x\"') > $ARM; sync"; say "arm b: hand-written $(qr "cat $ARM") (not this boot)"; fi
	o=$(timeout 900 ssh $SSHO root@$NODE "batman-slot apply $PDIR 2>&1 | tail -3" 2>/dev/null | tr -d '\r'); say "apply: $(echo $o)"
	grep -q "armed as one-shot tryboot" <<< "$o" || { q "$DISARM; rm -f $HOLDF" >/dev/null; no "apply did not arm: $o"; return 1; }
	PR_WROTE_B=1
	if [ "$w" = a ]; then [ "$(qr "[ -e $ARM ] && echo present || echo absent")" = absent ] && ok "arm a: no ota-armed.mesh after the direct apply" || no "arm a: an arm file exists after the apply"; fi
	s=$(qr "$ST"); b0=$(field "$s" boot)
	q '(sync; reboot) </dev/null >/dev/null 2>&1 &'
	pr_find 900 "$b0" || return 1
	s=$PR_STATE; say "landed: $s"
	[ "$(field "$s" slot)" = B ] && [ "$(field "$s" trial_rc)" = 0 ] && [ "$(field "$s" dt_try)" = 00000001 ] && [ "$(field "$s" held)" = 1 ] \
		&& ok "arm $w: landed in the held B trial" || { no "arm $w: landing ($s)"; back_to_a; return 1; }
	r=$(pr_trial_line 'mesh join required:'); say "trial: ${r##*autocommit*: }"
	case "$r" in *"mesh join required: 1 "*) ok "arm $w: mesh join required: 1";; *) no "arm $w: [$r] (want mesh join required: 1)";; esac
	o=$(qr "logread | grep -c 'member: no usable ota-armed.mesh — neighbours required (fail-closed)'")
	if [ "$w" = a ]; then [ "${o:-0}" -ge 1 ] && ok "arm a: 'no usable ota-armed.mesh — neighbours required (fail-closed)'" || no "arm a: no fail-closed line"
	else [ "${o:-0}" = 0 ] && ok "arm b: no 'no usable' line (the file exists, its boot id is not this boot's)" || no "arm b: the 'no usable' line appeared"; fi
	# this boot's line only (every ota-trace line carries boot=<boot_id8>, otatrace.sh:28)
	t=0; r=""; while [ $t -lt 30 ]; do r=$(qr "grep 'boot=$(field "$PR_STATE" boot) .*AC UNHEALTHY first_why=' /opt/batdata/log/ota-trace.log | tail -1"); [ -n "$r" ] && break; sleep 10; t=$((t + 1)); done
	case "$r" in *"mesh not joined/reachable"*) ok "arm $w: first_why names the mesh (${r##*first_why=})";; *) no "arm $w: first_why [$r]";; esac
	[ "$(qr 'cut -d. -f1 /proc/uptime')" -lt 480 ] && ok "arm $w: judged before uptime 480 s" || no "arm $w: past uptime 480 s"
	back_to_a || return 1
	q "rm -rf $PDIR $PR_PAY"
}
pr_begin 3000 || { pr_result; exit 1; }
arm a || { pr_abort "arm a"; pr_result; exit 1; }
pr_restore || { pr_abort "restore between the arms"; pr_result; exit 1; }
arm b || { pr_abort "arm b"; pr_result; exit 1; }
pr_end
pr_result
