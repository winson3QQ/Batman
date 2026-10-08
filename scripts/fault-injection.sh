#!/bin/bash
# fault-injection.sh — DESTRUCTIVE fault-injection for the flash-and-go payload path (#159/#216) and the
# A/B autocommit hold/recheck (#265/#261). Release-gate / HIL, NOT for the daily cron: it reboots the node,
# OTA-flashes trial slots, and breaks a slot's docker runtime. Runs from an operator box that can ssh the
# node (default key). daily-validation.sh invokes it only under --destructive, one case per suite.
#
#   scripts/fault-injection.sh <node> [--case f1|f2|r2|r1|r3|r4|all] [--no-tenant]   (default: all)
#
# --no-tenant  the CALLER declares the node carries no docker tenant (a Pi 3, #209 D6): only r3/r4 run, and
#              the OTS 6/6 / canary assertions are not made. Without it a missing tenant is a FAIL — never
#              inferred from the node, or a node that lost its tenant would pass silently (review #265 F5).
# Env:
#   FI_PAYLOAD      payload ON THE NODE that R2/R1/R3/R4 OTA-flash (default /opt/batdata/ota.tar.gz)
#   EXPECT_VERSION  if set, the node's BATMAN_VERSION must equal it; unset prints "VERSION NOT PINNED"
#
# Requires on the node: an A/B OTA payload of the build the node RUNS (checked by precheck, #268 A2), and
# (unless --no-tenant) a docker payload tenant (opentakserver) and the autocommit canary.
# Each case injects a fault and asserts the SYSTEM'S AUTONOMOUS response (no operator in the loop):
#   F1  a bad image tar is quarantined after N boots and never wedges the guardian (per-tenant)
#   F2  a lost image is recoverable from the offline images/loaded/ copy (mv-not-rm) on an offline fleet
#   R2  a first-loading tenant is NON-GATING (per-boot latch) so autocommit commits, not false-reverts
#   R1  a HELD trial whose docker engine answers `docker info` but cannot `docker run` (broken runc) is
#       released; the pre-commit canary (#265) must refuse it and the watchdog revert to the committed slot
#   R3  a healthy trial with hold-commit stays uncommitted until `batman-autocommit release`, then commits (#261)
#   R4  a healthy trial with hold-commit that nobody releases is reverted at the deadline (#261)
#
# Reads vs actions (#265 v1.2 H1): the host reaches some nodes only through a mesh that re-forms after
# every reboot, and an ssh can fail for a while after the first success. Every reading a verdict rests
# on goes through q(), which retries a CONNECTION failure (ssh rc 255, or a hung session cut by timeout)
# and records what it could not read in $UNREADF; a verdict with an unreadable input is reported
# "UNDETERMINED ... not verified" — never PASS, never a product FAIL. Remote commands used for readings
# must never exit 255 themselves. Actions (sysupgrade, reboot, mv, release) use n() and are never retried.
set -uo pipefail
NODE=${1:?usage: fault-injection.sh <node> [--case f1|f2|r2|r1|r3|r4|all] [--no-tenant]}
shift; CASE=all; NOTENANT=0
while [ $# -gt 0 ]; do case "$1" in --case) CASE=${2:-all}; shift 2;; --no-tenant) NOTENANT=1; shift;; *) echo "unknown arg $1"; exit 2;; esac; done
TENANT=opentakserver
APPS=/opt/batdata/apps
PAYLOAD=${FI_PAYLOAD:-/opt/batdata/ota.tar.gz}
DEFER_MAX=600   # batman-autocommit: the watchdog may postpone a revert this long past the deadline (busy converge/first-load)
# ServerAlive: an ssh whose route dies mid-session (the mesh re-forming) ends as rc 255 in ~15 s instead of hanging (F3)
S="-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 -o LogLevel=ERROR"
FI_TMP=$(mktemp -d); UNREADF=$FI_TMP/unread; : > "$UNREADF"
# #280: where the node keeps its decision state: the root-only run dir on an image that ships rundir.sh, /tmp on
# an older image. Never a fall back to /tmp on a #280 image — a missing run dir there reads as empty (no commit
# seen, no why), never as names a non-root process could have planted in /tmp.
RDR='R=/tmp; [ -r /usr/lib/batman/rundir.sh ] && R=/tmp/run/batman; '
n(){ ssh $S "root@$NODE" "$@"; }                       # action / raw poll: no retry
q(){ local o rc                                      # reading: retry connection failures, record the unreadable
  for _ in 1 2 3 4 5 6; do
    o=$(timeout "${QT:-90}" ssh $S "root@$NODE" "$@" 2>/dev/null); rc=$?
    case $rc in 255|124) sleep 10;; *) [ -n "$o" ] && printf '%s\n' "$o"; return $rc;; esac
  done
  echo "$*" | tr '\n' ' ' | cut -c1-70 >> "$UNREADF"; return 255; }
unread_reset(){ : > "$UNREADF"; }
# $1 = case tag. rc 0 (and one FAIL printed) when something the verdict needs could not be read.
undetermined(){ [ -s "$UNREADF" ] || return 1
  no "$1 UNDETERMINED: node unreadable ($(sort -u "$UNREADF" | tr '\n' ';')) — not verified"; return 0; }
isint(){ case "$1" in ""|*[!0-9]*) return 1;; esac; }
rawbid(){ timeout 30 ssh $S -o ConnectTimeout=6 "root@$NODE" 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null | tr -d '\r\n '; }
# Stable = three answers 5 s apart from the SAME boot, the node up >= 60 s (rc4: the drop came after the
# first ssh success; a boot-loop or a deferred second reboot must not look settled — F12).
settle(){ local max=${1:-300} t0=$SECONDS k=0 p="" o b u
  while [ $((SECONDS - t0)) -lt "$max" ]; do
    o=$(timeout 30 ssh $S -o ConnectTimeout=6 "root@$NODE" 'echo "$(cat /proc/sys/kernel/random/boot_id) $(cut -d. -f1 /proc/uptime)"' 2>/dev/null | tr -d '\r')
    b=${o% *}; u=${o##* }
    if [ -n "$o" ] && isint "$u" && [ "$u" -ge 60 ] && { [ "$k" = 0 ] || [ "$b" = "$p" ]; }; then
      k=$((k + 1)); p=$b; [ "$k" -ge 3 ] && return 0
    else k=0; fi
    sleep 5
  done; return 1; }
# wait for a NEW boot (boot_id != $1), max $2 s — a sysupgrade still writing must not pass for the trial (F8)
waitboot(){ local b0=$1 max=$2 t0=$SECONDS b
  while [ $((SECONDS - t0)) -lt "$max" ]; do b=$(rawbid); [ -n "$b" ] && [ "$b" != "$b0" ] && return 0; sleep 10; done; return 1; }
slot(){ q 'batman-slot active' | tr -d "\r\n "; }
committed(){ q 'batman-slot is-trial >/dev/null 2>&1; [ $? = 1 ]'; }   # rc0 committed, 1 trial, 255 unreadable
bootid(){ q 'cat /proc/sys/kernel/random/boot_id' | tr -d '\r\n '; }
nodever(){ q 'sed -n s/^BATMAN_VERSION=//p /etc/batman-build' | tr -d '\r'; }
# 6/6 = six containers in state running (`docker ps` also lists ones restarting in a crash loop — #274 review C5)
ots_up(){ [ "$NOTENANT" = 1 ] && return 0; [ "$(q 'docker ps -q --filter status=running 2>/dev/null | wc -l' | tr -d "\r\n ")" -ge 6 ] 2>/dev/null; }
ots_wait(){ [ "$NOTENANT" = 1 ] && return 0; for _ in $(seq 1 48); do ots_up && return 0; sleep 5; done; return 1; }
otsword(){ [ "$NOTENANT" = 1 ] && echo "no tenant (declared)" || echo "OTS 6/6"; }
PASS=0; FAIL=0
ok(){ echo "  PASS $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }

# Leave the node able to serve (#268 A4). R1 renames runc to break `docker run`; if R1's trial is committed
# and rebooted into, dockerd starts without runc, exits, and does NOT come back when runc is put back —
# that left the OTS host dark for ~6 min on 2026-10-07. So: wait for the node, put back what was renamed
# on the BOOTED slot, restart dockerd if anything changed or it is down, wait for the tenant, prove
# containers run (canary, only once committed — the autocommit daemon is done then). Never swallowed.
# A hold-commit flag left on p6 would hold — then revert — the next same-build OTA: removed AND verified (F10).
R1_BROKE=0; R1_SLOT=""; RESTORED=0
restore_node(){
  [ "$RESTORED" = 1 ] && return 0
  echo "== restore_node"
  settle 300 || { no "restore: node not stably reachable within 300 s — restore NOT done, node may be degraded"; return 1; }
  local moved
  q 'rm -f /opt/batdata/state/autocommit-hold-commit; sync' >/dev/null
  q '[ ! -e /opt/batdata/state/autocommit-hold-commit ]' || { no "restore: hold-commit flag still armed on p6 (or unreadable) — the next OTA of this build would be held"; return 1; }
  if [ "$NOTENANT" = 0 ]; then
    moved=$(q 'm=""; for p in /usr/bin/runc /usr/sbin/runc; do [ -f "$p.off" ] && [ ! -e "$p" ] && mv "$p.off" "$p" && m="$m $p"; done; echo "$m"' | tr -d '\r')
    [ -n "$moved" ] && echo "    put back:$moved (slot $(slot))"
    if [ -n "$moved" ] || ! q 'pidof dockerd >/dev/null'; then
      echo "    restarting dockerd"; q '/etc/init.d/dockerd restart >/dev/null 2>&1' >/dev/null
    fi
    ots_wait || { no "restore: OTS not back to 6/6 within 240 s — node left degraded"; return 1; }
    if committed; then q 'batman-autocommit canary' >/dev/null 2>&1 || { no "restore: canary still fails after restore — node left degraded"; return 1; }; fi
  fi
  RESTORED=1; echo "    node restored: $(otsword)$(committed && echo ', committed')"
  [ "$R1_BROKE" = 1 ] && echo "    NOTE: R1 broke runc on slot $R1_SLOT; if that is not the booted slot it keeps runc.off until its next OTA rewrites it — do not 'batman-slot rollback' into it"
  return 0; }
trap 'rc=$?; restore_node || rc=1; rm -rf "$FI_TMP"; exit $rc' EXIT

# The payload must be the image the node RUNS (#268 A2): the old harness OTA-flashed whatever sat in
# /opt/batdata/ota.tar.gz, and a stale 1.5.0 there turned both slots of the OTS host into 1.5.0.
# Compares the payload's root.squashfs with the first size= bytes of the booted rootfs partition (the
# /rom mount source) — the same read `batman-slot verify` does.
PRECHECK=""
precheck(){
  [ -n "$PRECHECK" ] && { [ "$PRECHECK" = ok ]; return; }
  echo "== payload precheck ($PAYLOAD)"
  local o; o=$(QT=600 q "P=$PAYLOAD; EXP='${EXPECT_VERSION:-}'"'
    [ -f "$P" ] || { echo "ERR payload $P missing"; exit 1; }
    meta=$(tar -xzOf "$P" metadata 2>/dev/null); size=$(echo "$meta" | sed -n "s/^size=//p"); board=$(echo "$meta" | sed -n "s/^board=//p")
    tsz=$(tar -tvzf "$P" root.squashfs 2>/dev/null | awk "{print \$3}")
    want=$(tar -xzOf "$P" SHA256SUMS 2>/dev/null | awk "\$2==\"root.squashfs\"{print \$1}")
    echo "metadata: $(echo $meta)"
    case "$size" in ""|*[!0-9]*) echo "ERR metadata size= unreadable [$size]"; exit 1;; esac
    [ "$tsz" = "$size" ] || { echo "ERR metadata size=$size != root.squashfs in the tar ($tsz)"; exit 1; }
    [ -n "$want" ] || { echo "ERR SHA256SUMS has no root.squashfs"; exit 1; }
    got=$(tar -xzOf "$P" root.squashfs | sha256sum | cut -d" " -f1)
    [ "$got" = "$want" ] || { echo "ERR payload root.squashfs $got != its SHA256SUMS $want (corrupt payload)"; exit 1; }
    myb=$(sed -n "s/^BATMAN_BOARD=//p" /etc/batman-build); myv=$(sed -n "s/^BATMAN_VERSION=//p" /etc/batman-build)
    [ "$board" = "$myb" ] || { echo "ERR payload board=$board, node BATMAN_BOARD=$myb"; exit 1; }
    dev=$(mount | awk "\$3==\"/rom\"{print \$1}" | head -1)   # busybox mount resolves it; /proc/mounts says /dev/root
    case "$dev" in /dev/mmcblk*) ;; *) echo "ERR /rom source is [$dev], not an mmcblk partition — not guessing the layout"; exit 1;; esac
    run=$(head -c "$size" "$dev" | sha256sum | cut -d" " -f1)
    echo "node runs $myv from $dev: rootfs sha $run / payload sha $want"
    [ "$run" = "$want" ] || { echo "ERR payload is not the build this node runs — stage the matching payload (FI_PAYLOAD)"; exit 1; }
    if [ -n "$EXP" ]; then [ "$myv" = "$EXP" ] || { echo "ERR node runs $myv, EXPECT_VERSION=$EXP"; exit 1; }
    else echo "VERSION NOT PINNED (set EXPECT_VERSION to require a specific build)"; fi
    echo OK' 2>&1); echo "$o" | sed 's/^/    /'
  if echo "$o" | tail -1 | grep -qx OK; then PRECHECK=ok; return 0; fi
  PRECHECK=bad; no "precheck refused the OTA cases (would OTA-flash a different build, or unreadable): $(echo "$o" | grep '^ERR' | head -1)"; return 1; }

# A case that needs the tenant refuses on a --no-tenant node; without --no-tenant the tenant must exist.
need_tenant(){ if [ "$NOTENANT" = 1 ]; then no "$1 needs a docker tenant — not run on a --no-tenant node"; return 1; fi
  q "ls $APPS/$TENANT/*.manifest >/dev/null 2>&1" || { no "$1: tenant $TENANT missing on the node (or unreadable) — not declared --no-tenant, so this is a FAIL"; return 1; }; }

f2(){ echo "== F2 offline-copy recovery =="
  need_tenant F2 || return
  n "docker stop rabbitmq >/dev/null 2>&1; docker rm -f rabbitmq >/dev/null 2>&1; docker rmi rabbitmq:4.3.6 >/dev/null 2>&1"
  if q 'docker image inspect rabbitmq:4.3.6 >/dev/null 2>&1'; then no "F2 could not remove image"; return; fi
  n "docker load -i $APPS/$TENANT/images/loaded/mq.tar >/dev/null 2>&1"
  q 'docker image inspect rabbitmq:4.3.6 >/dev/null 2>&1' || { no "F2 restore from loaded/ failed"; return; }
  unread_reset
  n 'payload-run '"$TENANT"' >/dev/null 2>&1 &'; for _ in $(seq 1 40); do ots_up && break; sleep 5; done
  unread_reset; ots_up; local r=$?; undetermined F2 && return
  [ $r = 0 ] && ok "F2 lost image recovered from offline loaded/ copy; OTS 6/6" || no "F2 OTS did not recover"; }

f1(){ echo "== F1 bad-tar quarantine + anti-wedge (decoy tenant, 3 reboots) =="
  need_tenant F1 || return
  local D=$APPS/faulttest/images b r
  q "mkdir -p $D; head -c 400000 /dev/urandom > $D/bad.tar; rm -f $D/.fail-bad.tar; rm -rf $D/failed $D/loaded" >/dev/null
  for r in 1 2 3; do
    b=$(bootid); [ -n "$b" ] || { no "F1 boot_id unreadable before reboot $r — not verified"; return; }
    n 'sync; reboot' 2>/dev/null
    waitboot "$b" 400 || { no "F1 node did not reboot/return (reboot $r)"; return; }
    settle 300 || { no "F1 node not stably reachable after reboot $r"; return; }; sleep 15
  done
  unread_reset
  local left failed; left=$(q "ls $D/*.tar 2>/dev/null; true"); failed=$(q "ls $D/failed/ 2>/dev/null; true" | tr -d "\r")
  ots_wait; local o=$?
  undetermined F1 && return
  [ -z "$left" ] && echo "$failed" | grep -q bad.tar && ok "F1 bad.tar quarantined to failed/ after N boots" || no "F1 not quarantined (left=$left failed=$failed)"
  [ $o = 0 ] && ok "F1 healthy tenant (OTS) 6/6 after the 3 reboots — per-tenant isolation" || no "F1 OTS not 6/6"
  q "rm -rf $APPS/faulttest" >/dev/null; }

# OTA-flash the staged payload; returns once the NEW boot is stably reachable. $1 tag, $2 boot_id before.
ota_boot(){ local tag=$1 b0=$2
  n "setsid sh -c 'sysupgrade -n $PAYLOAD >/opt/batdata/sysup.log 2>&1' </dev/null >/dev/null 2>&1 &"
  waitboot "$b0" 600 || { no "$tag: node did not reboot into the new image within 600 s (sysupgrade log: $(q 'tail -2 /opt/batdata/sysup.log' | tr '\n' ' '))"; return 1; }
  settle 300 || { no "$tag: trial not stably reachable within 300 s"; return 1; }; }

r2(){ echo "== R2 first-loading tenant is non-gating (no false revert) =="
  need_tenant R2 || return
  precheck || return
  local T=$APPS/r2test b0
  q "mkdir -p $T/images; echo 'IMAGE r2test=busybox:nope' > $T/r2test.manifest; head -c 200000 /dev/urandom > $T/images/pending.tar; rm -f $T/images/.fail-pending.tar; rm -rf $T/images/failed $T/images/loaded" >/dev/null
  b0=$(bootid); [ -n "$b0" ] || { no "R2 boot_id unreadable — not verified"; return; }
  ota_boot R2 "$b0" || return
  local c=0; for _ in $(seq 1 80); do committed && ots_up && { c=1; break; }; sleep 8; done
  unread_reset
  local latch; latch=$(q "$RDR"'ls "$R/batman-firstload-r2test.latch" 2>/dev/null; true')
  [ "$c" = 1 ] || { committed && ots_up && c=1; }
  undetermined R2 && return
  [ "$c" = 1 ] && [ -n "$latch" ] && ok "R2 committed while r2test first-loading (latch present) — non-gating, no false revert" || no "R2 did not commit / no latch (committed=$c latch=$latch)"
  q "$RDR rm -rf $APPS/r2test; rm -f \"\$R/batman-firstload-r2test.latch\"" >/dev/null; }

# R1/R3/R4 use the #261 hold-commit (ab-autocommit v2.4) so nothing races: the trial is held, the fault is
# injected (R1) or not (R3/R4), THEN released (R1/R3) or left alone (R4).
# held_trial: OTA the staged payload into a HELD trial; sets HT (trial slot), HB (its boot_id), HDL (deadline).
# Not run in $(...): its FAILs must count.
HT=""; HB=""; HDL=""
held_trial(){ local tag=$1 pre=$2 ver b0; HT=""; HB=""; HDL=""
  ver=$(nodever); [ -n "$ver" ] || { no "$tag: node version unreadable — not verified"; return 1; }
  b0=$(bootid); [ -n "$b0" ] || { no "$tag: boot_id unreadable — not verified"; return 1; }
  q "echo '$ver' > /opt/batdata/state/autocommit-hold-commit; sync" >/dev/null || { no "$tag: could not arm hold-commit"; return 1; }
  ota_boot "$tag" "$b0" || return 1
  unread_reset
  local s it hc; s=$(slot); q 'batman-slot is-trial >/dev/null 2>&1; [ $? = 0 ]'; it=$?
  q "$RDR"'[ ! -e /opt/batdata/state/autocommit-hold-commit ] && [ -f "$R/autocommit.ctl/hold-commit" ]'; hc=$?
  HDL=$(q "$RDR"'cat "$R/autocommit.deadline"' | tr -d '\r '); HB=$(bootid)
  undetermined "$tag" && return 1
  # Pi 4 EEPROM 2026-09-23 wrong-slot no-op: the "trial" can come back on the committed slot. Never inject there.
  [ "$s" != "$pre" ] || { no "$tag: trial did not switch off committed slot $pre (EEPROM wrong-slot no-op?) — not injecting on the good slot"; return 1; }
  [ "$it" = 0 ] || { no "$tag: booted slot is not an uncommitted trial"; return 1; }
  [ "$hc" = 0 ] || { no "$tag: hold-commit not consumed into this trial (p6 flag still there or no marker) — v2.4 autocommit missing?"; return 1; }
  isint "$HDL" || { no "$tag: no autocommit deadline on the trial"; return 1; }
  HT=$s; echo "    held trial on slot $HT (boot ${HB:0:8}, deadline uptime ${HDL}s)"; }

# Wait for the watchdog's revert reboot: boot_id leaves $1. One read per poll (F1: two reads let a failed
# read pass for a new boot). Budget = deadline + DEFER_MAX + 120 (the watchdog may defer — F7). A commit
# seen meanwhile is a FAIL. rc 0 rebooted, 1 not (evidence printed), 2 committed.
wait_revert(){ local tag=$1 b0=$2 dl=$3 lim t0=$SECONDS o b c
  lim=$((dl + DEFER_MAX + 120))
  while [ $((SECONDS - t0)) -lt "$lim" ]; do
    o=$(timeout 30 ssh $S -o ConnectTimeout=6 "root@$NODE" "$RDR"'echo "$(cat /proc/sys/kernel/random/boot_id) $([ -f "$R/autocommit.committed" ] && echo C || echo -)"' 2>/dev/null | tr -d '\r')
    b=${o% *}; c=${o##* }
    if [ -n "$o" ]; then
      [ "$b" != "$b0" ] && return 0
      [ "$c" = C ] && return 2
    fi
    sleep 10
  done
  echo "    no revert within ${lim}s; watchdog evidence: $(q 'logread | grep -E "batman-autocommit.*(revert deferred|TRIAL-REVERTED|claim)" | tail -3' | tr '\n' ' ')"
  return 1; }

r1(){ echo "== R1 docker-run-broken trial is NOT committed and reverts (hold -> break runc -> release) =="
  need_tenant R1 || return
  precheck || return
  local pre tr b0 dl post crun log rel rm w
  pre=$(slot); [ -n "$pre" ] || { no "R1 slot unreadable — not verified"; return; }
  held_trial R1 "$pre" || return; tr=$HT; b0=$HB; dl=$HDL
  echo "    breaking runc on trial slot $tr"
  n 'for p in /usr/bin/runc /usr/sbin/runc; do [ -f "$p" ] && { mv "$p" "$p.off"; break; }; done'; R1_BROKE=1; R1_SLOT=$tr
  q 'docker info >/dev/null 2>&1' && echo "    trial: docker engine still answers (docker run cannot)"
  n 'batman-autocommit release' 2>&1 | sed 's/^/    /'
  unread_reset; q "$RDR"'[ -f "$R/autocommit.ctl/released" ]'; rm=$?
  undetermined R1 && return
  [ "$rm" = 0 ] || { no "R1: release did not take effect (no released marker) — would revert for 'held', not for the canary"; return; }
  echo "    released; waiting for the watchdog revert (deadline uptime ${dl}s, budget +${DEFER_MAX}s deferral)"
  wait_revert R1 "$b0" "$dl"; w=$?
  [ "$w" = 2 ] && { no "R1 committed a broken trial (BAD) despite the pre-commit canary"; return; }
  [ "$w" = 0 ] || { no "R1: no revert reboot within the budget — trial still up"; return; }
  settle 300 || { no "R1 node not stably reachable after the revert"; return; }
  unread_reset
  post=$(slot); committed; local cm=$?
  log=$(q "tail -8 /opt/batdata/log/autocommit.log" | tr -d '\r')
  q "grep -q '^slot=$tr ' /opt/batdata/state/bad-slot"; local bs=$?
  ots_wait; local ou=$?
  crun=$(q 'batman-autocommit canary >/dev/null 2>&1 && echo OK || echo FAIL' | tr -d '\r\n ')
  undetermined R1 && return
  echo "$log" | sed 's/^/    aclog: /'
  echo "$log" | grep -q "PRECOMMIT-CANARY-FAIL .*slot=$tr" || no "R1: no PRECOMMIT-CANARY-FAIL for trial slot $tr in autocommit.log"
  # the watchdog's reason is the last why: the canary, or the engine itself if dockerd died without runc (F13)
  rel=$(echo "$log" | grep "TRIAL-REVERTED .*slot=$tr" | tail -1)
  echo "$rel" | grep -qE 'reason=.*(canary|docker engine not live)' || no "R1: TRIAL-REVERTED for slot $tr missing or its reason is not the canary/engine [${rel:-none}]"
  echo "$rel" | grep -q 'held for operator' && no "R1: reverted because still HELD, not because of the canary"
  [ "$bs" = 0 ] || no "R1: bad-slot does not record trial slot $tr"
  if [ "$post" = "$pre" ] && [ "$cm" = 0 ] && [ "$ou" = 0 ] && [ "$crun" = OK ]; then ok "R1 broken trial $tr refused at the pre-commit canary and reverted to committed slot $pre; canary OK, OTS 6/6"
  else no "R1 did not end on the good committed slot (pre=$pre post=$post committed=$([ $cm = 0 ] && echo y || echo n) ots=$([ $ou = 0 ] && echo y || echo n) canary=$crun)"; restore_node; fi
  echo "    NOTE: slot $tr keeps runc.off until its next OTA rewrites it (bad-slot records it: never committed as a stale fallback)"; }

# R3/R4 judge "healthy and held" from ONE read per poll (boot_id, uptime, committed, why). The held state
# must hold for NEED*POLL+30 = 60 s (a slow mesh join or a post-OTA converge may still be settling, so no
# fixed uptime), bounded by deadline-120; a reboot or a commit meanwhile is a FAIL (F9).
HELDWHY="held for operator acceptance (batman-autocommit release)"
# Every change of (drift verdict, mesh reachability+plinks, why) is printed, so a FAIL shows WHY the trial was
# not healthy-and-held (2026-10-08 canonical fi-r4: held at 81 s per the node, yet no 60 s held window by 480 s).
wait_held(){ local tag=$1 b0=$2 dl=$3 hs="" o b u c w t0=$SECONDS dd mm last=""
  while :; do
    o=$(timeout 30 ssh $S -o ConnectTimeout=6 "root@$NODE" "$RDR"'d=$(for f in "$R"/batman-payload-*-drift.json; do [ -f "$f" ] && printf "%s@%ss," "$(sed -n "s/.*\"status\":\"\([A-Z]*\)\".*/\1/p" "$f")" "$(( $(date +%s) - $(sed -n "s/.*\"ts\":\([0-9]*\).*/\1/p" "$f") ))"; done)
      m=-; . /usr/lib/batman/meshjoin.sh 2>/dev/null && meshjoin_sample && { meshjoin_reachable && m=R; m="$m/plink${MJ_PLINK:-0}/bat${MJ_BAT:-0}"; }
      echo "$(cat /proc/sys/kernel/random/boot_id) $(cut -d. -f1 /proc/uptime) $([ -f "$R/autocommit.committed" ] && echo C || echo -) ${d:--} $m $(cat "$R/autocommit.why" 2>/dev/null)"' 2>/dev/null | tr -d '\r')
    if [ -n "$o" ]; then
      read -r b u c dd mm w <<< "$o"
      [ "drift=$dd mesh=$mm why=[$w]" = "$last" ] || { last="drift=$dd mesh=$mm why=[$w]"; echo "    @${u}s $last"; }
      [ "$b" = "$b0" ] || { no "$tag: the held trial rebooted/reverted before the check ended (boot ${b0:0:8} -> ${b:0:8})"; return 1; }
      [ "$c" = C ] && { no "$tag committed while HELD (uptime ${u}s)"; return 1; }
      if isint "$u" && [ "$u" -ge $((dl - 120)) ]; then no "$tag: not healthy-and-held for 60 s before deadline-120 (last why: [$w])"; return 1; fi
      if [ "$w" = "$HELDWHY" ]; then [ -n "$hs" ] || hs=$SECONDS; [ $((SECONDS - hs)) -ge 60 ] && { echo "    healthy and HELD for $((SECONDS - hs)) s (uptime ${u}s), uncommitted, why=[held only]"; return 0; }
      else hs=""; fi
    fi
    [ $((SECONDS - t0)) -lt $((dl + 60)) ] || { no "$tag: node unreadable until past the deadline — not verified"; return 1; }
    sleep 10
  done; }

r3(){ echo "== R3 healthy held trial waits for release, then commits (#261) =="
  [ "$NOTENANT" = 1 ] || need_tenant R3 || return
  precheck || return
  local pre tr t0 o cm ou
  pre=$(slot); [ -n "$pre" ] || { no "R3 slot unreadable — not verified"; return; }
  held_trial R3 "$pre" || return; tr=$HT
  wait_held R3 "$HB" "$HDL" || return
  t0=$SECONDS; o=$(n 'batman-autocommit release --wait' 2>&1 | tr -d '\r'); echo "$o" | sed 's/^/    /'
  unread_reset; committed; cm=$?; ots_wait; ou=$?
  undetermined R3 && return
  echo "$o" | grep -q 'release: committed' || [ "$cm" = 0 ] || { no "R3: release --wait did not end committed"; return; }
  [ $((SECONDS - t0)) -le 60 ] || no "R3: commit took $((SECONDS - t0)) s after release (> 60 s)"
  [ "$cm" = 0 ] && [ "$ou" = 0 ] && ok "R3 healthy trial $tr held until release, then committed; $(otsword)" || no "R3: after release committed=$([ $cm = 0 ] && echo y || echo n) $(otsword)=$([ $ou = 0 ] && echo y || echo n)"; }

r4(){ echo "== R4 healthy held trial that nobody releases is reverted at the deadline (#261) =="
  [ "$NOTENANT" = 1 ] || need_tenant R4 || return
  precheck || return
  local pre tr b0 dl w post cm log rel bs ou
  pre=$(slot); [ -n "$pre" ] || { no "R4 slot unreadable — not verified"; return; }
  held_trial R4 "$pre" || return; tr=$HT; b0=$HB; dl=$HDL
  wait_held R4 "$b0" "$dl" || return
  echo "    not releasing; waiting for the deadline revert (deadline uptime ${dl}s)"
  wait_revert R4 "$b0" "$dl"; w=$?
  [ "$w" = 2 ] && { no "R4 committed a HELD trial that was never released (BAD)"; return; }
  [ "$w" = 0 ] || { no "R4: no revert reboot within the budget — held trial still up"; return; }
  settle 300 || { no "R4 node not stably reachable after the revert"; return; }
  unread_reset
  post=$(slot); committed; cm=$?
  log=$(q "tail -8 /opt/batdata/log/autocommit.log" | tr -d '\r')
  q "grep -q '^slot=$tr ' /opt/batdata/state/bad-slot"; bs=$?
  ots_wait; ou=$?
  undetermined R4 && return
  echo "$log" | sed 's/^/    aclog: /'
  rel=$(echo "$log" | grep "TRIAL-REVERTED .*slot=$tr" | tail -1)
  echo "$rel" | grep -q 'reason=held for operator' || no "R4: TRIAL-REVERTED for slot $tr missing or its reason is not the hold [${rel:-none}]"
  # every revert records bad-slot (watchdog): an unaccepted build must never be committed as a #133 stale fallback
  [ "$bs" = 0 ] || no "R4: bad-slot does not record trial slot $tr"
  if [ "$post" = "$pre" ] && [ "$cm" = 0 ] && [ "$ou" = 0 ]; then ok "R4 held trial $tr never released -> reverted at the deadline to committed slot $pre; $(otsword)"
  else no "R4 did not end on the committed slot (pre=$pre post=$post committed=$([ $cm = 0 ] && echo y || echo n) $(otsword)=$([ $ou = 0 ] && echo y || echo n))"; fi; }

# test seam (scripts/test-harness-265.sh): load the functions only
[ "${FI_SOURCE_ONLY:-0}" = 1 ] && return 0 2>/dev/null
echo "=== fault-injection on $NODE (case=$CASE$([ "$NOTENANT" = 1 ] && echo ', --no-tenant')) ==="
committed || echo "WARN: node not on a committed slot (or unreadable); some cases assume a clean committed start"
case "$CASE" in f2) f2;; f1) f1;; r2) r2;; r1) r1;; r3) r3;; r4) r4;; all) f2; f1; r2; r1; r3; r4;; *) echo "unknown case $CASE"; exit 2;; esac
restore_node
echo "================ fault-injection: $PASS passed, $FAIL failed ================"
[ "$FAIL" = 0 ]
