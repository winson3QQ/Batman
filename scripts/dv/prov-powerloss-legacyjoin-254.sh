#!/bin/bash
# scripts/dv/prov-powerloss-legacyjoin-254.sh [neg] — #254 tier-B unit prov-powerloss-legacyjoin-254
# (docs/design/254-wireless-txn.md §2, §8 "power loss mid join, legacy / operator key"): a node whose mesh settings
# the operator set (04's S0: legacy, the fleet mesh) is claimed, its first network/join dies at txn-2; at the next
# start the helper puts the OPERATOR's settings back (the pre-change snapshot in .txn), saves, drops .txn.
#   S0 -> claim -> the helper's init disabled (an overlay change the S0 restore undoes) + sync -> test helper with
#   killpoint txn-2 -> net-apply --first (random test mesh) -> sysrq -> reboot, the helper does not start ->
#   precondition: .txn present -> FAULT INJECTED (white-box, stated): the half-applied wireless written into uci
#   (a random key + the new mesh id) — the sysrq loses setkey's unsynced uci write (M6, 04 wsl.9), so without it the
#   live state would already be the operator's and Finish would have nothing to undo -> the release helper started ->
#   Finish -> judged:
#     "txn network/join finished (boot): wireless = the pre-change snapshot, applied, save rc=0"; the mesh key
#     (compared as a sha256 prefix, never printed), uci AND live mesh id == the operator's; .txn gone; --check rc 0;
#     a later --save rc 0 (the shipped image kept .txn and refused every save: #254 M6); 02 a neighbour again
#   negative control [neg]: helper-alwaysforget bound instead of the release helper (a failed join always forgets,
#     review B r5 m5) -> its witness line, the key is the placeholder, NOT the operator's.
# Type: — / A / F. Side effects: 04 off the fleet mesh ~25 min (02 unreachable through 04 meanwhile), 3 reboots (one by
# sysrq), claimed, the helper's init disabled until the S0 restore; B untouched.
set -u
NEG=${1:-}
case "$NEG" in ''|neg) ;; *) echo "FAIL bad argument [$NEG]"; exit 2 ;; esac
PR_UNIT=prov-powerloss-legacyjoin${NEG:+-$NEG}-254
# shellcheck source=scripts/dv/prov-254.sh
. "$(dirname "$0")/prov-254.sh"
MESHID='uci -q get wireless.default_radio1.mesh_id'
LIVEID='wpa_cli_s1g -p /var/run/wpa_supplicant_s1g -i wlh0 status 2>/dev/null | sed -n "s/^ssid=//p"'
pr_begin 3000 || { pr_result; exit 1; }
s=$(pr_info); say "S0: $s"
pr_keys && pr_pc_place && pr_claim || { pr_abort "claim"; pr_result; exit 1; }
k0=$(qr "$KEYH"); m0=$(qr "$MESHID")
[ -n "$k0" ] && [ "$k0" != "$PH" ] && [ -n "$m0" ] || { inv "S0 has no operator mesh key / id (key=$k0 id=$m0) — this unit needs 04's legacy S0"; pr_end; pr_result; exit 2; }
say "operator settings: mesh_id=$m0 key sha=$k0"
nb02 || say "note: 02 is not a neighbour at S0 (the 02 judgement below then proves nothing)"
q '/etc/init.d/batman-provhelper disable; sync'
new="dvj-$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
PR_FD3="umask 077; s=\$(head -c 16 /dev/urandom | hexdump -v -e '1/1 \"%02x\"'); printf 'mesh_id=%s\nchannel=%s\nbw=2\nsae=%s\n' '$new' \"\$(uci -q get wireless.radio1.channel)\" \"\$s\""
pr_killpoint txn-2 net-apply --first "$OWNER" || { pr_abort "killpoint txn-2"; pr_result; exit 1; }
o=$(qr '[ -e /etc/batman-prov/.txn ] && echo TXN; pidof batman-provhelper >/dev/null && echo RUNNING; true')
if [ "$(echo $o)" != TXN ]; then inv "precondition: .txn present and the helper not running — got [$(echo $o)]"; q '/etc/init.d/batman-provhelper enable'; pr_end; pr_result; exit 2; fi
say "after the power loss: mesh_id=$(qr "$MESHID") key sha=$(qr "$KEYH") (sysrq kept setkey's write: $([ "$(qr "$MESHID")" = "$new" ] && echo yes || echo no))"
q "uci set wireless.default_radio1.key='dvh-$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')'; uci set wireless.default_radio1.mesh_id='$new'; uci commit wireless; sync"
ok "fault injected: the half-applied wireless (random key, mesh id $new) in uci"
q '/etc/init.d/batman-provhelper enable'
if [ "$NEG" = neg ]; then pr_push_helper helper-alwaysforget || { pr_abort "mutant"; pr_result; exit 1; }
else q '/etc/init.d/batman-provhelper start'; fi
# the Finish runs at the helper's start holding its mutex (design §15.2): wait for its line (<= 420 s)
i=0; until [ -n "$(qr "logread | grep 'batman-provhelper' | grep -E 'finished \\(boot\\)|boot finish:'")" ] || [ $i -ge 84 ]; do sleep 5; i=$((i + 1)); done
[ $i -ge 84 ] && no "no boot Finish line within 420 s"
i=0; until [ "$(qr "$LIVEID")" = "$m0" ] || [ $i -ge 24 ]; do sleep 5; i=$((i + 1)); done   # the radio rejoins
k=$(qr "$KEYH"); m=$(qr "$MESHID"); lm=$(qr "$LIVEID")
l=$(qr "logread | grep 'batman-provhelper' | grep -E 'finished|finish|WBOX-' | tail -4")
say "after Finish: mesh_id=$m live=$lm key sha=$k"; echo "$l" | sed 's/^/    /'
txn=$(qr '[ -e /etc/batman-prov/.txn ] && echo present || echo gone')
if [ "$NEG" = neg ]; then
	grep -q 'WBOX-helper-alwaysforget-[0-9a-f]*: snapshot ignored' <<< "$l" && ok "neg: the mutant ran (witness line)" || no "neg: no witness line — the mutant did not run"
	[ "$k" = "$PH" ] && [ "$k" != "$k0" ] && ok "negative control: the key is the placeholder, not the operator's — the positive judgement fails on it" || no "negative control: key sha $k (placeholder $PH, operator $k0) — the mutant had no effect"
else
	grep -qE 'txn network/join finished \(boot\): wireless = the pre-change snapshot, applied, save rc=(0|6)$' <<< "$l" && ok "finished back to the operator's settings (the pre-change snapshot)" || no "no Finish line back to the pre-change snapshot"
	[ "$k" = "$k0" ] && ok "mesh key == the operator's (sha $k)" || no "mesh key sha $k (want the operator's $k0)"
	[ "$m" = "$m0" ] && ok "uci mesh id == the operator's ($m)" || no "uci mesh id $m (want $m0)"
	[ "$lm" = "$m0" ] && ok "live mesh id == the operator's ($lm)" || no "live mesh id [$lm] (want $m0)"
	[ "$txn" = gone ] && ok ".txn gone" || no ".txn $txn"
	c=$(qr 'batman-config-save --check >/dev/null 2>&1; echo rc=$?'); [ "$c" = rc=0 ] && ok "--check rc 0 (p5 == live)" || no "--check $c"
	s=$(qr 'batman-config-save --save >/dev/null 2>&1; echo rc=$?'); [ "$s" = rc=0 ] && ok "a later --save rc 0 (no deadlock)" || no "a later --save $s"
	i=0; until nb02 || [ $i -ge 18 ]; do sleep 10; i=$((i + 1)); done
	nb02 && ok "02 is a neighbour again (the fleet mesh is back)" || no "02 is not a neighbour within 180 s"
fi
pk_proof && ok "the lab key still logs in (publickey)" || no "the lab key does not log in"
pr_end
pr_result
