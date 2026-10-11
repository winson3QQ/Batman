#!/bin/sh
# eud-idle-client-264.sh — one idle EUD session for the eud-mem-264 suite (#264 R7). Runs on a PEER node:
#   TARGET=<ots-ip> RUN=<id> HOLD=<s> sh eud-idle-client-264.sh <k>
# Opens one TCP session to TARGET:8088, sends one position CoT (uid/callsign $RUN-$k, <dest callsign="dv-nobody"/>
# so cot_parser stores it but fans it out to nobody), then keeps the session open HOLD seconds with no traffic.
# The suite measures the handler container's memory per such session (upstream: 39 MB; patched: a few MB).
: "${TARGET:?}" "${RUN:?}"
k=${1:?} HOLD=${HOLD:-120}
n=$(date +%s); ts(){ date -u -d @"$1" +%Y-%m-%dT%H:%M:%S.000Z; }
ev="<event version=\"2.0\" uid=\"$RUN-$k\" type=\"a-f-G-U-C\" how=\"h-e\" time=\"$(ts "$n")\" start=\"$(ts "$n")\" stale=\"$(ts $((n+HOLD)))\"><point lat=\"25.03\" lon=\"121.56\" hae=\"10\" ce=\"9999999\" le=\"9999999\"/><detail><contact callsign=\"$RUN-$k\"/><marti><dest callsign=\"dv-nobody\"/></marti></detail></event>"
{ printf '%s' "$ev"; sleep "$HOLD"; } | nc "$TARGET" 8088 >/dev/null 2>&1
