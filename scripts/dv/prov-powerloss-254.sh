#!/bin/bash
# scripts/dv/prov-powerloss-254.sh <1..5> [neg-a|neg-b|neg] — #254 tier-B units prov-powerloss-254-txn{1..5} (L7;
# docs/design/254-h23-harness.md §6.2, §16.1): power lost at each point of a network/update transaction, then the
# release helper's boot logic must leave a consistent node. One snapshot / restore unit per point.
#   member (random test mesh) -> test helper bound with killpoint txn-N -> net-apply --update (new mesh id) -> sysrq ->
#   reboot (release helper) -> §16.1 (a)-(d)(f) -> (e) the state of that point:
#     txn-1  >= 120 s after boot: .txn gone, wireless unchanged (old mesh id)
#     txn-2  >= 120 s: "txn … not committed: restored" + "action=txn … NOT committed"; wireless back to old; p5 gen not
#            advanced
#     txn-3  "action=txn … committed (gen n): overlay completed from p5"; wireless == the update (new mesh id)
#     txn-4  --check rc 5 "p5 stale:" (the overrides lag until the next join: product gap F39, #254); p5 prov.meta gen
#            n+1; wireless == the update
#     txn-5  --check rc 0; wireless == the update
#   negative controls: txn-2 neg-a — within 120 s of boot `.txn` moved away + helper restart -> no restore line, wireless
#     stays new; txn-2 neg-b — helper-notxn in the upper -> no restore; txn-3 neg — helper-norebuild in the upper ->
#     no "overlay completed from p5". txn-1 / 4 / 5 have no negative control (stated).
# Type: — / A / F. Side effects: 04 ~35 min off the mesh, 3 reboots (one by sysrq), claimed; B untouched.
set -u
N=${1:?usage: prov-powerloss-254.sh <1..5> [neg-a|neg-b|neg]}; NEG=${2:-}
case "$N$NEG" in [1-5]|2neg-a|2neg-b|3neg) ;; *) echo "FAIL bad point / negative [$N $NEG]"; exit 2 ;; esac
PR_UNIT=prov-powerloss-txn$N${NEG:+-$NEG}-254
# shellcheck source=scripts/dv/prov-254.sh
. "$(dirname "$0")/prov-254.sh"
MESHID='uci -q get wireless.default_radio1.mesh_id'
P5GEN='d=$(mktemp -d /tmp/run/batman-dv/pg.XXXXXX); rmdir $d; batman-config-save --prov-get $d >/dev/null 2>&1; sed -n "s/.*gen=\([0-9]*\).*/\1/p" $d/prov.meta; rm -rf $d'
upper=""
case "$N$NEG" in 2neg-b) upper=helper-notxn ;; 3neg) upper=helper-norebuild ;; esac
pr_begin 3000 ${upper:+upper=$upper} || { pr_result; exit 1; }
pr_member || { pr_abort "member"; pr_result; exit 1; }
old=$(qr "$MESHID"); g0=$(qr "$P5GEN"); say "before: mesh_id=$old p5 gen=$g0"
new="dvu-$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
PR_FD3="umask 077; s=\$(head -c 16 /dev/urandom | hexdump -v -e '1/1 \"%02x\"'); printf 'mesh_id=%s\nchannel=%s\nbw=2\nsae=%s\n' '$new' \"\$(uci -q get wireless.radio1.channel)\" \"\$s\""
pr_killpoint "txn-$N" net-apply --update "$OWNER" "$PR_NETCFG" || { pr_abort "killpoint txn-$N"; pr_result; exit 1; }
bt0=$(mono); up=$(qr 'cut -d. -f1 /proc/uptime')
if [ "$NEG" = neg-a ]; then	# within 120 s of the boot: the .txn moved away, the helper restarted (its in-memory Txn dies)
	o=$(qr '[ -e /etc/batman-prov/.txn ] && echo TXN; logread | grep -c "not committed: restored"')
	if [ "$(echo $o)" != "TXN 0" ] || [ "${up:-999}" -ge 120 ]; then inv "neg-a precondition: .txn present AND no restore line yet within 120 s (uptime $up): [$(echo $o)] — run again"; pr_end; pr_result; exit 2; fi
	q 'mv /etc/batman-prov/.txn /etc/batman-prov/.txn.dv; /etc/init.d/batman-provhelper restart >/dev/null 2>&1'
fi
w=$(( 150 - $(qr 'cut -d. -f1 /proc/uptime') )); [ $w -gt 0 ] && { say "waiting ${w}s (the helper's restore runs 120 s after its start)"; sleep $w; }
[ "$NEG" = neg-a ] && { say "neg-a: waiting 150 s after the restart"; sleep 150; }
m=$(qr "$MESHID"); g1=$(qr "$P5GEN"); l=$(qr "logread | grep 'batman-provhelper' | grep -E 'action=txn|not committed: restored|boot rc=' | tail -4")
say "after: mesh_id=$m p5 gen=$g1"; echo "$l" | sed 's/^/    /'
txn=$(qr '[ -e /etc/batman-prov/.txn ] && echo present || echo gone')
case "$N$NEG" in
1)	[ "$txn" = gone ] && ok "txn-1: .txn gone" || no "txn-1: .txn $txn"
	[ "$m" = "$old" ] && ok "txn-1: wireless unchanged ($m)" || no "txn-1: mesh_id $m (want the old $old)" ;;
2)	grep -q 'not committed: restored' <<< "$l" && ok "txn-2: the helper restored the previous wireless" || no "txn-2: no 'not committed: restored' line"
	grep -q 'action=txn .*NOT committed' <<< "$l" && ok "txn-2: action=txn … NOT committed" || no "txn-2: no 'action=txn … NOT committed'"
	[ "$m" = "$old" ] && ok "txn-2: wireless back to the old mesh ($m)" || no "txn-2: mesh_id $m (want the old $old)"
	[ "$g1" = "$g0" ] && ok "txn-2: p5 generation not advanced ($g1)" || no "txn-2: p5 gen $g0 -> $g1" ;;
2neg-a|2neg-b)
	! grep -q 'not committed: restored' <<< "$l" && [ "$m" = "$new" ] && ok "negative control ($NEG): no restore, the half-applied wireless stays ($m)" || no "negative control ($NEG): restored anyway [$m] — the control had no effect"
	[ "$NEG" = neg-a ] && { [ "$(qr '[ -e /etc/batman-prov/.txn.dv ] && echo y')" = y ] && ok "neg-a: .txn.dv still there" || no "neg-a: .txn.dv gone"; } ;;
3)	grep -q 'action=txn .*committed (gen [0-9]*): overlay completed from p5' <<< "$l" && ok "txn-3: overlay completed from p5" || no "txn-3: no 'overlay completed from p5'"
	[ "$m" = "$new" ] && ok "txn-3: wireless == the update ($m)" || no "txn-3: mesh_id $m (want $new)" ;;
3neg)	! grep -q 'overlay completed from p5' <<< "$l" && ok "negative control: helper-norebuild does not complete the overlay" || no "negative control: overlay completed anyway — the mutant had no effect" ;;
4)	c=$(qr 'batman-config-save --check 2>&1; echo rc=$?'); say "--check: $(echo $c)"
	grep -q 'rc=5' <<< "$c" && grep -q 'p5 stale:' <<< "$c" && ok "txn-4: --check rc 5 'p5 stale:' (overrides lag — F39 product gap)" || no "txn-4: --check [$c]"
	[ "$g1" = $((g0 + 1)) ] && ok "txn-4: p5 gen n+1 ($g1)" || no "txn-4: p5 gen $g0 -> $g1 (want $((g0 + 1)))"
	[ "$m" = "$new" ] && ok "txn-4: wireless == the update" || no "txn-4: mesh_id $m (want $new)" ;;
5)	c=$(qr 'batman-config-save --check >/dev/null 2>&1; echo rc=$?'); [ "$c" = rc=0 ] && ok "txn-5: --check rc 0" || no "txn-5: --check $c"
	[ "$m" = "$new" ] && ok "txn-5: wireless == the update" || no "txn-5: mesh_id $m (want $new)" ;;
esac
pk_proof && ok "the lab key still logs in (publickey)" || no "the lab key does not log in after the killpoint"
pr_end
pr_result
