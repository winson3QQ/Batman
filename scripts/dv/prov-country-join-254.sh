#!/bin/bash
# scripts/dv/prov-country-join-254.sh — #254 H4 appendix A.4, the row on the R vehicle (p3-how "h"):
#   CJ2  network/update whose net_config key 5 (country) differs from the STORED net_config's key 5 -> E_REJECTED{14}
#        (helper 21 reason=14; 254-p3 D9: only a country change is refused), nothing written: `.txn` absent, the uci
#        wireless sha and the mesh id unchanged
#   (P)  the same update with the stored country -> code 0, the new mesh id applied (what was refused is the country,
#        not the update)
# CJ1 / CJ3 (join with a mismatch / key 2 then join) need a fresh card (F vehicle): with that flow.
# The member is pr_member's test mesh (its net_config says "TW", provclient's default); the update's country comes in
# on fd 3 (country=, provclient net.go).
# W (pre-P3 image): P2 does not look at key 5 (254-p3 F29) -> the AU update applies -> FAIL CJ2 (and P then runs on the
# version the AU update left).
# Type: R. Side effects: claimed + member of a random test mesh in between, 1 reboot (pr_member) + the restore.
set -u
PR_UNIT=prov-country-join-254
# shellcheck source=scripts/dv/prov-254.sh
. "$(dirname "$0")/prov-254.sh"
MESHID='uci -q get wireless.default_radio1.mesh_id'
WSHA='uci export wireless 2>/dev/null | sha256sum | cut -c1-16; [ -e /etc/batman-prov/.txn ] && echo txn=present || echo txn=gone'
code(){ sed -n 's/.* code=\([0-9]*\).*/\1/p' <<< "$1" | head -1; }
reason(){ sed -n 's/.* reason=\([0-9]*\).*/\1/p' <<< "$1" | head -1; }
fd3(){	# <mesh id> <country>: the network values for net-apply --update (the key drawn on the node)
	echo "umask 077; s=\$(head -c 16 /dev/urandom | hexdump -v -e '1/1 \"%02x\"'); printf 'mesh_id=%s\nchannel=%s\nbw=2\nsae=%s\ncountry=%s\n' '$1' \"\$(uci -q get wireless.radio1.channel)\" \"\$s\" '$2'"
}
pr_begin 2400 || { pr_result; exit 1; }
pr_member || { pr_abort "member"; pr_result; exit 1; }
PREV=$PR_NETCFG
CC=$(sed -n 's/.*0562\(....\)06.*/\1/p' <<< "$PREV"); say "stored net_config key 5: $(printf '%s' "$CC" | xxd -r -p 2>/dev/null) (radio1.country $(qr 'uci -q get wireless.radio1.country'))"
# ---- CJ2 a country change on update
m0=$(qr "$MESHID"); w0=$(qr "$WSHA")
NEW="dvc-$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
r=$(pr_pc owner.pem FD3="$(fd3 "$NEW" AU)" -- net-apply --update "$OWNER" "$PREV"); say "CJ2: $(grep '^RESULT' <<< "$r")"
m1=$(qr "$MESHID"); w1=$(qr "$WSHA")
if [ "$(code "$r")" = 21 ] && [ "$(reason "$r")" = 14 ]; then ok "CJ2: update with country AU (stored TW) -> E_REJECTED{14}"
else no "CJ2: update with a country mismatch: code $(code "$r") reason $(reason "$r") (want 21 / 14)$([ "$(code "$r")" = 0 ] && echo ' — applied: joined with country mismatch')"
	[ "$(code "$r")" = 0 ] && PREV=$(sed -n 's/^NETCFG //p' <<< "$r")   # P below chains on what was applied
fi
[ "$m1" = "$m0" ] && ok "CJ2: mesh id unchanged ($m1)" || no "CJ2: mesh id $m0 -> $m1"
[ "$(echo $w1)" = "$(echo $w0)" ] && ok "CJ2: uci wireless sha unchanged, $(echo $w1 | cut -d' ' -f2)" || no "CJ2: wireless / .txn [$(echo $w0)] -> [$(echo $w1)]"
# ---- (P) the same update with the stored country
NEW2="dvc-$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
r=$(pr_pc owner.pem FD3="$(fd3 "$NEW2" TW)" -- net-apply --update "$OWNER" "$PREV"); say "P: $(grep '^RESULT' <<< "$r")"
m2=$(qr "$MESHID")
[ "$(code "$r")" = 0 ] && [ "$m2" = "$NEW2" ] && ok "(P) update with the stored country -> applied ($m2)" || no "(P) update with the stored country: code $(code "$r") reason $(reason "$r") mesh id $m2 (want 0 / $NEW2)"
pr_end
pr_result
