# shellcheck shell=sh
# scripts/node/prov-p2-254.sh — #254 H3 node judge of batman-provd (docs/design/254-h23-harness.md §6.3, 254-p2-impl.md
# §5 / §9 / §21). Sent behind ble-lib-254.sh:  cat ble-lib-254.sh prov-p2-254.sh | ssh root@node sh -s -- <arm> [arg]
# Every check prints PASS / FAIL / INFO; the last line is "PROV-P2 <arm> fails=<n>"; exit 0 only with no FAIL.
# State-changing arms run under the host's prov lease and put back what they change themselves: the restore is the
# EXIT trap and HUP / INT / TERM only `exit 1` (so a cut-off arm restores and STOPS — 04 2026-11-01: traps without exit let
# judges whose ssh had timed out run on, overlap the next arms and the release, and leave bondable on), and SIGPIPE ignored so a dropped ssh cannot kill the shell between the change and the restore (review A-M1 /
# B-M1: an echo after the ssh died used to end the shell untrapped). Behind that, the host's pr_release and the lease
# deadman both run radio_restore (ble-lib-254.sh); preflight P9 FAILs on anything still left (radio_clean).
# Every wait has one deadline (no stacked inner waits) and the host's ssh limit is above the arm's worst case.
#   boot          read-only: provd runs as 471:471 under ujail, no capability, NoNewPrivs, jail without /etc/shadow
#                 but with its binary and the helper socket dir; no test switch in its environment (release init);
#                 health this boot with adv_registered_once=1 and the six preconditions; kernel instances = 1 with no
#                 LE link up (<= 1 with one); BlueZ not discoverable / pairable
#   stop          provd stopped -> instance gone <= 10 s ("adv withdrawn reason=stop"); two health ticks later
#                 adv_registered_once is still 1 (the latch, L2); started again -> provd_check
#   flip          bondable on -> instance withdrawn <= 9.5 s from the command, "adv withdrawn reason=health" (L67);
#                 bondable off -> registered again <= 15 s
#   respawn       kill -9 provd x5 (L8): each time a new pid <= 15 s (procd respawn 5 s), its instance and a new
#                 "adv registered reason=start" <= 15 s later. (h23's "backoff <n>s rising": a kill is procd's fixed
#                 5 s; provd's own backoff is for an unreachable helper — the helper-down arm.)
#   dep-helper    helper restarted (L11): provd keeps its pid, and 75 s later (past the 60 s stale limit) it is still
#                 advertising with no "withdrawn reason=helper" = it reconnected to the new helper; the new helper
#                 measured adv_registered_once=1
#   dep-bluetoothd | dep-bluetoothd-kill | dep-dbus [btmon]
#                 the dependency restarted (L9 / L65 / L10): a new "adv registered" and one instance <= 15 s after it is
#                 back (dbus: after bluetoothd's new pid and sc_file=1, the L10 split). With btmon (p2 §22.3 T4–T6, D3c):
#                 a clean restart removes the advertising before the old bluetoothd powers off; the new bluetoothd's
#                 first advertising-related command is Remove Advertising (before Set Powered / Add); no
#                 "Advertising: Enabled" before provd's own Add; the old instance's window is recorded
#   power-provdkill <btmon>
#                 p2 §21.5 T3 / L87: hci0 off and provd killed at once -> no instance left, and after power-on no
#                 "Advertising: Enabled" before the new provd's Add
#   dep-power <btmon>
#                 hci0 off (L84, p2 §21 T1): health hci0_powered=0, provd withdraws, the kernel lists no instance; on:
#                 btmon shows no "Advertising: Enabled" between power-on and provd's own re-registration (D3b; wsl.20
#                 re-enables the old instance at power-on = this arm's FAIL, the negative control)
#   power-bondable <btmon>
#                 L85 / §21 T2: hci0 off, bondable on while off, hci0 on -> 15 s with no "Advertising: Enabled", no
#                 instance, provd not registered; bondable off -> registered <= 15 s
#   sockdir-missing
#                 L77: helper stopped, its socket dir removed, provd restarted -> provd logs "… is not in the jail …
#                 exiting for a respawn" and does not advertise; helper started -> advertising <= 30 s
#   helper-stop   SIGSTOP the helper (L71 last row): withdrawn <= 65 s, "adv withdrawn reason=helper"; SIGCONT ->
#                 registered again <= 15 s
#   helper-down   the helper stopped (its socket refuses) for 40 s: provd's "helper ctl: connect failed (…); backoff
#                 <d>" lines rise 1s, 2s, 4s, 8s and stop at the 10 s cap (server.go ctl MaxBackoff), provd keeps its pid;
#                 the helper started -> provd re-signs (new helper boot_id), withdraws and registers again with
#                 reason=helper <= 75 s; the arm waits for it so the next arm starts from a settled provd
#   prov_test image only (after the host's set-provd-env):
#   sock-only     SOCK_ONLY=1: the serving line is the latest start line, no instance for 10 s, the frame socket dir
#                 provd 0700, gatt.sock provd 0600
#   sockdir-owner the socket dir made root:root 0755 (provd can open it, so only the owner / mode check can refuse),
#                 provd killed -> procd's respawn (the init does not run again) logs "owner 0 mode 755 (want 471 0700)
#                 — refusing to bind", and nothing listens
#   sockdir-link <decoy dir>  the socket dir replaced by a symlink to a provd 0700 decoy, then the test init's
#                 restart -> the init replaced the link by a real 471 0700 dir, provd bound there (a new "frame socket"
#                 start line), nothing created in the decoy. NOT a kill + respawn: procd respawns without the init's
#                 start_service and ujail's bind mount of the rw dir follows the host-side link, so the jail sees a real
#                 dir and checkSockDir's O_NOFOLLOW cannot see the link (04 wsl.21, 2026-11-01: gatt.sock appeared in the
#                 decoy). Only root can write /tmp/run, and the frame socket exists only in a prov_test build.
#   adv-len       ADV_LEN_TEST=29: "adv: payload would be 29 B (max 28)" is the latest start line, no instance 20 s
#   latch-neg     (while adv-len holds provd off the air) the helper restarted -> two fresh health ticks with
#                 adv_registered_once=0 (L2's negative: never registered -> 0)
#   nojail <W dir>  L72: a non-executable file bind-mounted over /sbin/ujail (its source in the harness wbox dir W, so
#                 prov-wbox unbind-all and the deadman remove it too), provd restarted -> requirejail: no provd process,
#                 no instance for 15 s; unbound, restarted -> provd_check
if [ -r /usr/lib/batman/rundir.sh ]; then . /usr/lib/batman/rundir.sh; else echo "FAIL no /usr/lib/batman/rundir.sh"; exit 1; fi
trap '' PIPE
HF=$RUNDIR/batman-prov.health
TD=/tmp/run/batman-provd-test
fails=0
ok() { echo "PASS $*"; }
no() { echo "FAIL $*"; fails=$((fails + 1)); }
info() { echo "INFO $*"; }
invl() { echo "INVALID $*"; }   # a precondition the arm needs did not hold: no verdict (the host counts it INVALID)
# hundredths of a second since boot; %.0f, not %d (busybox awk %d is 32-bit)
cs() { awk '{printf "%.0f", $1 * 100}' /proc/uptime; }
nap() { usleep 250000 2>/dev/null || sleep 1; }
secs() { echo "$1" | awk '{printf "%.2f", $1 / 100}'; }
hf() { [ -r "$HF" ] && echo " $(cat "$HF")" | sed -n "s/.* $1=\([^ ]*\).*/\1/p" | head -1; }
# provd log lines matching $1: how many in the ring. The tag is batman-provd[1] — provd is pid 1 of its ujail pid
# namespace (04 wsl.20, 2026-11-01) — so a line is never tied to a host pid: the arms compare counts / the latest line.
# Counted after THIS arm's syslog marker (MK, written at the start): a full ring drops old lines, and a count taken
# over the whole ring then need not grow (04, 2026-11-01; review A m6). lastline() reads the whole ring: it asks for the
# latest line, which a wrap cannot hide, and some arms judge a line written just before they started (set-provd-env).
plc() { logread | sed -n "/batman-dv-p2: mark $MK\$/,\$p" | grep -c "batman-provd\[[0-9]*\]: $1"; }
connected() { bluetoothctl devices Connected 2>/dev/null | clean | grep -c '^Device '; }
hpid() { pidof batman-provhelper | awk '{print $1}'; }
# wait_adv <want> <seconds>: hundredths it took (from the call); rc 1 when not reached
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
# health_tick <deadline uptime s> <after uptime s>: wait for a health line of this boot written at or after <after>
health_tick() {
	while [ "$(up_s)" -lt "$1" ]; do
		[ "$(hf boot_id)" = "$(bootid)" ] && [ "$(hf ts)" -ge "$2" ] 2>/dev/null && return 0; sleep 1
	done; return 1
}
# until_hf <seconds> <key> <value>: one deadline for a fresh health line carrying key=value
until_hf() {
	_d=$(( $(up_s) + $1 )); _a=$(up_s)
	while [ "$(up_s)" -lt "$_d" ]; do
		health_tick "$_d" "$_a" && [ "$(hf "$2")" = "$3" ] && return 0; _a=$(( $(up_s) + 1 )); sleep 1
	done; return 1
}
# listener on the frame socket: rc 0 yes, 1 no, 2 cannot tell (no netstat) — unreadable is never "nothing listens"
listens() { command -v netstat >/dev/null 2>&1 || return 2; _o=$(netstat -lx 2>/dev/null) || return 2; echo "$_o" | grep -q "$TD/gatt.sock"; }
# btmon capture for the power arms: start <btmon> -> $BM pid; stop -> the capture in $BMF
bm_start() { [ -x "$1" ] || { no "no btmon at [$1]"; return 1; }; BMF=$(mktemp "$H/p2bm.XXXXXX") || return 1; "$1" -T > "$BMF" 2>&1 & BM=$!; sleep 2; }
bm_stop() { [ -n "${BM:-}" ] && kill -INT "$BM" 2>/dev/null; sleep 1; BM=; }
# enable_before_add: in the capture, after the LAST "Powered: Enabled", an "Advertising: Enabled" that comes before
# the first MGMT Add Advertising / Add Extended Advertising Data (0x003e / 0x0055) = the kernel advertised on its own
enable_before_add() {
	awk '/Powered: Enabled \(0x01\)/ {p = NR} {l[NR] = $0} END {
		for (i = p + 1; i <= NR; i++) {
			if (l[i] ~ /MGMT Command \(0x003e\)|MGMT Command \(0x0055\)/) { print "add-first"; exit }
			if (l[i] ~ /Advertising: Enabled \(0x01\)/) { print "enable-first"; exit }
		}
		print (p ? "none" : "no-power-on") }' "$BMF"
}
# bm_first <pid> <opcode 4 hex>: line number of the first "MGMT Command (0x<op>)" sent by bluetoothd[<pid>] in the
# capture (btmon prints the sender "bluetoothd[pid]:"), 0 when none
bm_first() { awk -v p="bluetoothd[$1]" -v o="MGMT Command (0x$2)" 'index($0, p) && index($0, o) {print NR; f = 1; exit} END {if (!f) print 0}' "$BMF"; }
# bm_time <line>: the HH:MM:SS of that capture line (btmon -T puts the date / time at the end)
bm_time() { sed -n "${1}p" "$BMF" | grep -o '[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' | tail -1; }
hms() { echo "$1" | awk -F: '{print $1 * 3600 + $2 * 60 + $3}'; }
# bm_bluez <old pid> <new pid> <clean|crash>: p2 §22.3 on the capture. clean = T4 (D3c: the old bluetoothd removes
# its advertising before it powers off — the fix); crash = T5 / T6 (measurement only: the new bluetoothd's Reset, i.e.
# its Remove, comes before any Add, and the window the old instance kept transmitting is recorded and bounded)
bm_bluez() {
	if [ "$3" = clean ]; then
		r=$(bm_first "$1" 003f); s=$(bm_first "$1" 0005)
		[ "$r" -gt 0 ] && [ "$s" -gt 0 ] && [ "$r" -lt "$s" ] && ok "D3c: the old bluetoothd removed its advertising before powering off (capture lines $r < $s)" \
			|| no "D3c: no Remove Advertising before the old bluetoothd's Set Powered off (remove line $r, power line $s)"
		# and it took effect: the Command Complete for 0x003f after line r, before line s, says Success (review A m11).
		# btmon without a terminal truncates the event name: "@ MGMT Event: Com.. (0x0001)" (04, 2026-11-01)
		c=$(awk -v r="$r" -v s="$s" 'NR > r && NR < s && /MGMT Event: Com.*\(0x0001\)/ {cc = NR} cc && NR > cc && NR <= cc + 2 && /Remove Advertising \(0x003f\)/ {rm = NR} rm && NR > rm && NR <= rm + 2 && /Status: Success/ {print "ok"; exit}' "$BMF")
		[ "$c" = ok ] && ok "D3c: that Remove Advertising completed with Success before the power-off" || no "D3c: no Command Complete Success for the Remove before the power-off"
		return 0
	fi
	r=$(bm_first "$2" 003f); _ad=$(bm_first "$2" 0054); [ "$_ad" = 0 ] && _ad=$(bm_first "$2" 003e)   # not $a: the arm name
	[ "$r" -gt 0 ] && { [ "$_ad" = 0 ] || [ "$r" -lt "$_ad" ]; } && ok "the new bluetoothd removed the old instances (line $r) before any Add (line $_ad)" || no "the new bluetoothd sent no Remove before its first Add (remove $r, add $_ad)"
	if [ "$r" -gt 0 ]; then
		w=$(( $(hms "$(bm_time "$r")") - $(hms "$T_KILL") ))
		info "old instance window (measurement, p2 §22.3 T5/T6): $T_KILL -> the new bluetoothd's Remove at $(bm_time "$r") = ${w} s"
		[ "$w" -le 15 ] && ok "old instance window ${w} s (<= 15)" || no "old instance window ${w} s (> 15)"
	fi
}

a=${1:-}
MK="p2-$a-$(cs)-$(head -c 4 /dev/urandom | hexdump -v -e '/1 "%02x"')"; logger -t batman-dv-p2 "mark $MK"   # a log marker, not a path
o=$(p2_judges); [ -n "$o" ] && { echo "FAIL another H3 judge is still running (pid $o) — not overlapping it"; echo "PROV-P2 $a fails=1"; exit 1; }
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
		# the jail root is readable (its own binary is there) before its absences count (review B-m4)
		if [ -x "/proc/$p/root/usr/bin/batman-provd" ]; then
			[ ! -e "/proc/$p/root/etc/shadow" ] && ok "jail root has its binary and no /etc/shadow" || no "/etc/shadow visible in provd's root"
			[ -d "/proc/$p/root/tmp/run/batman-prov" ] && ok "helper socket dir mounted in the jail" || no "the helper socket dir is not in provd's root"
		else no "provd's root (/proc/$p/root) unreadable or without its binary"; fi
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
	info "provd log in the ring: $(plc 'provd: adv registered') registered, $(plc 'provd: adv withdrawn') withdrawn; last: $(lastline 'adv (registered|withdrawn)' | sed 's/.*provd: //')"
	;;
stop)
	trap 'provd_start' EXIT; trap 'exit 1' HUP INT TERM
	[ "$(hf adv_registered_once)" = 1 ] || no "precondition: adv_registered_once is not 1"
	w=$(plc 'provd: adv withdrawn reason=stop'); t0=$(cs)
	provd_stop
	if wait_adv 0 10 >/dev/null; then ok "provd stopped: no advertising instance after $(secs $(( $(cs) - t0 ))) s (<= 10)"; else no "provd stopped: an instance is still there after 10 s"; fi
	[ "$(plc 'provd: adv withdrawn reason=stop')" -gt "$w" ] && ok "logged 'adv withdrawn reason=stop'" || no "no 'adv withdrawn reason=stop' line"
	t=$(up_s); d=$((t + 80))
	if health_tick "$d" $((t + 16)) && health_tick "$d" $((t + 31)); then
		[ "$(hf adv_registered_once)" = 1 ] && ok "two health ticks later adv_registered_once is still 1 (latch, provd stopped)" || no "adv_registered_once fell to [$(hf adv_registered_once)] with provd stopped"
	else no "no two fresh health ticks within 80 s"; fi
	provd_start; trap - EXIT; trap - HUP INT TERM
	if o=$(provd_check); then ok "started again: $o"; else no "after the start: $o"; fi
	;;
flip)
	trap 'bluetoothctl mgmt.bondable off >/dev/null 2>&1' EXIT; trap 'exit 1' HUP INT TERM
	[ "$(adv_instances)" = 1 ] || no "precondition: no advertising instance"
	w=$(plc 'provd: adv withdrawn reason=health'); r=$(plc 'provd: adv registered')
	t0=$(cs); bluetoothctl mgmt.bondable on >/dev/null 2>&1	# timed from before the command (review B-m1)
	if wait_adv 0 12 >/dev/null; then d=$(( $(cs) - t0 ))
		[ "$d" -le 950 ] && ok "bondable on: withdrawn $(secs "$d") s after the command (<= 9.5, L67)" || no "bondable on: withdrawn after $(secs "$d") s (> 9.5)"
	else no "bondable on: still advertising after 12 s"; fi
	wait_line 'provd: adv withdrawn reason=health' "$w" 5 && ok "logged 'adv withdrawn reason=health'" || no "no 'adv withdrawn reason=health' line"
	t0=$(cs); bluetoothctl mgmt.bondable off >/dev/null 2>&1; trap - EXIT; trap - HUP INT TERM
	if wait_adv 1 15 >/dev/null && wait_line 'provd: adv registered' "$r" 5; then ok "bondable off: registered again $(secs $(( $(cs) - t0 ))) s after the command"; else no "bondable off: no instance / no new 'adv registered' within 15 s"; fi
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
dep-helper)
	trap 'pidof batman-provhelper >/dev/null || /etc/init.d/batman-provhelper start >/dev/null 2>&1' EXIT; trap 'exit 1' HUP INT TERM
	p=$(provd_pid); h=$(hpid); rs=$(plc 'helper boot_id changed: re-signing node_cert'); rh=$(plc 'provd: adv registered reason=helper')
	lim 60 /etc/init.d/batman-provhelper restart >/dev/null 2>&1
	n=0; x=""; while [ $n -lt 20 ]; do x=$(hpid); [ -n "$x" ] && [ "$x" != "$h" ] && break; sleep 1; n=$((n + 1)); done
	[ -n "$x" ] && [ "$x" != "$h" ] && ok "helper restarted (pid $h -> $x)" || no "helper did not come back with a new pid"
	t=$(up_s); until_hf 30 adv_registered_once 1 && ok "the new helper measured adv_registered_once=1" || no "after the helper restart adv_registered_once=[$(hf adv_registered_once)]"
	# provd reconnected to the NEW helper = it read the new helper's boot_id and re-signed node_cert (p2 §20 / L11:
	# a short "withdrawn reason=helper" + "registered reason=helper"); a provd that did not reconnect never sees the new
	# boot_id and, past the 60 s stale limit, withdraws for "helper" with nothing after it (as helper-stop shows)
	wait_line 'helper boot_id changed: re-signing node_cert' "$rs" 20 && wait_line 'provd: adv registered reason=helper' "$rh" 15 \
		&& ok "provd reconnected to the new helper: re-signed node_cert and registered again (reason=helper)" || no "provd did not re-sign / re-register after the helper restart (not reconnected?)"
	while [ "$(up_s)" -lt $((t + 75)) ]; do sleep 5; done
	l=$(lastline 'provd: adv (registered|withdrawn)')
	case "$l" in *"adv registered"*) [ "$(adv_instances)" = 1 ] && ok "75 s after the helper restart (past the 60 s stale limit) provd still advertises" || no "75 s after the helper restart: $(adv_instances) instance(s)" ;;
		*) no "75 s after the helper restart the latest provd advertising line is a withdraw: [${l##*provd: }]" ;; esac
	[ "$(provd_pid)" = "$p" ] && ok "provd kept running (pid $p)" || info "provd pid $p -> $(provd_pid)"
	trap - EXIT; trap - HUP INT TERM
	;;
dep-bluetoothd|dep-bluetoothd-kill|dep-dbus)
	trap 'bm_stop; pidof dbus-daemon >/dev/null || /etc/init.d/dbus start >/dev/null 2>&1; pidof bluetoothd >/dev/null || /etc/init.d/bluetoothd start >/dev/null 2>&1' EXIT; trap 'exit 1' HUP INT TERM
	BM=""; [ -n "${2:-}" ] && { bm_start "$2" || { echo "PROV-P2 $a fails=$fails"; exit 1; }; }
	# T4 / T5 / T6 need provd's instance registered first, or Remove(0) answers INVALID_PARAMS for an unrelated reason
	[ -n "${2:-}" ] && [ "$(adv_instances)" != 1 ] && invl "precondition: provd not advertising before the restart — the btmon assertions cannot judge"
	p=$(provd_pid); b=$(pidof bluetoothd); r=$(plc 'provd: adv registered'); x=""; T_KILL=$(date +%T)
	case "$a" in
	dep-bluetoothd|dep-bluetoothd-kill)
		if [ "$a" = dep-bluetoothd ]; then
			# stop / look / start (not restart): between the two, no instance may be left in the kernel (review A m11)
			lim 60 /etc/init.d/bluetoothd stop >/dev/null 2>&1; sleep 2
			n=$(adv_instances 2>/dev/null)
			if [ -n "$n" ]; then [ "$n" = 0 ] && ok "bluetoothd stopped: the kernel lists no advertising instance" || no "bluetoothd stopped: $n instance(s) left in the kernel (L9)"
			else info "bluetoothd stopped: advinfo not readable without bluetoothd (the Complete Success above is the evidence)"; fi
			lim 60 /etc/init.d/bluetoothd start >/dev/null 2>&1
		else kill -9 "$b"; fi
		n=0; while [ $n -lt 30 ]; do x=$(pidof bluetoothd); [ -n "$x" ] && [ "$x" != "$b" ] && break; sleep 1; n=$((n + 1)); done
		[ -n "$x" ] && [ "$x" != "$b" ] && ok "bluetoothd back (pid $b -> $x)" || no "bluetoothd did not come back with a new pid" ;;
	dep-dbus) lim 60 /etc/init.d/dbus restart >/dev/null 2>&1
		n=0; while [ $n -lt 60 ]; do x=$(pidof bluetoothd); [ -n "$x" ] && [ "$x" != "$b" ] && break; sleep 1; n=$((n + 1)); done
		[ -n "$x" ] && [ "$x" != "$b" ] && ok "bluetoothd followed the dbus restart (pid $b -> $x)" || no "bluetoothd did not restart after dbus (pid [$x])"
		until_hf 60 sc_file 1 && ok "sc_file=1 again (patch 900 rewrote batman-sc for the new bluetoothd)" || no "sc_file not 1 within 60 s of the dbus restart: [$(cat "$HF")]" ;;
	esac
	t0=$(cs)
	if wait_line 'provd: adv registered' "$r" 15 && wait_adv 1 5 >/dev/null; then ok "$a: a new 'adv registered' and one instance $(secs $(( $(cs) - t0 ))) s after the dependency was back (<= 15)"
	else no "$a: no new 'adv registered' / no instance within 15 s (instances $(adv_instances))"; fi
	q=$(provd_pid); [ "$q" = "$p" ] && ok "provd kept running (pid $p)" || info "provd pid $p -> $q"
	if [ -n "${2:-}" ]; then	# p2 §22.3 T4 (clean restart) / T5 (kill -9) / T6 (dbus restart)
		sleep 2; bm_stop
		x=$(pidof bluetoothd)	# the one that stayed (a dbus restart can respawn bluetoothd more than once)
		case "$a" in dep-bluetoothd) bm_bluez "$b" "$x" clean ;; *) bm_bluez "$b" "$x" crash ;; esac
		e=$(enable_before_add)
		case "$e" in add-first|none|no-power-on) ok "btmon: no 'Advertising: Enabled' before provd's own Add after the restart ($e)" ;;
			*) no "btmon: advertising enabled before provd re-registered (an old instance, p2 §22.1)" ;; esac
		rm -f "$BMF"
	fi
	trap - EXIT; trap - HUP INT TERM
	;;
adv-data)
	# what provd puts on the air, read on 04 itself (02's view of the "name" is BlueZ's per-address cache of the GAP
	# name from an earlier connection — not the advertisement; 2026-11-01): restart provd under btmon and judge the
	# advertising / scan-response data it registers: BlueZ's MGMT Add Extended Advertising Data (0x0055), the whole data
	# handed to the kernel. (Not the HCI LE Set Advertising Data: the kernel skips it when the data equals what the
	# controller already holds, hci_sync.c:1343 memcmp — a provd restart re-registers the same 21 bytes; 2026-11-01.)
	trap 'bm_stop' EXIT; trap 'exit 1' HUP INT TERM
	bm_start "${2:-}" || { echo "PROV-P2 $a fails=$fails"; exit 1; }
	r=$(plc 'provd: adv registered'); provd_restart
	wait_line 'provd: adv registered' "$r" 20 || no "provd did not register within 20 s of the restart"
	sleep 2; bm_stop
	# the last 0x0055 command block: its indented lines up to the next record (a line starting with @ < > =)
	ad=$(awk '/MGMT Command \(0x0055\)/ {b = ""; f = 1; next} f && /^[@<>=]/ {f = 0; last = b} f {b = b $0 "\n"} END {if (f) last = b; printf "%s", last}' "$BMF")
	if [ -z "$ad" ]; then no "btmon: no MGMT Add Extended Advertising Data (0x0055) after the restart"
	else
		echo "$ad" | grep -q 'Advertising data length: 21' && ok "advertising data: 21 bytes" || no "advertising data length: [$(echo "$ad" | grep -o 'Advertising data length: [0-9]*')] (want 21)"
		echo "$ad" | grep -q '128-bit Service UUIDs' && ok "advertising data carries the 128-bit service UUID list" || no "no 128-bit service UUID list in the advertising data"
		echo "$ad" | grep -qiE 'Name' && no "advertising data carries a name: $(echo "$ad" | grep -iE 'Name' | head -1)" || ok "no Local Name in the advertising data"
		echo "$ad" | grep -q 'Scan response length: 0' && ok "no scan response data" || no "scan response: [$(echo "$ad" | grep -o 'Scan response length: [0-9]*')] (want 0)"
	fi
	rm -f "$BMF"; trap - EXIT; trap - HUP INT TERM
	;;
power-provdkill)
	# p2 §21.5 T3 / L87: provd killed while hci0 is off, before its next health poll (<= 4 s) -> BlueZ's Remove for the
	# vanished client is the one that used to be dropped while off
	trap 'bm_stop; bluetoothctl power on >/dev/null 2>&1' EXIT; trap 'exit 1' HUP INT TERM
	bm_start "${2:-}" || { echo "PROV-P2 $a fails=$fails"; exit 1; }
	[ "$(adv_instances)" = 1 ] || no "precondition: provd not advertising"
	p=$(provd_pid); w=$(plc 'provd: adv withdrawn'); bluetoothctl power off >/dev/null 2>&1; kill -9 "$p"
	# the kill must beat provd's own health withdraw (<= 4 s poll), or this re-runs T1's path (design review A m7)
	[ "$(plc 'provd: adv withdrawn')" = "$w" ] && ok "hci0 off, provd $p killed before it withdrew" || invl "provd withdrew before the kill landed — this arm re-ran T1's path"
	sleep 8
	n=$(adv_instances); [ "$n" = 0 ] && ok "off + provd gone: the kernel lists no instance (D3b)" || no "off + provd gone: $n instance(s) left (p2 §21 L87)"
	r=$(plc 'provd: adv registered'); bluetoothctl power on >/dev/null 2>&1
	wait_line 'provd: adv registered' "$r" 30 && ok "powered on: the new provd registered" || no "powered on: no new 'adv registered' within 30 s"
	bm_stop
	e=$(enable_before_add)
	case "$e" in add-first|none) ok "btmon: no 'Advertising: Enabled' after power-on before provd's own Add ($e)" ;;
		enable-first) no "btmon: the kernel enabled the dead provd's instance at power-on (p2 §21 L87)" ;;
		*) no "btmon capture has no power-on ($e)" ;; esac
	rm -f "$BMF"; trap - EXIT; trap - HUP INT TERM
	;;
dep-power|power-bondable)
	trap 'bm_stop; bluetoothctl mgmt.bondable off >/dev/null 2>&1; bluetoothctl power on >/dev/null 2>&1' EXIT; trap 'exit 1' HUP INT TERM
	bm_start "${2:-}" || { echo "PROV-P2 $a fails=$fails"; exit 1; }
	w=$(plc 'provd: adv withdrawn')
	bluetoothctl power off >/dev/null 2>&1
	until_hf 30 hci0_powered 0 && ok "powered off: health hci0_powered=0" || no "powered off: health [$(cat "$HF")]"
	wait_line 'provd: adv withdrawn' "$w" 15 && ok "powered off: provd withdrew ($(lastline 'adv withdrawn' | sed 's/.*provd: //'))" || no "powered off: no new 'adv withdrawn' line within 15 s"
	n=$(adv_instances); [ "$n" = 0 ] && ok "powered off: the kernel lists no instance after provd's withdraw (D3b)" || no "powered off: the kernel still lists $n instance(s) after provd's withdraw (Remove Advertising dropped while off: p2 §21)"
	if [ "$a" = power-bondable ]; then bluetoothctl mgmt.bondable on >/dev/null 2>&1; has_tok "$(settings)" bondable && ok "bondable on while powered off" || no "bondable did not turn on while off"; fi
	r=$(plc 'provd: adv registered'); bluetoothctl power on >/dev/null 2>&1
	if [ "$a" = dep-power ]; then
		until_hf 30 hci0_powered 1 || no "powered on: health never hci0_powered=1"
		wait_line 'provd: adv registered' "$r" 20 && ok "powered on: provd registered again" || no "powered on: no new 'adv registered' within 20 s"
	else
		# bondable must stay on for the whole window, or the arm proves nothing (BlueZ PairableTimeout / agent paths may
		# turn it off: adapter.c:862-875, 9083-9090; design review A m6)
		k=0; lost=0; while [ $k -lt 15 ]; do has_tok "$(settings)" bondable || lost=1; sleep 1; k=$((k + 1)); done
		[ $lost = 0 ] || invl "bondable did not stay on for the 15 s window — T2 cannot judge"
		[ "$(adv_instances)" = 0 ] && ok "15 s after power-on with bondable on: no instance" || no "15 s after power-on with bondable on: $(adv_instances) instance(s) (fail-open, L85)"
		[ "$(plc 'provd: adv registered')" = "$r" ] && ok "provd did not register (health bondable=1)" || no "provd registered with bondable on"
	fi
	bm_stop
	e=$(enable_before_add)
	case "$e" in add-first|none) ok "btmon: no 'Advertising: Enabled' after power-on before provd's own Add Advertising ($e)" ;;
		enable-first) no "btmon: the kernel enabled advertising at power-on before provd registered (the old instance: p2 §21 L84/L85)" ;;
		*) no "btmon capture has no power-on ($e; $(wc -l < "$BMF") lines)" ;; esac
	rm -f "$BMF"
	if [ "$a" = power-bondable ]; then
		r=$(plc 'provd: adv registered'); t0=$(cs); bluetoothctl mgmt.bondable off >/dev/null 2>&1
		if wait_line 'provd: adv registered' "$r" 15 && wait_adv 1 5 >/dev/null; then ok "bondable off: provd registered $(secs $(( $(cs) - t0 ))) s later"; else no "bondable off: provd did not register within 15 s"; fi
	fi
	trap - EXIT; trap - HUP INT TERM
	;;
sockdir-missing)
	trap 'pidof batman-provhelper >/dev/null || /etc/init.d/batman-provhelper start >/dev/null 2>&1' EXIT; trap 'exit 1' HUP INT TERM
	m=$(plc 'provd: /tmp/run/batman-prov is not in the jail'); r=$(plc 'provd: adv registered')
	lim 60 /etc/init.d/batman-provhelper stop >/dev/null 2>&1; rm -rf /tmp/run/batman-prov
	provd_restart
	n=0; while [ $n -lt 20 ]; do [ "$(plc 'provd: /tmp/run/batman-prov is not in the jail')" -gt "$m" ] && break; sleep 1; n=$((n + 1)); done
	[ $n -lt 20 ] && ok "L77: provd logged '$(lastline 'is not in the jail' | sed 's/.*provd: //')'" || no "L77: no 'is not in the jail' line within 20 s"
	[ "$(adv_instances)" = 0 ] && ok "L77: no advertising without the helper socket dir" || no "L77: $(adv_instances) instance(s) without the helper socket dir"
	t0=$(cs); lim 60 /etc/init.d/batman-provhelper start >/dev/null 2>&1; trap - EXIT; trap - HUP INT TERM
	if wait_line 'provd: adv registered' "$r" 30 && wait_adv 1 5 >/dev/null; then ok "L77: helper back -> provd advertises $(secs $(( $(cs) - t0 ))) s later (respawn into a jail with the dir)"; else no "L77: provd not advertising 30 s after the helper came back"; fi
	;;
helper-stop)
	h=$(hpid); [ -n "$h" ] || { no "helper not running"; echo "PROV-P2 $a fails=$fails"; exit 1; }
	trap 'kill -CONT '"$h"' 2>/dev/null' EXIT; trap 'exit 1' HUP INT TERM
	w=$(plc 'provd: adv withdrawn reason=helper'); t0=$(cs)
	kill -STOP "$h"
	if wait_adv 0 70 >/dev/null; then d=$(( $(cs) - t0 ))
		[ "$d" -le 6500 ] && ok "helper stopped: withdrawn after $(secs "$d") s (<= 65, L71)" || no "helper stopped: withdrawn only after $(secs "$d") s"
	else no "helper stopped: still advertising after 70 s"; fi
	[ "$(plc 'provd: adv withdrawn reason=helper')" -gt "$w" ] && ok "logged 'adv withdrawn reason=helper'" || no "no 'adv withdrawn reason=helper' line"
	kill -CONT "$h"; trap - EXIT; trap - HUP INT TERM
	if d=$(wait_adv 1 15); then ok "helper continued: registered again after $(secs "$d") s"; else no "helper continued: no instance within 15 s"; fi
	;;
helper-down)
	p=$(provd_pid); [ -n "$p" ] && [ -n "$(hpid)" ] || { no "precondition: provd [$p] / helper [$(hpid)] not running"; echo "PROV-P2 $a fails=$fails"; exit 1; }
	trap '/etc/init.d/batman-provhelper start >/dev/null 2>&1' EXIT; trap 'exit 1' HUP INT TERM
	lim 60 /etc/init.d/batman-provhelper stop >/dev/null 2>&1; sleep 40
	# the backoff values in order, as provd printed them (Go time.Duration: 1s 2s 4s 8s 10s)
	b=$(logread | sed -n "/batman-dv-p2: mark $MK\$/,\$p" | sed -n 's/.*batman-provd\[[0-9]*\]: helper ctl: connect failed .*; backoff \([0-9]*\)s$/\1/p' | tr '\n' ' ')
	info "ctl backoffs in 40 s: [$b]"
	r=$(echo "$b" | awk '{ if (NF < 5) { print "only " NF " lines"; exit } if ($1 != 1) { print "first " $1 " s, not 1"; exit }
		for (i = 2; i <= NF; i++) { w = ($(i-1) * 2 > 10) ? 10 : $(i-1) * 2; if ($i != w) { print "line " i ": " $i " s after " $(i-1) " s (want " w ")"; exit } }
		if ($NF != 10) { print "never reached the 10 s cap"; exit } print "ok" }')
	[ "$r" = ok ] && ok "helper down: ctl backoff rose 1, 2, 4, 8 s to the 10 s cap ($(echo $b | wc -w) lines)" || no "helper down: backoff not 1, 2, 4, 8, 10…: $r [$b]"
	[ "$(provd_pid)" = "$p" ] && ok "provd kept its pid $p while the helper was down" || no "provd pid changed [$p -> $(provd_pid)] while the helper was down"
	rh=$(plc 'provd: adv registered reason=helper')
	lim 60 /etc/init.d/batman-provhelper start >/dev/null 2>&1; trap - EXIT; trap - HUP INT TERM
	# the new helper has a new boot_id: provd re-signs node_cert, withdraws (reason=helper) and registers again
	# (reason=helper) ~5-35 s later. The arm ends only once that is done: the next arm (dep-power) started inside it and
	# saw no withdraw of its own (04 wsl.21 2026-11-02: "helper boot_id changed" + "withdrawn reason=helper" in the same
	# second as dep-power's mark, registered 32 s later)
	if wait_line 'provd: adv registered reason=helper' "$rh" 60 && wait_adv 1 15 >/dev/null; then ok "helper started: provd re-signed and registered again (reason=helper), one instance"
	else no "helper started: no new 'adv registered reason=helper' + one instance within 75 s (latest: [$(lastline 'provd: adv (registered|withdrawn)' | sed 's/.*provd: //')])"; fi
	;;
sock-only)
	l=$(lastline 'provd: (frame socket|adv registered|test env)')
	case "$l" in *"provd: frame socket $TD/gatt.sock (SOCK_ONLY)") ok "the running provd serves $TD/gatt.sock (SOCK_ONLY)" ;; *) no "latest provd start line is not the frame socket: [${l##*]: }]" ;; esac
	l=$(ls -ldn "$TD" 2>/dev/null | awk '{print $1, $3, $4}'); [ "$l" = "drwx------ 471 471" ] && [ ! -L "$TD" ] && ok "$TD provd:provd 0700" || no "$TD [$l]"
	l=$(ls -ln "$TD/gatt.sock" 2>/dev/null | awk '{print $1, $3}'); [ "$l" = "srw------- 471" ] && ok "gatt.sock provd 0600" || no "gatt.sock [$l]"
	n=0; z=1; while [ $n -lt 10 ]; do [ "$(adv_instances)" = 0 ] || z=0; sleep 1; n=$((n + 1)); done
	[ $z = 1 ] && ok "no advertising instance for 10 s (SOCK_ONLY: no BLE)" || no "an advertising instance under SOCK_ONLY"
	;;
sockdir-link)
	dec=${2:?decoy dir}; [ -d "$dec" ] && [ ! -L "$dec" ] || { no "decoy [$dec] is not a directory"; echo "PROV-P2 $a fails=$fails"; exit 1; }
	chown 471:471 "$dec"; chmod 0700 "$dec"; f=$(plc 'provd: frame socket ')
	rm -rf "$TD"; ln -s "$dec" "$TD"; [ -L "$TD" ] || { no "could not place the symlink at $TD"; echo "PROV-P2 $a fails=$fails"; exit 1; }
	lim 30 "$PROVD_INIT" restart >/dev/null 2>&1
	wait_line 'provd: frame socket ' "$f" 20 && ok "provd bound again after the init's restart: $(lastline 'provd: frame socket ' | sed 's/.*provd: //')" || no "no new 'provd: frame socket' start line within 20 s of the init's restart"
	[ -L "$TD" ] && no "$TD is still a symlink after the init's start" || { [ "$(ls -ldn "$TD" | awk '{print $1, $3}')" = "drwx------ 471" ] && ok "the init replaced the link by a real 471 0700 dir" || no "$TD after the init's start: $(ls -ldn "$TD")"; }
	[ -z "$(ls -A "$dec" 2>/dev/null)" ] && ok "nothing created in the decoy behind the link" || no "the decoy got: $(ls -A "$dec" | tr '\n' ' ')"
	rm -rf "$dec"
	;;
sockdir-owner)
	p=$(provd_pid); f=$(plc 'frame socket: ')
	chown 0:0 "$TD"; chmod 0755 "$TD"; want="owner 0 mode 755 (want 471 0700)"
	kill -9 "$p"
	wait_line 'frame socket: ' "$f" 20 || true
	l=$(lastline ': frame socket: ' | sed 's/.*frame socket: //')
	case "$l" in *"$want"*) ok "respawned provd refused the dir: $l" ;; *) no "no refusal naming [$want] within 20 s of the respawn (latest: [$l])" ;; esac
	listens; case $? in 0) no "something listens on $TD/gatt.sock" ;; 1) ok "nothing listens on $TD/gatt.sock" ;; *) no "listeners unreadable (no netstat -lx)" ;; esac
	;;
adv-len)
	n=0; while [ $n -lt 10 ]; do case "$(lastline 'adv: payload would be|provd: adv registered')" in *"adv: payload would be 29 B (max 28)") break ;; esac; sleep 1; n=$((n + 1)); done
	[ $n -lt 10 ] && ok "'adv: payload would be 29 B (max 28)' is the latest start line" || no "no ADV length refusal as the latest start line: [$(lastline 'adv: payload would be|provd: adv registered')]"
	n=0; z=1; while [ $n -lt 20 ]; do [ "$(adv_instances)" = 0 ] || z=0; sleep 1; n=$((n + 1)); done
	[ $z = 1 ] && ok "no advertising instance for 20 s" || no "an advertising instance despite the length refusal"
	;;
latch-neg)
	[ "$(adv_instances)" = 0 ] || no "precondition: an advertising instance is registered (adv-len must hold provd off the air)"
	lim 60 /etc/init.d/batman-provhelper restart >/dev/null 2>&1
	t=$(up_s); d=$((t + 80))
	if health_tick "$d" $((t + 2)) && health_tick "$d" $(( $(hf ts) + 1 )); then
		[ "$(hf adv_registered_once)" = 0 ] && ok "L2 negative: a helper started while provd never registered reports adv_registered_once=0 (two ticks)" || no "adv_registered_once=[$(hf adv_registered_once)] although nothing registered since the helper started"
	else no "no two fresh health ticks within 80 s of the helper restart"; fi
	;;
nojail)
	W=${2:?wbox dir}; dir_ok "$W" drwx------ || { no "wbox dir [$W] is not a root 0700 dir"; echo "PROV-P2 $a fails=$fails"; exit 1; }
	trap 'umount /sbin/ujail 2>/dev/null' EXIT; trap 'exit 1' HUP INT TERM
	printf 'not an executable\n' > "$W/ujail.noexec"; chmod 0644 "$W/ujail.noexec"
	mount --bind "$W/ujail.noexec" /sbin/ujail || { no "bind over /sbin/ujail failed"; echo "PROV-P2 $a fails=$fails"; exit 1; }
	[ -x /sbin/ujail ] && no "ujail still executable after the bind" || ok "ujail made non-executable (bind from the wbox dir)"
	provd_stop; lim 30 "$PROVD_INIT" start >/dev/null 2>&1
	n=0; z=1; while [ $n -lt 15 ]; do [ -n "$(provd_pid)" ] && z=0; [ "$(adv_instances)" = 0 ] || z=0; sleep 1; n=$((n + 1)); done
	[ $z = 1 ] && ok "L72: without ujail no provd process and no instance for 15 s (requirejail)" || no "L72: provd ran / advertised without ujail (pid [$(provd_pid)], instances $(adv_instances))"
	umount /sbin/ujail; trap - EXIT; trap - HUP INT TERM; rm -f "$W/ujail.noexec"
	provd_restart; if o=$(provd_check); then ok "ujail back: $o"; else no "ujail back: $o"; fi
	;;
*) echo "FAIL usage: prov-p2-254.sh boot|stop|flip|respawn|dep-helper|dep-bluetoothd|dep-bluetoothd-kill|dep-dbus [btmon]|dep-power <btmon>|power-bondable <btmon>|power-provdkill <btmon>|sockdir-missing|helper-stop|helper-down|sock-only|sockdir-owner|sockdir-link <decoy>|adv-len|latch-neg|nojail <W>"; exit 2 ;;
esac
echo "PROV-P2 $a fails=$fails"
[ "$fails" = 0 ]
