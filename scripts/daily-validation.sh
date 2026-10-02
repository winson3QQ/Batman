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
  timeout 15 ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 "root@$1" \
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

# 3b. DESTRUCTIVE flash-and-go fault-injection (#159/#216): F1 bad-tar quarantine, F2 offline recovery,
# R2 first-load-latch non-gating, R1 docker-run-broken -> canary revert. Reboots/OTA-flashes the node,
# so it runs ONLY under AB_MODE=--destructive (the release gate), like ab-selftest above. On the daily
# --inspect-only run it is SKIPped (reported as loudly as a fail).
OTS_NODE=${OTS_NODE:-$MESH_NODE}          # the node carrying the OTS payload (also set below, kept identical)
OTS_SOC=$(soc_of "$OTS_NODE")
# OTS is a REQUIRED capability, so an OTS_NODE that is a Pi 3 is a misconfigured run, not "does not
# apply": FAIL it loudly (an N/A here would make every OTS regression vanish from a green run).
if [ "$OTS_SOC" = bcm2710 ]; then
  suite ots-node-209 "OTS_NODE must be the bcm2711 OTS host" "echo 'OTS_NODE $OTS_NODE is a Pi 3 (bcm2710); OTS is not shipped there (#209 D6). Set OTS_NODE to the Pi 4 OTS host.'; false"
  suite fault-injection "OTS_NODE $OTS_NODE is bcm2710 — OTS suites not run (see ots-node-209)" ""
elif [ "$AB_MODE" != --destructive ]; then
  suite fault-injection "flash-and-go fault-injection F1/F2/R2/R1 (#159/#216) — needs AB_MODE=--destructive" ""
elif up "$OTS_NODE"; then
  suite fault-injection \
    "flash-and-go fault-injection F1/F2/R2/R1 (#159/#216, DESTRUCTIVE)" \
    "$REPO/scripts/fault-injection.sh $OTS_NODE --case all"
else
  suite fault-injection "flash-and-go fault-injection (#159/#216) — OTS_NODE $OTS_NODE did not answer" ""
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

fssh() { timeout "${2:-60}" ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 "root@$1" "$3"; }

# ---- tier A: non-destructive, real ----
# #216: resolve the OTS tenant dir — flash-and-go / #167 uses /opt/batdata/apps/opentakserver;
# manually-provisioned nodes used /opt/batdata/deploy/ots. Prefer apps/, fall back to deploy/ots.
chk_98()  { fssh "$1" 60 'd=/opt/batdata/apps/opentakserver; [ -f "$d/verify-profile-ots.sh" ] || d=/opt/batdata/deploy/ots; sh "$d/verify-profile-ots.sh"'; }   # inspects 9 axes ×6
chk_162() { fssh "$1" 30 '
  n=0; for c in opentakserver ots-db ots_cot_parser ots_eud_handler ots_eud_handler_ssl rabbitmq; do
    [ "$(docker inspect -f "{{.State.Running}}" "$c" 2>/dev/null)" = true ] && n=$((n+1)); done
  db=$(docker exec ots-db psql -U ots -d ots -tAc "select 1" 2>/dev/null | tr -d " ")
  echo "running=$n/6 postgres=$db"; [ "$n" = 6 ] && [ "$db" = 1 ]'; }
chk_156() { fssh "$1" 45 '
  d=/opt/batdata/apps/opentakserver; [ -f "$d/verify-profile.sh" ] || d=/opt/batdata/deploy/ots   # #216: apps/ (flash-and-go) or deploy/ots
  [ -f "$d/verify-profile.sh" ] || { echo "verify-profile.sh not found in apps/ or deploy/ots"; exit 2; }   # do not let a missing file masquerade as DRIFT
  docker rm -f dv-decoy >/dev/null 2>&1
  docker run -d --name dv-decoy --entrypoint sleep batman/ots:1.7.13-arm64 60 >/dev/null 2>&1 || { echo "decoy start failed"; exit 2; }
  sleep 18   # clear verify-profile MIN_UPTIME=15 (else UNKNOWN, not DRIFT)
  sh "$d/verify-profile.sh" dv-decoy "$d/ots.hardening.env" >/tmp/dv-vp 2>&1; rc=$?
  docker rm -f dv-decoy >/dev/null 2>&1
  echo "unhardened decoy -> verify-profile rc=$rc (want non-0 = DRIFT detected)"; [ "$rc" -ne 0 ]'; }
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
  # the gate must be INSIDE platform_check_image, not back in platform_do_upgrade
  awk "/^platform_check_image\(\)/{f=1} f&&/REFUSING: image is for/{found=1} /^}/{if(f&&!found)f=0} END{exit !found}" /lib/upgrade/platform.sh \
    || { echo "SoC gate is not inside platform_check_image — it cannot refuse anything there"; exit 1; }
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
  for s in confinement-98 ots-up-162 drift-detect-156 payload-mgr-167 arbiter-167 payload-config-golden flashgo-159; do
    suite "$s" "OTS_NODE $OTS_NODE is bcm2710 — not run (see ots-node-209)" ""
  done
elif up "$OTS_NODE"; then
  suite confinement-98  "OTS container confinement — 9 axes ×6 (#98)"                       "chk_98 $OTS_NODE"
  suite ots-up-162       "OTS 6/6 running + postgres endpoint answers (#162)"                "chk_162 $OTS_NODE"
  suite drift-detect-156 "reconciler flags an unhardened decoy as DRIFT (#156, white-box)"   "chk_156 $OTS_NODE"
  suite payload-mgr-167  "OTS on the generic payload manager, old guardian gone (#167)"       "chk_167g $OTS_NODE"
  suite arbiter-167      "port/zone arbiter REFUSES a colliding tenant (#167, white-box)"      "chk_167a $OTS_NODE"
  suite payload-config-golden "p6 tenant config == baked golden + unless-stopped + images present (payload-config-golden.md)" "chk_golden $OTS_NODE"
  suite flashgo-159      "flash-and-go integrity — firstload enabled, offline copies (F2), canary runs, autocommit gate (#159/#216)" "chk_flashgo $OTS_NODE"
else
  for s in confinement-98 ots-up-162 drift-detect-156 payload-mgr-167 arbiter-167 payload-config-golden flashgo-159; do suite "$s" "OTS_NODE $OTS_NODE did not answer" ""; done
fi
if up "$MESH_NODE"; then
  suite field-status-130 "halow-status verdict agrees with batctl radio truth (#130)"        "chk_130 $MESH_NODE"
  suite meshjoin-209 "the OTA commit gate's mesh test passes on a joined node (ab-autocommit v2.2 N10)" "chk_meshjoin_209 $MESH_NODE"
  suite mesh-console-14  "/cgi-bin/mesh aggregate agrees with batctl (#14)"                   "chk_14 $MESH_NODE"
  suite p5-seed-202      "a JOINED node auto-seeds p5 (radio delta), decoupled from lockdown (#202)" "chk_202 $MESH_NODE"
  suite mesh-tput        "sustained mesh throughput to peer (median of N batctl tp; baseline soak median ~9.4 Mbps)" "chk_tput $MESH_NODE"
  if [ "$IPERF_PEER" != "$MESH_NODE" ] && up "$IPERF_PEER"; then
    suite mesh-tput-iperf "iperf TCP throughput MESH_NODE->peer (real IP payload; batctl tp under-reports ~15%; single-dir baseline ~9.3 Mbps)" "chk_iperf $MESH_NODE $IPERF_PEER"
  else
    suite mesh-tput-iperf "IPERF_PEER '$IPERF_PEER' unusable (unset / == MESH_NODE / down) — set IPERF_PEER to the other mesh node" ""
  fi
else
  for s in field-status-130 meshjoin-209 mesh-console-14 p5-seed-202 mesh-tput mesh-tput-iperf; do suite "$s" "MESH_NODE $MESH_NODE did not answer" ""; done
fi

# A/B commit hygiene (#211): a completed reflash must not leave the node an uncommitted trial (a reboot
# would revert). batman-autocommit health-gates + commits; assert the bench node ended committed.
# Placed here (after chk_* are defined) — chk_autocommit is used, unlike the inline BENCH suites above.
if up "$BENCH_NODE"; then
  suite autocommit-211 "A/B node is committed, not left in an uncommitted trial (#211, ab-autocommit)" "chk_autocommit $BENCH_NODE"
  suite p6grow-201 "A/B card data partition (p6) grew to fill the card at first boot (#201, not stuck at the baked ~200MiB)" "chk_p6grow_201 $BENCH_NODE"
  suite socgate-209 "sysupgrade refuses a wrong-SoC A/B image (#209 review: the old check only warned, and a bcm2711 wildcard passed everything)" "chk_socgate_209 $BENCH_NODE"
  suite slot-verify-209 "card sanity every slot op relies on: layout=SoC, FAT count, Pi 3 hybrid MBR, DT vs cmdline (#209 S5)" "chk_slotverify_209 $BENCH_NODE"
  suite memcg-209 "memory cgroup controller enabled — docker limits + autocommit canary (#209 D6; bcm2710 DTB disables it)" "chk_memcg_209 $BENCH_NODE"
  suite trybootget-209 "firmware answers the tryboot GET and the one-shot flag is clear on a normal boot (#209 D5)" "chk_trybootget_209 $BENCH_NODE"
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
bchk_174() {   # clock forward-only: reboot, assert faketime restored the clock forward (not back to 2025)
  fssh "$1" 15 '[ -f /etc/init.d/batman-faketime ]' || { echo "faketime not installed"; return 1; }
  fssh "$1" 15 'reboot' >/dev/null 2>&1; sleep 20; dwait "$1" 220 || return 1
  local yr; yr=$(fssh "$1" 12 'date -u +%Y' | tr -d " ")
  echo "post-reboot year=$yr (want >=2026 = faketime restored forward)"; [ -n "$yr" ] && [ "$yr" -ge 2026 ]; }
bchk_192() {   # clear the guardian from the overlay (as an A/B flash does), reboot, assert it auto-returns
  # #167 renamed the OTS guardian batman-ots -> batman-payload-opentakserver (generic payload manager);
  # match any tenant guardian batman-payload-* so this stays tenant-agnostic.
  fssh "$1" 12 'ls /etc/init.d/batman-payload-* >/dev/null 2>&1' || { echo "no guardian to test"; return 2; }
  fssh "$1" 15 'rm -f /etc/init.d/batman-payload-* /etc/rc.d/S*batman-payload-*' >/dev/null 2>&1
  fssh "$1" 15 'reboot' >/dev/null 2>&1; sleep 20; dwait "$1" 240 || return 1
  sleep 30   # batdata-mount restore + guardian start
  local r; r=$(fssh "$1" 12 'ls /etc/init.d/batman-payload-* >/dev/null 2>&1 && pgrep -f batman-payload >/dev/null && echo yes || echo no' | tr -d " ")
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
  echo "**$NPASS passed, $NFAIL failed, $NSKIP skipped, $NNA not applicable (by SoC, listed with reason)**"
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
