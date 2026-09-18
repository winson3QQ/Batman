#!/bin/sh
# Single-node retune-primitive dwell sweep (manet01). /proc/uptime busy-wait timer (10ms res).
# Isolates driver/primitive floor from coordination drift. Control is out-of-band (ahwlan).
R="-c 924000 -o 8 -p 2 -n 3"
F1="-c 908000 -o 8 -p 2 -n 3"; F2="-c 916000 -o 8 -p 2 -n 3"; F3="-c 924000 -o 8 -p 2 -n 3"
restore(){ morse_cli -i wlh0 channel $R >/dev/null 2>&1; }
trap 'restore' EXIT INT TERM
cs(){ read a b < /proc/uptime; f=1${a#*.}; echo $(( ${a%.*}*100 + f - 100 )); }
waitcs(){ read a b < /proc/uptime; f=1${a#*.}; t=$(( ${a%.*}*100 + f - 100 + $1 ))
  while :; do read a b < /proc/uptime; f=1${a#*.}; [ $(( ${a%.*}*100 + f - 100 )) -ge "$t" ] && break; done; }

# --- bare retune cost (no readback), 20 sets ---
S=$(cs); i=0; while [ "$i" -lt 20 ]; do morse_cli -i wlh0 channel $R >/dev/null 2>&1; i=$((i+1)); done; E=$(cs)
echo "bare_retune: 20 sets in $((E-S))cs => ~$(( (E-S)*10/20 ))ms per retune"
restore; sleep 1

echo "dwell_cs hops wall_cs achieved_hops_per_s meshvif readback dmesg_err"
for D in 100 50 20 10 5; do
  dm0=$(dmesg | wc -l)
  S=$(cs); hops=0
  while [ "$hops" -lt 30 ]; do
    case $((hops%3)) in 0) C="$F1";; 1) C="$F2";; *) C="$F3";; esac
    morse_cli -i wlh0 channel $C >/dev/null 2>&1
    waitcs "$D"
    hops=$((hops+1))
  done
  restore; E=$(cs)
  IW=$(iw dev wlh0 info 2>/dev/null | grep -c "type mesh point")
  RB=$(morse_cli -i wlh0 channel 2>/dev/null | awk -F': ' '/Frequency/{print $2}')
  ERR=$(dmesg | tail -n +$((dm0+1)) | grep -icE "error|fail|reset|timeout|hang|watchdog|morse|deauth")
  W=$((E-S)); RATE=$(( 3000 / (W>0?W:1) ))
  echo "$D 30 $W ${RATE}e-1 mesh=$IW $RB err=$ERR"
  if [ "$ERR" -gt 0 ]; then echo "  !! dmesg:"; dmesg | tail -n +$((dm0+1)) | grep -iE "error|fail|reset|timeout|hang|watchdog|morse|deauth" | tail -6; echo "  ABORT"; break; fi
  [ "$IW" -ne 1 ] && { echo "  !! wlh0 lost mesh vif — ABORT"; break; }
  sleep 1
done
restore; sleep 2; restore
echo "FINAL readback=$(morse_cli -i wlh0 channel 2>/dev/null | awk -F': ' '/Frequency/{print $2}')  meshvif=$(iw dev wlh0 info 2>/dev/null | grep -c 'type mesh point')"
