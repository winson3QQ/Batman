#!/bin/bash
# scripts/dv/brewrite-254.sh — (chain-1 restore, prov-lock P7) E3 (design 254-p1-impl v5.1 §4.5.4 / §9): rewrite slot B with V via `sysupgrade -n` + hold, land in the B
# trial, measure boot->HELD, back_to_a before the deadline; N iterations, must be N/N. Stops at first failure.
set -u
NODE=${NODE:-10.41.1.3}; N=${N:-10}; PAY=${PAY:-/opt/batdata/ota-wsl9.tar.gz}; PSHA=${PSHA:-58c4b1c3d008ddf906da564497e203ccfa061c5e54a0a817d6777ebb72db0127}
SSHO="-o BatchMode=yes -o ConnectTimeout=6 -o ServerAliveInterval=5 -o ServerAliveCountMax=3"
say(){ echo "[$(date +%H:%M:%S) it=${it:-0}] $*"; }
q(){ local o rc; for _ in 1 2 3 4 5 6; do o=$(timeout 90 ssh $SSHO root@$NODE "$@" 2>/dev/null); rc=$?; case $rc in 255|124) sleep 10;; *) printf '%s' "$o" | tr -d '\r'; [ -n "$o" ] && echo; return $rc;; esac; done; return 255; }
bid(){ timeout 30 ssh $SSHO root@$NODE 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null | tr -d '\r\n '; }
waitboot(){ local b0=$1 max=$2 t0=$SECONDS b; while [ $((SECONDS-t0)) -lt $max ]; do b=$(bid); [ -n "$b" ] && [ "$b" != "$b0" ] && return 0; sleep 10; done; return 1; }
settle(){ local max=${1:-300} t0=$SECONDS k=0 p="" o b u; while [ $((SECONDS-t0)) -lt $max ]; do o=$(timeout 30 ssh $SSHO root@$NODE 'echo "$(cat /proc/sys/kernel/random/boot_id) $(cut -d. -f1 /proc/uptime)"' 2>/dev/null | tr -d '\r'); b=${o% *}; u=${o##* }; if [ -n "$o" ] && [ "${u:-0}" -ge 60 ] 2>/dev/null && { [ $k = 0 ] || [ "$b" = "$p" ]; }; then k=$((k+1)); p=$b; [ $k -ge 3 ] && return 0; else k=0; fi; sleep 5; done; return 1; }
ST='echo "slot=$(batman-slot active) ver=$(sed -n s/^BATMAN_VERSION=//p /etc/batman-build) trial_rc=$(batman-slot is-trial >/dev/null 2>&1; echo $?) dt_try=$(hexdump -v -e "1/1 \"%02x\"" /proc/device-tree/chosen/bootloader/tryboot 2>/dev/null) hold=[$(cat /opt/batdata/state/autocommit-hold-commit 2>/dev/null)] badslot=[$(cat /opt/batdata/state/bad-slot 2>/dev/null)] held=$(. /usr/lib/batman/rundir.sh; ls $RUNDIR/autocommit.ctl/hold-commit 2>/dev/null | wc -l) protB=[$(cat /opt/batdata/state/slot-B.protected 2>/dev/null)] up=$(cut -d. -f1 /proc/uptime) boot=$(cut -c1-8 /proc/sys/kernel/random/boot_id)"'
back_to_a(){ local b0; b0=$(bid); local o; o=$(q 'if [ "$(batman-slot active)" = B ]; then batman-slot rollback >/dev/null && { (batman-slot reboot committed e3-254 </dev/null >/dev/null 2>&1 &); echo SENT; }; else echo NOT-ON-B; fi'); say "back_to_a: $o"; grep -q SENT <<< "$o" || return 0; waitboot "$b0" 600 && settle 300; }
stop(){ say "STOP: $*"; s=$(q "$ST"); say "state: $s"; case "$s" in *slot=B*) say "on B -> back_to_a"; back_to_a; say "after: $(q "$ST")";; esac; echo "E3 RESULT: FAIL at it=$it ($*) ; held_times=[$TIMES]"; exit 1; }
V=$(q 'sed -n s/^BATMAN_VERSION=//p /etc/batman-build'); PS=$(q "sha256sum $PAY | cut -c1-64")
say "node $NODE V=$V payload sha=$PS"
[ "$PS" = "$PSHA" ] || { echo "payload sha mismatch"; exit 1; }
TIMES=""
for it in $(seq 1 $N); do
  s=$(q "$ST"); say "pre: $s"
  case "$s" in *"slot=A ver=$V trial_rc=1 "*"hold=[] badslot=[]"*) ;; *) stop "precondition (want A committed, no hold, no bad-slot)";; esac
  q "echo '$V' > /opt/batdata/state/autocommit-hold-commit; sync"; [ "$(q 'cat /opt/batdata/state/autocommit-hold-commit')" = "$V" ] || stop "hold flag readback"
  b0=$(bid); q "setsid sh -c 'sysupgrade -n $PAY >/opt/batdata/sysup-e3.log 2>&1' </dev/null >/dev/null 2>&1 &"
  waitboot "$b0" 600 || stop "no reboot within 600 s (sysup: $(q 'tail -2 /opt/batdata/sysup-e3.log'))"
  settle 300 || stop "trial not reachable"
  s=$(q "$ST"); say "landed: $s"
  case "$s" in *"slot=B ver=$V trial_rc=0 dt_try=00000001 hold=[] "*"held=1 "*) ;; *) stop "landing assertion (want B trial, DT tryboot=1, hold consumed+effective)";; esac
  q 'grep -c "HOLD-COMMIT-DISCARDED boot=$(cut -c1-8 /proc/sys/kernel/random/boot_id)" /opt/batdata/log/autocommit.log' | grep -qx 0 || stop "HOLD-COMMIT-DISCARDED this boot"
  t=""; for _ in $(seq 1 60); do u=$(q 'logread | grep -q "is healthy and HELD" && cut -d. -f1 /proc/uptime'); [ -n "$u" ] && { t=$u; break; }; up=$(q 'cut -d. -f1 /proc/uptime'); [ "${up:-0}" -ge 480 ] && break; sleep 10; done
  [ -n "$t" ] || stop "no HELD by uptime 480 s"
  hl=$(q 'logread | grep -m1 "is healthy and HELD"'); say "HELD seen at uptime<=${t}s: $hl"; TIMES="$TIMES $t"
  case "$s" in *"protB=[$V]"*) ;; *) stop "slot-B.protected != V";; esac
  back_to_a || stop "back_to_a failed"
  s=$(q "$ST"); say "post: $s"
  case "$s" in *"slot=A ver=$V trial_rc=1 "*"hold=[] badslot=[]"*"protB=[$V]"*) ;; *) stop "post assertion";; esac
  q 'batctl n 2>/dev/null | tail -n +3 | grep -q .' || stop "no mesh neighbour after return"
  for _ in $(seq 1 36); do r=$(q 'docker ps -q --filter status=running | wc -l'); [ "${r:-0}" -ge 6 ] && break; sleep 5; done; say "docker running=$r"
done
echo "E3 RESULT: PASS $N/$N ; held_uptimes(s)=[$TIMES]"
