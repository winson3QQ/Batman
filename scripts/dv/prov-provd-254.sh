#!/bin/bash
# scripts/dv/prov-provd-254.sh <unit> — #254 H3 tier-A units of batman-provd on 04 (docs/design/254-h23-harness.md §6.3,
# 254-p2-impl.md §5 / §9 / §20 / §21). The node judge is scripts/node/prov-p2-254.sh (sent behind ble-lib-254.sh); 02 is
# the BLE central (scripts/node/prov-p2-central-254.sh), aimed at 04 by the last 4 hex digits of 04's serial (STATUS
# key 5; every P2 node advertises the same UUID — review A-M6 / B-M4) and backed by a 04-side witness (04's own log /
# instance count). Everything, 02's reads included, runs under a prov lease of this run; each arm puts back what it
# changes, and pr_release + the lease deadman run radio_restore behind it. No reboot, no p5 / slot write.
# Needs a P2 image (provd) committed on 04; the release image for the environ assertion.
#   boot-provd   judge `boot`; 02 finds 04 by UUID + last4, no name, reads CTRL = {1:1,2:0,3:244,4:8192} and a STATUS
#                map carrying key 5 = 04's last4, not paired; a held link withdraws ("withdrawn reason=connect",
#                0 instances on 04), dropping it registers again ("registered reason=disconnect"); judge `stop` (L2
#                latch) and `flip` (L67)
#   respawn      judge `respawn` (L8) with info.state the same before / after; L80 arm 1 with its control: 02 holds a link
#                and keeps it 15 s with provd untouched (control), then provd is killed -> the new provd logs
#                "disconnected 1 stale link(s)" and 02 sees Connected=no <= 15 s (02's clock); one instance afterwards
#   dep-restart  judge dep-helper, dep-bluetoothd / dep-bluetoothd-kill / dep-dbus (with btmon: p2 §22.3 T4–T6, D3c),
#                sockdir-missing (L77), helper-stop (L71 SIGSTOP row), dep-power / power-bondable / power-provdkill
#                (L84 / L85 / L87, p2 §21.5 T1–T3). btmon = the harness's copy ~/batman-dv-tools/bluez-5.72, pushed with
#                its sha. On wsl.20 (no D3b / D3c) the btmon assertions FAIL: those runs are the negative controls.
#   sec-dbus     the policy of user provd (firmware bluetooth.conf, p2 §4.7) with dbus-send (the harness's copy,
#                scripts/dv-dbus-tools.sh; F16) run as 471 by `provclient exec`: root Introspect + root Properties.Get
#                work; 471 Properties.Get Adapter1.Powered works (positive control); 471 AccessDenied for
#                AgentManager1.RegisterAgent / RequestDefaultAgent, Properties.Set Pairable, Device1.Pair, Adapter1.
#                StartDiscovery / RemoveDevice, Introspect (F16), org.freedesktop.DBus.UpdateActivationEnvironment; a
#                policy that let Set Pairable through is undone by pr_release's radio_restore (pairable off)
# Prints "UNIT prov-<unit>-254 PASS|FAIL|INVALID".
set -u
U=${1:-}; case "$U" in boot-provd|respawn|dep-restart|sec-dbus) ;; *) echo "usage: prov-provd-254.sh boot-provd|respawn|dep-restart|sec-dbus"; exit 2 ;; esac
PR_UNIT=prov-$U-254
# shellcheck source=scripts/dv/prov-254.sh
. "$(dirname "$0")/prov-254.sh"
P2J="$REPO/scripts/node/prov-p2-254.sh"; P2C="$REPO/scripts/node/prov-p2-central-254.sh"
DBT=${DV_DBUS_TOOLS:-$HOME/batman-dv-tools/dbus}; BTT=${DV_BT_TOOLS:-$HOME/batman-dv-tools/bluez-5.72}
# j <arm> [arg] [ssh limit s]: the judge on 04; PASS / FAIL lines become this unit's
j(){
	local o l
	o=$(cat "$REPO/scripts/node/ble-lib-254.sh" "$P2J" | timeout "${3:-600}" ssh $SSHO root@$NODE BATMAN_DV_P2=1 sh -s -- "$1" ${2:+"$2"} 2>&1 | tr -d '\r')
	while IFS= read -r l; do case "$l" in
		PASS\ *) ok "$1: ${l#PASS }" ;; FAIL\ *) no "$1: ${l#FAIL }" ;; INVALID\ *) inv "$1: ${l#INVALID }" ;; INFO\ *) say "$1: ${l#INFO }" ;; esac
	done <<< "$o"
	grep -q "^PROV-P2 $1 fails=" <<< "$o" || no "$1: the judge did not finish ($(tail -2 <<< "$o" | tr '\n' '|'))"
}
c02(){ timeout 300 ssh $SSHO root@$PEER sh -s -- "$@" < "$P2C" 2>&1 | tr -d '\r'; }
plog(){ qr "logread | grep -c 'batman-provd\[[0-9]*\]: provd: $1'"; }
ninst(){ qr "bluetoothctl mgmt.advinfo 2>/dev/null | sed -n 's/^Instances list with \([0-9]*\) item.*/\1/p' | head -1"; }
# 04's STATUS key 5: the last 4 hex digits of its serial (provd server.go Status: deviceID = hex(sn), sn = 9 bytes)
LAST4=""
last4(){ LAST4=$(qr 'tr -d "\n" < /etc/batman-prov/identity/sn | tail -c 4'); case "$LAST4" in [0-9a-f][0-9a-f][0-9a-f][0-9a-f]) return 0 ;; esac; no "04's serial last4 unreadable [$LAST4]"; return 1; }
k5(){ printf '0564%s' "$(printf '%s' "$1" | od -An -tx1 | tr -d ' \n')"; }   # CBOR key 5 = text(4) <last4>
# hold02: 02 connects to 04 and keeps the link up (the central retries its own connects); prints the address;
# rc 1 = no link (INVALID for the caller: a precondition, not a verdict)
hold02(){ local o a; o=$(c02 hold "$LAST4"); say "02 hold: $o" >&2; a=$(sed -n 's/^HELD \([^ ]*\) connected=yes$/\1/p' <<< "$o")
	[ -n "$a" ] && { echo "$a"; return 0; }; a=$(sed -n 's/^HELD \([^ ]*\) .*/\1/p' <<< "$o"); [ -n "$a" ] && c02 drop "$a" >/dev/null; return 1; }
# the jailed provd only (its ujail parent has the same comm)
KILLPROVD='for x in $(pidof batman-provd); do [ "$(readlink /proc/$x/exe)" = /usr/bin/batman-provd ] && kill -9 $x; done'
lease(){ pr_lock; PR_BEGUN=1; trap 'pr_on_exit' EXIT; PR_DEADLINE=$(( $(mono) + $1 )); local o; o=$(pr_acquire "$1") || { echo "$o"; no "lease"; pr_result; exit 1; }; }
ver=$(qr 'sed -n "s/^BATMAN_VERSION=//p" /etc/batman-build'); say "04 runs $ver"
[ -n "$ver" ] || { no "04 unreachable (no BATMAN_VERSION)"; pr_result; exit 1; }
[ "$(qr '[ -x /etc/init.d/batman-provd ] && echo yes || echo no')" = yes ] || { no "no batman-provd on 04 ($ver): a pre-P2 image"; pr_result; exit 1; }

case "$U" in
boot-provd)
	lease 1500
	j boot
	last4 || { pr_release; pr_result; exit 1; }
	c0=$(plog 'adv withdrawn reason=connect')
	o=$(c02 read "$LAST4"); echo "$o" | sed 's/^/    /'
	cv=$(sed -n 's/^CTRL //p' <<< "$o"); sv=$(sed -n 's/^STATUS //p' <<< "$o"); nm=$(sed -n 's/^NAME //p' <<< "$o"); a=$(sed -n 's/^ADDR //p' <<< "$o")
	if [ -z "$a" ]; then inv "02 could not read 04 (no advertiser with key 5 = $LAST4 / reads failed): $(echo $o)"
	else
		[ "$(plog 'adv withdrawn reason=connect')" -gt "$c0" ] && ok "04 logged the connection 02 made for the read (the link was to 04)" || no "04 logged no connection while 02 read [$a] — 02 read another node?"
		ok "02 found 04 by UUID + last4 $LAST4 at $a ($(sed -n 's/^ADVERTISERS //p' <<< "$o") advertiser(s) of the UUID in range)"
		# no Local Name in the advertisement: BlueZ then shows the address (dashes) or nothing as the name
		case "$nm" in -|"${a//:/-}") ok "no Local Name advertised (02 shows [$nm])" ;; *) no "02 shows a name [$nm] — a Local Name is advertised" ;; esac
		[ "$cv" = a4010102000318f404192000 ] && ok "02 read CTRL {1:1,2:0,3:244,4:8192} with no pairing" || no "CTRL [$cv]"
		case "$sv" in a5*"$(k5 "$LAST4")"*) ok "02 read STATUS with no pairing: a 5-entry map with key 5 = $LAST4 ($sv)" ;; *) no "STATUS [$sv] (want a 5-entry map with key 5 = $LAST4: $(k5 "$LAST4"))" ;; esac
		[ "$(sed -n 's/^PAIRED //p' <<< "$o")" = no ] && ok "02 not paired after the reads" || no "02 paired [$(sed -n 's/^PAIRED //p' <<< "$o")]"
	fi
	wc0=$(plog 'adv withdrawn reason=connect'); rd0=$(plog 'adv registered reason=disconnect')   # taken right before the hold (review B-m2)
	if a=$(hold02); then
		sleep 3
		[ "$(plog 'adv withdrawn reason=connect')" -gt "$wc0" ] && ok "a held link withdrew the advertisement (reason=connect)" || no "no 'adv withdrawn reason=connect' while 02 holds a link"
		n=$(ninst); [ "$n" = 0 ] && ok "0 advertising instances on 04 while connected" || no "$n advertising instance(s) while connected"
		rd0=$(plog 'adv registered reason=disconnect'); o=$(c02 drop "$a"); sleep 5
		[ "$(plog 'adv registered reason=disconnect')" -gt "$rd0" ] && ok "dropping the link registered again (reason=disconnect)" || no "no 'adv registered reason=disconnect' after the drop"
	else inv "02 could not hold a link to 04 — the connect / withdraw checks did not run"; fi
	j stop
	j flip
	pr_release ;;
respawn)
	lease 1500
	last4 || { pr_release; pr_result; exit 1; }
	pr_pc_place || { pr_release; pr_result; exit 1; }
	i0=$(timeout 60 ssh $SSHO root@$NODE "$PCD/provclient node info" 2>&1 | tr -d '\r' | grep '^RESULT info.state')
	j respawn
	i1=$(timeout 60 ssh $SSHO root@$NODE "$PCD/provclient node info" 2>&1 | tr -d '\r' | grep '^RESULT info.state')
	[ -n "$i0" ] && [ "$i0" = "$i1" ] && ok "info.state unchanged by the kills ($i1)" || no "info.state before [$i0] after [$i1]"
	# L80 arm 1 + its control (review A-M5 / B-M3): untouched, the link stays 15 s; killed, the new provd's inventory drops it
	if a=$(hold02); then
		o=$(c02 watch "$a" 15); say "control (provd untouched): $o"
		if grep -q '^STILL' <<< "$o"; then ok "L80 control: with provd untouched 02's link stays up 15 s"
			if a=$(hold02); then
				d0=$(plog 'disconnected [0-9]* stale link'); q "$KILLPROVD"
				o=$(c02 watch "$a" 30); say "after the kill: $o"; n=$(sed -n 's/^GONE .* after \([0-9]*\) s.*/\1/p' <<< "$o")
				[ -n "$n" ] && [ "$n" -le 15 ] && ok "L80: 02 saw Connected=no $n s after the kill (02's clock, <= 15)" || no "L80: [$o] (want GONE <= 15 s)"
				t=0; while [ $t -lt 10 ] && [ "$(plog 'disconnected [0-9]* stale link')" = "$d0" ]; do sleep 2; t=$((t + 1)); done
				[ "$(plog 'disconnected [0-9]* stale link')" -gt "$d0" ] && ok "L80: the new provd logged '$(qr "logread | grep 'batman-provd\[' | grep 'stale link' | tail -1" | sed 's/.*provd: //')'" || no "L80: the new provd logged no 'disconnected <n> stale link(s)' — the link went down some other way"
				sleep 5; n=$(ninst); [ "$n" = 1 ] && ok "L80: one instance afterwards" || no "L80: $n instance(s) afterwards"
			else inv "L80: 02 could not hold the second link — the arm did not run"; fi
		else inv "L80 control: the link went down with provd untouched ($o) — the arm cannot tell the cause"; fi
	else inv "L80: 02 could not hold a link to 04 — the arm did not run"; fi
	pr_release ;;
dep-restart)
	lease 900
	[ -f "$BTT/btmon" ] && (cd "$BTT" && sha256sum -c --quiet --ignore-missing SHA256SUMS) >/dev/null 2>&1 || { no "no verified btmon in $BTT (scripts/dv-bt-tools.sh)"; pr_release; pr_result; exit 1; }
	pr_pc_place || { pr_release; pr_result; exit 1; }
	scp -q $SSHO "$BTT/btmon" root@$NODE:$PCD/btmon.up && q "mv $PCD/btmon.up $PCD/btmon && chmod 0700 $PCD/btmon" || { no "btmon upload"; pr_release; pr_result; exit 1; }
	[ "$(qr "sha256sum < $PCD/btmon | cut -c1-64")" = "$(awk '{sub(/^\*/, "", $2)} $2 == "btmon" {print $1}' "$BTT/SHA256SUMS")" ] || { no "btmon sha on 04"; pr_release; pr_result; exit 1; }
	# arm | arg | its worst case (s): the lease is renewed to that + 120 before each arm, the ssh limit is that + 60
	# the list on fd 3: an ssh inside the loop (pr_lease_renew, j) would read fd 0 and eat the rest of it
	while IFS='|' read -r x arg w <&3; do
		[ -n "$x" ] || continue
		pr_lease_renew +$((w + 120)) >/dev/null || { no "lease renew before $x"; break; }
		j "$x" "$arg" $((w + 60))
	done 3<<< "dep-helper||140
dep-bluetoothd|$PCD/btmon|120
dep-bluetoothd-kill|$PCD/btmon|120
dep-dbus|$PCD/btmon|200
sockdir-missing||120
helper-stop||120
dep-power|$PCD/btmon|160
power-bondable|$PCD/btmon|160
power-provdkill|$PCD/btmon|120"
	pr_release ;;
sec-dbus)
	[ -f "$DBT/dbus-send" ] && (cd "$DBT" && sha256sum -c --quiet SHA256SUMS) >/dev/null 2>&1 || { no "no verified dbus-send in $DBT (run scripts/dv-dbus-tools.sh in WSL)"; pr_result; exit 1; }
	lease 900
	pr_pc_place || { pr_release; pr_result; exit 1; }
	scp -q $SSHO "$DBT/dbus-send" root@$NODE:$PCD/dbus-send.up && q "mv $PCD/dbus-send.up $PCD/dbus-send && chmod 0755 $PCD/dbus-send" || { no "dbus-send upload"; pr_release; pr_result; exit 1; }
	[ "$(qr "sha256sum < $PCD/dbus-send | cut -c1-64")" = "$(awk '{sub(/^\*/, "", $2)} $2 == "dbus-send" {print $1}' "$DBT/SHA256SUMS")" ] || { no "dbus-send sha on 04"; pr_release; pr_result; exit 1; }
	DS="$PCD/dbus-send --system --print-reply --reply-timeout=5000"
	as471(){ timeout 30 ssh $SSHO root@$NODE "$PCD/provclient node exec $DS $*" 2>&1 | tr -d '\r'; }
	o=$(qr "$DS --dest=org.bluez / org.freedesktop.DBus.Introspectable.Introspect 2>&1 | head -3")
	grep -q 'string "<!DOCTYPE' <<< "$o" && ok "root Introspect works (the dbus-send copy runs on 04)" || { no "root Introspect: $o"; pr_release; pr_result; exit 1; }
	o=$(qr "$DS --dest=org.bluez /org/bluez/hci0 org.freedesktop.DBus.Properties.Get string:org.bluez.Adapter1 string:Powered 2>&1")
	grep -q 'variant *boolean' <<< "$o" && ok "root Properties.Get works (control for the 471 call)" || no "root Properties.Get: $o"
	o=$(as471 --dest=org.bluez /org/bluez/hci0 org.freedesktop.DBus.Properties.Get string:org.bluez.Adapter1 string:Powered)
	grep -q 'variant *boolean' <<< "$o" && ok "471 Properties.Get Adapter1.Powered allowed (positive control: $(grep -o 'boolean [a-z]*' <<< "$o"))" || no "471 Properties.Get: $o"
	deny(){	# <label> <dbus-send args>
		local l=$1 o; shift; o=$(as471 "$@")
		grep -q 'org.freedesktop.DBus.Error.AccessDenied' <<< "$o" && ok "471 $l -> AccessDenied" || no "471 $l: [$(head -2 <<< "$o" | tr '\n' ' ')] (want AccessDenied)"
	}
	deny AgentManager1.RegisterAgent --dest=org.bluez /org/bluez org.bluez.AgentManager1.RegisterAgent objpath:/dv/agent string:NoInputNoOutput
	deny AgentManager1.RequestDefaultAgent --dest=org.bluez /org/bluez org.bluez.AgentManager1.RequestDefaultAgent objpath:/dv/agent
	deny "Properties.Set Pairable" --dest=org.bluez /org/bluez/hci0 org.freedesktop.DBus.Properties.Set string:org.bluez.Adapter1 string:Pairable variant:boolean:true
	deny Device1.Pair --dest=org.bluez /org/bluez/hci0/dev_00_00_00_00_00_00 org.bluez.Device1.Pair
	deny Adapter1.StartDiscovery --dest=org.bluez /org/bluez/hci0 org.bluez.Adapter1.StartDiscovery
	deny Adapter1.RemoveDevice --dest=org.bluez /org/bluez/hci0 org.bluez.Adapter1.RemoveDevice objpath:/org/bluez/hci0/dev_00_00_00_00_00_00
	deny "Introspect (F16)" --dest=org.bluez / org.freedesktop.DBus.Introspectable.Introspect
	deny DBus.UpdateActivationEnvironment --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.UpdateActivationEnvironment dict:string:string:DV,1
	o=$(qr 'bluetoothctl show 2>/dev/null | grep -E "Pairable|Discoverable"' | tr -s ' \t' ' ')
	grep -q 'Pairable: no' <<< "$o" && grep -q 'Discoverable: no' <<< "$o" && ok "adapter still not pairable / discoverable" || no "adapter after the calls: $o"
	pr_release ;;
esac
pr_result
