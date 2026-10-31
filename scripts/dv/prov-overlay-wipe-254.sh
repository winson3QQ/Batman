#!/bin/bash
# scripts/dv/prov-overlay-wipe-254.sh — #254 tier-B unit prov-overlay-wipe-254 (L60; docs/design/254-h23-harness.md §6.2):
# a node whose overlay is wiped comes back as the same device with the same provisioning (p5 is the record of truth).
#   positive: claim -> `firstboot -y` (the upper wiped, fstools) -> reboot committed -> 96 / the helper restore from p5:
#     state claimed, the same node cert (device id), the same prov.meta generation
#   negative control [wbox-B]: claim -> -wbox 96-norestore into B (hold; a fresh overlay that does NOT restore from p5)
#     -> the B trial is not the claimed device (state / cert / generation differ)
# Type: — / A / R (R = F: the restore puts p5 and the upper back). Side effects: 04 ~50 min, the A upper wiped and
# restored from the snapshot, B rewritten (wbox, then V), ~6 reboots.
set -u
PR_UNIT=prov-overlay-wipe-254
# shellcheck source=scripts/dv/prov-254.sh
. "$(dirname "$0")/prov-254.sh"
ID='echo "cert=$(sha256sum < /etc/batman-prov/identity/node.cert 2>/dev/null | cut -c1-16) meta=$(cut -d" " -f1-4 /etc/batman-prov/prov.meta 2>/dev/null | tr " " ,)"'
pr_begin 3000 || { pr_result; exit 1; }
pr_keys && pr_pc_place && pr_claim || { pr_abort "claim"; pr_result; exit 1; }
i0=$(pr_info); id0=$(qr "$ID"); say "before: $i0 $id0"
# the wiped node must still let the lab key in (claimed = password off): its key must be in p5's authorized_keys,
# which 96 restores; refused otherwise (a wiped, locked node without the key needs a person at the console)
lk=$(cut -d' ' -f2 "$LABKEY.pub" 2>/dev/null)
[ -n "$lk" ] && [ "$(qr "mkdir -p -m 0700 /tmp/run/batman-dv; m=\$(mktemp -d /tmp/run/batman-dv/p5k.XXXXXX) && mount -o ro,noload /dev/mmcblk0p5 \$m && { grep -qF '$lk' \$m/identity/dropbear/authorized_keys && echo KEYIN; umount \$m; }; rmdir \$m")" = KEYIN ] \
	|| { pr_abort "precondition: the lab key is not in p5 identity/dropbear/authorized_keys — a wipe would lock it out"; pr_result; exit 1; }
ok "precondition: the lab key is in p5's authorized_keys (restored after the wipe)"
s=$(qr "$ST"); b0=$(field "$s" boot)
q "firstboot -y >/dev/null 2>&1; (batman-slot reboot committed prov-dv-254 </dev/null >/dev/null 2>&1 &)"
pr_find 900 "$b0" || { pr_abort "reboot after the wipe"; pr_result; exit 1; }
[ "$(qr '[ -e /etc/.dv-prov-mark-'"$RUN"' ] && echo kept || echo gone')" = gone ] && ok "the upper was wiped (the snapshot's overlay marker is gone)" || no "the upper was not wiped (marker still there)"
pr_pc_place || { pr_abort "place after the wipe"; pr_result; exit 1; }
i1=$(pr_info); id1=$(qr "$ID"); say "after the wipe: $i1 $id1"
case " $i1 " in *" state=claimed "*) ok "state claimed after the wipe";; *) no "state after the wipe: $i1";; esac
[ "$id1" = "$id0" ] && ok "same device: node cert and prov.meta unchanged ($id1)" || no "identity / record changed: [$id0] -> [$id1]"
pr_restore || { pr_abort "restore"; pr_result; exit 1; }
if ! qr '/usr/bin/batman-provhelper --version >/dev/null 2>&1'; then
	no "pre-P1b image: $(field "$(qr "$ST")" ver) — the 96-norestore negative control needs a P1b rc"
else
	pr_keys && pr_pc_place && pr_claim || { pr_abort "claim (negative)"; pr_result; exit 1; }
	id0=$(qr "$ID")
	pr_ota_b "$PR_V.dirty.wbox-96-norestore" B || { pr_abort "OTA 96-norestore"; pr_result; exit 1; }
	id1=$(qr "$ID"); say "96-norestore trial: $id1"
	[ "$id1" != "$id0" ] && ok "negative control: 96-norestore -> not the same provisioned device ($id1)" || no "negative control: identical after 96-norestore — the mutant had no effect"
	back_to_a || { pr_abort "back to A"; pr_result; exit 1; }
fi
pr_end
pr_result
