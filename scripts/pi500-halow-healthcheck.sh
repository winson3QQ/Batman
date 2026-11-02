#!/bin/bash
# Pi 500 HaLow mesh health check — run after a reboot to confirm the gains survived.
#
# The point of this script is issue #33: the mesh can look completely healthy (peer
# ESTAB, data flowing, batctl ping 0% loss) while A-MPDU aggregation is silently dead,
# which costs ~3x throughput. PMF and aggregation are checked explicitly here because
# nothing else surfaces them.
#
#   sudo ./pi500-halow-healthcheck.sh          # checks only
#   sudo ./pi500-halow-healthcheck.sh -t       # also push traffic so the AGG check is meaningful
#
# Exit 0 = all pass.

set -u
IFACE=${IFACE:-wlan1}
PHY=${PHY:-phy2}
TRAFFIC=0
[ "${1:-}" = "-t" ] && TRAFFIC=1
FAIL=0

ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$1"; }
hdr()  { printf '\n\033[1m%s\033[0m\n' "$1"; }

[ "$(id -u)" -eq 0 ] || { echo "run me with sudo (needs debugfs + morse_cli)"; exit 2; }

hdr "1. driver"
if lsmod | grep -q '^morse'; then ok "morse module loaded"; else bad "morse module NOT loaded"; fi
# enable_twt is a bool param so the kernel renders it as N, not 0
for kv in country=US enable_ps=0 enable_twt=N enable_mcast_rate_control=Y spi_clock_speed=0; do
  k=${kv%%=*}; want=${kv#*=}; got=$(cat "/sys/module/morse/parameters/$k" 2>/dev/null)
  if [ "$got" = "$want" ]; then ok "$k=$got"
  else bad "$k=$got (expected $want)"; fi
done

hdr "2. interface + services"
if [ -d "/sys/class/net/$IFACE" ]; then ok "$IFACE exists"; else bad "$IFACE missing — driver did not probe"; fi
iw dev "$IFACE" info 2>/dev/null | grep -q "type mesh point" \
  && ok "$IFACE is a mesh point" || bad "$IFACE is not a mesh point"
for s in halow-mesh halow-batman; do
  a=$(systemctl is-active "$s.service" 2>/dev/null); e=$(systemctl is-enabled "$s.service" 2>/dev/null)
  [ "$a" = active ] && ok "$s active" || bad "$s $a"
  [ "$e" = enabled ] && ok "$s enabled (survives reboot)" || bad "$s $e — will NOT come back on reboot"
done

hdr "3. mesh peering"
DUMP=$(iw dev "$IFACE" station dump 2>/dev/null)
PEER=$(echo "$DUMP" | awk '/^Station/{print $2; exit}')
if [ -n "$PEER" ]; then ok "peer $PEER"; else bad "no peer"; fi
echo "$DUMP" | grep -q "mesh plink:.*ESTAB" && ok "plink ESTAB" || bad "plink not ESTAB"
# --- issue #33: without PMF the ADDBA handshake is silently dropped by the peer ---
if echo "$DUMP" | grep -q "MFP:[[:space:]]*yes"; then
  ok "MFP: yes  (ieee80211w=2 in effect — issue #33)"
else
  bad "MFP: no  -> ADDBA sent unprotected and dropped by the peer."
  bad "      add 'ieee80211w=2' to the network{} block of /etc/halow/mesh-wlan1.conf"
fi
echo "$DUMP" | awk '/signal:/{print "        signal " $2 " dBm"}' | head -1
echo "$DUMP" | awk '/tx failed:/{print "        tx failed " $3}' | head -1

hdr "4. batman"
ip -br addr show bat0 2>/dev/null | grep -q 'bat0' && ok "bat0 up: $(ip -br addr show bat0 | awk '{print $3}')" || bad "bat0 missing"
batctl if 2>/dev/null | grep -q "$IFACE: active" && ok "$IFACE attached to bat0" || bad "$IFACE not attached to bat0"
ORIG=$(batctl o 2>/dev/null | grep -c '^ \*')
[ "${ORIG:-0}" -gt 0 ] && ok "$ORIG originator(s) visible" || bad "no batman originators"

hdr "5. A-MPDU aggregation  <- the thing issue #33 fixed"
if [ "$TRAFFIC" = 1 ] && [ -n "${PEER:-}" ]; then
  TGT=$(batctl tg 2>/dev/null | awk '/^ \*/{print $2; exit}')
  printf '        pushing traffic for 5 s...\n'
  timeout 6 ping -f -s 1200 -I bat0 ff02::1%bat0 >/dev/null 2>&1
fi
B=$(morse_cli -i "$IFACE" stats 2>/dev/null | awk -F: '/AGG A-MPDUs/{print $2}')
BA=$(morse_cli -i "$IFACE" stats 2>/dev/null | awk -F: '/TX BlockAck/{print $2}' | tr -d ' ')
if [ -z "$B" ]; then
  bad "cannot read chip stats"
else
  SINGLE=$(echo "$B" | awk '{print $1}')
  MULTI=$(echo "$B" | awk '{s=0; for(i=2;i<=NF;i++) s+=$i; print s}')
  printf '        A-MPDU length histogram: 1-MPDU=%s  >1-MPDU=%s   TX BlockAck=%s\n' "$SINGLE" "$MULTI" "${BA:-?}"
  if [ "${MULTI:-0}" -gt 0 ] && [ "${BA:-0}" -gt 0 ]; then
    ok "aggregation is working"
  elif [ "${MULTI:-0}" -eq 0 ] && [ "${SINGLE:-0}" -lt 200 ]; then
    warn "not enough traffic to judge — re-run with -t"
  else
    bad "NO aggregation: every A-MPDU carries one MPDU and TX BlockAck is 0."
    bad "      this is the issue #33 regression. check MFP above."
  fi
fi

hdr "result"
if [ "$FAIL" -eq 0 ]; then printf '\033[32mall checks passed\033[0m\n'; else printf '\033[31m%d check(s) failed\033[0m\n' "$FAIL"; fi
exit $((FAIL > 0))
