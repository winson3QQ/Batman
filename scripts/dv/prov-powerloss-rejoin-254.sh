#!/bin/bash
# scripts/dv/prov-powerloss-rejoin-254.sh [neg] — #254 tier-B unit prov-powerloss-rejoin-254 (docs/design/254-wireless-txn.md
# §5, §8 "power loss mid join, fresh / left node"): a node that LEFT its network (L22: the mesh forgotten — placeholder
# key, radio blocked) dies at txn-2 of its next network/join; at the next start the helper forgets again (the record
# says Left), saves, drops .txn. Also the first run of `halow-setkey --forget-mesh` on real hardware (network/leave).
#   S0 -> claim + join (random test mesh) -> network/leave -> judged: placeholder key, radio1 disabled=1 and in the
#   keyguard mark, no wlh0, prov-state mesh_expect 0, --check rc 0 -> the helper's init disabled (undone by the S0
#   restore) + sync -> test helper with killpoint txn-2 -> net-apply --first (another random mesh) -> sysrq -> reboot,
#   the helper does not start -> precondition: .txn present -> FAULT INJECTED (white-box, stated): the half-applied
#   wireless written into uci as setkey leaves it (a random key, the new mesh id, the radio unblocked: `disabled`
#   deleted, radio1 out of the mark) — the sysrq loses setkey's unsynced uci write (M6) -> the release helper started ->
#   Finish -> judged: "txn network/join finished (boot): wireless = left (forgotten), applied, save rc=0";
#   placeholder key, radio1 disabled=1 and in the mark, no wlh0; .txn gone; --check rc 0; a later --save rc 0;
#   mesh_expect 0
#   negative control [neg]: helper-noforget bound instead of the release helper (forgetting does nothing, reports
#     success) -> its witness line, the injected key stays (NOT the placeholder).
# Type: — / A / F. Side effects: 04 off the fleet mesh ~35 min (02 unreachable through 04 meanwhile), 4 reboots (one
# by sysrq), claimed, the helper's init disabled until the S0 restore; B untouched.
set -u
NEG=${1:-}
case "$NEG" in ''|neg) ;; *) echo "FAIL bad argument [$NEG]"; exit 2 ;; esac
PR_UNIT=prov-powerloss-rejoin${NEG:+-$NEG}-254
# shellcheck source=scripts/dv/prov-254.sh
. "$(dirname "$0")/prov-254.sh"
KEYH='uci -q get wireless.default_radio1.key | sha256sum | cut -c1-16'
PH=$(printf 'CHANGE-ME-NOW\n' | sha256sum | cut -c1-16)
FORGOT='echo "dis=$(uci -q get wireless.radio1.disabled) mark=$(grep -qw radio1 /etc/halow-keyguard.blocked 2>/dev/null && echo 1 || echo 0) wlh0=$(iw dev wlh0 info >/dev/null 2>&1 && echo 1 || echo 0) me=$(cut -d" " -f6 /opt/batdata/state/prov-state 2>/dev/null)"'
forgotten(){	# <what>: placeholder key, radio blocked by the keyguard, no mesh netdev, mesh_expect 0
	local k f
	k=$(qr "$KEYH"); f=$(qr "$FORGOT"); say "$1: key sha=$k $f"
	[ "$k" = "$PH" ] && ok "$1: the mesh key is the placeholder" || no "$1: key sha $k (placeholder $PH)"
	[ "$f" = "dis=1 mark=1 wlh0=0 me=0" ] && ok "$1: radio1 blocked (disabled=1, in the keyguard mark), no wlh0, mesh_expect 0" || no "$1: [$f] (want dis=1 mark=1 wlh0=0 me=0)"
}
pr_begin 3000 || { pr_result; exit 1; }
pr_member || { pr_abort "member"; pr_result; exit 1; }
r=$(pr_pc owner.pem -- leave); echo "    $r"
grep -q "RESULT network.leave code=0" <<< "$r" || { no "leave: $r"; pr_abort "leave"; pr_result; exit 1; }
i=$(pr_info); case " $i " in *" state=claimed "*) ok "left: $i" ;; *) no "state after leave: $i" ;; esac
forgotten "after network/leave"
c=$(qr 'batman-config-save --check >/dev/null 2>&1; echo rc=$?'); [ "$c" = rc=0 ] && ok "after leave: --check rc 0 (p5 holds the placeholder)" || no "after leave: --check $c"
q '/etc/init.d/batman-provhelper disable; sync'
new="dvr-$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
PR_FD3="umask 077; s=\$(head -c 16 /dev/urandom | hexdump -v -e '1/1 \"%02x\"'); printf 'mesh_id=%s\nchannel=%s\nbw=2\nsae=%s\n' '$new' \"\$(uci -q get wireless.radio1.channel)\" \"\$s\""
pr_killpoint txn-2 net-apply --first "$OWNER" || { pr_abort "killpoint txn-2"; pr_result; exit 1; }
o=$(qr '[ -e /etc/batman-prov/.txn ] && echo TXN; pidof batman-provhelper >/dev/null && echo RUNNING; true')
if [ "$(echo $o)" != TXN ]; then inv "precondition: .txn present and the helper not running — got [$(echo $o)]"; q '/etc/init.d/batman-provhelper enable'; pr_end; pr_result; exit 2; fi
say "after the power loss: key sha=$(qr "$KEYH") $(qr "$FORGOT")"
q "uci set wireless.default_radio1.key='dvh-$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')'; uci set wireless.default_radio1.mesh_id='$new'; uci -q delete wireless.radio1.disabled; uci commit wireless; m=/etc/halow-keyguard.blocked; [ -f \$m ] && { n=\$(tr ' ' '\n' < \$m | grep -vx radio1 | tr '\n' ' '); echo \"\$n\" > \$m.tmp && mv -f \$m.tmp \$m; }; sync"
ki=$(qr "$KEYH"); fi_=$(qr "$FORGOT")
case "$ki $fi_" in "$PH "*|*" mark=1 "*) inv "fault injection did not take: key sha=$ki $fi_"; q '/etc/init.d/batman-provhelper enable'; pr_end; pr_result; exit 2 ;; esac
ok "fault injected: the half-applied wireless (random key sha $ki, mesh id $new, radio unblocked: $fi_)"
q '/etc/init.d/batman-provhelper enable'
if [ "$NEG" = neg ]; then pr_push_helper helper-noforget || { pr_abort "mutant"; pr_result; exit 1; }
else q '/etc/init.d/batman-provhelper start'; fi
# the Finish runs at the helper's start holding its mutex (design §15.2): wait for its line (<= 420 s)
i=0; until [ -n "$(qr "logread | grep 'batman-provhelper' | grep -E 'finished \\(boot\\)|boot finish:'")" ] || [ $i -ge 84 ]; do sleep 5; i=$((i + 1)); done
[ $i -ge 84 ] && no "no boot Finish line within 420 s"
sleep 10
l=$(qr "logread | grep -E 'batman-provhelper|halow-setkey' | grep -E 'finished|finish|forget|WBOX-' | tail -5")
echo "$l" | sed 's/^/    /'
if [ "$NEG" = neg ]; then
	grep -q 'WBOX-helper-noforget-[0-9a-f]*: forget-mesh skipped' <<< "$l" && ok "neg: the mutant ran (witness line)" || no "neg: no witness line — the mutant did not run"
	k=$(qr "$KEYH")
	[ "$k" = "$ki" ] && [ "$k" != "$PH" ] && ok "negative control: the injected key stays (sha $k), not the placeholder — the positive judgement fails on it" || no "negative control: key sha $k (injected $ki, placeholder $PH) — the mutant had no effect"
else
	grep -qE 'txn network/join finished \(boot\): wireless = left \(forgotten\), applied, save rc=(0|6)$' <<< "$l" && ok "finished: forgotten again (the record says Left)" || no "no Finish line 'left (forgotten)'"
	forgotten "after Finish"
	txn=$(qr '[ -e /etc/batman-prov/.txn ] && echo present || echo gone'); [ "$txn" = gone ] && ok ".txn gone" || no ".txn $txn"
	c=$(qr 'batman-config-save --check >/dev/null 2>&1; echo rc=$?'); [ "$c" = rc=0 ] && ok "--check rc 0 (p5 == live)" || no "--check $c"
	s=$(qr 'batman-config-save --save >/dev/null 2>&1; echo rc=$?'); [ "$s" = rc=0 ] && ok "a later --save rc 0 (no deadlock)" || no "a later --save $s"
fi
pk_proof && ok "the lab key still logs in (publickey)" || no "the lab key does not log in"
pr_end
pr_result
