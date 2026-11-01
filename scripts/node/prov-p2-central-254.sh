#!/bin/sh
# scripts/node/prov-p2-central-254.sh — #254 H3: 02 as the BLE central against 04's batman-provd (254-h23 §6.3,
# 254-p2-impl §5 L80 / §20). Run as root on 02:  ssh root@02 sh -s -- <cmd> [args] < prov-p2-central-254.sh
# bluetoothctl reads its commands from a pipe, paced with sleeps; one-shot calls get an empty pipe (`: |`), never the
# script itself (sh -s) and never /dev/null (02 has no btmgmt; the BLE suites found tools that hang on /dev/null).
# 02's bluetoothctl segfaults now and then (2026-11-01: 1 in ~5 calls): a scan + read is tried up to 5 times, a connect 3.
# Every device it found is removed again before it returns (BlueZ keeps temporary devices otherwise).
#
# WHICH node: every P2 node advertises the same service UUID, so the target is named by <last4> = the last 4 hex digits
# of its serial (STATUS key 5, sent only while unclaimed / legacy). With <last4> "-" (a claimed node: no key 5) the
# UUID must have exactly ONE advertiser in range, else AMBIGUOUS (rc 3) — the caller adds its own node-side witness.
#   read <last4|->          find the node, connect, read CTRL and STATUS (no pairing), disconnect, remove:
#                           "ADDR <a>", "NAME <name|->", "CTRL <hex>", "STATUS <hex>", "PAIRED <yes|no>", "ADVERTISERS <n>",
#                           "ERRS <bluetoothctl's 'Failed to read: <error name>' lines, | separated, or ->"
#                           rc 1 = no advertiser / no value after 3 tries; rc 3 = AMBIGUOUS / no advertiser with <last4>
#   hold <last4|->          as read (identifies the address), then connect again and leave the link up:
#                           "HELD <addr> connected=<yes|no>"
#   watch <addr> <s>        poll Connected; "GONE <addr> after <n> s (no|gone)" only on an explicit "Connected: no" or
#                           BlueZ's "not available" (an empty / segfaulted poll is retried, never taken as gone);
#                           "STILL <addr> after <s> s";
#                           seconds from 02's /proc/uptime. Then disconnect + remove either way.
#   drop <addr>             disconnect + remove
#   addrs                   one 12 s scan: "ADDRS <addr> ..." = the advertisers of the UUID whose advertisements arrived
#                           in THIS scan ([NEW] / [CHG] lines; `devices` alone also lists BlueZ's cached ones), then
#                           removes every unpaired device it saw; "ADDRS -" none
# busybox ash; the 128-bit UUIDs are the D4 values (254-p2-impl §1.3).
U=540aa38c-0086-4d58-a9c0-c7c9d1e1bd42
CTRL=540aa38c-0086-4d5b-a9c0-c7c9d1e1bd42
STAT=540aa38c-0086-4d5c-a9c0-c7c9d1e1bd42
D=/tmp/run/batman-dv
[ -d "$D" ] || mkdir -m 700 "$D"
T=$(mktemp -d "$D/p2c.XXXXXX") || { echo "FAIL no scratch dir"; exit 1; }
trap 'rm -rf "$T"' EXIT
trap '' PIPE
clean() { sed 's/\x1b\[[0-9;]*m//g; s/\r//g'; }
up() { cut -d. -f1 /proc/uptime; }
# 02's one-shot `bluetoothctl info` (empty stdin) segfaults now and then (rc 139, 2 in 10 on 2026-11-01; scan and
# remove sessions did not): an empty or segfaulted answer is asked again, up to 4 times, so a scan does not drop the node
info_of() {
	_i=0; while [ $_i -lt 4 ]; do
		_o=$(: | bluetoothctl info "$1" 2>/dev/null); _r=$?
		[ "$_r" != 139 ] && [ -n "$_o" ] && break
		_i=$((_i + 1))
	done
	printf '%s\n' "$_o" | clean
}
conn() { info_of "$1" | sed -n 's/^[[:space:]]*Connected: //p'; }
# conn_state <addr>: yes / no / gone (BlueZ no longer knows the device: "not available") / unknown (no output: a
# segfault or a hang — retried, never read as disconnected)
conn_state() {
	_o=$(: | bluetoothctl info "$1" 2>&1 | clean)
	case "$_o" in *"Connected: yes"*) echo yes ;; *"Connected: no"*) echo no ;; *"not available"*) echo gone ;; *) echo unknown ;; esac
}
drop() { { echo "disconnect $1"; sleep 3; echo "remove $1"; sleep 1; echo quit; } | bluetoothctl >/dev/null 2>&1; }
# all advertisers of the service UUID seen in one 12 s scan -> $T/addrs
scan_all() {
	{ echo "menu scan"; echo "uuids $U"; echo "transport le"; echo back; echo "scan on"; sleep 12; echo "scan off"; sleep 1; echo devices; sleep 1; } \
		| bluetoothctl 2>&1 | clean > "$T/scan"
	: > "$T/addrs"
	for a in $(grep -o 'Device [0-9A-F:]\{17\}' "$T/scan" | awk '{print $2}' | sort -u); do
		info_of "$a" | grep -qi "$U" && echo "$a" >> "$T/addrs"
	done
}
# the hex bytes printed after the n-th "Value:" of a bluetoothctl read. bluetoothctl 5.72 (02, 2026-11-01) prefixes
# every dump line with its prompt ("[Batman:/service…/char…]# … ") and prints the value twice (the [CHG] echo and the
# read result): strip the prompts, take the leading hex columns (<= 16 a line, the ascii column ignored), and keep
# one copy when the block is two equal halves.
value() {
	awk -v n="$1" '
	/Value:$/ { k++; inb = (k == n); next }
	inb {
		l = $0; sub(/^.*\]# */, "", l); m = split(l, f, /[[:space:]]+/); h = ""
		for (i = 1; i <= m && i <= 16; i++) { if (f[i] ~ /^[0-9a-f][0-9a-f]$/) h = h f[i]; else break }
		if (h == "") { inb = 0; next }
		L[++c] = h
	}
	END {
		if (c % 2 == 0) { a = ""; b = ""; for (i = 1; i <= c / 2; i++) { a = a L[i]; b = b L[i + c / 2] } if (a == b) { print a; exit } }
		s = ""; for (i = 1; i <= c; i++) s = s L[i]; print s
	}' "$T/read"
}
# read_one <addr>: connect, read STATUS then CTRL, drop; sets CV SV PV (empty on failure), NV = the name BlueZ knew from the
# advertisement BEFORE connecting (no Local Name advertised -> none) and GV = the name after connecting (BlueZ then
# reads the GAP Device Name characteristic: main.conf Name — not the advertisement; 02, 2026-11-01)
read_one() {
	NV=$(info_of "$1" | sed -n 's/^[[:space:]]*Name: //p' | head -1)
	{ echo "connect $1"; sleep 8; echo "menu gatt"; echo list-attributes; sleep 2
	  # CTRL last, with 8 s: a refused read (encrypt-read) first runs SMP and one retry before bluetoothctl prints the
	  # error (04 wbox, 2026-11-01: with 2 s the error line never came)
	  echo "select-attribute $STAT"; sleep 1; echo read; sleep 2
	  echo "select-attribute $CTRL"; sleep 1; echo read; sleep 8; echo back; sleep 1; echo quit; } | bluetoothctl 2>&1 | clean > "$T/read"
	info_of "$1" > "$T/info"; PV=$(sed -n 's/^[[:space:]]*Paired: //p' "$T/info"); GV=$(sed -n 's/^[[:space:]]*Name: //p' "$T/info" | head -1)
	drop "$1"
	# STATUS first: a refused CTRL read (prov-gatt's encrypt-read white box) prints no Value and may upset the session
	SV=$(value 1); CV=$(value 2)
}
# pick <last4|->: sets A (and CV SV PV of the chosen node); rc 1 none / unreadable, rc 3 ambiguous / not found
pick() {
	want=$1; A=""; tries=0
	while [ $tries -lt 5 ]; do	# 02's bluetoothctl segfaults ~1 call in 5: up to 5 scans
		tries=$((tries + 1)); scan_all; n=$(wc -l < "$T/addrs"); NADV=$n
		[ "$n" -gt 0 ] || continue
		if [ "$want" = - ]; then
			[ "$n" = 1 ] || { echo "AMBIGUOUS $n advertisers and no last4 to tell them apart"; return 3; }
			a=$(cat "$T/addrs"); read_one "$a"; [ -n "$CV" ] && [ -n "$SV" ] && { A=$a; return 0; }
		else
			k="0564$(printf '%s' "$want" | hexdump -v -e '/1 "%02x"')"
			for a in $(cat "$T/addrs"); do
				read_one "$a"; [ -n "$SV" ] || continue
				case "$SV" in *"$k"*) A=$a; return 0 ;; esac
			done
			[ -n "$SV" ] && { echo "NOTFOUND no advertiser's STATUS carries key 5 = $want ($n advertiser(s))"; return 3; }
		fi
	done
	return 1
}
c=${1:-}
case "$c" in
read)
	pick "${2:--}"; r=$?
	[ $r = 3 ] && exit 3
	[ $r = 0 ] || { echo "NOADDR (or no value) after 3 tries"; grep -E 'Failed|Error' "$T/read" 2>/dev/null | head -3; exit 1; }
	echo "ADDR $A"; echo "NAME ${NV:--}"; echo "GAPNAME ${GV:--}"; echo "CTRL $CV"; echo "STATUS $SV"; echo "PAIRED ${PV:-?}"; echo "ADVERTISERS $NADV"
	e=$(grep -o 'Failed to read: [^ ]*' "$T/read" | sort -u | tr '\n' '|'); echo "ERRS ${e:--}"
	# evidence when there is no such line: the session's last error-looking lines, prompts stripped
	e=$(grep -iE 'fail|error|not permitted' "$T/read" | sed 's/^.*\]# *//' | tail -3 | tr '\n' '|'); echo "ERRLINES ${e:--}" ;;
hold)
	pick "${2:--}"; r=$?
	[ $r = 0 ] || { [ $r = 3 ] && exit 3; echo "NOADDR after 3 tries"; exit 1; }
	# pick's read removed the device: scan again in the same session so BlueZ knows the address (its RPA stays the same
	# within provd's 900 s rotation), then connect
	i=0; while [ $i -lt 3 ]; do i=$((i + 1))
		{ echo "menu scan"; echo "uuids $U"; echo "transport le"; echo back; echo "scan on"; sleep 10; echo "scan off"; sleep 1
		  echo "connect $A"; sleep 6; echo quit; } | bluetoothctl >/dev/null 2>&1
		# a connect on 02 can take longer than the session: poll up to 10 s before the next try
		k=0; while [ $k -lt 10 ] && [ "$(conn_state "$A")" != yes ]; do sleep 1; k=$((k + 1)); done
		[ "$(conn_state "$A")" = yes ] && break
	done
	echo "HELD $A connected=$(conn_state "$A")" ;;
watch)
	a=$2; m=${3:-30}; t0=$(up)
	while [ $(( $(up) - t0 )) -lt "$m" ]; do
		s=$(conn_state "$a")
		case "$s" in no|gone) echo "GONE $a after $(( $(up) - t0 )) s ($s)"; drop "$a"; exit 0 ;; esac
		sleep 1
	done
	echo "STILL $a after $m s"; drop "$a" ;;
addrs)
	{ echo "menu scan"; echo "uuids $U"; echo "transport le"; echo back; echo "scan on"; sleep 12; echo "scan off"; sleep 1; } \
		| bluetoothctl 2>&1 | clean > "$T/scan"
	l=""; for a in $(sed -n -e 's/.*\[NEW\] Device \([0-9A-F:]\{17\}\).*/\1/p' -e 's/.*\[CHG\] Device \([0-9A-F:]\{17\}\).*/\1/p' "$T/scan" | sort -u); do
		info_of "$a" | grep -qi "$U" && l="$l $a"
	done
	# a paired device is never removed (its bond would go with it)
	for a in $(grep -o 'Device [0-9A-F:]\{17\}' "$T/scan" | awk '{print $2}' | sort -u); do
		info_of "$a" | grep -q 'Paired: yes' || { echo "remove $a"; sleep 1; echo quit; } | bluetoothctl >/dev/null 2>&1
	done
	echo "ADDRS${l:- -}" ;;
drop) drop "$2"; echo "DROPPED $2" ;;
*) echo "usage: prov-p2-central-254.sh read <last4|-> | hold <last4|-> | watch <addr> <s> | drop <addr> | addrs"; exit 2 ;;
esac
