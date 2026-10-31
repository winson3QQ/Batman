#!/bin/sh
# scripts/node/prov-sampler-254.sh <start|stop> — node side of prov-leave-after-join-254 (#254 wireless-txn §19.6):
# a 1 Hz sample of netifd's view of the morse radio and the mesh netdev, plus `logread -f`, into the root-only run dir
# /tmp/run/batman-dv/sampler. No key, no config value is recorded (the status blob carries the key; only booleans and
# names are extracted). `stop` kills both and prints the sample count.
set -u
D=/tmp/run/batman-dv/sampler
if [ "${1:-}" = stop ]; then
	for p in $(cat $D/pids 2>/dev/null); do kill "$p" 2>/dev/null; done
	echo "SAMPLER stopped samples=$(wc -l < $D/wl.log 2>/dev/null) logread=$(wc -l < $D/logread.log 2>/dev/null)"; exit 0
fi
mkdir -p $D; chmod 700 $D; : > $D/wl.log
R=$(uci show wireless 2>/dev/null | sed -n "s/^wireless\.\([^.]*\)\.type='morse'$/\1/p" | head -1)
logread -f > $D/logread.log 2>&1 &
echo $! > $D/pids
(
	while :; do
		s=$(ubus call network.wireless status 2>/dev/null)
		echo "$(cut -d. -f1 /proc/uptime) up=$(printf '%s' "$s" | jsonfilter -e "@.$R.up") dis=$(printf '%s' "$s" | jsonfilter -e "@.$R.disabled") pend=$(printf '%s' "$s" | jsonfilter -e "@.$R.pending") meshdev=$(iw dev 2>/dev/null | awk '/^\tInterface/{i=$2} /type mesh point/{print i; exit}') txn=$(ls /etc/batman-prov/.txn 2>/dev/null | wc -l)"
		sleep 1
	done >> $D/wl.log
) &
echo $! >> $D/pids
echo "SAMPLER started radio=$R"
