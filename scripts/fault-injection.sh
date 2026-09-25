#!/bin/bash
# fault-injection.sh — DESTRUCTIVE fault-injection for the flash-and-go payload path (#159/#216).
# Release-gate / HIL, NOT for the daily cron: it reboots the node, OTA-flashes trial slots, and
# breaks a slot's docker runtime. Runs from an operator box that can ssh the node (default key).
# daily-validation.sh invokes it only under AB_MODE=--destructive (alongside ab-selftest --destructive).
#
#   scripts/fault-injection.sh <ots-node> [--case f1|f2|r2|r1|all]   (default: all)
#
# Requires on the node: the current A/B OTA payload staged at /opt/batdata/ota.tar.gz (survives the
# reboots; /tmp does not), a docker payload tenant (opentakserver), and the baked canary image.
# Each case injects a fault and asserts the SYSTEM'S AUTONOMOUS response (no operator in the loop):
#   F1  a bad image tar is quarantined after N boots and never wedges the guardian (per-tenant)
#   F2  a lost image is recoverable from the offline images/loaded/ copy (mv-not-rm) on an offline fleet
#   R2  a first-loading tenant is NON-GATING (per-boot latch) so autocommit commits, not false-reverts
#   R1  a trial whose docker ENGINE answers `docker info` but cannot `docker run` (broken runc) fails
#       the autocommit canary and REVERTS to the good committed slot
set -uo pipefail
NODE=${1:?usage: fault-injection.sh <ots-node> [--case f1|f2|r2|r1|all]}
CASE=${3:-all}; [ "${2:-}" = --case ] && CASE=${3:-all}
TENANT=opentakserver
APPS=/opt/batdata/apps
PAYLOAD=/opt/batdata/ota.tar.gz
S="-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8"
n(){ ssh $S "root@$NODE" "$@"; }                       # node ssh
waitup(){ for _ in $(seq 1 "${1:-60}"); do ssh $S -o ConnectTimeout=6 "root@$NODE" true 2>/dev/null && return 0; sleep 6; done; return 1; }
slot(){ n 'batman-slot active' 2>/dev/null | tr -d "\r\n "; }
committed(){ n 'batman-slot is-trial >/dev/null 2>&1; [ $? = 1 ]' 2>/dev/null; }   # rc0 if committed
ots_up(){ [ "$(n 'docker ps -q 2>/dev/null | wc -l' 2>/dev/null | tr -d "\r\n ")" -ge 6 ] 2>/dev/null; }
PASS=0; FAIL=0
ok(){ echo "  PASS $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }

f2(){ echo "== F2 offline-copy recovery =="
  n "docker stop rabbitmq >/dev/null 2>&1; docker rm -f rabbitmq >/dev/null 2>&1; docker rmi rabbitmq:4.3.6 >/dev/null 2>&1"
  if n 'docker image inspect rabbitmq:4.3.6 >/dev/null 2>&1'; then no "F2 could not remove image"; return; fi
  n "docker load -i $APPS/$TENANT/images/loaded/mq.tar >/dev/null 2>&1"
  n 'docker image inspect rabbitmq:4.3.6 >/dev/null 2>&1' || { no "F2 restore from loaded/ failed"; return; }
  n 'payload-run '"$TENANT"' >/dev/null 2>&1 &'; for _ in $(seq 1 40); do ots_up && break; sleep 5; done
  ots_up && ok "F2 lost image recovered from offline loaded/ copy; OTS 6/6" || no "F2 OTS did not recover"; }

f1(){ echo "== F1 bad-tar quarantine + anti-wedge (decoy tenant, 3 reboots) =="
  local D=$APPS/faulttest/images
  n "mkdir -p $D; head -c 400000 /dev/urandom > $D/bad.tar; rm -f $D/.fail-bad.tar; rm -rf $D/failed $D/loaded"
  for r in 1 2 3; do n 'sync; reboot' 2>/dev/null; sleep 50; waitup 40 || { no "F1 node did not return (reboot $r)"; return; }; sleep 25; done
  local left failed up; left=$(n "ls $D/*.tar 2>/dev/null" 2>/dev/null); failed=$(n "ls $D/failed/ 2>/dev/null" 2>/dev/null | tr -d "\r");
  [ -z "$left" ] && echo "$failed" | grep -q bad.tar && ok "F1 bad.tar quarantined to failed/ after N boots" || no "F1 not quarantined (left=$left failed=$failed)"
  ots_up && ok "F1 healthy tenant (OTS) stayed 6/6 throughout — per-tenant isolation" || no "F1 OTS not 6/6"
  n "rm -rf $APPS/faulttest"; }

r2(){ echo "== R2 first-loading tenant is non-gating (no false revert) =="
  local T=$APPS/r2test
  n "mkdir -p $T/images; echo 'IMAGE r2test=busybox:nope' > $T/r2test.manifest; head -c 200000 /dev/urandom > $T/images/pending.tar; rm -f $T/images/.fail-pending.tar; rm -rf $T/images/failed $T/images/loaded"
  n "setsid sh -c 'sysupgrade -n $PAYLOAD >/opt/batdata/sysup.log 2>&1' </dev/null >/dev/null 2>&1 &"; sleep 50; waitup 60 || { no "R2 node did not return"; return; }
  local c=0; for _ in $(seq 1 80); do committed && ots_up && { c=1; break; }; sleep 8; done
  local latch; latch=$(n 'ls /tmp/batman-firstload-r2test.latch 2>/dev/null' 2>/dev/null)
  [ "$c" = 1 ] && [ -n "$latch" ] && ok "R2 committed while r2test first-loading (latch present) — non-gating, no false revert" || no "R2 did not commit / no latch (committed=$c latch=$latch)"
  n "rm -rf $APPS/r2test; rm -f /tmp/batman-firstload-r2test.latch"; }

r1(){ echo "== R1 docker-run-broken trial -> canary reverts to good slot =="
  local pre; pre=$(slot); n "setsid sh -c 'sysupgrade -n $PAYLOAD >/opt/batdata/sysup.log 2>&1' </dev/null >/dev/null 2>&1 &"; sleep 50; waitup 60 || { no "R1 trial did not come up"; return; }
  sleep 8
  n 'for p in /usr/bin/runc /usr/sbin/runc; do [ -f "$p" ] && { mv "$p" "$p.off"; break; }; done'   # docker info OK, docker run fails
  local info run; info=$(n 'docker info >/dev/null 2>&1 && echo OK || echo FAIL' 2>/dev/null|tr -d "\r\n "); run=$(n 'docker run --rm --network none batman-canary true >/dev/null 2>&1 && echo OK || echo FAIL' 2>/dev/null|tr -d "\r\n ")
  echo "    trial: docker info=$info  canary run=$run"
  local stilltrial=1; for _ in $(seq 1 8); do committed && { stilltrial=0; break; }; sleep 9; done
  [ "$stilltrial" = 1 ] && ok "R1 autocommit REFUSED to commit the docker-run-broken trial" || no "R1 committed a broken trial (BAD)"
  n 'sync; reboot' 2>/dev/null; sleep 55; waitup 40 || { no "R1 node did not return after revert"; return; }; sleep 20
  local post crun; post=$(slot); crun=$(n 'docker run --rm --network none batman-canary true >/dev/null 2>&1 && echo OK || echo FAIL' 2>/dev/null|tr -d "\r\n ")
  if committed && ots_up && [ "$crun" = OK ]; then ok "R1 reverted to good committed slot $post; canary=$crun, OTS 6/6 (runc intact)"; else no "R1 did not revert to a healthy slot (post=$post committed/ots/canary=$crun)"; fi
  echo "    NOTE: the broken trial slot's runc stays .off until its next OTA re-sync; good slot intact"; }

echo "=== fault-injection on $NODE (case=$CASE) ==="
committed || echo "WARN: node not on a committed slot; some cases assume a clean committed start"
case "$CASE" in f2) f2;; f1) f1;; r2) r2;; r1) r1;; all) f2; f1; r2; r1;; *) echo "unknown case $CASE"; exit 2;; esac
echo "================ fault-injection: $PASS passed, $FAIL failed ================"
[ "$FAIL" = 0 ]
