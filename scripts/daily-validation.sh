#!/bin/bash
# Daily system validation — runs the suites that are cheap and safe to repeat, and writes a
# dated report. Designed for cron in the early-morning window; see docs/storage-architecture.md.
#
#   scripts/daily-validation.sh [report-dir]        default: ~/batman-validation
#
# Env:
#   BENCH_NODE   A/B bench card node       (default 10.41.254.1)
#   MESH_NODE    a live mesh node          (default 10.41.239.205)
#   AB_MODE      --destructive | --inspect-only | --skip   (default --destructive)
#
# Every suite is one of PASS / FAIL / SKIP, and SKIP is reported as loudly as FAIL. A run that
# quietly skipped everything because no hardware answered must not look like a green run.
set -uo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-$HOME/batman-validation}
BENCH_NODE=${BENCH_NODE:-10.41.254.1}
MESH_NODE=${MESH_NODE:-10.41.239.205}
AB_MODE=${AB_MODE:---destructive}

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
[ $NFAIL -eq 0 ]
