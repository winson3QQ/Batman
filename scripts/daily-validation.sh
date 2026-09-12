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

up() { timeout 3 ping -c1 -W2 "$1" >/dev/null 2>&1; }

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
    "timeout 180 ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 root@$MESH_NODE 'sh /root/meshtest -q 2>/dev/null || sh /rom/root/meshtest -q'"
else
  suite meshtest "six-layer mesh health — MESH_NODE $MESH_NODE did not answer" ""
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
