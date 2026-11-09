#!/bin/bash
# scripts/dv/prov-autocommit-p3-254.sh — #254 H4 appendix A.10, the RD rows that need no seam (p3-how "n"):
# autocommit's dry run on the committed slot (AUTOCOMMIT_DRYRUN=1 AUTOCOMMIT_FORCE_TRIAL=1, as prov-ac-flap-254) says
# what the real trial decision would be. P3 (254-p3 §3.7.6, D16, D17) adds to the decision: the helper running,
# provd stable for >= 60 s (helper's $RUNDIR/provd-stable, 254-h4 §5.6), `inet fw4` present, and WARN-only exceptions
# for a DISABLED provd / helper.
#   AC1  everything up -> COMMIT (the positive control; also the P of every row below)
#   AC3  helper stopped -> REVERT                 (the helper is a P3 health input)
#   AC6  provd disabled (not just stopped) -> COMMIT + WARN   (D6: a node that chose no BLE is still a node)
#   AC8  no `inet fw4` table -> REVERT            (D-17: a signed image with a broken include must not be committed
#        without its firewall)                    [arm only when fw4 can be stopped and started again: undo = fw-start]
# AC2 (a broken provd: a seam), AC4 (provd killed after it was stable: needs the P3 helper writing provd-stable),
# AC5 (a provclient hanging a connection) and AC7 (helper disabled) follow with the RB vehicle / P3's helper.
# W (pre-P3 image): autocommit looks at none of these -> AC3 / AC8 see COMMIT -> FAIL; AC6 sees COMMIT without the
# WARN -> FAIL.
# Type: RD. Side effects: the helper stopped ~4 min and started again; provd disabled ~4 min and enabled again; the
# firewall stopped ~4 min (04 is on the lab LAN only, 254-h4 H4-U11) and started again; every step undone in the arm
# and by the restore (one reboot).
set -u
PR_UNIT=prov-autocommit-p3-254
PR_BASE=member
# shellcheck source=scripts/dv/prov-254.sh
. "$(dirname "$0")/prov-254.sh"
pr_begin 2400 || { pr_result; exit 1; }
SLOT=$(field "$(qr "$ST")" slot)
dry(){	# <label>: one dry run (<= 180 s), prints the decision line; DRY = that line
	local o
	o=$(QT=260 q "u=\$(cut -d. -f1 /proc/uptime); { AUTOCOMMIT_DRYRUN=1 AUTOCOMMIT_FORCE_TRIAL=1 AUTOCOMMIT_TIMEOUT=\$((u + 120)) batman-autocommit run 2>&1 & p=\$!; ( sleep 180; kill \$p 2>/dev/null ) & w=\$!; wait \$p; kill \$w 2>/dev/null; }")
	DRY=$(grep -m1 'DRYRUN decision' <<< "$o"); DRYWARN=$(grep -c 'WARN' <<< "$o")
	echo "$o" | grep -E 'DRYRUN decision|WARN|revert|REVERT' | head -6 | cut -c1-180 | sed "s/^/    $1: /"
	[ -n "$DRY" ] || inv "$1: no DRYRUN decision line within 180 s"
}
# ---- AC1 positive control
dry AC1
case "$DRY" in *"COMMIT slot $SLOT"*) ok "AC1: everything up -> COMMIT";; *) no "AC1: want COMMIT: [$DRY]";; esac
# ---- AC3 helper stopped
q "/etc/init.d/batman-provhelper stop" >/dev/null; sleep 5
h=$(qr 'pidof batman-provhelper | wc -w'); [ "$h" = 0 ] && say "AC3: helper stopped" || inv "AC3: helper still running"
dry AC3
q "/etc/init.d/batman-provhelper start" >/dev/null
case "$DRY" in *"REVERT"*) ok "AC3: helper down -> REVERT";; *"COMMIT"*) no "AC3: helper down but COMMIT (autocommit does not look at the helper): [$DRY]";; *) no "AC3: [$DRY]";; esac
for _ in 1 2 3 4 5 6; do h=$(qr 'pidof batman-provhelper | wc -w'); [ "$h" -ge 1 ] 2>/dev/null && break; sleep 5; done
[ "${h:-0}" -ge 1 ] && ok "AC3: helper running again" || no "AC3: helper did not come back"
# ---- AC6 provd disabled
q "/etc/init.d/batman-provd disable; /etc/init.d/batman-provd stop" >/dev/null; sleep 5
e=$(qr '/etc/init.d/batman-provd enabled && echo on || echo off; pidof batman-provd | wc -w'); say "AC6: provd enabled/pids: $(echo $e)"
dry AC6
q "/etc/init.d/batman-provd enable; /etc/init.d/batman-provd start" >/dev/null
case "$DRY" in *"COMMIT slot $SLOT"*) [ "${DRYWARN:-0}" -ge 1 ] && ok "AC6: provd disabled -> COMMIT with a WARN" || no "AC6: provd disabled -> COMMIT but no WARN line";; *) no "AC6: provd disabled -> want COMMIT + WARN: [$DRY]";; esac
for _ in 1 2 3 4 5 6; do p=$(qr 'pidof batman-provd | wc -w'); [ "$p" -ge 1 ] 2>/dev/null && break; sleep 5; done
e=$(qr '/etc/init.d/batman-provd enabled && echo on || echo off'); [ "$e" = on ] && [ "${p:-0}" -ge 1 ] && ok "AC6: provd enabled and running again" || no "AC6: provd afterwards: enabled=$e pids=${p:-0}"
# ---- AC8 no inet fw4 table (firewall stopped; H4-U11: <= a few minutes, lab LAN only)
t0=$(qr 'nft list tables 2>/dev/null | grep -c "inet fw4"'); [ "$t0" = 1 ] || inv "AC8: inet fw4 not present before the arm [$t0]"
q "/etc/init.d/firewall stop" >/dev/null; sleep 3
t1=$(qr 'nft list tables 2>/dev/null | grep -c "inet fw4"'); say "AC8: inet fw4 tables after stop: $t1"
dry AC8
q "/etc/init.d/firewall start" >/dev/null
case "$DRY" in *"REVERT"*) ok "AC8: no inet fw4 -> REVERT";; *"COMMIT"*) no "AC8: no inet fw4 but COMMIT (autocommit does not look at the firewall): [$DRY]";; *) no "AC8: [$DRY]";; esac
for _ in 1 2 3 4 5 6; do t2=$(qr 'nft list tables 2>/dev/null | grep -c "inet fw4"'); [ "$t2" = 1 ] && break; sleep 5; done
[ "${t2:-0}" = 1 ] && ok "AC8: inet fw4 back" || no "AC8: inet fw4 not back after firewall start [$t2]"
pr_end
pr_result
