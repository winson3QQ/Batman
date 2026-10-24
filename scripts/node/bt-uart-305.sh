#!/bin/sh
# scripts/node/bt-uart-305.sh — node side of the #305 mini UART flow-control tests (docs/design/305-mini-uart-flow.md
# §8 / §8a). Staged with ble-lib-254.sh and the #305 tools (scripts/dv-bt305-tools.sh) in
# /tmp/run/batman-dv/bt/<run_id>/ (root 0700) and run as:  RUN_ID=<id> sh <that dir>/bt-uart-305.sh <cmd> ...
#
#   gate                      transition short-circuit (§8 point 4): board / BATMAN_FEATURES marker / autoflow
#   flow [--flip]             T1  sysfs witness 0xcf, 0400, nobody denied (+ positive control), probe
#   load <secs> [--flip]      T2  hciflood + direct SD reads, no scan; judged on oe/fe/pe/bo + kmsg + probe + health
#   rebind <n> [--flip]       T3  n x unbind/bind: < 5 s, probe, exact CNTL sequence, security settings, kmsg
#   close [--flip]            T3b stuck TX (CNTL 0xcd) then unbind: < 5 s (normal) / >= 25 s (flip = no P2)
#   bootcheck                 T4  one boot: witness, probe, settings, no hci0 init error in this boot's kernel log
#   stage-check | acquire <s> | arm <s> | release | recover | dm-fire <run> <s> | state
#
# Every judgement line starts with PASS / FAIL / DET / FLIP / NOTE. The harness counts "FAIL" lines; flips are judged
# on the host (scripts/dv/bt-uart-305.sh) by WHICH lines failed. --flip runs only with BT305_FLIP_OK=1 (set by
# scripts/bt-uart-305-flip.sh, never by daily-validation). BT305_FORCE=1 bypasses the marker short-circuit (§8 pt 3).
set -u
SELF=$(readlink -f "$0"); DIR=$(dirname "$SELF")
. "$DIR/ble-lib-254.sh"
RUN_ID=${RUN_ID:-}
AF=${BT305_AF:-/sys/devices/platform/soc/fe215040.serial/autoflow}
SER=${BT305_SER:-/proc/tty/driver/serial}
DTC=${BT305_DTC:-/proc/device-tree/compatible}
BBUILD=${BT305_BBUILD:-/etc/batman-build}
KMSG=${BT305_KMSG:-$DIR/kmsg.txt}		# the self-test (scripts/test-dv-bt-uart-305.sh) points these at fixtures
DRV=/sys/bus/serial/drivers/hci_uart_bcm
MARK='mini-uart-autoflow(#305)'
PROBE=$DIR/btprobe; FLOOD=$DIR/hciflood; RAW=$DIR/r305raw.ko; NOP2=$DIR/hci_uart-noP2.ko
FORCE=${BT305_FORCE:-0}
FAILS=0
pass() { echo "PASS $*"; }
no() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }
ms() { cut -d' ' -f1 /proc/uptime | tr -d . ; }		# centiseconds since boot
flip_ok() { [ "${BT305_FLIP_OK:-0}" = 1 ] || die "--flip needs BT305_FLIP_OK=1 (scripts/bt-uart-305-flip.sh); refused"; }
NB() { start-stop-daemon -S -c nobody -n bt305nb -a /bin/sh -- -c "$1"; }	# busybox has no su (tmp-trust-280.sh:19)

# ---- the transition short-circuit (§8 point 4) ---------------------------------------------------------------------
gate() {
	case "$(tr '\0' ' ' < "$DTC" 2>/dev/null)" in *brcm,bcm2711*) ;; *) echo "NA not a bcm2711 board"; return 2;; esac
	f=$(sed -n 's/^BATMAN_FEATURES=//p' "$BBUILD" 2>/dev/null)
	has=0; case ",$f," in *",$MARK,"*) has=1;; esac
	if [ "$FORCE" = 1 ]; then echo "NOTE --force: marker=$has (short-circuit bypassed)"; return 0; fi
	[ "$has" = 1 ] || { echo "FAIL pre-305 image: test not applicable to this kernel"; return 1; }
	[ -e "$AF" ] || { echo "FAIL autoflow missing on a 305 image"; return 1; }
	return 0
}

# ---- readers -------------------------------------------------------------------------------------------------------
af_get() {	# $1 path -> AF_HW AF_CACHE AF_W AF_LAST (empty when unreadable)
	AF_HW=""; AF_CACHE=""; AF_W=""; AF_LAST=""
	l=$(cat "${1:-$AF}" 2>/dev/null) || return 1
	AF_HW=$(echo "$l" | sed -n 's/.*hw=\(0x[0-9a-f]*\).*/\1/p'); AF_CACHE=$(echo "$l" | sed -n 's/.*cache=\(0x[0-9a-f]*\).*/\1/p')
	AF_W=$(echo "$l" | sed -n 's/.*writes=\([0-9]*\).*/\1/p'); AF_LAST=$(echo "$l" | sed -n 's/.*last=\([0-9a-fx,]*\).*/\1/p')
	[ -n "$AF_HW" ] && [ -n "$AF_CACHE" ] && isint "$AF_W"
}
# the last <k> entries of a "last=" list (comma separated, oldest first)
tail_k() { echo "$1" | tr ',' '\n' | tail -n "$2" | tr '\n' ',' | sed 's/,$//'; }
ser_get() {	# the mini UART line of /proc/tty/driver/serial -> S_OE S_FE S_PE S_BO S_RX; rc 1 if the line is missing
	l=$(grep '^0: uart:16550 mmio:0xFE215040' "$SER" 2>/dev/null) || return 1
	for k in oe fe pe bo rx; do
		v=$(echo "$l" | sed -n "s/.* $k:\([0-9]*\).*/\1/p"); [ -n "$v" ] || v=0
		eval "S_$(echo "$k" | tr a-z A-Z)=\$v"
	done
}
sd_reads() { awk '$3 == "mmcblk0" { print $6 }' /proc/diskstats; }
probe() { PR=$(lim 10 "$PROBE" 2>&1); case "$PR" in *hci_version=status0*) return 0;; esac; return 1; }
settings_ok() {	# from the last probe line
	s=$(echo "$PR" | sed -n 's/.*settings=\([^ ]*\).*/\1/p')
	case ",$s," in *,privacy,*) ;; *) echo "settings [$s] without privacy"; return 1;; esac
	case ",$s," in *,secure-conn,*) ;; *) echo "settings [$s] without secure-conn"; return 1;; esac
	case ",$s," in *,bondable,*) echo "settings [$s] with bondable"; return 1;; esac
	return 0
}
health_ok() {	# helper health line: bondable=0 privacy=1 sc=1, written this boot
	[ -r /usr/lib/batman/rundir.sh ] && . /usr/lib/batman/rundir.sh
	h=$(cat "${RUNDIR:-/nonexistent}/batman-prov.health" 2>/dev/null)
	case "$h" in *"boot_id=$(bootid)"*) ;; *) echo "health line not of this boot: [$h]"; return 1;; esac
	case " $h " in *" bondable=0 "*) ;; *) echo "health bondable != 0: [$h]"; return 1;; esac
	case " $h " in *" privacy=1 "*) ;; *) echo "health privacy != 1"; return 1;; esac
	case " $h " in *" sc=1 "*) ;; *) echo "health sc != 1"; return 1;; esac
	return 0
}

# ---- kernel log capture from the start of a test (A v5 m1, A v6 m11): start / end marker lines, capture must live --
kmsg_start() {
	rm -f "$KMSG"
	setsid sh -c "exec cat /dev/kmsg" > "$KMSG" 2>&1 < /dev/null &
	sleep 1; pg=$(cut -d' ' -f5 "/proc/$!/stat" 2>/dev/null); isint "$pg" || die "kmsg capture did not start"
	echo "$pg" > "$DIR/kmsg.pg"
	echo "bt305: start $RUN_ID $1" > /dev/kmsg; sleep 1
}
kmsg_mark() { echo "bt305: mark $RUN_ID $1" > /dev/kmsg; }
kmsg_stop() {	# -> KM_OK=1 when both markers are in the capture and the reader was alive to the end
	echo "bt305: end $RUN_ID" > /dev/kmsg; sleep 1
	KM_OK=0; alive=0; pg=$(cat "$DIR/kmsg.pg" 2>/dev/null)
	isint "$pg" && for s in /proc/[0-9]*/stat; do [ "$(cut -d' ' -f5 "$s" 2>/dev/null)" = "$pg" ] && alive=1 && break; done
	[ "$alive" = 1 ] && pg_kill "$pg"; rm -f "$DIR/kmsg.pg"
	grep -q "bt305: start $RUN_ID" "$KMSG" && grep -q "bt305: end $RUN_ID" "$KMSG" && [ "$alive" = 1 ] && KM_OK=1
	grep -q 'Broken pipe' "$KMSG" && KM_OK=0		# ring overrun: the reader got EPIPE
}
km_count() {	# $1 ERE, [$2 from-marker tag] [$3 to-marker tag]: matching hci0 lines between markers
	awk -v re="$1" -v a="${2:-}" -v b="${3:-}" -v r="$RUN_ID" '
		index($0, "bt305: start " r) { on = (a == "") }
		a != "" && index($0, "bt305: mark " r " " a) { on = 1; next }
		b != "" && index($0, "bt305: mark " r " " b) { on = 0 }
		index($0, "bt305: end " r) { on = 0 }
		on && $0 ~ re { n++ } END { print n + 0 }' "$KMSG"
}

# ---- background load (A v6 m2): every group recorded for kill_run_groups / the deadman ------------------------------
bg() {	# $1 name, rest = command (the command limits its own run time)
	n=$1; shift; setsid "$@" > "$DIR/$n.out" 2>&1 < /dev/null &
	sleep 1; pg=$(cut -d' ' -f5 "/proc/$!/stat" 2>/dev/null); isint "$pg" || { no "background $n did not start"; return 1; }
	echo "$pg" > "$DIR/$n.pg"
}
bg_stop() {	# $1 name -> FAIL cleanup if a member survives
	pg=$(cat "$DIR/$1.pg" 2>/dev/null); rm -f "$DIR/$1.pg"
	isint "$pg" || return 0
	pg_kill "$pg" || no "cleanup: $1 group $pg survived"
}

# ---- module swap for the T3 / T3b negative controls (B v5 m3, A v6 m3) ---------------------------------------------
swap_nop2() {
	f=$(sed -n 's/^BATMAN_FW_COMMIT=//p' "$BBUILD")
	[ "$(cat "$DIR/FWCOMMIT" 2>/dev/null)" = "$f" ] || die "hci_uart-noP2.ko was built for firmware $(cat "$DIR/FWCOMMIT" 2>/dev/null), node is $f"
	mark_set bt305-dirty "module hci_uart-noP2 loaded"
	rmmod hci_uart 2>&1 | sed 's/^/NOTE rmmod: /'
	grep -q '^hci_uart ' /proc/modules && die "hci_uart still loaded after rmmod"
	insmod "$NOP2" 2>&1 | sed 's/^/NOTE insmod: /'
	grep -q '^hci_uart ' /proc/modules || die "insmod of hci_uart-noP2.ko failed"
	n=0; while [ $n -lt 30 ]; do probe && break; sleep 1; n=$((n + 1)); done
	probe && echo "FLIP module hci_uart-noP2 loaded (no P2), controller up after ${n}s" || die "controller did not come up on hci_uart-noP2"
}
raw_write() {	# $1 value: CNTL <- value | RXEN behind the driver's back; rmmod right away (A v6 m4)
	mark_set bt305-dirty "CNTL raw-written"
	insmod "$RAW" "cntl=$1" || die "insmod r305raw cntl=$1 failed"
	rmmod r305raw || die "rmmod r305raw failed"
}
raw_regs() {	# read-only register dump -> RAW_LINE
	insmod "$RAW" && rmmod r305raw || { RAW_LINE=""; return 1; }
	RAW_LINE=$(dmesg | grep 'r305raw before:' | tail -1)
}

# ---- T1 -------------------------------------------------------------------------------------------------------------
cmd_flow() {
	gate || return 1
	p=$AF; [ "${1:-}" = --flip ] && { flip_ok; p=$AF.bt305-flip-absent; echo "FLIP T1: reading $p"; }
	[ -e "$p" ] || { no "autoflow missing ($p)"; return 1; }
	m=$(ls -l "$p" | cut -c1-10); [ "$m" = "-r--------" ] && pass "mode $m" || no "mode $m (want -r--------, 0400)"
	af_get "$p" || no "autoflow unreadable"
	[ "$AF_HW" = 0xcf ] && [ "$AF_CACHE" = 0xcf ] && pass "hw=$AF_HW cache=$AF_CACHE writes=$AF_W" || no "hw=$AF_HW cache=$AF_CACHE (want 0xcf / 0xcf)"
	[ "$(NB 'id -u')" = 65534 ] && pass "nobody switch runs as uid 65534" || no "start-stop-daemon did not run as nobody: the non-root steps prove nothing"
	case "$(NB 'cat /proc/version')" in Linux*) pass "nobody positive control: /proc/version readable";; *) no "nobody positive control failed: /proc/version not readable as nobody";; esac
	if NB "cat $p" >/dev/null 2>&1; then no "nobody can read $p"; else pass "nobody cannot read $p"; fi
	probe && pass "probe: $PR" || no "probe: $PR"
	[ "$FAILS" = 0 ]
}

# ---- T2 -------------------------------------------------------------------------------------------------------------
cmd_load() {
	isint "${1:-}" || die "usage: load <secs> [--flip]"; dur=$1; flip=0; [ "${2:-}" = --flip ] && { flip_ok; flip=1; }
	held; unlock
	gate || return 1
	ser_get || { no "no '0: uart:16550 mmio:0xFE215040' line in $SER"; return 1; }
	if [ $flip = 1 ]; then
		raw_write 0x02; af_get || true
		[ "$AF_HW" = 0x03 ] && [ "$AF_CACHE" = 0xcf ] && echo "FLIP T2: CNTL forced to 0x03 (cache $AF_CACHE)" || die "flip injection did not hold: hw=$AF_HW cache=$AF_CACHE"
	fi
	af_get || true; w0=$AF_W
	kmsg_start load
	ser_get; oe0=$S_OE; fe0=$S_FE; pe0=$S_PE; bo0=$S_BO; rx0=$S_RX; sd0=$(sd_reads); sdseg=$sd0
	bg sdload sh -c "e=\$((\$(cut -d. -f1 /proc/uptime) + $dur)); while [ \$(cut -d. -f1 /proc/uptime) -lt \$e ]; do dd if=/dev/mmcblk0p2 of=/dev/null bs=64k count=4096 iflag=direct 2>/dev/null; done" || return 1
	bg flood "$FLOOD" "$dur" || { bg_stop sdload; return 1; }
	t=0; pf=0; seg=0
	while [ $t -lt "$dur" ]; do
		sleep 15; t=$((t + 15))
		probe || pf=$((pf + 1))
		r=$(health_ok) || no "health at +${t}s: $r"
		if [ $flip = 1 ]; then af_get || true; { [ "$AF_HW" = 0x03 ] && [ "$AF_CACHE" = 0xcf ] && [ "$AF_W" = "$w0" ]; } || no "flip not held at +${t}s: hw=$AF_HW cache=$AF_CACHE writes=$AF_W (was $w0)"; fi
		if [ $((t % 300)) = 0 ]; then
			s=$(sd_reads); seg=$((seg + 1)); d=$((s - sdseg)); sdseg=$s
			[ "$d" -ge 10000000 ] && echo "NOTE SD segment $seg: $d sectors" || no "load-sd: segment $seg read $d sectors < 10000000"
		fi
	done
	n=0; while [ $n -lt 40 ] && ! grep -q '^hciflood secs=' "$DIR/flood.out" 2>/dev/null; do sleep 1; n=$((n + 1)); done
	bg_stop flood; bg_stop sdload
	kmsg_stop
	ser_get || no "mini UART line vanished"
	fr=$(km_count 'hci0: Frame reassembly'); to=$(km_count 'hci0: .*tx timeout')
	doe=$((S_OE - oe0)); dfe=$((S_FE - fe0)); dpe=$((S_PE - pe0)); dbo=$((S_BO - bo0)); rate=$(( (S_RX - rx0) / dur ))
	fl=$(grep '^hciflood secs=' "$DIR/flood.out" 2>/dev/null); ok=$(echo "$fl" | sed -n 's/.* ok=\([0-9]*\).*/\1/p'); miss=$(echo "$fl" | sed -n 's/.* miss=\([0-9]*\).*/\1/p')
	echo "DET oe=+$doe fe=+$dfe pe=+$dpe bo=+$dbo frame=+$fr txto=+$to probe_fail=$pf rx_rate=$rate flood=[$fl] sd_total=$(( $(sd_reads) - sd0 ))"
	[ "$KM_OK" = 1 ] || no "kmsg capture incomplete (markers missing, reader died or ring overrun)"
	[ "$doe" = 0 ] || no "det-oe +$doe"
	[ "$dfe" = 0 ] || no "det-fe +$dfe"
	[ "$dpe" = 0 ] || no "det-pe +$dpe"
	[ "$dbo" = 0 ] || no "det-bo +$dbo"
	[ "$fr" = 0 ] || no "det-frame +$fr"
	[ "$to" = 0 ] || no "det-txto +$to"
	[ "$pf" = 0 ] || no "det-probe $pf probe failures"
	[ "$rate" -ge 10000 ] || no "load-rx ${rate} B/s < 10000"
	isint "$ok" && isint "$miss" && [ "$ok" -gt 0 ] && [ $((miss * 100)) -le "$ok" ] || no "load-flood ok=$ok miss=$miss (miss must be <= 1%)"
	if [ $flip = 1 ]; then rebind_once >/dev/null; af_get || true; [ "$AF_HW" = 0xcf ] && [ "$AF_CACHE" = 0xcf ] && { echo "FLIP restored by rebind: hw=cache=0xcf"; mark_clear bt305-dirty; } || no "flip restore: hw=$AF_HW cache=$AF_CACHE after rebind"; fi
	[ "$FAILS" = 0 ]
}

# ---- T3 -------------------------------------------------------------------------------------------------------------
rebind_once() {	# -> RB_UMS RB_UNB (entries written by unbind) RB_BND (by bind) RB_UP (probe ok)
	af_get || true; w0=$AF_W
	t0=$(ms); echo serial0-0 > "$DRV/unbind"; t1=$(ms); RB_UMS=$(( (t1 - t0) * 10 ))
	af_get || true; w1=$AF_W; RB_UNB=$(tail_k "$AF_LAST" $((w1 - w0)))
	sleep 2; echo serial0-0 > "$DRV/bind"
	n=0; RB_UP=0; while [ $n -lt 20 ]; do sleep 1; n=$((n + 1)); probe && { RB_UP=1; break; }; done
	af_get || true; w2=$AF_W; RB_BND=$(tail_k "$AF_LAST" $((w2 - w1)))
}
cmd_rebind() {
	isint "${1:-}" || die "usage: rebind <n> [--flip]"; k=$1; flip=0; [ "${2:-}" = --flip ] && { flip_ok; flip=1; }
	held; unlock
	gate || return 1
	[ $flip = 1 ] && swap_nop2
	kmsg_start rebind
	i=0; while [ $i -lt "$k" ]; do
		i=$((i + 1))
		lock 30 && { lease_write "$RUN_ID" 180; dm_arm "$RUN_ID" 185 "$SELF"; unlock; }		# deadman per rebind (B v6)
		kmsg_mark "r$i"; rebind_once; kmsg_mark "e$i"
		e=$(km_count 'hci0: .*(tx timeout|failed)' "r$i" "e$i")
		echo "DET rebind $i: unbind=${RB_UMS}ms unbind_writes=[$RB_UNB] bind_writes=[$RB_BND] probe_up=$RB_UP kmsg_err=$e"
		[ "$RB_UMS" -lt 5000 ] || no "rebind $i: unbind took ${RB_UMS} ms"
		[ "$RB_UP" = 1 ] || no "rebind $i: no probe answer within 20 s ($PR)"
		[ "$RB_UNB" = 0x03 ] || no "seq-unbind $i: [$RB_UNB] (want [0x03])"
		[ "$RB_BND" = "0xcf,0x03,0x8b,0xcf" ] || no "seq-bind $i: [$RB_BND] (want [0xcf,0x03,0x8b,0xcf])"
		r=$(settings_ok) || no "rebind $i: $r"
		[ "$e" = 0 ] || no "rebind $i: $e hci0 tx timeout / failed lines"
		[ -e /sys/class/bluetooth/hci0 ] || no "rebind $i: hci0 is gone (index moved?)"
		if [ "$RB_UP" != 1 ]; then rebind_once; [ "$RB_UP" = 1 ] && echo "NOTE rebind $i: recovered by a second rebind" || { echo "NOTE rebind $i: still down — the harness reboots this node"; break; }; fi
	done
	kmsg_stop; [ "$KM_OK" = 1 ] || no "kmsg capture incomplete"
	[ $flip = 1 ] && echo "NEEDS-REBOOT hci_uart-noP2 is loaded"
	[ "$FAILS" = 0 ]
}

# ---- T3b ------------------------------------------------------------------------------------------------------------
cmd_close() {
	flip=0; [ "${1:-}" = --flip ] && { flip_ok; flip=1; }
	held; unlock
	gate || return 1
	[ $flip = 1 ] && swap_nop2
	raw_write 0xcc; probe; probe						# 0xcd: AUTO* on, TXEN off -> the FIFO fills and stays
	raw_regs; tf=$(echo "$RAW_LINE" | sed -n 's/.*tx_fill=\([0-9]*\).*/\1/p'); c=$(echo "$RAW_LINE" | sed -n 's/.*CNTL=\(0x[0-9a-f]*\).*/\1/p')
	{ [ "$c" = 0xcd ] && isint "$tf" && [ "$tf" -gt 0 ]; } || { no "inject: CNTL=$c tx_fill=$tf (want 0xcd, > 0) — nothing was stuck, test invalid"; echo "NEEDS-REBOOT"; return 1; }
	echo "DET injected CNTL=$c tx_fill=$tf"
	t0=$(ms); echo serial0-0 > "$DRV/unbind"; t1=$(ms); d=$(( (t1 - t0) * 10 ))
	echo "DET stuck-TX unbind took ${d} ms"
	if [ $flip = 1 ]; then [ "$d" -ge 25000 ] && echo "FLIP close waited ${d} ms without P2" || no "flip-invalid: without P2 the close took only ${d} ms (want >= 25000)"
	else [ "$d" -lt 5000 ] && pass "close ${d} ms < 5000" || no "close-wait ${d} ms (want < 5000)"; fi
	echo "NEEDS-REBOOT CNTL raw-written, hci0 unbound"
	[ "$FAILS" = 0 ]
}

# ---- T4 (one boot) --------------------------------------------------------------------------------------------------
cmd_bootcheck() {
	gate || return 1
	u=$(up_s); [ "$u" -ge 60 ] || { no "uptime ${u}s < 60: too early"; return 1; }
	af_get || no "autoflow unreadable"
	[ "$AF_HW" = 0xcf ] && [ "$AF_CACHE" = 0xcf ] && pass "hw=cache=0xcf writes=$AF_W" || no "hw=$AF_HW cache=$AF_CACHE"
	probe && pass "probe ok" || no "probe: $PR"
	r=$(settings_ok) && pass "settings privacy, secure-conn, no bondable" || no "$r"
	e=$(dmesg | grep -cE 'hci0: .*(tx timeout|failed)'); [ "$e" = 0 ] && pass "no hci0 init error this boot" || no "init: $e hci0 tx timeout / failed lines this boot"
	[ "$FAILS" = 0 ]
}

# ---- framework (same contract as ble-periph-254.sh) -----------------------------------------------------------------
cmd_stage_check() {
	dir_ok "$DIR" drwx------ || die "$DIR is not a root 0700 directory"
	for t in "$DIR/ble-lib-254.sh" "$SELF" "$PROBE" "$FLOOD"; do file_ok "$t" || die "$t is not a root regular file with one link"; done
	for t in "$RAW" "$NOP2" "$DIR/FWCOMMIT"; do [ -e "$t" ] && { file_ok "$t" || die "$t is not a root regular file with one link"; }; done
	sha256sum "$DIR"/* 2>/dev/null | sed "s#$DIR/##" | grep -v ' kmsg.txt$\| .*\.out$\| .*\.pg$'
	echo "STAGE ok"
}
role_fire_restore() {	# deadman / recover: stop every group; a raw CNTL write or a swapped module => reboot
	if mark_here bt305-dirty; then
		dm_log "$1" "deadman: $(cut -d' ' -f2- "$ST/bt305-dirty") — reboot to restore (#305)"
		rm -f "$BT/lease" "$ST/dm" "$ST/dm.new"
		batman-slot reboot committed bt305-dm; exit 0
	fi
	grep -q '^r305raw ' /proc/modules && rmmod r305raw
	[ -e /sys/class/bluetooth/hci0 ] || { echo serial0-0 > "$DRV/bind" 2>/dev/null; sleep 15; }
}

[ "${BT305_LIB_ONLY:-0}" = 1 ] && return 0 2>/dev/null
c=${1:-}; [ $# -gt 0 ] && shift
case "$c" in
	dm-fire) cmd_dm_fire "$@" ;;
	gate) gate ;;
	flow) cmd_flow "$@" ;;
	bootcheck) cmd_bootcheck ;;
	*)
		[ -n "$RUN_ID" ] && [ "$(basename "$DIR")" = "$RUN_ID" ] || die "RUN_ID must name this script's directory"
		case "$c" in
			stage-check) cmd_stage_check ;;
			acquire) cmd_acquire "$@" ;;
			arm) cmd_arm "$@" ;;
			release) cmd_release ;;
			state) ble_state ;;
			recover) cmd_recover ;;
			load) cmd_load "$@" ;;
			rebind) cmd_rebind "$@" ;;
			close) cmd_close "$@" ;;
			*) die "unknown command: $c" ;;
		esac ;;
esac
