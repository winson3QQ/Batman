#!/bin/sh
# cot-stream-264.sh — one EUD session streaming N unique CoT at 2/s to TARGET:8088 (amqp-close-264, #264 R4).
#   ssh root@peer "TARGET=<ots-ip> RUN=<id> N=<count> sh -s" < this
# Every event has uid $RUN-<seq> and <dest callsign="dv-nobody"/> (stored, fanned out to nobody). One long-lived
# connection through a FIFO so a server-side drop is seen (CONNLOST) instead of counted as sent. Prints
# "SENT <n>" and, on a drop, "CONNLOST <seq>".
: "${TARGET:?}" "${RUN:?}"
N=${N:-120}
H=/tmp/run/batman-dv
{ [ -d "$H" ] || mkdir -m 700 "$H"; } && [ -O "$H" ] && [ ! -L "$H" ] || { echo "FAIL harness scratch $H unusable"; exit 1; }
F=$H/$RUN.fifo
trap '' PIPE
ts(){ date -u -d @"$1" +%Y-%m-%dT%H:%M:%S.000Z; }
ev(){ n=$(date +%s); printf '<event version="2.0" uid="%s" type="a-f-G-U-C" how="h-e" time="%s" start="%s" stale="%s"><point lat="25.03" lon="121.56" hae="10" ce="9999999" le="9999999"/><detail><contact callsign="%s"/><marti><dest callsign="dv-nobody"/></marti></detail></event>' "$1" "$(ts "$n")" "$(ts "$n")" "$(ts $((n+120)))" "$RUN"; }
rm -f "$F"; mkfifo "$F" || exit 1
nc "$TARGET" 8088 < "$F" >/dev/null 2>&1 & NCP=$!
exec 3>"$F"
s=0; i=1
while [ "$i" -le "$N" ]; do
	kill -0 "$NCP" 2>/dev/null || { echo "CONNLOST $i"; break; }
	printf '%s' "$(ev "$RUN-$i")" >&3 2>/dev/null || { echo "CONNLOST $i"; break; }
	s=$((s+1)); i=$((i+1))
	sleep 0.5
done
sleep 3; exec 3>&-; kill "$NCP" 2>/dev/null; wait "$NCP" 2>/dev/null; rm -f "$F"
echo "SENT $s"
