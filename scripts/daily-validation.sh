#!/bin/bash
# Daily system validation — runs the suites that are cheap and safe to repeat, and writes a
# dated report. Designed for cron in the early-morning window; see docs/storage-architecture.md.
#
#   scripts/daily-validation.sh [report-dir]        default: ~/batman-validation
#
# Env:
#   BENCH_NODE   A/B bench card node       (default 10.41.254.1)
#   MESH_NODE    a live mesh node          (default 10.41.239.205)
#   IPERF_PEER   the OTHER node reached OVER THE MESH, iperf sink for the TCP suite  (unset => SKIP)
#   AB_MODE      --inspect-only | --destructive | --skip   (default --inspect-only)
#   ALLOW_SKIP   set to 1 to let a run with skipped suites still exit 0  (default 0)
#   SOAK_MIN / SOAK_HTTP_IMAGE   release-gate load soak length (>= 30) and HTTP-tenant image (#268 B3)
#   DV_TEST_NOREBOOT=1 / DV_TEST_FAKETIME_NOSAVE=1   negative controls: the reboot-based checks must FAIL
#   DV_ONLY      ERE of suite names to run (whole-name match); every other suite is reported SKIP "not
#                selected", so a partial run can never exit 0 unless ALLOW_SKIP=1. For targeted re-runs.
#   DV_T263_KO   #263 fault-injection module (built by the firmware's scripts/build-debug-mm6108-fi.sh for
#                the build the target runs); unset => halow-fi-263 is SKIP. DV_T263_NODE = its target
#                (default BENCH_NODE). DESTRUCTIVE: the node leaves the mesh for ~3 min and reboots.
#
# THE canonical harness is /home/yello/Batman on branch main. Run from anywhere else (a feature worktree, an
# rc integration branch) it says so loudly on stderr AND in the report header, so a report can never be
# mistaken for a main-harness run (#263 hygiene: several worktrees carry different copies of this file).
#
# Failures are reported in two groups: NEW, and KNOWN (every FAIL line matches an entry for that suite in
# scripts/validation-known-failures.txt, with an open issue). Known failures still make the exit status 1.
# A suite that could not test prints "SKIP-REASON: ..." and returns 3; rc 3 without that line is a FAIL.
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
IPERF_PEER=${IPERF_PEER:-}                 # the other node reached over the mesh (iperf sink); unset => SKIP
AB_MODE=${AB_MODE:---inspect-only}
ALLOW_SKIP=${ALLOW_SKIP:-0}
DV_ONLY=${DV_ONLY:-}
DV_BRANCH=$(git -c safe.directory='*' -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)
DV_COMMIT=$(git -c safe.directory='*' -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)
# core.fileMode=false: Git Bash reading a WSL checkout over \\wsl.localhost sees every file as mode-changed
DV_DIRTY=$(git -c safe.directory='*' -c core.fileMode=false -C "$REPO" status --porcelain -- scripts 2>/dev/null | grep -c . || true)
if [ "$DV_BRANCH" != main ] || [ "${DV_DIRTY:-0}" != 0 ]; then
  {
    echo "##########################################################################################"
    echo "## NOT THE CANONICAL HARNESS: $REPO is on '$DV_BRANCH' @ $DV_COMMIT (scripts/ dirty: ${DV_DIRTY:-?})"
    echo "## The canonical run is /home/yello/Batman on main. This report is for that branch only."
    echo "##########################################################################################"
  } >&2
fi

STAMP=$(date +%Y%m%d-%H%M%S)
DIR="$OUT/$STAMP"; mkdir -p "$DIR"
REPORT="$DIR/report.md"
NPASS=0; NFAIL=0; NSKIP=0
ROWS=()

# Liveness by ssh, not ping: `ping -c1 -W2` is Linux-only (Windows/Git-Bash ping.exe rejects the
# flags), and the suites all need ssh anyway — an ssh-up node is what they actually require (#133).
up() { timeout 8 ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR -o ConnectTimeout=5 "root@$1" true >/dev/null 2>&1; }

suite() {                       # $1 = name, $2 = why-it-matters, $3 = command ("" => skip), $4 = D if it reboots/de-meshes a node
  local name=$1 why=$2 cmd=$3 kind=${4:-} log="$DIR/$1.log" rc
  if [ -n "$DV_ONLY" ] && ! printf '%s\n' "$name" | grep -Eqx "$DV_ONLY"; then
    NSKIP=$((NSKIP+1)); ROWS+=("| $name | SKIP | not selected (DV_ONLY=$DV_ONLY) |"); echo "SKIP  $name (not selected)"; return
  fi
  if [ -z "$cmd" ]; then
    NSKIP=$((NSKIP+1)); ROWS+=("| $name | SKIP | $why |"); echo "SKIP  $name"; return
  fi
  local t0=$SECONDS
  { echo "# $(date -Is)"; echo "# $cmd"; eval "$cmd"; } > "$log" 2>&1; rc=$?
  local dt=$((SECONDS-t0))
  # "could not test here" = rc 3 AND a harness-printed SKIP-REASON line (#268 K3). rc 3 alone is NOT a skip:
  # remote tools use exit 3 themselves (verify-profile.sh UNKNOWN, batman-config-save), and swallowing that
  # as a skip would hide a real failure.
  if [ $rc -eq 3 ] && grep -q '^SKIP-REASON:' "$log"; then
    local r; r=$(grep -m1 '^SKIP-REASON:' "$log" | cut -c14-)
    NSKIP=$((NSKIP+1)); ROWS+=("| $name | SKIP | ${dt}s — could not test:$r — $why |"); echo "SKIP  $name (${dt}s):$r"
  elif [ $rc -eq 0 ]; then NPASS=$((NPASS+1)); ROWS+=("| $name | PASS | ${dt}s — $why |"); echo "PASS  $name (${dt}s)"
  else
    [ $rc -eq 3 ] && echo "FAIL rc=3 without a SKIP-REASON line — treated as a failure, not a skip" >> "$log"
    NFAIL=$((NFAIL+1)); FAILED+=("$name"); ROWS+=("| $name | **FAIL** | ${dt}s — $why |"); echo "FAIL  $name (${dt}s)"
  fi
  fleet_settle "$name" "$kind"
}
# Fleet settle (#265 v1.2 H2): see scripts/lib/fleet-settle.sh.
. "$REPO/scripts/lib/fleet-settle.sh"
FAILED=()
# N/A is NOT a skip: the suite does not apply to this node's SoC BY DESIGN (e.g. a Pi 4 bench has no
# p7 firmware partition). It is listed with its reason, but it does not fail the run the way a SKIP
# (= "should have been verified and was not") does. Only ever call it from a SoC check, and never for
# a REQUIRED capability on a misconfigured node (an OTS_NODE that is a Pi 3 is a FAIL, not N/A).
NNA=0
na() {                          # $1 = name, $2 = reason
  NNA=$((NNA+1)); ROWS+=("| $1 | N/A | $2 |"); echo "N/A   $1 — $2"
}
# The node's SoC as an OpenWrt subtarget (bcm2711 = Pi 4, bcm2710 = Pi 3), from the device tree.
# Empty = unreachable or unrecognised — callers must treat that as "run the suite" (it then fails
# loudly), never as N/A.
soc_of() {
  timeout 15 ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR -o ConnectTimeout=8 "root@$1" \
    'case "$(cat /proc/device-tree/compatible 2>/dev/null)" in *bcm2711*) echo bcm2711;; *bcm2837*) echo bcm2710;; esac' 2>/dev/null | tr -d '\r'
}

echo "=== daily validation $STAMP ==="

# 1. No hardware needed, but needs Linux tooling: the A/B card invariants build a real card on a
#    loop device. On a host without losetup/mksquashfs/sudo (e.g. a Windows/Git-Bash operator box
#    driving the fleet over ssh) it cannot run — gate it to SKIP-with-note instead of a false FAIL;
#    the test still runs for real in CI and can be run by hand under WSL/Linux.
if command -v losetup >/dev/null 2>&1 && command -v mksquashfs >/dev/null 2>&1; then
  suite ab-card-invariants \
    "the A/B card layout and cmdline invariants (#133)" \
    "$REPO/tests/ab-card-invariants.sh"
else
  suite ab-card-invariants \
    "needs loop device + squashfs-tools + sudo — not available on this host; run in CI or WSL/Linux" ""
fi

# 2b. No hardware needed: the harness's own reachability logic (#265 v1.2) — a read lost to a mesh re-forming
#     must end UNDETERMINED (never PASS), and a destructive suite must not turn the next one into a SKIP.
suite harness-265   "harness reachability: q retry/UNDETERMINED, settle, revert/held waits, fleet settle (stub ssh, #265)"   "bash $REPO/scripts/test-harness-265.sh"

# 2. No hardware needed: the MAC->IP derivation used by the first-boot hook.
suite onboarding-ip \
  "first-boot MAC->IP + DHCP-window derivation" \
  "sh $REPO/scripts/test-onboarding-ip"

# Fleet for fleet_settle (H2): every node any suite may target, as reachable now. fssh/isint are defined
# here (again below, identical) because the settle needs them from the first hardware suite on.
fssh() { timeout "${2:-60}" ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR -o ConnectTimeout=8 "root@$1" "$3"; }
isint() { case "$1" in ""|*[!0-9]*) return 1;; esac; }
fleet_init "$BENCH_NODE" "$MESH_NODE" "${OTS_NODE:-$MESH_NODE}" "${DESTRUCTIVE_NODE:-${OTS_NODE:-$MESH_NODE}}" "${DV_T263_NODE:-}"

# 3. Hardware: the A/B bench card. Refuses on its own if the target is not an A/B card.
if [ "$AB_MODE" = --skip ]; then
  suite ab-selftest "A/B boot, switch, fallback and panic recovery (#133)" ""
elif up "$BENCH_NODE"; then
  suite ab-selftest \
    "A/B boot, switch, fallback and panic recovery (#133)" \
    "$REPO/scripts/ab-selftest.sh $BENCH_NODE $AB_MODE" D
else
  suite ab-selftest "A/B boot, switch, fallback and panic recovery (#133) — BENCH_NODE $BENCH_NODE did not answer" ""
fi

# 3b. DESTRUCTIVE flash-and-go fault-injection (#159/#216): F1 bad-tar quarantine, F2 offline recovery,
# R2 first-load-latch non-gating, R1 docker-run-broken -> canary revert. Reboots/OTA-flashes the node,
# so it runs ONLY under AB_MODE=--destructive (the release gate), like ab-selftest above. On the daily
# --inspect-only run it is SKIPped (reported as loudly as a fail).
OTS_NODE=${OTS_NODE:-$MESH_NODE}          # the node carrying the OTS payload (also set below, kept identical)
OTS_SOC=$(soc_of "$OTS_NODE")
# OTS is a REQUIRED capability, so an OTS_NODE that is a Pi 3 is a misconfigured run, not "does not
# apply": FAIL it loudly (an N/A here would make every OTS regression vanish from a green run).
# One suite per case (#268 A9): a known R1 failure (#265) must not hide an F1/F2/R2 regression.
fi_desc(){ case $1 in f2) echo "lost image recovered from the offline loaded/ copy";; f1) echo "bad image tar quarantined, guardian not wedged";;
  r2) echo "first-loading tenant is non-gating (no false revert)";; r1) echo "held trial with a broken runc is refused by the pre-commit canary and reverts (#265)";;
  r3) echo "held healthy trial waits for release, then commits (#261)";;
  r4) echo "held healthy trial nobody releases is reverted at the deadline (#261)";; esac; }
fi_skip_all(){ local c; for c in f2 f1 r2 r1 r3 r4; do suite "fi-$c" "flash-and-go fault-injection $c (#159/#216) — $1" ""; done; }
if [ "$OTS_SOC" = bcm2710 ]; then
  suite ots-node-209 "OTS_NODE must be the bcm2711 OTS host" "echo 'OTS_NODE $OTS_NODE is a Pi 3 (bcm2710); OTS is not shipped there (#209 D6). Set OTS_NODE to the Pi 4 OTS host.'; false"
  fi_skip_all "OTS_NODE $OTS_NODE is bcm2710 — OTS suites not run (see ots-node-209)"
elif [ "$AB_MODE" != --destructive ]; then
  fi_skip_all "needs AB_MODE=--destructive"
elif up "$OTS_NODE"; then
  for c in f2 f1 r2 r1 r3 r4; do
    suite "fi-$c" "fault-injection $c: $(fi_desc $c) (#159/#216, DESTRUCTIVE)" "$REPO/scripts/fault-injection.sh $OTS_NODE --case $c" D
  done
else
  fi_skip_all "OTS_NODE $OTS_NODE did not answer"
fi

# #261 requires both boards: the Pi 4 is covered by fi-r3/fi-r4 on the OTS host; the Pi 3 (no tenant by
# design, #209 D6 — declared --no-tenant by the caller, never inferred) runs R3/R4 on the first bcm2710 node
# of the fleet. None in the fleet = SKIP (loud), never N/A: the requirement still stands.
H261=""; for n in "${DESTRUCTIVE_NODE:-}" "$BENCH_NODE" "$MESH_NODE"; do [ -n "$n" ] && [ "$(soc_of "$n")" = bcm2710 ] && { H261=$n; break; }; done
if [ "$AB_MODE" != --destructive ]; then
  for c in release norelease; do suite "hold-261-$c" "Pi 3 hold-commit $c (#261) — needs AB_MODE=--destructive" ""; done
elif [ -z "$H261" ]; then
  for c in release norelease; do suite "hold-261-$c" "Pi 3 hold-commit $c (#261) — no reachable bcm2710 node among DESTRUCTIVE/BENCH/MESH" ""; done
else
  suite hold-261-release "Pi 3 ($H261): held healthy trial waits for release, then commits (#261, DESTRUCTIVE)" "$REPO/scripts/fault-injection.sh $H261 --case r3 --no-tenant" D
  suite hold-261-norelease "Pi 3 ($H261): held healthy trial nobody releases is reverted at the deadline (#261, DESTRUCTIVE)" "$REPO/scripts/fault-injection.sh $H261 --case r4 --no-tenant" D
fi

# 4. Hardware: mesh health on a live node.
if up "$MESH_NODE"; then
  suite meshtest \
    "six-layer mesh health on $MESH_NODE" \
    "timeout 180 ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR -o ConnectTimeout=8 root@$MESH_NODE 'm=\$(command -v meshtest 2>/dev/null); [ -n \"\$m\" ] || m=/root/meshtest; [ -f \"\$m\" ] || m=/rom/root/meshtest; sh \"\$m\" -q'"
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
# autocommit-211 is asserted in the feature-regression section below (after chk_* are defined).

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

fssh() { timeout "${2:-60}" ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR -o ConnectTimeout=8 "root@$1" "$3"; }
isint() { case "$1" in ""|*[!0-9]*) return 1;; esac; }   # every reading is checked before it is compared (#268)

# ---- tier A: non-destructive, real ----
# #216: resolve the OTS tenant dir — flash-and-go / #167 uses /opt/batdata/apps/opentakserver;
# manually-provisioned nodes used /opt/batdata/deploy/ots. Prefer apps/, fall back to deploy/ots.
# confinement-98 inspects 9 axes x6. The wrapper exits 0 when nothing DRIFTs — also when containers were
# UNKNOWN (skipped). Right for the #156 reconciler (never alarm on what it could not judge), wrong for a
# test: six UNKNOWNs verify nothing and still exit 0 (#269). So the verdict comes from its summary line:
# all six must be OK; UNKNOWN (mid-restart / too fresh) is retried, and still UNKNOWN = not verified = FAIL.
OTS_CTR_N=6
vp_ots_verdict() {   # stdin: wrapper output -> rc 0 all OK / 1 FAIL / 2 retry (UNKNOWN present)
  local s ok dr un
  s=$(sed -n 's/^verify-profile-ots: ok=\([0-9]*\) drift=\([0-9]*\) unknown=\([0-9]*\)$/\1 \2 \3/p' | tail -1)
  read -r ok dr un <<< "$s"
  { isint "$ok" && isint "$dr" && isint "$un"; } || { echo "FAIL no verify-profile-ots summary line — confinement not verified"; return 1; }
  [ "$dr" = 0 ] || { echo "FAIL $dr container(s) DRIFT from their hardening profile"; return 1; }
  [ "$un" = 0 ] || { echo "UNKNOWN $un container(s)"; return 2; }
  [ "$ok" = "$OTS_CTR_N" ] || { echo "FAIL only $ok/$OTS_CTR_N containers judged OK"; return 1; }
  echo "ok: $ok/$OTS_CTR_N containers match their hardening profile"; }
chk_98() { local i o v rc
  for i in 1 2 3; do
    o=$(fssh "$1" 60 'd=/opt/batdata/apps/opentakserver; [ -f "$d/verify-profile-ots.sh" ] || d=/opt/batdata/deploy/ots; sh "$d/verify-profile-ots.sh"' 2>&1)
    v=$(echo "$o" | vp_ots_verdict); rc=$?
    [ "$rc" = 2 ] || break
    echo "attempt $i: $v — retrying in 20 s"; sleep 20
  done
  echo "$o"
  [ "$rc" = 2 ] && { echo "FAIL ${v#UNKNOWN } still UNKNOWN after 3 attempts — confinement not verified"; return 1; }
  echo "$v"; return "$rc"; }
chk_162() { fssh "$1" 30 '
  n=0; for c in opentakserver ots-db ots_cot_parser ots_eud_handler ots_eud_handler_ssl rabbitmq; do
    [ "$(docker inspect -f "{{.State.Running}}" "$c" 2>/dev/null)" = true ] && n=$((n+1)); done
  db=$(docker exec ots-db psql -U ots -d ots -tAc "select 1" 2>/dev/null | tr -d " ")
  echo "running=$n/6 postgres=$db"; [ "$n" = 6 ] && [ "$db" = 1 ]'; }
chk_156() { fssh "$1" 45 '
  d=/opt/batdata/apps/opentakserver; [ -f "$d/verify-profile.sh" ] || d=/opt/batdata/deploy/ots   # #216: apps/ (flash-and-go) or deploy/ots
  [ -f "$d/verify-profile.sh" ] || { echo "verify-profile.sh not found in apps/ or deploy/ots"; exit 2; }   # do not let a missing file masquerade as DRIFT
  docker rm -f dv-decoy >/dev/null 2>&1
  docker run -d --name dv-decoy --entrypoint sleep batman/ots:1.7.13-arm64 90 >/dev/null 2>&1 || { echo "FAIL decoy start failed"; exit 1; }
  # clear verify-profile MIN_UPTIME=15 (else UNKNOWN, not DRIFT). DV_TEST_156_NOWAIT=1 = negative control:
  # judge a too-fresh decoy, which must end as "not verified", never as a pass.
  [ "'"${DV_TEST_156_NOWAIT:-0}"'" = 1 ] && w=0 || w=18; sleep $w
  sh "$d/verify-profile.sh" dv-decoy "$d/ots.hardening.env" >/tmp/dv-vp 2>&1; rc=$?
  # UNKNOWN (3) = verify-profile could not judge (too fresh, inspect failed): retry once (#269)
  [ "$rc" = 3 ] && [ "$w" != 0 ] && { sleep 10; sh "$d/verify-profile.sh" dv-decoy "$d/ots.hardening.env" >/tmp/dv-vp 2>&1; rc=$?; }
  docker rm -f dv-decoy >/dev/null 2>&1
  echo "unhardened decoy -> verify-profile rc=$rc (1 = DRIFT detected; 0 OK, 2 usage, 3 UNKNOWN are failures)"
  # only DRIFT (1) proves the reconciler sees an unhardened container. `-ne 0` used to pass rc 2 and 3 (#269).
  case $rc in 1) exit 0 ;; 3) echo "FAIL decoy UNKNOWN — DRIFT detection not verified"; tail -3 /tmp/dv-vp; exit 1 ;;
    0) echo "FAIL unhardened decoy judged OK — DRIFT NOT detected"; exit 1 ;; *) echo "FAIL verify-profile rc=$rc (usage/error)"; tail -3 /tmp/dv-vp; exit 1 ;; esac'; }
chk_167g() { fssh "$1" 20 '
  # OTS runs on the GENERIC payload manager (#167), not the bespoke run.sh/batman-ots: the generic
  # guardian owns it, the old guardian is gone (double-guardian regression), and drift reads OK.
  command -v payload-run >/dev/null 2>&1 || { echo "payload-run not installed (pre-image-bake #159)"; exit 1; }
  [ -x /etc/init.d/batman-payload-opentakserver ] || { echo "generic guardian init missing"; exit 1; }
  [ -e /etc/init.d/batman-ots ] && { echo "old batman-ots still present -> double-guardian risk"; exit 1; }
  st=$(sed -n "s/.*\"status\":\"\([A-Z]*\)\".*/\1/p" /tmp/batman-payload-opentakserver-drift.json 2>/dev/null | head -1)
  echo "generic guardian drift=$st (old batman-ots absent)"; [ "$st" = OK ]'; }
chk_167a() { fssh "$1" 20 '
  # white-box: the port/zone arbiter REFUSES a colliding tenant (host-port clash) with exit 3.
  command -v payload-arbiter >/dev/null 2>&1 || { echo "payload-arbiter not installed (pre-image-bake #159)"; exit 1; }
  T=$(mktemp -d); mkdir -p "$T/ots" "$T/dup"
  printf "TENANT=opentakserver\nPORTS=8088 8089 8443\nSUBNET=172.20.0.0/24\nZONE=dockert\nBRIDGE=br-ots\n" > "$T/ots/ots.net.alloc"
  printf "TENANT=dup\nPORTS=8088\nSUBNET=172.20.9.0/24\nZONE=dupz\nBRIDGE=br-dup\n" > "$T/dup/dup.net.alloc"
  payload-arbiter "$T/dup/dup.net.alloc" "$T" >/tmp/dv-arb 2>&1; rc=$?
  rm -rf "$T"
  echo "colliding tenant (:8088) -> arbiter rc=$rc (want 3=REFUSED)"; [ "$rc" = 3 ]'; }
chk_golden() { fssh "$1" 30 '                                  # payload-config-golden.md
  # For each baked golden tenant that is PROVISIONED on this node: (1) p6 config == baked golden per
  # file, (2) every live container has RestartPolicy unless-stopped (the real outcome the design drives;
  # tautology-free unlike the cmp alone — review m2), (3) every IMAGE the manifest references is loaded
  # (else a refreshed manifest would crash-loop the guardian — review M2). No golden / no tenant = PASS.
  GD=/usr/share/batman/payload-golden
  [ -d "$GD" ] || { echo "no golden baked (non-payloadhost image) — nothing to check"; exit 0; }
  rc=0; checked=0
  for g in "$GD"/*/ ; do
    [ -d "$g" ] || continue
    t=${g%/}; t=${t##*/}; dst=/opt/batdata/apps/$t
    ls "$dst"/*.manifest >/dev/null 2>&1 || continue          # not provisioned here -> skip tenant
    checked=1; man=$(ls "$dst"/*.manifest | head -1)
    for f in "$g"*; do [ -f "$f" ] || continue; b=${f##*/}; [ "$b" = secrets ] && continue
      cmp -s "$f" "$dst/$b" 2>/dev/null || { echo "DRIFT $t/$b: p6 != baked golden"; rc=1; }; done
    for c in $(awk "/^CONTAINER /{print \$2}" "$man"); do
      rp=$(docker inspect -f "{{.HostConfig.RestartPolicy.Name}}" "$c" 2>/dev/null)
      [ "$rp" = unless-stopped ] || { echo "$t/$c restart=${rp:-MISSING} (want unless-stopped)"; rc=1; }; done
    for img in $(awk "/^IMAGE /{print \$2}" "$man"); do
      docker image inspect "$img" >/dev/null 2>&1 || { echo "$t manifest references image $img — NOT loaded on p6"; rc=1; }; done
  done
  [ "$checked" = 1 ] || echo "no provisioned tenant on this node — nothing to check"
  echo "golden-config rc=$rc"; [ "$rc" = 0 ]'; }
chk_conform() { fssh "$1" 90 '                                  # #274 payload-conform
  # The LIVE containers are what the manifest says, not just the files on p6 (chk_golden): every container
  # running, not restart-looping, labelled batman.cfg == payload-run --cfg-hash and batman.tenant == the
  # tenant (after an OTA dockerd revives the OLD containers unless the guardian converged them); every
  # MOUNT present with the right source and RO/RW, source a regular file; no container labelled for the
  # tenant outside its manifest (orphan).
  rc=0; checked=0
  for d in /opt/batdata/apps/*/; do
    man=$(ls "$d"*.manifest 2>/dev/null | head -1); [ -n "$man" ] || continue
    t=${d%/}; t=${t##*/}; checked=1
    want=$(payload-run --cfg-hash "$t" 2>/dev/null); [ -n "$want" ] || { echo "FAIL $t: payload-run --cfg-hash gave nothing"; rc=1; }
    names=$(awk "/^CONTAINER /{print \$2}" "$man" | tr "\n" " "); c=""
    while read -r k v; do
      case "$k" in
        CONTAINER) c=$v
          s=$(docker inspect -f "{{.State.Status}} {{.State.Restarting}} {{index .Config.Labels \"batman.cfg\"}} {{index .Config.Labels \"batman.tenant\"}}" "$c" 2>/dev/null)
          [ "$s" = "running false $want $t" ] || { echo "FAIL $t/$c [status restarting cfg tenant]=[$s] want [running false $want $t]"; rc=1; } ;;
        MOUNT) src=${v%%:*}; r=${v#*:}; dst=${r%%:*}; rw=true; case "$v" in *:ro) rw=false ;; esac
          case "$src" in /*) ;; *) src="$d$src"; [ -f "$src" ] || { echo "FAIL $t/$c mount source $src is not a regular file"; rc=1; } ;; esac
          m=$(docker inspect -f "{{range .Mounts}}{{if eq .Destination \"$dst\"}}{{.Source}} {{.RW}}{{end}}{{end}}" "$c" 2>/dev/null)
          [ "$m" = "$src $rw" ] || { echo "FAIL $t/$c mount $dst = [$m] want [$src $rw]"; rc=1; } ;;
      esac
    done < "$man"
    for o in $(docker ps -a --filter "label=batman.tenant=$t" --format "{{.Names}}" 2>/dev/null); do
      case " $names " in *" $o "*) ;; *) echo "FAIL $t: orphan container $o (labelled for the tenant, not in its manifest)"; rc=1 ;; esac
    done
    echo "$t: containers [$names] checked, cfg $(echo "$want" | cut -c1-12)"
  done
  [ "$checked" = 1 ] || echo "no provisioned tenant on this node — nothing to check"
  echo "payload-conform rc=$rc"; [ "$rc" = 0 ]'; }
chk_tput() { fssh "$1" 170 '                                   # sustained-ish mesh throughput
  # A single batctl tp is jittery (seen 0.5-6 Mbps); take the MEDIAN of N runs so a real regression
  # (dead link / MCS collapse) is caught without false-failing on jitter. Baseline = soak-30min-4mhz
  # (docs/data): mean 9.30 / median 9.44 Mbps. Reports median/min/max for trend; PASS if median >= floor.
  mac=$(batctl n 2>/dev/null | grep -E "[0-9]+\.[0-9]+s" | awk "{print \$1}" | head -1)
  [ -n "$mac" ] || { echo "no mesh peer to measure throughput to"; exit 1; }
  N=7; i=0; vals=""
  while [ "$i" -lt "$N" ]; do
    k=$(batctl tp "$mac" 2>/dev/null | sed -n "s/.*(\([0-9]*\)\.[0-9]* Kbps).*/\1/p" | head -1)
    [ -n "$k" ] && vals="$vals $k"; i=$((i+1))
  done
  # shellcheck disable=SC2046,SC2086
  set -- $(printf "%s\n" $vals | sort -n); n=$#
  [ "$n" -ge 3 ] || { echo "only $n throughput samples (need >=3) — link flaky/down"; exit 1; }
  eval med=\${$(( (n+1)/2 ))}; min=$1; eval max=\${$n}
  echo "tput to $mac: median=${med} min=${min} max=${max} Kbps over $n runs (baseline soak median ~9440 Kbps)"
  FLOOR=${TPUT_FLOOR_KBPS:-3000}
  [ "$med" -ge "$FLOOR" ]'; }
# iperf TCP throughput — the REAL IP-layer payload over the mesh. batctl tp (chk_tput) is the
# batman-adv internal meter and systematically under-reports ~15%; iperf is what an app actually
# gets and it matches the soak baseline (~9.3-9.4 Mbps single-direction). Needs a sink on the peer,
# so unlike the fssh-on-one-node checks this orchestrates BOTH nodes from the host.
#
# Path integrity (do NOT trust the caller to point at a mesh peer): a HaLow link physically cannot
# exceed ~15 Mbps (4MHz soak max 11.3; 8MHz ~2x), whereas an eth/mgmt path is 100-1000 Mbps. So we
# assert a BAND [floor..ceil]: a result ABOVE ceil means the traffic did not cross HaLow (wrong
# IPERF_PEER / shared eth switch) and is a FAIL, not a fake mesh PASS. IPERF_PEER has no default so
# the suite never silently measures the wrong node (unset => SKIP at the call site).
# iperf2 auto-scales its unit (Kbits/Mbits/Gbits), so force Kbits/sec (-f k) and parse that — a
# sub-1-Mbps degraded link would otherwise print "Kbits/sec", miss a Mbits grep, and mis-FAIL as
# "no result". The sink is tracked by a pid-file (never pkill -f a pattern — it self-matches our own
# shell, a trap that hung an earlier wait loop) and every kill is guarded by /proc/PID identity.
# $1 = client (measured) node, $2 = peer/sink node reached over the mesh.
chk_iperf() {
  # Dedicated port, deliberately NOT iperf's 5001 (v2) / 5201 (v3) defaults: those collide with any
  # ad-hoc `iperf -s` an operator runs (e.g. a soak) and leave the port in TIME_WAIT, which the bind
  # check below would then (correctly) flag as a failure. 5399 is ours.
  local cli=$1 srv=$2 port=${IPERF_PORT:-5399} dur=${IPERF_SECS:-10}
  local floor=${IPERF_FLOOR_KBPS:-4000} ceil=${IPERF_CEIL_KBPS:-30000}
  fssh "$cli" 8 'command -v iperf >/dev/null 2>&1' || { echo "iperf missing on client $cli"; return 1; }
  fssh "$srv" 8 'command -v iperf >/dev/null 2>&1' || { echo "iperf missing on sink $srv";   return 1; }
  # (re)start a dedicated sink; kill any prior one only if that pid is still an iperf (PID-reuse guard)
  # detach with setsid, NOT nohup — busybox ash on the nodes has no nohup. The pid is captured INSIDE
  # the new session (echo \$\$ then exec) so it is iperf's real pid whether or not busybox setsid forks.
  fssh "$srv" 12 "p=\$(cat /tmp/dv-iperf-s.pid 2>/dev/null); [ -n \"\$p\" ] && grep -qs iperf \"/proc/\$p/cmdline\" && kill \"\$p\" 2>/dev/null; setsid sh -c 'echo \$\$ >/tmp/dv-iperf-s.pid; exec iperf -s -p $port -f k' >/tmp/dv-iperf-s.log 2>&1 </dev/null & sleep 1"
  # confirm the sink actually bound — iperf -s exits immediately if the port is already in use
  fssh "$srv" 8 "p=\$(cat /tmp/dv-iperf-s.pid 2>/dev/null); kill -0 \"\$p\" 2>/dev/null" \
    || { echo "iperf sink failed to start on $srv (port $port busy?)"; fssh "$srv" 8 'rm -f /tmp/dv-iperf-s.pid /tmp/dv-iperf-s.log' 2>/dev/null; return 1; }
  local kbps
  kbps=$(fssh "$cli" $((dur+25)) "iperf -c $srv -p $port -f k -t $dur 2>/dev/null | awk '/Kbits\/sec/{v=\$(NF-1)} END{printf \"%d\", v}'")
  fssh "$srv" 10 "p=\$(cat /tmp/dv-iperf-s.pid 2>/dev/null); [ -n \"\$p\" ] && grep -qs iperf \"/proc/\$p/cmdline\" && kill \"\$p\" 2>/dev/null; rm -f /tmp/dv-iperf-s.pid /tmp/dv-iperf-s.log"
  [ -n "$kbps" ] && [ "$kbps" -gt 0 ] || { echo "no iperf result — sink/link down or connection refused"; return 1; }
  echo "iperf TCP $cli -> $srv: ${kbps} Kbits/sec over ${dur}s [band ${floor}..${ceil} Kbps; mesh single-dir baseline ~9300]"
  [ "$kbps" -le "$ceil" ] || { echo "ABOVE CEILING — traffic did NOT cross HaLow (wrong IPERF_PEER / eth path)"; return 1; }
  [ "$kbps" -ge "$floor" ]
}
chk_socgate_209() { fssh "$1" 12 '                              # #209 review
  # The SoC gate must exist AND classify. The bug this guards against is a check that does not
  # check: before #209 the board comparison lived in platform_do_upgrade (after sysupgrade had
  # already accepted the image), only echoed "WARN", and carried a `*bcm2711*` wildcard that
  # matched every bcm2711 image on every board. On a mixed bcm2710/bcm2711 fleet that is the
  # highest-probability brick path, and no runtime symptom would ever reveal its absence.
  # White-box on purpose: source the installed override and exercise the classifier directly.
  [ -f /lib/upgrade/platform.sh ] || { echo "no /lib/upgrade/platform.sh"; exit 1; }
  grep -q "REFUSING: image is for" /lib/upgrade/platform.sh || { echo "SoC gate missing from platform.sh (#209 regression)"; exit 1; }
  grep -q "platform_check_image" /lib/upgrade/platform.sh || { echo "no platform_check_image"; exit 1; }
  # The gate must be reachable from stage 1 (platform_check_image), not back in platform_do_upgrade.
  # Since #209 S5 the check_image override factors the classifier into _ab_check_image() and
  # platform_check_image() DELEGATES to it (so -F/do_stage2 can reuse the same fail-closed gate), so
  # accept either the REFUSING line directly in platform_check_image OR a delegation to _ab_check_image
  # whose body carries the gate.
  awk "
    /^[a-zA-Z_][a-zA-Z0-9_]*\(\)/{fn=\$0}
    fn ~ /^platform_check_image/ && /_ab_check_image/{deleg=1}
    fn ~ /^platform_check_image/ && /REFUSING: image is for/{inpc=1}
    fn ~ /^_ab_check_image/ && /REFUSING: image is for/{inab=1}
    END{ exit !(inpc || (deleg && inab)) }" /lib/upgrade/platform.sh \
    || { echo "SoC gate not reachable from platform_check_image (neither inline nor via _ab_check_image) — it cannot refuse at stage 1"; exit 1; }
  . /lib/upgrade/platform.sh 2>/dev/null || true
  command -v soc_token >/dev/null 2>&1 || { echo "soc_token not defined"; exit 1; }
  [ "$(soc_token bcm27xx/bcm2711)" = bcm2711 ] || { echo "soc_token misreads bcm2711"; exit 1; }
  [ "$(soc_token bcm27xx/bcm2710)" = bcm2710 ] || { echo "soc_token misreads bcm2710"; exit 1; }
  [ -z "$(soc_token something-else)" ]         || { echo "soc_token invents a token"; exit 1; }
  echo "SoC gate present in platform_check_image and classifying"'; }
chk_slotverify_209() { fssh "$1" 30 '                          # #209 S5: card sanity, both layouts
  # The same read-only sanity every slot op runs first: layout matches the SoC, FAT count, the Pi 3
  # hybrid MBR (1=p7 2=bootA 3=bootB 4=ee), firmware-booted partition agrees with the cmdline. A
  # drift here makes the NEXT OTA refuse (or, without the check, mis-aim) — catch it on a quiet day.
  l=$(batman-slot layout 2>&1); s=$(case "$(cat /proc/device-tree/compatible)" in *bcm2711*) echo bcm2711;; *bcm2837*) echo bcm2710;; esac)
  echo "layout=$l soc=$s"
  case "$l:$s" in pi4:bcm2711|pi3:bcm2710) ;; *) echo "layout/SoC mismatch"; exit 1 ;; esac
  batman-slot verify'; }
chk_memcg_209() { fssh "$1" 12 '                               # #209 D6: docker needs memcg on both SoCs
  # bcm2710 DTBs ship cgroup_disable=memory (fixed by the 999-batman-enable-memcg-pi3 patch); losing
  # it silently breaks every container memory limit and the autocommit canary gate.
  c=$(cat /sys/fs/cgroup/cgroup.controllers 2>/dev/null)
  echo "cgroup2 controllers: ${c:-none}  cmdline cgroup_disable: $(grep -o "cgroup_disable=[a-z]*" /proc/cmdline || echo none)"
  echo " $c " | grep -q " memory "'; }
chk_slotintegrity_209() { fssh "$1" 20 '                       # #209 S5: Pi 4 EEPROM boots the wrong slot
  # The Pi 4 bootloader (EEPROM 2026-09-23) may read raw PM_RSTS as the reboot partition after a
  # partition-0 restart and walk to p1 (docs/design/explicit-reboot.md). The node must have the tool and
  # the K90 hook for explicit restarts, must not be running on a wrongly-booted slot now, must not be
  # stuck in correcting restarts, and both slots must carry the boot-time self-check.
  case "$(cat /proc/device-tree/compatible 2>/dev/null)" in *bcm2711*) ;; *) echo "Pi 3: no EEPROM bootloader, the bug is Pi 4 only — n/a"; exit 0 ;; esac
  [ -x /usr/sbin/batman-reboot ] || { echo "batman-reboot missing"; exit 1; }
  [ -e /etc/rc.d/K90batman-reboot ] || { echo "K90batman-reboot hook not enabled"; exit 1; }
  [ -f /tmp/batman-fw-override ] && { echo "the firmware booted the WRONG slot this boot: $(cat /tmp/batman-fw-override)"; exit 1; }
  tail -n 20 /opt/batdata/log/autocommit.log 2>/dev/null | grep -q "FW-OVERRIDE-STUCK" && { echo "recent FW-OVERRIDE-STUCK in autocommit.log"; exit 1; }
  a=/opt/batdata/state/slot-A.protected; b=/opt/batdata/state/slot-B.protected
  [ -f "$a" ] && [ -f "$b" ] || { echo "only partly protected (A:$(cat "$a" 2>/dev/null || echo -) B:$(cat "$b" 2>/dev/null || echo -)) — sysupgrade the same image once more"; exit 1; }
  w=$(grep -c " BOOT FW-OVERRIDE to=" /opt/batdata/log/ota-trace.log 2>/dev/null)
  echo "tool + hook present, on the committed slot, both slots protected; ${w:-0} correcting restart(s) in the trace"'; }
chk_otatrace_209() { fssh "$1" 15 '                            # #209 S5: OTA flight recorder
  # Every OTA must leave a complete stage-2 chain on p6 (S2 BEGIN ... S2 END rc=…), and every boot a
  # BOOT line of firmware facts — the evidence an OTA failure is diagnosed from (docs/design/ota-trace.md).
  f=/opt/batdata/log/ota-trace.log
  [ -f /usr/lib/batman/otatrace.sh ] || { echo "otatrace.sh missing from this rootfs"; exit 1; }
  grep -q " BOOT " "$f" 2>/dev/null || { echo "no BOOT line in $f (recorder not running at boot?)"; exit 1; }
  b=$(grep " S2 BEGIN " "$f" | tail -n 1 | sed -n "s/.* boot=\([^ ]*\) .*/\1/p")
  [ -n "$b" ] || { echo "recorder present, BOOT lines ok; no OTA recorded on p6 yet"; exit 0; }
  e=$(grep " boot=$b .* S2 END " "$f" | tail -n 1)
  [ -n "$e" ] || { echo "last OTA (stage-2 boot $b) has S2 BEGIN but no S2 END — stage 2 died or its trace was lost"; exit 1; }
  echo "last OTA (stage-2 boot $b): S2 END ${e#* S2 END }"'; }
chk_trybootget_209() { fssh "$1" 12 '                          # #209 v4.3 D5: tryboot GET read-back
  # batman-slot apply refuses on a pi3 unless the firmware answers the tryboot GET; on a normal
  # (committed, non-trial) boot the one-shot flag must read 0 — a 1 means the next reboot trials a slot.
  r=$(vcmailbox 0x00030064 4 4 0 2>/dev/null); set -- $r
  echo "tryboot GET: ${r:-no answer}"
  # Both SoCs must answer: batman-slot only WARNs on a silent Pi 4 firmware (armed blind) — that is a
  # degraded OTA, so the daily run flags it, with a SoC-specific message.
  if [ "${2:-}" != 0x80000000 ]; then
    case "$(cat /proc/device-tree/compatible)" in
      *bcm2837*) echo "Pi 3 firmware does not answer the tryboot GET — batman-slot apply will REFUSE every OTA" ;;
      *) echo "Pi 4 firmware does not answer the tryboot GET — batman-slot arms tryboot blind (warn-only)" ;;
    esac; exit 1
  fi
  [ "$(( ${6:-1} ))" -eq 0 ] || { echo "tryboot flag is ARMED on a normal boot — the next reboot will trial the other slot"; exit 1; }'; }
chk_p7_209() { fssh "$1" 20 '                                  # #209 v4.3 D3/D4: Pi 3 firmware partition
  m=/mnt/dv-p7; mkdir -p $m; mount -t vfat -o ro /dev/mmcblk0p7 $m 2>/dev/null || { echo "cannot mount p7"; exit 1; }
  h=$(sha256sum $m/bootcode.bin 2>/dev/null | cut -d" " -f1); rc=0
  grep -q "^$h  bootcode.bin$" /usr/share/batman/firmware-allowlist-bcm2710.sha256 2>/dev/null && echo "bootcode.bin allow-listed" || { echo "bootcode.bin $h NOT on the allow-list"; rc=1; }
  [ -f $m/config.txt ] && echo "config.txt present" || { echo "config.txt MISSING — the board will not boot (E0g)"; rc=1; }
  grep -q "^tryboot_a_b=1" $m/autoboot.txt 2>/dev/null && echo "autoboot.txt tryboot_a_b=1" || { echo "autoboot.txt bad/missing"; rc=1; }
  umount $m; rmdir $m 2>/dev/null; exit $rc'; }
chk_eeprom_209() {                                             # #209 S5: Pi 4 bootloader floor
  # Below 2025-08-20 the EEPROM cannot fall back from a slot that fails at the firmware level (a FAT
  # boot slot without a valid start4.elf): the trial hangs until someone pulls power (manet02,
  # 2023-01-11, 2026-10-02). Every Pi 4 the run can see must be at or above the floor.
  local n ts v rc=0 seen=0
  for n in "$@"; do
    [ "$(soc_of "$n")" = bcm2711 ] || continue
    seen=1
    ts=$(fssh "$n" 12 'vcgencmd bootloader_version | sed -n "s/^timestamp //p"' | tr -d '\r')
    v=$(fssh "$n" 12 'vcgencmd bootloader_version | head -1' | tr -d '\r')
    if ! [[ $ts =~ ^[0-9]+$ ]]; then echo "$n: bootloader version unreadable"; rc=1
    elif [ "$ts" -lt 1755648000 ]; then echo "$n: bootloader $v < 2025-08-20 — NO firmware-level A/B fallback; update the EEPROM"; rc=1
    else echo "$n: bootloader $v ok"; fi
  done
  [ "$seen" = 1 ] || { echo "no reachable Pi 4 among: $*"; return 1; }
  return $rc; }
chk_autocommit() { fssh "$1" 12 '                              # ab-autocommit.md / #211
  # A completed reflash must not leave the node in an uncommitted trial (a reboot would then revert to
  # the old slot). batman-autocommit health-gates + commits; assert the node ended committed.
  # #261: an armed hold-commit flag during a validation run is stray (no OTA is pending — an operator arms
  # it right before one): it would hold, then revert, the next OTA of that build. FAIL (review #265 F10).
  [ -f /opt/batdata/state/autocommit-hold-commit ] && { echo "FAIL hold-commit ARMED on p6 for [$(head -c 120 /opt/batdata/state/autocommit-hold-commit)] — stray flag"; exit 1; }
  batman-slot is-trial; rc=$?
  case $rc in
    1) echo "committed (not a stuck trial)"; exit 0 ;;
    0) echo "UNCOMMITTED TRIAL — autocommit did not commit (reboot would revert)"; exit 1 ;;
    *) echo "cannot determine slot commit state (rc=$rc)"; exit 1 ;;
  esac'; }
chk_meshjoin_209() { fssh "$1" 20 '                    # ab-autocommit v2.2 N10 / #209 S4-5
  # The OTA commit gate requires meshjoin_reachable on any node expected in a mesh. If a future image
  # renames wlh0/br-ahwlan/dropbear this would fail on EVERY trial and silently turn all OTAs into
  # reverts — so assert it on a committed, joined node first.
  [ -f /usr/lib/batman/meshjoin.sh ] || { echo "no /usr/lib/batman/meshjoin.sh (pre-v2.2 image)"; exit 1; }
  . /usr/lib/batman/meshjoin.sh; meshjoin_sample
  echo "plink=$MJ_PLINK batman(wlh0)=$MJ_BAT sta=$MJ_STA expected=$( [ -f /opt/batdata/state/mesh-joined ] || [ -f /opt/batdata/state/mesh-expected ] && echo yes || echo no)"
  meshjoin_reachable || { echo "meshjoin_reachable FAILS on a joined node — every OTA would revert"; exit 1; }
  echo "reachable"'; }
chk_batver_247() { local n rc=0; for n in "$@"; do echo "== $n"; fssh "$n" 20 '   # #247, every reachable node
  # The mesh core must be the routing openwrt-24.10 line (batman-adv 2024.3 + 101 backports, PKG_RELEASE
  # >= 13; routing master ships 2024.3-r7 with 11), the LOADED module must be the INSTALLED one, batctl
  # must agree, and network coding must be compiled out (OpenMANET uci sets network_coding=1 and the
  # 24.10 proto script applies it). A pre-#247 image (OpenMANET 2025.4) fails here on purpose.
  m=$(cat /sys/module/batman_adv/version 2>/dev/null)
  v=$(batctl -v 2>/dev/null | head -1)
  k=$(opkg list-installed kmod-batman-adv 2>/dev/null | sed -n "s/^kmod-batman-adv - //p")
  echo "module=$m  batctl=[$v]  opkg kmod=$k"
  case "$m" in 2024.3-openwrt-*) r=${m#2024.3-openwrt-} ;; *) echo "module $m is not the 24.10 2024.3 line (pre-#247 image?)"; exit 1 ;; esac
  [ "$r" -ge 13 ] 2>/dev/null || { echo "2024.3 release $r < 13 (routing master line, not openwrt-24.10)"; exit 1; }
  case "$k" in *.2024.3-r"$r") ;; *) echo "loaded module $m != installed package $k"; exit 1 ;; esac
  case "$v" in *"[batman-adv: $m]"*) ;; *) echo "batctl sees a different kmod: $v"; exit 1 ;; esac
  case "$v" in "batctl 2024.3-openwrt-"*) ;; *) echo "batctl userspace is not 2024.3: $v"; exit 1 ;; esac
  if batctl meshif bat0 nc >/dev/null 2>&1; then echo "batctl nc answers — network coding compiled in"; exit 1; fi
  batctl mj 2>/dev/null | grep -q network_coding_enabled && { echo "mj JSON carries network_coding_enabled"; exit 1; }
  echo "ok: 24.10 line r$r, loaded == installed, batctl agrees, NC compiled out"' || rc=1; done; return $rc; }
chk_go_252() { local n rc=0; for n in "$@"; do echo "== $n"; fssh "$n" 20 '   # #252, every reachable node
  # One Go for every Go program in the image. Up to 1.5.2 the container stack (docker/dockerd/containerd/
  # runc) was silently built by the build host system go 1.22.2 (EOL) while openmanetd used the tree go
  # 1.26 — so: all must report the SAME go, and it must be >= go1.23. Reads the version string the Go
  # linker embeds (first go1.x.y in the binary). A pre-#252 image fails on purpose.
  ref=""; bad=0
  for f in /usr/bin/openmanetd /usr/bin/dockerd /usr/bin/docker /usr/bin/containerd /usr/sbin/runc; do
    [ -x "$f" ] || { echo "$f missing"; bad=1; continue; }
    v=$(strings "$f" 2>/dev/null | grep -m1 -oE "go1\.[0-9]+\.[0-9]+")
    echo "$f $v"
    [ -n "$v" ] || { echo "  no Go version found in $f"; bad=1; continue; }
    [ -n "$ref" ] || ref=$v
    [ "$v" = "$ref" ] || { echo "  $f built by $v, openmanetd by $ref — mixed toolchains"; bad=1; }
    m=$(echo "$v" | cut -d. -f2); [ "$m" -ge 23 ] 2>/dev/null || { echo "  $f built by $v (< go1.23, EOL)"; bad=1; }
  done
  [ "$bad" = 0 ] && echo "ok: one toolchain $ref"' || rc=1; done; return $rc; }
chk_halow_263() { local n rc=0; for n in "$@"; do echo "== $n"; fssh "$n" 20 '   # #263, every reachable node
  # The shipped mm6108 driver carries the command-ownership fix (mm6108-driver patch 023): before it, a command
  # that timed out while the TX path held its skb corrupted the command queue counters and the next timeout
  # unlinked a freed skb (Oops, write to 0x8; 3 fleet panics). Black-box: the loaded driver exposes the fix
  # counter cmd_timeout_in_flight (a pre-fix image fails here on purpose), and this boot has no refused unlink
  # (the patch WARNs instead of corrupting), no fault-injection residue, no Oops/BUG. The counter > 0 means the
  # race HAPPENED and was survived — reported, not failed. The race itself: halow-fi-263 (destructive tier).
  P=/sys/module/mm6108_sdio/parameters
  [ -d $P ] || { echo "FAIL mm6108_sdio not loaded"; exit 1; }
  [ -f $P/cmd_timeout_in_flight ] || { echo "FAIL loaded mm6108 driver lacks the #263 fix (no cmd_timeout_in_flight)"; exit 1; }
  [ -f $P/fi263_put_delay_ms ] && { echo "FAIL a fault-injection DEBUG driver is loaded (fi263 knobs) — never on a normal boot"; exit 1; }
  echo "cmd_timeout_in_flight=$(cat $P/cmd_timeout_in_flight)  late responses this boot=$(dmesg | grep -c "Late response")  SPI timeouts=$(dmesg | grep -c "SPI transfer timed out")"
  b=$(dmesg | grep -E "not on this queue|Unable to handle kernel|Internal error: Oops|BUG: |FI263")
  [ -z "$b" ] || { echo "$b" | head -5 | sed "s/^/FAIL dmesg: /"; exit 1; }
  echo "no refused unlink / Oops / BUG this boot"' || rc=1; done; return $rc; }

# #263 destructive: drive the race on purpose with the fault-injection build of THIS image's driver and require
# the patched driver to survive it (scripts/node/halow-fi-263.sh). $1 node, $2 local .ko. The node leaves the
# mesh and reboots; judged afterwards from its log + boot reason. With the STOCK debug module it is the
# negative control: the node panics on the first case and this FAILs.
bchk_fi_263() { local n=$1 ko=$2 b0 b1 t l kv nv rc=0
  [ -f "$ko" ] || { echo "SKIP-REASON: DV_T263_KO '$ko' does not exist"; return 3; }
  up "$n" || { echo "SKIP-REASON: DV_T263_NODE $n did not answer"; return 3; }
  kv=$(grep -a -o -m1 'vermagic=[^ ]*' "$ko" | cut -d= -f2); nv=$(fssh "$n" 8 'uname -r' | tr -d ' \r')
  [ -n "$kv" ] && [ "$kv" = "$nv" ] || { echo "FAIL module vermagic [$kv] != node kernel [$nv] — build the FI module for the image this node runs"; return 1; }
  grep -aq fi263_put_delay_ms "$ko" || { echo "FAIL $ko is not a fault-injection build (no fi263 knobs)"; return 1; }
  grep -aq cmd_timeout_in_flight "$ko" && echo "module: patched (023) + FI" || echo "module: STOCK + FI — NEGATIVE CONTROL, the node is expected to panic"
  scp -q -o BatchMode=yes -o LogLevel=ERROR "$ko" "root@$n:/tmp/mm6108_sdio-dvfi.ko" && \
  scp -q -o BatchMode=yes -o LogLevel=ERROR "$REPO/scripts/node/halow-fi-263.sh" "root@$n:/tmp/halow-fi-263.sh" || { echo "FAIL could not stage the module/script on $n"; return 1; }
  b0=$(bootid "$n"); [ -n "$b0" ] || { echo "FAIL boot_id unreadable — not verified"; return 1; }
  fssh "$n" 10 'setsid sh /tmp/halow-fi-263.sh </dev/null >/dev/null 2>&1 & echo launched' || { echo "FAIL could not launch"; return 1; }
  echo "launched on $n (boot $b0); waiting for its reboot"
  for t in $(seq 1 90); do sleep 10; b1=$(bootid "$n"); [ -n "$b1" ] && [ "$b1" != "$b0" ] && break; done
  [ -n "$b1" ] && [ "$b1" != "$b0" ] || { echo "FAIL $n did not reboot within 15 min — check it by hand"; return 1; }
  sleep 20
  l=$(fssh "$n" 15 'f=$(ls -t /opt/batdata/halow-fi-263-*.log 2>/dev/null | grep -v dmesg | head -1); cat "$f"; echo "PREV: $(grep " BOOT " /opt/batdata/log/ota-trace.log | tail -1 | sed "s/.*prev=//" | cut -c1-80)"')
  echo "$l"
  case "$(echo "$l" | sed -n 's/^PREV: //p')" in PANIC*) echo "FAIL the node PANICKED during the injection (the #263 race is not survived)"; rc=1 ;; esac
  echo "$l" | grep -q "START boot=$b0" || { echo "FAIL no result log for this run — not verified"; return 1; }
  echo "$l" | grep -qE "QLEN|WARNING: CPU|Oops|Unable to handle|not on this queue" && { echo "FAIL WARN/Oops during the injection"; rc=1; }
  echo "$l" | grep -q "case4-5:" || { echo "FAIL the run did not reach case 4"; rc=1; }
  echo "$l" | grep -q "case2: morse_cli stats rc=0" || { echo "FAIL case 2: a response to a command the host dropped after writing was not delivered"; rc=1; }
  echo "$l" | grep -q "case3: morse_cli stats rc=0" || { echo "FAIL case 3: a 300 ms stall turned the live response into a late one"; rc=1; }
  echo "$l" | grep -q "normal stats after injection: 20/20 ok" || { echo "FAIL commands did not all work after the injection"; rc=1; }
  [ "$rc" = 0 ] && echo "ok the patched driver survived every injected case; node rebooted back to the shipped driver"
  return $rc; }

chk_runc_247() { local n rc=0; for n in "$@"; do echo "== $n"; fssh "$n" 20 '   # #247-2, every reachable node
  # runc <= 1.2.7 / <= 1.3.2 is hit by CVE-2025-31133 / -52565 / -52881 (high: container escape) and
  # <= 1.3.5 by CVE-2026-41579; the image ships 1.3.6. Also: the overlayfs /proc/self/exe seal must be
  # the path runc takes here (a fallback copies the ~12 MB binary into the container memcg on every
  # run/exec). A pre-#247-2 image (runc 1.1.14) fails on purpose.
  v=$(runc --version 2>/dev/null | sed -n "s/^runc version //p" | head -1)
  echo "runc $v"
  [ -n "$v" ] || { echo "no runc"; exit 1; }
  ok=$(echo "$v" | awk -F. "{ if (\$1>1 || (\$1==1 && \$2>3) || (\$1==1 && \$2==3 && \$3>=6)) print 1; else print 0 }")
  [ "$ok" = 1 ] || { echo "runc $v < 1.3.6 (container-escape CVEs)"; exit 1; }
  d=/tmp/dv-runc247; rm -rf $d; mkdir -p $d/rootfs/bin $d/rootfs/lib
  cp /bin/busybox $d/rootfs/bin/; cp -P /lib/ld-musl-*.so.1 $d/rootfs/lib/; cp /lib/libc.so $d/rootfs/lib/
  ( cd $d && runc spec >/dev/null 2>&1 && sed -i "s/\"terminal\": true/\"terminal\": false/; s/\"sh\"/\"\\/bin\\/busybox\",\"true\"/" config.json )
  o=$(cd $d && runc --debug run dv-runc247 </dev/null 2>&1); runc delete -f dv-runc247 >/dev/null 2>&1; rm -rf $d
  case "$o" in *"using overlayfs for sealed /proc/self/exe"*) echo "ok: runc $v, exe sealed via overlayfs" ;; *"could not use overlayfs"*) echo "exeseal fell back to copying the runc binary"; exit 1 ;; *) echo "no exeseal message from runc --debug run: $(echo "$o" | tail -2)"; exit 1 ;; esac' || rc=1; done; return $rc; }
# #263 M0: joinwatch runs `batman-config-save --on-join` every ~15 s while a node is open; before the fix each
# call mounted p5 rw (215 mounts/hour on 03, coinciding with the SPI stalls in the #263 crash logs). On every
# reachable node, count p5 mounts (ext4 superblock s_mnt_count, read without mounting) over 90 s: a joined node
# must not mount p5 at all. All nodes are sampled in the same window.
chk_p5churn_263() { local n a b rc=0 tested=0; declare -A A
  for n in "$@"; do A[$n]=$(fssh "$n" 15 'hexdump -s 1076 -n 2 -e "1/2 \"%u\"" /dev/mmcblk0p5 2>/dev/null; echo " $(cut -d" " -f1 /tmp/joinwatch.state 2>/dev/null)"'); done
  sleep 90
  for n in "$@"; do
    b=$(fssh "$n" 15 'hexdump -s 1076 -n 2 -e "1/2 \"%u\"" /dev/mmcblk0p5 2>/dev/null; echo " $(cut -d" " -f1 /tmp/joinwatch.state 2>/dev/null)"')
    set -- ${A[$n]}; a=$1; local sa=$2; set -- $b
    if [ -z "$a" ] || [ -z "$1" ]; then echo "  $n: no p5 superblock readable — not tested"; continue; fi
    if [ "$sa" != JOINED ] || [ "$2" != JOINED ]; then echo "  $n: joinwatch not JOINED ($sa/$2) — on-join not exercised"; continue; fi
    tested=$((tested+1))
    if [ $(( $1 - a )) -eq 0 ]; then echo "  $n: p5 mounts in 90 s: 0 (ok)"; else echo "FAIL $n: p5 mounted $(( $1 - a ))x in 90 s while joined (M0 churn)"; rc=1; fi
  done
  [ "$tested" -gt 0 ] || { echo "SKIP-REASON: no joined node to observe"; return 3; }
  return $rc; }
# #263 M0 feature test on one node: the installed batman-config-save --on-join mounts p5 once per change, not per tick.
chk_p5onjoin_263() { timeout 120 ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR -o ConnectTimeout=8 "root@$1" sh -s < "$REPO/scripts/node/p5-onjoin-263.sh"; }
# #275: every board patch the image was BUILT with is visible in /rom of the running image — its Batman-Witness,
# baked by the firmware stamp into /etc/batman-patch-witness (file <glob> <string> | pkg <name> <ver-prefix> |
# none <reason>). 1.5.5-wsl.2 (Pi 4) shipped without a board patch and only the #263 probe noticed. Checks the
# image (/rom, opkg status there), not the overlay. An image built without the #275 stamp fails on purpose.
chk_patches_275() { local n rc=0; for n in "$@"; do echo "== $n"; fssh "$n" 30 '
  R=/rom; [ -f $R/etc/batman-build ] || R=
  S=$R/etc/batman-build; W=$R/etc/batman-patch-witness
  g() { sed -n "s/^$1=//p" $S | head -1; }
  echo "$(g BATMAN_VERSION) board=$(g BATMAN_BOARD) patches=$(g BATMAN_BOARD_PATCHES) root=${R:-/}"
  [ -f $W ] || { echo "no $W: image built without the #275 stamp (pre-#275 or a bypassed build)"; exit 1; }
  np=$(g BATMAN_BOARD_PATCHES | cut -d: -f1); nw=$(grep -c . $W)
  [ -n "$np" ] && [ "$np" = "$nw" ] || { echo "witness list has $nw entries, stamp says ${np:-?} patches"; exit 1; }
  T=$(printf "\t"); f=0; k=0
  while IFS="$T" read -r p kind a v; do
    [ -n "$p" ] || continue; k=$((k+1))
    case "$kind" in
      file) ok=0; for x in $R/$a; do [ -f "$x" ] && grep -aqF -- "$v" "$x" && ok=1; done
        if [ $ok = 1 ]; then echo "  ok    $p: $a has $v"; else echo "  FAIL  $p: no $a in the image contains $v"; f=1; fi ;;
      pkg) i=$(awk -v P="$a" "\$0==\"Package: \"P{q=1} q&&/^Version:/{print \$2; exit}" $R/usr/lib/opkg/status)
        case "$i" in "$v"*) echo "  ok    $p: $a $i" ;; *) echo "  FAIL  $p: image has $a ${i:-not installed}, want $v*"; f=1 ;; esac ;;
      none) echo "  none  $p: $v" ;;
      *) echo "  FAIL  $p: unknown witness kind $kind"; f=1 ;;
    esac
  done < $W
  [ $f = 0 ] && echo "ok: $k board patch(es) witnessed in the running image"
  exit $f' || rc=1; done; return $rc; }
# #268 B1: the container stack regression from the #252/#247-2 dogfood, on every reachable node. The node
# script only prints PASS/FAIL items; the EXPECTED COUNT lives here (#268 C2), so an item that silently
# stops running shows up as a short count instead of a green run.
LC_EXPECT=17
chk_lifecycle() { local n rc=0 o p f; for n in "$@"; do echo "== $n"
  o=$(timeout 300 ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR -o ConnectTimeout=8 "root@$n" sh -s < "$REPO/scripts/node/container-lifecycle.sh" 2>&1); r=$?
  echo "$o"
  p=$(echo "$o" | sed -n 's/^RESULT pass=\([0-9]*\) fail=\([0-9]*\)$/\1/p'); f=$(echo "$o" | sed -n 's/^RESULT pass=\([0-9]*\) fail=\([0-9]*\)$/\2/p')
  if [ -z "$p" ] || [ -z "$f" ]; then echo "FAIL $n: no RESULT line (ssh rc=$r) — not verified"; rc=1
  elif [ "$f" != 0 ] || [ "$p" != "$LC_EXPECT" ]; then echo "FAIL $n: pass=$p fail=$f (expected pass=$LC_EXPECT fail=0)"; rc=1
  else echo "ok $n: $p/$LC_EXPECT"; fi
done; return $rc; }
# #268 C2: dockerd restart only on nodes WITHOUT tenant containers (decided by the node's actual state).
# Not run anywhere = SKIP (with reason), never a silent pass.
chk_dockerd_restart() { local n rc=0 ran=0 o r; for n in "$@"; do echo "== $n"
  o=$(timeout 240 ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR -o ConnectTimeout=8 "root@$n" sh -s < "$REPO/scripts/node/dockerd-restart.sh" 2>&1); r=$?
  echo "$o"
  case $r in 0) ran=$((ran+1)) ;; 3) echo "$o" | grep -q '^SKIP-REASON:' || { echo "FAIL $n: rc=3 without SKIP-REASON"; rc=1; } ;; *) ran=$((ran+1)); echo "FAIL $n: dockerd restart (rc=$r)"; rc=1 ;; esac
done
[ "$rc" = 0 ] && [ "$ran" = 0 ] && { echo "SKIP-REASON: every node carries tenant containers — dockerd restart verified nowhere"; return 3; }
return $rc; }

# #268 B2 / #264: OTS CoT end to end — sent == stored, per phase, from a peer over the mesh. Each phase
# is judged on its own: P1 (one event per write) and P2A (the complete event in the truncating write) are
# CONTROLS that must arrive even with #264 unfixed — losing them is a NEW failure. P2B is the deterministic
# #264 mechanism-A victim (OTS 1.7.13 drops every one); P3 is the coalesced-write case. #264 mechanism B
# (AMQP heartbeat) needs >= 10 min and is NOT exercised here — only its log counters are reported.
ots_sql() { timeout 60 ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR -o ConnectTimeout=8 "root@$1" 'docker exec -i ots-db psql -U ots -d ots -At' 2>&1; }
ots_ctr() { fssh "$1" 15 'docker ps -q 2>/dev/null | wc -l' 2>/dev/null | tr -d ' \r'; }
ots_logc() { fssh "$1" 30 'echo "$(docker exec ots_eud_handler sh -c "grep -c \"Failed to parse\" /app/ots/logs/eud_handler_tcp.log" 2>/dev/null) $(docker logs rabbitmq 2>&1 | grep -c "missed heartbeats") $(docker exec ots_eud_handler sh -c "grep -c \"channel is closed\" /app/ots/logs/eud_handler_tcp.log" 2>/dev/null)"' 2>/dev/null | tr -d '\r'; }
chk_cot_264() { local ots=$1 peer=$2 run o c0 c1 l0 l1 rc=0 ph sent st prev i
  [ -n "$peer" ] && [ "$peer" != "$ots" ] && up "$peer" || { echo "SKIP-REASON: no generator peer (BENCH_NODE '$peer' unset, == OTS_NODE or down)"; return 3; }
  c0=$(ots_ctr "$ots"); [ "$c0" = 6 ] || { echo "FAIL OTS not 6/6 before the test ($c0)"; return 1; }
  run=DV$(date +%Y%m%d%H%M%S); echo "run id $run; generator $peer -> $ots:8088"
  l0=$(ots_logc "$ots")
  o=$(timeout 400 ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR -o ConnectTimeout=8 "root@$peer" "TARGET=$ots RUN=$run sh -s" < "$REPO/scripts/node/cot-e2e-gen.sh" 2>&1)
  echo "$o"
  # stored: poll until two consecutive identical totals (max 60 s)
  prev=x; for i in $(seq 1 12); do st=$(echo "select count(*) from cot where uid like '$run-%';" | ots_sql "$ots"); [ "$st" = "$prev" ] && break; prev=$st; sleep 5; done
  echo "stored total=$st"
  for ph in P1 P2A P2B P3; do
    sent=$(echo "$o" | sed -n "s/^SENT $ph \([0-9]*\)$/\1/p")
    case $ph in P2A) pat="$run-P2-%A" ;; P2B) pat="$run-P2-%B" ;; *) pat="$run-$ph-%" ;; esac
    st=$(echo "select count(*) from cot where uid like '$pat';" | ots_sql "$ots")
    case "$sent$st" in ''|*[!0-9]*) echo "FAIL $ph: unreadable sent=[$sent] stored=[$st] — not verified"; rc=1; continue ;; esac
    if [ "$st" = "$sent" ]; then echo "ok $ph: stored $st/$sent"
    else echo "FAIL $ph lost $((sent-st))/$sent (stored $st)"; rc=1
      case $ph in P1) u="'$run-P1-'||g" ;; P2A) u="'$run-P2-'||g||'A'" ;; P2B) u="'$run-P2-'||g||'B'" ;; *) u="" ;; esac
      [ -n "$u" ] && [ "$sent" -gt 0 ] && echo "  missing seq: $(echo "select string_agg(g::text,' ') from generate_series(1,$sent) g where not exists (select 1 from cot where uid=$u);" | ots_sql "$ots")"
    fi
  done
  echo "$o" | grep '^CONNLOST' | sed 's/^/FAIL CONNECTION-LOST /' && rc=1
  l1=$(ots_logc "$ots"); echo "eud 'Failed to parse' / rabbit 'missed heartbeats' / eud 'channel is closed': before [$l0] after [$l1] (info; #264 mechanism B is not exercised by this suite)"
  # cleanup in one transaction, then verify every related table is empty for this run
  ots_sql "$ots" <<SQL
begin; delete from euds where uid like '$run-%'; delete from cot where uid like '$run-%'; commit;
SQL
  o=$(ots_sql "$ots" <<SQL
select (select count(*) from cot where uid like '$run-%' or sender_uid like '$run-%') + (select count(*) from euds where uid like '$run-%') + (select count(*) from points where uid like '$run-%' or device_uid like '$run-%');
SQL
)
  [ "$o" = 0 ] && echo "cleanup ok (cot/euds/points = 0)" || { echo "FAIL cleanup: $o rows of run $run left behind"; rc=1; }
  c1=$(ots_ctr "$ots"); [ "$c1" = 6 ] || { echo "FAIL OTS not 6/6 after the test ($c1)"; rc=1; }
  return $rc; }
# #268 B3: release-gate load soak (AB_MODE=--destructive only). All three nodes under real load at once for
# SOAK_MIN (>= 30) minutes: an HTTP tenant on BENCH_NODE and MESH_NODE (GET locally and over the mesh), CoT
# into the OTS. soak-run drives the load and records one sample per node per minute in $DIR/soak.samples;
# the soak-* suites then judge it, one property each (one suite = one state).
SOAK_MIN=${SOAK_MIN:-30}; SOAK_HTTP_IMAGE=${SOAK_HTTP_IMAGE:-meshtastic-cli:arm64}
SOAK_RUN=""; SOAK_WEB=""
soak_ssh() { local n=$1 vars=$2; timeout 60 ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR -o ConnectTimeout=8 "root@$n" "$vars sh -s" < "$REPO/scripts/node/soak-node.sh" 2>&1 | tr -d '\r'; }
soak_nodes() { local n out=""; for n in "$BENCH_NODE" "$MESH_NODE" "$OTS_NODE"; do case " $out " in *" $n "*) ;; *) out="$out $n";; esac; done; echo $out; }
chk_soak_run() { local n o dur rc=0 m peer other
  [ "$SOAK_MIN" -ge 30 ] 2>/dev/null || { echo "FAIL SOAK_MIN=$SOAK_MIN < 30: the 10-min first/last windows would overlap and miss the heartbeat period"; return 1; }
  dur=$(( (SOAK_MIN + 3) * 60 )); SOAK_RUN=DVS$(date +%Y%m%d%H%M%S); : > "$DIR/soak.samples"
  echo "run $SOAK_RUN, ${SOAK_MIN} min + 2 min warm-up, nodes: $(soak_nodes)"
  for n in "$BENCH_NODE" "$MESH_NODE"; do
    o=$(soak_ssh "$n" "ROLE=web-up IMG=$SOAK_HTTP_IMAGE"); echo "$n: $o"
    case "$(echo "$o" | tail -1)" in OK*) SOAK_WEB="$SOAK_WEB $n";; NOIMAGE*) ;; *) echo "FAIL $n: dv-web setup"; rc=1;; esac   # judge the role's last line (docker may print warnings first)
  done
  for n in $SOAK_WEB; do
    o=$(soak_ssh "$n" "ROLE=httpgen TARGET=127.0.0.1 LABEL=local DUR=$dur"); echo "$n: $o"
    for other in "$BENCH_NODE" "$MESH_NODE"; do [ "$other" = "$n" ] && continue
      o=$(soak_ssh "$other" "ROLE=httpgen TARGET=$n LABEL=mesh DUR=$dur"); echo "$other -> $n: $o"; done
  done
  o=$(soak_ssh "$BENCH_NODE" "ROLE=cotgen TARGET=$OTS_NODE RUN=$SOAK_RUN DUR=$dur"); echo "$BENCH_NODE: $o"
  for m in $(seq 0 $((SOAK_MIN + 2))); do
    for n in $(soak_nodes); do o=$(soak_ssh "$n" ROLE=sample); echo "$m $n $o" >> "$DIR/soak.samples"; done
    echo "$m $(grep "^$m " "$DIR/soak.samples" | cut -c1-200 | tr '\n' '|')"
    sleep 55
  done
  sleep 20   # let cot_parser drain
  echo "stored $(echo "select count(*) from cot where uid like '$SOAK_RUN-S-%';" | ots_sql "$OTS_NODE")" >> "$DIR/soak.samples"
  ots_sql "$OTS_NODE" <<SQL >/dev/null
begin; delete from euds where uid like '$SOAK_RUN-%'; delete from cot where uid like '$SOAK_RUN-%'; commit;
SQL
  o=$(echo "select count(*) from cot where uid like '$SOAK_RUN-%' or sender_uid like '$SOAK_RUN-%';" | ots_sql "$OTS_NODE")
  [ "$o" = 0 ] && echo "cleanup ok" || { echo "FAIL cleanup: $o soak CoT rows left"; rc=1; }
  for n in $(soak_nodes); do o=$(soak_ssh "$n" ROLE=down); echo "$n: $o"; case "$(echo "$o" | tail -1)" in OK*) ;; *) echo "FAIL cleanup on $n"; rc=1;; esac; done
  return $rc; }
# value of key $3 for node $2 at minute $1 from soak.samples ("" if absent)
sv() { awk -v m="$1" -v n="$2" -v k="$3" '$1==m && $2==n { for (i=3;i<=NF;i++) { split($i,a,"="); if (a[1]==k) { print a[2]; exit } } }' "$DIR/soak.samples"; }
savg() { local n=$1 k=$2 a=$3 b=$4 m s=0 c=0 v; for m in $(seq "$a" "$b"); do v=$(sv "$m" "$n" "$k"); isint "$v" && { s=$((s+v)); c=$((c+1)); }; done
  [ "$c" -ge $(( (b-a+1) * 8 / 10 )) ] && echo $((s/c)); }   # >= 80% of the window must have been read
chk_soak_mem() { local n k f l rc=0 last=$((SOAK_MIN + 2)); for n in $(soak_nodes); do for k in dockerd_kb containerd_kb shims_kb; do
    f=$(savg "$n" "$k" 2 11); l=$(savg "$n" "$k" $((last-9)) "$last")
    { [ -n "$f" ] && [ -n "$l" ]; } || { echo "FAIL $n $k: window unreadable (first=[$f] last=[$l]) — not verified"; rc=1; continue; }
    if [ "$l" -le $(( f * 115 / 100 + 8192 )) ]; then echo "ok $n $k first10=$((f/1024))M last10=$((l/1024))M"
    else echo "FAIL $n $k grew: first10=$((f/1024))M last10=$((l/1024))M (> x1.15 + 8M)"; rc=1; fi
  done; done; return $rc; }
chk_soak_avail() { local n m v base mn rc=0; for n in $(soak_nodes); do base=$(sv 2 "$n" avail_kb); mn=""
    isint "$base" || { echo "FAIL $n baseline MemAvailable unreadable — not verified"; rc=1; continue; }
    for m in $(seq 2 $((SOAK_MIN + 2))); do v=$(sv "$m" "$n" avail_kb); isint "$v" && { [ -z "$mn" ] || [ "$v" -lt "$mn" ]; } && mn=$v; done
    if [ "$mn" -ge $(( base * 85 / 100 )) ]; then echo "ok $n MemAvailable base=$((base/1024))M min=$((mn/1024))M"
    else echo "FAIL $n MemAvailable fell to $((mn/1024))M (< 85% of $((base/1024))M)"; rc=1; fi; done; return $rc; }
chk_soak_ctr() { local n k a b rc=0 last=$((SOAK_MIN + 2)); for n in $(soak_nodes); do for k in restarts oom_kill; do
    a=$(sv 2 "$n" $k); b=$(sv "$last" "$n" $k)
    { isint "$a" && isint "$b"; } || { echo "FAIL $n $k unreadable [$a] [$b] — not verified"; rc=1; continue; }
    [ "$b" = "$a" ] && echo "ok $n $k $a -> $b" || { echo "FAIL $n $k $a -> $b"; rc=1; }; done; done; return $rc; }
chk_soak_http() { local lab=$1 n o f rc=0 last=$((SOAK_MIN + 2)) any=0; for n in $(soak_nodes); do
    o=$(sv "$last" "$n" "http_${lab}_ok"); f=$(sv "$last" "$n" "http_${lab}_fail"); [ -z "$o$f" ] && continue; any=1
    { isint "$o" && isint "$f"; } || { echo "FAIL $n http $lab unreadable — not verified"; rc=1; continue; }
    [ "$f" = 0 ] && [ "$o" -gt 0 ] && echo "ok $n http $lab ok=$o fail=0" || { echo "FAIL $n http $lab ok=$o fail=$f"; rc=1; }; done
  [ "$any" = 0 ] && { echo "SKIP-REASON: no node ran the $lab HTTP generator (no '$SOAK_HTTP_IMAGE' image on BENCH/MESH: tenants started on [${SOAK_WEB# }])"; return 3; }
  [ "$lab" = local ] && for n in "$BENCH_NODE" "$MESH_NODE"; do case " $SOAK_WEB " in *" $n "*) ;; *) echo "info: $n had no '$SOAK_HTTP_IMAGE' image — its HTTP tenant was not loaded";; esac; done
  return $rc; }
chk_soak_cot() { local sent st rc re
  sent=$(sv $((SOAK_MIN + 2)) "$BENCH_NODE" cot_sent); re=$(sv $((SOAK_MIN + 2)) "$BENCH_NODE" cot_reconn); st=$(sed -n 's/^stored //p' "$DIR/soak.samples")
  { isint "$sent" && isint "$st"; } || { echo "FAIL CoT counters unreadable sent=[$sent] stored=[$st] — not verified"; return 1; }
  echo "CoT sent=$sent stored=$st reconnects=$re"
  [ "$st" = "$sent" ] || { echo "FAIL CoT lost $((sent-st))/$sent"; return 1; }; }
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

chk_p6grow_201() { fssh "$1" 20 '                              # 201-firstboot-grow.md: A/B .img ships p6
  [ -b /dev/mmcblk0p6 ] || { echo "no p6 (single-slot/MBR card) — n/a"; exit 0; }   # only the v2 A/B card has p6
  disk=$(cat /sys/block/mmcblk0/size 2>/dev/null)
  p6=$(cat /sys/class/block/mmcblk0p6/size 2>/dev/null)
  [ -n "$disk" ] && [ "$p6" -gt 0 ] 2>/dev/null || { echo "cannot read geometry"; exit 1; }
  pct=$(( p6 * 100 / disk ))
  echo "p6=$p6 sectors of disk=$disk ( data = ${pct}% of card ); baked A/B img ships p6 ~200MiB (<1%)"
  # a p6 that failed to grow stays ~200MiB (<1% of a >=8G card); a grown one is the whole free tail (>50%)
  [ "$pct" -ge 50 ]'; }

chk_flashgo() { fssh "$1" 40 '                                 # #159/#216 flash-and-go payload integrity
  d=/opt/batdata/apps/opentakserver
  # (1) firstload service installed + enabled — catches the from-feed Makefile-install / overlay-shadow
  #     regression that shipped an image WITHOUT the service (session found this the hard way).
  [ -x /etc/init.d/batman-ots-firstload ] || { echo "firstload service missing"; exit 1; }
  ls /etc/rc.d/S[0-9]*batman-ots-firstload >/dev/null 2>&1 || { echo "firstload not enabled (no S-link)"; exit 1; }
  # (2) offline copies present (F2 mv-not-rm contract) + no stuck tars in the images root (load complete).
  ls "$d"/images/loaded/*.tar >/dev/null 2>&1 || { echo "no offline copies in images/loaded"; exit 1; }
  ls "$d"/images/*.tar >/dev/null 2>&1 && { echo "stuck tars in images root (load incomplete)"; exit 1; }
  # (3) the autocommit canary, run through autocommit itself (same code path as the OTA gate): it is
  #     built on the node from this rootfs (#209 S5 review K1c) and proves the rootfs can run
  #     containers (overlay/memcg/runc), the very thing docker-info alone does not.
  batman-autocommit canary || { echo "canary failed (rootfs cannot run containers)"; exit 1; }
  # (4) autocommit carries the docker-engine/canary gate and NOT the busybox-absent timeout applet.
  grep -q "tenants on p6 but this rootfs has no docker engine" /usr/bin/batman-autocommit || { echo "autocommit missing docker-engine/canary gate"; exit 1; }
  grep -q "timeout 15 docker" /usr/bin/batman-autocommit && { echo "autocommit uses busybox-absent timeout applet"; exit 1; }
  echo "firstload enabled; offline copies present; canary runs; autocommit gate ok"'; }

if [ "$OTS_SOC" = bcm2710 ]; then
  for s in confinement-98 ots-up-162 drift-detect-156 payload-mgr-167 arbiter-167 payload-config-golden payload-conform flashgo-159 ots-cot-e2e-264; do
    suite "$s" "OTS_NODE $OTS_NODE is bcm2710 — not run (see ots-node-209)" ""
  done
elif up "$OTS_NODE"; then
  suite confinement-98  "OTS container confinement — 9 axes ×6 (#98)"                       "chk_98 $OTS_NODE"
  suite ots-up-162       "OTS 6/6 running + postgres endpoint answers (#162)"                "chk_162 $OTS_NODE"
  suite drift-detect-156 "reconciler flags an unhardened decoy as DRIFT (#156, white-box)"   "chk_156 $OTS_NODE"
  suite payload-mgr-167  "OTS on the generic payload manager, old guardian gone (#167)"       "chk_167g $OTS_NODE"
  suite arbiter-167      "port/zone arbiter REFUSES a colliding tenant (#167, white-box)"      "chk_167a $OTS_NODE"
  suite payload-config-golden "p6 tenant config == baked golden + unless-stopped + images present (payload-config-golden.md)" "chk_golden $OTS_NODE"
  suite payload-conform "live containers == manifest: running + config-fingerprint label + tenant label + MOUNTs (src/RO) + no orphans (#274)" "chk_conform $OTS_NODE"
  suite flashgo-159      "flash-and-go integrity — firstload enabled, offline copies (F2), canary runs, autocommit gate (#159/#216)" "chk_flashgo $OTS_NODE"
  suite ots-cot-e2e-264  "CoT sent == stored per phase from $BENCH_NODE: P1 control, P2 deterministic truncation (A control / B #264-A), P3 burst; heartbeat (#264-B) NOT exercised (#268 B2)" "chk_cot_264 $OTS_NODE $BENCH_NODE"
else
  for s in confinement-98 ots-up-162 drift-detect-156 payload-mgr-167 arbiter-167 payload-config-golden payload-conform flashgo-159 ots-cot-e2e-264; do suite "$s" "OTS_NODE $OTS_NODE did not answer" ""; done
fi
if up "$MESH_NODE"; then
  suite field-status-130 "halow-status verdict agrees with batctl radio truth (#130)"        "chk_130 $MESH_NODE"
  suite meshjoin-209 "the OTA commit gate's mesh test passes on a joined node (ab-autocommit v2.2 N10)" "chk_meshjoin_209 $MESH_NODE"
  BV_NODES=$MESH_NODE                      # every distinct reachable node: a mixed fleet must show up
  for n in "$OTS_NODE" "$IPERF_PEER"; do [ -n "$n" ] && [ "$n" != "$MESH_NODE" ] && up "$n" && case " $BV_NODES " in *" $n "*) ;; *) BV_NODES="$BV_NODES $n" ;; esac; done
  suite batman-ver-247 "mesh core = routing openwrt-24.10 batman-adv 2024.3-r>=13, loaded == installed, NC compiled out, on: $BV_NODES (#247)" "chk_batver_247 $BV_NODES"
  suite go-toolchain-252 "docker/dockerd/containerd/runc built by the same Go as openmanetd, >= go1.23, on: $BV_NODES (#252)" "chk_go_252 $BV_NODES"
  suite halow-cmd-263 "mm6108 driver carries the #263 command-ownership fix; no refused unlink / Oops this boot; reports late responses + survived races, on: $BV_NODES (#263)" "chk_halow_263 $BV_NODES"
  suite p5-churn-263 "no p5 mount churn from joinwatch save-on-join on a joined node (M0), on: $BV_NODES (#263)" "chk_p5churn_263 $BV_NODES"
  if up "$BENCH_NODE"; then suite p5-onjoin-263 "save-on-join mounts p5 once per change, not per tick: unchanged/changed/other-writer/--save cases, on $BENCH_NODE (#263 M0)" "chk_p5onjoin_263 $BENCH_NODE"
  else suite p5-onjoin-263 "save-on-join p5 cache (#263 M0) — BENCH_NODE $BENCH_NODE did not answer" ""; fi
  suite board-patches-275 "every firmware board patch is witnessed in the running image (/rom), not only applied at build time, on: $BV_NODES (#275)" "chk_patches_275 $BV_NODES"
  suite runc-cve-247 "runc >= 1.3.6 (container-escape CVEs) and /proc/self/exe sealed via overlayfs, on: $BV_NODES (#247-2)" "chk_runc_247 $BV_NODES"
  suite container-lifecycle-247 "container stack: limits, exec, OOM containment, restart policy, exeseal, tty, cp, logs -f, healthcheck, pids, runc features, CRI off — $LC_EXPECT items each, on: $BV_NODES (#268 B1)" "chk_lifecycle $BV_NODES"
  suite dockerd-restart-247 "dockerd restarts with a live container and runs containers again — only on nodes without tenants, on: $BV_NODES (#268 C2)" "chk_dockerd_restart $BV_NODES"
  suite mesh-console-14 "/cgi-bin/mesh aggregate agrees with batctl (#14)"                   "chk_14 $MESH_NODE"
  suite p5-seed-202      "a JOINED node auto-seeds p5 (radio delta), decoupled from lockdown (#202)" "chk_202 $MESH_NODE"
  suite mesh-tput        "sustained mesh throughput to peer (median of N batctl tp; baseline soak median ~9.4 Mbps)" "chk_tput $MESH_NODE"
  if [ "$IPERF_PEER" != "$MESH_NODE" ] && up "$IPERF_PEER"; then
    suite mesh-tput-iperf "iperf TCP throughput MESH_NODE->peer (real IP payload; batctl tp under-reports ~15%; single-dir baseline ~9.3 Mbps)" "chk_iperf $MESH_NODE $IPERF_PEER"
  else
    suite mesh-tput-iperf "IPERF_PEER '$IPERF_PEER' unusable (unset / == MESH_NODE / down) — set IPERF_PEER to the other mesh node" ""
  fi
else
  for s in field-status-130 meshjoin-209 batman-ver-247 go-toolchain-252 runc-cve-247 container-lifecycle-247 dockerd-restart-247 mesh-console-14 p5-seed-202 mesh-tput mesh-tput-iperf; do suite "$s" "MESH_NODE $MESH_NODE did not answer" ""; done
fi

# A/B commit hygiene (#211): a completed reflash must not leave the node an uncommitted trial (a reboot
# would revert). batman-autocommit health-gates + commits; assert the bench node ended committed.
# Placed here (after chk_* are defined) — chk_autocommit is used, unlike the inline BENCH suites above.
if up "$BENCH_NODE"; then
  suite autocommit-211 "every fleet node committed (not an uncommitted trial) and no stray hold-commit flag (#211/#261)" '(rc=0; for n in $FLEET; do echo "== $n"; chk_autocommit "$n" || rc=1; done; [ -n "$FLEET" ] || { echo "FAIL fleet empty"; rc=1; }; exit $rc)' 
  suite p6grow-201 "A/B card data partition (p6) grew to fill the card at first boot (#201, not stuck at the baked ~200MiB)" "chk_p6grow_201 $BENCH_NODE"
  suite socgate-209 "sysupgrade refuses a wrong-SoC A/B image (#209 review: the old check only warned, and a bcm2711 wildcard passed everything)" "chk_socgate_209 $BENCH_NODE"
  suite slot-verify-209 "card sanity every slot op relies on: layout=SoC, FAT count, Pi 3 hybrid MBR, DT vs cmdline (#209 S5)" "chk_slotverify_209 $BENCH_NODE"
  suite memcg-209 "memory cgroup controller enabled — docker limits + autocommit canary (#209 D6; bcm2710 DTB disables it)" "chk_memcg_209 $BENCH_NODE"
  suite trybootget-209 "firmware answers the tryboot GET and the one-shot flag is clear on a normal boot (#209 D5)" "chk_trybootget_209 $BENCH_NODE"
  suite ota-trace-209 "OTA flight recorder: BOOT facts every boot + a complete stage-2 chain for the last OTA (#209 S5)" "chk_otatrace_209 $BENCH_NODE"
  suite slot-integrity-209 "Pi 4: explicit-restart tool + hook, not on a wrongly-booted slot, not stuck, both slots self-checking (#209 S5)" "chk_slotintegrity_209 $BENCH_NODE"
  # every reachable Pi 4 in the run (bench, mesh, OTS) must meet the bootloader floor
  P4S=""; for n in "$BENCH_NODE" "$MESH_NODE" "$OTS_NODE"; do [ "$(soc_of "$n")" = bcm2711 ] && case " $P4S " in *" $n "*) ;; *) P4S="$P4S $n" ;; esac; done
  if [ -n "$P4S" ]; then
    suite eeprom-209 "Pi 4 bootloader >= 2025-08-20 — below it a firmware-level slot failure hangs instead of falling back (#209 S5)" "chk_eeprom_209 $P4S"
  else
    na eeprom-209 "no Pi 4 in this run (bench/mesh/OTS are all Pi 3, which has no EEPROM; its fallback is covered by p7-209 + the read-back)"
  fi
  if [ "$(soc_of "$BENCH_NODE")" = bcm2711 ]; then
    na p7-209 "BENCH_NODE is a Pi 4: it boots from GPT via the EEPROM, there is no p7 firmware partition"
  else
    suite p7-209 "Pi 3 firmware partition: allow-listed bootcode.bin, config.txt present, autoboot.txt valid (#209 D3/D4)" "chk_p7_209 $BENCH_NODE"
  fi
else
  suite autocommit-211 "A/B commit state (#211) — BENCH_NODE $BENCH_NODE did not answer" ""
  suite p6grow-201 "p6 grow-to-fill (#201) — BENCH_NODE $BENCH_NODE did not answer" ""
  for s in socgate-209 slot-verify-209 memcg-209 trybootget-209 p7-209 eeprom-209; do suite "$s" "BENCH_NODE $BENCH_NODE did not answer" ""; done
fi

# ---- tier B: destructive, induces the real failure — DNODE (eth) only, --destructive ----
dwait() {   # $1 node, wait until ssh answers with a boot_id, up to $2 s
  local n=$1 max=${2:-200} t=0
  while [ "$t" -lt "$max" ]; do
    fssh "$n" 8 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null | grep -q . && return 0
    sleep 8; t=$((t+8))
  done; return 1
}
bootid() { fssh "$1" 10 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null | tr -d ' \r'; }
# Every reboot-based check must PROVE the node rebooted (#268 A8/K1): a `reboot` lost to a mesh blip leaves
# the node up, dwait returns at once, and the post-check then reads the untouched state as a pass.
# DV_TEST_NOREBOOT=1 replaces the reboot with `true` — the negative control for exactly that failure.
reboot_and_wait() {   # $1 node, $2 the command that reboots it (default: reboot), $3 dwait budget s
  local n=$1 cmd=${2:-reboot} max=${3:-220} b0 b1
  b0=$(bootid "$n"); [ -n "$b0" ] || { echo "FAIL boot_id unreadable before the reboot — not verified"; return 1; }
  [ "${DV_TEST_NOREBOOT:-0}" = 1 ] && cmd=true
  fssh "$n" 15 "$cmd" >/dev/null 2>&1; sleep 20
  dwait "$n" "$max" || { echo "FAIL node did not come back within ${max}s"; return 1; }
  b1=$(bootid "$n")
  [ -n "$b1" ] && [ "$b1" != "$b0" ] || { echo "FAIL reboot did not happen (boot_id $b0 -> ${b1:-unreadable})"; return 1; }
  echo "rebooted: boot_id $b0 -> $b1"; }

bchk_174() {   # #174 faketime: the offline clock only moves forward across a reboot (#268 A6 — checks the MECHANISM)
  # 1 the shutdown save happened: the saved bound S >= the clock T0 read just before the reboot (save is
  #   forward-only, so it has to be read back, not assumed); 2 the boot restore happened: the clock T1
  #   after boot >= S; 3 the reboot happened (boot_id). Not judged: whether the clock is RIGHT — with no
  #   time source it cannot be (#174 is a monotonic lower bound); T0 >= 2026 is printed as info only.
  # Not checked via logread: restore runs at START=12, before logd, so its log line may never be seen.
  # DV_TEST_FAKETIME_NOSAVE=1: remove the K09 stop link for this reboot (negative control: check 1 must FAIL).
  local n=$1 t0 s t1 rc=0
  fssh "$n" 15 '[ -x /usr/sbin/batman-faketime ] && [ -f /etc/init.d/batman-faketime ]' || { echo "FAIL faketime not installed"; return 1; }
  t0=$(fssh "$n" 10 'date +%s' | tr -d ' \r'); isint "$t0" || { echo "FAIL T0 unreadable"; return 1; }
  if [ "${DV_TEST_FAKETIME_NOSAVE:-0}" = 1 ]; then
    fssh "$n" 10 'l=$(ls /etc/rc.d/K*batman-faketime 2>/dev/null); [ -n "$l" ] && mv "$l" /tmp/dv-faketime-klink && echo "$l" > /tmp/dv-faketime-klink.name'
    echo "NEGATIVE CONTROL: shutdown save link removed for this reboot"
  fi
  reboot_and_wait "$n" reboot 240 || rc=1
  if [ "${DV_TEST_FAKETIME_NOSAVE:-0}" = 1 ]; then   # the link lives on the overlay: put it back
    fssh "$n" 10 'cd /etc/rc.d && ln -sf ../init.d/batman-faketime K09batman-faketime && ls -l K09batman-faketime' || echo "FAIL could not restore /etc/rc.d/K09batman-faketime"
  fi
  [ "$rc" = 0 ] || return 1
  s=$(fssh "$n" 10 'cat /opt/batdata/.faketime 2>/dev/null' | tr -d ' \r'); t1=$(fssh "$n" 10 'date +%s' | tr -d ' \r')
  isint "$s" && isint "$t1" || { echo "FAIL saved bound [$s] or T1 [$t1] unreadable — not verified"; return 1; }
  echo "T0=$t0 ($(date -u -d @$t0 +%FT%TZ 2>/dev/null))  saved=$s  T1=$t1 ($(date -u -d @$t1 +%FT%TZ 2>/dev/null))  had-real-time=$([ "$t0" -ge 1767225600 ] && echo yes || echo no)"
  [ "$s" -ge "$t0" ] || { echo "FAIL shutdown save did not happen: saved bound $s < pre-reboot clock $t0"; rc=1; }
  [ "$t1" -ge "$s" ] || { echo "FAIL boot restore did not happen: clock $t1 < saved bound $s"; rc=1; }
  return $rc; }

bchk_192() {   # clear the guardian from the overlay (as an A/B flash does), reboot, assert it auto-returns
  # #167 renamed the OTS guardian batman-ots -> batman-payload-opentakserver (generic payload manager);
  # match any tenant guardian batman-payload-* so this stays tenant-agnostic. Only called on a bcm2711
  # DNODE (a Pi 3 carries no tenant by design -> N/A at the call site); a Pi 4 without one is BROKEN.
  fssh "$1" 12 'ls /etc/init.d/batman-payload-* >/dev/null 2>&1' || { echo "FAIL no guardian on this Pi 4 (expected batman-payload-*)"; return 1; }
  fssh "$1" 15 'rm -f /etc/init.d/batman-payload-* /etc/rc.d/S*batman-payload-*' >/dev/null 2>&1
  reboot_and_wait "$1" reboot 240 || return 1
  sleep 30   # batdata-mount restore + guardian start
  local r; r=$(fssh "$1" 12 'ls /etc/init.d/batman-payload-* >/dev/null 2>&1 && pgrep -f batman-payload >/dev/null && echo yes || echo no' | tr -d " \r")
  echo "guardian auto-restored after overlay-clear+reboot: $r"; [ "$r" = yes ]; }

bchk_173() {   # force a real kernel panic; assert the ramoops backend captured it AND boot-reason classified PANIC (#173/#61)
  # the backend must be the correctly-reg'd ramoops-pi4 (the #173 fix). With a bare `dtoverlay=ramoops` (2-cell
  # reg, invalid on arm64 bcm2711) or on HW that cannot preserve the reserved region, pstore never registers a
  # backend and the panic is silently lost — which is exactly the regression this guards. Precondition-checked so
  # a node missing the fix FAILs loudly instead of the test passing on a node that captured nothing.
  fssh "$1" 12 'dmesg | grep -q "Registered ramoops as persistent store backend"' \
    || { echo "FAIL ramoops backend NOT registered — pstore capture inactive (#173 fix missing, or HW cannot preserve the region)"; return 1; }
  local before after reason
  before=$(fssh "$1" 12 'ls /opt/batdata/crash/*_dmesg-ramoops-* 2>/dev/null | wc -l' | tr -d " \r")
  isint "$before" || { echo "FAIL crash record count unreadable before the panic"; return 1; }
  reboot_and_wait "$1" 'echo 1 > /proc/sys/kernel/sysrq; sync; echo c > /proc/sysrq-trigger' 240 || return 1
  sleep 8   # 95-batman-storage moves pstore records -> crash/ and writes boot-reasons.log at first boot
  after=$(fssh "$1" 12 'ls /opt/batdata/crash/*_dmesg-ramoops-* 2>/dev/null | wc -l' | tr -d " \r")
  reason=$(fssh "$1" 12 'tail -1 /opt/batdata/log/boot-reasons.log 2>/dev/null')
  echo "dmesg-ramoops records $before -> ${after:-unreadable}; last boot-reason: $reason"
  isint "$after" || { echo "FAIL crash record count unreadable after the panic — not verified"; return 1; }
  [ "$after" -gt "$before" ] || { echo "FAIL no new pstore record"; return 1; }
  echo "$reason" | grep -q 'prev=PANIC' || { echo "FAIL boot-reason did not classify the panic"; return 1; }; }

bchk_rejoin_245() {   # DNODE leaves+rejoins the mesh; assert peers never kernel-panic (#245) and DNODE never hangs (#246)
  # #245: mm6108 rate-control read a freed/NULL STA table on TX-status when a mesh peer (re)joined -> peer Oops/panic.
  # #246: batman-adv 2025.4 ELP worker vs cancel_delayed_work_sync rtnl deadlock when a hard iface left bat0 -> mover
  #       network config hangs (no plain-reboot recovery). `wifi down/up` exercises BOTH in one test: the down path
  #       hits #246 on the mover, the up path hits #245 on the peers. An unpatched build fails within ~2 cycles.
  # #268 A1/A7: every peer reading must be a number (unreadable = FAIL, never 0); a peer that rebooted during the
  # test (boot_id changed: panic, or a hang -> watchdog) FAILs even if its PANIC count did not move; and the
  # mover must have rejoined the mesh before we decide nobody is reachable (it may be the operator's only bridge).
  local mover=$1 N=${REJOIN_CYCLES:-3} i v t pl idx a b ba bb
  local victims=() base=() boots=() cand=()
  for v in "$BENCH_NODE" "$MESH_NODE" "$OTS_NODE"; do
    [ "$v" = "$mover" ] && continue; case " ${cand[*]} " in *" $v "*) continue;; esac; cand+=("$v"); done
  t=0; pl=0
  while [ "$t" -lt 240 ]; do
    pl=$(fssh "$mover" 10 'iw dev wlh0 station dump 2>/dev/null | grep -c "mesh plink:.*ESTAB"' | tr -d ' \r')
    isint "$pl" && [ "$pl" -ge 1 ] && break; sleep 10; t=$((t+10))
  done
  isint "$pl" && [ "$pl" -ge 1 ] || { echo "FAIL mover $mover has no ESTAB mesh peer after 240 s (plink=${pl:-unreadable}) — it did not (re)join the mesh"; return 1; }
  for v in "${cand[@]}"; do dwait "$v" 240 && victims+=("$v") || echo "info: peer $v not reachable from this host (mover has $pl plink)"; done
  [ "${#victims[@]}" -ge 1 ] || { echo "SKIP-REASON: mover $mover is in the mesh ($pl plink) but no peer is reachable from this host"; return 3; }
  fssh "$mover" 12 '[ "$(cat /sys/class/net/wlh0/operstate 2>/dev/null)" = up ]' || { echo "FAIL mover $mover wlh0 not up at start"; return 1; }
  for v in "${victims[@]}"; do
    b=$(fssh "$v" 12 'grep -c prev=PANIC /opt/batdata/log/boot-reasons.log 2>/dev/null' | tr -d ' \r'); bb=$(bootid "$v")
    isint "$b" && [ -n "$bb" ] || { echo "FAIL peer $v baseline unreadable (PANIC=[$b] boot_id=[$bb]) — not verified"; return 1; }
    base+=("$b"); boots+=("$bb")
  done
  local nv=${#victims[@]}
  for i in $(seq 1 "$N"); do
    fssh "$mover" 25 'wifi down radio1; sleep 45; wifi up radio1' >/dev/null 2>&1
    t=0; pl=0
    while [ "$t" -lt 180 ]; do
      pl=$(fssh "$mover" 10 'iw dev wlh0 station dump 2>/dev/null | grep -c "mesh plink:.*ESTAB"' | tr -d ' \r')
      isint "$pl" && [ "$pl" -ge "$nv" ] && break; sleep 10; t=$((t+10))
    done
    isint "$pl" && [ "$pl" -ge "$nv" ] || { echo "FAIL cycle $i/$N: mover $mover did not rejoin $nv peers in 180s (plink=${pl:-unreadable}) — likely #246 rtnl hang"; return 1; }
    sleep 15   # let a panicking peer reboot far enough to bump its boot-reasons PANIC count
  done
  local bad=0
  for idx in "${!victims[@]}"; do
    v=${victims[$idx]}; b=${base[$idx]}; bb=${boots[$idx]}
    dwait "$v" 240 >/dev/null
    a=$(fssh "$v" 12 'grep -c prev=PANIC /opt/batdata/log/boot-reasons.log 2>/dev/null' | tr -d ' \r'); ba=$(bootid "$v")
    if ! isint "$a" || [ -z "$ba" ]; then echo "FAIL peer $v unreadable after the test (PANIC=[$a] boot_id=[$ba]) — not verified"; bad=1; continue; fi
    echo "peer $v PANIC $b -> $a, boot_id $bb -> $ba"
    [ "$a" -gt "$b" ] && { echo "FAIL peer $v panicked during the rejoin cycles"; bad=1; }
    [ "$ba" != "$bb" ] && { echo "FAIL peer $v rebooted during the rejoin cycles (boot_id changed)"; bad=1; }
  done
  echo "$N leave/rejoin cycles, $nv peer(s), mover $mover back each time"
  [ "$bad" = 0 ]; }

# ---- #274 payload converge / clean stop (docs/design/274-payload-converge.md §6) ----
ots_ids() { fssh "$1" 20 'm=$(ls /opt/batdata/apps/opentakserver/*.manifest | head -1); for c in $(awk "/^CONTAINER /{print \$2}" "$m"); do echo "$c $(docker inspect -f "{{.Id}}" $c 2>/dev/null | cut -c1-12)"; done' | tr -d '\r'; }
ots_ready() { fssh "$1" 20 '[ "$(docker ps -q | wc -l)" -ge 6 ] && docker exec ots-db pg_isready -q && wget -q -T 5 -O /dev/null http://172.20.0.5:8081/api/health' >/dev/null 2>&1; }
# the guardian's LAST "converge done ... uptime=<s.ss>" line (unique: it carries the uptime). Compared by content,
# not counted: a rebuild logs enough to push older lines out of the logread ring, so a count can stand still.
conv_last() { fssh "$1" 15 'logread | grep "batman-payload\[opentakserver\]: converge done" | tail -1 | sed -n "s/.*\(converge done.*\)/\1/p"' | tr -d '\r'; }
# wait until the last "converge done" line differs from $2 (max $3 s); prints it
wait_converge() { local n=$1 l0=$2 max=${3:-300} i l
  for i in $(seq 1 $((max / 5))); do
    l=$(conv_last "$n")
    [ -n "$l" ] && [ "$l" != "$l0" ] && { echo "$l"; return 0; }
    sleep 5
  done; return 1; }
# early-CoT probe (#274 review C1), run on the HOST in the background: the nodes' busybox nc has no -w, the host
# has bash /dev/tcp + timeout and reaches the OTS node over the mesh like a field client. Waits for 8088 to go
# down (the reboot) and come back, then sends one CoT the moment it accepts. Writes "UP <epoch>" / "SENT <epoch> rc=".
cot_probe_274() { local ip=$1 uid=$2 out=$3 i n
  ( i=0; while timeout 2 bash -c ": > /dev/tcp/$ip/8088" 2>/dev/null; do i=$((i+1)); [ $i -gt 180 ] && { echo NEVER-DOWN; exit 1; }; sleep 1; done
    i=0; until timeout 2 bash -c ": > /dev/tcp/$ip/8088" 2>/dev/null; do i=$((i+1)); [ $i -gt 400 ] && { echo NEVER-UP; exit 1; }; sleep 1; done
    echo "UP $(date +%s)"; n=$(date +%s)
    ev="<event version=\"2.0\" uid=\"$uid\" type=\"a-f-G-U-C\" how=\"h-e\" time=\"$(date -u -d @$n +%Y-%m-%dT%H:%M:%S.000Z)\" start=\"$(date -u -d @$n +%Y-%m-%dT%H:%M:%S.000Z)\" stale=\"$(date -u -d @$((n+60)) +%Y-%m-%dT%H:%M:%S.000Z)\"><point lat=\"25.03\" lon=\"121.56\" hae=\"10\" ce=\"9999999\" le=\"9999999\"/><detail><contact callsign=\"$uid\"/><marti><dest callsign=\"dv-nobody\"/></marti></detail></event>"
    timeout 5 bash -c "exec 3<>/dev/tcp/$ip/8088; printf '%s' '$ev' >&3; sleep 2" 2>/dev/null
    echo "SENT $n rc=$?" ) > "$out" 2>&1 &
}

bchk_cleanstop_274() {   # a clean reboot stops the tenant GRACEFULLY (tiered, recorded) and the next boot STARTS it (no rebuild)
  # Asserts on the boot after a plain `reboot`:
  #  1 a payload-stop.log record for the PREVIOUS boot_id, also in that boot's shutdown_*.log; no final-tier
  #    (stateful: ots-db, rabbitmq) ExitCode 137/255 (SIGKILLed); an earlier tier's 137 is reported, not failed
  #  2 ots-db's LAST start says "database system was shut down at" (graceful), not crash recovery
  #  3 the same container IDs as before the reboot (not recreated — the feat/264 regression that broke fi-f1)
  #  4 the guardian logged "start mode" this boot, and StartedAt is non-decreasing in manifest order
  #  5 boot-to-ready (health gates passed: the guardian's "converge done ... uptime=") <= 90 s
  #    (control 1.5.4: 6 running at +63 s)
  # Negative controls: DV_TEST_274_NOSTOP=1 (K08/K09 stop links removed) must FAIL 1 (and 4: dockerd revives,
  # no start mode); DV_TEST_274_RMSTOP=1 (the stop removes the containers once, feat/264-style) must FAIL 3.
  local n=$1 rc=0 ids0 ids1 pb l r up codes c
  fssh "$n" 12 'ls /etc/init.d/batman-payload-* >/dev/null 2>&1 && [ -f /usr/lib/batman/payload-stop.sh ]' || { echo "FAIL no payload guardian / payload-stop.sh on this node"; return 1; }
  ots_ready "$n" || { echo "FAIL OTS not ready before the test"; return 1; }
  ids0=$(ots_ids "$n"); pb=$(bootid "$n" | cut -c1-8)
  if [ "${DV_TEST_274_NOSTOP:-0}" = 1 ]; then
    fssh "$n" 10 'for l in /etc/rc.d/K*batman-payload-* /etc/rc.d/K*batman-prestop-payload; do [ -e "$l" ] && mv "$l" /tmp/dv-274-klink.$(basename "$l"); done; ls /tmp/dv-274-klink.* 2>/dev/null'
    echo "NEGATIVE CONTROL: payload stop links removed for this reboot"
  fi
  if [ "${DV_TEST_274_RMSTOP:-0}" = 1 ]; then
    fssh "$n" 10 'mkdir -p /opt/batdata/state && : > /opt/batdata/state/fault.274-rmstop-once'
    echo "NEGATIVE CONTROL: the stop removes the containers once"
  fi
  # 6 (C1): a peer sends one CoT the moment 8088 accepts again after the reboot (as early as a field client)
  # 6 (C1): the host sends one CoT the moment 8088 accepts again after the reboot (as early as a field client)
  local pu pf
  pu="DV274E$(date +%Y%m%d%H%M%S)"; pf="$DIR/cleanstop-274.probe"
  cot_probe_274 "$n" "$pu" "$pf"; echo "early-CoT probe $pu started on the host (-> $n:8088)"
  reboot_and_wait "$n" reboot 240 || rc=1
  if [ "${DV_TEST_274_NOSTOP:-0}" = 1 ]; then   # the K links live on the overlay: put them back
    fssh "$n" 10 'for f in /tmp/dv-274-klink.*; do [ -e "$f" ] || continue; b=${f#/tmp/dv-274-klink.}; t=${b#K??}; ln -sf ../init.d/$t /etc/rc.d/$b; ls -l /etc/rc.d/$b; done' \
      || echo "FAIL could not restore the payload K links"
  fi
  [ "$rc" = 0 ] || return 1
  for r in $(seq 1 60); do ots_ready "$n" && break; sleep 5; done
  ots_ready "$n" || { echo "FAIL OTS not ready within 300 s after the reboot"; return 1; }
  # 1 stop record
  l=$(fssh "$n" 15 "grep 'boot=$pb ' /opt/batdata/log/payload-stop.log 2>/dev/null | tail -1" | tr -d '\r')
  if [ -z "$l" ]; then echo "FAIL 1 no payload-stop.log record for the previous boot $pb (the stop did not run)"; rc=1
  else
    echo "stop record: $l"
    # each K script gets its own 15 s from procd (then TERM): K08 (client tiers) and K09 (final tier + record)
    for k in k08 k09; do
      v=$(echo "$l" | sed -n "s/.* $k=\([0-9]*\)\.[0-9]s.*/\1/p")
      if isint "$v"; then [ "$v" -lt 15 ] && echo "ok 1 $k took ${v}.x s (< 15 s procd budget)" || { echo "FAIL 1 $k took ${v}.x s — over procd's 15 s per K script"; rc=1; }
      else echo "FAIL 1 no $k time in the stop record"; rc=1; fi
    done
    codes=${l#*exit: }
    for c in $codes; do case "$c" in
      ots-db=137|ots-db=255|rabbitmq=137|rabbitmq=255) echo "FAIL 1 final-tier container SIGKILLed: $c"; rc=1 ;;
      *=137|*=255) echo "NOTE 1 earlier-tier container killed after its grace: $c (reported, not failed)" ;;
    esac; done
    fssh "$n" 15 "grep -l 'stop: boot=$pb ' /opt/batdata/log/shutdown_*.log 2>/dev/null | tail -1" | grep -q . \
      && echo "ok 1 the record is in that boot's shutdown log" || { echo "FAIL 1 the stop record is not in any shutdown_*.log (stop ran after the shutdown capture?)"; rc=1; }
  fi
  # 2 postgres graceful
  l=$(fssh "$n" 15 'docker logs ots-db 2>&1 | grep -E "database system was shut down at|not properly shut down|was interrupted" | tail -1')
  echo "ots-db last start: ${l:-<none>}"
  case "$l" in *"shut down at"*) echo "ok 2 graceful postgres stop" ;; *) echo "FAIL 2 postgres was not stopped gracefully (crash recovery on start)"; rc=1 ;; esac
  # 3 same containers
  ids1=$(ots_ids "$n")
  if [ "$ids0" = "$ids1" ]; then echo "ok 3 same container IDs (started, not recreated)"
  else echo "FAIL 3 containers recreated:"; echo "  before: $(echo $ids0)"; echo "  after:  $(echo $ids1)"; rc=1; fi
  # 4 start mode, two phases (D2'): every final-tier service (no STOPTIER) started before any other container
  fssh "$n" 15 'logread | grep -q "payload-run\[opentakserver\]: start mode"' && echo "ok 4 guardian used start mode" || { echo "FAIL 4 no start-mode line this boot"; rc=1; }
  l=$(fssh "$n" 20 'm=$(ls /opt/batdata/apps/opentakserver/*.manifest | head -1); awk "\$1==\"CONTAINER\"{if(c!=\"\")print c, t; c=\$2; t=99} \$1==\"STOPTIER\"{t=\$2} END{print c, t}" "$m" | while read -r c t; do echo "$c $t $(docker inspect -f "{{.State.StartedAt}}" $c)"; done | awk "{ if (\$2 == 99) { if (\$3 > maxf) maxf = \$3 } else { if (minr == \"\" || \$3 < minr) { minr = \$3; mc = \$1 } } } END { if (minr != \"\" && minr < maxf) print \"bad=1 \" mc \" started \" minr \" before the last service \" maxf; else print \"bad=0\" }"' | tr -d '\r')
  case "$l" in bad=0*) echo "ok 4 services started before the rest (two-phase start)" ;; *) echo "FAIL 4 ${l#bad=1 }"; rc=1 ;; esac
  # 5 boot-to-ready
  up=$(fssh "$n" 15 'logread | grep "batman-payload\[opentakserver\]: converge done" | tail -1 | sed -n "s/.*uptime=\([0-9]*\).*/\1/p"' | tr -d ' \r')
  if isint "$up"; then
    echo "boot-to-ready: ${up} s uptime (SLO <= 90 s; control 1.5.4: 6 running at +63 s)"
    [ "$up" -le 90 ] || { echo "FAIL 5 boot-to-ready ${up} s > 90 s"; rc=1; }
  else echo "FAIL 5 no 'converge done' line this boot — boot-to-ready not measured"; rc=1; fi
  # 6 (#274 review C1) the clients do not depend on the opentakserver API: no container restarted during the
  # two-phase start, and a CoT sent the moment 8088 accepted (before the API gate, when the timing allows) is stored
  l=$(fssh "$n" 15 'm=$(ls /opt/batdata/apps/opentakserver/*.manifest | head -1); for c in $(awk "/^CONTAINER /{print \$2}" "$m"); do echo "$c=$(docker inspect -f "{{.RestartCount}}" $c)"; done' | tr '\r\n' '  ')
  echo "restart counts: $l"
  echo "$l" | grep -Eq '=[1-9]' && { echo "FAIL 6 a container restarted during the start (a dependency the two-phase start does not honour)"; rc=1; } || echo "ok 6 no container restarted"
  if [ -n "$pu" ]; then
    local po d04 bt sent i st
    for i in $(seq 1 30); do po=$(cat "$pf" 2>/dev/null); echo "$po" | grep -q '^SENT\|^NEVER' && break; sleep 3; done
    echo "probe: $(echo $po)"
    d02=$(date +%s); d04=$(fssh "$n" 10 'echo $(( $(date +%s) - $(cut -d. -f1 /proc/uptime) )) $(date +%s)' | tr -d '\r')
    bt=${d04%% *}; d04=${d04##* }
    sent=$(echo "$po" | sed -n 's/^SENT \([0-9]*\) rc=0$/\1/p')
    if isint "$sent" && isint "$d02" && isint "$bt" && isint "$up"; then
      sent=$(( sent + d04 - d02 - bt ))   # the host's send time on the OTS node's uptime axis (+-2 s: two clocks)
      if [ "$sent" -lt $((up - 3)) ]; then echo "ok 6 CoT sent at +${sent} s, before the API gate passed (+${up} s)"
      else echo "NOTE 6 8088 accepted only at +${sent} s, API gate at +${up} s — before-API delivery not exercised this run"; fi
      st=0; for i in $(seq 1 12); do st=$(echo "select count(*) from cot where uid='$pu';" | ots_sql "$n" | tr -d ' \r'); [ "$st" = 1 ] && break; sleep 5; done
      [ "$st" = 1 ] && echo "ok 6 the early CoT was stored" || { echo "FAIL 6 the early CoT ($pu) was not stored (count=$st)"; rc=1; }
      ots_sql "$n" <<SQL >/dev/null
begin; delete from euds where uid like '$pu%'; delete from cot where uid like '$pu%'; commit;
SQL
    else echo "FAIL 6 early-CoT probe did not send (probe: $(echo $po))"; rc=1; fi
  fi
  return $rc; }

bchk_converge_274() {   # the guardian converges a CHANGED config by a graceful rebuild and leaves an unchanged one alone (#274)
  # No reboot. On the OTS node: (a) guardian restart, nothing changed -> same container IDs; (b) a comment appended
  # to the p6 manifest -> restart -> every container recreated with the new fingerprint; (c) a comment appended to
  # the MOUNTED rabbitmq-extra.conf (a real mount-content case) -> recreated again; (d) both restored from the
  # golden -> recreated with the ORIGINAL fingerprint, verdict OK. Postgres never crash-recovers (rebuilds stop
  # gracefully before removing).
  local n=$1 rc=0 g=/etc/init.d/batman-payload-opentakserver D=/opt/batdata/apps/opentakserver GD=/usr/share/batman/payload-golden/opentakserver
  local cfg0 cfg ids0 ids man l pg
  fssh "$n" 10 "[ -x $g ] && [ -d $GD ]" || { echo "FAIL no guardian / golden on this node"; return 1; }
  ots_ready "$n" || { echo "FAIL OTS not ready before the test"; return 1; }
  man=$(fssh "$n" 10 "ls $D/*.manifest | head -1" | tr -d '\r')
  cfg0=$(fssh "$n" 30 'payload-run --cfg-hash opentakserver' | tr -d '\r'); ids0=$(ots_ids "$n")
  c274_restart() { local l0; l0=$(conv_last "$n"); fssh "$n" 90 "$g restart" >/dev/null 2>&1
    wait_converge "$n" "$l0" 400 || { echo "FAIL $1: the guardian did not converge within 400 s"; return 1; }; }
  c274_check() {   # $1 ids before, $2 step, $3 expected fingerprint
    local ids1 lab x
    ids1=$(ots_ids "$n")
    lab=$(fssh "$n" 20 "for c in \$(awk '/^CONTAINER /{print \$2}' $man); do docker inspect -f '{{index .Config.Labels \"batman.cfg\"}}' \$c; done | sort -u" | tr -d '\r')
    for x in $(echo "$1" | awk '{print $2}'); do echo "$ids1" | grep -q " $x\$" && { echo "FAIL $2 container $x survived (not recreated)"; return 1; }; done
    [ "$lab" = "$3" ] || { echo "FAIL $2 labels [$lab] != fingerprint [$3]"; return 1; }
    echo "ok $2 every container recreated with fingerprint $(echo "$3" | cut -c1-12)"; }
  # (a)
  c274_restart a || return 1
  ids=$(ots_ids "$n"); [ "$ids" = "$ids0" ] && echo "ok a unchanged config: restart kept the same containers" || { echo "FAIL a containers recreated on an unchanged config"; rc=1; }
  # (b)
  fssh "$n" 10 "echo '# dv-274 converge test' >> $man"
  cfg=$(fssh "$n" 30 'payload-run --cfg-hash opentakserver' | tr -d '\r')
  [ "$cfg" != "$cfg0" ] || { echo "FAIL b fingerprint did not change"; rc=1; }
  c274_restart b && c274_check "$ids0" b "$cfg" || rc=1; ids=$(ots_ids "$n")
  # (c)
  fssh "$n" 10 "echo '# dv-274 converge test' >> $D/rabbitmq-extra.conf"
  cfg=$(fssh "$n" 30 'payload-run --cfg-hash opentakserver' | tr -d '\r')
  c274_restart c && c274_check "$ids" c "$cfg" || rc=1; ids=$(ots_ids "$n")
  # (d)
  fssh "$n" 10 "cp -p $GD/$(basename "$man") $man && cp -p $GD/rabbitmq-extra.conf $D/rabbitmq-extra.conf"
  cfg=$(fssh "$n" 30 'payload-run --cfg-hash opentakserver' | tr -d '\r')
  [ "$cfg" = "$cfg0" ] || { echo "FAIL d restored fingerprint $cfg != original $cfg0"; rc=1; }
  c274_restart d && c274_check "$ids" d "$cfg0" || rc=1
  ots_ready "$n" || { echo "FAIL OTS not ready at the end"; rc=1; }
  sleep 35; l=$(fssh "$n" 10 'cat /tmp/batman-payload-opentakserver-drift.json' | tr -d '\r'); echo "verdict: $l"
  case "$l" in *'"status":"OK"'*) ;; *) echo "FAIL verdict not OK after convergence"; rc=1 ;; esac
  # the rebuilds removed the old ots-db only after a graceful stop: the current one started from a clean shutdown
  pg=$(fssh "$n" 15 'docker logs ots-db 2>&1 | grep -E "database system was shut down at|not properly shut down|was interrupted" | tail -1')
  case "$pg" in *"shut down at"*) echo "ok postgres: clean shutdown before the last rebuild" ;; *) echo "FAIL postgres last start: ${pg:-<none>}"; rc=1 ;; esac
  return $rc; }

if [ "$FEATURE_MODE" = --destructive ]; then
  if fssh "$DNODE" 8 '[ "$(cat /sys/class/net/eth0/carrier 2>/dev/null)" = 1 ]'; then
    # rejoin FIRST (#268 A7): the three below reboot DNODE, and a just-rebooted DNODE may be the host's only
    # way into the mesh. Tier A never reboots DNODE.
    suite rejoin-245-246 "mesh peer (re)join does not panic peers (#245) and the leaver does not rtnl-hang (#246), destructive" "bchk_rejoin_245 $DNODE" D
    suite faketime-174 "offline clock moves only forward across a reboot: shutdown save + boot restore happened (#174, destructive)" "bchk_174 $DNODE" D
    if [ "$(soc_of "$DNODE")" = bcm2710 ]; then
      na guardian-192 "DNODE $DNODE is a Pi 3: it carries no tenant/guardian by design (#209 D6)"
    else
      suite guardian-192 "guardian auto-restores after an overlay-clear+reboot (#192, destructive)"     "bchk_192 $DNODE" D
    fi
    suite ramoops-173  "kernel panic captured to pstore and classified PANIC (#173/#61, destructive)"  "bchk_173 $DNODE" D
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
    for s in faketime-174 guardian-192 ramoops-173 rejoin-245-246; do suite "$s" "DNODE $DNODE has no ethernet — destructive refused (no out-of-band recovery)" ""; done
  fi
  # #274 runs on the OTS node (the only one with a tenant), NOT behind DNODE's ethernet gate: a plain, clean
  # reboot and guardian restarts are the node's normal life and never touch the mesh config, so they need no
  # out-of-band recovery. reboot_and_wait FAILs if the node does not return.
  # ramoops-173 just panicked DNODE, which may be the host's only way into the mesh: WAIT for the OTS node
  # (as soak_ready does) instead of a one-shot `up` — 2026-10-08 an `up` here found 03 still booting and
  # skipped both #274 suites.
  if [ "$OTS_SOC" = bcm2710 ]; then
    na cleanstop-274 "OTS_NODE $OTS_NODE is a Pi 3: no tenant/guardian by design (#209 D6)"
    na converge-274 "OTS_NODE $OTS_NODE is a Pi 3: no tenant/guardian by design (#209 D6)"
  elif dwait "$OTS_NODE" 300; then
    suite converge-274 "guardian converges a changed manifest / mounted file by a graceful rebuild, leaves an unchanged stack alone, restores to the golden fingerprint (#274, destructive)" "bchk_converge_274 $OTS_NODE" D
    suite cleanstop-274 "clean reboot: tiered graceful stop recorded before the shutdown capture, postgres clean, same containers started in order, boot-to-ready <= 90 s (#274, destructive)" "bchk_cleanstop_274 $OTS_NODE" D
  else   # not back within 300 s after the destructive tier = a real finding, never a SKIP (#274 review C6)
    suite converge-274 "guardian converges a changed config (#274) — OTS node unreachable" "echo 'FAIL OTS_NODE $OTS_NODE not reachable within 300 s after the destructive tier'; false"
    suite cleanstop-274 "clean reboot stop/start (#274) — OTS node unreachable" "echo 'FAIL OTS_NODE $OTS_NODE not reachable within 300 s after the destructive tier'; false"
  fi
fi

# ---- #263 driver race under fault injection (release gate) ----
if [ "$AB_MODE" != --destructive ]; then
  suite halow-fi-263 "mm6108 command race under fault injection (#263) — release gate, needs AB_MODE=--destructive" ""
elif [ -z "${DV_T263_KO:-}" ]; then
  suite halow-fi-263 "mm6108 command race under fault injection (#263) — DV_T263_KO unset: build the FI module for this image (firmware scripts/build-debug-mm6108-fi.sh)" ""
else
  suite halow-fi-263 "patched mm6108 driver survives the #263 race driven by fault injection (no WARN/Oops, responses delivered, 20/20 after), on ${DV_T263_NODE:-$BENCH_NODE} (DESTRUCTIVE)" "bchk_fi_263 ${DV_T263_NODE:-$BENCH_NODE} $DV_T263_KO" D
fi

# ---- release-gate load soak (#268 B3) ----
# Tier B just rebooted (and panicked) DNODE, which may be the host's only way into the mesh: wait for every
# soak node to answer again before deciding it is unavailable (2026-10-07: an `up` right after ramoops-173
# found 03 still booting and skipped the whole soak).
soak_ready() { local n miss=""; for n in $(soak_nodes); do dwait "$n" 300 || miss="$miss $n"; done; SOAK_MISS=${miss# }; [ -z "$miss" ]; }
SOAK_MISS=""
if [ "$AB_MODE" != --destructive ]; then
  suite load-soak "${SOAK_MIN}-min three-node load soak (daemon memory, MemAvailable, restarts/OOM, HTTP, CoT) — release gate, needs AB_MODE=--destructive" ""
elif [ "$BENCH_NODE" = "$OTS_NODE" ]; then
  suite load-soak "load soak (#268 B3) — BENCH_NODE == OTS_NODE: the CoT generator must be a different node" ""
elif ! soak_ready; then
  suite load-soak "load soak (#268 B3) — node(s) [$SOAK_MISS] did not answer within 300 s" ""
else
  suite soak-run        "${SOAK_MIN}-min load on $(soak_nodes): HTTP tenant + GETs local/mesh, CoT 5/s into OTS; setup and cleanup must succeed (#268 B3)" "chk_soak_run"
  suite soak-daemon-mem "dockerd/containerd/shims RSS: last 10 min <= first 10 min x1.15 + 8 MB, every node (leak)" "chk_soak_mem"
  suite soak-memavail   "MemAvailable never below 85% of the post-warm-up baseline, every node" "chk_soak_avail"
  suite soak-containers "no container restart and no cgroup oom_kill during the soak, every node" "chk_soak_ctr"
  suite soak-http-local "HTTP tenant answered every local GET (container stack)" "chk_soak_http local"
  suite soak-http-mesh  "HTTP tenant answered every GET over the mesh (container + radio; judged separately)" "chk_soak_http mesh"
  suite soak-cot-264    "CoT sent == stored over the soak (#264 mechanisms A and B both in play)" "chk_soak_cot"
fi

# ---- NEW vs KNOWN failures (#268 C1) ----------------------------------------------------------------
# A failed suite is KNOWN only if every "FAIL ..." line in its log matches a pattern listed for it in
# scripts/validation-known-failures.txt. No FAIL lines (a free-form check) = NEW. These can never be known,
# whatever the list says: a node left degraded, a cleanup that failed, a dropped connection, a reboot that
# did not happen, anything unreadable. The exit status is NOT affected — a known failure is still a failure.
KNOWN_FILE="$REPO/scripts/validation-known-failures.txt"
NEVER_KNOWN='restore|cleanup|CONNECTION-LOST|CONNLOST|reboot did not happen|unreadable|not verified|rc=3 without'
NEWF=(); KNOWNF=()
classify() {   # $1 suite -> echoes "known <issues>" or "new <why>"
  local s=$1 log="$DIR/$1.log" line pat iss hit issues="" st ks
  local lines; lines=$(grep -E '^[[:space:]]*FAIL ' "$log" 2>/dev/null | sed 's/^[[:space:]]*//')
  [ -n "$lines" ] || { echo "new (no FAIL lines to match)"; return; }
  while IFS= read -r line; do
    echo "$line" | grep -qE "$NEVER_KNOWN" && { echo "new (never-known failure: $line)"; return; }
    hit=""
    while IFS=$'\t' read -r ks pat iss; do
      case "$ks" in ''|'#'*) continue;; esac
      [ "$ks" = "$s" ] && [ -n "$iss" ] && echo "$line" | grep -qE -- "$pat" && { hit=$iss; break; }
    done < "$KNOWN_FILE"
    [ -n "$hit" ] || { echo "new (unmatched: $line)"; return; }
    case " $issues " in *" #$hit "*) ;; *) issues="$issues #$hit";; esac
  done <<< "$lines"
  if command -v gh >/dev/null 2>&1; then
    for iss in $issues; do st=$(gh issue view "${iss#\#}" -R winson3QQ/Batman --json state --jq .state 2>/dev/null)
      [ "$st" = CLOSED ] && { echo "new (matches $iss, but $iss is CLOSED)"; return; }
      [ -z "$st" ] && issues="$issues(state?)"; done
  else issues="$issues (issue state not checked: no gh)"; fi
  echo "known$issues"; }
for s in "${FAILED[@]}"; do
  c=$(classify "$s")
  case "$c" in known*) KNOWNF+=("| $s | ${c#known } |");; *) NEWF+=("| $s | ${c#new } |");; esac
done

{
  echo "# Batman daily validation — $(date -Is)"
  echo
  if [ "$DV_BRANCH" != main ] || [ "${DV_DIRTY:-0}" != 0 ]; then
    echo "> ⚠️ **NOT THE CANONICAL HARNESS** — run from \`$REPO\` on \`$DV_BRANCH\` @ \`$DV_COMMIT\` (uncommitted changes under scripts/: ${DV_DIRTY:-?}). Valid for that branch only."
    echo
  fi
  [ -n "$DV_ONLY" ] && { echo "> ⚠️ **PARTIAL RUN** — only suites matching \`DV_ONLY=$DV_ONLY\`; everything else is SKIP (not selected)."; echo; }
  echo "**$NPASS passed, $NFAIL failed, $NSKIP skipped, $NNA not applicable (by SoC, listed with reason)**"
  echo
  echo "| suite | result | notes |"
  echo "|---|---|---|"
  printf '%s\n' "${ROWS[@]}"
  echo
  if [ "${#FAILED[@]}" -gt 0 ]; then
    echo "## FAIL — NEW (${#NEWF[@]})"; echo
    if [ "${#NEWF[@]}" -gt 0 ]; then echo "| suite | why it is new |"; echo "|---|---|"; printf '%s\n' "${NEWF[@]}"; else echo "(none)"; fi
    echo; echo "## FAIL — known, tracked (${#KNOWNF[@]}) — still failures; the exit status counts them"; echo
    if [ "${#KNOWNF[@]}" -gt 0 ]; then echo "| suite | issue |"; echo "|---|---|"; printf '%s\n' "${KNOWNF[@]}"; else echo "(none)"; fi
    echo
  fi
  echo "Host: \`$(hostname)\`  ·  bench: \`$BENCH_NODE\` (\`$AB_MODE\`)  ·  mesh: \`$MESH_NODE\`"
  echo "Repo: \`$DV_COMMIT\` on \`$DV_BRANCH\` (\`$REPO\`)"
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
