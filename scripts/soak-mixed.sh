#!/bin/bash
# soak-mixed.sh — 12h mixed-traffic soak for CPU attribution profiling.
#
# Drives manet01 <-> manet02 over HaLow with a rotation of realistic traffic
# types while deep-sample.sh (running on each node) attributes CPU time to
# processes / IRQs / softirqs. Runs from the desktop over SSH; the samplers and
# iperf servers run detached on the nodes so they survive ssh drops.
#
#   DUR=43200 PHASE=300 ./soak-mixed.sh
#
# Phase markers are written on each NODE (node clock) so they line up with the
# node's sampler CSV timestamps. Background ping logs node<->node RTT throughout.
set +e
M1=${M1:-10.41.239.205}          # manet01 (clean reference)
M2=${M2:-10.41.254.156}          # manet02 (runs FTS; partner)
DUR=${DUR:-43200}                # 12 h
PHASE=${PHASE:-300}              # 5 min per phase
OUT=${OUT:-/tmp/soakprof}
IVL=${IVL:-10}
SAMPLE_CPU=${SAMPLE_CPU:-3}
LOG=${LOG:-$HOME/soak-mixed.log}
SSH="ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=15"
MCAST=239.2.3.1

log(){ echo "$(date '+%F %T') $*" >> "$LOG"; }
on(){ $SSH root@$1 "$2" 2>/dev/null; }          # on NODE run cmd
# write a phase marker on both nodes using the node's own clock
mark(){ for H in $M1 $M2; do $SSH root@$H "echo \"\$(date '+%F %T'),$1,$2\" >> $OUT/phases.csv" 2>/dev/null; done; }

log "=== soak-mixed start: DUR=${DUR}s PHASE=${PHASE}s M1=$M1 M2=$M2 ==="

# --- one-time setup on both nodes: clean, sampler, iperf servers, ping ---
for H in $M1 $M2; do
  on $H "rm -rf $OUT; mkdir -p $OUT; echo 'ts,marker,name' > $OUT/phases.csv"
  on $H "setsid sh -c 'OUT=$OUT IVL=$IVL CPU=$SAMPLE_CPU /tmp/deep-sample.sh >$OUT/samp.log 2>&1' >/dev/null 2>&1 &"
  # UDP servers 5001-5005, TCP 5011-5012, multicast receiver on 6969
  on $H "for p in 5001 5002 5003 5004 5005; do (ss -lun 2>/dev/null|grep -q :\$p ) || setsid iperf -su -p \$p >/dev/null 2>&1 & done"
  on $H "for p in 5011 5012; do (ss -ltn 2>/dev/null|grep -q :\$p ) || setsid iperf -s -p \$p >/dev/null 2>&1 & done"
  on $H "setsid iperf -su -B $MCAST -p 6969 >/dev/null 2>&1 &"
done
# background RTT probe: manet02 -> manet01, 1/s, timestamped, for the whole run
on $M2 "setsid sh -c 'ping -i 1 $M1 | while read line; do echo \"\$(date +%s) \$line\"; done > $OUT/ping.log 2>&1' >/dev/null 2>&1 &"
sleep 3

# ---- phase generators (each backgrounds clients, returns immediately) ----
# bidirectional UDP fixed payload
udp(){ local L=$1 R=$2 pt=$3 T=$4
  on $M1 "setsid iperf -c $M2 -u -b $R -l $L -t $T -p $pt >/dev/null 2>&1 &"
  on $M2 "setsid iperf -c $M1 -u -b $R -l $L -t $T -p $pt >/dev/null 2>&1 &"; }
# one-direction UDP (video-like)
udp1(){ local L=$1 R=$2 pt=$3 T=$4
  on $M1 "setsid iperf -c $M2 -u -b $R -l $L -t $T -p $pt >/dev/null 2>&1 &"; }
# bidirectional TCP bulk
tcp(){ local T=$1
  on $M1 "setsid iperf -c $M2 -t $T -p 5011 >/dev/null 2>&1 &"
  on $M2 "setsid iperf -c $M1 -t $T -p 5012 >/dev/null 2>&1 &"; }
# multicast CoT-like (both nodes send small pkts to the group)
mcast(){ local T=$1
  on $M1 "setsid iperf -c $MCAST -u -T 5 -b 4M -l 300 -t $T -p 6969 >/dev/null 2>&1 &"
  on $M2 "setsid iperf -c $MCAST -u -T 5 -b 4M -l 300 -t $T -p 6969 >/dev/null 2>&1 &"; }
# voice CBR: several small steady streams each way
voice(){ local T=$1
  for s in 1 2 3; do
    on $M1 "setsid iperf -c $M2 -u -b 128K -l 160 -t $T -p 5003 >/dev/null 2>&1 &"
    on $M2 "setsid iperf -c $M1 -u -b 128K -l 160 -t $T -p 5003 >/dev/null 2>&1 &"
  done; }
# PPS ceiling: tiny packets blasted
pps(){ local T=$1
  on $M1 "setsid iperf -c $M2 -u -b 25M -l 64 -t $T -p 5002 >/dev/null 2>&1 &"
  on $M2 "setsid iperf -c $M1 -u -b 25M -l 64 -t $T -p 5002 >/dev/null 2>&1 &"; }

run_phase(){
  local name=$1 T=$2
  mark PHASE_START "$name"
  log "phase $name (${T}s)"
  case $name in
    idle)      : ;;                                   # baseline, no load
    udp_1400)  udp 1400 8M  5001 $T ;;
    udp_800)   udp 800  6M  5001 $T ;;
    udp_400)   udp 400  4M  5001 $T ;;
    udp_200)   udp 200  3M  5001 $T ;;
    udp_100)   udp 100  2M  5001 $T ;;
    pps_64)    pps  $T ;;
    tcp_bulk)  tcp  $T ;;
    multicast) mcast $T ;;
    voice)     voice $T ;;
    video)     udp1 1400 10M 5004 $T ;;
    mixed)     mcast $T; tcp $T; voice $T ;;          # concurrent
  esac
  sleep $T
  on $M1 "killall iperf 2>/dev/null"; on $M2 "killall iperf 2>/dev/null"
  # restart the persistent servers that killall just took down
  for H in $M1 $M2; do
    on $H "for p in 5001 5002 5003 5004 5005; do setsid iperf -su -p \$p >/dev/null 2>&1 & done; for p in 5011 5012; do setsid iperf -s -p \$p >/dev/null 2>&1 & done; setsid iperf -su -B $MCAST -p 6969 >/dev/null 2>&1 &"
  done
  mark PHASE_END "$name"
  sleep 3
}

PHASES=(idle udp_1400 udp_800 udp_400 udp_200 udp_100 pps_64 tcp_bulk multicast voice video mixed)
START=$(date +%s); i=0
while :; do
  NOW=$(date +%s); EL=$((NOW-START))
  [ $EL -ge $DUR ] && { log "duration reached ($EL s)"; break; }
  [ -f "$OUT.STOP" ] && { log "local STOP"; break; }
  name=${PHASES[$((i % ${#PHASES[@]}))]}
  run_phase "$name" "$PHASE"
  i=$((i+1))
done

# cleanup: stop samplers, ping, iperf
for H in $M1 $M2; do on $H "touch $OUT/STOP; sleep 1; killall iperf 2>/dev/null; killall ping 2>/dev/null"; done
log "=== soak-mixed end: $i phases over $(( $(date +%s) - START ))s ==="
