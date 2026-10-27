#!/bin/bash
# scripts/dv/addr-defer-reconcile-254.sh <node> — host runner of scripts/node/addr-defer-reconcile-254.sh (#254 B-M4,
# 254-p1-impl.md §13.8.2): r1 flip, r1, reboot, r2 flip, r2, reboot. Each case runs DETACHED on the node (an ssh drop
# cannot cut it in half) and ends with DONE; the host polls the log. Verdict: r1 / r2 "RESULT … PASS" and both flips
# "FLIP … VALID"; any missing line = FAIL. Two reboots (`batman-slot reboot committed`), committed node only.
set -u
NODE=${1:?usage: $0 <node>}; REPO=$(cd "$(dirname "$0")/../.." && pwd)
SSHO="-o BatchMode=yes -o ConnectTimeout=6 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 -o LogLevel=ERROR -o IdentitiesOnly=yes"
q(){ timeout 60 ssh $SSHO "root@$NODE" "$@" 2>/dev/null | tr -d '\r'; }
qrc(){ timeout 60 ssh $SSHO "root@$NODE" "$@" >/dev/null 2>&1; }   # rc = the remote command's rc (q's rc is tr's)
bid(){ q 'cat /proc/sys/kernel/random/boot_id' | tr -d '\n '; }
fails=0; ok(){ echo "PASS $*"; }; no(){ echo "FAIL $*"; fails=$((fails + 1)); }
reboot_c(){ local b0 b t u; b0=$(bid); q "(batman-slot reboot committed adr-254 </dev/null >/dev/null 2>&1 &)"; t=$SECONDS
	while [ $((SECONDS - t)) -lt 900 ]; do sleep 10; b=$(bid); [ -n "$b" ] && [ "$b" != "$b0" ] && break; done
	[ -n "$b" ] && [ "$b" != "$b0" ] || { no "reboot did not happen within 900 s"; return 1; }
	while [ $((SECONDS - t)) -lt 900 ]; do u=$(q 'cut -d. -f1 /proc/uptime'); [ "${u:-0}" -ge 120 ] && break; sleep 10; done
	echo "[$(date +%T)] rebooted: $(q '/usr/libexec/batman-addr-defer status; batman-slot active') up=$(q 'cut -d. -f1 /proc/uptime')"; }
one(){ local c="$1" fl="${2:-}" log="/tmp/run/batman-dv/adr-$1${2:+-$2}.log" t o
	q "mkdir -p -m 0700 /tmp/run/batman-dv"
	scp -q $SSHO "$REPO/scripts/node/addr-defer-reconcile-254.sh" "root@$NODE:/tmp/run/batman-dv/adr.sh" || { no "$c $fl: upload failed"; return 1; }
	q "chmod 700 /tmp/run/batman-dv/adr.sh; rm -f $log; setsid sh /tmp/run/batman-dv/adr.sh $c $fl > $log 2>&1 < /dev/null &"
	t=$SECONDS; while [ $((SECONDS - t)) -lt 600 ]; do sleep 5; qrc "grep -q '^DONE' $log" && break; done
	o=$(q "cat $log"); echo "=== $c $fl ($((SECONDS - t)) s)"; echo "$o"
	grep -q '^DONE' <<< "$o" || { no "$c $fl: no DONE after 600 s — sequence stopped"; return 1; }
	if [ -n "$fl" ]; then grep -qE "^FLIP $c(-flip)? VALID$" <<< "$o" && ok "$c flip VALID" || no "$c flip not VALID"
	else grep -q "^RESULT $c PASS" <<< "$o" && ok "$c PASS" || no "$c not PASS"; fi; }
echo "[$(date +%T)] start on $NODE: $(q '/usr/libexec/batman-addr-defer status')"
q 'batman-slot is-trial >/dev/null 2>&1; echo $?' | grep -qx 1 || { no "node is not on a committed slot"; echo "RESULT addr-defer-reconcile-254 FAIL"; exit 1; }
one r1 flip && one r1 && reboot_c && one r2 flip && one r2 && reboot_c
echo "RESULT addr-defer-reconcile-254 $([ $fails = 0 ] && echo PASS || echo FAIL)"; [ $fails = 0 ]
