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

# 2c. No hardware needed: nothing that runs as root on a node trusts world-writable /tmp (#280) — the static
#     allowlist check, and its mutation proof (every bypass form must be caught).
# the mutation proofs make git temp repos: under Git Bash (MSYS) they hang (2026-10-15, twice: case 3 / case 23;
# in WSL 26/26 twice), so a //wsl.localhost repo is checked INSIDE its distro; a hang is a FAIL (timeout), never a stall
chk_tmp_trust_static() { local d p
  case "$(uname -o 2>/dev/null)" in
    Msys) if command -v wsl.exe >/dev/null 2>&1; then case "$REPO" in //wsl.localhost/*)
            d=${REPO#//wsl.localhost/}; p=/${d#*/}; d=${d%%/*}
            echo "MSYS: delegated to WSL distro $d, repo $p"
            timeout 900 wsl.exe -d "$d" -- bash -c "cd '$p' && bash scripts/check-tmp-trust.sh && bash scripts/test-tmp-trust.sh"; return ;;
          esac; fi ;;
  esac
  timeout 900 bash "$REPO/scripts/check-tmp-trust.sh" && timeout 900 bash "$REPO/scripts/test-tmp-trust.sh"; }
suite tmp-trust-static   "no decision state / root-executed file in world-writable /tmp on the node; per-hit allowlist, path table, wiring checks + mutation proofs (#280)"   "chk_tmp_trust_static"

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
  r4) echo "held healthy trial nobody releases is reverted at the deadline (#261)";;
  s1) echo "ota-start-274: after a same-build OTA every container starts once, in order, by the guardian — no DRIFT, postgres clean (#274)";;
  c1) echo "trial-crash-274: a crash in a held trial reverts it even after release (#274 §12.13)";;
  c2) echo "trial-crash-274: a manual batman-slot commit after a crash in the trial stands (#274 §12.13)";; esac; }
FI_CASES="f2 f1 r2 r1 r3 r4 s1 c1 c2"
fi_skip_all(){ local c; for c in $FI_CASES; do suite "fi-$c" "fault-injection $c (#159/#216/#274) — $1" ""; done; }
if [ "$OTS_SOC" = bcm2710 ]; then
  suite ots-node-209 "OTS_NODE must be the bcm2711 OTS host" "echo 'OTS_NODE $OTS_NODE is a Pi 3 (bcm2710); OTS is not shipped there (#209 D6). Set OTS_NODE to the Pi 4 OTS host.'; false"
  fi_skip_all "OTS_NODE $OTS_NODE is bcm2710 — OTS suites not run (see ots-node-209)"
elif [ "$AB_MODE" != --destructive ]; then
  fi_skip_all "needs AB_MODE=--destructive"
elif up "$OTS_NODE"; then
  for c in $FI_CASES; do
    suite "fi-$c" "fault-injection $c: $(fi_desc $c) (DESTRUCTIVE)" "$REPO/scripts/fault-injection.sh $OTS_NODE --case $c" D
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
# #289: the OTS stack is 6 containers on the overlay build (two eud_handler listeners) and 5 on the gateway build
# (ots_eud_gateway). Both the expected count and which EUD implementation runs come from the NODE (its manifest and
# its containers), never from this script's idea of the build: ots_probe sets OTS_N / OTS_EUD once per run.
OTS_N=${OTS_N:-6}; OTS_EUD=${OTS_EUD:-overlay}
ots_probe() { local o
  o=$(fssh "$1" 20 'm=$(ls /opt/batdata/apps/opentakserver/*.manifest 2>/dev/null | head -1); echo "$(awk '"'"'$1=="CONTAINER"{n++} END{print n+0}'"'"' "$m" 2>/dev/null) $(docker ps --format "{{.Names}}" 2>/dev/null | grep -c "^ots_eud_gateway$")" 2>/dev/null' | tr -d '\r')
  isint "${o%% *}" && [ "${o%% *}" -gt 0 ] && OTS_N=${o%% *}
  [ "${o##* }" = 1 ] && OTS_EUD=gateway || OTS_EUD=overlay
  echo "OTS stack on $1: $OTS_N containers, EUD implementation = $OTS_EUD"; }
# #280 node-side snippets. RDR resolves where the node keeps its decision state: the root-only run dir on an
# image that ships rundir.sh (missing there = FAIL, never a fall back to /tmp names anyone can plant), /tmp on
# an older image (version-tolerant harness). HDS = the harness's own scratch dir on the node: under /tmp/run
# (root 0755 on every OpenWrt image), so no non-root process can pre-create or rewrite what root runs from it.
RDR='R=/tmp; if [ -r /usr/lib/batman/rundir.sh ]; then R=/tmp/run/batman; [ -d "$R" ] || { echo "FAIL run dir $R missing on a #280 image"; exit 1; }; fi; '
HDS='H=/tmp/run/batman-dv; { [ -d "$H" ] || mkdir -m 700 "$H"; } && [ -O "$H" ] && [ ! -L "$H" ] || { echo "FAIL harness scratch $H unusable"; exit 1; }; '
HD=/tmp/run/batman-dv

# ---- tier A: non-destructive, real ----
# #216: resolve the OTS tenant dir — flash-and-go / #167 uses /opt/batdata/apps/opentakserver;
# manually-provisioned nodes used /opt/batdata/deploy/ots. Prefer apps/, fall back to deploy/ots.
# confinement-98 inspects 9 axes x6. The wrapper exits 0 when nothing DRIFTs — also when containers were
# UNKNOWN (skipped). Right for the #156 reconciler (never alarm on what it could not judge), wrong for a
# test: six UNKNOWNs verify nothing and still exit 0 (#269). So the verdict comes from its summary line:
# all six must be OK; UNKNOWN (mid-restart / too fresh) is retried, and still UNKNOWN = not verified = FAIL.
OTS_CTR_N=6   # #289: ots_probe sets it to the node's manifest count (OTS_N) before the OTS suites run
vp_ots_verdict() {   # stdin: wrapper output -> rc 0 all OK / 1 FAIL / 2 retry (UNKNOWN present)
  local s ok dr un
  s=$(sed -n 's/^verify-profile-ots: ok=\([0-9]*\) drift=\([0-9]*\) unknown=\([0-9]*\)$/\1 \2 \3/p' | tail -1)
  read -r ok dr un <<< "$s"
  { isint "$ok" && isint "$dr" && isint "$un"; } || { echo "FAIL no verify-profile-ots summary line — confinement not verified"; return 1; }
  [ "$dr" = 0 ] || { echo "FAIL $dr container(s) DRIFT from their hardening profile"; return 1; }
  [ "$un" = 0 ] || { echo "UNKNOWN $un container(s)"; return 2; }
  [ "$ok" = "${OTS_N:-$OTS_CTR_N}" ] || { echo "FAIL only $ok/${OTS_N:-$OTS_CTR_N} containers judged OK"; return 1; }
  echo "ok: $ok/${OTS_N:-$OTS_CTR_N} containers match their hardening profile"; }
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
  m=$(ls /opt/batdata/apps/opentakserver/*.manifest 2>/dev/null | head -1); want=$(awk '"'"'$1=="CONTAINER"{n++} END{print n+0}'"'"' "$m" 2>/dev/null)
  n=0; for c in $(awk '"'"'$1=="CONTAINER"{print $2}'"'"' "$m" 2>/dev/null); do
    [ "$(docker inspect -f "{{.State.Running}}" "$c" 2>/dev/null)" = true ] && n=$((n+1)); done
  db=$(docker exec ots-db psql -U ots -d ots -tAc "select 1" 2>/dev/null | tr -d " ")
  echo "running=$n/$want (manifest) postgres=$db"; [ "$want" -gt 0 ] && [ "$n" = "$want" ] && [ "$db" = 1 ]'; }
chk_156() { fssh "$1" 45 "$HDS"'
  d=/opt/batdata/apps/opentakserver; [ -f "$d/verify-profile.sh" ] || d=/opt/batdata/deploy/ots   # #216: apps/ (flash-and-go) or deploy/ots
  [ -f "$d/verify-profile.sh" ] || { echo "verify-profile.sh not found in apps/ or deploy/ots"; exit 2; }   # do not let a missing file masquerade as DRIFT
  docker rm -f dv-decoy >/dev/null 2>&1
  docker run -d --name dv-decoy --entrypoint sleep batman/ots:1.7.13-arm64 90 >/dev/null 2>&1 || { echo "FAIL decoy start failed"; exit 1; }
  # clear verify-profile MIN_UPTIME=15 (else UNKNOWN, not DRIFT). DV_TEST_156_NOWAIT=1 = negative control:
  # judge a too-fresh decoy, which must end as "not verified", never as a pass.
  [ "'"${DV_TEST_156_NOWAIT:-0}"'" = 1 ] && w=0 || w=18; sleep $w
  sh "$d/verify-profile.sh" dv-decoy "$d/ots.hardening.env" >"$H/dv-vp" 2>&1; rc=$?
  # UNKNOWN (3) = verify-profile could not judge (too fresh, inspect failed): retry once (#269)
  [ "$rc" = 3 ] && [ "$w" != 0 ] && { sleep 10; sh "$d/verify-profile.sh" dv-decoy "$d/ots.hardening.env" >"$H/dv-vp" 2>&1; rc=$?; }
  docker rm -f dv-decoy >/dev/null 2>&1
  echo "unhardened decoy -> verify-profile rc=$rc (1 = DRIFT detected; 0 OK, 2 usage, 3 UNKNOWN are failures)"
  # only DRIFT (1) proves the reconciler sees an unhardened container. `-ne 0` used to pass rc 2 and 3 (#269).
  case $rc in 1) exit 0 ;; 3) echo "FAIL decoy UNKNOWN — DRIFT detection not verified"; tail -3 "$H/dv-vp"; exit 1 ;;
    0) echo "FAIL unhardened decoy judged OK — DRIFT NOT detected"; exit 1 ;; *) echo "FAIL verify-profile rc=$rc (usage/error)"; tail -3 "$H/dv-vp"; exit 1 ;; esac'; }
chk_167g() { fssh "$1" 20 "$RDR"'
  # OTS runs on the GENERIC payload manager (#167), not the bespoke run.sh/batman-ots: the generic
  # guardian owns it, the old guardian is gone (double-guardian regression), and drift reads OK.
  command -v payload-run >/dev/null 2>&1 || { echo "payload-run not installed (pre-image-bake #159)"; exit 1; }
  [ -x /etc/init.d/batman-payload-opentakserver ] || { echo "generic guardian init missing"; exit 1; }
  [ -e /etc/init.d/batman-ots ] && { echo "old batman-ots still present -> double-guardian risk"; exit 1; }
  st=$(sed -n "s/.*\"status\":\"\([A-Z]*\)\".*/\1/p" "$R/batman-payload-opentakserver-drift.json" 2>/dev/null | head -1)
  echo "generic guardian drift=$st (old batman-ots absent)"; [ "$st" = OK ]'; }
chk_167a() { fssh "$1" 20 '
  # white-box: the port/zone arbiter REFUSES a colliding tenant (host-port clash) with exit 3.
  command -v payload-arbiter >/dev/null 2>&1 || { echo "payload-arbiter not installed (pre-image-bake #159)"; exit 1; }
  T=$(mktemp -d); mkdir -p "$T/ots" "$T/dup"
  printf "TENANT=opentakserver\nPORTS=8088 8089 8443\nSUBNET=172.20.0.0/24\nZONE=dockert\nBRIDGE=br-ots\n" > "$T/ots/ots.net.alloc"
  printf "TENANT=dup\nPORTS=8088\nSUBNET=172.20.9.0/24\nZONE=dupz\nBRIDGE=br-dup\n" > "$T/dup/dup.net.alloc"
  payload-arbiter "$T/dup/dup.net.alloc" "$T" >"$T/arb.out" 2>&1; rc=$?
  rm -rf "$T"
  echo "colliding tenant (:8088) -> arbiter rc=$rc (want 3=REFUSED)"; [ "$rc" = 3 ]'; }
chk_golden() { fssh "$1" 30 '                                  # payload-config-golden.md
  # For each baked golden tenant that is PROVISIONED on this node: (1) p6 config == baked golden per
  # file, (2) every live container has RestartPolicy no (#274 §12 D7-1: the guardian is the only restarter;
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
      [ "$rp" = no ] || { echo "$t/$c restart=${rp:-MISSING} (want no — #274)"; rc=1; }; done
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
    names=$(awk "/^CONTAINER /{print \$2}" "$man" | tr "\n" " "); c=""; img=""
    while read -r k v; do
      case "$k" in
        CONTAINER) c=$v
          s=$(docker inspect -f "{{.State.Status}} {{.State.Restarting}} {{index .Config.Labels \"batman.cfg\"}} {{index .Config.Labels \"batman.tenant\"}}" "$c" 2>/dev/null)
          [ "$s" = "running false $want $t" ] || { echo "FAIL $t/$c [status restarting cfg tenant]=[$s] want [running false $want $t]"; rc=1; } ;;
        IMAGE) img=$v ;;
        MOUNT) src=${v%%:*}; r=${v#*:}; dst=${r%%:*}; rw=true; case "$v" in *:ro) rw=false ;; esac
          case "$src" in /*) ;; *) src="$d$src"; [ -f "$src" ] || { echo "FAIL $t/$c mount source $src is not a regular file"; rc=1; } ;; esac
          m=$(docker inspect -f "{{range .Mounts}}{{if eq .Destination \"$dst\"}}{{.Source}} {{.RW}}{{end}}{{end}}" "$c" 2>/dev/null)
          [ "$m" = "$src $rw" ] || { echo "FAIL $t/$c mount $dst = [$m] want [$src $rw]"; rc=1; }
          # #264: what the process actually reads at $dst is the p6 overlay, byte for byte (not a stale pyc, not the image file)
          case "$src" in */EudHandler-264.py)
            hs=$(sha256sum < "$src" | cut -d" " -f1); hc=$(docker exec "$c" sha256sum "$dst" 2>/dev/null | cut -d" " -f1)
            [ -n "$hc" ] && [ "$hc" = "$hs" ] && echo "$t/$c #264 overlay in the container == p6 source (${hs%${hs#????????}}...)" \
              || { echo "FAIL $t/$c $dst in the container is sha256 [${hc:-unreadable}], the p6 overlay is $hs"; rc=1; }
            # which #264 items the overlay carries (the module-level BATMAN_264 string), read where the process reads it
            items=$(docker exec "$c" sed -n "s/^BATMAN_264 = \"\([^\"]*\)\".*/\1/p" "$dst" 2>/dev/null)
            want_items=$(sed -n "s/^BATMAN_264 = \"\([^\"]*\)\".*/\1/p" "$src")
            [ -n "$items" ] && [ "$items" = "$want_items" ] && echo "$t/$c #264 overlay items: $items" \
              || { echo "FAIL $t/$c $dst item list [$items] != p6 overlay [$want_items]"; rc=1; } ;;
          esac ;;
        MOUNTSHA) dst=${v%% *}; want_sha=${v#* }
          # #264 R8: the image own (unmounted) file at $dst is still the upstream file the overlay was made for.
          # docker create + cp: nothing executes; the allowlist flags keep the guardian foreign scan quiet.
          k2=$(docker create --pull=never --network none --security-opt no-new-privileges "$img" 2>/dev/null)
          h=$( { docker cp "$k2:$dst" - 2>/dev/null | tar -xO 2>/dev/null; } | sha256sum | cut -d" " -f1); docker rm "$k2" >/dev/null 2>&1
          [ "$h" = "$want_sha" ] && echo "$t/$c image $img own $dst == MOUNTSHA (${h%${h#????????}}...)" \
            || { echo "FAIL $t/$c image $img own $dst sha256 $h != MOUNTSHA $want_sha (the overlay was made for a different file)"; rc=1; } ;;
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
  # Floor 1500 (was 3000, #265 full run 2026-10-08): over 16 runs 10/06-10/08 on healthy links (iperf 8529-9275
  # Kbps every time) the tp median ranged 2459-6552 across 1.5.1/1.5.4/1.5.5/1.5.6 — 3000 sat INSIDE the healthy
  # spread and false-FAILed at random. 1500 still catches a dead link / MCS collapse; the real throughput gate
  # is mesh-tput-iperf (band 4000..30000).
  FLOOR=${TPUT_FLOOR_KBPS:-1500}
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
  fssh "$srv" 12 "$HDS p=\$(cat $HD/iperf-s.pid 2>/dev/null); [ -n \"\$p\" ] && grep -qs iperf \"/proc/\$p/cmdline\" && kill \"\$p\" 2>/dev/null; setsid sh -c 'echo \$\$ >$HD/iperf-s.pid; exec iperf -s -p $port -f k' >$HD/iperf-s.log 2>&1 </dev/null & sleep 1"
  # confirm the sink actually bound — iperf -s exits immediately if the port is already in use
  fssh "$srv" 8 "p=\$(cat $HD/iperf-s.pid 2>/dev/null); kill -0 \"\$p\" 2>/dev/null" \
    || { echo "iperf sink failed to start on $srv (port $port busy?)"; fssh "$srv" 8 "rm -f $HD/iperf-s.pid $HD/iperf-s.log" 2>/dev/null; return 1; }
  local kbps
  kbps=$(fssh "$cli" $((dur+25)) "iperf -c $srv -p $port -f k -t $dur 2>/dev/null | awk '/Kbits\/sec/{v=\$(NF-1)} END{printf \"%d\", v}'")
  fssh "$srv" 10 "p=\$(cat $HD/iperf-s.pid 2>/dev/null); [ -n \"\$p\" ] && grep -qs iperf \"/proc/\$p/cmdline\" && kill \"\$p\" 2>/dev/null; rm -f $HD/iperf-s.pid $HD/iperf-s.log"
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
chk_slotintegrity_209() { fssh "$1" 20 "$RDR"'                       # #209 S5: Pi 4 EEPROM boots the wrong slot
  # The Pi 4 bootloader (EEPROM 2026-09-23) may read raw PM_RSTS as the reboot partition after a
  # partition-0 restart and walk to p1 (docs/design/explicit-reboot.md). The node must have the tool and
  # the K90 hook for explicit restarts, must not be running on a wrongly-booted slot now, must not be
  # stuck in correcting restarts, and both slots must carry the boot-time self-check.
  case "$(cat /proc/device-tree/compatible 2>/dev/null)" in *bcm2711*) ;; *) echo "Pi 3: no EEPROM bootloader, the bug is Pi 4 only — n/a"; exit 0 ;; esac
  [ -x /usr/sbin/batman-reboot ] || { echo "batman-reboot missing"; exit 1; }
  [ -e /etc/rc.d/K90batman-reboot ] || { echo "K90batman-reboot hook not enabled"; exit 1; }
  [ -f "$R/batman-fw-override" ] && { echo "the firmware booted the WRONG slot this boot: $(cat "$R/batman-fw-override")"; exit 1; }
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
  # #280 review 4 #2: an OTA run by a #280 stage 2 records the ramfs root; it must be the root-only run dir
  rf=$(grep " boot=$b .* S2 BEGIN " "$f" | tail -n 1 | sed -n "s/.* ramfs=\([^ ]*\).*/\1/p")
  s1=$(grep " boot=$b .* S1 CHECK .*caller=/sbin/procd" "$f" | tail -n 1 | sed -n "s/.* ramroot=\([^ ]*\).*/\1/p")
  [ -n "$s1" ] && [ -z "$rf" ] && { echo "last OTA: #280 stage 1 (ramroot=$s1) but stage 2 wrote no ramfs= — not the #280 stage 2"; exit 1; }
  case "$rf" in "") rr="(pre-#280 stage 2: no ramfs field)";; /run/batman/ramroot) rr="ramfs=$rf";;
    *) echo "last OTA ramfs root is $rf, not /run/batman/ramroot — RAM_ROOT not in the run dir"; exit 1;; esac
  echo "last OTA (stage-2 boot $b): S2 END ${e#* S2 END } $rr"'; }
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
  fssh "$n" 10 "$HDS"'echo ok' >/dev/null || { echo "FAIL harness scratch dir on $n unusable"; return 1; }
  scp -q -o BatchMode=yes -o LogLevel=ERROR "$ko" "root@$n:$HD/mm6108_sdio-dvfi.ko" && \
  scp -q -o BatchMode=yes -o LogLevel=ERROR "$REPO/scripts/node/halow-fi-263.sh" "root@$n:$HD/halow-fi-263.sh" || { echo "FAIL could not stage the module/script on $n"; return 1; }
  b0=$(bootid "$n"); [ -n "$b0" ] || { echo "FAIL boot_id unreadable — not verified"; return 1; }
  fssh "$n" 10 "KO=$HD/mm6108_sdio-dvfi.ko setsid sh $HD/halow-fi-263.sh </dev/null >/dev/null 2>&1 & echo launched" || { echo "FAIL could not launch"; return 1; }
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
  d=$(mktemp -d) || exit 1; mkdir -p $d/rootfs/bin $d/rootfs/lib
  cp /bin/busybox $d/rootfs/bin/; cp -P /lib/ld-musl-*.so.1 $d/rootfs/lib/; cp /lib/libc.so $d/rootfs/lib/
  ( cd $d && runc spec >/dev/null 2>&1 && sed -i "s/\"terminal\": true/\"terminal\": false/; s/\"sh\"/\"\\/bin\\/busybox\",\"true\"/" config.json )
  o=$(cd $d && runc --debug run dv-runc247 </dev/null 2>&1); runc delete -f dv-runc247 >/dev/null 2>&1; rm -rf $d
  case "$o" in *"using overlayfs for sealed /proc/self/exe"*) echo "ok: runc $v, exe sealed via overlayfs" ;; *"could not use overlayfs"*) echo "exeseal fell back to copying the runc binary"; exit 1 ;; *) echo "no exeseal message from runc --debug run: $(echo "$o" | tail -2)"; exit 1 ;; esac' || rc=1; done; return $rc; }
# #263 M0: joinwatch runs `batman-config-save --on-join` every ~15 s while a node is open; before the fix each
# call mounted p5 rw (215 mounts/hour on 03, coinciding with the SPI stalls in the #263 crash logs). On every
# reachable node, count p5 mounts (ext4 superblock s_mnt_count, read without mounting) over 90 s: a joined node
# must not mount p5 at all. All nodes are sampled in the same window.
chk_p5churn_263() { local n a b rc=0 tested=0; declare -A A
  for n in "$@"; do A[$n]=$(fssh "$n" 15 "$RDR"'hexdump -s 1076 -n 2 -e "1/2 \"%u\"" /dev/mmcblk0p5 2>/dev/null; echo " $(cut -d" " -f1 "$R/joinwatch.state" 2>/dev/null)"'); done
  sleep 90
  for n in "$@"; do
    b=$(fssh "$n" 15 "$RDR"'hexdump -s 1076 -n 2 -e "1/2 \"%u\"" /dev/mmcblk0p5 2>/dev/null; echo " $(cut -d" " -f1 "$R/joinwatch.state" 2>/dev/null)"')
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
# #264 harness note (rc wsl.20, 2026-10-13): the eud handlers' log files are read as "the newest file of the name"
# (`ls -t eud_handler_tcp.log* | head -1`, expanded inside the container). Upstream's TimedRotatingFileHandler runs in
# every forked session process; at node midnight the rename race leaves the LIVE writes in the dated file (PID 1's fd
# pointed at eud_handler_tcp.log.2025-07-10 while eud_handler_tcp.log held 116 bytes), so a fixed path reads nothing
# after the rotation (every log-based #264 suite FAILed with the product fine). Upstream (B); the gateway (#289) owns
# its logging. A rotation inside one suite still skews that suite's before/after counts: once a day, attributable.
ots_logc() { fssh "$1" 30 'echo "$(docker exec ots_eud_handler sh -c "grep -c \"Failed to parse\" \$(ls -t /app/ots/logs/eud_handler_tcp.log* | head -1)" 2>/dev/null) $(docker logs rabbitmq 2>&1 | grep -c "missed heartbeats") $(docker exec ots_eud_handler sh -c "grep -c \"channel is closed\" \$(ls -t /app/ots/logs/eud_handler_tcp.log* | head -1)" 2>/dev/null)"' 2>/dev/null | tr -d '\r'; }
chk_cot_264() { local ots=$1 peer=$2 run o c0 c1 l0 l1 rc=0 ph sent st prev i
  [ -n "$peer" ] && [ "$peer" != "$ots" ] && up "$peer" || { echo "SKIP-REASON: no generator peer (BENCH_NODE '$peer' unset, == OTS_NODE or down)"; return 3; }
  c0=$(ots_ctr "$ots"); [ "$c0" = "$OTS_N" ] || { echo "FAIL OTS not $OTS_N/$OTS_N before the test ($c0)"; return 1; }
  run=DV$(date +%Y%m%d%H%M%S); echo "run id $run; generator $peer -> $ots:8088"
  l0=$(ots_logc "$ots")
  o=$(timeout 400 ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR -o ConnectTimeout=8 "root@$peer" "TARGET=$ots RUN=$run sh -s" < "$REPO/scripts/node/cot-e2e-gen.sh" 2>&1)
  echo "$o"
  cot_judge "$ots" "$run" "$o" || rc=1
  l1=$(ots_logc "$ots"); echo "eud 'Failed to parse' / rabbit 'missed heartbeats' / eud 'channel is closed': before [$l0] after [$l1] (info; #264 mechanism B is not exercised by this suite)"
  c1=$(ots_ctr "$ots"); [ "$c1" = "$OTS_N" ] || { echo "FAIL OTS not $OTS_N/$OTS_N after the test ($c1)"; rc=1; }
  return $rc; }
# cot_judge <ots> <run> <generator output>: per phase sent == stored, connection losses, then delete the run's
# rows and prove they are gone. Shared by the TCP (8088) and SSL (8089) suites (#264).
cot_judge() { local ots=$1 run=$2 o=$3 rc=0 ph sent st prev i pat u
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
  # cleanup in one transaction, then verify every related table is empty for this run
  ots_sql "$ots" <<SQL
begin; delete from cot where uid like '$run-%' or sender_uid like '$run-%'; delete from points where device_uid like '$run-%'; delete from euds where uid like '$run-%'; commit;
SQL
  o=$(ots_sql "$ots" <<SQL
select (select count(*) from cot where uid like '$run-%' or sender_uid like '$run-%') + (select count(*) from euds where uid like '$run-%') + (select count(*) from points where uid like '$run-%' or device_uid like '$run-%');
SQL
)
  [ "$o" = 0 ] && echo "cleanup ok (cot/euds/points = 0)" || { echo "FAIL cleanup: $o rows of run $run left behind"; rc=1; }
  # #264: the per-EUD rabbit queues a test EUD declares (<callsign>, <uid>) outlive the session; delete ours
  o=$(fssh "$ots" 60 'n=0; for q in $(docker exec rabbitmq rabbitmqctl -q list_queues name 2>/dev/null | grep "^'"$run"'"); do docker exec rabbitmq rabbitmqctl -q delete_queue "$q" >/dev/null 2>&1 && n=$((n+1)); done; left=$(docker exec rabbitmq rabbitmqctl -q list_queues name 2>/dev/null | grep -c "^'"$run"'"); echo "deleted=$n left=$left"' | tr -d '\r')
  echo "rabbit per-EUD queues of this run: $o"; case "$o" in *left=0) ;; *) echo "FAIL cleanup: per-EUD rabbit queues of run $run left behind"; rc=1 ;; esac
  return $rc; }
# #264 on the SSL listener (8089): the same three phases over mutual TLS. The generator runs INSIDE ots_cot_parser
# (python3 + ssl; the node has neither) against ots_eud_handler_ssl on br-ots, so this exercises the handler, not
# the mesh path (ots-cot-e2e-264 covers that on 8088). A 1-day client cert for the existing OTS user 'administrator'
# (the SSL handler maps the cert CN to a user) is signed on the node by the OTS CA into the container's tmpfs and
# removed afterwards; the CA password is read inside the container, never printed.
chk_cot_264_ssl() { local ots=$1 run o c0 rc=0
  c0=$(ots_ctr "$ots"); [ "$c0" = "$OTS_N" ] || { echo "FAIL OTS not $OTS_N/$OTS_N before the test ($c0)"; return 1; }
  o=$(timeout 60 ssh -o BatchMode=yes -o LogLevel=ERROR -o ConnectTimeout=8 "root@$ots" 'docker exec -i ots_cot_parser python3 -' < "$REPO/scripts/node/ots-test-client-cert.py" 2>&1)
  echo "$o"; echo "$o" | grep -q '^OK test client cert' || { echo "FAIL could not issue the test client cert — not verified"; return 1; }
  run=DVS$(date +%Y%m%d%H%M%S); echo "run id $run; generator ots_cot_parser -> ots_eud_handler_ssl:8089 (mTLS, CN=administrator)"
  o=$(timeout 400 ssh -o BatchMode=yes -o LogLevel=ERROR -o ConnectTimeout=8 "root@$ots" \
    "docker exec -i -e TARGET=172.20.0.12 -e RUN=$run -e CA=/app/ots/ca/ca.pem -e CERT=/tmp/dv-client.pem -e KEY=/tmp/dv-client.key ots_cot_parser python3 -" \
    < "$REPO/scripts/node/cot-e2e-gen-ssl.py" 2>&1)
  echo "$o"
  cot_judge "$ots" "$run" "$o" || rc=1
  fssh "$ots" 15 'docker exec ots_cot_parser rm -f /tmp/dv-client.pem /tmp/dv-client.key; docker exec ots_cot_parser ls /tmp/dv-client.pem 2>/dev/null' | grep -q . \
    && { echo "FAIL test client cert still present in ots_cot_parser:/tmp"; rc=1; } || echo "test client cert removed"
  [ "$(ots_ctr "$ots")" = "$OTS_N" ] || { echo "FAIL OTS not $OTS_N/$OTS_N after the test"; rc=1; }
  return $rc; }
# #264 R10: an 8088 client's uid/callsign become queue names on the shared broker. A callsign "cot_parser" would
# consume the cot_parser queue (round-robin with cot_parser: every second CoT of every EUD lost from storage).
# From the bench node: one session identifies with callsign cot_parser and a plain uid, keeps the session 8 s.
# Patched: the subscription is refused (handler log line), the cot_parser queue keeps exactly 1 consumer, and
# nothing is stored from that session (no EUD row, so cot_parser rejects its CoT). Negative control (upstream, by
# code: EudHandler.py:524-645 declares/consumes the callsign queue unconditionally): consumers 2 and the storage
# round-robin starts.
chk_name_guard_264() { local ots=$1 peer=$2 run o c rc=0 g0 g1 st
  [ -n "$peer" ] && [ "$peer" != "$ots" ] && up "$peer" || { echo "SKIP-REASON: no generator peer (BENCH_NODE '$peer' unset, == OTS_NODE or down)"; return 3; }
  [ "$(ots_ctr "$ots")" = "$OTS_N" ] || { echo "FAIL OTS not $OTS_N/$OTS_N before the test"; return 1; }
  run=DVN$(date +%H%M%S)
  g0=$(fssh "$ots" 20 'docker exec ots_eud_handler sh -c "grep -c \"is not used as a queue\" \$(ls -t /app/ots/logs/eud_handler_tcp.log* | head -1) 2>/dev/null"' | tr -d ' \r'); isint "$g0" || g0=0
  ( timeout 40 ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR -o ConnectTimeout=8 "root@$peer" \
      'n=$(date +%s); ts(){ date -u -d @$1 +%Y-%m-%dT%H:%M:%S.000Z; }; { printf "<event version=\"2.0\" uid=\"'"$run"'\" type=\"a-f-G-U-C\" how=\"h-e\" time=\"%s\" start=\"%s\" stale=\"%s\"><point lat=\"25.03\" lon=\"121.56\" hae=\"10\" ce=\"9999999\" le=\"9999999\"/><detail><contact callsign=\"cot_parser\"/><marti><dest callsign=\"dv-nobody\"/></marti></detail></event>" "$(ts $n)" "$(ts $n)" "$(ts $((n+120)))"; sleep 8; } | nc '"$ots"' 8088 >/dev/null 2>&1; echo done' ) > "$DIR/$run.gen" 2>&1 &
  sleep 5
  c=$(fssh "$ots" 20 'docker exec rabbitmq rabbitmqctl -q list_queues name consumers 2>/dev/null | grep "^cot_parser	" | cut -f2' | tr -d ' \r')
  echo "cot_parser queue consumers while the callsign=cot_parser session is up: [$c] (expect 1)"
  [ "$c" = 1 ] || { echo "FAIL the client's session consumes the cot_parser queue (consumers [$c]) — upstream behaviour"; rc=1; }
  wait; echo "peer: $(tr '\n' ' ' < "$DIR/$run.gen")"
  g1=$(fssh "$ots" 20 'docker exec ots_eud_handler sh -c "grep -c \"is not used as a queue\" \$(ls -t /app/ots/logs/eud_handler_tcp.log* | head -1) 2>/dev/null"' | tr -d ' \r'); isint "$g1" || g1=0
  [ "$g1" -gt "$g0" ] && echo "handler log: the callsign is not used as a queue ($((g1 - g0)) line(s))" || { echo "FAIL no 'is not used as a queue' line in the handler's log"; rc=1; }
  sleep 3; st=$(echo "select count(*) from cot where uid = '$run';" | ots_sql "$ots")
  # the user's decision 2026-10-12 (review r4/r5): the colliding NAME is refused, the device is RECORDED (its own row,
  # its own <uid> queue). Negative control: rc wsl.12 stored 0 (cot_parser FK: no EUD row)
  isint "$st" && [ "$st" -ge 1 ] && echo "the device is recorded: $st row(s) (expect >= 1)" || { echo "FAIL [$st] rows: the device with a refused callsign was not recorded (AAR gap)"; rc=1; }
  ots_sql "$ots" <<SQL
begin; delete from cot where uid = '$run'; delete from euds where uid = '$run'; commit;
SQL
  o=$(fssh "$ots" 60 'for q in $(docker exec rabbitmq rabbitmqctl -q list_queues name 2>/dev/null | grep "^'"$run"'$"); do docker exec rabbitmq rabbitmqctl -q delete_queue "$q" >/dev/null 2>&1; done; echo "left=$(docker exec rabbitmq rabbitmqctl -q list_queues name 2>/dev/null | grep -c "^'"$run"'$")"' | tr -d '\r')
  echo "rabbit queue of this run: $o"; case "$o" in *left=0) ;; *) echo "FAIL cleanup: rabbit queue of run $run left behind"; rc=1 ;; esac
  [ "$(ots_ctr "$ots")" = "$OTS_N" ] || { echo "FAIL OTS not $OTS_N/$OTS_N after the test"; rc=1; }
  return $rc; }
# #264 R4/R4b/R13 (mechanism B; review r3 A3-3, the user's decision 2026-10-12): the broker ends a streaming
# session's AMQP connection (rabbitmqctl close_connection of that session's connection, found by the connection_name
# the overlay sets). Patched: the session's unconfirmed bodies go back to its cache, the ioloop reconnects only to
# deliver them, then the CLIENT session ends (the phone reconnects and is subscribed afresh from the database, as
# upstream does). Asserted: the client sees its session end (CONNLOST) shortly after the close; every CoT it had sent
# before is stored (at least once; duplicates reported); the handler logs "delivering the cache, then ending".
# Negative controls: upstream (measured 2026-10-11): the session ends and the CoT in flight are lost; rc wsl.10
# (2026-10-12): the client session was kept and the recorded subscription replayed (bindings made later by the Marti
# API were lost, review r3 A3-3).
chk_amqp_close_264() { local ots=$1 peer=$2 run o rc=0 sent st distinct dup closed=0 l0 l1 lost
  [ -n "$peer" ] && [ "$peer" != "$ots" ] && up "$peer" || { echo "SKIP-REASON: no generator peer (BENCH_NODE '$peer' unset, == OTS_NODE or down)"; return 3; }
  [ "$(ots_ctr "$ots")" = "$OTS_N" ] || { echo "FAIL OTS not $OTS_N/$OTS_N before the test"; return 1; }
  run=DVB$(date +%H%M%S)
  l0=$(fssh "$ots" 20 'docker exec ots_eud_handler sh -c "grep -c \"delivering the cache, then ending\" \$(ls -t /app/ots/logs/eud_handler_tcp.log* | head -1) 2>/dev/null"' | tr -d ' \r'); isint "$l0" || l0=0
  ( timeout 240 ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR -o ConnectTimeout=8 "root@$peer" "TARGET=$ots RUN=$run N=120 sh -s" < "$REPO/scripts/node/cot-stream-264.sh" > "$DIR/$run.gen" 2>&1 ) &
  sleep 20
  # close_connection takes the connection's pid, not its name (rc wsl.6/wsl.7: the name was rejected); a miss or a
  # failed close prints rabbitmqctl's own output so it is attributable
  o=$(fssh "$ots" 45 'l=$(docker exec rabbitmq rabbitmqctl -q list_connections pid client_properties 2>&1); r=$?; n=$(echo "$l" | grep "eud-8088-'"$peer"':" | cut -f1 | head -1); if [ -n "$n" ]; then e=$(docker exec rabbitmq rabbitmqctl -q close_connection "$n" "amqp-close-264" 2>&1) && echo "closed $n" || echo "close_connection failed on $n: $e"; else echo "no connection named eud-8088-'"$peer"':* found (list_connections rc=$r, $(echo "$l" | wc -l) line(s)):"; echo "$l" | sed "s/^/    | /" | cut -c1-300; fi' | tr -d '\r')
  echo "t=20s: $o"; case "$o" in closed*) closed=1 ;; esac
  wait; o=$(cat "$DIR/$run.gen"); echo "generator: $(echo "$o" | tr '\n' ' ')"
  [ "$closed" = 1 ] || { echo "FAIL the session's broker connection was not closed — not verified"; rc=1; }
  lost=$(echo "$o" | sed -n 's/^CONNLOST \([0-9]*\)$/\1/p')
  sent=$(echo "$o" | sed -n 's/^SENT \([0-9]*\)$/\1/p'); isint "$sent" || { echo "FAIL unreadable sent count"; return 1; }
  if isint "$lost" && [ "$lost" -le 90 ]; then echo "the client's session ended after the broker-side close (CONNLOST at CoT $lost; R13)"
  else echo "FAIL the client's session was kept (no CONNLOST before CoT 90): R13 ends it after delivering the cache"; rc=1; fi
  sleep 10
  distinct=$(echo "select count(distinct uid) from cot where uid like '$run-%';" | ots_sql "$ots"); st=$(echo "select count(*) from cot where uid like '$run-%';" | ots_sql "$ots")
  isint "$distinct" && isint "$st" || { echo "FAIL unreadable stored counts [$distinct] [$st]"; return 1; }
  dup=$((st - distinct)); echo "sent $sent (all before the session ended), stored rows $st, distinct uids $distinct, duplicates $dup (at-least-once: allowed, reported)"
  [ "$distinct" = "$sent" ] || { echo "FAIL $((sent - distinct)) of $sent CoT never stored (lost across the broker-side close)"; rc=1
    echo "  missing seq: $(echo "select string_agg(g::text,' ') from generate_series(1,$sent) g where not exists (select 1 from cot where uid='$run-'||g);" | ots_sql "$ots")"; }
  l1=$(fssh "$ots" 20 'docker exec ots_eud_handler sh -c "grep -c \"delivering the cache, then ending\" \$(ls -t /app/ots/logs/eud_handler_tcp.log* | head -1) 2>/dev/null"' | tr -d ' \r'); isint "$l1" || l1=0
  [ $((l1 - l0)) -ge 1 ] && echo "handler log: \"delivering the cache, then ending the client session\" ($((l1 - l0)))" || { echo "FAIL no R13 log line"; rc=1; }
  r264_clean "$ots" "$run"
  [ "$(ots_ctr "$ots")" = "$OTS_N" ] || { echo "FAIL OTS not $OTS_N/$OTS_N after the test"; rc=1; }
  return $rc; }
# #264 review round 2 (2026-10-12): every suite below reproduced its finding on node 04 with rc wsl.8 before the
# fix (negative control, logs in the register) and must PASS on the fixed overlay. Helpers: s264 runs
# scripts/node/session-264.sh on the bench node; r264_clean removes a run's rows and per-EUD queues.
s264() { local peer=$1 ots=$2 run=$3 act=$4; shift 4
  timeout "${S264_T:-90}" ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR -o ConnectTimeout=8 "root@$peer" "TARGET=$ots RUN=$run ACTION=$act $* sh -s" < "$REPO/scripts/node/session-264.sh" 2>&1 | tr -d '\r'; }
r264_clean() { local ots=$1 run=$2 o
  ots_sql "$ots" <<SQL >/dev/null
begin; delete from cot where uid like '$run%'; delete from euds where uid like '$run%'; commit;
SQL
  o=$(fssh "$ots" 60 'n=0; for q in $(docker exec rabbitmq rabbitmqctl -q list_queues name 2>/dev/null | grep "^'"$run"'"); do docker exec rabbitmq rabbitmqctl -q delete_queue "$q" >/dev/null 2>&1 && n=$((n+1)); done; echo "harness-deleted=$n"' | tr -d '\r')
  echo "cleanup of run $run: rows deleted, $o"; }
r264_stored() { echo "select count(*) from cot where sender_uid = '$2';" | ots_sql "$1" | tr -d ' \r'; }   # review r4: records, not log lines
r264_binds() { fssh "$1" 20 'docker exec rabbitmq rabbitmqctl -q list_bindings source_name destination_name routing_key 2>/dev/null | grep "	'"$2"'	" | grep -v "^	" | sort' | tr -d '\r'; }
# R17 (the user's decision 2026-10-12; review r2 B2-1, r7 A7-1/A7-2): A = a phone's session that keeps sending
# (one report every 4 s for 40 s); B = the same uid from the same address (the phone's new connection), reading for
# 25 s. Asserted: once B identifies, the downlink goes to B only (10/10 from C, A 0: no split); A keeps being read
# and every report it sends is STORED (10/10: what the phone's TCP still delivers on the old connection is not lost);
# A ends by the R17 quiet timeout only after its reports stopped. Negative controls: rc wsl.14 (no R17): the downlink
# split between A and B; rc wsl.15 (round 6: superseded at once): A's later reports lost.
chk_same_uid_end_264() { local ots=$1 peer=$2 run o rc=0 t0 q
  [ -n "$peer" ] && [ "$peer" != "$ots" ] && up "$peer" || { echo "SKIP-REASON: no generator peer (BENCH_NODE '$peer' unset, == OTS_NODE or down)"; return 3; }
  [ "$(ots_ctr "$ots")" = "$OTS_N" ] || { echo "FAIL OTS not $OTS_N/$OTS_N before the test"; return 1; }
  run=DVSU$(date +%H%M%S); q="$run-U"
  echo "  peer: $(s264 "$peer" "$ots" "$run" same-uid)"; sleep 5
  echo "  peer: $(s264 "$peer" "$ots" "$run" send10 TAG=post)"; sleep 2
  o=$(s264 "$peer" "$ots" "$run" count TAG=post); echo "received while both are connected: $o (expect A 0 B 10: the downlink with the newest session)"
  [ "$o" = "A 0 B 10" ] || { echo "FAIL the downlink is not with the device's newest session only ($o)"; rc=1; }
  o=$(fssh "$ots" 20 'docker exec ots_eud_handler sh -c "grep -c \"session of '"$q"' superseded by the device.s new session\" \$(ls -t /app/ots/logs/eud_handler_tcp.log* | head -1)"' | tr -d ' \r')
  echo "A superseded (log): ${o:-0} (expect 1)"; [ "${o:-0}" = 1 ] || { echo "FAIL A was not superseded"; rc=1; }
  # B leaves at ~+30 s while A still sends (until ~+44 s): B's end must not disconnect/unbind the device (r8 A8-4/B8-3)
  d0=$(fssh "$ots" 20 'docker exec ots_cot_parser sh -c "grep -c \"Sending disconnect cot to '"$q"'\$\" /app/ots/logs/cot_parser.log 2>/dev/null"' | tr -d ' \r'); isint "$d0" || d0=0
  t0=$SECONDS; o=""
  while [ $((SECONDS - t0)) -lt 40 ] && [ -z "$o" ]; do sleep 5
    o=$(fssh "$ots" 20 'docker exec ots_eud_handler sh -c "grep -c \"another session of '"$q"' is live\" \$(ls -t /app/ots/logs/eud_handler_tcp.log* | head -1)"' | tr -d ' \r'); [ "${o:-0}" = 0 ] && o=""; done
  echo "B's end saw A live (no disconnect, nothing unbound): ${o:-0} line(s) (expect >= 1)"; [ -n "$o" ] || { echo "FAIL B's end did not treat the superseded A as live"; rc=1; }
  o=$(fssh "$ots" 20 'docker exec rabbitmq rabbitmqctl -q list_bindings source_name destination_name 2>/dev/null | grep -c "	'"$q"'$"' | tr -d ' \r')
  echo "bindings of $q after B's end: ${o:-?} (expect >= 1: A still has them)"; isint "$o" && [ "$o" -ge 1 ] || { echo "FAIL B's end unbound the device while A lives"; rc=1; }
  # A sends until ~+44 s, then is quiet; it ends by the R17 deadline (~20 s later), as the device's last session
  t0=$SECONDS; o=""
  while [ $((SECONDS - t0)) -lt 100 ] && [ -z "$o" ]; do sleep 5
    o=$(fssh "$ots" 20 'docker exec ots_eud_handler sh -c "grep \"superseded session of '"$q"' quiet for\" \$(ls -t /app/ots/logs/eud_handler_tcp.log* | head -1)"' | tr -d '\r'); done
  echo "A's end by the R17 deadline: ${o:-none}"; [ -n "$o" ] || { echo "FAIL A did not end by the R17 deadline"; rc=1; }
  sleep 3
  d1=$(fssh "$ots" 20 'docker exec ots_cot_parser sh -c "grep -c \"Sending disconnect cot to '"$q"'\$\" /app/ots/logs/cot_parser.log 2>/dev/null"' | tr -d ' \r'); isint "$d1" || d1=0
  echo "cot_parser disconnects for $q: $((d1 - d0)) (expect 1: from A's end, the last session)"; [ $((d1 - d0)) = 1 ] || { echo "FAIL disconnect count $((d1 - d0)) (B's end sent one while A lived, or A's end sent none)"; rc=1; }
  o=$(echo "select count(distinct uid) from cot where uid like '$q-a-%';" | ots_sql "$ots" | tr -d ' \r')
  echo "A's reports stored (sent while superseded too): ${o:-?} of 10"
  [ "$o" = 10 ] || { echo "FAIL ${o:-?} of 10 reports A sent were stored (rc wsl.15: A ended at once, its later reports lost)"; rc=1; }
  o=$(fssh "$ots" 20 'docker logs ots_eud_handler 2>&1 | grep -c "Exception occurred during processing"' | tr -d ' \r'); echo "container tracebacks (total): ${o:-?}"
  echo "  peer: $(s264 "$peer" "$ots" "$run" cleanup)"; sleep 5; r264_clean "$ots" "$run"
  [ "$(ots_ctr "$ots")" = "$OTS_N" ] || { echo "FAIL OTS not $OTS_N/$OTS_N after the test"; rc=1; }
  return $rc; }
# R10 (review r2 B2-4): two devices with the same callsign and different uids both get broadcast traffic (own
# <uid> queue each, as upstream). Negative control, rc wsl.8 (node 04, 2026-10-12): A 10, B 0 (B held off for its
# whole session, its <uid> queue never bound, left behind as an orphan).
chk_callsign_share_264() { local ots=$1 peer=$2 run o rc=0
  [ -n "$peer" ] && [ "$peer" != "$ots" ] && up "$peer" || { echo "SKIP-REASON: no generator peer (BENCH_NODE '$peer' unset, == OTS_NODE or down)"; return 3; }
  [ "$(ots_ctr "$ots")" = "$OTS_N" ] || { echo "FAIL OTS not $OTS_N/$OTS_N before the test"; return 1; }
  run=DVCS$(date +%H%M%S)
  o=$(s264 "$peer" "$ots" "$run" share-cs); echo "  peer: $o"
  echo "$o" | grep -q '^STARTED established=2$' || { echo "FAIL expected A and B established"; rc=1; }
  sleep 3; echo "  peer: $(s264 "$peer" "$ots" "$run" send10 TAG=t1)"; sleep 2
  o=$(s264 "$peer" "$ots" "$run" count TAG=t1); echo "received: $o (expect A 10 B 10)"
  [ "$o" = "A 10 B 10" ] || { echo "FAIL a device sharing a callsign lost its broadcast traffic"; rc=1; }
  # review r4: euds.callsign is UNIQUE; the second device's row failed and cot_parser's FK dropped all it sent (rc
  # wsl.12, cot_parser.log: "Key (sender_uid)=(...-U2) is not present"). Both must be recorded.
  for o in U1 U2; do e=$(r264_stored "$ots" "$run-$o"); echo "stored CoT of $run-$o: ${e:-?} (expect >= 1)"
    isint "$e" && [ "$e" -ge 1 ] || { echo "FAIL $run-$o (shared callsign) was not recorded (AAR gap)"; rc=1; }; done
  # the two end one after the other (A, then B): the last one removes the shared callsign queue. Residual, stated:
  # two devices sharing a callsign that end at the same instant both see the other consumer and both keep it
  echo "  peer: $(s264 "$peer" "$ots" "$run" stop WHO=A)"; sleep 4
  echo "  peer: $(s264 "$peer" "$ots" "$run" cleanup)"; sleep 6
  o=$(fssh "$ots" 30 'docker exec rabbitmq rabbitmqctl -q list_queues name messages consumers 2>/dev/null | grep "^'"$run"'"' | tr -d '\r')
  [ -n "$o" ] && echo "$o" | sed 's/^/  left: /'
  o=$(echo "$o" | awk -F'\t' 'NF>=3 && $2==0 {n++} END {print n+0}')
  [ "$o" = 0 ] || { echo "FAIL $o EMPTY queue(s) of the run left behind (orphans, F3)"; rc=1; }
  r264_clean "$ots" "$run"
  [ "$(ots_ctr "$ots")" = "$OTS_N" ] || { echo "FAIL OTS not $OTS_N/$OTS_N after the test"; rc=1; }
  return $rc; }
# R10 (review r2 B2-2): an unauthenticated 8088 client must not take over an authenticated (8089) user's queues by
# swapping uid and callsign. An 8089 session (test cert, CN=administrator) identifies once; then an 8088 client
# uses the user's uid as its CALLSIGN (and, as the control, as its uid). Both must be refused (log line) and no
# 8088 session may consume the user's queues. Negative control, rc wsl.8 (node 04, 2026-10-12): the swap was
# subscribed ("subscribed ...-X/<user's uid>", 1 consumer on the user's uid queue); the direct one was refused.
chk_owner_swap_264() { local ots=$1 peer=$2 run o rc=0 V VC r0 r1 mode
  [ -n "$peer" ] && [ "$peer" != "$ots" ] && up "$peer" || { echo "SKIP-REASON: no generator peer (BENCH_NODE '$peer' unset, == OTS_NODE or down)"; return 3; }
  [ "$(ots_ctr "$ots")" = "$OTS_N" ] || { echo "FAIL OTS not $OTS_N/$OTS_N before the test"; return 1; }
  o=$(timeout 60 ssh -o BatchMode=yes -o LogLevel=ERROR -o ConnectTimeout=8 "root@$ots" 'docker exec -i ots_cot_parser python3 -' < "$REPO/scripts/node/ots-test-client-cert.py" 2>&1)
  echo "$o" | grep -q '^OK test client cert' || { echo "FAIL could not issue the test client cert — not verified"; return 1; }
  run=DVOS$(date +%H%M%S); V=$run-V; VC=$run-Vc
  o=$(timeout 60 ssh -o BatchMode=yes -o LogLevel=ERROR -o ConnectTimeout=8 "root@$ots" "docker exec -i -e TARGET=172.20.0.12 -e V=$V -e VC=$VC -e HOLD=5 -e CA=/app/ots/ca/ca.pem -e CERT=/tmp/dv-client.pem -e KEY=/tmp/dv-client.key ots_cot_parser python3 -" < "$REPO/scripts/node/eud-ssl-victim-264.py" 2>&1 | tr -d '\r')
  echo "8089 user session: $o"; sleep 3
  o=$(echo "select uid, callsign, user_id is not null from euds where uid = '$V';" | ots_sql "$ots"); echo "the user's EUD row: $o"
  case "$o" in "$V|$VC|t") ;; *) echo "FAIL no EUD row with a user for $V — not verified"; rc=1 ;; esac
  for mode in swap direct; do
    r0=$(fssh "$ots" 20 'docker exec ots_eud_handler sh -c "grep -cE \"belong to an authenticated user|is not used as a queue\" \$(ls -t /app/ots/logs/eud_handler_tcp.log* | head -1)"' | tr -d ' \r'); isint "$r0" || r0=0
    if [ $mode = swap ]; then ( s264 "$peer" "$ots" "$run-$mode" swap VICTIM="$V" >/dev/null ) &
    else ( timeout 40 ssh -o BatchMode=yes -o LogLevel=ERROR -o ConnectTimeout=8 "root@$peer" 'n=$(date +%s); ts(){ date -u -d @$1 +%Y-%m-%dT%H:%M:%S.000Z; }; { printf "<event version=\"2.0\" uid=\"'"$V"'\" type=\"a-f-G-U-C\" how=\"h-e\" time=\"%s\" start=\"%s\" stale=\"%s\"><point lat=\"25.03\" lon=\"121.56\" hae=\"10\" ce=\"9999999\" le=\"9999999\"/><detail><contact callsign=\"'"$run"'-direct-c\"/></detail></event>" "$(ts $n)" "$(ts $n)" "$(ts $((n+600)))"; sleep 10; } | nc '"$ots"' 8088 >/dev/null 2>&1' ) & fi
    sleep 6
    o=$(fssh "$ots" 20 'docker exec rabbitmq rabbitmqctl -q list_queues name consumers 2>/dev/null | grep -E "^('"$V"'|'"$VC"')	"' | tr -d '\r' | tr '\t\n' '= ')
    echo "$mode: consumers of the user's queues while the 8088 client is up: [${o:-none}] (expect none or =0)"
    case "$o" in *=[1-9]*) echo "FAIL $mode: an unauthenticated 8088 session consumes the user's queue"; rc=1 ;; esac
    wait
    r1=$(fssh "$ots" 20 'docker exec ots_eud_handler sh -c "grep -cE \"belong to an authenticated user|is not used as a queue\" \$(ls -t /app/ots/logs/eud_handler_tcp.log* | head -1)"' | tr -d ' \r'); isint "$r1" || r1=0
    [ "$r1" -gt "$r0" ] && echo "$mode: refused (handler log)" || { echo "FAIL $mode: no refusal line in the handler's log"; rc=1; }
    if [ $mode = swap ]; then   # review r4 (the user's decision): the colliding NAME is refused, the device is recorded
      o=$(r264_stored "$ots" "$run-$mode-X"); echo "swap: stored CoT of $run-$mode-X: ${o:-?} (expect >= 1)"
      isint "$o" && [ "$o" -ge 1 ] || { echo "FAIL swap: the 8088 device was not recorded (rc wsl.12: FK, 0 stored)"; rc=1; }
    fi
  done
  fssh "$ots" 15 'docker exec ots_cot_parser rm -f /tmp/dv-client.pem /tmp/dv-client.key' >/dev/null
  sleep 3; r264_clean "$ots" "$run"
  [ "$(ots_ctr "$ots")" = "$OTS_N" ] || { echo "FAIL OTS not $OTS_N/$OTS_N after the test"; rc=1; }
  return $rc; }
# R12 (review r2 B2-6, the user's decision 2026-10-12): admission. (a) 8088: silent sockets (no byte ever sent) are
# closed by the server within IDENT_MAX_S (60 s) + slack; (b) 8088: more than PER_IP_MAX (8) sessions from one
# address are refused at once (log line); (c) 8089: a socket that never completes the TLS handshake gets no AMQP
# connection (nothing allocated) and is closed within 10 s. Negative control, rc wsl.8 (node 04, 2026-10-12):
# silent sockets stayed open (no deadline), nothing refused, and every 8089 socket opened an AMQP connection
# before its handshake (measured: see register r2 B2-6).
chk_admission_264() { local ots=$1 peer=$2 run o rc=0 r0 r1 t0 e
  [ -n "$peer" ] && [ "$peer" != "$ots" ] && up "$peer" || { echo "SKIP-REASON: no generator peer (BENCH_NODE '$peer' unset, == OTS_NODE or down)"; return 3; }
  [ "$(ots_ctr "$ots")" = "$OTS_N" ] || { echo "FAIL OTS not $OTS_N/$OTS_N before the test"; return 1; }
  run=DVAD$(date +%H%M%S)
  rlog() { fssh "$ots" 20 'docker exec '"$1"' sh -c "grep -c \"'"$2"'\" /app/ots/logs/'"$3"' 2>/dev/null"' | tr -d ' \r'; }
  # (c) 8089 first (its sockets are gone within seconds): 3 TCP connections that never start TLS
  o=$(s264 "$peer" "$ots" "$run" silent N=3 PORT=8089); echo "  peer: $o (8089, no TLS)"; sleep 2
  o=$(fssh "$ots" 20 'l=$(docker exec rabbitmq rabbitmqctl -q list_connections client_properties 2>&1) || { echo "ERR $l" | head -1; exit 0; }; echo "$l" | grep -c "eud-8089-'"$peer"':"' | tr -d ' \r')
  echo "(c) AMQP connections of 8089 sessions from $peer before their handshake: ${o:-?} (expect 0)"
  [ "$o" = 0 ] || { echo "FAIL (c) an 8089 socket without a TLS handshake got an AMQP connection (allocated before authentication)"; rc=1; }
  t0=$SECONDS; e=3; while [ $((SECONDS - t0)) -lt 20 ] && [ "$e" != 0 ]; do sleep 2; e=$(s264 "$peer" "$ots" "$run" est PORT=8089 | sed -n 's/^EST //p'); done
  echo "(c) 8089 silent sockets still open after $((SECONDS - t0 + 4)) s: ${e:-?} (expect 0 within ~14 s)"; [ "$e" = 0 ] || { echo "FAIL (c) handshake-less 8089 sockets not closed"; rc=1; }
  s264 "$peer" "$ots" "$run" cleanup >/dev/null
  # (b) 10 silent 8088 sockets from one address, 1 s apart: the 9th and 10th are refused (> PER_IP_MAX 8). Spaced:
  # rc wsl.10 FAILed this step with 10 at once, attributed by a flip test (same build, 1 s apart -> 2 refused): a crowd
  # overflowed upstream's listen backlog of 5, so the server never saw more than 8 at a time (round 3 raises it)
  r0=$(rlog ots_eud_handler "sessions from this address" eud_handler_tcp.log); isint "$r0" || r0=0
  o=$(S264_T=120 s264 "$peer" "$ots" "$run" silent N=10 PORT=8088 GAP=1); echo "  peer: $o (8088, silent, 1 s apart)"; sleep 3
  r1=$(rlog ots_eud_handler "sessions from this address" eud_handler_tcp.log); isint "$r1" || r1=0
  echo "(b) refusals over the per-address limit: $((r1 - r0)) (expect exactly 2: the 9th and 10th; review r3 B3-8 over-refusal)"; [ $((r1 - r0)) = 2 ] || { echo "FAIL (b) 10 sessions from one address: $((r1 - r0)) refused, not 2 (under- or over-refusal)"; rc=1; }
  s264 "$peer" "$ots" "$run" cleanup >/dev/null; sleep 3
  # (a) 3 silent 8088 sockets (under the limit) are closed by the server at IDENT_MAX_S
  r0=$(rlog ots_eud_handler "sent no complete message within" eud_handler_tcp.log); isint "$r0" || r0=0
  o=$(s264 "$peer" "$ots" "$run" silent N=3 PORT=8088); echo "  peer: $o (8088, silent, under the limit)"
  t0=$SECONDS; e=3; while [ $((SECONDS - t0)) -lt 90 ] && [ "$e" != 0 ]; do sleep 5; e=$(s264 "$peer" "$ots" "$run" est PORT=8088 | sed -n 's/^EST //p'); done
  r1=$(rlog ots_eud_handler "sent no complete message within" eud_handler_tcp.log); isint "$r1" || r1=0
  echo "(a) silent 8088 sockets open after $((SECONDS - t0)) s: ${e:-?} (expect 0 by ~65 s); deadline log lines: $((r1 - r0)) (expect 3)"
  [ "$e" = 0 ] && [ $((r1 - r0)) -ge 3 ] || { echo "FAIL (a) silent 8088 sockets kept open (no first-message deadline)"; rc=1; }
  s264 "$peer" "$ots" "$run" cleanup >/dev/null; sleep 3
  # (d) review r3 B3-3: a client that sends only an empty <event></event> and then nothing is closed at the deadline
  # too (rc wsl.10: the empty event cleared the deadline for good, the socket stayed)
  r0=$(rlog ots_eud_handler "(not identified)" eud_handler_tcp.log); isint "$r0" || r0=0
  o=$(s264 "$peer" "$ots" "$run" chatter N=3); echo "  peer: $o (8088, one empty event each)"
  t0=$SECONDS; e=3; while [ $((SECONDS - t0)) -lt 90 ] && [ "$e" != 0 ]; do sleep 5; e=$(s264 "$peer" "$ots" "$run" est PORT=8088 | sed -n 's/^EST //p'); done
  r1=$(rlog ots_eud_handler "(not identified)" eud_handler_tcp.log); isint "$r1" || r1=0
  echo "(d) sockets that sent one empty event, open after $((SECONDS - t0)) s: ${e:-?} (expect 0 by ~65 s); deadline lines: $((r1 - r0)) (expect 3)"
  [ "$e" = 0 ] && [ $((r1 - r0)) -ge 3 ] || { echo "FAIL (d) an empty event cleared the deadline (review r3 B3-3)"; rc=1; }
  echo "  peer: $(s264 "$peer" "$ots" "$run" cleanup)"; sleep 3
  # (e) review r4 A4-3/B4-9 (rc wsl.12: three silent sockets held the admission lock 20 s each): with 3 silent 8088
  # sockets open, a phone that identifies at once is subscribed within a few seconds
  o=$(s264 "$peer" "$ots" "$run" silent N=3 PORT=8088); echo "  peer: $o (8088, silent, holding nothing)"
  o=$(s264 "$peer" "$ots" "$run-e" idle N=1 HOLD=20); echo "  peer: $o (one identifying phone)"; sleep 5
  e=$(fssh "$ots" 20 'docker exec ots_eud_handler sh -c "grep -c \"subscribed '"$run"'-e-1/\" \$(ls -t /app/ots/logs/eud_handler_tcp.log* | head -1)"' | tr -d ' \r')
  echo "(e) the phone subscribed within ~8 s while 3 silent sockets are open: ${e:-?} (expect 1)"
  [ "$e" = 1 ] || { echo "FAIL (e) silent sockets hold up a phone's admission (the lock is taken before any message)"; rc=1; }
  echo "  peer: $(s264 "$peer" "$ots" "$run" cleanup)"; sleep 3
  # (f) review r6 A6-3/B6-3 (round 5 held the lock ADMIT_HOLD_S after a ping-first message): 3 sockets that each send
  # one ping and stay; a phone that identifies right after is subscribed within a few seconds, serialized
  o=$(s264 "$peer" "$ots" "$run" pinger N=3); echo "  peer: $o (8088, one ping each, then silent)"
  o=$(s264 "$peer" "$ots" "$run-f" idle N=1 HOLD=20); echo "  peer: $o (one identifying phone)"; sleep 5
  e=$(fssh "$ots" 20 'docker exec ots_eud_handler sh -c "grep -c \"subscribed '"$run"'-f-1/\" \$(ls -t /app/ots/logs/eud_handler_tcp.log* | head -1)"' | tr -d ' \r')
  echo "(f) the phone subscribed within ~8 s while 3 ping-only sockets are open: ${e:-?} (expect 1)"
  [ "$e" = 1 ] || { echo "FAIL (f) ping-first sockets hold up a phone's admission (the lock held after a ping)"; rc=1; }
  echo "  peer: $(s264 "$peer" "$ots" "$run" cleanup)"; sleep 3
  # (g) review r7 B7-1 (dc7474b: one 20 s timer thread per ping/<auth>; pids.max 512): 450 <auth></auth> from one
  # unidentified client; the container's task count must not follow the message count
  r0=$(fssh "$ots" 20 'docker exec ots_eud_handler cat /sys/fs/cgroup/pids.current' | tr -d ' \r')
  o=$(s264 "$peer" "$ots" "$run" authflood N=450); echo "  peer: $o"
  echo "$o" | grep -q "EST 1$" || { echo "FAIL (g) the flood socket is not open (nothing to measure)"; rc=1; }   # r8 A8-6
  o=$(s264 "$peer" "$ots" "$run-g" idle N=1 HOLD=20); echo "  peer: $o (one identifying phone during the flood)"; sleep 2
  r1=$(fssh "$ots" 20 'docker exec ots_eud_handler cat /sys/fs/cgroup/pids.current' | tr -d ' \r')
  echo "(g) ots_eud_handler tasks before / during an <auth> flood of 450: $r0 / $r1 (expect +< 25: the phone's session included)"
  isint "$r0" && isint "$r1" && [ $((r1 - r0)) -lt 25 ] || { echo "FAIL (g) the flood grew the container's tasks by $((r1 - r0)) (a thread per message)"; rc=1; }
  sleep 3; e=$(fssh "$ots" 20 'docker exec ots_eud_handler sh -c "grep -c \"subscribed '"$run"'-g-1/\" \$(ls -t /app/ots/logs/eud_handler_tcp.log* | head -1)"' | tr -d ' \r')
  echo "(g) the phone subscribed during the flood: ${e:-?} (expect 1)"; [ "$e" = 1 ] || { echo "FAIL (g) a phone was not admitted during an <auth> flood"; rc=1; }
  echo "  peer: $(s264 "$peer" "$ots" "$run" cleanup)"; sleep 3
  # (h) review r8 A8-2/B8-2 (afbb22f: a client that never identifies took the admission per message, 6020 takes in
  # 15 s offline; phones waited seconds, up to the 30 s wait and then unserialized): one socket streams contact-less
  # events (a relay that never identifies) while a phone identifies: the phone is subscribed within ~8 s, nothing is
  # admitted unserialized
  u0=$(rlog ots_eud_handler "admitting unserialized" eud_handler_tcp.log); isint "$u0" || u0=0
  o=$(s264 "$peer" "$ots" "$run" stream N=400); echo "  peer: $o (8088, ~400 contact-less events over ~20 s)"; sleep 3
  o=$(s264 "$peer" "$ots" "$run-h" idle N=1 HOLD=20); echo "  peer: $o (one identifying phone during the stream)"; sleep 5
  e=$(fssh "$ots" 20 'docker exec ots_eud_handler sh -c "grep -c \"subscribed '"$run"'-h-1/\" \$(ls -t /app/ots/logs/eud_handler_tcp.log* | head -1)"' | tr -d ' \r')
  u1=$(rlog ots_eud_handler "admitting unserialized" eud_handler_tcp.log); isint "$u1" || u1=0
  echo "(h) the phone subscribed within ~8 s during a contact-less stream: ${e:-?} (expect 1); unserialized admissions +$((u1 - u0)) (expect 0)"
  [ "$e" = 1 ] && [ "$u1" = "$u0" ] || { echo "FAIL (h) a non-identifying stream holds up a phone's admission (the lock re-taken per message)"; rc=1; }
  echo "  peer: $(s264 "$peer" "$ots" "$run" cleanup)"; r264_clean "$ots" "$run"
  [ "$(ots_ctr "$ots")" = "$OTS_N" ] || { echo "FAIL OTS not $OTS_N/$OTS_N after the test"; rc=1; }
  return $rc; }
# #264 R8 (review r3 B3-1, destructive: stops and starts the OTS stack through its guardian): an update that leaves a
# p6 overlay whose MOUNTSHA no longer matches the image. The guardian stops the stack (as at an OTA reboot), the
# manifest's MOUNTSHA is set wrong and a marker appended to the p6 overlay, the guardian starts it: the converge is
# refused and the overlay containers are kept stopped; the guardian's later `--restart-exited` must NOT start them
# (rc wsl.10: it did after 30 s, the marker ran). Both files are restored from the golden copy and the stack is
# converged again on every exit path.
bchk_r8_hold_264() { local n=$1 rc=0 g=/etc/init.d/batman-payload-opentakserver D=/opt/batdata/apps/opentakserver GD=/usr/share/batman/payload-golden/opentakserver
  local man F=/app/venv/lib/python3.13/site-packages/opentakserver/eud_handler/EudHandler.py st i ran=0 l0
  fssh "$n" 10 "[ -x $g ] && [ -d $GD ]" || { echo "FAIL no guardian / golden on this node"; return 1; }
  ots_ready "$n" || { echo "FAIL OTS not ready before the test"; return 1; }
  man=$(fssh "$n" 10 "ls $D/*.manifest | head -1" | tr -d '\r')
  fssh "$n" 15 "cmp -s $GD/$(basename "$man") $man && cmp -s $GD/EudHandler-264.py $D/EudHandler-264.py" || { echo "FAIL p6 differs from the golden before the test"; return 1; }
  l0=$(fssh "$n" 10 'logread | grep -c "kept STOPPED on its old config"' | tr -d ' \r')
  fssh "$n" 90 "$g stop" >/dev/null 2>&1
  fssh "$n" 15 "sed -i 's/^\(MOUNTSHA [^ ]*EudHandler.py\) [0-9a-f]*\$/\1 0000000000000000000000000000000000000000000000000000000000000000/' $man && echo '# DV-R8-HOLD marker' >> $D/EudHandler-264.py"
  fssh "$n" 90 "$g start" >/dev/null 2>&1
  for i in $(seq 1 30); do sleep 5; fssh "$n" 10 'logread | grep -q "converge done"' && [ "$(fssh "$n" 10 'logread | grep -c "kept STOPPED on its old config"' | tr -d ' \r')" -gt "$l0" ] && break; done
  echo "payload-run: $(fssh "$n" 10 'logread | grep "kept STOPPED on its old config" | tail -2 | cut -c1-150' | tr -d '\r' | tr '\n' ' ')"
  [ "$(fssh "$n" 10 'logread | grep -c "kept STOPPED on its old config"' | tr -d ' \r')" -gt "$l0" ] || { echo "FAIL the refused converge did not hold the overlay containers"; rc=1; }
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do sleep 5; st=$(fssh "$n" 10 "docker inspect -f '{{.State.Status}}' ots_eud_handler" | tr -d '\r'); [ "$st" = running ] && ran=1; done
  echo "ots_eud_handler over 60 s after the converge: $([ $ran = 1 ] && echo "STARTED (marker: $(fssh "$n" 10 "docker exec ots_eud_handler grep -c DV-R8-HOLD $F" | tr -d '\r'))" || echo "kept stopped")"
  [ $ran = 0 ] || { echo "FAIL the held overlay container was started (the guardian's restart path ignored the hold: review r3 B3-1)"; rc=1; }
  fssh "$n" 15 "cp -p $GD/$(basename "$man") $man && cp -p $GD/EudHandler-264.py $D/EudHandler-264.py" || echo "WARN restore from the golden failed"
  fssh "$n" 90 "$g restart" >/dev/null 2>&1
  for i in $(seq 1 36); do sleep 5; ots_ready "$n" && break; done
  ots_ready "$n" || { echo "FAIL OTS not ready after the restore"; rc=1; }
  echo "after restore: marker in ots_eud_handler: $(fssh "$n" 10 "docker exec ots_eud_handler grep -c DV-R8-HOLD $F" | tr -d '\r') (expect 0); hold file: $(fssh "$n" 10 "$RDR"'ls "$R"/batman-payload-opentakserver.mountsha-hold 2>/dev/null | wc -l' | tr -d '\r') (expect 0)"
  return $rc; }
# #264 review r2 A2-1 (destructive on a broken build: it crash-loops cot_parser): an authenticated (8089) user in an
# OTS group ends its session while cot_parser is busy. cot_parser's 8089 disconnect branch BINDS <uid> to the
# user's groups (cot_parser.py:989); if the eud handler has deleted <uid> by then, the bind is a 404 that kills
# cot_parser, and the unacked disconnect is redelivered first after every restart: a crash loop (up to 24 h).
# Setup: a group membership for 'administrator' (ADS-B, OUT; removed on every exit path), a 600-CoT burst from the
# bench node so cot_parser lags, the 8089 session ends. Asserted: no "crash ots_cot_parser" in the guardian ledger,
# no "no queue '<uid>'" in the broker log, cot_parser running with its queue drained. Negative control, rc wsl.8
# (node 04, 2026-10-12): 5 x "queue.bind ... not_found: no queue 'DVRE061117-V'", 6 x crash ots_cot_parser; the
# loop ended only when the membership was removed.
bchk_group_disc_264() { local ots=$1 peer=$2 run o rc=0 V VC c0 c1 i
  [ -n "$peer" ] && [ "$peer" != "$ots" ] && up "$peer" || { echo "SKIP-REASON: no generator peer (BENCH_NODE '$peer' unset, == OTS_NODE or down)"; return 3; }
  [ "$(ots_ctr "$ots")" = "$OTS_N" ] || { echo "FAIL OTS not $OTS_N/$OTS_N before the test"; return 1; }
  o=$(timeout 60 ssh -o BatchMode=yes -o LogLevel=ERROR -o ConnectTimeout=8 "root@$ots" 'docker exec -i ots_cot_parser python3 -' < "$REPO/scripts/node/ots-test-client-cert.py" 2>&1)
  echo "$o" | grep -q '^OK test client cert' || { echo "FAIL could not issue the test client cert — not verified"; return 1; }
  run=DVGD$(date +%H%M%S); V=$run-V; VC=$run-Vc
  c0=$(fssh "$ots" 20 "docker inspect -f '{{.State.StartedAt}}' ots_cot_parser" | tr -d ' \r')
  [ -n "$c0" ] || { echo "FAIL cannot read ots_cot_parser's StartedAt — not verified"; return 1; }
  o=$(echo "insert into groups_users (user_id, group_id, direction, enabled) select u.id, g.id, 'OUT', true from \"user\" u, groups g where u.username = 'administrator' and g.name = 'ADS-B' returning user_id, group_id;" | ots_sql "$ots")
  echo "test membership added: $(echo "$o" | head -1)"
  case "$o" in [0-9]*"|"[0-9]*) ;; *) echo "FAIL could not add the test membership — not verified"; return 1 ;; esac
  ( timeout 60 ssh -o BatchMode=yes -o LogLevel=ERROR -o ConnectTimeout=8 "root@$peer" "sleep 5; n=\$(date +%s); t=\$(date -u -d @\$n +%Y-%m-%dT%H:%M:%S.000Z); i=1; while [ \$i -le 600 ]; do printf '<event version=\"2.0\" uid=\"$run-L-%s\" type=\"a-f-G-U-C\" how=\"h-e\" time=\"%s\" start=\"%s\" stale=\"%s\"><point lat=\"25.03\" lon=\"121.56\" hae=\"10\" ce=\"9999999\" le=\"9999999\"/><detail><contact callsign=\"$run-L\"/></detail></event>' \$i \$t \$t \$t; i=\$((i+1)); done | nc $ots 8088 >/dev/null 2>&1; echo burst sent" ) > "$DIR/$run.burst" 2>&1 &
  o=$(timeout 60 ssh -o BatchMode=yes -o LogLevel=ERROR -o ConnectTimeout=8 "root@$ots" "docker exec -i -e TARGET=172.20.0.12 -e V=$V -e VC=$VC -e HOLD=8 -e CA=/app/ots/ca/ca.pem -e CERT=/tmp/dv-client.pem -e KEY=/tmp/dv-client.key ots_cot_parser python3 -" < "$REPO/scripts/node/eud-ssl-victim-264.py" 2>&1 | tr -d '\r')
  wait; echo "8089 group member: $o; bench: $(cat "$DIR/$run.burst")"
  for i in 1 2 3 4 5 6 7 8 9; do sleep 10; done
  c1=$(fssh "$ots" 20 "docker inspect -f '{{.State.StartedAt}}' ots_cot_parser" | tr -d ' \r')
  o=$(fssh "$ots" 20 'docker logs --since 3m rabbitmq 2>&1 | grep -c "no queue '"'$V'"'"' | tr -d ' \r')
  echo "ots_cot_parser StartedAt $c0 -> $c1 (a crash restarts it); broker \"no queue '$V'\": ${o:-?}"
  [ "$c1" = "$c0" ] || { echo "FAIL cot_parser crashed after the group member's disconnect (r2 A2-1 crash loop)"; rc=1; }
  [ "${o:-1}" = 0 ] || { echo "FAIL cot_parser's group bind hit a deleted <uid> queue"; rc=1; }
  # every exit path below removes the membership (also the recovery from a crash loop: no group, no bind)
  o=$(echo "delete from groups_users where user_id = (select id from \"user\" where username = 'administrator') and group_id = (select id from groups where name = 'ADS-B') returning user_id;" | ots_sql "$ots")
  echo "test membership removed: $(echo "$o" | head -1)"
  fssh "$ots" 15 'docker exec ots_cot_parser rm -f /tmp/dv-client.pem /tmp/dv-client.key' >/dev/null 2>&1
  # recovery (a broken build: the guardian's next restart processes the poison message once the group is gone): wait
  # up to 180 s for $OTS_N/$OTS_N and a drained, consumed cot_parser queue, so the node is left usable either way
  for i in $(seq 1 18); do
    o=$(fssh "$ots" 20 'docker exec rabbitmq rabbitmqctl -q list_queues name messages consumers 2>/dev/null | grep "^cot_parser'"$(printf '	')"'"' | tr -d '\r' | tr '	' ' ')
    [ "$(ots_ctr "$ots")" = "$OTS_N" ] && [ "$o" = "cot_parser 0 1" ] && break; sleep 10; done
  echo "cot_parser queue: $o (expect 0 messages, 1 consumer)"; case "$o" in "cot_parser 0 1") ;; *) echo "FAIL cot_parser not consuming a drained queue within 180 s"; rc=1 ;; esac
  r264_clean "$ots" "$run"
  [ "$(ots_ctr "$ots")" = "$OTS_N" ] || { echo "FAIL OTS not $OTS_N/$OTS_N after the test"; rc=1; }
  return $rc; }
# #264 review round 3 (2026-10-12): each suite below reproduced its finding on node 04 with rc wsl.10 first (the
# negative control, logs in the register "Code review round 3") and must PASS on the fixed build.
ssl264() {   # $1 ots, $2 uid, $3 callsign, $4 hold s, $5 extra plain events, $6 delay between them (an 8089 session)
  timeout 400 ssh -o BatchMode=yes -o LogLevel=ERROR -o ConnectTimeout=8 "root@$1" "docker exec -i -e TARGET=172.20.0.12 -e V=$2 -e VC=$3 -e HOLD=$4 -e N=${5:-0} -e DELAY=${6:-0.5} -e CA=/app/ots/ca/ca.pem -e CERT=/tmp/dv-client.pem -e KEY=/tmp/dv-client.key ots_cot_parser python3 -" < "$REPO/scripts/node/eud-ssl-client-264.py" 2>&1 | tr -d '\r'; }
cert264() { timeout 60 ssh -o BatchMode=yes -o LogLevel=ERROR -o ConnectTimeout=8 "root@$1" "docker exec -i -e CN=${2:-administrator} ots_cot_parser python3 -" < "$REPO/scripts/node/ots-test-client-cert.py" 2>&1 | grep -q '^OK test client cert'; }
# R14 / A3-2. Since review r5 no client input makes identification or a message raise (a CoT without start is now
# recorded), so the two handlers are driven by WHITE-BOX fault injection (review r6 B6-2): "<stage> <uid>" in
# /tmp/batman-264-fi inside ots_eud_handler (its private tmpfs); the first matching CoT of a session raises once.
#  (1) ident: the identification raises after the uid is set -> R14 resets it (log line), the next CoT identifies
#      again and is STORED (rc wsl.12: the device was never recorded, FK);
#  (2) message: one message raises -> dropped (log line), the session goes on, its next CoT stored; no traceback
#      ending a child (rc wsl.10: KeyError ended the child, an orphan queue left);
#  (3) hostile metadata (review r5 B5-1): phone "555-123-4567" (BigInteger), an os over 255 characters, a __group
#      without role -> the device is recorded and its CoT stored (162af3a: never recorded).
# Every session ends properly (no empty queue left). Negative control of the injection: rc wsl.14 (no _fi): 0 lines.
fi264() { fssh "$1" 20 "docker exec ots_eud_handler sh -c 'printf \"%s\" \"$2\" > /tmp/batman-264-fi'"; }
chk_exception_264() { local ots=$1 peer=$2 run o rc=0 t0 t1 k0 k1 m0 m1 u
  [ -n "$peer" ] && [ "$peer" != "$ots" ] && up "$peer" || { echo "SKIP-REASON: no generator peer (BENCH_NODE '$peer' unset, == OTS_NODE or down)"; return 3; }
  [ "$(ots_ctr "$ots")" = "$OTS_N" ] || { echo "FAIL OTS not $OTS_N/$OTS_N before the test"; return 1; }
  run=DVEX$(date +%H%M%S)
  exlog() { fssh "$ots" 20 'docker exec ots_eud_handler sh -c "grep -c \"'"$1"'\" \$(ls -t /app/ots/logs/eud_handler_tcp.log* | head -1)"' | tr -d ' \r'; }
  k0=$(exlog "identification raised RuntimeError"); isint "$k0" || k0=0
  m0=$(exlog "a message raised RuntimeError"); isint "$m0" || m0=0
  t0=$(fssh "$ots" 20 'docker logs ots_eud_handler 2>&1 | grep -c "Exception occurred during processing"' | tr -d ' \r'); isint "$t0" || t0=0
  fi264 "$ots" "ident $run-B"; echo "  peer: $(s264 "$peer" "$ots" "$run" twice UID="$run-B")"
  fi264 "$ots" "message $run-M"; echo "  peer: $(s264 "$peer" "$ots" "$run" twice UID="$run-M")"
  fssh "$ots" 20 "docker exec ots_eud_handler rm -f /tmp/batman-264-fi" >/dev/null
  echo "  peer: $(s264 "$peer" "$ots" "$run" hostile UID="$run-H")"; sleep 6
  k1=$(exlog "identification raised RuntimeError"); isint "$k1" || k1=0
  m1=$(exlog "a message raised RuntimeError"); isint "$m1" || m1=0
  t1=$(fssh "$ots" 20 'docker logs ots_eud_handler 2>&1 | grep -c "Exception occurred during processing"' | tr -d ' \r'); isint "$t1" || t1=0
  echo "handler: R14 \"identification raised RuntimeError\" +$((k1 - k0)) (expect 1); \"a message raised RuntimeError ... dropped\" +$((m1 - m0)) (expect 1); container tracebacks +$((t1 - t0)) (expect 0)"
  [ $((k1 - k0)) = 1 ] || { echo "FAIL the injected identification fault was not handled by R14 (no line; rc wsl.14 has no injection)"; rc=1; }
  [ $((m1 - m0)) = 1 ] || { echo "FAIL the injected message fault was not dropped by the per-message handler"; rc=1; }
  [ "$t1" = "$t0" ] || { echo "FAIL a raising CoT ended a child (traceback)"; rc=1; }
  for u in B M H; do
    o=$(r264_stored "$ots" "$run-$u"); echo "stored CoT of $run-$u: ${o:-?} (expect >= 1)"
    isint "$o" && [ "$o" -ge 1 ] || { echo "FAIL $run-$u was left unrecorded (AAR gap)"; rc=1; }
  done
  o=$(echo "select phone_number, length(os), team_role is null from euds where uid = '$run-H';" | ots_sql "$ots"); echo "EUD row of the hostile metadata: [$o] (expect 5551234567|255|t)"
  [ "$o" = "5551234567|255|t" ] || { echo "FAIL the hostile-metadata row is not as written by R14 (r5)"; rc=1; }
  o=$(fssh "$ots" 20 'docker exec rabbitmq rabbitmqctl -q list_queues name messages consumers 2>/dev/null | grep "^'"$run"'"' | tr -d '\r')
  [ -n "$o" ] && echo "$o" | sed 's/^/  left: /'
  o=$(echo "$o" | awk -F'\t' 'NF>=3 && $2==0 {n++} END {print n+0}')
  [ "$o" = 0 ] || { echo "FAIL $o EMPTY queue(s) left behind by the sessions (they did not end properly)"; rc=1; }
  r264_clean "$ots" "$run"
  [ "$(ots_ctr "$ots")" = "$OTS_N" ] || { echo "FAIL OTS not $OTS_N/$OTS_N after the test"; rc=1; }
  return $rc; }
# R10 (review r3 B3-5, the user's decision 2026-10-12): an 8089 user must not claim the uid of ANOTHER user's device.
# A test user (no password: cert only) is created and removed by this suite. Asserted: user 2's session claiming user
# 1's uid is refused (log line), consumes none of user 1's queues, and the EUD row keeps user_id 1. Callsigns stay
# shared (two users naming their phones alike is common). Negative control, rc wsl.10 (2026-10-12): user 2 consumed
# the queue and the row's user_id went 1 -> 2.
chk_owner_8089_264() { local ots=$1 run o rc=0 V r0 r1 u1 c
  [ "$(ots_ctr "$ots")" = "$OTS_N" ] || { echo "FAIL OTS not $OTS_N/$OTS_N before the test"; return 1; }
  run=DVO9$(date +%H%M%S); V=$run-V
  u1=$(echo "select id from \"user\" where username = 'administrator';" | ots_sql "$ots"); isint "$u1" || { echo "FAIL no administrator user — not verified"; return 1; }
  echo "delete from \"user\" where username = 'dv-264-u2';" | ots_sql "$ots" >/dev/null   # left by an interrupted run (r8 B8-6)
  o=$(echo "insert into \"user\" (username, active, fs_uniquifier) values ('dv-264-u2', true, md5(random()::text)) returning id;" | ots_sql "$ots" | head -1)
  isint "$o" || { echo "FAIL could not create the test user ($o) — not verified"; return 1; }
  cert264 "$ots" administrator || { echo "FAIL cert"; rc=1; }
  echo "user 1: $(ssl264 "$ots" "$V" "$V-c1" 4)"; sleep 3
  r0=$(fssh "$ots" 20 'docker exec ots_eud_handler_ssl sh -c "grep -c \"belongs to another user\" \$(ls -t /app/ots/logs/eud_handler_ssl.log* | head -1)"' | tr -d ' \r'); isint "$r0" || r0=0
  cert264 "$ots" dv-264-u2 || { echo "FAIL cert"; rc=1; }
  ( ssl264 "$ots" "$V" "$V-c2" 12 > "$DIR/$run.u2" ) & sleep 6
  c=$(fssh "$ots" 20 'docker exec rabbitmq rabbitmqctl -q list_queues name consumers 2>/dev/null | grep "^'"$V"'	" | cut -f2' | tr -d ' \r')
  echo "consumers of user 1's queue $V while user 2 claims it: [${c:-none}] (expect 0 or none)"
  case "$c" in ""|0) ;; *) echo "FAIL user 2 consumes user 1's queue"; rc=1 ;; esac
  wait; echo "user 2: $(cat "$DIR/$run.u2")"; sleep 3
  r1=$(fssh "$ots" 20 'docker exec ots_eud_handler_ssl sh -c "grep -c \"belongs to another user\" \$(ls -t /app/ots/logs/eud_handler_ssl.log* | head -1)"' | tr -d ' \r'); isint "$r1" || r1=0
  [ "$r1" -gt "$r0" ] && echo "refused (handler log)" || { echo "FAIL no refusal line"; rc=1; }
  o=$(echo "select user_id from euds where uid = '$V';" | ots_sql "$ots"); echo "EUD row $V user_id: $o (expect $u1)"
  [ "$o" = "$u1" ] || { echo "FAIL the row was taken over by user 2"; rc=1; }
  fssh "$ots" 15 'docker exec ots_cot_parser rm -f /tmp/dv-client.pem /tmp/dv-client.key' >/dev/null 2>&1
  r264_clean "$ots" "$run"
  o=$(echo "delete from \"user\" where username = 'dv-264-u2' returning id;" | ots_sql "$ots" | head -1); echo "test user removed: $o"
  [ "$(echo "select count(*) from \"user\" where username = 'dv-264-u2';" | ots_sql "$ots")" = 0 ] || { echo "FAIL test user left behind"; rc=1; }
  [ "$(ots_ctr "$ots")" = "$OTS_N" ] || { echo "FAIL OTS not $OTS_N/$OTS_N after the test"; rc=1; }
  return $rc; }
# #264 R7/R16 at the margin (tier B; review r6 A6-1/B6-1, A2-5's R7 refusal node test): ots_eud_handler's memory
# limit is lowered to 768m for one rto-264 run, the #156 resource reconciler paused by its operator flag (it put the
# profile's value back within 5 s otherwise); the flag is removed on every exit path and the reconciler's restore is
# asserted. 16 zombies + 16 reconnects do not fit: the R7 reserve must refuse (log), a memcg OOM kill may only take a
# session (oom_score_adj 1000), never the listener (StartedAt unchanged), and every admission is serialized (0
# "unserialized"). Negative controls: rc wsl.11 (no R16): the listener OOM-killed, 0/16; rc wsl.13 run with the lock
# held from outside (the author's mistake, review r6): 53 unserialized admissions, 4 OOM kills.
bchk_rto768_264() { local ots=$1 p1=$2 p2=$3 rc=0 m0 m1 t0 r
  mlim() { fssh "$ots" 20 'c=$(docker inspect -f "{{.Id}}" ots_eud_handler); cat /sys/fs/cgroup/docker/$c/memory.max' | tr -d ' \r'; }
  m0=$(mlim); isint "$m0" || { echo "FAIL cannot read ots_eud_handler's memory.max — not verified"; return 1; }
  # the admission lock must be free before the run (review r7: the rc13 flip ran with an outside holder)
  o=$(fssh "$ots" 20 "docker exec ots_eud_handler python3 -c \"import fcntl, os; fd = os.open('/tmp/batman-264-admit.lock', os.O_RDWR | os.O_CREAT, 0o600); fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB); print('FREE')\"" | tr -d '\r')
  echo "admission lock before the run: ${o:-held or unreadable}"; [ "$o" = FREE ] || { echo "FAIL the admission lock is held before the run — not verified"; return 1; }
  fssh "$ots" 20 'touch /tmp/batman-ots-pause && docker update --memory 768m ots_eud_handler >/dev/null' || rc=1
  m1=$(mlim); echo "limit for the run: $m1 (expect 805306368; profile value $m0)"
  if [ "$m1" = 805306368 ]; then
    RTO_FLIP=1 chk_rto_264 "$ots" "$p1" "$p2" 8088; r=$?; [ "$r" = 0 ] || rc=$r
    m1=$(mlim); echo "limit at the end of the run: $m1 (expect 805306368: held for the whole run)"; [ "$m1" = 805306368 ] || { echo "FAIL the limit changed during the run"; rc=1; }
  else
    echo "FAIL the limit was not lowered — not verified"; rc=1
  fi
  fssh "$ots" 20 'rm -f /tmp/batman-ots-pause' >/dev/null
  t0=$SECONDS; while [ $((SECONDS - t0)) -lt 60 ]; do sleep 5; m1=$(mlim); [ "$m1" = "$m0" ] && break; done
  echo "limit after the run: $m1 (expect $m0, put back by the #156 reconciler)"
  [ "$m1" = "$m0" ] || { fssh "$ots" 20 "docker update --memory $m0 ots_eud_handler" >/dev/null; echo "FAIL the reconciler did not restore the limit within 60 s (restored by the suite: $(mlim))"; rc=1; }
  return $rc; }
# Broker policy (review r3, resources): a departed 8089 group member's queue is rebound to its groups by cot_parser
# (cot_parser.py:989) when cot_parser is busy, and kept filling for nobody (rc wsl.10: 12 messages in 40 s). The
# policy "batman-264-eud-queues" (rabbitmq-definitions.json) caps every per-EUD queue at 500 messages / 1 MiB (oldest
# dropped) and deletes it after 24 h unused; cot_parser's own queue is excluded. Asserted, behaviourally: the departed
# member's queue holds at most 500 after 1500 group messages; the cot_parser queue carries no such policy. Negative
# control, rc wsl.10 (2026-10-12): no policy; with 520 messages the queue reached only 366 (< 500, so the count did not
# discriminate: register impl-8): 1500, measured once cot_parser has routed them: 1502 held, no cap.
chk_queue_policy_264() { local ots=$1 peer=$2 run o rc=0 m
  [ -n "$peer" ] && [ "$peer" != "$ots" ] && up "$peer" || { echo "SKIP-REASON: no generator peer (BENCH_NODE '$peer' unset, == OTS_NODE or down)"; return 3; }
  [ "$(ots_ctr "$ots")" = "$OTS_N" ] || { echo "FAIL OTS not $OTS_N/$OTS_N before the test"; return 1; }
  cert264 "$ots" administrator || { echo "FAIL could not issue the test client cert — not verified"; return 1; }
  run=DVQP$(date +%H%M%S)
  o=$(echo "insert into groups_users (user_id, group_id, direction, enabled) select u.id, g.id, d, true from \"user\" u, groups g, (values ('OUT'), ('IN')) v(d) where u.username = 'administrator' and g.name = 'ADS-B' returning direction;" | ots_sql "$ots" | tr '\n' ' ')
  echo "test memberships: $o"
  ( timeout 60 ssh -o BatchMode=yes -o LogLevel=ERROR -o ConnectTimeout=8 "root@$peer" "sleep 4; n=\$(date +%s); t=\$(date -u -d @\$n +%Y-%m-%dT%H:%M:%S.000Z); i=1; while [ \$i -le 600 ]; do printf '<event version=\"2.0\" uid=\"$run-L-%s\" type=\"a-f-G-U-C\" how=\"h-e\" time=\"%s\" start=\"%s\" stale=\"%s\"><point lat=\"1\" lon=\"1\" hae=\"0\" ce=\"9\" le=\"9\"/><detail><contact callsign=\"$run-L\"/></detail></event>' \$i \$t \$t \$t; i=\$((i+1)); done | nc $ots 8088 >/dev/null 2>&1; echo burst" ) > "$DIR/$run.burst" 2>&1 &
  echo "member V1 (leaves while cot_parser is busy): $(ssl264 "$ots" "$run-V1" "$run-V1c" 7)"; wait; sleep 40
  echo "V1's queue after it left: $(fssh "$ots" 20 'docker exec rabbitmq rabbitmqctl -q list_queues name messages consumers policy 2>/dev/null | grep "^'"$run"'-V1	"' | tr -d '\r' | tr '\t' ' ')"
  o=$(ssl264 "$ots" "$run-V2" "$run-V2c" 10 1500 0); echo "member V2 sends 1500 to the group: $o"
  # cot_parser routes about 24 CoT/s (rc wsl.10): measure only once it has routed the burst (its queue empty), or the
  # count shows the routing rate, not the cap (impl-8: 366 after 520 and 364 after 1500, both read 15 s after)
  for i in $(seq 1 36); do
    m=$(fssh "$ots" 20 'docker exec rabbitmq rabbitmqctl -q list_queues name messages 2>/dev/null | grep "^cot_parser	"' | tr -d '\r' | awk '{print $2}')
    [ "$m" = 0 ] && break; sleep 5
  done; echo "cot_parser queue drained: ${m:-?} left after ~$((i * 5)) s"
  [ "$m" = 0 ] || { echo "FAIL cot_parser did not route the burst within 180 s: nothing to measure"; rc=1; }
  case "$o" in *"sent 1501"*) ;; *) echo "FAIL the burst did not send 1500 CoT: nothing to measure"; rc=1 ;; esac
  o=$(fssh "$ots" 20 'docker exec rabbitmq rabbitmqctl -q list_queues name messages consumers policy 2>/dev/null | grep "^'"$run"'-V1	"' | tr -d '\r' | tr '\t' ' ')
  echo "V1's queue now: [$o]"; m=$(echo "$o" | awk '{print $2}')
  if ! isint "$m"; then echo "FAIL V1's queue is gone: nothing to measure (an 8089 queue is never deleted, the expiry is 24 h)"; rc=1
  elif [ "$m" -le 500 ]; then echo "capped: $m <= 500 messages"
  else echo "FAIL the departed member's queue holds $m messages (no cap)"; rc=1; fi
  case "$o" in ""|*batman-264-eud-queues*) ;; *) echo "FAIL V1's queue carries no batman-264-eud-queues policy"; rc=1 ;; esac
  o=$(fssh "$ots" 20 'docker exec rabbitmq rabbitmqctl -q list_queues name policy 2>/dev/null | grep "^cot_parser	"' | tr -d '\r' | tr '\t' ' ')
  echo "cot_parser queue: [$o] (expect no policy)"; case "$o" in *batman*) echo "FAIL the cot_parser queue is under the per-EUD policy"; rc=1 ;; esac
  o=$(echo "delete from groups_users where user_id = (select id from \"user\" where username = 'administrator') and group_id = (select id from groups where name = 'ADS-B') returning direction;" | ots_sql "$ots" | tr '\n' ' ')
  echo "test memberships removed: $o"
  fssh "$ots" 15 'docker exec ots_cot_parser rm -f /tmp/dv-client.pem /tmp/dv-client.key' >/dev/null 2>&1
  r264_clean "$ots" "$run"
  [ "$(ots_ctr "$ots")" = "$OTS_N" ] || { echo "FAIL OTS not $OTS_N/$OTS_N after the test"; rc=1; }
  return $rc; }
# Capacity (the user's target 2026-10-12: 16 phones per node): 16 identifying idle 8088 sessions at once from two
# addresses (8 from the bench node, 8 from the mesh node: PER_IP_MAX 8). Asserted: all 16 subscribed, none refused,
# no OOM kill, anonymous memory at its peak <= 85 % of the container's memory.max (room for a 17th and for the
# sessions' traffic). Negative control, rc wsl.10 (512 MiB): 474 MiB anon of 512 = 93 % (16 fitted with ~21 MiB left).
chk_cap16_264() { local ots=$1 p1=$2 p2=$3 run o rc=0 r0 r1 sub peak mx oom0 oom1 a st0
  [ -n "$p1" ] && [ -n "$p2" ] && [ "$p1" != "$ots" ] && [ "$p2" != "$ots" ] && up "$p1" && up "$p2" || { echo "SKIP-REASON: needs two client nodes besides OTS_NODE ($p1, $p2)"; return 3; }
  [ "$(ots_ctr "$ots")" = "$OTS_N" ] || { echo "FAIL OTS not $OTS_N/$OTS_N before the test"; return 1; }
  run=DVC16$(date +%H%M%S)
  cg='c=$(docker inspect -f "{{.Id}}" ots_eud_handler); d=/sys/fs/cgroup/docker/$c'
  r0=$(fssh "$ots" 20 'docker exec ots_eud_handler sh -c "grep -cE \"refusing session\" \$(ls -t /app/ots/logs/eud_handler_tcp.log* | head -1)"' | tr -d ' \r'); isint "$r0" || r0=0
  oom0=$(fssh "$ots" 20 "$cg"'; awk "/oom_kill/{print \$2}" $d/memory.events' | tr -d ' \r')
  st0=$(fssh "$ots" 20 'docker inspect -f "{{.State.StartedAt}}" ots_eud_handler' | tr -d '\r')
  ( s264 "$p1" "$ots" "$run-a" idle N=8 HOLD=90 > "$DIR/$run.p1" ) & ( s264 "$p2" "$ots" "$run-b" idle N=8 HOLD=90 > "$DIR/$run.p2" ) &
  wait; echo "  peers: $(cat "$DIR/$run.p1") / $(cat "$DIR/$run.p2")"
  peak=0
  for i in 1 2 3 4 5 6; do sleep 5; a=$(fssh "$ots" 20 "$cg"'; awk "/^anon /{print \$2}" $d/memory.stat' | tr -d ' \r'); isint "$a" && [ "$a" -gt "$peak" ] && peak=$a; done
  mx=$(fssh "$ots" 20 "$cg"'; cat $d/memory.max' | tr -d ' \r')
  sub=$(fssh "$ots" 20 'docker exec ots_eud_handler sh -c "grep -c \"subscribed '"$run"'-\" \$(ls -t /app/ots/logs/eud_handler_tcp.log* | head -1)"' | tr -d ' \r')
  r1=$(fssh "$ots" 20 'docker exec ots_eud_handler sh -c "grep -cE \"refusing session\" \$(ls -t /app/ots/logs/eud_handler_tcp.log* | head -1)"' | tr -d ' \r'); isint "$r1" || r1=0
  oom1=$(fssh "$ots" 20 "$cg"'; awk "/oom_kill/{print \$2}" $d/memory.events' | tr -d ' \r')
  echo "16 at once: subscribed $sub (expect 16), refused $((r1 - r0)) (expect 0), oom_kill $oom0 -> $oom1, anon peak $((peak >> 20)) MiB of memory.max $(( ${mx:-0} >> 20 )) MiB"
  [ "$sub" = 16 ] || { echo "FAIL not all 16 sessions subscribed"; rc=1; }
  [ "$r1" = "$r0" ] || { echo "FAIL sessions refused under the 16-phone target"; rc=1; }
  [ "$oom0" = "$oom1" ] || { echo "FAIL the eud container was OOM-killed"; rc=1; }
  # an OOM kill of the listener restarts the container in a NEW cgroup (memory.events from 0): compare StartedAt too
  [ "$(fssh "$ots" 20 'docker inspect -f "{{.State.StartedAt}}" ots_eud_handler' | tr -d '\r')" = "$st0" ] && [ -n "$st0" ] \
    || { echo "FAIL ots_eud_handler restarted during the test (its sessions all dropped)"; rc=1; }
  # review r4 B4-4: at 1280m the 85 % bound no longer discriminates the lock; the log does. The 16 admissions take
  # the lock one after the other: "lock taken" and "lock released" strictly alternate, and none is unserialized
  o=$(fssh "$ots" 20 'docker exec ots_eud_handler sh -c "tail -n 400 \$(ls -t /app/ots/logs/eud_handler_tcp.log* | head -1) | grep -E \"admission of .*lock (taken|released)|admitting unserialized\" | tail -n 32"' | tr -d '\r' \
      | awk '/admitting unserialized/ {u++} /lock taken/ {if (h) bad++; h=1; t++} /lock released/ {h=0} END {printf "%d %d %d", t, bad+0, u+0}')
  echo "admission lock over the last 16 sessions: taken / overlapping / unserialized = $o (expect 16 0 0)"
  [ "$o" = "16 0 0" ] || { echo "FAIL the admissions were not serialized by the lock"; rc=1; }
  isint "$mx" && [ $((peak * 100)) -le $((mx * 85)) ] || { echo "FAIL anon peak above 85 % of memory.max (no room left above 16 phones)"; rc=1; }
  s264 "$p1" "$ots" "$run-a" cleanup >/dev/null; s264 "$p2" "$ots" "$run-b" cleanup >/dev/null; sleep 8
  r264_clean "$ots" "$run"
  [ "$(ots_ctr "$ots")" = "$OTS_N" ] || { echo "FAIL OTS not $OTS_N/$OTS_N after the test"; rc=1; }
  return $rc; }
# Broker memory alarm (review r4 A4-8/B4-5, r5 A5-5): no blocked_connection_timeout any more, so a broker alarm
# longer than 60 s must not end the sessions; they cache and deliver after it. The watermark is dropped to 1 MB for
# ~75 s (every publisher is blocked), then put back to the value in rabbitmq-extra.conf; a detached timer on the
# node restores it after 150 s whatever happens to this script. Asserted: the alarm was raised (blocked
# connections seen), the client's session was not cut (no CONNLOST), every CoT sent is stored after the alarm.
# Negative control: by code only (rc wsl.12 had blocked_connection_timeout=60: pika's ConnectionBlockedTimeout
# closed the connection, R13 ended the client session) - rc12 is no longer installed (stated, register r5).
chk_alarm_264() { local ots=$1 peer=$2 run o rc=0 wm blk sent lost distinct
  [ -n "$peer" ] && [ "$peer" != "$ots" ] && up "$peer" || { echo "SKIP-REASON: no generator peer (BENCH_NODE '$peer' unset, == OTS_NODE or down)"; return 3; }
  [ "$(ots_ctr "$ots")" = "$OTS_N" ] || { echo "FAIL OTS not $OTS_N/$OTS_N before the test"; return 1; }
  wm=$(fssh "$ots" 20 'docker exec rabbitmq sh -c "sed -n \"s/^vm_memory_high_watermark.absolute = //p\" /etc/rabbitmq/conf.d/99-batman.conf"' | tr -d ' \r')
  case "$wm" in [0-9]*MB) ;; *) echo "FAIL unreadable configured watermark [$wm] — not verified"; return 1 ;; esac
  run=DVAL$(date +%H%M%S)
  ( timeout 200 ssh -o BatchMode=yes -o LogLevel=ERROR -o ConnectTimeout=8 "root@$peer" "TARGET=$ots RUN=$run N=110 sh -s" < "$REPO/scripts/node/cot-stream-264.sh" > "$DIR/$run.gen" 2>&1 ) &
  sleep 10
  fssh "$ots" 20 "docker exec rabbitmq rabbitmqctl -q set_vm_memory_high_watermark absolute 1MB >/dev/null; (trap '' HUP; sleep 150; docker exec rabbitmq rabbitmqctl -q set_vm_memory_high_watermark absolute $wm) </dev/null >/dev/null 2>&1 &" >/dev/null
  sleep 15
  blk=$(fssh "$ots" 20 'docker exec rabbitmq rabbitmqctl -q list_connections state 2>/dev/null | grep -c block' | tr -d ' \r')
  echo "broker alarm raised (watermark 1MB): blocked/blocking connections ${blk:-?}"
  isint "$blk" && [ "$blk" -ge 1 ] || { echo "FAIL the alarm did not block publishers — not verified"; rc=1; }
  sleep 60
  fssh "$ots" 20 "docker exec rabbitmq rabbitmqctl -q set_vm_memory_high_watermark absolute $wm" >/dev/null; echo "watermark restored to $wm after ~75 s of alarm"
  wait; o=$(cat "$DIR/$run.gen"); echo "generator: $(echo "$o" | tr '\n' ' ')"
  lost=$(echo "$o" | sed -n 's/^CONNLOST \([0-9]*\)$/\1/p'); sent=$(echo "$o" | sed -n 's/^SENT \([0-9]*\)$/\1/p')
  [ -z "$lost" ] && echo "the client's session lasted through the alarm" || { echo "FAIL the session was cut during the alarm (CONNLOST at $lost)"; rc=1; }
  sleep 20
  distinct=$(echo "select count(distinct uid) from cot where uid like '$run-%';" | ots_sql "$ots" | tr -d ' \r')
  echo "sent ${sent:-?}, stored distinct ${distinct:-?}"
  isint "$sent" && [ "$sent" -ge 100 ] && [ "$distinct" = "$sent" ] || { echo "FAIL not every CoT sent through the alarm was stored"; rc=1; }
  rm -f "$DIR/$run.gen"; r264_clean "$ots" "$run"
  [ "$(ots_ctr "$ots")" = "$OTS_N" ] || { echo "FAIL OTS not $OTS_N/$OTS_N after the test"; rc=1; }
  return $rc; }
# The RTO returns (field scenario, the user 2026-10-12: the OTS node is carried by the RTO): the node walks out of
# range and is back within ~2 min, so the team's 16 sessions are still on the server as zombies (no FIN) when the
# same 16 phones reconnect at once: 32 sessions on one listener. Zombies: 8 from each peer, then black-holed there
# (scripts/node/rto-264.sh, own nft table, self-expiring). Reconnects: the same 16 uids from inside ots_cot_parser and
# opentakserver (scripts/node/rto-reconnect-264.py; distinct br-ots addresses, so PER_IP_MAX is not what is measured:
# every phone has its own address in the field). Asserted: every reconnect kept for 120 s (a refused phone records
# no CoT: an AAR gap), ots_eud_handler not restarted, no OOM kill; then the zombies are reaped and nothing is left.
# Negative control, rc wsl.11 (768m, 2026-10-12): the memcg OOM killer killed the listener parent 10 s in, the
# container restarted, 0/16 kept (r4/rto-rc11.log).
rto264() { timeout "${3:-60}" ssh -o BatchMode=yes -o LogLevel=ERROR -o ConnectTimeout=8 "root@$1" "TARGET=$OTS_NODE RUN=$2 ACTION=$4 PORT=${5:-8088} N=8 sh -s" < "$REPO/scripts/node/rto-264.sh" 2>&1 | tr -d '\r'; }
# review r4 A4-12 / B4-8: the zombies have pending downlink (a third peer streams broadcasts while they are black-holed,
# as zombie-264 does); every reconnect's subscription and stored CoT are asserted, not only its socket; cleanup kills
# only the run's own clients; the same case on 8089 (mTLS: the zombies use `openssl s_client` with a 1-day test cert,
# the reconnects the same cert inside the containers; all copies removed after).
# review r6: every admission of the run serialized (0 "admitting unserialized" lines: the rc wsl.13 flip ran with
# the lock held from outside and nobody noticed, A6-1/B6-1); per phone >= 2 DISTINCT reports stored (a duplicate
# of one report no longer passes, A6-7/B6-8); 8088: the 16 zombies' ends see their phones' reconnects live (R6 reap
# of a phone back from another address); 8089: a non-admin test user (A6-9), the downlink generator outside the
# measured container (B6-8), and a SECOND flap 30 s after the first (A6-2: without R17 48 sessions on the
# listener; with R17 each return ends the previous session): the second reconnects all kept, >= 3 reports per phone.
chk_rto_264() { local ots=$1 p1=$2 p2=$3 port=${4:-8088} run rc=0 cg st0 st1 o0 o1 r0 r1 sub k1 k2 i a peak=0 mx ctr tgt c u0 u1 gen nb=2 want=2 hold=170 ru flip=${RTO_FLIP:-0} m0 m1 v
  [ -n "$p1" ] && [ -n "$p2" ] && [ "$p1" != "$ots" ] && [ "$p2" != "$ots" ] && up "$p1" && up "$p2" || { echo "SKIP-REASON: needs two client nodes besides OTS_NODE ($p1, $p2)"; return 3; }
  [ "$(ots_ctr "$ots")" = "$OTS_N" ] || { echo "FAIL OTS not $OTS_N/$OTS_N before the test"; return 1; }
  run=DVRTO$(date +%H%M%S); ctr=ots_eud_handler; tgt=172.20.0.10; gen=ots_eud_handler_ssl
  if [ "$port" = 8089 ]; then
    ctr=ots_eud_handler_ssl; tgt=172.20.0.12; run=DVRTS$(date +%H%M%S); gen=ots_eud_handler; nb=3; want=3
    echo "delete from \"user\" where username = 'dv-264-rto';" | ots_sql "$ots" >/dev/null   # left by an interrupted run (r8 B8-6)
    ru=$(echo "insert into \"user\" (username, active, fs_uniquifier) values ('dv-264-rto', true, md5(random()::text)) returning id;" | ots_sql "$ots" | head -1)
    isint "$ru" || { echo "FAIL could not create the non-admin test user ($ru) — not verified"; return 1; }
    rto_user_rm() {   # every early return (r7 B7-7, r8 B8-6): the test user and the container-internal certs
      echo "delete from \"user\" where username = 'dv-264-rto';" | ots_sql "$ots" >/dev/null
      fssh "$ots" 20 'for c in ots_cot_parser opentakserver ots_eud_handler ots_eud_handler_ssl; do docker exec $c rm -f /tmp/dv-client.pem /tmp/dv-client.key; done' >/dev/null; }
    cert264 "$ots" dv-264-rto || { echo "FAIL could not issue the test client cert — not verified"; rto_user_rm; return 1; }
    # the container-internal /tmp/dv-client.{pem,key} (tmpfs of ots_cot_parser / opentakserver, not the node's /tmp)
    for c in pem key; do
      case $c in pem) f=/tmp/dv-client.pem ;; *) f=/tmp/dv-client.key ;; esac
      fssh "$ots" 20 "docker exec ots_cot_parser cat $f" > "$DIR/$run.$c" || { echo "FAIL cert copy"; rto_user_rm; return 1; }
      for n in "$p1:$run-a" "$p2:$run-b"; do timeout 20 ssh -o BatchMode=yes -o LogLevel=ERROR "root@${n%%:*}" "umask 077; cat > /tmp/run/batman-dv/${n#*:}.$c; (trap '' HUP; sleep 900; rm -f /tmp/run/batman-dv/${n#*:}.$c) </dev/null >/dev/null 2>&1 &" < "$DIR/$run.$c"; done   # self-expiring (r5 B5-8)
      timeout 20 ssh -o BatchMode=yes -o LogLevel=ERROR "root@$ots" "docker exec -i opentakserver sh -c 'umask 077; cat > $f'" < "$DIR/$run.$c"
      timeout 20 ssh -o BatchMode=yes -o LogLevel=ERROR "root@$ots" "docker exec -i ots_eud_handler sh -c 'umask 077; cat > $f'" < "$DIR/$run.$c"
      timeout 20 ssh -o BatchMode=yes -o LogLevel=ERROR "root@$ots" "docker exec -i ots_eud_handler_ssl sh -c 'umask 077; cat > $f'" < "$DIR/$run.$c"
      timeout 20 ssh -o BatchMode=yes -o LogLevel=ERROR "root@$ots" "H=/tmp/run/batman-dv; { [ -d \$H ] || mkdir -m 700 \$H; }; umask 077; cat > \$H/$run-a.$c; (trap '' HUP; sleep 900; rm -f \$H/$run-a.$c) </dev/null >/dev/null 2>&1 &" < "$DIR/$run.$c"
    done; rm -f "$DIR/$run.pem" "$DIR/$run.key"
  fi
  cg='c=$(docker inspect -f "{{.Id}}" '"$ctr"'); d=/sys/fs/cgroup/docker/$c'
  st0=$(fssh "$ots" 20 "docker inspect -f '{{.State.StartedAt}}' $ctr" | tr -d '\r')
  o0=$(fssh "$ots" 20 "$cg"'; awk "/oom_kill /{print \$2}" $d/memory.events' | tr -d ' \r')
  r0=$(fssh "$ots" 20 "docker exec $ctr sh -c 'cat \$(ls -t \$(ls -t /app/ots/logs/eud_handler_tcp.log* | head -1)* | head -1) \$(ls -t \$(ls -t /app/ots/logs/eud_handler_ssl.log* | head -1)* | head -1) | grep -c \"refusing session\"'" | tr -d ' \r'); isint "$r0" || r0=0
  mx=$(fssh "$ots" 20 "$cg"'; cat $d/memory.max' | tr -d ' \r')
  u0=$(fssh "$ots" 20 "docker exec $ctr sh -c 'cat \$(ls -t \$(ls -t /app/ots/logs/eud_handler_tcp.log* | head -1)* | head -1) \$(ls -t \$(ls -t /app/ots/logs/eud_handler_ssl.log* | head -1)* | head -1) | grep -c \"admitting unserialized\"'" | tr -d ' \r'); isint "$u0" || u0=0
  m0=$(fssh "$ots" 20 "docker exec $ctr sh -c 'cat \$(ls -t \$(ls -t /app/ots/logs/eud_handler_tcp.log* | head -1)* | head -1) \$(ls -t \$(ls -t /app/ots/logs/eud_handler_ssl.log* | head -1)* | head -1) | grep -c \"MiB free (BATMAN-264-R7)\"'" | tr -d ' \r'); isint "$m0" || m0=0
  echo "the team ($port): 02 $(rto264 "$p1" "$run-a" 60 start "$port") / 03 $(rto264 "$p2" "$run-b" 60 start "$port")"; sleep 8
  sub=$(fssh "$ots" 20 "docker exec $ctr sh -c 'cat \$(ls -t \$(ls -t /app/ots/logs/eud_handler_tcp.log* | head -1)* | head -1) \$(ls -t \$(ls -t /app/ots/logs/eud_handler_ssl.log* | head -1)* | head -1) | grep -cE \"subscribed $run-[ab]-\"'" | tr -d ' \r')
  echo "subscribed $sub (expect 16)"; [ "$sub" = 16 ] || { echo "FAIL the team's 16 sessions are not all subscribed: nothing to measure"; rc=1; }
  echo "RTO out of range: 02 $(rto264 "$p1" "$run-a" 30 blackhole "$port") / 03 $(rto264 "$p2" "$run-b" 30 blackhole "$port")"
  # downlink pending towards the zombies: 20 broadcasts from a third address (rc wsl.13: a generator on 03 was refused
  # as the 9th session of that address and the zombies stayed idle)
  ( fssh "$ots" 60 "docker exec -i -e TARGET=172.20.0.10 -e RUN=$run-c $gen python3 -" < "$REPO/scripts/node/rto-downlink-264.py" > "$DIR/$run.dl" 2>&1 ) &
  sleep 5
  # the return: 4 per container address (r10 B10-5: 8 from one container sat exactly at PER_IP_MAX, and one stray
  # established socket made the 9th a refusal, the ❓-2 signature); every phone has its own address in the field
  for c in "ots_cot_parser $run-a 1" "ots_eud_handler $run-a 5" "opentakserver $run-b 1" "ots_eud_handler_ssl $run-b 5"; do
    read -r rctr rrun rfirst <<< "$c"
    ( fssh "$ots" 260 "docker exec -i -e TARGET=$tgt -e PORT=$port -e RUN=$rrun -e FIRST=$rfirst -e N=4 -e HOLD=$hold -e CA=/app/ots/ca/ca.pem -e CERT=/tmp/dv-client.pem -e KEY=/tmp/dv-client.key $rctr python3 -" < "$REPO/scripts/node/rto-reconnect-264.py" > "$DIR/$run.$rctr.1" 2>&1 ) &
    sleep 1   # ssh launches 1 s apart: dropbear (-T 3) resets the 6th simultaneous connection from one host (rc wsl.20 re-run)
  done
  if [ "$port" = 8089 ]; then
    # the second flap, 30 s later: inside R17's wait for the first return's superseded sessions, so three generations
    # of 16 are alive on the listener (the capacity claim; the user's decision 2, r10 B10-4: 1536m on this listener).
    # The 16 come from the OTS node itself on br-ots (openssl, host side: not in the measured cgroup) and the four
    # containers, 4 + 3/3/3/3 on top of the first return's 4 each: no address holds more than 7 of PER_IP_MAX 8 (r9,
    # r10 A10-1/B10-5: 8 on one address sat at the limit, one stray socket = a refusal, ❓-2). PER_IP_MAX is not what
    # is measured: every phone has its own address in the field. The census below names a stray before the flap.
    sleep 30
    echo "before the second flap, established sockets to $ctr per client address (hex): $(fssh "$ots" 20 "docker exec $ctr awk '\$4 == \"01\" && \$2 ~ /:1F99\$/ { split(\$3, a, \":\"); n[a[1]]++ } END { for (k in n) printf \"%s=%d \", k, n[k] }' /proc/net/tcp" | tr -d '\r') (expect 4 each on the four containers: an 8 after the flap is a refusal)"
    # the host leg first and alone (rc wsl.20 re-run: launched as the 6th simultaneous ssh it was reset by dropbear
    # -T 3 and printed nothing; flip test 6 parallel -> 1 reset, 3 -> 0), then the container legs 1 s apart
    o=$(timeout 60 ssh -o BatchMode=yes -o LogLevel=ERROR -o ConnectTimeout=8 "root@$ots" "TARGET=$tgt RUN=$run-a ACTION=start PORT=8089 N=4 TAG=.g3 sh -s" < "$REPO/scripts/node/rto-264.sh" 2>&1 | tr -d '\r')
    echo "second return, $run-a 1-4 from the OTS node: $o"
    case "$o" in *STARTED*) ;; *) echo "FAIL the host leg of the second return did not run (its ssh produced no STARTED: a reset connection, not a refusal)"; rc=1 ;; esac
    for c in "ots_cot_parser $run-a 5 3" "ots_eud_handler $run-a 8 1" "ots_eud_handler $run-b 1 2" "opentakserver $run-b 3 3" "ots_eud_handler_ssl $run-b 6 3"; do
      read -r rctr rrun rfirst rn <<< "$c"
      ( fssh "$ots" 260 "docker exec -i -e TARGET=$tgt -e PORT=$port -e RUN=$rrun -e FIRST=$rfirst -e N=$rn -e HOLD=$((hold - 30)) -e CA=/app/ots/ca/ca.pem -e CERT=/tmp/dv-client.pem -e KEY=/tmp/dv-client.key $rctr python3 -" < "$REPO/scripts/node/rto-reconnect-264.py" > "$DIR/$run.2.$rctr.f$rfirst" 2>&1 ) &
      sleep 1
    done
  fi
  for i in $(seq 1 22); do sleep 5; a=$(fssh "$ots" 20 "$cg"'; awk "/^anon /{print \$2}" $d/memory.stat' | tr -d ' \r'); isint "$a" && [ "$a" -gt "$peak" ] && peak=$a; done; wait
  if [ "$port" = 8088 ]; then   # KEPT per run: $run-a's two legs, $run-b's two legs
    cat "$DIR/$run.ots_cot_parser.1" "$DIR/$run.ots_eud_handler.1" > "$DIR/$run.ots_cot_parser" 2>/dev/null
    cat "$DIR/$run.opentakserver.1" "$DIR/$run.ots_eud_handler_ssl.1" > "$DIR/$run.opentakserver" 2>/dev/null
    rm -f "$DIR/$run".*.1
  fi
  if [ "$port" = 8089 ]; then
    o=$(cat "$DIR/$run".*.1 2>/dev/null | grep -c " closed after "); rm -f "$DIR/$run".*.1
    c=$(fssh "$ots" 20 "docker exec $ctr sh -c 'cat \$(ls -t \$(ls -t /app/ots/logs/eud_handler_tcp.log* | head -1)* | head -1) \$(ls -t \$(ls -t /app/ots/logs/eud_handler_ssl.log* | head -1)* | head -1) | grep -cE \"session of $run-[ab]-[0-9]+ superseded by\"'" | tr -d ' \r')
    echo "the first returns ended after the second: $o of 16 closed (expect 16); sessions superseded this run: ${c:-?} (expect 32: the team by the first return, the first return by the second; R17)"
    [ "$o" = 16 ] && [ "$c" = 32 ] || { echo "FAIL R17 on the second return: $o of 16 closed, ${c:-?} of 32 superseded (rc wsl.15: closed by the end-at-once code, not superseded)"; rc=1; }
    o=$(timeout 30 ssh -o BatchMode=yes -o LogLevel=ERROR -o ConnectTimeout=8 "root@$ots" "TARGET=$tgt RUN=$run-a ACTION=est PORT=8089 sh -s" < "$REPO/scripts/node/rto-264.sh" 2>&1 | tr -d '\r')
    echo "second return of $run-a 1-4 (OTS node side) still connected: $o"; echo "KEPT ${o#EST } / 4" > "$DIR/$run.ots_cot_parser"
    cat "$DIR/$run".2.* > "$DIR/$run.opentakserver" 2>/dev/null; rm -f "$DIR/$run".2.*
  fi
  grep -hv " kept$" "$DIR/$run.ots_cot_parser" "$DIR/$run.opentakserver" 2>/dev/null
  echo "downlink generator: $(cat "$DIR/$run.dl" 2>/dev/null | tail -1)"; grep -q '^SENT 20$' "$DIR/$run.dl" || { echo "FAIL the downlink generator did not send (the zombies had no pending data)"; rc=1; }; rm -f "$DIR/$run.dl"
  k1=$(grep -o "KEPT [0-9]*" "$DIR/$run.ots_cot_parser" | awk '{s+=$2} END{print s+0}'); k2=$(grep -o "KEPT [0-9]*" "$DIR/$run.opentakserver" | awk '{s+=$2} END{print s+0}')
  st1=$(fssh "$ots" 20 "docker inspect -f '{{.State.StartedAt}}' $ctr" | tr -d '\r')
  o1=$(fssh "$ots" 20 "$cg"'; awk "/oom_kill /{print \$2}" $d/memory.events' | tr -d ' \r')
  r1=$(fssh "$ots" 20 "docker exec $ctr sh -c 'cat \$(ls -t \$(ls -t /app/ots/logs/eud_handler_tcp.log* | head -1)* | head -1) \$(ls -t \$(ls -t /app/ots/logs/eud_handler_ssl.log* | head -1)* | head -1) | grep -c \"refusing session\"'" | tr -d ' \r'); isint "$r1" || r1=0
  sub=$(fssh "$ots" 20 "docker exec $ctr sh -c 'cat \$(ls -t \$(ls -t /app/ots/logs/eud_handler_tcp.log* | head -1)* | head -1) \$(ls -t \$(ls -t /app/ots/logs/eud_handler_ssl.log* | head -1)* | head -1) | grep -cE \"subscribed $run-[ab]-\"'" | tr -d ' \r')
  u1=$(fssh "$ots" 20 "docker exec $ctr sh -c 'cat \$(ls -t \$(ls -t /app/ots/logs/eud_handler_tcp.log* | head -1)* | head -1) \$(ls -t \$(ls -t /app/ots/logs/eud_handler_ssl.log* | head -1)* | head -1) | grep -c \"admitting unserialized\"'" | tr -d ' \r'); isint "$u1" || u1=0
  a=$(echo "select count(*) from cot where sender_uid like '$run-a-%' or sender_uid like '$run-b-%';" | ots_sql "$ots" | tr -d ' \r')
  # per phone: one DISTINCT report per session (the team's, each return's), not a duplicate of one (review r6)
  c=$(echo "select count(*) from (select sender_uid from cot where sender_uid like '$run-a-%' or sender_uid like '$run-b-%' group by sender_uid having count(distinct start) >= $want) x;" | ots_sql "$ots" | tr -d ' \r')
  echo "reconnects kept $((${k1:-0} + ${k2:-0}))/16, subscribed $sub of $((16 * nb)) (team + returns), stored CoT $a (expect >= $((16 * nb))), refused $((r1 - r0)), unserialized admissions $((u1 - u0)), oom_kill $o0 -> $o1, StartedAt $st0 -> $st1, anon peak $((peak >> 20)) MiB of $(( ${mx:-0} >> 20 )) MiB"
  if [ "$flip" = 1 ]; then
    # rto768-264: the limit is below what 32 sessions need; the R7 reserve must refuse, an OOM may only take sessions
    m1=$(fssh "$ots" 20 "docker exec $ctr sh -c 'cat \$(ls -t \$(ls -t /app/ots/logs/eud_handler_tcp.log* | head -1)* | head -1) \$(ls -t \$(ls -t /app/ots/logs/eud_handler_ssl.log* | head -1)* | head -1) | grep -c \"MiB free (BATMAN-264-R7)\"'" | tr -d ' \r'); isint "$m1" || m1=0
    echo "R7 reserve refusals during the run: $((m1 - m0)) (expect >= 1 at this limit)"
    [ $((m1 - m0)) -ge 1 ] || { echo "FAIL the R7 reserve refused nothing although 32 sessions do not fit"; rc=1; }
    if [ "$o1" != "$o0" ]; then
      v=$(fssh "$ots" 20 "dmesg | grep 'Killed process' | tail -n $((o1 - o0))" | tr -d '\r')
      echo "$v" | sed 's/^/  oom: /'
      [ "$(echo "$v" | grep -c 'oom_score_adj:1000')" = $((o1 - o0)) ] || { echo "FAIL an OOM victim was not a session (oom_score_adj 1000)"; rc=1; }
    fi
  else
  [ "$((${k1:-0} + ${k2:-0}))" = 16 ] || { echo "FAIL not every reconnecting phone was kept (a refused phone records no CoT: an AAR gap)"; rc=1; }
  [ "$sub" = $((16 * nb)) ] || { echo "FAIL not every returning phone was subscribed"; rc=1; }
  isint "$a" && [ "$a" -ge $((16 * nb)) ] || { echo "FAIL stored ${a:-?} of $((16 * nb)) identifying CoT (duplicates may add)"; rc=1; }
  echo "phones with $want distinct reports stored (team + each return): ${c:-?} of 16"
  [ "$c" = 16 ] || { echo "FAIL ${c:-?} of 16 phones recorded on every session"; rc=1; }
  fi
  # both modes (review r7 A7-3/B7-3: rto768-264 never checked it, the rc13 contamination would have passed)
  [ "$u1" = "$u0" ] || { echo "FAIL $((u1 - u0)) admission(s) ran unserialized (the admission lock was held elsewhere): the run does not measure the shipping order"; rc=1; }
  [ -n "$st0" ] && [ "$st0" = "$st1" ] || { echo "FAIL $ctr restarted (the listener died with every session)"; rc=1; }
  [ "$flip" = 1 ] || [ "$o0" = "$o1" ] || { echo "FAIL memcg OOM kill"; rc=1; }
  # the zombies' ends (8088: R6 reap ~120 s after the black hole, their phones' reconnects still live until ~175 s;
  # 8089: ended by R17 at the return) must see their phones live: no disconnect, bindings kept
  sleep 20
  c=$(fssh "$ots" 20 "docker exec $ctr sh -c 'cat \$(ls -t \$(ls -t /app/ots/logs/eud_handler_tcp.log* | head -1)* | head -1) \$(ls -t \$(ls -t /app/ots/logs/eud_handler_ssl.log* | head -1)* | head -1) | grep -oE \"another session of $run-[ab]-[0-9]+ is live\" | sort -u | wc -l'" | tr -d ' \r')
  echo "phones whose stale session's end saw them live: ${c:-?} of 16"
  [ "$flip" = 1 ] || [ "$c" = 16 ] || { echo "FAIL ${c:-?} of 16 stale sessions ended seeing the phone live (not reaped, or took itself for the last session)"; rc=1; }
  echo "cleanup: 02 $(rto264 "$p1" "$run-a" 30 cleanup "$port") / 03 $(rto264 "$p2" "$run-b" 30 cleanup "$port")"; sleep 15
  [ "$port" = 8089 ] && echo "cleanup OTS node side: $(timeout 30 ssh -o BatchMode=yes -o LogLevel=ERROR -o ConnectTimeout=8 "root@$ots" "TARGET=$tgt RUN=$run-a ACTION=cleanup PORT=8089 TAG=.g3 sh -s" < "$REPO/scripts/node/rto-264.sh" 2>&1 | tr -d '\r')"
  [ "$port" = 8089 ] && fssh "$ots" 20 'for c in ots_cot_parser opentakserver ots_eud_handler ots_eud_handler_ssl; do docker exec $c rm -f /tmp/dv-client.pem /tmp/dv-client.key; done' >/dev/null
  rm -f "$DIR/$run".ots_cot_parser "$DIR/$run".opentakserver "$DIR/$run".*.1 "$DIR/$run".2.*
  r264_clean "$ots" "$run"
  if [ "$port" = 8089 ]; then
    o=$(echo "delete from \"user\" where username = 'dv-264-rto' returning id;" | ots_sql "$ots" | head -1); echo "test user removed: $o"
    [ "$(echo "select count(*) from \"user\" where username = 'dv-264-rto';" | ots_sql "$ots")" = 0 ] || { echo "FAIL test user left behind"; rc=1; }
  fi
  [ "$(ots_ctr "$ots")" = "$OTS_N" ] || { echo "FAIL OTS not $OTS_N/$OTS_N after the test"; rc=1; }
  return $rc; }
# #264 R17 (review r6) / R6 / R10, in FIELD ORDER (scripts/node/zombie-264.sh on the bench node): A = the EUD's
# first session, which goes stale (its port black-holed on the bench node both ways: no FIN/RST ever); then B = the
# same EUD reconnecting FROM THE SAME ADDRESS while A still holds its queues; D streams 1 CoT/s so the server has data
# pending towards A. Asserted on the OTS node: B's identification stops A's downlink at once (A logs "superseded", B
# logs "is back"; rc wsl.14 without R17: A lived ~116 s and took every other downlink message) and A, black-holed
# (nothing arrives), ends by the R17 deadline (its outage + 20 s, the user's decision 2026-10-12; rc wsl.15 ended it at
# once), A's end sees B live
# (no disconnect to cot_parser: its 8089 branch would unbind the user's missions, r2 A2-3), 1 consumer; 10/10 from C
# reach B right away (phase 1: no split) and again later (phase 2). Spoof leg: the same uid from ANOTHER address
# ($MESH_NODE) ends nothing ("both kept"; B is not superseded). The last end removes the idle queues (F3).
# R6's reap of a vanished phone that comes back from another address is asserted by rto-264 (16 zombies).
# Negative controls on node 04: upstream 1.7.13: the zombie kept its consumers, then 0/10; rc wsl.8 (busy guard):
# B held off ~2 min; rc wsl.14 (no R17): A not superseded, phase 1 split between A and B.
chk_zombie_264() { local ots=$1 peer=$2 run o rc=0 c t0 sup="" q apid bpid d0 d1
  [ -n "$peer" ] && [ "$peer" != "$ots" ] && up "$peer" || { echo "SKIP-REASON: no generator peer (BENCH_NODE '$peer' unset, == OTS_NODE or down)"; return 3; }
  [ "$(ots_ctr "$ots")" = "$OTS_N" ] || { echo "FAIL OTS not $OTS_N/$OTS_N before the test"; return 1; }
  run=DVZ$(date +%H%M%S); q="$run-A"
  zlog() { fssh "$ots" 20 'docker exec ots_eud_handler sh -c "grep -c \"'"$1"'\" \$(ls -t /app/ots/logs/eud_handler_tcp.log* | head -1) 2>/dev/null"' | tr -d ' \r'; }
  zpids() { fssh "$ots" 20 'docker exec ots_eud_handler sh -c "grep \"subscribed '"$q"'/\" \$(ls -t /app/ots/logs/eud_handler_tcp.log* | head -1) 2>/dev/null"' | sed -n 's/.* - eud_handler\[\([0-9]*\)\] - .*/\1/p' | tr -d '\r'; }
  cpdisc() { fssh "$ots" 20 'docker exec ots_cot_parser sh -c "grep -c \"Sending disconnect cot to '"$q"'\$\" /app/ots/logs/cot_parser.log 2>/dev/null"' | tr -d ' \r'; }
  d0=$(cpdisc); isint "$d0" || d0=0
  o=$(timeout 120 ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR -o ConnectTimeout=8 "root@$peer" "TARGET=$ots RUN=$run ACTION=start sh -s" < "$REPO/scripts/node/zombie-264.sh" 2>&1 | tr -d '\r')
  echo "$o" | sed 's/^/  peer: /'
  echo "$o" | grep -q '^BLACKHOLE [0-9]* 1$' || { echo "FAIL the black hole was not installed — not verified"; rc=1; }
  t0=$SECONDS
  # A's handler pid: the first "subscribed <q>/" line; wait (bounded) for its "superseded" line
  while [ $((SECONDS - t0)) -lt 20 ]; do
    sleep 2; apid=$(zpids | head -1)
    o=$(fssh "$ots" 20 'docker exec ots_eud_handler sh -c "grep \"eud_handler\['"${apid:-x}"'\] .*superseded by the device.s new session\" \$(ls -t /app/ots/logs/eud_handler_tcp.log* | head -1) 2>/dev/null"' | tr -d '\r')
    [ -n "$o" ] && { sup=$((SECONDS - t0)); break; }
  done
  bpid=$(zpids | sed -n 2p)
  echo "handler pids with \"subscribed $q/\": A [${apid:-none}] B [${bpid:-none}]"
  isint "$apid" && isint "$bpid" && [ "$apid" != "$bpid" ] || { echo "FAIL A and B are not both subscribed"; rc=1; }
  if [ -n "$sup" ]; then echo "A (pid $apid) superseded within ${sup} s of B's start (R17)"
  else echo "FAIL A was not superseded within 20 s (rc wsl.14 without R17: A lived ~116 s)"; rc=1; fi
  o=$(fssh "$ots" 20 'docker exec ots_eud_handler sh -c "grep -c \"eud_handler\['"${bpid:-x}"'\] .*device '"$q"' is back; its previous session (pid '"${apid:-x}"')\" \$(ls -t /app/ots/logs/eud_handler_tcp.log* | head -1) 2>/dev/null"' | tr -d ' \r')
  [ "${o:-0}" = 1 ] && echo "B logged that the device is back (A: downlink stopped)" || { echo "FAIL B did not log superseding A ($o)"; rc=1; }
  sleep 2
  c=$(fssh "$ots" 20 'docker exec rabbitmq rabbitmqctl -q list_queues name consumers 2>/dev/null | grep "^'"$q"'	" | cut -f2' | tr -d ' \r')
  echo "consumers of $q now: [$c] (expect 1 = B)"; [ "$c" = 1 ] || { echo "FAIL expected 1 consumer (B) on $q, got [$c]"; rc=1; }
  o=$(timeout 60 ssh -o BatchMode=yes -o LogLevel=ERROR -o ConnectTimeout=8 "root@$peer" "TARGET=$ots RUN=$run ACTION=phase1 sh -s" < "$REPO/scripts/node/zombie-264.sh" 2>&1 | tr -d '\r')
  echo "  peer: $o (A would still be alive here without R17)"
  echo "$o" | grep -q '^PHASE1 10$' || { echo "FAIL phase 1: B got $(echo "$o" | sed -n 's/^PHASE1 //p')/10 while A would still be alive (downlink split)"; rc=1; }
  # the user's decision (2026-10-12): the superseded A ends once quiet for 20 s (it is black-holed: nothing arrives)
  t0=$SECONDS; o=""
  while [ $((SECONDS - t0)) -lt 60 ] && [ -z "$o" ]; do sleep 5
    o=$(fssh "$ots" 20 'docker exec ots_eud_handler sh -c "grep \"eud_handler\['"${apid:-x}"'\] .*another session of '"$q"' is live\" \$(ls -t /app/ots/logs/eud_handler_tcp.log* | head -1) 2>/dev/null"' | tr -d '\r'); done
  [ -n "$o" ] && echo "A ended once quiet and its end saw B live (no disconnect, bindings kept)" || { echo "FAIL A's end did not log \"another session of $q is live\" within ~80 s of B's return"; rc=1; }
  o=$(fssh "$ots" 20 'docker exec ots_eud_handler sh -c "grep -c \"eud_handler\['"${apid:-x}"'\] .*superseded session of '"$q"' quiet for\" \$(ls -t /app/ots/logs/eud_handler_tcp.log* | head -1) 2>/dev/null"' | tr -d ' \r')
  [ "${o:-0}" = 1 ] && echo "A's end came from the quiet timeout (R17)" || { echo "FAIL A did not end by the R17 quiet timeout ($o)"; rc=1; }
  # spoof leg: the same uid from another address ends nothing
  if [ -n "$MESH_NODE" ] && [ "$MESH_NODE" != "$ots" ] && [ "$MESH_NODE" != "$peer" ] && up "$MESH_NODE"; then
    echo "  spoof from $MESH_NODE: $(s264 "$MESH_NODE" "$ots" "$run" twice UID="$q")"
    o=$(fssh "$ots" 20 'docker exec ots_eud_handler sh -c "grep -c \"eud_handler\['"${bpid:-x}"'\] .*superseded\" \$(ls -t /app/ots/logs/eud_handler_tcp.log* | head -1) 2>/dev/null"' | tr -d ' \r')
    c=$(fssh "$ots" 20 'docker exec rabbitmq rabbitmqctl -q list_queues name consumers 2>/dev/null | grep "^'"$q"'	" | cut -f2' | tr -d ' \r')
    echo "spoof: B superseded ${o:-?} (expect 0); consumers of $q after the spoof left: [$c] (expect 1 = B)"
    [ "${o:-1}" = 0 ] && [ "$c" = 1 ] || { echo "FAIL a client at another address took the device's downlink"; rc=1; }
  else
    echo "FAIL spoof leg: MESH_NODE '$MESH_NODE' unset, == OTS/BENCH node or down — not verified"; rc=1
  fi
  d1=$(cpdisc); isint "$d1" || d1=0
  echo "cot_parser disconnects for $q while B is live: $((d1 - d0)) (expect 0)"
  [ "$d1" = "$d0" ] || { echo "FAIL a disconnect was sent for the live EUD (8089: missions unbound, r2 A2-3)"; rc=1; }
  sleep 3
  o=$(timeout 60 ssh -o BatchMode=yes -o LogLevel=ERROR -o ConnectTimeout=8 "root@$peer" "TARGET=$ots RUN=$run ACTION=phase2 sh -s" < "$REPO/scripts/node/zombie-264.sh" 2>&1 | tr -d '\r')
  echo "  peer: $o"
  echo "$o" | grep -q '^PHASE2 10$' || { echo "FAIL phase 2: the live session B got $(echo "$o" | sed -n 's/^PHASE2 //p')/10"; rc=1; }
  o=$(timeout 60 ssh -o BatchMode=yes -o LogLevel=ERROR -o ConnectTimeout=8 "root@$peer" "TARGET=$ots RUN=$run ACTION=cleanup sh -s" < "$REPO/scripts/node/zombie-264.sh" 2>&1 | tr -d '\r')
  echo "  peer: $o"; echo "$o" | grep -q '^LEFT 0$' || { echo "FAIL peer cleanup left sessions ($o)"; rc=1; }
  sleep 8
  ots_sql "$ots" <<SQL
begin; delete from cot where uid like '$run-%'; delete from euds where uid like '$run-%'; commit;
SQL
  # B was the last session of the EUD: its end removes the idle, empty queues itself (F3); a queue left EMPTY is an
  # orphan (FAIL); one left holding messages is kept by design (a broadcast that landed after the last check)
  o=$(fssh "$ots" 30 'docker exec rabbitmq rabbitmqctl -q list_queues name messages consumers 2>&1 | grep "^'"$run"'"' | tr -d '\r')
  [ -n "$o" ] && echo "$o" | sed 's/^/  left: /'
  c=$(echo "$o" | awk -F'\t' 'NF>=3 && $2==0 {n++} END {print n+0}')
  [ "$c" = 0 ] || { echo "FAIL $c EMPTY queue(s) of the run left behind after their EUD's last session ended (orphans, F3)"; rc=1; }
  o=$(fssh "$ots" 60 'left=$(docker exec rabbitmq rabbitmqctl -q list_queues name 2>/dev/null | grep -c "^'"$run"'"); for q in $(docker exec rabbitmq rabbitmqctl -q list_queues name 2>/dev/null | grep "^'"$run"'"); do docker exec rabbitmq rabbitmqctl -q delete_queue "$q" >/dev/null 2>&1; done; echo "left-by-the-handler=$left"' | tr -d '\r')
  echo "rabbit per-EUD queues after the last session ended: $o (empty ones: FAIL above; ones holding messages: kept by design)"
  [ "$(ots_ctr "$ots")" = "$OTS_N" ] || { echo "FAIL OTS not $OTS_N/$OTS_N after the test"; rc=1; }
  return $rc; }
# #264 R7: memory per idle EUD session on the 8088 handler. N idle sessions from the peer (one CoT each, then
# silent); cgroup memory.current of ots_eud_handler before/after; the per-session cost must stay under
# EUD_MEM_MAX_MB (25; measured 22 on rc wsl.6 with the shared app, frozen heap and pre-warmed ORM: what is left
# is the session's own pika connection, ioloop thread, DB connection and the pages it touches). Negative
# control: upstream 1.7.13 costs 39 MB per session (8 sessions: 153 -> 465 MB,
# measured on node 04 2026-10-11, OOM at about the 10th client in the 512 MiB cgroup). Also asserted: no session
# refused, memory back near the baseline after the clients leave (no per-session leak), the run's EUD rows and
# per-EUD rabbit queues removed. The clients are nc sessions on the peer, killed by pattern at the end.
eud_mem_264() { fssh "$1" 20 'c=$(docker inspect -f "{{.Id}}" ots_eud_handler 2>/dev/null); cat /sys/fs/cgroup/docker/$c/memory.current 2>/dev/null' | tr -d ' \r'; }
# the handler logs to a file in its data volume (stdout only on a tty); count "refusing session from <peer>" lines
eud_refused_264() { fssh "$1" 20 'docker exec ots_eud_handler sh -c "grep -c \"refusing session from '"$2"'\" \$(ls -t /app/ots/logs/eud_handler_tcp.log* | head -1) 2>/dev/null"' | tr -d ' \r'; }
chk_eud_mem_264() { local ots=$1 peer=$2 n=6 run m0 m1 m2 d rc=0 o r0 H=/tmp/run/batman-dv
  [ -n "$peer" ] && [ "$peer" != "$ots" ] && up "$peer" || { echo "SKIP-REASON: no generator peer (BENCH_NODE '$peer' unset, == OTS_NODE or down)"; return 3; }
  [ "$(ots_ctr "$ots")" = "$OTS_N" ] || { echo "FAIL OTS not $OTS_N/$OTS_N before the test"; return 1; }
  m0=$(eud_mem_264 "$ots"); isint "$m0" || { echo "FAIL cannot read ots_eud_handler memory.current ([$m0]) — not verified"; return 1; }
  run=DVM$(date +%Y%m%d%H%M%S); r0=$(eud_refused_264 "$ots" "$peer"); isint "$r0" || r0=0
  o=$(timeout 90 ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR -o ConnectTimeout=8 "root@$peer" \
    "{ [ -d $H ] || mkdir -m 700 $H; } && [ -O $H ] && [ ! -L $H ] || { echo FAIL-scratch; exit 1; }; cat > $H/eud-idle-264.sh; for k in \$(seq 1 $n); do (trap '' HUP; TARGET=$ots RUN=$run HOLD=150 sh $H/eud-idle-264.sh \$k </dev/null >/dev/null 2>&1) & sleep 3; done; sleep 2; echo clients=\$(netstat -tn 2>/dev/null | grep -c \"$ots:8088 .*ESTABLISHED\")" \
    < "$REPO/scripts/node/eud-idle-client-264.sh" 2>&1 | tr -d '\r')
  echo "run id $run; $n idle sessions $peer -> $ots:8088: $o"
  case "$o" in *clients=$n) ;; *) echo "FAIL expected $n established sessions on the peer ($o) — not verified"; rc=1 ;; esac
  sleep 20; m1=$(eud_mem_264 "$ots"); isint "$m1" || { echo "FAIL memory.current unreadable after ([$m1]) — not verified"; return 1; }
  d=$(( (m1 - m0) / n / 1048576 ))
  echo "ots_eud_handler memory.current: before $((m0/1048576)) MiB, with $n idle sessions $((m1/1048576)) MiB -> $d MiB per session (limit ${EUD_MEM_MAX_MB:-25}; upstream 39, rc wsl.6 22)"
  [ "$d" -le "${EUD_MEM_MAX_MB:-25}" ] || { echo "FAIL $d MiB per idle session"; rc=1; }
  # the handler logs to a file in its data volume (stdout only on a tty): refusals of this peer, before vs after
  o=$(eud_refused_264 "$ots" "$peer"); isint "$o" || o=0
  [ "$o" -le "$r0" ] && echo "no session refused (file count $o)" || { echo "FAIL $((o - r0)) session(s) refused during the test (container memory at the limit)"; rc=1; }
  # kill by exact process name: a pgrep -f pattern naming the target matches this very shell and kills it first
  o=$(fssh "$peer" 30 'for p in $(pgrep -f "^sh /tmp/run/batman-dv/eud-idle-264.sh") $(pgrep -x nc) $(pgrep -f "^sleep 150$"); do kill $p 2>/dev/null; done; sleep 2; echo "clients left: $(pgrep -x nc | wc -l) (established: $(netstat -tn 2>/dev/null | grep -c ":8088 .*ESTABLISHED"))"' | tr -d '\r')
  echo "$o"; case "$o" in "clients left: 0 (established: 0)") ;; *) echo "FAIL peer cleanup did not end the sessions ($o)"; rc=1 ;; esac
  sleep 20; m2=$(eud_mem_264 "$ots"); isint "$m2" || m2=$m1
  echo "after the clients left: $((m2/1048576)) MiB (baseline $((m0/1048576)))"
  [ $(( (m2 - m0) / 1048576 )) -le 15 ] || { echo "FAIL memory did not return within 15 MiB of the baseline (leak)"; rc=1; }
  ots_sql "$ots" <<SQL
begin; delete from cot where uid like '$run-%'; delete from euds where uid like '$run-%'; commit;
SQL
  o=$(fssh "$ots" 60 'n=0; for q in $(docker exec rabbitmq rabbitmqctl -q list_queues name 2>/dev/null | grep "^'"$run"'"); do docker exec rabbitmq rabbitmqctl -q delete_queue "$q" >/dev/null 2>&1 && n=$((n+1)); done; echo "deleted=$n left=$(docker exec rabbitmq rabbitmqctl -q list_queues name 2>/dev/null | grep -c "^'"$run"'")"' | tr -d '\r')
  echo "rabbit per-EUD queues of this run: $o"; case "$o" in *left=0) ;; *) echo "FAIL cleanup: per-EUD rabbit queues of run $run left behind"; rc=1 ;; esac
  [ "$(ots_ctr "$ots")" = "$OTS_N" ] || { echo "FAIL OTS not $OTS_N/$OTS_N after the test"; rc=1; }
  return $rc; }
# #264 mechanism C, destructive (tier B): the transient cot_parser queue disappears while a client streams. Deleting
# it also cancels cot_parser's consumer, so cot_parser EXITS and the guardian restarts it (a ledger line, DRIFT for
# 600 s) — asserted, never worked around: the test only acts inside the broker and never starts/stops a container.
# Patched eud: the unroutable publishes come back (mandatory), the session re-declares the queue and retries, so
# sent == stored. Unpatched: every CoT in the window is dropped (negative control, measured before the overlay).
bchk_queue_gone_264() { local ots=$1 peer=$2 run rc=0 l0 l1 s st sd rec i t0
  [ -n "$peer" ] && [ "$peer" != "$ots" ] && up "$peer" || { echo "SKIP-REASON: no generator peer (BENCH_NODE '$peer' unset, == OTS_NODE or down)"; return 3; }
  [ "$(ots_ctr "$ots")" = "$OTS_N" ] || { echo "FAIL OTS not $OTS_N/$OTS_N before the test"; return 1; }
  l0=$(fssh "$ots" 15 "$RDR"'grep -c "crash ots_cot_parser" "$R"/batman-payload-opentakserver-restarts 2>/dev/null || echo 0' | tr -d ' \r')
  run=DVQ$(date +%Y%m%d%H%M%S); t0=$(date +%s)
  soak_ssh "$peer" "ROLE=cotgen TARGET=$ots RUN=$run DUR=150" | grep -q '^OK cotgen' || { echo "FAIL could not start the CoT generator on $peer"; return 1; }
  echo "run $run: $peer streams 5 CoT/s to $ots:8088 for 150 s; the cot_parser queue is deleted at +30 s"
  sleep 30
  # only an EMPTY queue is deleted (--if-empty, up to 20 tries 0.5 s apart): a message still in the queue at the
  # deletion is destroyed by the test, not lost by the product (02/03 full run 2026-10-13: "deleted with 2 ready
  # messages", exactly 2/740 lost). R5 is about what is published AFTER the queue is gone.
  o=$(fssh "$ots" 40 'for i in $(seq 1 20); do r=$(docker exec rabbitmq rabbitmqctl -q delete_queue cot_parser --if-empty 2>&1 | tail -1); case "$r" in *"successfully deleted"*) echo "$r (try $i)"; exit 0;; esac; sleep 0.5; done; echo "NOT DELETED: $r"' | tr -d '\r')
  echo "$o"; case "$o" in *"successfully deleted"*) ;; *) echo "FAIL the cot_parser queue was never empty to delete — the queue-gone path was not exercised"; return 1 ;; esac
  for i in $(seq 1 24); do l1=$(fssh "$ots" 15 "$RDR"'grep -c "crash ots_cot_parser" "$R"/batman-payload-opentakserver-restarts 2>/dev/null || echo 0' | tr -d ' \r'); [ "${l1:-0}" -gt "${l0:-0}" ] 2>/dev/null && break; sleep 5; done
  [ "${l1:-0}" -gt "${l0:-0}" ] 2>/dev/null && echo "ok cot_parser exited on the cancelled consumer and the guardian restarted it (ledger $l0 -> $l1)" \
    || { echo "FAIL no guardian restart of ots_cot_parser within 120 s of the queue deletion (ledger $l0 -> ${l1:-?}) — the fault was not what this test assumes"; rc=1; }
  # read the sent counter only after the generator has ENDED (DUR 150 s + margin): sampled while it still ran,
  # "sent" undercounts and stored > sent looked like duplicates (745/720, 740/720 on the rc: distinct == rows)
  while [ $(( $(date +%s) - t0 )) -lt 165 ]; do sleep 5; done
  s=$(soak_ssh "$peer" "ROLE=sample" | sed -n 's/.*cot_sent=\([0-9]*\).*/\1/p'); rec=$(soak_ssh "$peer" "ROLE=sample" | sed -n 's/.*cot_reconn=\([0-9]*\).*/\1/p')
  # at-least-once (user decision 2026-10-11): every (uid, time) the generator sent is stored at least once; a
  # duplicate row is reported, never a FAIL
  i=0; while [ "$i" -lt 12 ]; do sd=$(echo "select count(distinct (uid, timestamp)) from cot where uid like '$run-%';" | ots_sql "$ots" | tr -d ' \r'); [ "$sd" = "$s" ] && break; sleep 5; i=$((i+1)); done
  st=$(echo "select count(*) from cot where uid like '$run-%';" | ots_sql "$ots" | tr -d ' \r')
  echo "sent=$s stored rows=$st distinct (uid,time)=$sd duplicates=$((st - sd)) client reconnects=$rec"
  case "$s$st$sd" in ''|*[!0-9]*) echo "FAIL unreadable sent=[$s] stored=[$st] distinct=[$sd] — not verified"; rc=1 ;;
    *) [ "$s" -gt 100 ] || { echo "FAIL generator sent only $s"; rc=1; }
       [ "$sd" = "$s" ] && echo "ok every CoT sent across the queue-gone window was stored (at least once)" || { echo "FAIL lost $((s - sd))/$s CoT across the queue-gone window"; rc=1; } ;;
  esac
  fssh "$ots" 30 'docker exec ots_eud_handler sh -c "tail -400 \$(ls -t /app/ots/logs/eud_handler_tcp.log* | head -1)" | grep -ciE "declare refused|cache full|session end:"' | tr -d '\r' | sed 's|^|eud error lines (declare refused, cache full, session end): |'
  soak_ssh "$peer" "ROLE=down" | tail -1
  ots_sql "$ots" <<SQL >/dev/null
begin; delete from cot where uid like '$run-%' or sender_uid like '$run-%'; delete from points where device_uid like '$run-%'; delete from euds where uid like '$run-%'; commit;
SQL
  [ "$(ots_ctr "$ots")" = "$OTS_N" ] || { echo "FAIL OTS not $OTS_N/$OTS_N after the test"; rc=1; }
  # the guardian restart left the tenant DRIFT for the 600 s ledger window: wait it out so later suites judge a clean tenant
  for i in $(seq 1 70); do fssh "$ots" 10 "$RDR"'grep -q "\"status\":\"OK\"" "$R"/batman-payload-opentakserver-drift.json' && break; sleep 10; done
  fssh "$ots" 10 "$RDR"'grep -q "\"status\":\"OK\"" "$R"/batman-payload-opentakserver-drift.json' && echo "tenant verdict back to OK" || { echo "FAIL tenant verdict not OK 700 s after the test"; rc=1; }
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
  # distinct (uid, timestamp): the generator sends one batch of 5 uids per second (batches >= 1 s apart), so every
  # sent CoT is one distinct pair; distinct uid alone is always 5 (02/03 full run 2026-10-13: "stored=5" vs 8955 sent)
  echo "stored $(echo "select count(distinct (uid, timestamp)) from cot where uid like '$SOAK_RUN-S-%';" | ots_sql "$OTS_NODE")" >> "$DIR/soak.samples"
  echo "rows $(echo "select count(*) from cot where uid like '$SOAK_RUN-S-%';" | ots_sql "$OTS_NODE")" >> "$DIR/soak.samples"
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
chk_soak_cot() { local sent st rc re rows
  # at-least-once (#264 decision): every sent uid stored at least once; duplicates are reported, not failed
  sent=$(sv $((SOAK_MIN + 2)) "$BENCH_NODE" cot_sent); re=$(sv $((SOAK_MIN + 2)) "$BENCH_NODE" cot_reconn); st=$(sed -n 's/^stored //p' "$DIR/soak.samples"); rows=$(sed -n 's/^rows //p' "$DIR/soak.samples")
  { isint "$sent" && isint "$st"; } || { echo "FAIL CoT counters unreadable sent=[$sent] stored=[$st] — not verified"; return 1; }
  isint "$rows" || rows=$st
  # sent is sampled at minute SOAK_MIN+2 while the generator still runs; stored/rows are read at the end: >= sent
  echo "CoT sent (sampled)=$sent distinct (uid,time) stored=$st rows=$rows duplicates=$((rows - st)) client reconnects=$re"
  [ "$st" -ge "$sent" ] || { echo "FAIL CoT lost $((sent-st))/$sent"; return 1; }; }
# #286: meshled's health check must not write to the log every tick. Black-box on the REAL service under procd (SIGPIPE
# ignored there, which a shell reproduction does not get right). Per fleet node: a marker line is logged, 60 s later
# the lines after the marker are counted (the logread ring is FULL of these lines on an unfixed node, so a plain
# before/after count goes negative), and meshled must be alive and ticking: procd's pid for it unchanged and its
# CPU time incl. reaped children grown (a tick runs mount/ip/df every 5 s; a dead or stopped meshled would pass the
# line count on its own). Negative control: 1.5.9-wsl.21 writes one line per tick.
chk_286() { local n rc=0 id c p0 p1 u0 u1 v
  for n in $FLEET; do
    id=DV286$(date +%H%M%S)
    read -r p0 u0 <<< "$(fssh "$n" 20 'p=$(ubus call service list "{\"name\":\"meshled\"}" 2>/dev/null | sed -n "s/.*\"pid\": \([0-9]*\).*/\1/p" | head -1); echo "${p:-0} $(awk "{print \$14+\$15+\$16+\$17}" /proc/${p:-0}/stat 2>/dev/null || echo 0)"; logger -t dv286 "MARK '"$id"'"' | tr -d '\r')"
    sleep 60
    read -r p1 u1 c <<< "$(fssh "$n" 20 'p=$(ubus call service list "{\"name\":\"meshled\"}" 2>/dev/null | sed -n "s/.*\"pid\": \([0-9]*\).*/\1/p" | head -1); echo "${p:-0} $(awk "{print \$14+\$15+\$16+\$17}" /proc/${p:-0}/stat 2>/dev/null || echo 0) $(logread | sed -n "/dv286: MARK '"$id"'/,\$p" | grep -c "meshled.*write error")"' | tr -d '\r')"
    { isint "$u0" && isint "$u1" && isint "$c"; } || { echo "FAIL $n: counters unreadable pid=[$p0/$p1] cpu=[$u0/$u1] lines=[$c] — not verified"; rc=1; continue; }
    echo "$n: meshled write-error lines in the 60 s after the marker: $c; meshled pid $p0 -> $p1, cpu(utime+stime+cutime+cstime) $u0 -> $u1 jiffies"
    [ "$c" = 0 ] || { echo "FAIL $n: meshled still writes '$(fssh "$n" 10 'logread | grep "meshled.*write error" | tail -1' | tr -d '\r' | cut -c1-120)' every tick (#286)"; rc=1; }
    [ "$p0" != 0 ] && [ "$p0" = "$p1" ] && [ "$u1" -gt "$u0" ] || { echo "FAIL $n: meshled not alive and ticking (pid $p0 -> $p1, cpu $u0 -> $u1)"; rc=1; }
    # the two rewritten checks must still judge right: on a healthy node neither rootfs-ro nor no-ip is raised, and
    # the raw inputs the new patterns read are shown (the root line of /proc/mounts, br-ahwlan's inet line)
    # (#280: the state file is read from the run dir the node resolves, never from a /tmp name anyone can plant)
    v=$(fssh "$n" 20 "$RDR"'cat "$R/meshled.state" 2>/dev/null | tr "\n" " "; echo; grep " / " /proc/mounts | cut -c1-60; ip -4 addr show br-ahwlan 2>/dev/null | grep "inet " | head -1' | tr -d "\r")
    echo "$n: meshled state [$(echo "$v" | sed -n 1p)]; /proc/mounts root: $(echo "$v" | sed -n 2p); br-ahwlan: $(echo "$v" | sed -n 3p | sed "s/^ *//")"
    case "$(echo "$v" | sed -n 1p)" in *rootfs-ro*|*no-ip*) echo "FAIL $n: meshled raises rootfs-ro/no-ip on a healthy node — the rewritten check misjudges (#286)"; rc=1 ;; esac
    echo "$v" | sed -n 2p | grep -q " / overlay rw" || { echo "FAIL $n: /proc/mounts root line does not carry ' / overlay rw' — the new pattern would misjudge"; rc=1; }
    echo "$v" | sed -n 3p | grep -q "inet " || { echo "FAIL $n: br-ahwlan has no inet line — the no-ip check would fire"; rc=1; }
  done
  [ -n "$FLEET" ] || { echo "FAIL fleet empty"; rc=1; }
  return $rc; }
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
  for s in confinement-98 ots-up-162 drift-detect-156 payload-mgr-167 arbiter-167 payload-config-golden payload-conform flashgo-159 ots-cot-e2e-264 ots-cot-e2e-264-ssl eud-mem-264 zombie-264 amqp-close-264 name-guard-264; do
    suite "$s" "OTS_NODE $OTS_NODE is bcm2710 — not run (see ots-node-209)" ""
  done
elif up "$OTS_NODE"; then
  ots_probe "$OTS_NODE"
  suite confinement-98  "OTS container confinement — 9 axes ×6 (#98)"                       "chk_98 $OTS_NODE"
  suite ots-up-162       "OTS $OTS_N/$OTS_N running + postgres endpoint answers (#162)"                "chk_162 $OTS_NODE"
  suite drift-detect-156 "reconciler flags an unhardened decoy as DRIFT (#156, white-box)"   "chk_156 $OTS_NODE"
  suite payload-mgr-167  "OTS on the generic payload manager, old guardian gone (#167)"       "chk_167g $OTS_NODE"
  suite arbiter-167      "port/zone arbiter REFUSES a colliding tenant (#167, white-box)"      "chk_167a $OTS_NODE"
  suite payload-config-golden "p6 tenant config == baked golden + restart policy no (#274) + images present (payload-config-golden.md)" "chk_golden $OTS_NODE"
  suite payload-conform "live containers == manifest: running + config-fingerprint label + tenant label + MOUNTs (src/RO) + no orphans (#274)" "chk_conform $OTS_NODE"
  suite flashgo-159      "flash-and-go integrity — firstload enabled, offline copies (F2), canary runs, autocommit gate (#159/#216)" "chk_flashgo $OTS_NODE"
  if [ "$OTS_EUD" = overlay ]; then
  suite ots-cot-e2e-264  "CoT sent == stored per phase from $BENCH_NODE: P1 control, P2 deterministic truncation (A control / B #264-A), P3 burst; heartbeat (#264-B) NOT exercised (#268 B2)" "chk_cot_264 $OTS_NODE $BENCH_NODE"
  suite ots-cot-e2e-264-ssl "CoT sent == stored per phase on the SSL listener 8089 (mTLS, 1-day test cert for an existing user): P1 / P2 truncation / P3 burst — handler path via br-ots, not the mesh (#264)" "chk_cot_264_ssl $OTS_NODE"
  suite eud-mem-264 "ots_eud_handler memory per idle session from $BENCH_NODE: 6 sessions, <= 25 MiB each (upstream 39, OOM at ~10 clients), none refused, no leak after they leave (#264 R7)" "chk_eud_mem_264 $OTS_NODE $BENCH_NODE"
  suite zombie-264 "field order: the EUD's stale session (port black-holed on $BENCH_NODE, data pending) is ended at once when the same device comes back from the same address, its end keeps the live one's bindings (no disconnect); 10/10 at once and later; the same uid from $MESH_NODE ends nothing; the last end removes the idle queues (#264 R17/R6/R10/F3; rc wsl.14: zombie ~116 s, downlink split)" "chk_zombie_264 $OTS_NODE $BENCH_NODE"
  suite amqp-close-264 "the broker closes the streaming session's AMQP connection twice (rabbitmqctl close_connection): every CoT stored at least once, client session kept, 2 reconnects logged (#264 R4/R4b mechanism B; upstream: session dropped, CoT in flight lost)" "chk_amqp_close_264 $OTS_NODE $BENCH_NODE"
  suite name-guard-264 "(review r5: the callsign is refused as a queue, the device recorded) an 8088 client with callsign cot_parser gets no subscription: cot_parser queue keeps 1 consumer, log line, CoT still stored (#264 R10; upstream: the client consumes storage's queue)" "chk_name_guard_264 $OTS_NODE $BENCH_NODE"
  suite same-uid-end-264 "the same device opens a new session while the old one still sends: the downlink goes to the newest only (10/10), every report the old one sends is stored, the newer one's end disconnects nothing while the old one lives, the old one ends by the R17 deadline as the last session (#264 R17, the user's decisions 2026-10-12; rc wsl.14: split; the r8 assertions' negative control is offline R17 case 11 / AMQP #9 — rc wsl.16's log showed A deaf and a disconnect after B's end, unasserted then)" "chk_same_uid_end_264 $OTS_NODE $BENCH_NODE"
  suite callsign-share-264 "two devices with the same callsign and different uids both get broadcast traffic, no empty queue left (#264 R10, review r2 B2-4; wsl.8: 10/0)" "chk_callsign_share_264 $OTS_NODE $BENCH_NODE"
  suite owner-swap-264 "an 8088 client naming an 8089 user's uid as its callsign (and as its uid) is refused and consumes none of the user's queues (#264 R10, review r2 B2-2; wsl.8: the swap was subscribed)" "chk_owner_swap_264 $OTS_NODE $BENCH_NODE"
  suite admission-264 "admission: 8089 nothing allocated before the TLS handshake; 8088 exactly the 9th and 10th session per address refused; silent / empty-event sockets closed at 60 s; silent, ping-only or contact-less-streaming sockets hold up no phone; an <auth> flood spawns no thread per message (#264 R12, review r2 B2-6 / r3 B3-2/B3-3 / r6 / r7 B7-1 / r8 A8-2)" "chk_admission_264 $OTS_NODE $BENCH_NODE"
  suite exception-264 "injected faults: a raising identification is reset and the device recorded (R14), a raising message is dropped and the session goes on (A3-2); hostile metadata recorded (r5 B5-1); no traceback, no orphan queue (#264 review r6 B6-2; rc wsl.14: no injection)" "chk_exception_264 $OTS_NODE $BENCH_NODE"
  suite owner-8089-264 "an 8089 user claiming another user's uid is refused, consumes none of that user's queues, the row keeps its user (#264 R10, review r3 B3-5; wsl.10: taken over)" "chk_owner_8089_264 $OTS_NODE"
  suite queue-policy-264 "a departed 8089 group member's queue is capped at 500 messages by the broker policy; the cot_parser queue is not under it (#264 review r3, resources; wsl.10: grew without bound)" "chk_queue_policy_264 $OTS_NODE $BENCH_NODE"
  suite cap16-264 "16 identifying sessions at once from two addresses: all subscribed, none refused, no OOM, anon peak <= 85 % of memory.max (#264 capacity target 16; wsl.10: 93 %)" "chk_cap16_264 $OTS_NODE $BENCH_NODE $MESH_NODE"
  suite rto-264 "the RTO returns: 16 stale sessions (downlink pending) + the same 16 phones reconnecting at once on 8088; every reconnect kept, subscribed and recorded, the listener not restarted, no OOM (#264 R16, field scenario 2026-10-12; wsl.11 768m: the listener was OOM-killed)" "chk_rto_264 $OTS_NODE $BENCH_NODE $MESH_NODE 8088"
  suite alarm-264 "a broker memory alarm of ~75 s: the client session is not cut, every CoT is stored after it (#264 R9/R13, review r4 A4-8/B4-5)" "chk_alarm_264 $OTS_NODE $BENCH_NODE"
  suite rto-ssl-264 "the RTO returns TWICE on 8089 (mTLS, the tactical listener, a non-admin test user): every phone kept and recorded on every session, each return ends the previous session (R17), all admissions serialized (#264 R16/R17, review r4 B4-8, r6 A6-2)" "chk_rto_264 $OTS_NODE $BENCH_NODE $MESH_NODE 8089"
  else
    # #289: the gateway build — the overlay suites do not apply; the -289 suites take over
    . "$REPO/scripts/dv/gateway-289.sh"; gw_register
    for s in ots-cot-e2e-264 ots-cot-e2e-264-ssl eud-mem-264 zombie-264 amqp-close-264 name-guard-264 same-uid-end-264 callsign-share-264 owner-swap-264 admission-264 exception-264 owner-8089-264 queue-policy-264 cap16-264 rto-264 alarm-264 rto-ssl-264; do suite "$s" "superseded by the -289 suites on the gateway build (#289)" ""; done
  fi
else
  for s in confinement-98 ots-up-162 drift-detect-156 payload-mgr-167 arbiter-167 payload-config-golden payload-conform flashgo-159 ots-cot-e2e-264 ots-cot-e2e-264-ssl eud-mem-264 zombie-264 amqp-close-264 name-guard-264; do suite "$s" "OTS_NODE $OTS_NODE did not answer" ""; done
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
  suite meshled-286 "meshled's health check writes nothing to the log (no 'mount: write error' per tick) and keeps ticking, on every fleet node (#286)" "chk_286"
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
  # #270: the trigger's ssh outcome is evidence, not noise. A reboot/panic cuts the session (rc 255 is the normal
  # signature of a successful `echo c`); a node that was already wedged never takes the command at all, and the
  # boot_id change that follows then came from somewhere else (watchdog, brown-out). Record it so a later FAIL
  # can say "the trigger was not delivered" instead of blaming the capture.
  local trc t0 t1
  t0=$(date +%s); fssh "$n" 15 "$cmd" >/dev/null 2>&1; trc=$?; t1=$(date +%s)
  echo "trigger '$cmd' ssh rc=$trc in $((t1-t0))s (255/cut = the node went down under it; 0 with a delay = command returned first)"
  sleep 20
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
    fssh "$n" 10 'rm -f /etc/rc.d/K*batman-faketime'
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
  if [ "$after" -le "$before" ]; then
    # #270: say what the console zone holds so the loss can be attributed (crash started? pstore dropped the dump?
    # only the driver flood?) — the 2026-10-07 FAILs on 03 left nothing but "UNCLEAN" and were never attributed
    echo "FAIL no new pstore record — console record evidence: $(fssh "$1" 15 'c=$(ls -t /opt/batdata/crash/*_console-ramoops-* 2>/dev/null | head -1); [ -n "$c" ] || { echo "none saved"; exit 0; }; echo "$c $(wc -c < "$c") bytes; sysrq-crash=$(grep -c "sysrq: Trigger a crash" "$c") panic-text=$(grep -c "Kernel panic - not syncing" "$c") dump-skipped=$(grep -c "because of concurrent dump" "$c") spi-timeouts=$(grep -c "SPI transfer timed out" "$c") throttled=$(vcgencmd get_throttled 2>/dev/null)"; echo "tail: $(tail -2 "$c" | tr "\n" "|")"' | tr -d '\r')"
    return 1
  fi
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
  # Negative controls: DV_TEST_274_NOSTOP=1 (K08/K09 stop links removed) must FAIL 1 (no stop record) and 2
  # (postgres SIGKILLed by procd's halt) — #274 v8.2: start mode now runs on every boot, so 4 passes either way;
  # DV_TEST_274_RMSTOP=1 (the stop removes the containers once, feat/264-style) must FAIL 3.
  local n=$1 rc=0 ids0 ids1 pb l r up codes c kl=""
  fssh "$n" 12 'ls /etc/init.d/batman-payload-* >/dev/null 2>&1 && [ -f /usr/lib/batman/payload-stop.sh ]' || { echo "FAIL no payload guardian / payload-stop.sh on this node"; return 1; }
  ots_ready "$n" || { echo "FAIL OTS not ready before the test"; return 1; }
  ids0=$(ots_ids "$n"); pb=$(bootid "$n" | cut -c1-8)
  if [ "${DV_TEST_274_NOSTOP:-0}" = 1 ]; then
    kl=$(fssh "$n" 10 'for l in /etc/rc.d/K*batman-payload-* /etc/rc.d/K*batman-prestop-payload; do [ -e "$l" ] && rm -f "$l" && basename "$l"; done' | tr -d '\r' | tr '\n' ' ')
    echo "removed K links: $kl"
    echo "NEGATIVE CONTROL: payload stop links removed for this reboot"
  fi
  if [ "${DV_TEST_274_RMSTOP:-0}" = 1 ]; then
    fssh "$n" 10 "$RDR"': > "$R/fault.274-rmstop-once"'   # #274 §12 D7-6: the seam lives in the root-only run dir
    echo "NEGATIVE CONTROL: the stop removes the containers once"
  fi
  # 6 (C1): a peer sends one CoT the moment 8088 accepts again after the reboot (as early as a field client)
  # 6 (C1): the host sends one CoT the moment 8088 accepts again after the reboot (as early as a field client)
  local pu pf
  pu="DV274E$(date +%Y%m%d%H%M%S)"; pf="$DIR/cleanstop-274.probe"
  cot_probe_274 "$n" "$pu" "$pf"; echo "early-CoT probe $pu started on the host (-> $n:8088)"
  reboot_and_wait "$n" reboot 240 || rc=1
  if [ "${DV_TEST_274_NOSTOP:-0}" = 1 ]; then   # the K links live on the overlay: put them back
    fssh "$n" 10 "for b in $kl; do case \$b in K[0-9][0-9]batman-*) ;; *) continue;; esac; t=\${b#K??}; ln -sf ../init.d/\$t /etc/rc.d/\$b; ls -l /etc/rc.d/\$b; done" \
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
  # #274 v8.2: with --restart no RestartCount is always 0 (vacuous) — count each container's `start` events since
  # this dockerd started instead (docker keeps 256 in memory; a wrapped buffer or 0 events is a FAIL, not a pass)
  l=$(fssh "$n" 20 'm=$(ls /opt/batdata/apps/opentakserver/*.manifest | head -1); now=$(date +%s)
    nev=$(docker events --since 0 --until "$now" --format x 2>/dev/null | wc -l); ev=$(docker events --since 0 --until "$now" --filter event=start --format "{{.ID}}" 2>/dev/null)
    [ "$nev" -gt 0 ] && [ "$nev" -lt 256 ] || echo "events=$nev"
    for c in $(awk "/^CONTAINER /{print \$2}" "$m"); do id=$(docker inspect -f "{{.Id}}" $c); echo "$c=$(echo "$ev" | grep -c "^$id\$")"; done' | tr '\r\n' '  ')
  echo "start events per container this boot: $l"
  if echo "$l" | grep -q 'events='; then echo "FAIL 6 docker event buffer empty or possibly wrapped — start count not measurable"; rc=1
  elif echo "$l" | grep -Eq '=(0|[2-9]|[1-9][0-9])( |$)'; then echo "FAIL 6 a container was started more than once (or never) during the start"; rc=1
  else echo "ok 6 every container started exactly once"; fi
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
  sleep 35; l=$(fssh "$n" 10 "$RDR"'cat "$R/batman-payload-opentakserver-drift.json"' | tr -d '\r'); echo "verdict: $l"
  case "$l" in *'"status":"OK"'*) ;; *) echo "FAIL verdict not OK after convergence"; rc=1 ;; esac
  # the rebuilds removed the old ots-db only after a graceful stop: the current one started from a clean shutdown
  pg=$(fssh "$n" 15 'docker logs ots-db 2>&1 | grep -E "database system was shut down at|not properly shut down|was interrupted" | tail -1')
  case "$pg" in *"shut down at"*) echo "ok postgres: clean shutdown before the last rebuild" ;; *) echo "FAIL postgres last start: ${pg:-<none>}"; rc=1 ;; esac
  return $rc; }

# ---- #274 v8.2 (docs/design/274-payload-converge.md §12.7): the guardian as the only starter/restarter ----
p274() {   # $1 node, $2 case of scripts/node/payload-274.sh
  local o r; o=$(timeout 2400 ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR -o ConnectTimeout=8 "root@$1" "CASE=$2 sh -s" < "$REPO/scripts/node/payload-274.sh" 2>&1); r=$?
  echo "$o"
  echo "$o" | grep -qx "== payload-274 $2: PASS" || { [ "$r" = 0 ] && echo "FAIL rc 0 without the PASS trailer (script cut short?)"; return 1; }
  return "$r"; }
# L-PWR + L-TENANT-PLANT: `reboot -f` (no K scripts — containers die with the kernel, as on power loss). Before it a
# tenant dir is planted on p6 whose .init would touch a marker if it were ever installed; after the boot the
# guardian stub for it must be the GENERATED one. Then: every OTS container started exactly once, in order, by the
# guardian; ledger empty; verdict OK. postgres crash recovery is expected (nothing can stop it on power loss).
bchk_unclean_274() {
  local n=$1 rc=0 b0 l fo
  ots_ready "$n" || { echo "FAIL OTS not ready before the test"; return 1; }
  fssh "$n" 20 "$RDR"'d=/opt/batdata/apps/zz274; mkdir -p "$d"; printf "NETWORK_NAME zz274-net\nBRIDGE br-zz274\nCONTAINER zz274\nIMAGE none/zz274:0\nENDCONTAINER\n" > "$d/zz274.manifest"
    printf "#!/bin/sh /etc/rc.common\nSTART=99\nboot(){ touch $R/zz274-init-ran; }\nstart(){ touch $R/zz274-init-ran; }\n" > "$d/batman-payload-zz274.init"; chmod +x "$d/batman-payload-zz274.init"; sync' \
    || { echo "FAIL could not plant the test tenant"; return 1; }
  b0=$(bootid "$n" | cut -c1-8)
  reboot_and_wait "$n" 'sync; reboot -f' 300 || rc=1
  if [ "$rc" = 0 ]; then
    for r in $(seq 1 60); do ots_ready "$n" && break; sleep 5; done
    ots_ready "$n" || { echo "FAIL OTS not ready within 300 s after reboot -f"; rc=1; }
    fo=$(fssh "$n" 20 "$RDR"'sed "s/@TENANT@/zz274/g" /usr/share/batman/payload-guardian.init.in | cmp -s - /etc/init.d/batman-payload-zz274 && echo GEN; [ -e "$R/zz274-init-ran" ] && echo RAN; true' | tr -d '\r' | tr '\n' ' ')
    case "$fo" in *RAN*) echo "FAIL the planted p6 .init was executed"; rc=1 ;; *) echo "ok the planted p6 .init never ran" ;; esac
    case "$fo" in *GEN*) echo "ok /etc/init.d/batman-payload-zz274 is the generated stub, not the p6 file" ;; *) echo "FAIL the zz274 stub is not the generated one [$fo]"; rc=1 ;; esac
    l=$(fssh "$n" 30 "B0=$b0 sh -s" < "$REPO/scripts/node/ota-start-274.sh" | tr -d '\r')
    echo "$l" | grep -E '^(ok|FAIL) (1|2|5) ' | sed 's/^/  /'
    echo "$l" | grep -qE '^FAIL (1|2|5) ' && { echo "FAIL the start after reboot -f was not clean (see above)"; rc=1; } || echo "ok one start per container, ordered, empty ledger after reboot -f"
    # the first verdict comes at the guardian's first tick after its converge (up to INTERVAL later): wait for it
    l=""; for r in $(seq 1 24); do l=$(fssh "$n" 10 "$RDR"'grep -q "\"status\":\"OK\"" "$R/batman-payload-opentakserver-drift.json" 2>/dev/null && echo OK' | tr -d '\r '); [ "$l" = OK ] && break; sleep 5; done
    [ "$l" = OK ] && echo "ok verdict OK" || { echo "FAIL verdict not OK within 120 s after OTS ready (reboot -f)"; rc=1; }
    fssh "$n" 10 'grep -i "fw-override\|correcting" /opt/batdata/log/ota-trace.log 2>/dev/null | grep " boot=$(cut -c1-8 /proc/sys/kernel/random/boot_id) " | tail -1' | sed 's/^/  report (EEPROM partition misread this boot?): /'
  fi
  fssh "$n" 20 "$RDR"'/etc/init.d/batman-payload-zz274 stop >/dev/null 2>&1; /etc/init.d/batman-payload-zz274 disable >/dev/null 2>&1; rm -f /etc/init.d/batman-payload-zz274 "$R/zz274-init-ran"; rm -rf /opt/batdata/apps/zz274; sync' >/dev/null
  return $rc; }
# L-FIRST2 + L-HOLD-REBOOT with the real firstload: a tar that `docker load` rejects puts the tenant in the hold.
# Reboot 1: the hold — guardian started for this boot (not enabled: no S link), K09 link kept, stack up. Reboot 2
# while held: the stop record must have BOTH halves (K08 clients, K09 final tier) each < 15 s — with v7's `disable`
# K09 was gone and procd's halt KILLed postgres. Negative control (old image): no k09 half in the record.
bchk_hold_274() {
  local n=$1 rc=0 b l pb
  ots_ready "$n" || { echo "FAIL OTS not ready before the test"; return 1; }
  fssh "$n" 15 'head -c 300000 /dev/urandom > /opt/batdata/apps/opentakserver/images/zz274.tar; rm -f /opt/batdata/apps/opentakserver/images/.fail-zz274.tar; sync' || { echo "FAIL could not plant the bad tar"; return 1; }
  reboot_and_wait "$n" reboot 300 || { echo "FAIL node did not return from reboot 1"; rc=1; }
  if [ "$rc" = 0 ]; then
    for r in $(seq 1 90); do ots_ready "$n" && break; sleep 5; done
    l=$(fssh "$n" 20 'ls /etc/rc.d/S??batman-payload-opentakserver >/dev/null 2>&1 && echo SLINK; ls /etc/rc.d/K??batman-payload-opentakserver >/dev/null 2>&1 && echo KLINK
      /etc/init.d/batman-payload-opentakserver running && echo RUNNING; tail -20 /opt/batdata/log/firstload.log | grep -q "guardian started for this boot" && echo LOADER' | tr -d '\r' | tr '\n' ' ')
    echo "hold state: $l"
    case "$l" in *SLINK*) echo "FAIL the S link is still there (not held)"; rc=1 ;; *) echo "ok held: S link removed" ;; esac
    case "$l" in *KLINK*) echo "ok K09 link kept during the hold" ;; *) echo "FAIL no K09 link during the hold"; rc=1 ;; esac
    case "$l" in *RUNNING*LOADER*|*LOADER*RUNNING*) echo "ok the loader started the guardian for this boot" ;; *) echo "FAIL guardian not started by the loader"; rc=1 ;; esac
    ots_ready "$n" && echo "ok OTS up during the hold (dark window: $(fssh "$n" 15 'docker inspect -f "{{.State.StartedAt}}" ots-db' | tr -d '\r') )" || { echo "FAIL OTS not up during the hold"; rc=1; }
    pb=$(bootid "$n" | cut -c1-8)
    reboot_and_wait "$n" reboot 300 || { echo "FAIL node did not return from reboot 2"; rc=1; }
    l=$(fssh "$n" 15 "grep 'boot=$pb ' /opt/batdata/log/payload-stop.log 2>/dev/null | tail -1" | tr -d '\r')
    echo "stop record of the held boot: ${l:-<none>}"
    k8=$(echo "$l" | sed -n 's/.* k08=\([0-9]*\)\.[0-9]s.*/\1/p'); k9=$(echo "$l" | sed -n 's/.* k09=\([0-9]*\)\.[0-9]s.*/\1/p')
    if isint "$k8" && isint "$k9"; then
      [ "$k8" -lt 15 ] && [ "$k9" -lt 15 ] && echo "ok reboot during the hold: both stop halves ran (k08=${k8}.x s, k09=${k9}.x s, each < 15 s)" || { echo "FAIL a stop half over procd's 15 s (k08=$k8 k09=$k9)"; rc=1; }
    else echo "FAIL the held boot's stop record lacks a K08 or K09 half (K09 link gone? postgres would be SIGKILLed)"; rc=1; fi
    l=$(fssh "$n" 15 'docker logs ots-db 2>&1 | grep -E "database system was shut down at|not properly shut down|was interrupted" | tail -1')
    echo "postgres (reported): ${l:-<none>}"
  fi
  fssh "$n" 20 'rm -f /opt/batdata/apps/opentakserver/images/zz274.tar /opt/batdata/apps/opentakserver/images/.fail-zz274.tar /opt/batdata/apps/opentakserver/images/failed/zz274.tar; /etc/init.d/batman-payload-opentakserver enable; sync' >/dev/null
  # one more clean reboot: the held boot carries a firstload latch (the tenant is non-gating for the rest of that
  # boot), which would change what later suites measure (crash-274 step 4 on 1.5.8-wsl.1)
  reboot_and_wait "$n" reboot 300 || { echo "FAIL node did not return from the cleanup reboot"; rc=1; }
  for r in $(seq 1 60); do ots_ready "$n" && break; sleep 5; done
  ots_ready "$n" || { echo "FAIL OTS not back after the cleanup"; rc=1; }
  fssh "$n" 10 "$RDR"'ls "$R"/batman-firstload-*.latch 2>/dev/null' | grep -q . && { echo "FAIL a firstload latch is still present after the cleanup reboot"; rc=1; }
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
    for s274 in unclean-boot-274 hold-274 golden-exec-274 host-alarm-274 queue-gone-264 rto768-264 crash-274 dockerd-restart-274; do na "$s274" "OTS_NODE $OTS_NODE is a Pi 3: no tenant/guardian by design (#209 D6)"; done
  elif dwait "$OTS_NODE" 300; then
    suite converge-274 "guardian converges a changed manifest / mounted file by a graceful rebuild, leaves an unchanged stack alone, restores to the golden fingerprint (#274, destructive)" "bchk_converge_274 $OTS_NODE" D
    suite cleanstop-274 "clean reboot: tiered graceful stop recorded before the shutdown capture, postgres clean, same containers started in order, boot-to-ready <= 90 s (#274, destructive)" "bchk_cleanstop_274 $OTS_NODE" D
    suite unclean-boot-274 "reboot -f (as on power loss): nothing revives by itself, one ordered start by the guardian; a planted p6 .init never runs — the stub is generated (#274 §12, destructive)" "bchk_unclean_274 $OTS_NODE" D
    suite hold-274 "firstload hold (a tar docker load rejects): guardian started for the boot, K09 kept; a reboot during the hold stops both halves (#274 §12, destructive)" "bchk_hold_274 $OTS_NODE" D
    suite golden-exec-274 "root never executes a p6 copy of a golden tenant's script; edits are DRIFT, planted files a host alarm (#274 §12)" "p274 $OTS_NODE golden" D
    suite host-alarm-274 "dangerous foreign containers (p6/socket bind, device, host net, disguised volume) raise a host alarm, never the verdict (#274 §12)" "p274 $OTS_NODE hostalarm"
    # these three leave the tenant DRIFT for the 600 s ledger window: they wait it out themselves, and run last (§12.7)
    if [ "$OTS_EUD" = overlay ]; then
      suite queue-gone-264 "the transient cot_parser queue is deleted under a CoT stream: cot_parser exits and the guardian restarts it (asserted), the patched eud re-declares + retries so sent == stored (#264 mechanism C, destructive)" "bchk_queue_gone_264 $OTS_NODE $BENCH_NODE" D
    else na queue-gone-264 "overlay-only mechanism; the gateway build has no eud_handler (#289)"; fi
    if [ "$OTS_EUD" = overlay ]; then
      suite group-disc-264 "an 8089 group member ends its session while cot_parser is busy: no cot_parser crash loop, no bind on a deleted queue (#264 review r2 A2-1; wsl.8: 6 crashes until the membership was removed; destructive on a broken build)" "bchk_group_disc_264 $OTS_NODE $BENCH_NODE" D
    else na group-disc-264 "overlay-only mechanism; the gateway build has no eud_handler (#289)"; fi
    if [ "$OTS_EUD" = overlay ]; then
      suite rto768-264 "the RTO returns with ots_eud_handler at 768m (reconciler paused, restored after): the R7 reserve refuses, an OOM takes only sessions, the listener survives, admissions serialized (#264 R7/R16, review r6; tier B)" "bchk_rto768_264 $OTS_NODE $BENCH_NODE $MESH_NODE" D
    else na rto768-264 "overlay-only mechanism; the gateway build has no eud_handler (#289)"; fi
    if [ "$OTS_EUD" = overlay ]; then
      suite r8-hold-264 "a refused converge (overlay MOUNTSHA mismatch) keeps the overlay containers stopped, and the guardian's restart path does not start them; restored from the golden after (#264 R8, review r3 B3-1; wsl.10: started after 30 s; destructive)" "bchk_r8_hold_264 $OTS_NODE" D
    else na r8-hold-264 "overlay-only mechanism; the gateway build has no eud_handler (#289)"; fi
    suite crash-274 "crash / PRIMARY / loop backoff / old config / respawn / rm / docker update / docker stop / hung health check: the guardian restarts, records, and DRIFTs (#274 §12, destructive)" "p274 $OTS_NODE crash" D
    suite dockerd-restart-274 "dockerd restart stops the tenant gracefully; the guardian brings it back in order (#274 §12, destructive)" "p274 $OTS_NODE dockerd" D
    if [ "$OTS_EUD" = gateway ]; then gw_register_b_destructive
    else for s289 in broker-restart-289 queue-gone-289 amqp-down-289; do na "$s289" "gateway suites: the overlay build has no gateway (#289)"; done; fi
  else   # not back within 300 s after the destructive tier = a real finding, never a SKIP (#274 review C6)
    suite converge-274 "guardian converges a changed config (#274) — OTS node unreachable" "echo 'FAIL OTS_NODE $OTS_NODE not reachable within 300 s after the destructive tier'; false"
    suite cleanstop-274 "clean reboot stop/start (#274) — OTS node unreachable" "echo 'FAIL OTS_NODE $OTS_NODE not reachable within 300 s after the destructive tier'; false"
    for s274 in unclean-boot-274 hold-274 golden-exec-274 host-alarm-274 queue-gone-264 rto768-264 crash-274 dockerd-restart-274; do suite "$s274" "#274 §12 / #264 — OTS node unreachable" "echo 'FAIL OTS_NODE $OTS_NODE not reachable within 300 s after the destructive tier'; false"; done
  fi
fi

# ---- #280: a non-root process cannot steer the node through /tmp (every fleet node, version-gated) ----
# Plants as nobody: old /tmp markers, an operator flag, a battery reading. Restarts batpower under a STAGED mock
# config; the plant lives < (confirm-1)*interval so even a regressed build cannot reach CRIT (design §9 N2).
chk_tmptrust_280() { local n rc=0 o r; for n in $FLEET; do echo "== $n"
  o=$(timeout 300 ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR -o ConnectTimeout=8 "root@$n" 'sh -s' < "$REPO/scripts/node/tmp-trust-280.sh" 2>&1); r=$?
  echo "$o"
  [ "$r" = 0 ] && ! echo "$o" | grep -qx '== tmp-trust-280: PASS' && { echo "FAIL $n: rc 0 without the PASS trailer (script cut short?)"; rc=1; }
  case $r in 0) ;; 3) echo "$o" | grep -q '^SKIP-REASON: pre-#280' && echo "FAIL $n runs a pre-#280 image — this run cannot verify #280 on it" ; rc=1 ;; *) rc=1 ;; esac
  done; return $rc; }
if [ "$FEATURE_MODE" = --destructive ]; then
  suite tmp-trust-280 "nobody cannot write the run dir, planted /tmp markers + operator flag ignored (TAMPER), batpower never reads a planted value — every fleet node (#280)" "chk_tmptrust_280"
else
  suite tmp-trust-280 "non-root /tmp steering (#280) — restarts batpower, needs FEATURE_MODE=--destructive" ""
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
  suite soak-cot-264    "every CoT sent over the soak stored at least once (distinct (uid,time) >= sent; duplicates reported, #264 at-least-once; mechanisms A and B both in play)" "chk_soak_cot"
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
