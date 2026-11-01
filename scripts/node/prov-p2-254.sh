# shellcheck shell=sh
# scripts/node/prov-p2-254.sh — #254 H3 node judge of batman-provd (docs/design/254-h23-harness.md §6.3, 254-p2-impl.md
# §5 / §9). Sent behind ble-lib-254.sh:  cat ble-lib-254.sh prov-p2-254.sh | ssh root@node sh -s -- <arm>
# Every check prints PASS / FAIL / INFO; the last line is "PROV-P2 <arm> fails=<n>"; exit 0 only with no FAIL.
# The arms that change something put it back themselves (trap on EXIT / HUP / INT / TERM) and run under the host's prov
# lease, whose deadman also puts each of them back (prov-lease-254.sh role_fire_restore): a SIGSTOPped helper, a stopped
# provd, bondable on, hci0 powered off.
#   boot          read-only (prov-boot-254, provd side): provd runs as 471:471 under ujail, no capability, NoNewPrivs,
#                 jail without /etc/shadow but with the helper socket dir; no test switch in its environment (release
#                 init); health this boot with adv_registered_once=1 and the six preconditions; kernel advertising
#                 instances = 1 with no LE link up (<= 1 with one); BlueZ not discoverable / pairable
#   stop          provd stopped -> instance gone <= 10 s ("adv withdrawn reason=stop"); two health ticks later
#                 adv_registered_once is still 1 (the latch, L2); started again -> provd_check
#   flip          bondable on -> instance withdrawn <= 9.5 s with "adv withdrawn reason=health" (L67); bondable off ->
#                 registered again <= 15 s
#   respawn       kill -9 provd x5 (L8): each time a new pid <= 15 s (procd respawn 5 s) and its instance <= 15 s later
#   dep-helper | dep-bluetoothd | dep-bluetoothd-kill | dep-dbus | dep-power
#                 the dependency restarted (L11 / L9 / L65 / L10 / L73): provd advertises again <= 15 s after the
#                 dependency is back (dbus: after bluetoothd's new pid and sc_file=1, the L10 split); dep-power: hci0
#                 powered off -> health hci0_powered=0 and no instance, powered on -> instance <= 15 s
#   helper-stop   SIGSTOP the helper (L71 last row): provd withdraws <= 65 s with "adv withdrawn reason=helper";
#                 SIGCONT -> registered again <= 15 s
#   sock-only     (prov_test image, after set-provd-env SOCK_ONLY=1) the frame socket line of this pid, no instance
#                 for 10 s, /tmp/run/batman-provd-test provd 0700 with gatt.sock provd 0600
#   sockdir-root  (prov_test, SOCK_ONLY running) the socket dir made root:root, provd killed -> procd's respawn (the
#                 init does not run again) refuses the dir: "refusing to bind" by a new pid, no listener
#   adv-len       (prov_test, after set-provd-env ADV_LEN_TEST=29) "adv: payload would be 29 B (max 28)" by this pid
#                 and no instance for 20 s (arm 1 of prov-sec-adv-len-254; no kernel witness on the node, p2 §4.8)
if [ -r /usr/lib/batman/rundir.sh ]; then . /usr/lib/batman/rundir.sh; else echo "FAIL no /usr/lib/batman/rundir.sh"; exit 1; fi
HF=$RUNDIR/batman-prov.health
TD=/tmp/run/batman-provd-test
fails=0
ok() { echo "PASS $*"; }
no() { echo "FAIL $*"; fails=$((fails + 1)); }
info() { echo "INFO $*"; }
# hundredths of a second since boot (busybox: no %N, sleep takes whole seconds; usleep when there is one)
cs() { awk '{printf "%d", $1 * 100}' /proc/uptime; }
nap() { usleep 250000 2>/dev/null || sleep 1; }
secs() { echo "$1" | awk '{printf "%.2f", $1 / 100}'; }
hf() { [ -r "$HF" ] && echo " $(cat "$HF")" | sed -n "s/.* $1=\([^ ]*\).*/\1/p" | head -1; }
# provd log lines matching $1: how many in the ring. The tag is batman-provd[1] — provd is pid 1 of its ujail pid
# namespace (04 wsl.20, 2026-11-01) — so a line is never tied to a host pid: the arms compare counts / the latest line.
plc() { logread | grep -c "batman-provd\[[0-9]*\]: $1"; }
connected() { bluetoothctl devices Connected 2>/dev/null | clean | grep -c '^Device '; }
hpid() { pidof batman-provhelper | awk '{print $1}'; }
# wait_adv <want> <seconds> -> prints the hundredths it took; rc 1 when not reached
wait_adv() {
	_t0=$(cs); while :; do
		[ "$(adv_instances 2>/dev/null)" = "$1" ] && { echo $(( $(cs) - _t0 )); return 0; }
		[ $(( $(cs) - _t0 )) -ge $(( $2 * 100 )) ] && return 1
		nap
	done
}
# wait_line <text after the tag> <count before> <seconds>: a new provd log line
wait_line() {
	_n=0; while [ $_n -lt "$3" ]; do [ "$(plc "$1")" -gt "$2" ] && return 0; sleep 1; _n=$((_n + 1)); done; return 1
}
# lastline <ERE>: the latest provd log line matching ERE
lastline() { logread | grep "batman-provd\[[0-9]*\]: " | grep -E "$1" | tail -1; }
# health_fresh <max s> <uptime>: a health line of this boot written at or after <uptime>
health_fresh() {
	_n=0; while [ $_n -lt "$1" ]; do
		[ "$(hf boot_id)" = "$(bootid)" ] && [ "$(hf ts)" -ge "$2" ] 2>/dev/null && return 0; sleep 1; _n=$((_n + 1))
	done; return 1
}

a=${1:-}
provd_present || { echo "FAIL no batman-provd on this image (pre-P2)"; echo "PROV-P2 $a fails=1"; exit 1; }
case "$a" in
boot)
	p=$(provd_pid)
	if [ -z "$p" ]; then no "provd not running"
	else
		n=0; for x in $(pidof batman-provd); do [ "$(readlink "/proc/$x/exe")" = /usr/bin/batman-provd ] && n=$((n + 1)); done
		[ "$n" = 1 ] && ok "one provd (pid $p; pidof: $(pidof batman-provd), the other is its ujail)" || no "$n provd processes: $(pidof batman-provd)"
		u=$(awk '/^Uid:/ {print $2, $3, $4, $5}' "/proc/$p/status"); g=$(awk '/^Gid:/ {print $2, $3, $4, $5}' "/proc/$p/status")
		[ "$u" = "471 471 471 471" ] && [ "$g" = "471 471 471 471" ] && ok "uid / gid 471 (all four)" || no "uid [$u] gid [$g]"
		c=$(awk '/^Cap(Inh|Prm|Eff|Bnd|Amb):/ {printf "%s ", $2}' "/proc/$p/status")
		[ "$c" = "0000000000000000 0000000000000000 0000000000000000 0000000000000000 0000000000000000 " ] && ok "no capability (Inh Prm Eff Bnd Amb all 0)" || no "capabilities [$c]"
		nn=$(awk '/^NoNewPrivs:/ {print $2}' "/proc/$p/status"); [ "$nn" = 1 ] && ok "NoNewPrivs 1" || no "NoNewPrivs [$nn]"
		pp=$(awk '{print $4}' "/proc/$p/stat"); pe=$(readlink "/proc/$pp/exe")
		[ "$pe" = /sbin/ujail ] && ok "parent is ujail (pid $pp, $pe)" || no "parent exe [$pe] (want /sbin/ujail)"
		[ ! -e "/proc/$p/root/etc/shadow" ] && ok "jail root has no /etc/shadow" || no "/etc/shadow visible in provd's root"
		[ -d "/proc/$p/root/tmp/run/batman-prov" ] && ok "helper socket dir mounted in the jail" || no "the helper socket dir is not in provd's root"
		k=$(tr '\0' '\n' < "/proc/$p/environ" | grep -c -E "$PROVD_KEYS")
		if grep -q provd.env "$PROVD_INIT"; then info "prov_test init; provd environ carries $k test switch(es)"
		else [ "$k" = 0 ] && ok "release init, no test switch in provd's environ" || no "release init but $k test switch(es) in provd's environ"; fi
	fi
	if [ "$(hf boot_id)" = "$(bootid)" ]; then
		up=$(up_s); t=$(hf ts); [ $((up - t)) -le 60 ] && ok "health this boot, fresh (age $((up - t)) s)" || no "health stale (ts $t, uptime $up)"
		v="bluetoothd=$(hf bluetoothd) hci0_powered=$(hf hci0_powered) privacy=$(hf privacy) sc=$(hf sc) sc_file=$(hf sc_file) bondable=$(hf bondable)"
		[ "$v" = "bluetoothd=1 hci0_powered=1 privacy=1 sc=1 sc_file=1 bondable=0" ] && ok "health preconditions: $v" || no "health preconditions: $v"
		[ "$(hf adv_registered_once)" = 1 ] && ok "health adv_registered_once=1 (latch, measured by the helper)" || no "health adv_registered_once=[$(hf adv_registered_once)]"
	else no "health line not of this boot: [$(cat "$HF" 2>/dev/null)]"; fi
	n=$(adv_instances); c=$(connected)
	if [ -z "$n" ]; then no "kernel advertising instances unreadable"
	elif [ "$c" = 0 ]; then [ "$n" = 1 ] && ok "kernel advertising instances = 1, no LE link up" || no "kernel advertising instances = $n with no LE link up (want 1)"
	else [ "$n" -le 1 ] && ok "kernel advertising instances = $n with $c link(s) up" || no "kernel advertising instances = $n with $c link(s)"; fi
	s=$(bluetoothctl show 2>/dev/null | clean)
	echo "$s" | grep -q 'Discoverable: no' && echo "$s" | grep -q 'Pairable: no' && ok "BlueZ adapter not discoverable, not pairable" || no "BlueZ adapter: $(echo "$s" | grep -E 'Discoverable|Pairable' | tr -s ' \t' ' ' | tr '\n' ' ')"
	info "provd log in the ring: $(plc 'provd: adv registered') registered, $(plc 'provd: adv withdrawn') withdrawn; last: $(logread | grep 'batman-provd\[' | grep -E 'adv (registered|withdrawn)' | tail -1 | sed 's/.*provd: //')"
	;;
stop)
	trap 'provd_start' EXIT HUP INT TERM
	[ "$(hf adv_registered_once)" = 1 ] || no "precondition: adv_registered_once is not 1"
	w=$(plc 'provd: adv withdrawn reason=stop'); t0=$(cs)
	provd_stop
	if wait_adv 0 10 >/dev/null; then ok "provd stopped: no advertising instance after $(secs $(( $(cs) - t0 ))) s (<= 10)"; else no "provd stopped: an instance is still there after 10 s"; fi
	[ "$(plc 'provd: adv withdrawn reason=stop')" -gt "$w" ] && ok "logged 'adv withdrawn reason=stop'" || no "no 'adv withdrawn reason=stop' line"
	t=$(up_s)
	if health_fresh 40 $((t + 16)) && health_fresh 40 $((t + 31)); then
		[ "$(hf adv_registered_once)" = 1 ] && ok "two health ticks later adv_registered_once is still 1 (latch, provd stopped)" || no "adv_registered_once fell to [$(hf adv_registered_once)] with provd stopped"
	else no "no two fresh health ticks within 80 s"; fi
	provd_start; trap - EXIT HUP INT TERM
	if o=$(provd_check); then ok "started again: $o"; else no "after the start: $o"; fi
	;;
flip)
	trap 'bluetoothctl mgmt.bondable off >/dev/null 2>&1' EXIT HUP INT TERM
	[ "$(adv_instances)" = 1 ] || no "precondition: no advertising instance"
	w=$(plc 'provd: adv withdrawn reason=health'); r=$(plc 'provd: adv registered')
	bluetoothctl mgmt.bondable on >/dev/null 2>&1
	if d=$(wait_adv 0 12); then
		[ "$d" -le 950 ] && ok "bondable on: withdrawn after $(secs "$d") s (<= 9.5, L67)" || no "bondable on: withdrawn after $(secs "$d") s (> 9.5)"
	else no "bondable on: still advertising after 12 s"; fi
	wait_line 'provd: adv withdrawn reason=health' "$w" 5 && ok "logged 'adv withdrawn reason=health'" || no "no 'adv withdrawn reason=health' line"
	bluetoothctl mgmt.bondable off >/dev/null 2>&1; trap - EXIT HUP INT TERM
	if d=$(wait_adv 1 15); then ok "bondable off: registered again after $(secs "$d") s"; else no "bondable off: no instance within 15 s"; fi
	wait_line 'provd: adv registered' "$r" 5 && ok "logged 'adv registered' again" || no "no new 'adv registered' line"
	;;
respawn)
	i=1; while [ $i -le 5 ]; do
		p=$(provd_pid); [ -n "$p" ] || { no "round $i: provd not running"; break; }
		s0=$(plc 'provd: adv registered reason=start'); t0=$(cs); kill -9 "$p"
		q=""; while [ $(( $(cs) - t0 )) -lt 1500 ]; do q=$(provd_pid); [ -n "$q" ] && [ "$q" != "$p" ] && break; nap; done
		if [ -n "$q" ] && [ "$q" != "$p" ]; then
			ok "round $i: kill -9 $p -> new provd $q after $(secs $(( $(cs) - t0 ))) s (<= 15)"
			if d=$(wait_adv 1 15) && wait_line 'provd: adv registered reason=start' "$s0" 15; then ok "round $i: advertising again $(secs "$d") s after the new pid, with a new 'adv registered reason=start'"
			else no "round $i: no instance / no new 'adv registered reason=start' within 15 s of the new pid"; fi
		else no "round $i: no new provd within 15 s of kill -9 $p"; break; fi
		i=$((i + 1))
	done
	if o=$(provd_check); then ok "after the kills: $o"; else no "after the kills: $o"; fi
	;;
dep-helper|dep-bluetoothd|dep-bluetoothd-kill|dep-dbus)
	trap 'pidof batman-provhelper >/dev/null || /etc/init.d/batman-provhelper start >/dev/null 2>&1; pidof bluetoothd >/dev/null || /etc/init.d/bluetoothd start >/dev/null 2>&1' EXIT HUP INT TERM
	p=$(provd_pid); b=$(pidof bluetoothd); h=$(hpid); r=$(plc 'provd: adv registered'); x=""
	case "$a" in
	dep-helper) lim 60 /etc/init.d/batman-provhelper restart >/dev/null 2>&1
		n=0; while [ $n -lt 20 ]; do x=$(hpid); [ -n "$x" ] && [ "$x" != "$h" ] && break; sleep 1; n=$((n + 1)); done
		[ -n "$x" ] && [ "$x" != "$h" ] && ok "helper restarted (pid $h -> $x)" || no "helper did not come back with a new pid" ;;
	dep-bluetoothd|dep-bluetoothd-kill)
		if [ "$a" = dep-bluetoothd ]; then lim 60 /etc/init.d/bluetoothd restart >/dev/null 2>&1; else kill -9 "$b"; fi
		n=0; while [ $n -lt 30 ]; do x=$(pidof bluetoothd); [ -n "$x" ] && [ "$x" != "$b" ] && break; sleep 1; n=$((n + 1)); done
		[ -n "$x" ] && [ "$x" != "$b" ] && ok "bluetoothd back (pid $b -> $x)" || no "bluetoothd did not come back with a new pid" ;;
	dep-dbus) lim 60 /etc/init.d/dbus restart >/dev/null 2>&1
		n=0; while [ $n -lt 60 ]; do x=$(pidof bluetoothd); [ -n "$x" ] && [ "$x" != "$b" ] && break; sleep 1; n=$((n + 1)); done
		[ -n "$x" ] && [ "$x" != "$b" ] && ok "bluetoothd followed the dbus restart (pid $b -> $x)" || no "bluetoothd did not restart after dbus (pid [$x])"
		t=$(up_s); n=0; while [ $n -lt 60 ]; do health_fresh 20 "$t" && [ "$(hf sc_file)" = 1 ] && break; sleep 1; n=$((n + 1)); done
		[ "$(hf sc_file)" = 1 ] && ok "sc_file=1 again (patch 900 rewrote batman-sc for the new bluetoothd)" || no "sc_file not 1 after the dbus restart: [$(cat "$HF")]" ;;
	esac
	t0=$(cs)
	if wait_adv 1 15 >/dev/null && wait_line 'provd: adv registered' "$r" 15; then ok "$a: advertising again $(secs $(( $(cs) - t0 ))) s after the dependency was back (<= 15)"
	elif [ "$a" = dep-helper ] && [ "$(adv_instances)" = 1 ]; then ok "$a: the instance stayed registered through the helper restart"
	else no "$a: no advertising instance / no new 'adv registered' within 15 s (instances $(adv_instances))"; fi
	q=$(provd_pid)
	case "$a" in dep-dbus) info "provd pid $p -> $q (provd retries the bus inside)" ;;
		*) [ "$q" = "$p" ] && ok "provd kept running (pid $p): no restart needed" || info "provd pid $p -> $q" ;; esac
	if [ "$a" = dep-helper ]; then
		t=$(up_s); health_fresh 30 "$t" && [ "$(hf adv_registered_once)" = 1 ] && ok "the new helper measured adv_registered_once=1" || no "after the helper restart adv_registered_once=[$(hf adv_registered_once)]"
	fi
	trap - EXIT HUP INT TERM
	;;
dep-power)
	trap 'bluetoothctl power on >/dev/null 2>&1' EXIT HUP INT TERM
	w=$(plc 'provd: adv withdrawn'); r=$(plc 'provd: adv registered')
	bluetoothctl power off >/dev/null 2>&1
	t=$(up_s); n=0; while [ $n -lt 30 ]; do health_fresh 20 "$t" && [ "$(hf hci0_powered)" = 0 ] && break; sleep 1; n=$((n + 1)); done
	[ "$(hf hci0_powered)" = 0 ] && ok "powered off: health hci0_powered=0" || no "powered off: health [$(cat "$HF")]"
	# powered off the radio sends nothing, but the kernel keeps its instance list (04 wsl.20, 2026-11-01: 1 listed after
	# provd's withdraw) -> the verdict is provd's own withdraw; the kernel count is recorded only
	wait_line 'provd: adv withdrawn' "$w" 15 && ok "powered off: provd withdrew ($(lastline 'provd: adv withdrawn' | sed 's/.*provd: //'))" || no "powered off: no new 'adv withdrawn' line within 15 s"
	info "powered off: kernel lists $(adv_instances) instance(s) (kept by the kernel while off)"
	bluetoothctl power on >/dev/null 2>&1; trap - EXIT HUP INT TERM
	t=$(up_s); n=0; while [ $n -lt 30 ]; do health_fresh 20 "$t" && [ "$(hf hci0_powered)" = 1 ] && break; sleep 1; n=$((n + 1)); done
	if d=$(wait_adv 1 15); then ok "powered on: advertising again $(secs "$d") s after hci0_powered=1"; else no "powered on: no instance within 15 s of hci0_powered=1"; fi
	wait_line 'provd: adv registered' "$r" 5 && ok "logged a new 'adv registered'" || no "no new 'adv registered' after power on"
	info "withdrawn lines during the arm: $(( $(plc 'provd: adv withdrawn') - w ))"
	;;
helper-stop)
	h=$(hpid); [ -n "$h" ] || { no "helper not running"; echo "PROV-P2 $a fails=$fails"; exit 1; }
	trap 'kill -CONT '"$h"' 2>/dev/null' EXIT HUP INT TERM
	w=$(plc 'provd: adv withdrawn reason=helper')
	kill -STOP "$h"
	if d=$(wait_adv 0 70); then
		[ "$d" -le 6500 ] && ok "helper stopped: withdrawn after $(secs "$d") s (<= 65, L71)" || no "helper stopped: withdrawn only after $(secs "$d") s"
	else no "helper stopped: still advertising after 70 s"; fi
	[ "$(plc 'provd: adv withdrawn reason=helper')" -gt "$w" ] && ok "logged 'adv withdrawn reason=helper'" || no "no 'adv withdrawn reason=helper' line"
	kill -CONT "$h"; trap - EXIT HUP INT TERM
	if d=$(wait_adv 1 15); then ok "helper continued: registered again after $(secs "$d") s"; else no "helper continued: no instance within 15 s"; fi
	;;
sock-only)
	l=$(lastline 'provd: (frame socket|adv registered|test env)')
	case "$l" in *"provd: frame socket $TD/gatt.sock (SOCK_ONLY)") ok "the running provd serves $TD/gatt.sock (SOCK_ONLY)" ;; *) no "latest provd start line is not the frame socket: [${l##*]: }]" ;; esac
	l=$(ls -ldn "$TD" 2>/dev/null | awk '{print $1, $3, $4}'); [ "$l" = "drwx------ 471 471" ] && [ ! -L "$TD" ] && ok "$TD provd:provd 0700" || no "$TD [$l]"
	l=$(ls -ln "$TD/gatt.sock" 2>/dev/null | awk '{print $1, $3}'); [ "$l" = "srw------- 471" ] && ok "gatt.sock provd 0600" || no "gatt.sock [$l]"
	n=0; z=1; while [ $n -lt 10 ]; do [ "$(adv_instances)" = 0 ] || z=0; sleep 1; n=$((n + 1)); done
	[ $z = 1 ] && ok "no advertising instance for 10 s (SOCK_ONLY: no BLE)" || no "an advertising instance under SOCK_ONLY"
	;;
sockdir-root)
	p=$(provd_pid); f=$(logread | grep -c 'batman-provd\[[0-9]*\]: frame socket: .*refusing to bind')
	chown 0:0 "$TD"; kill -9 "$p"
	n=0; while [ $n -lt 20 ]; do [ "$(logread | grep -c 'batman-provd\[[0-9]*\]: frame socket: .*refusing to bind')" -gt "$f" ] && break; sleep 1; n=$((n + 1)); done
	l=$(logread | grep 'batman-provd\[[0-9]*\]: frame socket: .*refusing to bind' | tail -1)
	[ $n -lt 20 ] && ok "respawned provd refused the root-owned dir: ${l##*frame socket: }" || no "no 'refusing to bind' within 20 s of the respawn"
	netstat -lx 2>/dev/null | grep -q "$TD/gatt.sock" && no "something listens on $TD/gatt.sock" || ok "nothing listens on $TD/gatt.sock"
	;;
adv-len)
	n=0; while [ $n -lt 10 ]; do case "$(lastline 'adv: payload would be|provd: adv registered')" in *"adv: payload would be 29 B (max 28)") break ;; esac; sleep 1; n=$((n + 1)); done
	[ $n -lt 10 ] && ok "'adv: payload would be 29 B (max 28)' is the latest start line" || no "no ADV length refusal as the latest start line: [$(lastline 'adv: payload would be|provd: adv registered')]"
	n=0; z=1; while [ $n -lt 20 ]; do [ "$(adv_instances)" = 0 ] || z=0; sleep 1; n=$((n + 1)); done
	[ $z = 1 ] && ok "no advertising instance for 20 s" || no "an advertising instance despite the length refusal"
	;;
*) echo "FAIL usage: prov-p2-254.sh boot|stop|flip|respawn|dep-helper|dep-bluetoothd|dep-bluetoothd-kill|dep-dbus|dep-power|helper-stop|sock-only|sockdir-root|adv-len"; exit 2 ;;
esac
echo "PROV-P2 $a fails=$fails"
[ "$fails" = 0 ]
