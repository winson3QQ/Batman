#!/bin/bash
# scripts/dv/prov-base-254.sh — #254 tier-B unit prov-base-254 (docs/design/254-h23-harness.md §6.2; p1-impl §5.3 /
# §4.5): the snapshot / restore machinery every other prov unit stands on, proven on 04.
#   1 snap (pr_begin) -> change one p5 file, one overlay file, one p6 state file, delete the lower /etc/banner (a
#     whiteout in the upper) -> compare must SEE all four (positive control of compare)
#   2 negative controls: restore with PROV_BASE_SKIP=p5 -> compare FAILs on p5 only; change again, restore with
#     PROV_BASE_SKIP=extra -> compare FAILs on the upper extras only
#   3 power loss in the middle of the p5 write: sysrq "b" while the restore's dd runs -> 04 reboots with a half-written
#     p5 -> the restore run again (idempotent) -> S0: diffs=0, /etc/banner back
#   4 prov-boot-254 (scripts/node/prov-p1-254.sh) after each of the three restore reboots: all PASS (L2 x3)
# Type: — / A / F. Side effects: 04 reboots 4 times (one of them a sysrq hard reboot), ~45 min off the mesh; B untouched.
set -u
PR_UNIT=prov-base-254
# shellcheck source=scripts/dv/prov-254.sh
. "$(dirname "$0")/prov-254.sh"
PJ=$REPO/scripts/node/prov-p1-254.sh
boots=0
prov_boot(){	# the tier-A judge after a reboot
	local o; o=$(timeout 300 ssh $SSHO root@$NODE sh -s < "$PJ" 2>&1 | tr -d '\r'); boots=$((boots + 1))
	if [ -n "$o" ] && ! grep -q '^FAIL' <<< "$o"; then ok "prov-boot-254 after reboot $boots: $(grep -c '^PASS' <<< "$o") PASS, 0 FAIL"
	else no "prov-boot-254 after reboot $boots: $(grep '^FAIL' <<< "$o" | head -5 | tr '\n' '|')"; fi
}
mutate(){	# $1 = what: all | extra
	local m
	q "echo dv-$RUN > /etc/dv-prov-base-$RUN"
	[ "$1" = extra ] && return 0
	m=$(q "/etc/init.d/joinwatch stop >/dev/null 2>&1; d=\$(mktemp -d /tmp/run/batman-dv/pbm.XXXXXX) && mount -t ext4 /dev/mmcblk0p5 \$d && echo dv-$RUN > \$d/dv-prov-base-$RUN && sync && umount \$d && rmdir \$d && echo P5W; /etc/init.d/joinwatch start >/dev/null 2>&1")
	[ "$m" = P5W ] || { no "could not write the p5 test file ($m)"; return 1; }
	q "echo dv-$RUN > /opt/batdata/state/mesh-expected; rm -f /etc/banner; sync"
}

pr_begin 3000 || { pr_result; exit 1; }
# ---- 1 changes, and compare sees each of them
mutate all || { pr_abort "mutate"; pr_result; exit 1; }
pr_compare before && no "compare saw no difference after four changes" || {
	c=$PR_CMP; echo "$c" | grep '^DIFF' | head -12 | sed 's/^/    /'
	grep -q "^DIFF p5.manifest .*dv-prov-base-$RUN" <<< "$c" && ok "compare sees the p5 change" || no "compare missed the p5 change"
	grep -q "^DIFF upper.manifest .*etc/dv-prov-base-$RUN" <<< "$c" && ok "compare sees the overlay file" || no "compare missed the overlay file"
	grep -q "^DIFF upper.manifest .*etc/banner" <<< "$c" && ok "compare sees the whiteout of the lower /etc/banner" || no "compare missed the banner whiteout"
	grep -q "^DIFF state mesh-expected" <<< "$c" && ok "compare sees the p6 state change" || no "compare missed the p6 state change"
}
# ---- 2 negative controls
pr_restore_cycle p5 || { pr_abort "restore cycle (skip p5)"; pr_result; exit 1; }
grep -q "SKIP p5 write" <<< "$PR_RCYCLE_OUT" || no "PROV_BASE_SKIP=p5 did not reach the node"
prov_boot
if pr_compare skipp5; then no "negative control: PROV_BASE_SKIP=p5 still compared clean"
else d=$(grep '^DIFF' <<< "$PR_CMP"); echo "$d" | head -6 | sed 's/^/    /'
	if grep -q '^DIFF p5.manifest' <<< "$d" && ! grep -qv '^DIFF p5.manifest' <<< "$d"; then ok "negative control: p5 not written -> compare FAILs on p5 only"
	else no "negative control (skip p5): unexpected diffs"; fi; fi
mutate extra
pr_restore_cycle extra || { pr_abort "restore cycle (skip extra)"; pr_result; exit 1; }
grep -q "SKIP extra removal" <<< "$PR_RCYCLE_OUT" || no "PROV_BASE_SKIP=extra did not reach the node"
prov_boot
if pr_compare skipextra; then no "negative control: PROV_BASE_SKIP=extra still compared clean"
else d=$(grep '^DIFF' <<< "$PR_CMP"); echo "$d" | head -6 | sed 's/^/    /'
	# the p5 still differs (skip p5 left it), plus the upper extras
	grep -q "^DIFF upper.manifest .*etc/dv-prov-base-$RUN" <<< "$d" && ok "negative control: extras kept -> compare FAILs on the upper extra" || no "negative control (skip extra): the extra file not seen"
fi
# ---- 3 power loss in the middle of the p5 write, then the restore again
s=$(qr "$ST"); b0=$(field "$s" boot)
pr_lease_renew +1800 || { pr_abort "renew"; pr_result; exit 1; }
pl restoring set >/dev/null
o=$(timeout 600 ssh $SSHO root@$NODE "(n=0; while ! pidof dd >/dev/null && [ \$n -lt 120 ]; do sleep 1; n=\$((n+1)); done; sleep 3; pidof dd >/dev/null && echo b > /proc/sysrq-trigger) </dev/null >/dev/null 2>&1 & sh -s -- p5-restore $RUN" < "$PB" 2>&1 | tr -d '\r')
say "p5-restore under sysrq: $(echo "$o" | tail -2 | tr '\n' '|')"
grep -q "^P5-RESTORED" <<< "$o" && inv "the dd finished before the sysrq reboot (no power loss in the middle)"
pr_find 900 "$b0" || { pr_needs_person "no node after the sysrq reboot"; pr_result; exit 1; }
br=$(qr 'tail -2 /opt/batdata/log/boot-reasons.log'); say "boot-reasons: $br"
grep -qi sysrq <<< "$br" && ok "the reboot was the sysrq one (boot-reasons)" || no "boot-reasons does not show the sysrq reboot: $br"
prov_boot
pr_restore || { pr_needs_person "restore after the power loss did not reach S0"; pr_result; exit 1; }
prov_boot
[ "$(qr "head -c 100 /etc/banner | wc -c; [ -e /etc/dv-prov-base-$RUN ] && echo extra-left")" = 100 ] && ok "/etc/banner back, no extra file left" || no "/etc/banner / extra file after the restore"
# ---- end: nothing was written to B
pr_finish_snap || no "finish"
pr_release
s=$(qr "$ST"); [ "$(field "$s" protB)" = "[$PR_V]" ] && [ "$(qr "$PROTB_LS")" = "$PR_PROTB_LS" ] && ok "slot B untouched" || no "slot B changed: $s"
pr_peer_after
[ "$boots" -ge 3 ] || no "prov-boot ran $boots times (want >= 3)"
pr_result
