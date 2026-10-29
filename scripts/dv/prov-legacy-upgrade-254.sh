#!/bin/bash
# scripts/dv/prov-legacy-upgrade-254.sh — #254 tier-B unit prov-legacy-upgrade-254 (L17; docs/design/254-h23-harness.md
# §6.2, 254-p1-impl §5.3): a fleet node that never had provisioning (pre-P1 image, pre-P1 p5) upgrades to V and comes up
# legacy with nothing it had changed.
#   DV_OLD_VERSION into B (hold) -> release -> B committed -> strip-p5-prov (a pre-P1 p5) -> record AP key, lock-status,
#   authorized_keys, mesh-expected -> V into A (hold) -> the trial's helper: "boot rc=9 verdict=legacy" -> release ->
#   A committed -> the four recorded things unchanged
#   negative control (after the positive): strip-p5-prov again (V's helper seeded p5 on A; rc 9 needs "seeded, no
#   prov") -> -wbox rc9-unclaimed into B (hold) -> "boot rc=9 verdict=unclaimed" -> back to A -> restore
# Type: hold -> commit / A / R. Side effects: 04 ~80 min off the mesh, BOTH slots rewritten (old on B and committed,
# V on A from a fresh overlay; the restore puts A's overlay and p5 back, B is rewritten with V), ~8 reboots.
set -u
PR_UNIT=prov-legacy-upgrade-254
OLD=${DV_OLD_VERSION:-1.5.12-wsl.9+f2f2bf6.fw07f2063}
# shellcheck source=scripts/dv/prov-254.sh
. "$(dirname "$0")/prov-254.sh"
KEEP='echo "ap=$(uci -q get wireless.default_radio0.key | sha256sum | cut -c1-16) lock=$(cat /opt/batdata/state/lock-status 2>/dev/null) ak=$(sha256sum < /etc/dropbear/authorized_keys | cut -c1-16) me=$(cat /opt/batdata/state/mesh-expected 2>/dev/null | sha256sum | cut -c1-16)"'
release_commit(){	# the held trial on <slot>: release -> committed
	local s t=0
	q 'batman-autocommit release >/dev/null 2>&1; echo rc=$?' | sed 's/^/    release: /'
	while [ $t -lt 40 ]; do s=$(qr "$ST"); [ "$(field "$s" trial_rc)" = 1 ] && [ "$(field "$s" slot)" = "$1" ] && break; sleep 10; t=$((t + 1)); done
	[ "$(field "$s" trial_rc)" = 1 ] && [ "$(field "$s" slot)" = "$1" ] || { no "slot $1 not committed after release ($s)"; return 1; }
	ok "slot $1 committed after the release"
}
strip(){ local o; o=$(nb strip-p5-prov "$RUN"); echo "$o" | tail -2 | sed 's/^/    /'; grep -q "^STRIPPED $RUN" <<< "$o" || { no "strip-p5-prov: $(tail -1 <<< "$o")"; return 1; }; }
pr_begin 3000 || { pr_result; exit 1; }
pr_ota_b "$OLD" B || { pr_abort "OTA $OLD"; pr_result; exit 1; }
release_commit B || { pr_abort "commit $OLD on B"; pr_result; exit 1; }
strip || { pr_abort "strip"; pr_result; exit 1; }
k0=$(qr "$KEEP"); say "on $OLD (B): $k0"
pr_ota_b "$PR_V" A || { pr_abort "OTA V into A"; pr_result; exit 1; }
l=$(pr_trial_line 'batman-provhelper.*boot rc=') && say "A trial: ${l##*: }"
grep -q 'boot rc=9 verdict=legacy' <<< "$l" && ok "A trial: the helper says rc=9 verdict=legacy" || no "A trial helper: [$l] (want boot rc=9 verdict=legacy)"
release_commit A || { pr_abort "commit V on A"; pr_result; exit 1; }
k1=$(qr "$KEEP"); say "on V (A): $k1"
for f in ap lock ak me; do [ "$(field "$k1" $f)" = "$(field "$k0" $f)" ] && ok "unchanged by the upgrade: $f" || no "$f changed: $(field "$k0" $f) -> $(field "$k1" $f)"; done
if ! qr '/usr/bin/batman-provhelper --version >/dev/null 2>&1'; then
	no "pre-P1b image — the rc9-unclaimed negative control needs a P1b rc"
else
	# the same precondition as the positive arm: rc 9 = "p5 seeded, no prov" (batman-config-save --prov-get,
	# boot.go case 9). V's helper on A has just seeded p5 with the legacy record, so without a strip the mutant's boot
	# took the in-sync path and its rc-9 change never ran (M6 2026-10-29: "boot rc=0 verdict=legacy action=in sync")
	strip || { pr_abort "strip before the negative control"; pr_result; exit 1; }
	pr_ota_b "$PR_V.dirty.wbox-rc9-unclaimed" B || { pr_abort "OTA rc9-unclaimed"; pr_result; exit 1; }
	l=$(pr_trial_line 'batman-provhelper.*boot rc=') && say "B trial: ${l##*: }"
	grep -q 'boot rc=9 verdict=unclaimed' <<< "$l" && ok "negative control: rc9-unclaimed -> rc=9 verdict=unclaimed" || no "negative control: [$l] — the mutant had no effect"
	back_to_a || { pr_abort "back to A"; pr_result; exit 1; }   # p5 (maybe seeded by the mutant) is put back by the restore
fi
pr_end
pr_result
