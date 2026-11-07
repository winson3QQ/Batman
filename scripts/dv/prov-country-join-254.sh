#!/bin/bash
# scripts/dv/prov-country-join-254.sh — #254 H4 appendix A.4, the row on the R vehicle (p3-how "h"):
#   CJ2  network/update whose net_config key 5 (country) differs from the STORED net_config's key 5 -> E_REJECTED{14}
#        (helper hERejectR 24 reason=14: 254-p3-impl.md error codes, F38, line ~192; D9: only a country change is
#        refused), nothing written: `.txn` absent, the uci wireless sha, the prov records (prov.cbor / prov.meta) and
#        the mesh id unchanged; every reading non-empty
#   (P)  the same update with the stored country -> code 0, the new mesh id applied (what was refused is the country,
#        not the update)
# CJ1 / CJ3 (join with a mismatch / key 2 then join) need a fresh card (F vehicle): with that flow.
# The member is pr_member's test mesh. The STORED country is read from the signed net_config pr_member's join returned
# (PR_NETCFG, key 5), not guessed: today pr_member sends provclient's default "TW"; on a P3 image the join itself must
# carry radio1.country (D9) — pr_member passing country= is a #254 H5 checklist item (prov-254.sh), and until it
# lands this unit stops at "member" on a P3 image with a non-TW radio (a harness FAIL, said so by pr_member's "join:"
# line). The update's country comes in on fd 3 (country=, provclient net.go).
# W (pre-P3 image): P2 does not look at key 5 (254-p3 F29) -> the mismatching update applies -> FAIL CJ2 (and P then runs on the
# version the AU update left).
# Type: R. Side effects: claimed + member of a random test mesh in between, 1 reboot (pr_member) + the restore.
set -u
PR_UNIT=prov-country-join-254
# shellcheck source=scripts/dv/prov-254.sh
. "$(dirname "$0")/prov-254.sh"
MESHID='uci -q get wireless.default_radio1.mesh_id'
# one line: the uci wireless sha, the prov record shas (nothing may be stored on a refusal), .txn present / gone
WSHA='echo "w=$(uci export wireless 2>/dev/null | sha256sum | cut -c1-16) p=$(cat /etc/batman-prov/prov.cbor /etc/batman-prov/prov.meta 2>/dev/null | sha256sum | cut -c1-16) txn=$([ -e /etc/batman-prov/.txn ] && echo present || echo gone)"'
code(){ sed -n 's/.* code=\([0-9]*\).*/\1/p' <<< "$1" | head -1; }
reason(){ sed -n 's/.* reason=\([0-9]*\).*/\1/p' <<< "$1" | head -1; }
fd3(){	# <mesh id> <country>: the network values for net-apply --update (the key drawn on the node)
	echo "umask 077; s=\$(head -c 16 /dev/urandom | hexdump -v -e '1/1 \"%02x\"'); printf 'mesh_id=%s\nchannel=%s\nbw=2\nsae=%s\ncountry=%s\n' '$1' \"\$(uci -q get wireless.radio1.channel)\" \"\$s\" '$2'"
}
pr_begin 2400 || { pr_result; exit 1; }
pr_member || { pr_abort "member"; pr_result; exit 1; }
PREV=$PR_NETCFG
# the stored country = key 5 of the signed net_config (provclient net.go netObjects: ... 05 62 <2 bytes> 06 a3 ...)
h=$(grep -o '0562[0-9a-f]\{4\}06a3' <<< "$PREV" | head -1); RC=""; [ -n "$h" ] && RC=$(printf "\x${h:4:2}\x${h:6:2}")
case "$RC" in [A-Z][A-Z]) ;; *) inv "the stored net_config's country (key 5) could not be read [$RC]"; pr_end; pr_result; exit 2;; esac
BAD=AU; [ "$RC" = AU ] && BAD=NZ
say "stored net_config country $RC (radio1.country $(qr 'uci -q get wireless.radio1.country')); the mismatch arm says $BAD"
# ---- CJ2 a country change on update
m0=$(qr "$MESHID"); w0=$(qr "$WSHA")
[ -n "$m0" ] && grep -q '^w=[0-9a-f]\{16\} p=[0-9a-f]\{16\} txn=' <<< "$w0" || inv "CJ2: the state before could not be read [mesh $m0] [$w0]"
NEW="dvc-$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
r=$(pr_pc owner.pem FD3="$(fd3 "$NEW" "$BAD")" -- net-apply --update "$OWNER" "$PREV"); say "CJ2: $(grep '^RESULT' <<< "$r")"
m1=$(qr "$MESHID"); w1=$(qr "$WSHA")
if [ "$(code "$r")" = 24 ] && [ "$(reason "$r")" = 14 ]; then ok "CJ2: update with country $BAD (stored $RC) -> E_REJECTED{14}"
else no "CJ2: update with a country mismatch: code $(code "$r") reason $(reason "$r") (want 24 / 14)$([ "$(code "$r")" = 0 ] && echo ' — applied: joined with country mismatch')"
	[ "$(code "$r")" = 0 ] && PREV=$(sed -n 's/^NETCFG //p' <<< "$r")   # P below chains on what was applied
fi
if [ -z "$m1" ] || ! grep -q '^w=[0-9a-f]\{16\} p=[0-9a-f]\{16\} txn=' <<< "$w1"; then inv "CJ2: the state after could not be read [mesh $m1] [$w1]"
else
	[ "$m1" = "$m0" ] && ok "CJ2: mesh id unchanged ($m1)" || no "CJ2: mesh id $m0 -> $m1"
	[ "${w1% txn=*}" = "${w0% txn=*}" ] && ok "CJ2: uci wireless and the prov records unchanged ($w1)" || no "CJ2: wireless / prov records [$w0] -> [$w1]"
	case "$w1" in *txn=gone) ok "CJ2: no .txn left";; *) no "CJ2: .txn present after the refused update";; esac
fi
# ---- (P) the same update with the stored country
NEW2="dvc-$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
r=$(pr_pc owner.pem FD3="$(fd3 "$NEW2" "$RC")" -- net-apply --update "$OWNER" "$PREV"); say "P: $(grep '^RESULT' <<< "$r")"
m2=$(qr "$MESHID")
if [ -z "$m2" ]; then inv "(P) the mesh id could not be read after the update"
elif [ "$(code "$r")" = 0 ] && [ "$m2" = "$NEW2" ]; then ok "(P) update with the stored country -> applied ($m2)"
else no "(P) update with the stored country: code $(code "$r") reason $(reason "$r") mesh id $m2 (want 0 / $NEW2)"; fi
pr_end
pr_result
