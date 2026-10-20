#!/bin/sh
# scripts/node/ble-central-254.sh — the test central (BLE_CENTRAL = 02) for the #254 tier-B suites
# (PR-H1, docs/design/254-h1-harness.md §4.4–§4.7). Staged with ble-lib-254.sh in /tmp/run/batman-dv/bt/<run_id>/.
#   RUN_ID=<id> sh <dir>/ble-central-254.sh <cmd> ...
# 02 is the attacker's role. Its pairing rounds use an INTERACTIVE bluetoothctl session (a FIFO; it registers an
# agent, E26), so bondable is switched off explicitly in the same session and asserted right before the pair.
# Samples use NON-interactive `bluetoothctl --timeout N scan on` (no agent).
set -u
SELF=$(readlink -f "$0"); DIR=$(dirname "$SELF")
. "$DIR/ble-lib-254.sh"
RUN_ID=${RUN_ID:-}
MAC='^([0-9A-F]{2}:){5}[0-9A-F]{2}$'

adapter_dir() { for a in /tmp/lib/bluetooth/*/; do b=$(basename "$a"); echo "$b" | grep -qE "$MAC" && { echo "${a%/}"; return; }; done; }
h_of() { [ -f "$1" ] && sha256sum < "$1" | cut -c1-12 || echo none; }

cmd_stage_check() {
	dir_ok "$DIR" drwx------ || die "$DIR is not a root 0700 directory"
	for t in "$DIR/ble-lib-254.sh" "$SELF"; do file_ok "$t" || die "$t is not a root regular file with one link"; done
	sha256sum "$DIR/ble-lib-254.sh" "$SELF" | sed "s#$DIR/##"
	echo "STAGE ok"
}

# reset: bluetoothd stopped -> print + delete cache/* and peer dirs (whitelist: MAC-named dirs) -> start.
# 02's own identity / settings are never touched: their hashes must be unchanged afterwards (design §3, §4.5).
cmd_reset() {
	held; a=$(adapter_dir); [ -n "$a" ] || { unlock; die "no adapter dir"; }
	hi=$(h_of "$a/identity"); hs=$(h_of "$a/settings"); old=$(pidof bluetoothd)
	/etc/init.d/bluetoothd stop >/dev/null 2>&1
	n=0; while pidof bluetoothd >/dev/null && [ $n -lt 10 ]; do sleep 1; n=$((n + 1)); done
	pidof bluetoothd >/dev/null && { unlock; die "bluetoothd did not stop"; }
	dir_ok /tmp/lib/bluetooth drwx------ && [ ! -L "$a" ] || { /etc/init.d/bluetoothd start >/dev/null 2>&1; unlock; die "store ownership changed — not deleting"; }
	for f in "$a"/cache/*; do [ -e "$f" ] || continue; echo "RESET rm cache/$(basename "$f")"; rm -f "$f"; done
	for d in "$a"/*/; do
		p=$(basename "$d"); echo "$p" | grep -qE "$MAC" || continue
		[ -L "${d%/}" ] && continue; echo "RESET rm $p/"; rm -rf "${a:?}/$p"
	done
	/etc/init.d/bluetoothd start >/dev/null 2>&1
	new=$(wait_bluetoothd "") || { unlock; die "bluetoothd did not come back after reset"; }
	unlock
	[ "$(h_of "$a/identity")" = "$hi" ] && [ "$(h_of "$a/settings")" = "$hs" ] || die "02's own identity/settings changed during reset"
	echo "RESET done pid $old -> $new"
}

# sample <name> <secs>: one discovery window; prints "SEEN <addr>" for every address that ADVERTISED <name> during
# THIS window. Evidence = a [NEW] line or an RSSI change in this session (non-interactive bluetoothctl lists no
# cached device at start, E37); the name of an address seen only via RSSI comes from bluetoothd's object
# (identification only). N2b proves a cached object alone is never reported as seen.
cmd_sample() {
	held; nm=${1:?name}; sec=${2:-10}; unlock
	out="$DIR/sample.$$"
	BATMAN_DV_BLE=1 bluetoothctl --timeout "$sec" scan on 2>/dev/null | clean > "$out"
	grep -q '^Discovery started' "$out" || { rm -f "$out"; die "discovery did not start"; }
	seen=""
	for x in $(sed -n "s/^\[NEW\] Device \([0-9A-F:]\{17\}\) $nm\$/\1/p" "$out"); do seen="$seen $x"; done
	for x in $(sed -n 's/^\[CHG\] Device \([0-9A-F:]\{17\}\) RSSI: .*/\1/p' "$out" | sort -u); do
		case " $seen " in *" $x "*) continue;; esac
		n=$(bluetoothctl info "$x" 2>/dev/null | clean | sed -n 's/^[[:space:]]*Name: //p' | head -1)
		[ "$n" = "$nm" ] && seen="$seen $x"
	done
	echo "SAMPLED lines=$(wc -l < "$out")"; rm -f "$out"
	for x in $seen; do echo "SEEN $x"; done
}

# round <label> <sc on|off> <bondable on|off> <name> <periph public addr>: one pairing attempt (design §4.5 step 3)
cmd_round() {
	held; L=$1 SC=$2 BO=$3 NM=$4 PUB=$5; unlock
	F="$DIR/round-$L.fifo"; LOG="$DIR/round-$L.log"; rm -f "$F" "$LOG"; mkfifo -m 600 "$F"
	bg_start "keep-$L" sh -c "exec sleep 600 > '$F'" || die "keeper"
	bg_start "ctl-$L" sh -c "bluetoothctl < '$F' 2>&1 | while IFS= read -r l; do echo \"\$(cut -d. -f1 /proc/uptime) \$l\"; done > '$LOG'" || die "session"
	s() { echo "$*" > "$F"; }
	sleep 3; s "mgmt.bondable $BO"; sleep 1; s "mgmt.sc $SC"; sleep 1
	s "scan on"; sleep 10; s "scan off"; sleep 2
	A=$(clean < "$LOG" | sed -n "s/.*\[NEW\] Device \([0-9A-F:]\{17\}\) $NM\$/\1/p" | tail -1)
	if [ -z "$A" ]; then s quit; sleep 1; bg_stop "ctl-$L"; bg_stop "keep-$L"; rm -f "$F"; echo "ROUND $L INVALID no-target"; return 0; fi
	s "mgmt.info"; sleep 2; s "mgmt.pair -c 3 -t 2 $A"; sleep 25
	s "devices"; sleep 1; s quit; sleep 1
	bg_stop "ctl-$L"; bg_stop "keep-$L"; rm -f "$F"
	C=$(clean < "$LOG")
	echo "ROUND $L target=$A"
	echo "ROUND $L settings-before-pair: $(echo "$C" | sed -n 's/.*current settings: //p' | tail -1)"
	echo "ROUND $L connected=$(echo "$C" | grep -c 'Connected: yes')"
	echo "ROUND $L paired-public=$(echo "$C" | grep -c "Paired with $PUB")"
	echo "ROUND $L public-seen=$(echo "$C" | grep -ci "$PUB")"
	echo "ROUND $L pair-result: $(echo "$C" | grep -E 'Paired with|failed with status|Failed to pair|Pairing with .* failed' | tail -1 | sed 's/^[0-9]* //; s/\[[^]]*\]# //g')"
}

cmd_mark_exposed() { held; mark_set irk-exposed "$RUN_ID"; unlock; echo "IRK-EXPOSED marked"; }
cmd_restore() {
	held; kill_run_groups "$RUN_ID"; old=$(pidof bluetoothd)
	/etc/init.d/bluetoothd restart >/dev/null 2>&1
	new=$(wait_bluetoothd "$old") || { unlock; die "bluetoothd did not come back"; }
	unlock; echo "RESTORED pid $old -> $new settings: $(settings)"
}
role_fire_restore() {	# deadman on 02: kill the sessions; a possibly leaked IRK => reboot (H-U7), else restart bluetoothd
	if mark_here irk-exposed; then
		dm_log "$1" "deadman: 02 IRK may have leaked in the flip segment — reboot (H-U7)"
		rm -f "$BT/lease" "$ST/dm" "$ST/dm.new"
		batman-slot reboot committed ble-dm-254; exit 0
	fi
	/etc/init.d/bluetoothd restart >/dev/null 2>&1; wait_bluetoothd "" >/dev/null
}

c=${1:-}; [ $# -gt 0 ] && shift
case "$c" in
	dm-fire) cmd_dm_fire "$@" ;;
	*) [ -n "$RUN_ID" ] || die "RUN_ID unset" ;;
esac
case "$c" in
	stage-check) cmd_stage_check ;;
	acquire) cmd_acquire "$@" ;;
	arm) cmd_arm "$@" ;;
	release) cmd_release ;;
	state) ble_state ;;
	reset) cmd_reset ;;
	sample) cmd_sample "$@" ;;
	round) cmd_round "$@" ;;
	mark-exposed) cmd_mark_exposed ;;
	restore) cmd_restore ;;
	info) echo "SETTINGS $(settings)"; echo "PID $(pidof bluetoothd)" ;;
	canary) cmd_canary ;;
	*) die "unknown command [$c]" ;;
esac
