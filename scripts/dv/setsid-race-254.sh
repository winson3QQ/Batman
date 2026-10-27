#!/bin/bash
# scripts/dv/setsid-race-254.sh <node> — #254 claim-lock fix §5.5 / §11.7: the commit's detached openmanetd start
# survives the PTY hangup of a non-interactive `ssh -tt node batman-slot commit`. No OTA, no reboot; files only under
# the node's /tmp/run/batman-dv/race. The construct is taken from the node's OWN batman-slot (scripts/node/setsid-race-254.sh).
#   image-delay  N_D trials under CPU load: the image's construct with a ms busy loop before setsid()  want N/N
#                (HUP is ignored before the fork, so no window is left; 1.5.13 -> 0/N, deterministic)
#   image        N trials under CPU load: the construct as shipped                                     want N/N
#   old-delay    N_C trials: the 1.5.13 construct + the same loop (negative control: the loop really opens
#                the window)                                                                           want k <= N/10
#   nodetach     N_C trials: no setsid (control: the hangup really kills a plain child)                want 0/N
# Every FAIL line starts with "FAIL"; RESULT setsid-race-254 PASS|FAIL last.
set -u
NODE=${1:?usage: $0 <node>}; N=${SR_N:-100}; ND=${SR_ND:-100}; NC=${SR_NC:-30}
REPO=$(cd "$(dirname "$0")/../.." && pwd)
SSHO="-o BatchMode=yes -o ConnectTimeout=6 -o LogLevel=ERROR -o IdentitiesOnly=yes"
fails=0; ok(){ echo "PASS $*"; }; no(){ echo "FAIL $*"; fails=$((fails + 1)); }
ns(){ timeout 120 ssh $SSHO "root@$NODE" sh -s -- "$@" < "$REPO/scripts/node/setsid-race-254.sh" 2>&1 | tr -d '\r'; }
done_(){ local c; c=$(ns clean); echo "$c"; grep -q CLEANED <<< "$c" && grep -qv 'busy_left=[1-9]' <<< "$c" || no "node cleanup: $c"; echo "RESULT setsid-race-254 $([ $fails = 0 ] && echo PASS || echo FAIL)"; [ $fails = 0 ]; }
trap 'echo interrupted; ns clean; exit 1' INT TERM
trial(){ sleep 1 | timeout 20 ssh -tt $SSHO "root@$NODE" "sh /tmp/run/batman-dv/race/parent.$1.sh $2" >/dev/null 2>&1; }
run(){ local v=$1 n=$2 i k; for i in $(seq 1 "$n"); do trial "$v" "$i"; done; sleep 3; k=$(ns count "$v"); case "$k" in ''|*[!0-9]*) k=-1;; esac; echo "$k"; }
s=$(ns stage); echo "$s"; grep -q '^STAGED' <<< "$s" || { no "stage: $s"; done_; exit 1; }
grep -q 'STAGED hup=[1-9]' <<< "$s" && ok "the image's release ignores HUP before the fork ($s)" || no "the image's release has no trap '' HUP ($s) — pre-fix construct"
# controls first: they prove the method (no load: the plain kill is not load-dependent)
k=$(run nodetach "$NC"); [ "$k" = 0 ] && ok "control nodetach: 0/$NC survived (the hangup kills a plain child)" || no "control nodetach: $k/$NC (method invalid)"
k=$(run old-delay "$NC"); [ "$k" -ge 0 ] && [ $((k * 10)) -le "$NC" ] && ok "negative control old-delay: $k/$NC survived (the loop opens the fork->setsid window)" || no "negative control old-delay: $k/$NC (window not opened: image-delay would not discriminate)"
l=$(ns load $(( (N + ND) * 3 + 180 ))); echo "$l"; grep -q '^LOAD' <<< "$l" || no "load: $l"
k=$(run image-delay "$ND"); [ "$k" = "$ND" ] && ok "image-delay under load: $ND/$ND survived (failure rate < $(awk -v n="$ND" 'BEGIN{printf "%.1f", 300/n}') % at 95 %)" || no "image-delay under load: $k/$ND survived"
k=$(run image "$N"); [ "$k" = "$N" ] && ok "image under load: $N/$N survived" || no "image under load: $k/$N survived"
done_
