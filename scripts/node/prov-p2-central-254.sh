#!/bin/sh
# scripts/node/prov-p2-central-254.sh — #254 H3: 02 as the BLE central against 04's batman-provd (254-h23 §6.3,
# 254-p2-impl §5 L80 / §20). Run as root on 02:  ssh root@02 sh -s -- <cmd> < prov-p2-central-254.sh
# bluetoothctl reads its commands from a pipe, paced with sleeps; one-shot calls get an empty pipe (`: |`), never the
# script itself (sh -s) and never /dev/null (02 has no btmgmt; the BLE suites found tools that hang on /dev/null).
# Every device it found is removed again before it returns (BlueZ keeps temporary devices otherwise).
#   find                 scan 12 s filtered on the provd service UUID -> "ADDR <addr>" + "NAME <name or ->" of the one
#                        advertiser (none -> "NOADDR", rc 1)
#   read                 find -> connect -> read CTRL and STATUS (no pairing) -> disconnect -> remove:
#                        "CTRL <hex>", "STATUS <hex>", "PAIRED <yes|no>" (rc 1 when a value is missing)
#   hold                 find -> connect and leave the link up: "HELD <addr> connected=<yes|no>"
#   watch <addr> <s>     poll Connected once a second up to <s> s: "GONE <addr> after <n> s" or "STILL <addr>"; then
#                        disconnect + remove either way
#   drop <addr>          disconnect + remove
# busybox ash; the 128-bit UUIDs are the D4 values (254-p2-impl §1.3).
U=540aa38c-0086-4d58-a9c0-c7c9d1e1bd42
CTRL=540aa38c-0086-4d5b-a9c0-c7c9d1e1bd42
STAT=540aa38c-0086-4d5c-a9c0-c7c9d1e1bd42
D=/tmp/run/batman-dv
[ -d "$D" ] || mkdir -m 700 "$D"
T=$(mktemp -d "$D/p2c.XXXXXX") || { echo "FAIL no scratch dir"; exit 1; }
trap 'rm -rf "$T"' EXIT
clean() { sed 's/\x1b\[[0-9;]*m//g; s/\r//g'; }
conn() { : | bluetoothctl info "$1" 2>/dev/null | clean | sed -n 's/^[[:space:]]*Connected: //p'; }
drop() { { echo "disconnect $1"; sleep 3; echo "remove $1"; sleep 1; echo quit; } | bluetoothctl >/dev/null 2>&1; }
find_one() {
	{ echo "menu scan"; echo "uuids $U"; echo "transport le"; echo back; echo "scan on"; sleep 12; echo "scan off"; sleep 1; echo devices; sleep 1; } \
		| bluetoothctl 2>&1 | clean > "$T/scan"
	A=""
	for a in $(grep -o 'Device [0-9A-F:]\{17\}' "$T/scan" | awk '{print $2}' | sort -u); do
		if : | bluetoothctl info "$a" 2>/dev/null | clean | grep -qi "$U"; then A=$a; break; fi
	done
	[ -n "$A" ]
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
c=${1:-}
case "$c" in
find)
	if find_one; then echo "ADDR $A"; echo "NAME $(: | bluetoothctl info "$A" 2>/dev/null | clean | sed -n 's/^[[:space:]]*Name: //p' | head -1 | grep . || echo -)"; drop "$A"
	else echo NOADDR; exit 1; fi ;;
read)
	find_one || { echo NOADDR; exit 1; }
	{ echo "connect $A"; sleep 8; echo "menu gatt"; echo list-attributes; sleep 2
	  echo "select-attribute $CTRL"; sleep 1; echo read; sleep 2
	  echo "select-attribute $STAT"; sleep 1; echo read; sleep 2; echo back; sleep 1; echo quit; } | bluetoothctl 2>&1 | clean > "$T/read"
	p=$(: | bluetoothctl info "$A" 2>/dev/null | clean | sed -n 's/^[[:space:]]*Paired: //p')
	drop "$A"
	cv=$(value 1); sv=$(value 2)
	echo "ADDR $A"; echo "CTRL ${cv:-none}"; echo "STATUS ${sv:-none}"; echo "PAIRED ${p:-?}"
	[ -n "$cv" ] && [ -n "$sv" ] || { grep -E 'Failed|Error|Value' "$T/read" | head -5; exit 1; } ;;
hold)
	find_one || { echo NOADDR; exit 1; }
	{ echo "connect $A"; sleep 6; echo quit; } | bluetoothctl >/dev/null 2>&1
	echo "HELD $A connected=$(conn "$A")" ;;
watch)
	a=$2; m=${3:-30}; n=0
	while [ $n -lt "$m" ]; do [ "$(conn "$a")" = yes ] || { echo "GONE $a after $n s"; drop "$a"; exit 0; }; sleep 1; n=$((n + 1)); done
	echo "STILL $a"; drop "$a" ;;
drop) drop "$2"; echo "DROPPED $2" ;;
*) echo "usage: prov-p2-central-254.sh find|read|hold|watch <addr> <s>|drop <addr>"; exit 2 ;;
esac
