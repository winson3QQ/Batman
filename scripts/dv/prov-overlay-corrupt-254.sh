#!/bin/bash
# scripts/dv/prov-overlay-corrupt-254.sh — #254 tier-B unit prov-overlay-corrupt-254 (L33; docs/design/254-h23-harness.md
# §6.2): a corrupt overlay provisioning record is rebuilt from p5 at boot.
#   positive: garbage over A's /etc/batman-prov/prov.cbor -> reboot -> the helper logs "overlay record unusable:" and
#     "boot rc=0 … action=p5 newer: rebuilt the overlay record"; overlay prov.meta == p5, generation unchanged
#   negative control [wbox-B, no reboot]: -wbox helper-norebuild into B (hold) -> garbage over B's prov.cbor -> helper
#     restart (boot logic, F8) -> "overlay record unusable:" but NO rebuild
# Type: — / A / F. Side effects: 04 ~45 min, 2 reboots + one wbox trial, B rewritten (wbox, then V).
set -u
PR_UNIT=prov-overlay-corrupt-254
# shellcheck source=scripts/dv/prov-254.sh
. "$(dirname "$0")/prov-254.sh"
GEN='sed -n "s/.*gen=\([0-9]*\).*/\1/p; s/^[^ ]* \([0-9]*\) .*/\1/p" /etc/batman-prov/prov.meta | head -1'
P5SAME='d=$(mktemp -d /tmp/run/batman-dv/pg.XXXXXX); rmdir $d; batman-config-save --prov-get $d >/dev/null 2>&1; cmp -s $d/prov.meta /etc/batman-prov/prov.meta && echo P5SAME; rm -rf $d'
garbage(){ q 'head -c 512 /dev/urandom > /etc/batman-prov/prov.cbor.dv && mv /etc/batman-prov/prov.cbor.dv /etc/batman-prov/prov.cbor && sync && echo GARBAGE'; }
pr_begin 3000 || { pr_result; exit 1; }
m0=$(qr 'cat /etc/batman-prov/prov.meta'); say "prov.meta before: $m0"
[ "$(garbage)" = GARBAGE ] || { pr_abort "write garbage"; pr_result; exit 1; }
s=$(qr "$ST"); b0=$(field "$s" boot); q "(batman-slot reboot committed prov-dv-254 </dev/null >/dev/null 2>&1 &)"
pr_find 900 "$b0" || { pr_abort "reboot"; pr_result; exit 1; }
l=$(qr "logread | grep 'batman-provhelper' | grep -E 'overlay record unusable|boot rc=' | head -3"); echo "$l" | sed 's/^/    /'
grep -q 'overlay record unusable:' <<< "$l" && ok "helper: overlay record unusable" || no "no 'overlay record unusable:' line"
grep -q 'action=p5 newer: rebuilt the overlay record' <<< "$l" && ok "helper rebuilt the overlay record from p5" || no "no rebuild from p5: $l"
[ "$(qr "$P5SAME")" = P5SAME ] && ok "overlay prov.meta == p5 after the rebuild" || no "overlay / p5 prov.meta differ after the rebuild"
m1=$(qr 'cat /etc/batman-prov/prov.meta'); [ "$m1" = "$m0" ] && ok "prov.meta identical to before (generation unchanged)" || no "prov.meta [$m0] -> [$m1]"
pr_restore || { pr_abort "restore"; pr_result; exit 1; }
if ! qr '/usr/bin/batman-provhelper --version >/dev/null 2>&1'; then
	no "pre-P1b image: $(field "$(qr "$ST")" ver) — the helper-norebuild negative control needs a P1b rc"
else
	pr_ota_b "$PR_V.dirty.wbox-helper-norebuild" B || { pr_abort "OTA helper-norebuild"; pr_result; exit 1; }
	[ "$(garbage)" = GARBAGE ] || { pr_abort "garbage in the B trial"; pr_result; exit 1; }
	p0=$(qr 'pidof batman-provhelper'); q '/etc/init.d/batman-provhelper restart >/dev/null 2>&1'
	t=0; while [ $t -lt 20 ]; do p=$(qr 'pidof batman-provhelper'); [ -n "$p" ] && [ "$p" != "$p0" ] && break; sleep 2; t=$((t + 1)); done
	sleep 5; l=$(qr "logread | grep 'batman-provhelper\[$p\]' | grep -E 'overlay record unusable|boot rc=' | head -3"); echo "$l" | sed 's/^/    /'
	grep -q 'overlay record unusable:' <<< "$l" && ! grep -q 'rebuilt the overlay record' <<< "$l" \
		&& ok "negative control: helper-norebuild leaves the corrupt record (no rebuild)" || no "negative control: [$l] — the mutant had no effect / no log"
	back_to_a || { pr_abort "back to A"; pr_result; exit 1; }
fi
pr_end
pr_result
