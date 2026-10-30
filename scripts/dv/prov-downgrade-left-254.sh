#!/bin/bash
# scripts/dv/prov-downgrade-left-254.sh — #254 tier-B unit prov-downgrade-left-254 (docs/design/254-wireless-txn.md §2,
# §8 "older image reads a v6 record"): the provisioning record gained `Left` (key 12, written ONLY when true). An image
# with the previous P1 helper (DV_P1_OLD_VERSION, default the fleet's wsl.9) in the other slot (rollback / OTA back):
#   arm 1: claim (no leave: no key 12) -> OTA the old image into B (hold) -> the old helper's verdict is `claimed`
#     (the record reads as today) -> back to A
#   arm 2: join (random test mesh) + network/leave (Left committed to p5) -> OTA the old image into B (hold) -> the old
#     helper's verdict is `unknown(prov-corrupt)` (fail-closed: state-changing verbs refused), lock-status LOCKED, the
#     p5 provisioning files unchanged by the old image -> back to A -> the new helper reads it again: state claimed
#   negative control: arm 1 IS arm 2's (the same old image, the same claimed record, without key 12 -> `claimed`).
# Type: hold / A / F. Side effects: 04 ~60 min (off the fleet mesh after the leave), B rewritten with the old image
# twice then with V, ~8 reboots.
set -u
PR_UNIT=prov-downgrade-left-254
OLD=${DV_P1_OLD_VERSION:-1.5.14-wsl.9+825a239.fw4d19709}
# shellcheck source=scripts/dv/prov-254.sh
. "$(dirname "$0")/prov-254.sh"
P5PROV='mkdir -p -m 0700 /tmp/run/batman-dv; m=$(mktemp -d /tmp/run/batman-dv/p5d.XXXXXX) && mount -o ro,noload /dev/mmcblk0p5 $m && { echo "meta=$(sha256sum < $m/prov.meta 2>/dev/null | cut -c1-12) cbor=$(sha256sum < $m/prov.cbor 2>/dev/null | cut -c1-12)"; umount $m; }; rmdir $m'
VERDICT='cut -d" " -f4 /opt/batdata/state/prov-state 2>/dev/null; cat /opt/batdata/state/lock-status 2>/dev/null'
trial(){	# <arm> <want verdict>
	local p0 p1 v
	p0=$(qr "$P5PROV"); say "arm $1: p5 before: $p0"
	pr_ota_b "$OLD" B || return 1
	v=$(qr "$VERDICT" | tr '\n' ' '); say "arm $1: B trial ($OLD): verdict+lock = $v"
	case " $v " in *" $2 "*) ok "arm $1: the old helper's verdict is $2" ;; *) no "arm $1: verdict [$v] (want $2)" ;; esac
	case " $v " in *" LOCKED "*) ok "arm $1: lock-status LOCKED under the old image" ;; *) no "arm $1: lock [$v] (want LOCKED)" ;; esac
	p1=$(qr "$P5PROV")
	[ "$p1" = "$p0" ] && ok "arm $1: p5 provisioning unchanged under the old image" || no "arm $1: p5 changed under the old image: [$p0] -> [$p1]"
	back_to_a || return 1
	return 0
}
pr_begin 3600 || { pr_result; exit 1; }
pr_keys && pr_pc_place && pr_claim || { pr_abort "claim"; pr_result; exit 1; }
trial 1 claimed || { pr_abort "arm 1"; pr_result; exit 1; }
pr_pc_place || { pr_abort "provclient"; pr_result; exit 1; }
MESH="dvd-$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
FD3="umask 077; s=\$(head -c 16 /dev/urandom | hexdump -v -e '1/1 \"%02x\"'); printf 'mesh_id=%s\nchannel=%s\nbw=2\nsae=%s\n' '$MESH' \"\$(uci -q get wireless.radio1.channel)\" \"\$s\""
r=$(pr_pc owner.pem FD3="$FD3" -- net-apply --first "$OWNER"); grep -q "RESULT net.apply code=0 " <<< "$r" || { no "join: $r"; pr_abort "join"; pr_result; exit 1; }
r=$(pr_pc owner.pem PROVCLIENT_TIMEOUT_S=120 -- leave)
if grep -q "RESULT network.leave code=21" <<< "$r"; then	# committed, forget unverified: retry as the app does
	say "leave: committed, the forget was not verified (code 21) — retrying as the app does"
	r=$(pr_pc owner.pem PROVCLIENT_TIMEOUT_S=120 -- leave); grep -qE "RESULT network.leave code=3( |$)" <<< "$r" && r="RESULT network.leave code=0 (retry: not a member any more)"
fi
grep -q "RESULT network.leave code=0" <<< "$r" || { no "leave: $r"; pr_abort "leave"; pr_result; exit 1; }
ok "joined $MESH and left (Left committed)"
trial 2 'unknown(prov-corrupt)' || { pr_abort "arm 2"; pr_result; exit 1; }
pr_pc_place || { pr_abort "provclient"; pr_result; exit 1; }
i=$(pr_info); case " $i " in *" state=claimed "*) ok "back on A: the new helper reads the Left record ($i)" ;; *) no "back on A: $i (want state=claimed)" ;; esac
pr_end
pr_result
