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
# #254 wireless-txn §19 (netifd's word on the radio):
#   pending     present = netifd reports the morse radio pending=true (a change in flight); pending0 = radio0 pending
#   wifi.async  N: a `wifi reload` first sets pending (netdev gone, up=false), and the final state lands N s later
#   wifi.stale  N: for N s after a `wifi reload` ubus still reports the PRE-reload status (up=true, old config)
#   rsf         present = netifd reports retry_setup_failed=true for the morse radio
#   stay-down   present = after a `wifi reload` netifd ends with the radio down, not pending, no netdev (no rsf)
#   ubus.fail   present = ubus exits 1 with no output;  ubus.nosection = no section for the morse radio
#   orphan      the name of a stray mesh netdev that `iw dev` lists whatever the radio does, until `iw dev X del`
#   s1g.pids    the pids `pgrep -f "... -i <orphan> ..."` returns (real processes the test started)
#   sys/        a fake /sys: ieee80211/phy1/device -> the morse uci path, net/<dev>/phy80211 -> the phy (stub_sys)
#   iw.log / pgrep.log  every `iw dev X del` / `pgrep` call, in order (uptime-stamped)
#   ubus always reports the committed radio channel and the committed mesh key / mesh_id as netifd's running config.
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
	cp "$S/committed" "$S/committed.prev" 2>/dev/null; cp "$S/live" "$S/committed"
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
echo "begin $$ $* fd9=$fd9 up=$(cut -d. -f1 /proc/uptime)" >> "$S/wifi.log"
[ -f "$S/wifi.sleep" ] && sleep "$(cat "$S/wifi.sleep")"
final() {   # the state netifd ends in for the committed config
	r=$(sed -n 's/^wireless\.\([^.]*\)\.type=morse$/\1/p' "$S/committed" | head -1)
	if [ -n "$r" ] && grep -qx "wireless.$r.disabled=1" "$S/committed" && [ ! -f "$S/stuck" ]; then
		rm -f "$S/netdev"; if [ -f "$S/stuck-ubus" ]; then echo up > "$S/radio"; else echo down > "$S/radio"; fi
	else
		echo wlh0 > "$S/netdev"; echo up > "$S/radio"
	fi
	[ -f "$S/stay-down" ] && { rm -f "$S/netdev"; echo down > "$S/radio"; }
}
if [ -f "$S/wifi.stale" ]; then   # ubus keeps the pre-reload view for N s (§19.1 ordering mutant)
	cp "$S/committed.prev" "$S/stale-cfg" 2>/dev/null || cp "$S/committed" "$S/stale-cfg"
	echo $(( $(date +%s) + $(cat "$S/wifi.stale") )) > "$S/stale-until"
fi
if [ -f "$S/wifi.async" ]; then   # netifd's teardown + setup takes N s: pending meanwhile, the final state after
	rm -f "$S/netdev"; echo down > "$S/radio"; : > "$S/pending"
	n=$(cat "$S/wifi.async")
	setsid bash -c "sleep $n; $(declare -f final); S=$S; final; rm -f '$S/pending'" >/dev/null 2>&1 </dev/null &
else
	final
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
	[ -s "$S/orphan" ] && [ "$(cat "$S/orphan")" != "$(cat "$S/netdev" 2>/dev/null)" ] && printf 'phy#1\n\tInterface %s\n\t\ttype mesh point\n' "$(cat "$S/orphan")"
	exit 0
fi
[ "$1" = dev ] && [ "${3:-}" = info ] && { [ -f "$S/netdev" ] || [ "$(cat "$S/orphan" 2>/dev/null)" = "$2" ]; exit; }
if [ "$1" = dev ] && [ "${3:-}" = del ]; then
	echo "$(cut -d. -f1 /proc/uptime) iw dev $2 del" >> "$S/iw.log"
	[ "$(cat "$S/orphan" 2>/dev/null)" = "$2" ] && rm -f "$S/orphan"
	[ "$(cat "$S/netdev" 2>/dev/null)" = "$2" ] && rm -f "$S/netdev"
	exit 0
fi
exit 0
EOF
	cat > "$ST/bin/ubus" <<'EOF'
#!/bin/bash
S=${STUB_ST:?}
echo "ubus fd9=$([ -e /proc/$$/fd/9 ] && echo open || echo closed)" >> "$S/fd9.log"
[ "$*" = "call network.wireless status" ] || exit 1
[ -f "$S/ubus.fail" ] && exit 1
cfg=$S/committed; p=false; u=; d=
if [ -f "$S/stale-until" ] && [ "$(date +%s)" -lt "$(cat "$S/stale-until")" ]; then cfg=$S/stale-cfg; u=true; d=false; fi
r=$(sed -n 's/^wireless\.\([^.]*\)\.type=morse$/\1/p' "$cfg" | head -1)
g(){ awk -v k="$1" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$cfg"; }
if [ -z "$u" ]; then
	if [ "$(cat "$S/radio" 2>/dev/null)" = down ]; then u=false; d=true; else u=true; d=false; fi
	[ -f "$S/pending" ] && p=true
fi
rsf=false; [ -f "$S/rsf" ] && rsf=true
p0=false; [ -f "$S/pending0" ] && p0=true
ms=$(sed -n "s/^wireless\.\([^.]*\)\.mode=mesh$/\1/p" "$cfg" | while read -r s; do [ "$(g "wireless.$s.device")" = "$r" ] && echo "$s"; done)
ifs=""
for sct in $ms; do
	ifs="$ifs$([ -n "$ifs" ] && echo ,)
		{ \"section\": \"$sct\", \"ifname\": \"wlh0\", \"config\": { \"mode\": \"mesh\", \"key\": \"$(g "wireless.$sct.key")\", \"mesh_id\": \"$(g "wireless.$sct.mesh_id")\" } }"
done
[ -f "$S/ubus.nosection" ] && r=""
printf '{\n\t"radio0": {\n\t\t"up": true,\n\t\t"pending": %s,\n\t\t"disabled": false\n\t}' "$p0"
[ -n "$r" ] && printf ',\n\t"%s": {\n\t\t"up": %s,\n\t\t"pending": %s,\n\t\t"disabled": %s,\n\t\t"retry_setup_failed": %s,\n\t\t"config": { "channel": "%s" },\n\t\t"interfaces": [%s ]\n\t}' "$r" "$u" "$p" "$d" "$rsf" "$(g "wireless.$r.channel")" "$ifs"
printf '\n}\n'
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
import re
def walk(v, keys):
    if not keys:
        return [v]
    k, rest = keys[0], keys[1:]
    m = re.match(r"^([^\[]*)(?:\[(\*|\d+)\])?$", k)
    name, idx = m.group(1), m.group(2)
    if name:
        if not isinstance(v, dict) or name not in v:
            return None
        v = v[name]
    if idx is None:
        return walk(v, rest)
    if not isinstance(v, list):
        return None
    if idx == "*":
        out = []
        for e in v:
            r = walk(e, rest)
            if r is None:
                return None
            out += r
        return out
    i = int(idx)
    return walk(v[i], rest) if i < len(v) else None
v = walk(json.load(sys.stdin), a[1][2:].split("."))
if v is None:
    sys.exit(1)
for x in v:
    print(json.dumps(x) if isinstance(x, (bool, dict, list)) else x)
EOF
	cat > "$ST/bin/pgrep" <<'EOF'
#!/bin/bash
# `pgrep -f <ERE>`: records the call; answers the pids of s1g.pids when the pattern names the orphan netdev
S=${STUB_ST:?}
echo "$(cut -d. -f1 /proc/uptime) pgrep $*" >> "$S/pgrep.log"
[ "$1" = -f ] || exit 1
o=$(cat "$S/orphan" 2>/dev/null); [ -n "$o" ] || exit 1
case "$2" in *"-i $o"*|*"-i ${o//./\\.}"*) [ -s "$S/s1g.pids" ] && { cat "$S/s1g.pids"; exit 0; } ;; esac
exit 1
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
# stub_sys <radio> <path>: the fake /sys the forget escalation reads — ieee80211/phy1/device resolves to <path> (the
# radio's uci `path`), net/wlh0/phy80211 -> phy1, net/wlhx/phy80211 -> phy0 (a mesh netdev on the OTHER phy)
stub_sys() {
	rm -rf "$ST/sys"; mkdir -p "$ST/sys/ieee80211/phy0" "$ST/sys/ieee80211/phy1" "$ST/sys/net/wlh0" "$ST/sys/net/wlhx" "$ST/sys/devices/$2" "$ST/sys/devices/other"
	ln -s "$ST/sys/devices/$2" "$ST/sys/ieee80211/phy1/device"; ln -s "$ST/sys/devices/other" "$ST/sys/ieee80211/phy0/device"
	ln -s "$ST/sys/ieee80211/phy1" "$ST/sys/net/wlh0/phy80211"; ln -s "$ST/sys/ieee80211/phy0" "$ST/sys/net/wlhx/phy80211"
}
commits() { grep -c '^--- commit' "$ST/commits.log"; }
committed_get() { awk -v k="$1" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$ST/committed"; }
