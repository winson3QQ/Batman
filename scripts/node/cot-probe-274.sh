#!/bin/sh
# cot-probe-274.sh — runs on a PEER node during the OTS node's reboot (daily-validation cleanstop-274, #274 review C1).
#   sh cot-probe-274.sh <ots-ip> <uid>      (started detached BEFORE the reboot; output in its stdout)
# Waits for the OTS node's 8088 listener to go DOWN (the reboot), then for it to come back, and sends ONE CoT
# event the moment it accepts — i.e. as early as a field client could. The harness then checks, on the OTS node,
# whether that was BEFORE the opentakserver API was healthy (start mode phase B starts the CoT listeners before
# that gate) and whether the event was stored anyway: proof that the clients do not depend on the API.
# Output: "UP <epoch>" when 8088 accepted again, "SENT <epoch> rc=<nc rc>", or "NEVER-DOWN" / "NEVER-UP".
T=${1:?ots ip}; U=${2:?uid}
i=0; while nc -w 1 "$T" 8088 </dev/null >/dev/null 2>&1; do i=$((i + 1)); [ "$i" -gt 180 ] && { echo NEVER-DOWN; exit 1; }; sleep 1; done
i=0; until nc -w 1 "$T" 8088 </dev/null >/dev/null 2>&1; do i=$((i + 1)); [ "$i" -gt 400 ] && { echo NEVER-UP; exit 1; }; sleep 1; done
echo "UP $(date +%s)"
ts(){ date -u -d @"$1" +%Y-%m-%dT%H:%M:%S.000Z; }
n=$(date +%s)
# dest dv-nobody: stored, never fanned out to real ATAK clients (as cot-e2e-gen.sh); stale +60 s
printf '<event version="2.0" uid="%s" type="a-f-G-U-C" how="h-e" time="%s" start="%s" stale="%s"><point lat="25.03" lon="121.56" hae="10" ce="9999999" le="9999999"/><detail><contact callsign="%s"/><marti><dest callsign="dv-nobody"/></marti></detail></event>' \
	"$U" "$(ts "$n")" "$(ts "$n")" "$(ts $((n + 60)))" "$U" | nc -w 3 "$T" 8088 >/dev/null 2>&1
echo "SENT $(date +%s) rc=$?"
