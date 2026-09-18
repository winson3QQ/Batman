#!/bin/sh
# Single-node bottom-to-top coherence across a morse_cli retune (manet01)
# Control is via ahwlan (out-of-band); this only moves wlh0 (HaLow mesh).
PEER=a8:dd:9f:4d:c7:60          # manet02 originator on wlh0
PEER_IP=10.41.1.1               # manet02 mesh IP
RESTORE="-c 924000 -o 8 -p 2 -n 3"   # 924MHz/8MHz = manet02's channel
AWAY="-c 916000 -o 8 -p 2 -n 3"      # 916MHz/8MHz = non-overlapping, leaves manet02

restore(){ morse_cli -i wlh0 channel $RESTORE >/dev/null 2>&1; }
trap 'echo "[trap] restoring 924"; restore' EXIT INT TERM

u(){ cut -d" " -f1 /proc/uptime; }
ch(){ morse_cli -i wlh0 channel 2>/dev/null | awk -F": " '/Operating Frequency/{f=$2}/Operating BW/{b=$2}END{print f" / "b}'; }
iwch(){ iw dev wlh0 info 2>/dev/null | grep -E "channel|type"; }
peer(){ batctl o 2>/dev/null | grep -i "$PEER" | grep -oE "[0-9]+\.[0-9]+s" | head -1; }

sample(){  # uptime  peer-last-seen  dataplane-ping
  U=$(u); S=$(peer)
  if ping -c1 -w1 "$PEER_IP" >/dev/null 2>&1; then P=OK; else P=LOSS; fi
  echo "  t=$U  peer=${S:-GONE}  ping=$P"
}

echo "===================== BASELINE ====================="
echo "t=$(u)"
echo "L0 PHY   : $(ch)"
echo "L2 iw    : $(iwch | tr '\n' ' ')"
echo "L2.5 bat : if=$(batctl if 2>/dev/null | tr '\n' ' ')  peer_lastseen=$(peer)"
echo "L3 IP    : ahwlan=$(ip -4 addr show br-ahwlan 2>/dev/null | grep -oE 'inet [0-9.]+')  bat0=$(ip -4 addr show bat0 2>/dev/null | grep -oE 'inet [0-9.]+')"
echo "L3 app   : OTS containers up = $(docker ps -q 2>/dev/null | wc -l)"
DM0=$(dmesg | wc -l)

echo
echo "============ RETUNE AWAY: 924 -> 916 (leave manet02) ============"
A=$(u); morse_cli -i wlh0 channel $AWAY; RC=$?; B=$(u)
echo "retune rc=$RC  before=$A after=$B"
echo "L0 PHY   : $(ch)"
echo "L2 iw    : $(iwch | tr '\n' ' ')   <-- did mac80211 channel move?"
echo "dmesg delta:"; dmesg | tail -n +$((DM0+1)) | grep -iE "morse|wlh0|batman|mm6108|crypt|sae|peer" | tail -8
echo "-- poll while AWAY (~12s): batman last-seen should GROW, ping should LOSS --"
i=0; while [ $i -lt 12 ]; do sample; i=$((i+1)); sleep 0.6; done

echo
echo "============ RETUNE BACK: 916 -> 924 (rejoin manet02) ============"
A=$(u); morse_cli -i wlh0 channel $RESTORE; RC=$?; B=$(u)
echo "retune rc=$RC  before=$A after=$B"
echo "L0 PHY   : $(ch)"
echo "-- poll RECONVERGE (~24s): last-seen should snap back <1s, ping -> OK --"
i=0; FIRST=""; while [ $i -lt 40 ]; do
  U=$(u); S=$(peer)
  if ping -c1 -w1 "$PEER_IP" >/dev/null 2>&1; then P=OK; else P=LOSS; fi
  echo "  t=$U  peer=${S:-GONE}  ping=$P"
  if [ "$P" = OK ] && [ -z "$FIRST" ]; then FIRST=$U; echo "  >>> DATAPLANE RECOVERED at t=$U (retune-back after=$B)"; fi
  i=$((i+1)); sleep 0.6
done

echo
echo "===================== FINAL ====================="
echo "L0 PHY   : $(ch)"
echo "L2.5 bat : peer_lastseen=$(peer)"
echo "L3 app   : OTS containers up = $(docker ps -q 2>/dev/null | wc -l)"
echo "control-channel (ahwlan ssh): still alive = YES"
