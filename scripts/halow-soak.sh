#!/bin/bash
# halow-soak.sh — long-run endurance test for the HaLow mesh.
#
# Bidirectional UDP load, both directions running at once, cycling the payload
# size so the run covers mixed packet lengths rather than one profile. Offered
# rate per phase is ~70% of that size's measured one-way ceiling, so packet loss
# stays a real signal instead of a saturation artefact.
#
#   ./halow-soak.sh                  # 12 h, 5 min phases
#   DUR=3600 PHASE=120 ./halow-soak.sh
#   touch ~/halow-soak/STOP          # stop after the current phase
#
# Writes ~/halow-soak/soak.csv (one row per phase) and soak.log (human readable).
# Designed to survive node IP changes, ssh drops, dead iperf servers and mesh
# re-peering — it logs the failure and carries on rather than aborting.

OUT=${OUT:-$HOME/halow-soak}
DUR=${DUR:-43200}          # 12 h
PHASE=${PHASE:-300}        # 5 min
LL=${LL:-root@fe80::f0da:3ff:fe5a:883%bat0}
SELF=10.41.250.1
IF=wlan1
mkdir -p "$OUT"
CSV=$OUT/soak.csv
LOG=$OUT/soak.log
SSH="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 -o ServerAliveInterval=5"

log(){ echo "$(date '+%F %T') $*" >> "$LOG"; }

# payload -> offered rate per direction (~70% of the measured one-way ceiling)
rate_for(){ case $1 in 1400) echo 4M;; 800) echo 3M;; 400) echo 2M;; 200) echo 1500K;; 100) echo 1200K;; esac; }

find_node(){
  for t in 1 2 3 4 5; do
    N=$($SSH "$LL" "ip -4 addr show br-ahwlan | grep -oE '10\.[0-9.]+' | head -1" 2>/dev/null)
    [ -n "$N" ] && { echo "$N"; return 0; }
    sleep 5
  done
  return 1
}

ensure_servers(){                       # $1 = node ip
  for pt in 5001 5002 5003; do
    ss -lun 2>/dev/null | grep -q ":$pt " || { setsid iperf -su -p $pt >/dev/null 2>&1 & sleep 1; }
  done
  $SSH "root@$1" 'for pt in 5001 5002 5003; do (ss -lun 2>/dev/null || netstat -lun 2>/dev/null) | grep -q ":$pt " || (setsid iperf -su -p $pt >/dev/null 2>&1 &); done' 2>/dev/null
}

parse(){ echo "$1" | grep -oE "$2" | tail -1 | grep -oE "[0-9.]+" | head -1; }

[ -f "$CSV" ] || echo "ts,elapsed_s,phase,pktlen,dl_mbps,dl_loss_pct,ul_mbps,ul_loss_pct,ul_jitter_ms,rssi_dbm,tx_failed,tx_retries,mem_avail_kb,slab_kb,chip_temp_c,plink,note" > "$CSV"

log "=== soak start: DUR=${DUR}s PHASE=${PHASE}s ==="
START=$(date +%s); P=0; SIZES=(1400 800 400 200 100 MIX)

while :; do
  NOW=$(date +%s); EL=$((NOW-START))
  [ $EL -ge $DUR ] && { log "duration reached"; break; }
  [ -f "$OUT/STOP" ] && { log "STOP file found"; break; }

  L=${SIZES[$((P % 6))]}
  NODE=$(find_node) || { log "phase $P: node unreachable, retrying in 60s"
    echo "$(date '+%F %T'),$EL,$P,$L,,,,,,,,,,,,,NODE_UNREACHABLE" >> "$CSV"; sleep 60; P=$((P+1)); continue; }
  ensure_servers "$NODE"

  DLF=$OUT/.dl; ULF=$OUT/.ul; : > $DLF; : > $ULF
  if [ "$L" = MIX ]; then
    # three payload sizes concurrently in each direction
    # MIX rates are lower than the single-size phases: three concurrent streams must
    # sum to ~60% of capacity, not 3x it, or the phase clips and loss stops being a signal
    ( pt=5001; for sp in "1400 1500K" "400 800K" "100 500K"; do set -- $sp; iperf -c "$NODE" -u -b $2 -t $PHASE -l $1 -p $pt >> $DLF 2>&1 & pt=$((pt+1)); done; wait ) &
    DLPID=$!
    ( $SSH "root@$NODE" "iperf -c $SELF -u -b 1500K -t $PHASE -l 1400 -p 5001 & iperf -c $SELF -u -b 800K -t $PHASE -l 400 -p 5002 & iperf -c $SELF -u -b 500K -t $PHASE -l 100 -p 5003 & wait" >> $ULF 2>&1 ) &
    ULPID=$!
  else
    R=$(rate_for $L)
    ( iperf -c "$NODE" -u -b $R -t $PHASE -l $L >> $DLF 2>&1 ) & DLPID=$!
    ( $SSH "root@$NODE" "iperf -c $SELF -u -b $R -t $PHASE -l $L" >> $ULF 2>&1 ) & ULPID=$!
  fi

  wait $DLPID 2>/dev/null; wait $ULPID 2>/dev/null

  sum_mbps(){ awk '{for(i=1;i<=NF;i++){if($i=="Mbits/sec") s+=$(i-1); else if($i=="Kbits/sec") s+=$(i-1)/1000}} END{printf "%.2f", s/2}' "$1"; }
  DL=$(sum_mbps $DLF)
  DLL=$(grep -oE "\([0-9.]+%\)" $DLF | tr -d '()%' | awk '{s+=$1; n++} END{if(n) printf "%.3f", s/n}')
  UL=$(sum_mbps $ULF)
  ULL=$(grep -oE "\([0-9.]+%\)" $ULF | tr -d '()%' | awk '{s+=$1; n++} END{if(n) printf "%.3f", s/n}')
  ULJ=$(grep -oE "[0-9.]+ ms" $ULF | tail -1 | grep -oE "[0-9.]+")

  D=$(iw dev $IF station dump 2>/dev/null)
  RSSI=$(echo "$D" | awk '/signal:/{print $2; exit}')
  TXF=$(echo "$D"  | awk '/tx failed:/{print $3; exit}')
  TXR=$(echo "$D"  | awk '/tx retries:/{print $3; exit}')
  PLINK=$(echo "$D" | grep -c "ESTAB")
  MA=$(awk '/^MemAvailable/{print $2}' /proc/meminfo)
  SL=$(awk '/^Slab:/{print $2}' /proc/meminfo)
  TEMP=$(sudo -n morse_cli -i $IF stats 2>/dev/null | awk -F: '/Temperature \(C\)/{gsub(/ /,"",$2); print $2}')

  echo "$(date '+%F %T'),$EL,$P,$L,${DL:-},${DLL:-},${UL:-},${ULL:-},${ULJ:-},${RSSI:-},${TXF:-},${TXR:-},$MA,$SL,${TEMP:-},$PLINK," >> "$CSV"
  log "phase $P len=$L dl=${DL}Mbps/${DLL}% ul=${UL}Mbps/${ULL}% rssi=$RSSI txfail=$TXF temp=${TEMP}C mem=$MA slab=$SL plink=$PLINK"
  P=$((P+1))
done

killall iperf 2>/dev/null
NODE=$(find_node) && $SSH "root@$NODE" 'killall iperf 2>/dev/null' 2>/dev/null
log "=== soak end: $P phases over $(( $(date +%s) - START ))s ==="
