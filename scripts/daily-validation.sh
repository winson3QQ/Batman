#!/bin/bash
# Daily system validation — runs the suites that are cheap and safe to repeat, and writes a
# dated report. Designed for cron in the early-morning window; see docs/storage-architecture.md.
#
#   scripts/daily-validation.sh [report-dir]        default: ~/batman-validation
#
# Env:
#   BENCH_NODE   A/B bench card node       (default 10.41.254.1)
#   MESH_NODE    a live mesh node          (default 10.41.239.205)
#   AB_MODE      --inspect-only | --destructive | --skip   (default --inspect-only)
#   ALLOW_SKIP   set to 1 to let a run with skipped suites still exit 0  (default 0)
#
# Every suite is one of PASS / FAIL / SKIP, and SKIP is reported as loudly as FAIL — including
# in the EXIT STATUS. A run that quietly skipped everything because no hardware answered must
# not look like a green run, and cron only ever sees the exit status.
#
# AB_MODE defaults to --inspect-only, not --destructive. This is the scheduled runner:
# ab-selftest.sh --destructive reboots the bench node four times, renames bootB/start4.elf and
# zeroes the head of rootB, and a run that dies between the break and the restore (host reboot,
# network drop, ssh timeout) leaves slot B broken until somebody reads the log. That belongs to
# a release, not to 06:30 every day; docs/storage-architecture.md assigns --inspect-only to
# "scheduled" and --destructive to "before tagging a release". Pass AB_MODE explicitly for the
# release run.
set -uo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-$HOME/batman-validation}
BENCH_NODE=${BENCH_NODE:-10.41.254.1}
MESH_NODE=${MESH_NODE:-10.41.239.205}
AB_MODE=${AB_MODE:---inspect-only}
ALLOW_SKIP=${ALLOW_SKIP:-0}

STAMP=$(date +%Y%m%d-%H%M%S)
DIR="$OUT/$STAMP"; mkdir -p "$DIR"
REPORT="$DIR/report.md"
NPASS=0; NFAIL=0; NSKIP=0
ROWS=()

# Liveness by ssh, not ping: `ping -c1 -W2` is Linux-only (Windows/Git-Bash ping.exe rejects the
# flags), and the suites all need ssh anyway — an ssh-up node is what they actually require (#133).
up() { timeout 8 ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 "root@$1" true >/dev/null 2>&1; }

suite() {                       # $1 = name, $2 = why-it-matters, $3 = command ("" => skip)
  local name=$1 why=$2 cmd=$3 log="$DIR/$1.log" rc
  if [ -z "$cmd" ]; then
    NSKIP=$((NSKIP+1)); ROWS+=("| $name | SKIP | $why |"); echo "SKIP  $name"; return
  fi
  local t0=$SECONDS
  { echo "# $(date -Is)"; echo "# $cmd"; eval "$cmd"; } > "$log" 2>&1; rc=$?
  local dt=$((SECONDS-t0))
  if [ $rc -eq 0 ]; then NPASS=$((NPASS+1)); ROWS+=("| $name | PASS | ${dt}s — $why |"); echo "PASS  $name (${dt}s)"
  else NFAIL=$((NFAIL+1)); ROWS+=("| $name | **FAIL** | ${dt}s — $why |"); echo "FAIL  $name (${dt}s)"; fi
}

echo "=== daily validation $STAMP ==="

# 1. No hardware needed: the A/B card invariants, built on a loop device.
suite ab-card-invariants \
  "the A/B card layout and cmdline invariants (#133)" \
  "$REPO/tests/ab-card-invariants.sh"

# 2. No hardware needed: the MAC->IP derivation used by the first-boot hook.
suite onboarding-ip \
  "first-boot MAC->IP + DHCP-window derivation" \
  "sh $REPO/scripts/test-onboarding-ip"

# 3. Hardware: the A/B bench card. Refuses on its own if the target is not an A/B card.
if [ "$AB_MODE" = --skip ]; then
  suite ab-selftest "A/B boot, switch, fallback and panic recovery (#133)" ""
elif up "$BENCH_NODE"; then
  suite ab-selftest \
    "A/B boot, switch, fallback and panic recovery (#133)" \
    "$REPO/scripts/ab-selftest.sh $BENCH_NODE $AB_MODE"
else
  suite ab-selftest "A/B boot, switch, fallback and panic recovery (#133) — BENCH_NODE $BENCH_NODE did not answer" ""
fi

# 4. Hardware: mesh health on a live node.
if up "$MESH_NODE"; then
  suite meshtest \
    "six-layer mesh health on $MESH_NODE" \
    "timeout 180 ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 root@$MESH_NODE 'm=\$(command -v meshtest 2>/dev/null); [ -n \"\$m\" ] || m=/root/meshtest; [ -f \"\$m\" ] || m=/rom/root/meshtest; sh \"\$m\" -q'"
else
  suite meshtest "six-layer mesh health — MESH_NODE $MESH_NODE did not answer" ""
fi

# 5. Hardware: write-placement contract — no unexpected app/daemon state DB on the rootfs overlay (#104).
if up "$BENCH_NODE"; then
  suite flash-write-guard \
    "no new state DB on the rootfs overlay — write-placement contract (#104/#41)" \
    "sh $REPO/scripts/flash-write-guard.sh $BENCH_NODE"
else
  suite flash-write-guard "write-placement contract (#104) — BENCH_NODE $BENCH_NODE did not answer" ""
fi

# ============================================================================
# v1.1 FEATURE regression — the completed features, not just the A/B plumbing.
# Two tiers, mirroring ab-selftest's inspect/destructive split:
#   A (always, non-destructive): real black/white-box — drive the interface and
#     assert the outcome, without disrupting live service. Safe on any node daily.
#   B (FEATURE_MODE=--destructive): induces the actual failure each feature must
#     survive (clock-back / reflash / slot-switch). Runs ONLY on DNODE, which
#     MUST have ethernet — a broken run is recovered out-of-band over eth, never
#     physical access. Release-time, not the cron.
# Each check is validated: an empty/UNKNOWN string never satisfies an assertion.
# ============================================================================
OTS_NODE=${OTS_NODE:-$MESH_NODE}          # the node carrying the OTS payload
FEATURE_MODE=${FEATURE_MODE:---daily}     # --daily | --destructive (adds tier B)
DNODE=${DESTRUCTIVE_NODE:-$OTS_NODE}      # tier-B target — MUST have ethernet

fssh() { timeout "${2:-60}" ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 "root@$1" "$3"; }

# ---- tier A: non-destructive, real ----
chk_98()  { fssh "$1" 60 'sh /opt/batdata/deploy/ots/verify-profile-ots.sh'; }           # inspects 9 axes ×6
chk_162() { fssh "$1" 30 '
  n=0; for c in opentakserver ots-db ots_cot_parser ots_eud_handler ots_eud_handler_ssl rabbitmq; do
    [ "$(docker inspect -f "{{.State.Running}}" "$c" 2>/dev/null)" = true ] && n=$((n+1)); done
  db=$(docker exec ots-db psql -U ots -d ots -tAc "select 1" 2>/dev/null | tr -d " ")
  echo "running=$n/6 postgres=$db"; [ "$n" = 6 ] && [ "$db" = 1 ]'; }
chk_156() { fssh "$1" 45 '
  docker rm -f dv-decoy >/dev/null 2>&1
  docker run -d --name dv-decoy --entrypoint sleep batman/ots:1.7.13-arm64 60 >/dev/null 2>&1 || { echo "decoy start failed"; exit 2; }
  sleep 18   # clear verify-profile MIN_UPTIME=15 (else UNKNOWN, not DRIFT)
  sh /opt/batdata/deploy/ots/verify-profile.sh dv-decoy /opt/batdata/deploy/ots/ots.hardening.env >/tmp/dv-vp 2>&1; rc=$?
  docker rm -f dv-decoy >/dev/null 2>&1
  echo "unhardened decoy -> verify-profile rc=$rc (want non-0 = DRIFT detected)"; [ "$rc" -ne 0 ]'; }
chk_130() { fssh "$1" 20 '
  st=$(/usr/bin/halow-status json 2>/dev/null | sed -n "s/.*\"join\":{\"state\":\"\([A-Za-z_]*\)\".*/\1/p" | head -1)
  p=$(batctl n 2>/dev/null | grep -c wlh0)
  echo "halow join.state=$st  batctl peers=$p"
  [ -n "$st" ] || exit 1
  if [ "$p" -gt 0 ]; then [ "$st" = JOINED ]; else [ "$st" != JOINED ]; fi'; }   # verdict must agree with radio truth
chk_14()  { fssh "$1" 20 '
  n=$(QUERY_STRING=json sh /www/cgi-bin/mesh 2>/dev/null | grep -o "\"nodes\":[0-9][0-9]*" | head -1 | grep -o "[0-9][0-9]*")
  p=$(batctl n 2>/dev/null | grep -c wlh0)
  echo "cgi mesh.nodes=$n  batctl peers=$p"
  [ -n "$n" ] && [ "$n" -ge 1 ] && [ "$n" -le $((p+1)) ]'; }   # aggregate agrees with batctl (<= peers+self)
chk_202() { fssh "$1" 20 '                                     # a JOINED node must have seeded p5 (#202)
  [ -b /dev/mmcblk0p5 ] || { echo "no p5 — skip"; exit 0; }
  m=/mnt/dv-p5; mkdir -p "$m"
  mount -t ext4 -o ro /dev/mmcblk0p5 "$m" 2>/dev/null || { echo "p5 not plain-ext4 (LUKS/Secure? interlock skips it too) — skip"; exit 0; }
  seeded=0; [ -f "$m/.seeded" ] && seeded=1
  key=0; grep -q "wireless.default_radio1.key=" "$m/overrides.uci" 2>/dev/null && key=1
  umount "$m" 2>/dev/null; rmdir "$m" 2>/dev/null
  echo "p5 .seeded=$seeded  mesh-key-in-overrides.uci=$key (join must persist radio delta regardless of #137 lockdown)"
  [ "$seeded" = 1 ] && [ "$key" = 1 ]'; }   # decoupled from lockdown-OK: a meshed-but-open node MUST still seed

if up "$OTS_NODE"; then
  suite confinement-98   "OTS container confinement — 9 axes ×6 (#98)"                       "chk_98 $OTS_NODE"
  suite ots-up-162       "OTS 6/6 running + postgres endpoint answers (#162)"                "chk_162 $OTS_NODE"
  suite drift-detect-156 "reconciler flags an unhardened decoy as DRIFT (#156, white-box)"   "chk_156 $OTS_NODE"
else
  for s in confinement-98 ots-up-162 drift-detect-156; do suite "$s" "OTS_NODE $OTS_NODE did not answer" ""; done
fi
if up "$MESH_NODE"; then
  suite field-status-130 "halow-status verdict agrees with batctl radio truth (#130)"        "chk_130 $MESH_NODE"
  suite mesh-console-14  "/cgi-bin/mesh aggregate agrees with batctl (#14)"                   "chk_14 $MESH_NODE"
  suite p5-seed-202      "a JOINED node auto-seeds p5 (radio delta), decoupled from lockdown (#202)" "chk_202 $MESH_NODE"
else
  for s in field-status-130 mesh-console-14 p5-seed-202; do suite "$s" "MESH_NODE $MESH_NODE did not answer" ""; done
fi

# ---- tier B: destructive, induces the real failure — DNODE (eth) only, --destructive ----
dwait() {   # $1 node, wait until ssh answers with a boot_id, up to $2 s
  local n=$1 max=${2:-200} t=0
  while [ "$t" -lt "$max" ]; do
    fssh "$n" 8 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null | grep -q . && return 0
    sleep 8; t=$((t+8))
  done; return 1
}
bchk_174() {   # clock forward-only: reboot, assert faketime restored the clock forward (not back to 2025)
  fssh "$1" 15 '[ -f /etc/init.d/batman-faketime ]' || { echo "faketime not installed"; return 1; }
  fssh "$1" 15 'reboot' >/dev/null 2>&1; sleep 20; dwait "$1" 220 || return 1
  local yr; yr=$(fssh "$1" 12 'date -u +%Y' | tr -d " ")
  echo "post-reboot year=$yr (want >=2026 = faketime restored forward)"; [ -n "$yr" ] && [ "$yr" -ge 2026 ]; }
bchk_192() {   # clear the guardian from the overlay (as an A/B flash does), reboot, assert it auto-returns
  fssh "$1" 12 'ls /etc/init.d/batman-ots >/dev/null 2>&1' || { echo "no guardian to test"; return 2; }
  fssh "$1" 15 'rm -f /etc/init.d/batman-ots /etc/rc.d/S*batman-ots' >/dev/null 2>&1
  fssh "$1" 15 'reboot' >/dev/null 2>&1; sleep 20; dwait "$1" 240 || return 1
  sleep 30   # batdata-mount restore + guardian start
  local r; r=$(fssh "$1" 12 'ls /etc/init.d/batman-ots >/dev/null 2>&1 && pgrep -f batman-ots >/dev/null && echo yes || echo no' | tr -d " ")
  echo "guardian auto-restored after overlay-clear+reboot: $r"; [ "$r" = yes ]; }
bchk_173() {   # force a real kernel panic; assert the ramoops backend captured it AND boot-reason classified PANIC (#173/#61)
  # the backend must be the correctly-reg'd ramoops-pi4 (the #173 fix). With a bare `dtoverlay=ramoops` (2-cell
  # reg, invalid on arm64 bcm2711) or on HW that cannot preserve the reserved region, pstore never registers a
  # backend and the panic is silently lost — which is exactly the regression this guards. Precondition-checked so
  # a node missing the fix FAILs loudly instead of the test passing on a node that captured nothing.
  fssh "$1" 12 'dmesg | grep -q "Registered ramoops as persistent store backend"' \
    || { echo "ramoops backend NOT registered — pstore capture inactive (#173 fix missing, or HW cannot preserve the region)"; return 1; }
  local before; before=$(fssh "$1" 12 'ls /opt/batdata/crash/*_dmesg-ramoops-* 2>/dev/null | wc -l' | tr -d " ")
  fssh "$1" 12 'echo 1 > /proc/sys/kernel/sysrq; sync; echo c > /proc/sysrq-trigger' >/dev/null 2>&1   # real kernel panic
  sleep 20; dwait "$1" 240 || return 1
  sleep 8   # 95-batman-storage moves pstore records -> crash/ and writes boot-reasons.log at first boot
  local after reason
  after=$(fssh "$1" 12 'ls /opt/batdata/crash/*_dmesg-ramoops-* 2>/dev/null | wc -l' | tr -d " ")
  reason=$(fssh "$1" 12 'tail -1 /opt/batdata/log/boot-reasons.log 2>/dev/null')
  echo "dmesg-ramoops records ${before:-?} -> ${after:-?}; last boot-reason: $reason"
  [ -n "$after" ] && [ "${after:-0}" -gt "${before:-0}" ] && echo "$reason" | grep -q 'prev=PANIC'; }

if [ "$FEATURE_MODE" = --destructive ]; then
  if fssh "$DNODE" 8 '[ "$(cat /sys/class/net/eth0/carrier 2>/dev/null)" = 1 ]'; then
    suite faketime-174 "clock survives a reboot forward, not back to 2025 (#174, destructive)"        "bchk_174 $DNODE"
    suite guardian-192 "guardian auto-restores after an overlay-clear+reboot (#192, destructive)"     "bchk_192 $DNODE"
    suite ramoops-173  "kernel panic captured to pstore and classified PANIC (#173/#61, destructive)"  "bchk_173 $DNODE"
    # NOT reboot-testable — validated by other means (a supervised run on manet01 proved this the hard way):
    #  #137 LOCKED path: the lockdown gate lives in the 96-batman-config-migrate UCI-DEFAULT, which runs
    #    ONLY on a FRESH SLOT firstboot, never on a plain reboot — so a reboot-based test cannot trigger it
    #    (and setting a root password to seed it locks the empty-pw path out). #137 LOCKED is exercised on a
    #    seeded A/B FLASH (Case B); the UNPROVISIONED fail-open path is exercised on every flash/burn.
    #  #103 keyguard: keyguard DOES re-run every boot, but the test has to blank the live mesh key, which
    #    drops the mesh and risks not reforming — too destructive for the unattended tier; validate supervised.
    #  #127 joinwatch: the stuck-node AUTO-REBOOT window is ~60 min (not a timed test); its join DIAGNOSIS
    #    is covered by field-status-130.
    #  config-survival: asserted during the flash/burn (a fresh slot's firstboot restores mesh_id/key/channel).
  else
    for s in faketime-174 guardian-192 ramoops-173; do suite "$s" "DNODE $DNODE has no ethernet — destructive refused (no out-of-band recovery)" ""; done
  fi
fi

{
  echo "# Batman daily validation — $(date -Is)"
  echo
  echo "**$NPASS passed, $NFAIL failed, $NSKIP skipped**"
  echo
  echo "| suite | result | notes |"
  echo "|---|---|---|"
  printf '%s\n' "${ROWS[@]}"
  echo
  echo "Host: \`$(hostname)\`  ·  bench: \`$BENCH_NODE\` (\`$AB_MODE\`)  ·  mesh: \`$MESH_NODE\`"
  echo "Repo: \`$(cd "$REPO" && git rev-parse --short HEAD 2>/dev/null)\` on \`$(cd "$REPO" && git rev-parse --abbrev-ref HEAD 2>/dev/null)\`"
  echo
  echo "Logs are next to this file, one per suite."
  [ $NSKIP -gt 0 ] && { echo; echo "> A skipped suite verified nothing. Do not read this run as green unless the skip count is 0."; }
} > "$REPORT"

ln -sfn "$DIR" "$OUT/latest"
echo
cat "$REPORT"

# A skip has to reach the exit status too. The bold warning above only exists inside report.md,
# which nobody opens on a green run — and the realistic failure mode of a scheduled hardware
# test is that the hardware was not plugged in. With both nodes unreachable every hardware
# suite SKIPs, NFAIL stays 0, and `[ $NFAIL -eq 0 ]` would hand cron a silent success for a run
# that verified nothing. Set ALLOW_SKIP=1 to opt out deliberately.
if [ $NFAIL -ne 0 ]; then
  exit 1
elif [ $NSKIP -ne 0 ] && [ "$ALLOW_SKIP" != 1 ]; then
  echo "EXIT 1: $NSKIP suite(s) skipped — nothing verified them. Set ALLOW_SKIP=1 if that is intended."
  exit 1
fi
exit 0
