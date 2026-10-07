#!/bin/bash
# fault-injection.sh — DESTRUCTIVE fault-injection for the flash-and-go payload path (#159/#216).
# Release-gate / HIL, NOT for the daily cron: it reboots the node, OTA-flashes trial slots, and
# breaks a slot's docker runtime. Runs from an operator box that can ssh the node (default key).
# daily-validation.sh invokes it only under AB_MODE=--destructive, one case per suite (fi-f2/f1/r2/r1).
#
#   scripts/fault-injection.sh <ots-node> [--case f1|f2|r2|r1|r3|all]   (default: all)
#
# Env:
#   FI_PAYLOAD      payload ON THE NODE that R2/R1 OTA-flash (default /opt/batdata/ota.tar.gz)
#   EXPECT_VERSION  if set, the node's BATMAN_VERSION must equal it; unset prints "VERSION NOT PINNED"
#
# Requires on the node: an A/B OTA payload of the build the node RUNS (checked by precheck, #268 A2),
# a docker payload tenant (opentakserver), and the autocommit canary.
# Each case injects a fault and asserts the SYSTEM'S AUTONOMOUS response (no operator in the loop):
#   F1  a bad image tar is quarantined after N boots and never wedges the guardian (per-tenant)
#   F2  a lost image is recoverable from the offline images/loaded/ copy (mv-not-rm) on an offline fleet
#   R2  a first-loading tenant is NON-GATING (per-boot latch) so autocommit commits, not false-reverts
#   R1  a trial whose docker ENGINE answers `docker info` but cannot `docker run` (broken runc) fails
#       the autocommit canary and REVERTS to the good committed slot. KNOWN GAP #265: the canary latches
#       on its first success; v2.4 re-runs it before every commit. R1 holds the trial (#261 hold-commit),
#       breaks runc, releases — the pre-commit canary must refuse and the watchdog revert.
#   R3  a healthy trial with hold-commit stays uncommitted until `batman-autocommit release`, then commits (#261)
set -uo pipefail
NODE=${1:?usage: fault-injection.sh <ots-node> [--case f1|f2|r2|r1|all]}
CASE=${3:-all}; [ "${2:-}" = --case ] && CASE=${3:-all}
TENANT=opentakserver
APPS=/opt/batdata/apps
PAYLOAD=${FI_PAYLOAD:-/opt/batdata/ota.tar.gz}
S="-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -o LogLevel=ERROR"
n(){ ssh $S "root@$NODE" "$@"; }                       # node ssh
waitup(){ for _ in $(seq 1 "${1:-60}"); do ssh $S -o ConnectTimeout=6 "root@$NODE" true 2>/dev/null && return 0; sleep 6; done; return 1; }
slot(){ n 'batman-slot active' 2>/dev/null | tr -d "\r\n "; }
committed(){ n 'batman-slot is-trial >/dev/null 2>&1; [ $? = 1 ]' 2>/dev/null; }   # rc0 if committed
# 6/6 = six containers in state running (`docker ps` also lists ones restarting in a crash loop — #274 review C5)
ots_up(){ [ "$(n 'docker ps -q --filter status=running 2>/dev/null | wc -l' 2>/dev/null | tr -d "\r\n ")" -ge 6 ] 2>/dev/null; }
PASS=0; FAIL=0
ok(){ echo "  PASS $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }

# Leave the node able to serve (#268 A4). R1 renames runc to break `docker run`; if R1's trial is committed
# and rebooted into, dockerd starts without runc, exits, and does NOT come back when runc is put back —
# that left the OTS host dark for ~6 min on 2026-10-07. So: wait for the node, put back what was renamed
# on the BOOTED slot, restart dockerd if anything changed or it is down, wait for the tenant, prove
# containers run (canary, only once committed — the autocommit daemon is done then). Never swallowed.
R1_BROKE=0; R1_SLOT=""; RESTORED=0
restore_node(){
  [ "$RESTORED" = 1 ] && return 0
  echo "== restore_node"
  waitup 50 || { no "restore: node unreachable after 300 s — restore NOT done, node may be degraded"; return 1; }
  local moved i
  # a hold-commit flag left on p6 by an aborted R1/R3 would hold — then revert — the NEXT, unrelated OTA
  n 'rm -f /opt/batdata/state/autocommit-hold-commit; sync' 2>/dev/null
  moved=$(n 'm=""; for p in /usr/bin/runc /usr/sbin/runc; do [ -f "$p.off" ] && [ ! -e "$p" ] && mv "$p.off" "$p" && m="$m $p"; done; echo "$m"' 2>/dev/null | tr -d '\r')
  [ -n "$moved" ] && echo "    put back:$moved (slot $(slot))"
  if [ -n "$moved" ] || ! n 'pidof dockerd >/dev/null' 2>/dev/null; then
    echo "    restarting dockerd"; n '/etc/init.d/dockerd restart >/dev/null 2>&1' 2>/dev/null
  fi
  for i in $(seq 1 48); do ots_up && break; sleep 5; done
  ots_up || { no "restore: OTS not back to 6/6 within 240 s — node left degraded"; return 1; }
  if committed; then n 'batman-autocommit canary' >/dev/null 2>&1 || { no "restore: canary still fails after restore — node left degraded"; return 1; }; fi
  RESTORED=1; echo "    node restored: OTS 6/6$(committed && echo ', committed, canary ok')"
  [ "$R1_BROKE" = 1 ] && echo "    NOTE: R1 broke runc on slot $R1_SLOT; if that is not the booted slot it keeps runc.off until its next OTA rewrites it — do not 'batman-slot rollback' into it"
  return 0; }
trap 'rc=$?; restore_node || rc=1; exit $rc' EXIT

# The payload must be the image the node RUNS (#268 A2): the old harness OTA-flashed whatever sat in
# /opt/batdata/ota.tar.gz, and a stale 1.5.0 there turned both slots of the OTS host into 1.5.0.
# Compares the payload's root.squashfs with the first size= bytes of the booted rootfs partition (the
# /rom mount source) — the same read `batman-slot verify` does.
PRECHECK=""
precheck(){
  [ -n "$PRECHECK" ] && { [ "$PRECHECK" = ok ]; return; }
  echo "== payload precheck ($PAYLOAD)"
  local o; o=$(n "P=$PAYLOAD; EXP='${EXPECT_VERSION:-}'"'
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
  PRECHECK=bad; no "precheck refused R2/R1 (would OTA-flash a different build): $(echo "$o" | grep '^ERR' | head -1)"; return 1; }

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
  local left failed; left=$(n "ls $D/*.tar 2>/dev/null" 2>/dev/null); failed=$(n "ls $D/failed/ 2>/dev/null" 2>/dev/null | tr -d "\r");
  [ -z "$left" ] && echo "$failed" | grep -q bad.tar && ok "F1 bad.tar quarantined to failed/ after N boots" || no "F1 not quarantined (left=$left failed=$failed)"
  ots_up && ok "F1 healthy tenant (OTS) stayed 6/6 throughout — per-tenant isolation" || no "F1 OTS not 6/6"
  n "rm -rf $APPS/faulttest"; }

r2(){ echo "== R2 first-loading tenant is non-gating (no false revert) =="
  precheck || return
  local T=$APPS/r2test
  n "mkdir -p $T/images; echo 'IMAGE r2test=busybox:nope' > $T/r2test.manifest; head -c 200000 /dev/urandom > $T/images/pending.tar; rm -f $T/images/.fail-pending.tar; rm -rf $T/images/failed $T/images/loaded"
  n "setsid sh -c 'sysupgrade -n $PAYLOAD >/opt/batdata/sysup.log 2>&1' </dev/null >/dev/null 2>&1 &"; sleep 50; waitup 60 || { no "R2 node did not return"; return; }
  local c=0; for _ in $(seq 1 80); do committed && ots_up && { c=1; break; }; sleep 8; done
  local latch; latch=$(n 'ls /tmp/batman-firstload-r2test.latch 2>/dev/null' 2>/dev/null)
  [ "$c" = 1 ] && [ -n "$latch" ] && ok "R2 committed while r2test first-loading (latch present) — non-gating, no false revert" || no "R2 did not commit / no latch (committed=$c latch=$latch)"
  n "rm -rf $APPS/r2test; rm -f /tmp/batman-firstload-r2test.latch"; }

# R1/R3 use the #261 hold-commit (ab-autocommit v2.4) so nothing races: the trial is held, the fault is
# injected (R1) or not (R3), THEN released — the commit decision happens strictly after.
nodever(){ n 'sed -n s/^BATMAN_VERSION=//p /etc/batman-build' 2>/dev/null | tr -d '\r'; }
bootid(){ n 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null | tr -d '\r'; }
# OTA the staged payload into a HELD trial; on success sets HT (the trial slot). Not run in $(...): its FAILs must count.
HT=""
isint(){ case "$1" in ""|*[!0-9]*) return 1;; esac; }
held_trial(){ local tag=$1 pre=$2 ver; HT=""
  ver=$(nodever); [ -n "$ver" ] || { no "$tag: node version unreadable"; return 1; }
  n "echo '$ver' > /opt/batdata/state/autocommit-hold-commit; sync" || { no "$tag: could not arm hold-commit"; return 1; }
  n "setsid sh -c 'sysupgrade -n $PAYLOAD >/opt/batdata/sysup.log 2>&1' </dev/null >/dev/null 2>&1 &"; sleep 50
  waitup 60 || { no "$tag: trial did not come up"; return 1; }
  sleep 8
  # Pi 4 EEPROM 2026-09-23 wrong-slot no-op: the "trial" can come back on the committed slot. Never inject there.
  [ "$(slot)" != "$pre" ] || { no "$tag: trial did not switch off committed slot $pre (EEPROM wrong-slot no-op?) — not injecting on the good slot"; return 1; }
  n 'batman-slot is-trial >/dev/null 2>&1; [ $? = 0 ]' || { no "$tag: booted slot is not an uncommitted trial"; return 1; }
  n '[ ! -e /opt/batdata/state/autocommit-hold-commit ] && [ -f /tmp/autocommit.ctl/hold-commit ]' \
    || { no "$tag: hold-commit not consumed into this trial (p6 flag still there or no marker) — v2.4 autocommit missing?"; return 1; }
  HT=$(slot); }

r1(){ echo "== R1 docker-run-broken trial is NOT committed and reverts (hold -> break runc -> release) =="
  precheck || return
  local pre tr b0 dl i post crun log
  pre=$(slot); held_trial R1 "$pre" || return; tr=$HT
  echo "    trial on slot $tr (held); breaking runc"
  n 'for p in /usr/bin/runc /usr/sbin/runc; do [ -f "$p" ] && { mv "$p" "$p.off"; break; }; done'; R1_BROKE=1; R1_SLOT=$tr
  n 'docker info >/dev/null 2>&1' && echo "    trial: docker engine still answers (docker run cannot)"
  b0=$(bootid); dl=$(n 'cat /tmp/autocommit.deadline' 2>/dev/null | tr -d '\r ')
  isint "$dl" || { no "R1: no autocommit deadline on the trial"; return; }
  n 'batman-autocommit release' 2>&1 | sed 's/^/    /'
  n '[ -f /tmp/autocommit.ctl/released ]' || { no "R1: release did not take effect (no released marker) — would revert for 'held', not for the canary"; return; }
  # now the pre-commit canary must refuse; the watchdog reverts at the deadline (no manual reboot here)
  echo "    released; waiting for the watchdog revert (deadline uptime ${dl}s)"
  for i in $(seq 1 $(( (dl + 180) / 10 ))); do
    [ "$(bootid)" != "$b0" ] && [ -n "$(bootid)" ] && break
    n '[ -f /tmp/autocommit.committed ]' 2>/dev/null && { no "R1 committed a broken trial (BAD) despite the pre-commit canary"; break; }
    sleep 10
  done
  waitup 60 || { no "R1 node did not return after the revert"; return; }; sleep 20
  post=$(slot); crun=$(n 'batman-autocommit canary >/dev/null 2>&1 && echo OK || echo FAIL' 2>/dev/null | tr -d '\r\n ')
  log=$(n "tail -6 /opt/batdata/log/autocommit.log" 2>/dev/null | tr -d '\r'); echo "$log" | sed 's/^/    aclog: /'
  echo "$log" | grep -q "PRECOMMIT-CANARY-FAIL .*slot=$tr" || no "R1: no PRECOMMIT-CANARY-FAIL for trial slot $tr in autocommit.log"
  echo "$log" | grep "TRIAL-REVERTED .*slot=$tr" | grep -q 'reason=.*canary' || no "R1: TRIAL-REVERTED for slot $tr missing or its reason is not the canary"
  echo "$log" | grep "TRIAL-REVERTED .*slot=$tr" | grep -q 'held for operator' && no "R1: reverted because still HELD, not because of the canary"
  n "grep -q '^slot=$tr ' /opt/batdata/state/bad-slot" || no "R1: bad-slot does not record trial slot $tr"
  if [ "$post" = "$pre" ] && committed && ots_up && [ "$crun" = OK ]; then ok "R1 broken trial $tr refused at the pre-commit canary and reverted to committed slot $pre; canary OK, OTS 6/6"
  else no "R1 did not end on the good committed slot (pre=$pre post=$post committed/ots/canary=$crun)"; restore_node; fi
  echo "    NOTE: slot $tr keeps runc.off until its next OTA rewrites it (bad-slot records it: never committed as a stale fallback)"; }

r3(){ echo "== R3 healthy held trial waits for release, then commits (#261) =="
  precheck || return
  local pre tr w u
  pre=$(slot); held_trial R3 "$pre" || return; tr=$HT
  echo "    trial on slot $tr (held); must stay uncommitted until uptime 240 s with ONLY the hold as reason"
  while :; do
    u=$(n 'cut -d. -f1 /proc/uptime' 2>/dev/null | tr -d '\r ')
    n '[ -f /tmp/autocommit.committed ]' 2>/dev/null && { no "R3 committed while HELD (uptime ${u}s)"; return; }
    w=$(n 'cat /tmp/autocommit.why' 2>/dev/null | tr -d '\r')
    case "${u:-0}" in *[!0-9]*) u=0;; esac
    [ "${u:-0}" -ge 240 ] && break
    sleep 10
  done
  [ "$w" = "held for operator acceptance (batman-autocommit release)" ] || { no "R3: at ${u}s the trial was not healthy-and-held (why: [$w])"; return; }
  echo "    uptime ${u}s, still uncommitted, why=[held only]; releasing"
  local t0=$SECONDS o; o=$(n 'batman-autocommit release --wait' 2>&1 | tr -d '\r'); echo "$o" | sed 's/^/    /'
  echo "$o" | grep -q 'release: committed' || { no "R3: release --wait did not end committed"; return; }
  [ $((SECONDS - t0)) -le 60 ] || no "R3: commit took $((SECONDS - t0)) s after release (> 60 s)"
  committed && ots_up && ok "R3 healthy trial $tr held until release, then committed; OTS 6/6" || no "R3: after release not committed/OTS (committed=$(committed && echo y || echo n))"; }

echo "=== fault-injection on $NODE (case=$CASE) ==="
committed || echo "WARN: node not on a committed slot; some cases assume a clean committed start"
case "$CASE" in f2) f2;; f1) f1;; r2) r2;; r1) r1;; r3) r3;; all) f2; f1; r2; r1; r3;; *) echo "unknown case $CASE"; exit 2;; esac
restore_node
echo "================ fault-injection: $PASS passed, $FAIL failed ================"
[ "$FAIL" = 0 ]
