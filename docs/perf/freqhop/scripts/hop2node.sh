#!/bin/sh
# Runs ON each node. Self-scheduled coordinated hop with triple restore safety net.
R="-c 924000 -o 8 -p 2 -n 3"      # 924/8MHz = home channel (rendezvous)
A="-c 916000 -o 8 -p 2 -n 3"      # 916/8MHz = hop target
LOG=/tmp/hop2.log; : > "$LOG"
restore(){ morse_cli -i wlh0 channel $R >/dev/null 2>&1; }
trap 'restore' EXIT INT TERM
u(){ cut -d" " -f1 /proc/uptime; }
dm0=$(dmesg | wc -l)
echo "$(u) START phy=$(morse_cli -i wlh0 channel 2>/dev/null | awk -F': ' '/Frequency/{print $2}')" >> "$LOG"
sleep 6
echo "$(u) HOP_AWAY_916" >> "$LOG"
morse_cli -i wlh0 channel $A >/dev/null 2>&1
sleep 2
echo "$(u) HOP_BACK_924" >> "$LOG"
morse_cli -i wlh0 channel $R >/dev/null 2>&1
sleep 5
restore                                   # net 1: explicit
sleep 2; morse_cli -i wlh0 channel $R >/dev/null 2>&1   # net 2: hard
echo "$(u) DONE phy=$(morse_cli -i wlh0 channel 2>/dev/null | awk -F': ' '/Frequency/{print $2}')" >> "$LOG"
echo "--- dmesg delta (sae/peer/crypt/morse/batman) ---" >> "$LOG"
dmesg | tail -n +$((dm0+1)) | grep -iE "sae|peer|crypt|morse|batman|wlh0|deauth|disassoc" | tail -12 >> "$LOG"
# net 3 belongs to orchestrator (re-asserts 924 after reconnect)
