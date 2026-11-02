#!/bin/sh
# scripts/node/prov-orphan-254.sh <forget|noforget|cleanup> — node side of prov-forget-orphan-254 (#254 wireless-txn
# §19.6): the orphan of §19.1 rebuilt by hand — the morse radio taken down the way a forget does it (placeholder key,
# disabled=1, keyguard mark, one commit, wifi reload, netifd down), then a mesh netdev with the SAME name recreated on
# the morse phy, named in /var/state splist as morse.sh:594 writes it, with a root wpa_supplicant_s1g on it. Then
#   forget    halow-setkey --forget-mesh (the fixed setkey escalates: E2 kill + E3 del -> rc 0; wsl.15: rc 3)
#   noforget  nothing (arm 2: does netifd's own next setup clean an orphan it has in its splist? outcome recorded)
# and in both arms the rebuild on hardware: the node's own mesh key / id / channel back by halow-setkey (the key from
# uci over stdin, root-only, never printed), netifd up, meshjoin_radio_up.
#   cleanup   kill the recorded s1g, delete the netdev, remove the run dir (the host runs it on every exit)
# Prints one line per step; the host judges. Secrets: the key lives only in the 0700 run dir and is removed here.
set -u
D=/tmp/run/batman-dv/orphan
if [ "${1:-}" = cleanup ]; then
	p=$(cat $D/pid 2>/dev/null); [ -n "$p" ] && kill "$p" 2>/dev/null
	d=$(cat $D/dev 2>/dev/null); [ -n "$d" ] && [ -d "/sys/class/net/$d" ] && [ "$(ubus call network.wireless status 2>/dev/null | jsonfilter -e "@.$(cat $D/radio 2>/dev/null).up" 2>/dev/null)" != true ] && iw dev "$d" del 2>/dev/null
	rm -rf $D; echo "CLEANUP done"; exit 0
fi
mkdir -p $D; chmod 700 $D; umask 077
R=$(uci show wireless 2>/dev/null | sed -n "s/^wireless\.\([^.]*\)\.type='morse'$/\1/p" | head -1)
MS=""; for s in $(uci show wireless 2>/dev/null | sed -n "s/^wireless\.\([^.]*\)\.mode='mesh'$/\1/p"); do [ "$(uci -q get "wireless.$s.device")" = "$R" ] && { MS=$s; break; }; done
md(){ iw dev 2>/dev/null | awk '/^\tInterface/{i=$2} /type mesh point/{print i; exit}'; }
DEV=$(md)
[ -n "$R" ] && [ -n "$MS" ] && [ -n "$DEV" ] || { echo "INVALID no morse radio / mesh iface / mesh netdev (R=[$R] MS=[$MS] DEV=[$DEV])"; exit 2; }
PHY=$(basename "$(readlink -f "/sys/class/net/$DEV/phy80211")")
echo "$R" > $D/radio; echo "$DEV" > $D/dev
uci -q get "wireless.$MS.key" > $D/key; ID=$(uci -q get "wireless.$MS.mesh_id"); CH=$(uci -q get "wireless.$R.channel")
[ -s $D/key ] && [ -n "$ID" ] && [ -n "$CH" ] || { echo "INVALID no key / mesh id / channel in uci"; exit 2; }
cp "/var/run/wpa_supplicant-$DEV.conf" $D/s1g.conf 2>/dev/null || { echo "INVALID no /var/run/wpa_supplicant-$DEV.conf"; exit 2; }
st(){ s=$(ubus call network.wireless status 2>/dev/null); echo "up=$(printf '%s' "$s" | jsonfilter -e "@.$R.up") dis=$(printf '%s' "$s" | jsonfilter -e "@.$R.disabled") pend=$(printf '%s' "$s" | jsonfilter -e "@.$R.pending") meshdev=$(md) s1g=[$(pgrep -f "wpa_supplicant_s1g .*-i $DEV( |\$)" | tr '\n' ,)]"; }
echo "O0 radio=$R iface=$MS dev=$DEV phy=$PHY id=$ID ch=$CH before: $(st)"
# 1. the radio down the way --forget-mesh stages it (one commit), netifd's own teardown
uci -q set "wireless.$MS.key=CHANGE-ME-NOW"; uci -q set "wireless.$R.disabled=1"; uci commit wireless
prev=""; [ -f /etc/halow-keyguard.blocked ] && { read -r prev < /etc/halow-keyguard.blocked || true; }
echo "$prev $R" > /etc/halow-keyguard.blocked
wifi reload >/dev/null 2>&1
i=0; while [ "$i" -lt 30 ]; do s=$(st); case "$s" in *"up=false"*"dis=true"*"pend=false"*"meshdev= "*) break ;; esac; sleep 1; i=$((i + 1)); done
echo "O1 netifd down after ${i}s: $(st)"
case "$(st)" in *"up=false"*"dis=true"*"pend=false"*"meshdev= "*) ;; *) echo "INVALID netifd did not take the radio down"; exit 2 ;; esac
# 2. the orphan: the netdev as morse.sh creates it, the splist line, a root wpa_supplicant_s1g on it
iw phy "$PHY" interface add "$DEV" type mp 2>&1 || { echo "INVALID iw interface add failed"; exit 2; }
# netifd's teardown may have dropped the whole _phy section (then `uci set` of an option fails, rc 1): recreate it
uci -q -P /var/state get "wireless._$PHY" >/dev/null 2>&1 || uci -q -P /var/state set "wireless._$PHY=state"
uci -q -P /var/state set "wireless._$PHY.splist= $DEV "
/usr/sbin/wpa_supplicant_s1g -t -D nl80211 -s -i "$DEV" -c $D/s1g.conf -B 2>&1; sleep 3
PID=$(pgrep -f "wpa_supplicant_s1g .*-i $DEV( |\$)" | head -1); echo "$PID" > $D/pid
if [ "$(md)" = "$DEV" ] && [ -n "$PID" ] && [ "$(readlink "/proc/$PID/exe")" = /usr/sbin/wpa_supplicant_s1g ]; then
	echo "ORPHAN ok dev=$DEV pid=$PID splist=[$(uci -q -P /var/state get "wireless._$PHY.splist")]: $(st)"
else
	echo "INVALID orphan not created (meshdev=$(md) pid=[$PID]): $(st)"; exit 2
fi
# 3. the arm
if [ "$1" = forget ]; then
	t0=$(cut -d. -f1 /proc/uptime); out=$(halow-setkey --forget-mesh --no-persist 2>&1); rc=$?
	echo "FORGET rc=$rc t=$(( $(cut -d. -f1 /proc/uptime) - t0 ))s :: $(echo "$out" | tail -1)"
	echo "FORGET-AFTER $(st) pidalive=$(kill -0 "$PID" 2>/dev/null && echo yes || echo no) escalation-logged=$(logread 2>/dev/null | grep -c 'forgotten after escalation')"
fi
# 4. the rebuild on hardware: the node's own network back by setkey (the key over stdin)
t0=$(cut -d. -f1 /proc/uptime); out=$(halow-setkey --mesh - --mesh-id "$ID" --channel "$CH" --no-persist < $D/key 2>&1); rc=$?
echo "RESTORE rc=$rc t=$(( $(cut -d. -f1 /proc/uptime) - t0 ))s :: $(echo "$out" | tail -1)"
echo "RESTORE-AFTER $(st) splist=[$(uci -q -P /var/state get "wireless._$PHY.splist")] pidalive=$(kill -0 "$PID" 2>/dev/null && echo yes || echo no) mark=[$(head -1 /etc/halow-keyguard.blocked 2>/dev/null)]"
# shellcheck source=/dev/null
. /usr/lib/batman/meshjoin.sh
i=0; while [ "$i" -lt 90 ] && ! meshjoin_radio_up; do sleep 2; i=$((i + 2)); done
echo "MESHUP $(meshjoin_radio_up >/dev/null 2>&1 && echo yes || echo no) after ${i}s"
rm -f $D/key $D/s1g.conf
echo "ARM-DONE $1"
