#!/bin/bash
# scripts/dv/prov-ac-flap-254.sh — #254 tier-B unit autocommit (9) (docs/design/254-h23-harness.md §6.2; F14, F42):
# characterization — a helper that keeps exiting (wbox helper-flap: exit 5 s after serving, procd respawns) does not
# stop a trial from being judged commit-worthy (BLE health is WARN-only, P-U5). L39's real intent (provd flap) is §6.3.
#   precondition: ble-ok present (S0)
#   -wbox helper-flap hold into B -> the mutant is live (>= 2 "WBOX-helper-flap-f4703b1d: exiting" lines) -> the
#   helper's health file is this boot's and fresh (not stale, F14) -> the real main's WARN ble line and "is healthy
#   and HELD" (content recorded) -> in the same trial a background dry run
#   (AUTOCOMMIT_DRYRUN=1 AUTOCOMMIT_FORCE_TRIAL=1 AUTOCOMMIT_TIMEOUT=<uptime+120>, killed after 180 s; no `timeout`
#   applet on the node) prints "DRYRUN decision: COMMIT slot B (services 3x10s, mesh samples <n>)" -> back to A.
#   The mutant slot is never really committed (v4 A-M1); the dry run's own ctl dir is autocommit.ctl.dry (:53).
# Type: hold / A. Side effects: 04 ~45 min, B rewritten twice (wbox, then V), ~4 reboots.
set -u
PR_UNIT=prov-ac-flap-254
# shellcheck source=scripts/dv/prov-254.sh
. "$(dirname "$0")/prov-254.sh"
W=WBOX-helper-flap-f4703b1d
flap(){
	local n h u r o
	[ "$(qr "[ -e /opt/batdata/state/ble-ok ] && echo present || echo absent")" = present ] || { no "precondition: no ble-ok at S0"; return 1; }
	pr_ota_b "$PR_V.dirty.wbox-helper-flap" B || return 1
	pr_wait_held 480 && ok "HELD (helper-flap trial)" || no "not HELD by uptime 480 s"
	n=$(qr "logread | grep -c '$W: exiting'")
	[ "${n:-0}" -ge 2 ] && ok "mutant live: $n helper exits this boot" || { no "mutant had no effect: $n '$W: exiting' lines"; back_to_a; return 1; }
	h=$(qr '. /usr/lib/batman/rundir.sh; cat $RUNDIR/batman-prov.health 2>/dev/null'); u=$(qr 'cut -d. -f1 /proc/uptime'); say "health: $h (uptime $u)"
	case "$h" in "boot_id=$(qr 'cat /proc/sys/kernel/random/boot_id') ts="*) ;; *) no "health file not this boot's: [$h]"; back_to_a; return 1 ;; esac
	r=${h#*ts=}; r=${r%% *}
	[ $((u - r)) -le 60 ] 2>/dev/null && ok "health fresh: ts $r, uptime $u" || no "health stale: ts $r, uptime $u"
	r=$(qr "logread | grep -m1 'autocommit.*WARN ble:'"); say "real main WARN: ${r##*WARN ble: }"
	r=$(qr "logread | grep -m1 'is healthy and HELD'"); say "real main: ${r##*autocommit*: }"
	# each line stamped with node seconds since the start: E-H5 #2 (§22.6) = the time to the decision, canary included
	o=$(QT=260 q "u=\$(cut -d. -f1 /proc/uptime); { AUTOCOMMIT_DRYRUN=1 AUTOCOMMIT_FORCE_TRIAL=1 AUTOCOMMIT_TIMEOUT=\$((u + 120)) batman-autocommit run 2>&1 & p=\$!; ( sleep 180; kill \$p 2>/dev/null ) & w=\$!; wait \$p; kill \$w 2>/dev/null; } | while IFS= read -r l; do echo \"+\$(( \$(cut -d. -f1 /proc/uptime) - u ))s \$l\"; done | grep -E 'DRYRUN decision|PRECOMMIT|health regressed' | tail -4")
	echo "$o" | sed 's/^/    dry: /'
	t=$(sed -n 's/^+\([0-9]*\)s DRYRUN decision.*/\1/p' <<< "$o" | head -1); say "E-H5 #2: the dry run decided at +${t:-?}s (canary included; bound 180 s)"
	o=$(sed 's/^+[0-9]*s //' <<< "$o")
	grep -qE '^DRYRUN decision: COMMIT slot B \(services 3x10s, mesh samples [0-9]+\)' <<< "$o" \
		&& ok "dry run: $(grep -m1 'DRYRUN decision' <<< "$o")" || no "dry run: no 'DRYRUN decision: COMMIT slot B' within 180 s"
	back_to_a || return 1
}
pr_begin 3000 || { pr_result; exit 1; }
flap || { pr_abort "helper-flap"; pr_result; exit 1; }
pr_end
pr_result
