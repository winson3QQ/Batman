# shellcheck shell=bash
# tests/prov-p1/lib-wireless-stubs.sh — sourced by setkey-forget-lock.sh and chanfix-lock.sh (#254 wireless-txn §6/§11).
# Fake uci / iw / ubus / jsonfilter / wifi / logger / batman-config-save in $ST/bin, state in $ST:
#   live        merged uci view (what `uci get/show` returns: committed + staged), one "cfg.sec.opt=value" per line
#   committed   what the last `uci commit` wrote; commits.log = every committed state, "--- commit <n>" separated
#   netdev      present = the mesh netdev (wlh0) exists;  radio = up|down (netifd's view, ubus)
#   stuck       present = `wifi reload` does NOT bring the morse radio down (netdev and up stay)
#   stuck-ubus  present = the netdev goes away but netifd still reports the radio up=false disabled=false
#   wifi.sleep  seconds a `wifi` call takes; wifi.log: begin/end per call + whether fd 9 (the lock) was open
#   lockfile    if set (file path), `uci commit` records UNLOCKED in commits.log when nobody holds that flock
#   fd9.log     one line "<cmd> fd9=open|closed" per iw / ubus / jsonfilter / morse_cli / batman-config-save call
# No root needed. The product runs under busybox ash, as on the node.
stubs_init() {   # $1 = state dir
	ST=$1; mkdir -p "$ST/bin"; : > "$ST/commits.log"; : > "$ST/wifi.log"; : > "$ST/logger.log"; : > "$ST/cfgsave.log"
	cat > "$ST/bin/uci" <<'EOF'
#!/bin/bash
S=${STUB_ST:?}
while :; do case "${1:-}" in -q) shift ;; -P) shift 2 ;; *) break ;; esac; done
cmd=${1:-}; shift
getk(){ awk -v k="$1" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); f = 1; exit } END { exit !f }' "$S/live"; }
case "$cmd" in
get) getk "$1" ;;
set) k=${1%%=*}; v=${1#*=}; awk -v k="$k" 'index($0, k "=") != 1' "$S/live" > "$S/live.n"; echo "$k=$v" >> "$S/live.n"; mv "$S/live.n" "$S/live" ;;
delete) awk -v k="$1" 'index($0, k "=") != 1' "$S/live" > "$S/live.n"; mv "$S/live.n" "$S/live" ;;
show) grep "^$1\." "$S/live" | sed "s/=\(.*\)$/='\1'/" ;;
commit)
	cp "$S/live" "$S/committed"
	n=$(grep -c '^--- commit' "$S/commits.log"); { echo "--- commit $((n + 1))"; cat "$S/committed"; } >> "$S/commits.log"
	if [ -n "${STUB_LOCKFILE:-}" ] && flock -n "$STUB_LOCKFILE" true 2>/dev/null; then echo UNLOCKED >> "$S/commits.log"; fi ;;
revert) cp "$S/committed" "$S/live" ;;
*) exit 1 ;;
esac
EOF
	cat > "$ST/bin/wifi" <<'EOF'
#!/bin/bash
S=${STUB_ST:?}
fd9=closed; [ -e /proc/$$/fd/9 ] && fd9=open
echo "begin $$ $* fd9=$fd9" >> "$S/wifi.log"
[ -f "$S/wifi.sleep" ] && sleep "$(cat "$S/wifi.sleep")"
r=$(sed -n 's/^wireless\.\([^.]*\)\.type=morse$/\1/p' "$S/committed" | head -1)
if [ -n "$r" ] && grep -qx "wireless.$r.disabled=1" "$S/committed" && [ ! -f "$S/stuck" ]; then
	rm -f "$S/netdev"; if [ -f "$S/stuck-ubus" ]; then echo up > "$S/radio"; else echo down > "$S/radio"; fi
else
	echo wlh0 > "$S/netdev"; echo up > "$S/radio"
fi
echo "end $$" >> "$S/wifi.log"
EOF
	cat > "$ST/bin/iw" <<'EOF'
#!/bin/bash
S=${STUB_ST:?}
echo "iw fd9=$([ -e /proc/$$/fd/9 ] && echo open || echo closed)" >> "$S/fd9.log"
if [ "$1 ${2:-}" = "dev " ] || [ "$*" = dev ]; then
	printf 'phy#0\n\tInterface phy0-ap0\n\t\ttype AP\n'
	[ -f "$S/netdev" ] && printf 'phy#1\n\tInterface wlh0\n\t\ttype mesh point\n'
	exit 0
fi
[ "$1" = dev ] && [ "${3:-}" = info ] && { [ -f "$S/netdev" ]; exit; }
exit 0
EOF
	cat > "$ST/bin/ubus" <<'EOF'
#!/bin/bash
S=${STUB_ST:?}
echo "ubus fd9=$([ -e /proc/$$/fd/9 ] && echo open || echo closed)" >> "$S/fd9.log"
[ "$*" = "call network.wireless status" ] || exit 1
r=$(sed -n 's/^wireless\.\([^.]*\)\.type=morse$/\1/p' "$S/committed" | head -1)
if [ "$(cat "$S/radio" 2>/dev/null)" = down ]; then u=false; d=true; else u=true; d=false; fi
printf '{\n\t"radio0": {\n\t\t"up": true,\n\t\t"disabled": false\n\t},\n\t"%s": {\n\t\t"up": %s,\n\t\t"pending": false,\n\t\t"disabled": %s\n\t}\n}\n' "$r" "$u" "$d"
EOF
	cat > "$ST/bin/jsonfilter" <<'EOF'
#!/usr/bin/env python3
# subset of OpenWrt jsonfilter: -e @.a.b  (prints JSON booleans as true/false)
import json, os, sys
with open(os.environ["STUB_ST"] + "/fd9.log", "a") as f:
    f.write("jsonfilter fd9=%s\n" % ("open" if os.path.exists("/proc/self/fd/9") else "closed"))
a = sys.argv[1:]
if len(a) != 2 or a[0] != "-e" or not a[1].startswith("@."):
    sys.exit(2)
v = json.load(sys.stdin)
for k in a[1][2:].split("."):
    if not isinstance(v, dict) or k not in v:
        sys.exit(1)
    v = v[k]
print(json.dumps(v) if isinstance(v, bool) else v)
EOF
	cat > "$ST/bin/logger" <<'EOF'
#!/bin/bash
echo "$*" >> "${STUB_ST:?}/logger.log"
EOF
	cat > "$ST/bin/batman-config-save" <<'EOF'
#!/bin/bash
echo "batman-config-save fd9=$([ -e /proc/$$/fd/9 ] && echo open || echo closed)" >> "${STUB_ST:?}/fd9.log"
echo "$*" >> "${STUB_ST:?}/cfgsave.log"; echo "batman-config-save: saved (--save)"
EOF
	cat > "$ST/bin/morse_cli" <<'EOF'
#!/bin/bash
echo "morse_cli fd9=$([ -e /proc/$$/fd/9 ] && echo open || echo closed)" >> "${STUB_ST:?}/fd9.log"
f=$(cat "${STUB_ST:?}/morse.khz" 2>/dev/null); [ -n "$f" ] && echo "	Operating Frequency: $f kHz"
exit 0
EOF
	chmod +x "$ST/bin/"*
	export STUB_ST=$ST
}
# rundir.sh with RUNDIR inside the test dir (the product hard-codes /tmp/run/batman, #280 — no env override)
stub_rundir() {   # $1 = product rundir.sh, $2 = output copy; RUNDIR = $ST/run/batman
	mkdir -p "$ST/run"; chmod 755 "$ST/run"
	# the lock file exists up front, so the fake `uci commit` can probe it (flock -n) even against a product that never
	# opens it — that is what makes the "commit under the lock" checks fail on the shipped scripts (negative control)
	mkdir -p "$ST/run/batman"; chmod 700 "$ST/run/batman"; : > "$ST/run/batman/halow-setkey.lock"
	sed "s#^RUNDIR=/tmp/run/batman#RUNDIR=$ST/run/batman#" "$1" > "$2"
}
commits() { grep -c '^--- commit' "$ST/commits.log"; }
committed_get() { awk -v k="$1" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$ST/committed"; }
