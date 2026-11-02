#!/bin/bash
# scripts/dv/prov-lock-failsecure-254.sh — #254 tier-B unit prov-lock-failsecure-254 (docs/design/254-h23-harness.md
# §6.2; F32, F37): power lost after the claim is recorded but BEFORE the root shadow line is written: the node must come
# back shut, and stay shut even when the next image's helper does not run at all.
#   positive: test helper with killpoint claim-before-shadow -> claim -> sysrq -> reboot: lock-status LOCKED, the root
#     shadow field = before the injection, p5 has no identity/shadow-root -> OTA -wbox helper-exit1 into B (hold: the
#     helper exits 1 at once) -> the B trial offers publickey only and is LOCKED -> back to A
#   negative control: the same precondition -> OTA DV_OLD_VERSION (1.5.12-wsl.9, whose 96 locks only with a key AND a
#     password on p5, F32) into B (hold) -> UNPROVISIONED: the pre-claim-lock image would have opened the door
# Type: hold / A / F. Side effects: 04 ~70 min off the mesh, 2 sysrq reboots, B rewritten 3 times (wbox, old, V).
set -u
PR_UNIT=prov-lock-failsecure-254
OLD=${DV_OLD_VERSION:-1.5.12-wsl.9+f2f2bf6.fw07f2063}
# shellcheck source=scripts/dv/prov-254.sh
. "$(dirname "$0")/prov-254.sh"
# root's shadow field by kind, never the hash itself: empty / locked-<! or *> / hash-<sha16 of the field> / other
ROOTF="f=\$(grep '^root:' /etc/shadow | cut -d: -f2); case \"\$f\" in '') echo empty ;; '!'|'*') echo \"locked-\$f\" ;; \\\$*) echo \"hash-\$(printf '%s' \"\$f\" | sha256sum | cut -c1-16)\" ;; *) echo other ;; esac"
SHROOT='mkdir -p -m 0700 /tmp/run/batman-dv; m=$(mktemp -d /tmp/run/batman-dv/p5s.XXXXXX) && mount -o ro,noload /dev/mmcblk0p5 $m && { [ -s $m/identity/shadow-root ] && echo shadow-root || echo none; umount $m; }; rmdir $m'
offered(){ timeout 30 ssh -v $NONEO -o LogLevel=DEBUG root@$NODE true 2>&1 | tr -d '\r' | sed -n 's/.*Authentications that can continue: //p' | tail -1; }
precondition(){	# claim cut at claim-before-shadow by sysrq; the node back shut
	local r0 r1 o
	pr_keys && pr_pc_place && pk_proof || return 1
	r0=$(qr "$ROOTF")
	PR_FD3=""; pr_killpoint claim-before-shadow claim "$OWNER" "$ENC" || return 1
	o=$(qr 'cat /opt/batdata/state/lock-status'); [ "$o" = LOCKED ] && ok "after the cut claim: LOCKED (F37)" || no "after the cut claim: lock-status [$o]"
	# the cut claim must not have handed out a password: the field is as before, or an EMPTY one was locked to "!" by
	# the boot lock (F37: prov_apply_lock turns an empty root field into "!", prov-lock.sh:167-168 — 04's S0 is empty,
	# M6 2026-10-29); a new hash, or anything else, FAILs
	r1=$(qr "$ROOTF")
	if [ "$r1" = "$r0" ]; then ok "root shadow field = before the injection ($r1)"
	elif [ "$r0" = empty ] && [ "$r1" = 'locked-!' ]; then ok "root shadow field: empty before, locked to ! by the boot lock (F37) — no password handed out"
	else no "root shadow field changed by the cut claim ($r0 -> $r1)"; fi
	[ "$(qr "$SHROOT")" = none ] && ok "p5 has no identity/shadow-root" || no "p5 has a shadow-root after the cut"
	return 0
}
pr_begin 3000 || { pr_result; exit 1; }
if ! qr '/usr/bin/batman-provhelper --version >/dev/null 2>&1'; then no "pre-P1b image: $(field "$(qr "$ST")" ver) — the killpoint needs a P1b rc"; pr_end; pr_result; exit 1; fi
precondition || { pr_abort "precondition (positive)"; pr_result; exit 1; }
pr_ota_b "$PR_V.dirty.wbox-helper-exit1" B || { pr_abort "OTA helper-exit1"; pr_result; exit 1; }
m=$(offered); [ "$m" = publickey ] && ok "helper-exit1 trial: sshd offers only publickey" || no "helper-exit1 trial offers [$m]"
o=$(qr 'cat /opt/batdata/state/lock-status'); [ "$o" = LOCKED ] && ok "helper-exit1 trial: LOCKED (fail-secure without a helper)" || no "helper-exit1 trial lock-status [$o]"
back_to_a || { pr_abort "back to A"; pr_result; exit 1; }
pr_restore || { pr_abort "restore between the halves"; pr_result; exit 1; }
precondition || { pr_abort "precondition (negative)"; pr_result; exit 1; }
pr_ota_b "$OLD" B || { pr_abort "OTA $OLD"; pr_result; exit 1; }
o=$(qr 'cat /opt/batdata/state/lock-status'); [ "$o" = UNPROVISIONED ] && ok "negative control: $OLD -> UNPROVISIONED (F32: the old 96 would have opened it)" || no "negative control: $OLD lock-status [$o] (want UNPROVISIONED)"
back_to_a || { pr_abort "back to A (negative)"; pr_result; exit 1; }
pr_end
pr_result
