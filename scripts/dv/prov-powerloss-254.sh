#!/bin/bash
# scripts/dv/prov-powerloss-254.sh <1..5> [neg-b|neg] — #254 tier-B units prov-powerloss-254-txn{1..5} (L7;
# docs/design/254-h23-harness.md §6.2, §16.1; product rule docs/design/254-wireless-txn.md §3, §8): power lost at each
# point of a network/update transaction; at the next start the helper FINISHES the change (the previous state of the
# record p5 confirmed) before it serves, saves under the transaction's token and drops .txn. One snapshot / restore
# unit per point.
#   member (random test mesh) -> test helper bound with killpoint txn-N -> net-apply --update (new mesh id) -> sysrq ->
#   reboot (release helper) -> §16.1 (a)-(d)(f) -> (e) the state of that point:
#     txn-1  .txn written, nothing else: Finish -> the committed (old) network; mesh id old
#     txn-2  wireless changed (not persisted), p5 not: Finish -> the old network; p5 gen not advanced
#     txn-3  p5 committed, overlay not: --boot "p5 newer: rebuilt the overlay record", Finish -> the new network
#     txn-4  committed, save not done: Finish saves; p5 gen n+1; mesh id new
#     txn-5  everything done (.txn already gone): no Finish; mesh id new
#   and at every point: .txn gone, uci AND live (wpa_supplicant) mesh id as expected, --check rc 0, and a later plain
#   `batman-config-save --save` rc 0 — the shipped deadlock (wsl.9: .txn kept -> every --save refused, #254 M6) is the
#   negative control of the whole unit (reproduced twice on 04 wsl.9, scratchpad txnstuck.sh, #254 comment 6469943996).
#   negative controls on the release image: txn-2 neg-b — helper-notxn in the upper (the .txn is dropped at boot, never
#     finished) -> its witness line, no "finished" line, no save under the token; txn-3 neg — helper-norebuild in the
#     upper (neither --boot nor Finish rebuilds the overlay from p5) -> no rebuild line, overlay generation != p5's.
#   (The former txn-2 neg-a — .txn moved away within the 120 s restore delay — has no subject any more: the delayed
#   restore is gone, Finish runs before the helper serves.)
# Type: — / A / F. Side effects: 04 ~35 min off the mesh, 3 reboots (one by sysrq), claimed; B untouched.
set -u
N=${1:?usage: prov-powerloss-254.sh <1..5> [neg-b|neg]}; NEG=${2:-}
case "$N$NEG" in [1-5]|2neg-b|3neg) ;; *) echo "FAIL bad point / negative [$N $NEG]"; exit 2 ;; esac
PR_UNIT=prov-powerloss-txn$N${NEG:+-$NEG}-254
# shellcheck source=scripts/dv/prov-254.sh
. "$(dirname "$0")/prov-254.sh"
MESHID='uci -q get wireless.default_radio1.mesh_id'
# the live mesh id: the s1g wpa_supplicant's ssid (meshjoin_radio_up's source; `iw dev info` does not show it)
LIVEID='wpa_cli_s1g -p /var/run/wpa_supplicant_s1g -i wlh0 status 2>/dev/null | sed -n "s/^ssid=//p"'
P5GEN='d=$(mktemp -d /tmp/run/batman-dv/pg.XXXXXX); rmdir $d; batman-config-save --prov-get $d >/dev/null 2>&1; sed -n "s/.*gen=\([0-9]*\).*/\1/p" $d/prov.meta; rm -rf $d'
OVGEN='sed -n "s/.*gen=\([0-9]*\).*/\1/p" /etc/batman-prov/prov.meta'
upper=""
case "$N$NEG" in 2neg-b) upper=helper-notxn ;; 3neg) upper=helper-norebuild ;; esac
pr_begin 3000 ${upper:+upper=$upper} || { pr_result; exit 1; }
pr_member || { pr_abort "member"; pr_result; exit 1; }
old=$(qr "$MESHID"); g0=$(qr "$P5GEN"); say "before: mesh_id=$old p5 gen=$g0"
new="dvu-$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
PR_FD3="umask 077; s=\$(head -c 16 /dev/urandom | hexdump -v -e '1/1 \"%02x\"'); printf 'mesh_id=%s\nchannel=%s\nbw=2\nsae=%s\n' '$new' \"\$(uci -q get wireless.radio1.channel)\" \"\$s\""
pr_killpoint "txn-$N" net-apply --update "$OWNER" "$PR_NETCFG" || { pr_abort "killpoint txn-$N"; pr_result; exit 1; }
# Finish runs before the helper serves; rejoining a network waits for the radio (<= 120 s)
i=0; until [ -n "$(qr "logread | grep 'batman-provhelper' | grep 'serving ('")" ] || [ $i -ge 60 ]; do sleep 5; i=$((i + 1)); done
[ $i -ge 60 ] && no "the helper did not reach 'serving' within 300 s"
sleep 20	# the radio settles after a Finish setkey
m=$(qr "$MESHID"); lm=$(qr "$LIVEID"); g1=$(qr "$P5GEN"); og=$(qr "$OVGEN")
l=$(qr "logread | grep 'batman-provhelper' | grep -E 'boot rc=|finished|unfinished|finish|WBOX-' | tail -6")
say "after: mesh_id=$m live=$lm p5 gen=$g1 overlay gen=$og"; echo "$l" | sed 's/^/    /'
txn=$(qr '[ -e /etc/batman-prov/.txn ] && echo present || echo gone')
fin=$(grep -E 'txn [^ ]+ finished \(boot\): wireless = .*, setkey rc=0 save rc=(0|6)$' <<< "$l" | tail -1)
common(){	# $1 = the expected mesh id
	[ "$txn" = gone ] && ok "txn-$N: .txn gone" || no "txn-$N: .txn $txn"
	[ "$m" = "$1" ] && ok "txn-$N: uci mesh id $m" || no "txn-$N: uci mesh id $m (want $1)"
	[ "$lm" = "$1" ] && ok "txn-$N: live mesh id $lm" || no "txn-$N: live mesh id [$lm] (want $1)"
	c=$(qr 'batman-config-save --check >/dev/null 2>&1; echo rc=$?'); [ "$c" = rc=0 ] && ok "txn-$N: --check rc 0 (p5 == live)" || no "txn-$N: --check $c"
	s=$(qr 'batman-config-save --save >/dev/null 2>&1; echo rc=$?'); [ "$s" = rc=0 ] && ok "txn-$N: a later --save rc 0 (no deadlock)" || no "txn-$N: a later --save $s"
}
case "$N$NEG" in
1)	[ -n "$fin" ] && grep -q 'the committed network' <<< "$fin" && ok "txn-1: finished to the committed network [$fin]" || no "txn-1: no Finish line to the committed network"
	common "$old" ;;
2)	[ -n "$fin" ] && grep -q 'the committed network' <<< "$fin" && ok "txn-2: finished back to the committed network [$fin]" || no "txn-2: no Finish line back to the committed network"
	[ "$g1" = "$g0" ] && ok "txn-2: p5 generation not advanced ($g1)" || no "txn-2: p5 gen $g0 -> $g1"
	common "$old" ;;
2neg-b)
	grep -q 'WBOX-helper-notxn-[0-9a-f]*: .txn dropped at boot' <<< "$l" && ok "neg-b: the mutant dropped the .txn (witness line)" || no "neg-b: no witness line — the mutant did not run"
	! grep -q 'finished (boot)' <<< "$l" && ok "negative control (neg-b): no Finish without the product's boot path" || no "negative control (neg-b): finished anyway — the control had no effect" ;;
3)	grep -q 'action=p5 newer: rebuilt the overlay record' <<< "$l" && ok "txn-3: --boot rebuilt the overlay from p5" || no "txn-3: no 'p5 newer: rebuilt the overlay record'"
	[ -n "$fin" ] && grep -q 'the committed network' <<< "$fin" && ok "txn-3: finished to the committed (new) network" || no "txn-3: no Finish line"
	[ "$og" = "$g1" ] && ok "txn-3: overlay gen == p5 gen ($og)" || no "txn-3: overlay gen $og, p5 gen $g1"
	common "$new" ;;
3neg)	grep -q 'WBOX-helper-norebuild-[0-9a-f]*' <<< "$l" && ok "neg: the mutant ran (witness line)" || no "neg: no witness line — the mutant did not run"
	! grep -q 'rebuilt the overlay record' <<< "$l" && [ "$og" != "$g1" ] && ok "negative control: no rebuild, overlay gen $og != p5 gen $g1" || no "negative control: rebuilt anyway (overlay $og, p5 $g1) — the mutant had no effect" ;;
4)	[ -n "$fin" ] && ok "txn-4: finished (saved) [$fin]" || no "txn-4: no Finish line"
	[ "$g1" = $((g0 + 1)) ] && ok "txn-4: p5 gen n+1 ($g1)" || no "txn-4: p5 gen $g0 -> $g1 (want $((g0 + 1)))"
	common "$new" ;;
5)	! grep -q 'finished (boot)' <<< "$l" && ok "txn-5: nothing to finish" || no "txn-5: a Finish ran although the transaction was complete"
	common "$new" ;;
esac
pk_proof && ok "the lab key still logs in (publickey)" || no "the lab key does not log in after the killpoint"
pr_end
pr_result
