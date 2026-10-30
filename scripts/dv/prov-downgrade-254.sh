#!/bin/bash
# scripts/dv/prov-downgrade-254.sh — #254 tier-B unit prov-downgrade-254 (L12, a CHARACTERIZATION; docs/design/
# 254-h23-harness.md §6.2): a CLAIMED node OTA'd back to a pre-P1 image (1.5.12-wsl.9, F32: its 96 locks only when a key
# AND a password are on p5) keeps its door shut, and the old image does not destroy the provisioning on p5.
#   claim -> OTA DV_OLD_VERSION into B (hold) -> in the B trial: lock-status LOCKED, ttylogin=1, p5 still has prov.meta
#   and identity/prov (read-only mount) -> back to A (the claimed overlay of A is restored at the end)
# Type: hold / A / F. Side effects: 04 ~40 min, B rewritten with the old image then with V, ~5 reboots.
set -u
PR_UNIT=prov-downgrade-254
OLD=${DV_OLD_VERSION:-1.5.12-wsl.9+f2f2bf6.fw07f2063}
# shellcheck source=scripts/dv/prov-254.sh
. "$(dirname "$0")/prov-254.sh"
P5PROV='mkdir -p -m 0700 /tmp/run/batman-dv; m=$(mktemp -d /tmp/run/batman-dv/p5d.XXXXXX) && mount -o ro,noload /dev/mmcblk0p5 $m && { echo "meta=$([ -f $m/prov.meta ] && echo y || echo n) ident=$(ls $m/identity/prov 2>/dev/null | wc -l) seeded=$([ -f $m/.seeded ] && echo y || echo n)"; umount $m; }; rmdir $m'
pr_begin 3000 || { pr_result; exit 1; }
pr_keys && pr_pc_place && pr_claim || { pr_abort "claim"; pr_result; exit 1; }
p0=$(qr "$P5PROV"); say "p5 before: $p0"
pr_ota_b "$OLD" B || { pr_abort "OTA $OLD"; pr_result; exit 1; }
s=$(qr 'echo "lock=$(cat /opt/batdata/state/lock-status 2>/dev/null) tty=$(uci -q get system.@system[0].ttylogin) pw=$(uci -q get dropbear.@dropbear[0].PasswordAuth)"'); say "B trial ($OLD): $s"
case " $s " in *" lock=LOCKED "*) ok "old image keeps the claimed node LOCKED";; *) no "old image: $s (want lock=LOCKED)";; esac
case " $s " in *" tty=1 "*) ok "old image: ttylogin=1";; *) no "old image ttylogin: $s";; esac
p1=$(qr "$P5PROV"); say "p5 in the old trial: $p1"
[ "$p1" = "$p0" ] && ok "p5 provisioning files intact under the old image ($p1)" || no "p5 changed under the old image: [$p0] -> [$p1]"
back_to_a || { pr_abort "back to A"; pr_result; exit 1; }
pr_end
pr_result
