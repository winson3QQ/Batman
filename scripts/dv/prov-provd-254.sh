#!/bin/bash
# scripts/dv/prov-provd-254.sh <unit> — #254 H3 tier-A units of batman-provd on 04 (docs/design/254-h23-harness.md §6.3,
# 254-p2-impl.md §5 / §9 / §20). The node judge is scripts/node/prov-p2-254.sh (sent behind ble-lib-254.sh); 02 is the
# BLE central (scripts/node/prov-p2-central-254.sh). Every state change runs under a prov lease of this run, put back by
# the arm itself and, if the host dies, by the lease's deadman (prov-lease-254.sh role_fire_restore). No reboot, no p5 /
# slot write. Needs a P2 image (provd) committed on 04; the release image (no provd.env) for the env assertion.
#   boot-provd   judge `boot` (read-only); 02: the advertiser is found by the service UUID with no name; CTRL and STATUS
#                read with no pairing (CTRL = {1:1,2:0,3:244,4:8192}); a held link withdraws the advertisement
#                ("withdrawn reason=connect", 0 instances) and dropping it registers again ("registered
#                reason=disconnect"); judge `stop` (L2 latch) and `flip` (L67)
#   respawn      judge `respawn` (L8: kill -9 x5) with info.state the same before and after (provclient); L80 arm 1:
#                02 holds a link, provd is killed -> 02 sees Connected=false <= 15 s (the new provd's inventory
#                disconnects it)
#   dep-restart  judge dep-helper, dep-bluetoothd, dep-bluetoothd-kill, dep-dbus, dep-power (L11 / L9 / L65 / L10 / L73),
#                helper-stop (L71 kill -STOP row)
#   sec-dbus     the policy of user provd (firmware bluetooth.conf, p2 §4.7) with dbus-send (the harness's copy,
#                scripts/dv-dbus-tools.sh; F16: the image has none) run as 471 by `provclient exec`: root Introspect works
#                (the binary runs); 471 Properties.Get Adapter1.Powered works (positive control); 471 AccessDenied for
#                AgentManager1.RegisterAgent / RequestDefaultAgent, Properties.Set Pairable, Device1.Pair, Adapter1.
#                StartDiscovery / RemoveDevice, Introspect (F16), org.freedesktop.DBus.UpdateActivationEnvironment
# Prints "UNIT prov-<unit>-254 PASS|FAIL|INVALID".
set -u
U=${1:-}; case "$U" in boot-provd|respawn|dep-restart|sec-dbus) ;; *) echo "usage: prov-provd-254.sh boot-provd|respawn|dep-restart|sec-dbus"; exit 2 ;; esac
PR_UNIT=prov-$U-254
# shellcheck source=scripts/dv/prov-254.sh
. "$(dirname "$0")/prov-254.sh"
P2J="$REPO/scripts/node/prov-p2-254.sh"; P2C="$REPO/scripts/node/prov-p2-central-254.sh"
DBT=${DV_DBUS_TOOLS:-$HOME/batman-dv-tools/dbus}
j(){	# <arm>: the judge on 04; PASS / FAIL lines become this unit's
	local o l
	o=$(cat "$REPO/scripts/node/ble-lib-254.sh" "$P2J" | timeout 600 ssh $SSHO root@$NODE sh -s -- "$1" 2>&1 | tr -d '\r')
	while IFS= read -r l; do case "$l" in
		PASS\ *) ok "$1: ${l#PASS }" ;; FAIL\ *) no "$1: ${l#FAIL }" ;; INFO\ *) say "$1: ${l#INFO }" ;; esac
	done <<< "$o"
	grep -q "^PROV-P2 $1 fails=" <<< "$o" || no "$1: the judge did not finish ($(tail -2 <<< "$o" | tr '\n' '|'))"
}
c02(){ timeout 120 ssh $SSHO root@$PEER sh -s -- "$@" < "$P2C" 2>&1 | tr -d '\r'; }
plog(){ qr "logread | grep -c 'batman-provd\[[0-9]*\]: provd: $1'"; }
# hold02: 02 connects and keeps the link up; 3 tries (02's bluetoothctl connect misses now and then: 04 run 1,
# 2026-11-01 "connected=no"); prints the address, rc 1 = no link (the caller says INVALID: a precondition, not a verdict)
hold02(){ local o a i; for i in 1 2 3; do o=$(c02 hold); say "02 hold (try $i): $o" >&2; a=$(sed -n 's/^HELD \([^ ]*\) connected=yes$/\1/p' <<< "$o")
	[ -n "$a" ] && { echo "$a"; return 0; }; a=$(sed -n 's/^HELD \([^ ]*\) .*/\1/p' <<< "$o"); [ -n "$a" ] && c02 drop "$a" >/dev/null; done; return 1; }
# the jailed provd only (its ujail parent has the same comm)
KILLPROVD='for x in $(pidof batman-provd); do [ "$(readlink /proc/$x/exe)" = /usr/bin/batman-provd ] && kill -9 $x; done'
lease(){ pr_lock; PR_BEGUN=1; trap 'pr_on_exit' EXIT; PR_DEADLINE=$(( $(mono) + $1 )); local o; o=$(pr_acquire "$1") || { echo "$o"; no "lease"; pr_result; exit 1; }; }
ver=$(qr 'sed -n "s/^BATMAN_VERSION=//p" /etc/batman-build'); say "04 runs $ver"
[ "$(qr '[ -x /etc/init.d/batman-provd ] && echo yes')" = yes ] || { no "no batman-provd on 04 ($ver): a pre-P2 image"; pr_result; exit 1; }

case "$U" in
boot-provd)
	j boot
	o=$(c02 find); say "02 find: $(echo $o)"
	a=$(sed -n 's/^ADDR //p' <<< "$o"); nm=$(sed -n 's/^NAME //p' <<< "$o")
	[ -n "$a" ] && ok "02 found the advertiser by the service UUID ($a)" || no "02 found no advertiser with the service UUID"
	# no Local Name in the advertisement: BlueZ then shows the address (dashes) or nothing as the name
	case "$nm" in -|"${a//:/-}") ok "no Local Name advertised (02 shows [$nm])" ;; *) no "02 shows a name [$nm] — a Local Name is advertised" ;; esac
	o=$(c02 read); echo "$o" | sed 's/^/    /'
	cv=$(sed -n 's/^CTRL //p' <<< "$o"); sv=$(sed -n 's/^STATUS //p' <<< "$o")
	[ "$cv" = a4010102000318f404192000 ] && ok "02 read CTRL {1:1,2:0,3:244,4:8192} with no pairing" || no "CTRL [$cv]"
	case "$sv" in a[0-9a-f]*) ok "02 read STATUS ($sv) with no pairing" ;; *) no "STATUS [$sv]" ;; esac
	[ "$(sed -n 's/^PAIRED //p' <<< "$o")" = no ] && ok "02 not paired after the reads" || no "02 paired [$(sed -n 's/^PAIRED //p' <<< "$o")]"
	lease 1200
	wc0=$(plog 'adv withdrawn reason=connect'); rd0=$(plog 'adv registered reason=disconnect')
	if a=$(hold02); then
		sleep 3
		[ "$(plog 'adv withdrawn reason=connect')" -gt "$wc0" ] && ok "a held link withdrew the advertisement (reason=connect)" || no "no 'adv withdrawn reason=connect' while 02 holds a link"
		n=$(qr "bluetoothctl mgmt.advinfo 2>/dev/null | sed -n 's/^Instances list with \([0-9]*\) item.*/\1/p' | head -1")
		[ "$n" = 0 ] && ok "0 advertising instances while connected" || no "$n advertising instance(s) while connected"
		o=$(c02 drop "$a"); sleep 5
		[ "$(plog 'adv registered reason=disconnect')" -gt "$rd0" ] && ok "dropping the link registered again (reason=disconnect)" || no "no 'adv registered reason=disconnect' after the drop"
	else inv "02 could not hold a link in 3 tries — the connect / withdraw checks did not run"; fi
	j stop
	j flip
	pr_release ;;
respawn)
	lease 1200
	pr_pc_place || { pr_release; pr_result; exit 1; }
	i0=$(timeout 60 ssh $SSHO root@$NODE "$PCD/provclient node info" 2>&1 | tr -d '\r' | grep '^RESULT info.state')
	j respawn
	i1=$(timeout 60 ssh $SSHO root@$NODE "$PCD/provclient node info" 2>&1 | tr -d '\r' | grep '^RESULT info.state')
	[ -n "$i0" ] && [ "$i0" = "$i1" ] && ok "info.state unchanged by the kills ($i1)" || no "info.state before [$i0] after [$i1]"
	# L80 arm 1: a link left up across a provd restart is disconnected by the new provd's inventory
	if a=$(hold02); then
		q "$KILLPROVD"
		o=$(c02 watch "$a" 30); say "02 watch: $o"
		n=$(sed -n 's/^GONE .* after \([0-9]*\) s$/\1/p' <<< "$o")
		[ -n "$n" ] && [ "$n" -le 15 ] && ok "L80: 02 disconnected $n s after the kill (<= 15)" || no "L80: [$o] (want GONE <= 15 s)"
	else inv "L80: 02 could not hold a link in 3 tries — the arm did not run"; fi
	q "rm -rf $PCD"
	pr_release ;;
dep-restart)
	lease 1800
	for x in dep-helper dep-bluetoothd dep-bluetoothd-kill dep-dbus dep-power helper-stop; do j "$x"; pr_lease_renew +900 >/dev/null; done
	pr_release ;;
sec-dbus)
	[ -f "$DBT/dbus-send" ] && (cd "$DBT" && sha256sum -c --quiet SHA256SUMS) >/dev/null 2>&1 || { no "no verified dbus-send in $DBT (run scripts/dv-dbus-tools.sh in WSL)"; pr_result; exit 1; }
	lease 900
	pr_pc_place || { pr_release; pr_result; exit 1; }
	scp -q $SSHO "$DBT/dbus-send" root@$NODE:$PCD/dbus-send.up && q "mv $PCD/dbus-send.up $PCD/dbus-send && chmod 0755 $PCD/dbus-send" || { no "dbus-send upload"; pr_release; pr_result; exit 1; }
	[ "$(qr "sha256sum < $PCD/dbus-send | cut -c1-64")" = "$(awk '$2 == "dbus-send" {print $1}' "$DBT/SHA256SUMS")" ] || { no "dbus-send sha on 04"; pr_release; pr_result; exit 1; }
	DS="$PCD/dbus-send --system --print-reply --reply-timeout=5000"
	as471(){ timeout 30 ssh $SSHO root@$NODE "$PCD/provclient node exec $DS $*" 2>&1 | tr -d '\r'; }
	o=$(qr "$DS --dest=org.bluez / org.freedesktop.DBus.Introspectable.Introspect 2>&1 | head -3")
	grep -q 'string "<!DOCTYPE' <<< "$o" && ok "root Introspect works (the dbus-send copy runs on 04)" || { no "root Introspect: $o"; pr_release; pr_result; exit 1; }
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
	q "rm -rf $PCD"
	pr_release ;;
esac
pr_result
