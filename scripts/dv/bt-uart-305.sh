# shellcheck shell=bash
# scripts/dv/bt-uart-305.sh — the #305 mini UART flow-control suites, sourced by daily-validation.sh and by
# scripts/bt-uart-305-flip.sh (docs/design/305-mini-uart-flow.md §8 / §8a). Node side: scripts/node/bt-uart-305.sh.
#   tier A : chk_bt_uart_flow_305 <node...>     T1 (read-only)
#            chk_bt_uart_rebind_305 <node...>   T3 (10 rebinds under the BLE lease + deadman)
#   tier B : bchk_bt_uart_load_305 <node...>    T2 (BT305_LOAD_SECS, default 1800, per node, in order)
#            bchk_bt_uart_close_305 <node>      T3b (stuck TX + unbind; reboots the node)
#            bchk_bt_uart_boot_305 <node>       T4 (BT305_BOOTS, default 20, loaded reboots)
# Tools: scripts/dv-bt305-tools.sh <firmware tree> -> $DV_BT305_TOOLS_ROOT/bt305-<fwcommit>/ (SHA256SUMS). Kernel
# modules are only staged when the directory's FWCOMMIT equals the node's BATMAN_FW_COMMIT; the Go tools are generic.
# Every FAIL line starts with "FAIL".
BT305_ROOT=${DV_BT305_TOOLS_ROOT:-$HOME/batman-dv-tools}
BT305_SSHO=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR -o ConnectTimeout=8)
BT305_LOAD_SECS=${BT305_LOAD_SECS:-1800}
BT305_BOOTS=${BT305_BOOTS:-20}

bt305_ssh() { local n=$1 t=$2; shift 2; timeout "$t" ssh "${BT305_SSHO[@]}" "root@$n" "$@"; }
bt305_fw() { bt305_ssh "$1" 20 'sed -n "s/^BATMAN_FW_COMMIT=//p" /etc/batman-build' | tr -d '\r'; }
bt305_run_id() { echo "bt305-$(date +%H%M%S)-$RANDOM"; }

# bt305_stage <node> <run_id>: run dir + scripts + tools; sha of every staged file must equal the host copy
bt305_stage() {
	local n=$1 run=$2 fw d go f files o h
	fw=$(bt305_fw "$n"); [ -n "$fw" ] || { echo "FAIL $n: BATMAN_FW_COMMIT unreadable"; return 1; }
	d=$BT305_ROOT/bt305-$fw
	go=$(ls -d "$BT305_ROOT"/bt305-* 2>/dev/null | head -1)
	[ -n "$go" ] && [ -f "$go/btprobe" ] && [ -f "$go/hciflood" ] || { echo "FAIL no #305 tools under $BT305_ROOT (scripts/dv-bt305-tools.sh <firmware tree>)"; return 1; }
	[ -f "$d/SHA256SUMS" ] && go=$d
	files=("$REPO/scripts/node/ble-lib-254.sh" "$REPO/scripts/node/bt-uart-305.sh" "$go/btprobe" "$go/hciflood")
	if [ -f "$d/SHA256SUMS" ]; then
		(cd "$d" && sha256sum -c --quiet SHA256SUMS) || { echo "FAIL $d does not match its SHA256SUMS"; return 1; }
		files+=("$d/r305raw.ko" "$d/hci_uart-noP2.ko" "$d/FWCOMMIT")
	else echo "NOTE no tools built for firmware $fw: kernel modules not staged (pre-#305 image or unbuilt rc)"; fi
	{ cat "$REPO/scripts/node/ble-lib-254.sh"; echo "scratch; d=\$BT/$run; [ -e \"\$d\" ] && { echo \"FAIL \$d exists\"; exit 1; }; mkdir -m 700 \"\$d\" && echo STAGED-DIR"; } \
		| bt305_ssh "$n" 30 sh -s | grep -q STAGED-DIR || { echo "FAIL could not create the run dir on $n"; return 1; }
	scp -q "${BT305_SSHO[@]}" "${files[@]}" "root@$n:/tmp/run/batman-dv/bt/$run/" || { echo "FAIL scp to $n failed"; return 1; }
	bt305_ssh "$n" 20 "chmod 700 /tmp/run/batman-dv/bt/$run/*" || { echo "FAIL chmod on $n"; return 1; }
	o=$(bt305_n "$n" "$run" 60 stage-check) || { echo "$o"; return 1; }
	for f in "${files[@]}"; do
		h=$(sha256sum "$f" | cut -c1-64)
		grep -q "^$h  $(basename "$f")\$" <<< "$o" || { echo "FAIL $(basename "$f") on $n differs from the host copy"; return 1; }
	done
	echo "ok   staged #305 run $run on $n (firmware $fw)"
}
# bt305_n <node> <run_id> <secs> <cmd> [args]: run the node script under that run id
bt305_n() {
	local n=$1 run=$2 t=$3; shift 3
	bt305_ssh "$n" "$t" "RUN_ID=$run BT305_FORCE=${BT305_FORCE:-0} BT305_FLIP_OK=${BT305_FLIP_OK:-0} sh /tmp/run/batman-dv/bt/$run/bt-uart-305.sh $*"
}
bt305_drop() { bt305_ssh "$1" 20 "rm -rf /tmp/run/batman-dv/bt/$2"; }	# a run dir that never took the lease
# bt305_reboot <node> <reason>: back onto the committed slot, wait for a new boot and uptime >= 90 s
bt305_reboot() {
	local n=$1 b0 b t0
	b0=$(bt305_ssh "$n" 15 'cat /proc/sys/kernel/random/boot_id')
	bt305_ssh "$n" 15 "batman-slot reboot committed $2 </dev/null >/dev/null 2>&1 &" >/dev/null 2>&1
	t0=$SECONDS
	while [ $((SECONDS - t0)) -lt 600 ]; do sleep 10; b=$(bt305_ssh "$n" 10 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null); [ -n "$b" ] && [ "$b" != "$b0" ] && break; done
	[ -n "$b" ] && [ "$b" != "$b0" ] || { echo "FAIL $n did not come back within 600 s"; return 1; }
	while [ $((SECONDS - t0)) -lt 900 ]; do u=$(bt305_ssh "$n" 10 'cut -d. -f1 /proc/uptime' 2>/dev/null); [ "${u:-0}" -ge 90 ] && return 0; sleep 10; done
	echo "FAIL $n did not settle"; return 1
}
# one test command on one node under its own lease; prints the node's lines; rc = node rc
bt305_leased() {
	local n=$1 secs=$2 run o rc=0; shift 2
	run=$(bt305_run_id)
	bt305_stage "$n" "$run" || return 1
	o=$(bt305_n "$n" "$run" 60 gate); rc=$?
	if [ "$rc" != 0 ]; then echo "$o"; bt305_drop "$n" "$run"; return 1; fi
	bt305_n "$n" "$run" 60 acquire "$secs" || { bt305_drop "$n" "$run"; return 1; }
	o=$(bt305_n "$n" "$run" "$((secs + 120))" "$@" 2>&1); rc=$?
	echo "$o"
	if grep -q '^NEEDS-REBOOT' <<< "$o" || grep -q 'still down' <<< "$o"; then
		bt305_reboot "$n" "bt305-restore" || rc=1		# tmpfs (lease, run dir, markers) goes with the reboot
	else bt305_n "$n" "$run" 60 release >/dev/null || { echo "FAIL release on $n"; rc=1; }; fi
	return $rc
}

chk_bt_uart_flow_305() { local n rc=0 run; [ $# -gt 0 ] || { echo "FAIL no bcm2711 node to check"; return 1; }
	for n in "$@"; do echo "== $n"; run=$(bt305_run_id); bt305_stage "$n" "$run" || { rc=1; continue; }
		bt305_n "$n" "$run" 120 flow ${BT305_FLIP_ARG:-} || rc=1; bt305_drop "$n" "$run"; done; return $rc; }
chk_bt_uart_rebind_305() { local n rc=0; [ $# -gt 0 ] || { echo "FAIL no bcm2711 node to check"; return 1; }
	for n in "$@"; do echo "== $n"; bt305_leased "$n" 600 rebind 10 ${BT305_FLIP_ARG:-} || rc=1; done; return $rc; }
bchk_bt_uart_load_305() { local n rc=0; [ $# -gt 0 ] || { echo "FAIL no bcm2711 node to load"; return 1; }
	for n in "$@"; do echo "== $n"; bt305_leased "$n" "$((BT305_LOAD_SECS + 900))" load "$BT305_LOAD_SECS" ${BT305_FLIP_ARG:-} || rc=1; done; return $rc; }
bchk_bt_uart_close_305() { local n=${1:?node} rc=0 run
	echo "== $n"; bt305_leased "$n" 600 close ${BT305_FLIP_ARG:-} || rc=1
	run=$(bt305_run_id); bt305_stage "$n" "$run" && { bt305_n "$n" "$run" 120 bootcheck || rc=1; bt305_drop "$n" "$run"; } || rc=1
	return $rc; }
bchk_bt_uart_boot_305() { local n=${1:?node} rc=0 i run o r
	run=$(bt305_run_id); bt305_stage "$n" "$run" >/dev/null || { echo "FAIL staging on $n failed"; return 1; }
	o=$(bt305_n "$n" "$run" 60 gate); r=$?; bt305_drop "$n" "$run"
	[ "$r" = 0 ] || { echo "$o"; return 1; }		# a pre-#305 image: one KNOWN line, no reboot
	for i in $(seq 1 "$BT305_BOOTS"); do
		BT305_LOAD_SECS=60 bt305_leased "$n" 900 load 60 >/dev/null 2>&1		# busy controller before the reboot (#305 trigger)
		bt305_reboot "$n" "bt305-boot-$i" || { rc=1; break; }
		run=$(bt305_run_id); bt305_stage "$n" "$run" >/dev/null || { echo "FAIL boot $i: staging failed"; rc=1; break; }
		o=$(bt305_n "$n" "$run" 120 bootcheck); r=$?; bt305_drop "$n" "$run"
		echo "boot $i: $(grep -c '^PASS' <<< "$o") PASS, $(grep -c '^FAIL' <<< "$o") FAIL"; [ "$r" = 0 ] || { echo "$o" | grep '^FAIL' | sed "s/^FAIL /FAIL boot $i: /"; rc=1; }
	done; return $rc; }

# bt305_verdict <test> <output> <forbidden ERE|""> <required ERE...>: a flip / force run is VALID only when it failed
# through its own detection lines (A v6 m1). Sets rc=1 in the caller on INVALID ($mode / $node name the run).
bt305_verdict() {
	local t=$1 o=$2 bad=$3 r ok=1; shift 3
	for r in "$@"; do grep -qE -- "$r" <<< "$o" || ok=0; done
	[ -n "$bad" ] && grep -qE -- "$bad" <<< "$o" && ok=0
	if [ $ok = 1 ]; then echo "FLIP-RESULT $t VALID (${mode:-?} on ${node:-?})"; return 0; fi
	echo "FLIP-RESULT $t INVALID (${mode:-?} on ${node:-?}): did not fail through its own detection"; rc=1; return 1
}
