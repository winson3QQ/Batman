#!/bin/sh
# cot-e2e-gen.sh — CoT generator for the OTS end-to-end suite (#268 B2 / #264). Runs on a PEER node:
#   ssh root@peer "TARGET=<ots-ip> RUN=DV<stamp> sh -s" < this
# Three phases, each on its OWN long-lived TCP connection to TARGET:8088 (busybox nc through a FIFO,
# so a connection the server drops is detected instead of being counted as "sent"):
#   P1 control      30 events, one event per write, 1 s apart — must arrive even with #264 unfixed
#   P2 truncation   20 pairs: write1 = full A + first half of B, sleep 1, write2 = rest of B, sleep 1.
#                   Deterministically hits #264 mechanism A (a recv holding a complete event followed by a
#                   partial one): OTS 1.7.13 stores every A and drops every B (offline repro, p2check.py)
#   P3 burst        20 s x 5 events per write (~1.6 KB > 1 MSS) — the real-client coalesced-write case
# Every event carries <marti><dest callsign="dv-nobody"/></marti>: cot_parser route_cot sends a dest'd
# event only to the dms exchange under that callsign (nobody), so it is stored but NOT fanned out to
# connected ATAK clients (no ghost markers). stale = +60 s.
# Output (one per line): "SENT <phase> <n>" and, if the server dropped the connection, "CONNLOST <phase> <seq>".
: "${TARGET:?}" "${RUN:?}"
F=/tmp/dv-cot.fifo
trap '' PIPE
ts(){ date -u -d @$1 +%Y-%m-%dT%H:%M:%S.000Z; }
head_of(){ n=$(date +%s); printf '<event version="2.0" uid="%s" type="a-' "$1"; }
tail_of(){ n=$(date +%s); printf 'f-G-U-C" how="h-e" time="%s" start="%s" stale="%s"><point lat="25.03" lon="121.56" hae="10" ce="9999999" le="9999999"/><detail><contact callsign="%s"/><marti><dest callsign="dv-nobody"/></marti></detail></event>' "$(ts $n)" "$(ts $n)" "$(ts $((n+60)))" "$1"; }
ev(){ head_of "$1"; tail_of "$1"; }
open_conn(){ rm -f $F; mkfifo $F || exit 1; nc "$TARGET" 8088 < $F >/dev/null 2>&1 & NCP=$!; exec 3>$F; LOST=""; }
# write one chunk as ONE write(2) on the connection; fail if nc is gone
w(){ kill -0 $NCP 2>/dev/null || return 1; printf '%s' "$1" >&3 2>/dev/null || return 1; kill -0 $NCP 2>/dev/null; }
close_conn(){ sleep 3; exec 3>&-; kill $NCP 2>/dev/null; wait $NCP 2>/dev/null; rm -f $F; }
lost(){ [ -z "$LOST" ] && { LOST=1; echo "CONNLOST $1 $2"; }; }

# P1 control
open_conn; s=0
for k in $(seq 1 30); do w "$(ev $RUN-P1-$k)" && s=$((s+1)) || { lost P1 $k; break; }; sleep 1; done
close_conn; echo "SENT P1 $s"

# P2 deterministic truncation (A = same-batch control, B = the #264 victim)
open_conn; sa=0; sb=0
for k in $(seq 1 20); do
	w "$(ev $RUN-P2-${k}A)$(head_of $RUN-P2-${k}B)" && sa=$((sa+1)) || { lost P2 ${k}A; break; }
	sleep 1
	w "$(tail_of $RUN-P2-${k}B)" && sb=$((sb+1)) || { lost P2 ${k}B; break; }
	sleep 1
done
close_conn; echo "SENT P2A $sa"; echo "SENT P2B $sb"

# P3 burst
open_conn; s=0
for k in $(seq 1 20); do
	c=""; for j in 1 2 3 4 5; do c="$c$(ev $RUN-P3-$k-$j)"; done
	w "$c" && s=$((s+5)) || { lost P3 $k; break; }; sleep 1
done
close_conn; echo "SENT P3 $s"
