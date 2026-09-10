#!/bin/bash
# soak-stress.sh — sustained heavy bidirectional load to accelerate the manet02
# hang/reboot for crash debugging (no idle/light phases, oversubscribed, small+large
# packet mix to press the Morse SPI path). FTS is left running on manet02 (repro
# condition). Marks chunks into manet02's phases.csv (node clock) for the sampler.
#
#   DUR=21600 ./soak-stress.sh        # 6 h cap; ends on reboot-driven kill or STOP
#   touch /tmp/soakstress.STOP        # stop
set +e
M1=${M1:-10.41.239.205}          # manet01 (load partner, stable)
M2=${M2:-10.41.254.156}          # manet02 (target — runs FTS, expected to hang)
OUT=/tmp/soakprof
DUR=${DUR:-21600}
CHUNK=${CHUNK:-120}
LOG=${LOG:-/c/Users/yello/Desktop/Batman/soak-stress.log}
SSH="ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=15"
on(){ $SSH root@$1 "$2" 2>/dev/null; }
log(){ echo "$(date '+%F %T') $*" >> "$LOG"; }

log "=== stress start: M2=$M2 target, offered ~26M aggregate on ~10M link ==="
# UDP servers on both (5001/5002 recv on M2, 5003/5004 recv on M1)
for H in $M1 $M2; do
  on $H "for p in 5001 5002 5003 5004; do (ss -lun 2>/dev/null|grep -q :\$p)||setsid iperf -su -p \$p >/dev/null 2>&1 & done"
done
sleep 2
START=$(date +%s); i=0
while :; do
  [ $(( $(date +%s)-START )) -ge $DUR ] && { log "duration cap"; break; }
  [ -f /tmp/soakstress.STOP ] && { log "STOP file"; break; }
  on $M2 "echo \"\$(date '+%F %T'),STRESS,chunk$i\" >> $OUT/phases.csv"
  # re-arm servers each chunk in case a reboot took them down
  on $M1 "for p in 5003 5004; do (ss -lun 2>/dev/null|grep -q :\$p)||setsid iperf -su -p \$p >/dev/null 2>&1 & done"
  on $M2 "for p in 5001 5002; do (ss -lun 2>/dev/null|grep -q :\$p)||setsid iperf -su -p \$p >/dev/null 2>&1 & done"
  # heavy bidirectional: large-throughput + tiny-packet SPI pressure, both ways
  on $M1 "setsid iperf -c $M2 -u -b 8M -l 1400 -t $CHUNK -p 5001 >/dev/null 2>&1 & setsid iperf -c $M2 -u -b 5M -l 64 -t $CHUNK -p 5002 >/dev/null 2>&1 &"
  on $M2 "setsid iperf -c $M1 -u -b 8M -l 1400 -t $CHUNK -p 5003 >/dev/null 2>&1 & setsid iperf -c $M1 -u -b 5M -l 64 -t $CHUNK -p 5004 >/dev/null 2>&1 &"
  log "chunk $i launched"
  sleep $CHUNK
  i=$((i+1))
done
for H in $M1 $M2; do on $H "killall iperf 2>/dev/null"; done
log "=== stress end: $i chunks ==="
