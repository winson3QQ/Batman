#!/bin/bash
# scripts/dv/prov-netjoin-254.sh — #254 tier-B unit prov-netjoin-254 (docs/design/254-h23-harness.md §6.2;
# 254-p1-impl §4.4 single node): 04 alone, a RANDOM mesh id and key (made on the node, never on the host), the channel
# unchanged — 04 leaves the fleet mesh until the restore.
#   positive (release helper): claim -> net.apply network/join WITHOUT the owner-op -> E_FORBIDDEN (3), still claimed ->
#     net-apply --first -> code 0; member, radio managed; wireless (mesh_id, key, encryption, channel) == the
#     applied values; overlay prov.meta == p5; --check in sync (overrides == prov); the key in no log
#   L71 (P2 image, 254-p2-impl §5): the positive join runs through a halow-setkey hook that sleeps 60 s first (the
#     helper holds its mutex); meanwhile info.state on a third connection <= 2 s, 02 reads STATUS over BLE (claimed:
#     no key 5), bondable on withdraws <= 9.5 s (judge `flip`); the single-connection helper that would block all
#     three is the helper Go tests' mutant
#   negative control: restore -> claim again -> helper-nojoinop bound -> the same join WITHOUT the owner-op is
#     ACCEPTED (code 0) — this unit would see a helper that skips the owner-op check
# Type: — / A / F. Side effects: 04 off the mesh ~25 min, 3 reboots (restores), claimed twice, B untouched.
set -u
PR_UNIT=prov-netjoin-254
# shellcheck source=scripts/dv/prov-254.sh
. "$(dirname "$0")/prov-254.sh"
MESH="dvj-$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"   # not secret (the key is made on the node)
# the fd-3 producer, run ON the node by root: the key is drawn there, kept root-only in $PCD/sae for the checks
FD3="umask 077; s=\$(head -c 16 /dev/urandom | hexdump -v -e '1/1 \"%02x\"'); echo \"\$s\" > $PCD/sae; printf 'mesh_id=%s\nchannel=%s\nbw=2\nsae=%s\n' '$MESH' \"\$(uci -q get wireless.radio1.channel)\" \"\$s\""
WCHK='m=$(uci -q get wireless.default_radio1.mesh_id); e=$(uci -q get wireless.default_radio1.encryption); c=$(uci -q get wireless.radio1.channel); k=$( [ "$(uci -q get wireless.default_radio1.key)" = "$(cat '"$PCD"'/sae 2>/dev/null)" ] && echo same || echo differ); echo "mesh_id=$m enc=$e channel=$c key=$k"'

pr_begin 3000 || { pr_result; exit 1; }
CH0=$(qr 'uci -q get wireless.radio1.channel')
pr_keys && pr_pc_place && pr_claim || { pr_abort "claim"; pr_result; exit 1; }
# ---- positive: the owner-op is required, then the join
r=$(pr_pc owner.pem FD3="$FD3" -- net-apply --first-noop "$OWNER"); echo "$r" | sed 's/^/    /'
grep -q "RESULT net.apply(no owner-op) code=3 " <<< "$r" && ok "join without the owner-op -> E_FORBIDDEN" || no "join without the owner-op not refused: $r"
i=$(pr_info); [ "${i%% *}" = state=claimed ] && ok "still claimed after the refused join ($i)" || no "state after the refused join: $i"
if [ "$(qr '[ -x /etc/init.d/batman-provd ] && echo yes')" = yes ]; then
	# L71 (254-p2-impl §5, H3): the join holds the helper's mutex ~60 s (a hook over halow-setkey sleeps first, then runs
	# the real setkey); meanwhile provd's ctl side is not blocked: a third connection (provclient) answers info.state
	# <= 2 s, 02 reads STATUS over BLE (claimed: no last-4 digits, key 5), bondable on withdraws <= 9.5 s (judge `flip`).
	# The single-connection helper that would block all three is the helper Go unit tests' mutant (#254 P2).
	W=/tmp/run/batman-dv/wbox/$RUN
	pw prep >/dev/null
	q "cp -p /usr/bin/halow-setkey $W/setkey.real && chmod 700 $W/setkey.real && printf '#!/bin/sh\nsleep 60\nexec $W/setkey.real \"\$@\"\n' > $W/setkey.slow && chmod 755 $W/setkey.slow"
	o=$(pw bind setkey.slow "$(qr "sha256sum < $W/setkey.slow | cut -c1-64")" /usr/bin/halow-setkey); say "$o"
	grep -q '^BOUND /usr/bin/halow-setkey' <<< "$o" || { pr_abort "bind of the slow setkey"; pr_result; exit 1; }
	jf=$(mktemp); ( pr_pc owner.pem FD3="$FD3" -- net-apply --first "$OWNER" > "$jf" ) & jp=$!
	sleep 15
	o=$(qr "a=\$(cut -d' ' -f1 /proc/uptime); $PCD/provclient node info 2>&1 | grep '^RESULT'; b=\$(cut -d' ' -f1 /proc/uptime); awk -v a=\$a -v b=\$b 'BEGIN { printf \"T=%dms\n\", (b - a) * 1000 }'")
	say "L71 info during the join: $(echo $o)"; t=$(sed -n 's/^T=\([0-9]*\)ms$/\1/p' <<< "$o")
	grep -q '^RESULT info.state code=0 state=claimed ' <<< "$o" && [ "${t:-99999}" -le 2000 ] && ok "L71: info.state on a third connection in ${t} ms while the join holds the helper (<= 2 s)" || no "L71: info.state during the join: $(echo $o)"
	o=$(timeout 120 ssh $SSHO root@$PEER sh -s -- read < "$REPO/scripts/node/prov-p2-central-254.sh" 2>&1 | tr -d '\r'); sv=$(sed -n 's/^STATUS //p' <<< "$o")
	case "$sv" in a*) case "$sv" in *0564*) no "L71: STATUS of a claimed node carries key 5 (last-4): $sv" ;; *) ok "L71: 02 read STATUS over BLE during the join ($sv, claimed: no last-4)" ;; esac ;;
		*) no "L71: 02 could not read STATUS during the join: $(echo $o)" ;; esac
	o=$(cat "$REPO/scripts/node/ble-lib-254.sh" "$REPO/scripts/node/prov-p2-254.sh" | timeout 120 ssh $SSHO root@$NODE sh -s -- flip 2>&1 | tr -d '\r')
	while IFS= read -r l; do case "$l" in PASS\ *) ok "L71 flip: ${l#PASS }" ;; FAIL\ *) no "L71 flip: ${l#FAIL }" ;; esac; done <<< "$o"
	[ "$(qr 'pidof batman-provhelper >/dev/null && ps | grep -c "[s]etkey.slow\|[s]leep 60"')" -ge 1 ] && ok "L71: the join was still in its slow setkey after the three checks" || inv "L71: the join had already left the slow setkey — the checks may not have overlapped it"
	wait $jp; r=$(cat "$jf"); rm -f "$jf"
	say "unbind: $(pw unbind-all | tr '\n' ' ')"
else
	no "L71: pre-P2 image (no batman-provd) — the L71 arm did not run"
	r=$(pr_pc owner.pem FD3="$FD3" -- net-apply --first "$OWNER")
fi
echo "$r" | grep -v '^NETCFG' | sed 's/^/    /'
grep -q "RESULT net.apply code=0 " <<< "$r" && ok "net.apply network/join code 0" || no "net.apply --first: $r"
# #254 wireless-txn §19.2 rule 2: code 0 means netifd reports the radio up on the new network (not pending)
w=$(qr 'ubus call network.wireless status | jsonfilter -e @.radio1.up -e @.radio1.pending | tr "\n" " "')
[ "$w" = "true false " ] && ok "after the join netifd reports radio1 up=true pending=false" || no "after the join netifd reports [$w] (want up=true pending=false)"
i=$(pr_info); say "after join: $i"
case " $i " in *" state=member "*) ok "state member";; *) no "state after the join: $i";; esac
case " $i " in *" rm=true "*|*" rm=1 "*) ok "radio managed";; *) no "radio not managed: $i";; esac
w=$(qr "$WCHK"); say "wireless: $w"
[ "$w" = "mesh_id=$MESH enc=sae channel=$CH0 key=same" ] && ok "wireless == the applied net (mesh_id, sae, key, channel $CH0 unchanged)" || no "wireless after the join: [$w] want mesh_id=$MESH enc=sae channel=$CH0 key=same"
o=$(qr 'd=$(mktemp -d /tmp/run/batman-dv/pg.XXXXXX); rmdir $d; batman-config-save --prov-get $d >/dev/null 2>&1; cmp -s $d/prov.meta /etc/batman-prov/prov.meta && echo P5SAME; rm -rf $d; batman-config-save --check >/dev/null 2>&1; echo check_rc=$?')
grep -q P5SAME <<< "$o" && ok "p5 prov.meta == overlay" || no "p5 / overlay prov.meta differ"
grep -q 'check_rc=0' <<< "$o" && ok "--check: overrides in sync with prov" || no "--check after the join: $o"
l=$(qr "logread | grep 'batman-provhelper.*network/join: --save rc=' | tail -1")
[ -z "$l" ] && ok "the helper's own --save after the join succeeded" || no "the helper's --save failed: ${l##*]: } (Batman 5c5bf1a fixes the txn-marker order)"
c=$(qr "n=0; logread > $PCD/lr; cat /opt/batdata/log/*.log >> $PCD/lr 2>/dev/null; grep -qF -f $PCD/sae $PCD/lr && n=1; rm -f $PCD/lr; echo leaks=\$n")
[ "$c" = leaks=0 ] && ok "the mesh key is in no log (logread, p6 logs)" || no "mesh key canary: $c"
# ---- negative control: helper-nojoinop accepts the join without the owner-op
pr_restore || { pr_abort "restore after the positive half"; pr_result; exit 1; }
if ! qr '/usr/bin/batman-provhelper --version >/dev/null 2>&1'; then
	no "pre-P1b image: $(field "$(qr "$ST")" ver) (helper has no --version) — the helper-nojoinop negative control needs P1b"
else
	pr_pc_place && pr_claim || { pr_abort "claim (negative)"; pr_result; exit 1; }
	pr_push_helper helper-nojoinop || { pr_abort "push helper-nojoinop"; pr_result; exit 1; }
	r=$(pr_pc owner.pem FD3="$FD3" -- net-apply --first-noop "$OWNER"); echo "$r" | sed 's/^/    /'
	grep -q "RESULT net.apply(no owner-op) code=0 " <<< "$r" && ok "negative control: helper-nojoinop accepts the join without the owner-op" || no "negative control: helper-nojoinop did not accept it ($r) — the mutant had no effect"
fi
pr_end
pr_result
