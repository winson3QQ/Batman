#!/bin/bash
# scripts/dv-preflight.sh — checks run BEFORE any daily-validation suite (#290 rule 4, #254 PR-H1 §4.1).
# Any FAIL = the run does not start. Reads the same environment as daily-validation.sh. Read-only on the nodes,
# except P6's staging probe (a root-0700 run dir under /tmp/run/batman-dv/bt, removed again).
# Every remote command starts with ": P<n>;" so scripts/test-dv-preflight.sh can answer it with a stub ssh.
# Exit 0 = all passed. Output: "preflight ok: ..." / "PREFLIGHT FAIL: ..." lines, then PREFLIGHT PASS|FAILED.
set -u
REPO=${REPO:-$(cd "$(dirname "$0")/.." && pwd)}
AB_MODE=${AB_MODE:---inspect-only}; FEATURE_MODE=${FEATURE_MODE:---daily}
OTS_NODE=${OTS_NODE:-${MESH_NODE:-}}; DNODE=${DESTRUCTIVE_NODE:-$OTS_NODE}
BLE_PERIPH=${BLE_PERIPH:-$DNODE}; BLE_CENTRAL=${BLE_CENTRAL:-${BENCH_NODE:-}}
bad=0
f() { echo "PREFLIGHT FAIL: $*"; bad=1; }
ok() { echo "preflight ok: $*"; }
S() { timeout "${3:-30}" ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR -o ConnectTimeout=8 "root@$1" "$2" 2>/dev/null | tr -d '\r'; }
isint() { case "$1" in ""|*[!0-9]*) return 1;; esac; }
uniq_nodes() { printf '%s\n' "$@" | awk 'NF && !s[$0]++'; }

# ---- P1 / P2 harness checkout
if git -c safe.directory='*' -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then ok "P1 harness is a git checkout ($(git -c safe.directory='*' -C "$REPO" log --oneline -1 2>/dev/null | cut -c1-60))"
else f "P1 $REPO is not a git checkout (a git archive copy breaks tmp-trust / ab-card, 2026-10-19)"; fi
for d in feed tests scripts/daily-validation.sh; do [ -e "$REPO/$d" ] || f "P1 $REPO/$d missing (incomplete harness copy)"; done
case "$(uname -o 2>/dev/null)" in Msys|Cygwin)
	case "$REPO" in //wsl.localhost/*) ok "P2 Git Bash harness on a //wsl.localhost path";; *) f "P2 under Git Bash REPO must be //wsl.localhost/... (tmp-trust delegates into WSL), not $REPO";; esac;;
esac

# ---- P3 nodes: reachable, committed, same version, slot; no leftover hold-commit flag
ALL=$(uniq_nodes "${BENCH_NODE:-}" "${MESH_NODE:-}" "$OTS_NODE" "$DNODE" "${IPERF_PEER:-}" "${DV_T263_NODE:-}" "$BLE_PERIPH" "$BLE_CENTRAL")
[ -n "$ALL" ] || f "P3 no node configured"
vers=""; declare -A SOC
for n in $ALL; do
	r=$(S "$n" ': P3; v=$(sed -n "s/^BATMAN_VERSION=//p" /etc/batman-build); batman-slot is-trial >/dev/null 2>&1; t=$?; s=$(batman-slot active 2>/dev/null); c=$(cat /proc/device-tree/compatible 2>/dev/null | tr "\0" " "); h=$(cat /opt/batdata/state/autocommit-hold-commit 2>/dev/null); echo "v=$v t=$t s=$s h=[$h] c=$c"')
	v=$(sed -n 's/^v=\([^ ]*\) .*/\1/p' <<< "$r"); t=$(sed -n 's/.* t=\([0-9]*\) .*/\1/p' <<< "$r"); s=$(sed -n 's/.* s=\([AB]*\) .*/\1/p' <<< "$r")
	h=$(sed -n 's/.* h=\[\([^]]*\)\].*/\1/p' <<< "$r")
	case "$r" in *bcm2711*) SOC[$n]=bcm2711;; *bcm2837*) SOC[$n]=bcm2710;; *) SOC[$n]="";; esac
	if [ -z "$v" ]; then f "P3 $n not reachable or no BATMAN_VERSION ($r)"; continue; fi
	[ "$t" = 1 ] && ok "P3 $n $v slot $s committed" || f "P3 $n is an uncommitted trial (is-trial rc=$t) — a run on a trial measures the wrong slot"
	[ -n "$h" ] && f "P3 $n has a leftover autocommit-hold-commit flag [$h] (an interrupted held trial?). Safe clear: is-trial rc 1, tryboot not armed, then rm /opt/batdata/state/autocommit-hold-commit"
	vers="$vers $v"
done
nv=$(tr ' ' '\n' <<< "$vers" | awk 'NF' | sort -u | wc -l)
[ "$nv" -le 1 ] && ok "P3 fleet runs one version" || f "P3 fleet versions differ:$vers (#290)"
if [ "$AB_MODE" = --destructive ] && [ -n "${BENCH_NODE:-}" ]; then
	s=$(S "$BENCH_NODE" ': P3b; batman-slot active')
	[ "$s" = A ] && ok "P3 BENCH_NODE on slot A (ab-selftest --destructive precondition)" || f "P3 BENCH_NODE $BENCH_NODE is on slot [$s], ab-selftest --destructive needs slot A (#290)"
fi

# ---- P4 roles
b4=$bad; bad=0
[ -n "${BENCH_NODE:-}" ] && [ "$BENCH_NODE" = "${MESH_NODE:-}" ] && f "P4 BENCH_NODE == MESH_NODE ($BENCH_NODE): soak-http-mesh has no second web tenant"
[ -n "${IPERF_PEER:-}" ] && [ "$IPERF_PEER" = "${MESH_NODE:-}" ] && f "P4 IPERF_PEER == MESH_NODE: iperf needs the OTHER node"
[ -n "${BENCH_NODE:-}" ] && [ "$BENCH_NODE" = "$OTS_NODE" ] && [ "$AB_MODE" = --destructive ] && f "P4 BENCH_NODE == OTS_NODE: the load soak needs the CoT generator on a different node"
if [ "$FEATURE_MODE" = --destructive ]; then
	[ -n "$BLE_PERIPH" ] && [ -n "$BLE_CENTRAL" ] || f "P4 BLE_PERIPH / BLE_CENTRAL unset (tier-B BLE suites)"
	[ "$BLE_PERIPH" != "$BLE_CENTRAL" ] || f "P4 BLE_PERIPH == BLE_CENTRAL"
	[ "$BLE_PERIPH" = "$DNODE" ] || f "P4 BLE_PERIPH ($BLE_PERIPH) must be DNODE ($DNODE): the BLE suites reboot it and need its ethernet for recovery"
fi
[ $bad = 0 ] && ok "P4 roles"; [ $b4 = 1 ] && bad=1

# ---- P5 destructive payloads: fault-injection's own precheck (one judge), DV_T263_KO vs the running kernel
if [ "$AB_MODE" = --destructive ]; then
	for n in $(uniq_nodes "$OTS_NODE" "${MESH_NODE:-}"); do
		[ "${SOC[$n]:-}" = bcm2710 ] && continue
		o=$( ( FI_SOURCE_ONLY=1 . "$REPO/scripts/fault-injection.sh" "$n" --case r1 >/dev/null 2>&1 || exit 9
		       trap - EXIT          # never run fault-injection's restore_node from a preflight
		       precheck; r=$?; rm -rf "$FI_TMP"; exit $r ) 2>&1 ); r=$?
		[ $r = 0 ] && ok "P5 FI payload ${FI_PAYLOAD:-/opt/batdata/ota.tar.gz} == the build $n runs" || f "P5 FI payload on $n: $(grep -E 'ERR|FAIL' <<< "$o" | head -1)"
	done
	if [ -z "${DV_T263_KO:-}" ]; then f "P5 DV_T263_KO unset — halow-fi-263 would SKIP"
	elif [ ! -f "$DV_T263_KO" ]; then f "P5 DV_T263_KO $DV_T263_KO missing"
	else
		tn=${DV_T263_NODE:-${BENCH_NODE:-}}
		kv=$(grep -a -o -m1 'vermagic=[^ ]*' "$DV_T263_KO" | cut -d= -f2); nk=$(S "$tn" ': P5k; uname -r')
		bv=$(S "$tn" ': P5v; sed -n "s/^BATMAN_VERSION=//p" /etc/batman-build')
		[ -n "$kv" ] && [ "$kv" = "$nk" ] || f "P5 DV_T263_KO vermagic [$kv] != $tn kernel [$nk]"
		case "$DV_T263_KO" in *"$bv"*) ok "P5 DV_T263_KO is from $bv";; *) f "P5 DV_T263_KO path does not name the build $tn runs ($bv)";; esac
	fi
fi

# ---- P6 BLE harness state (never product state: hci0 / batman-sc are judged by the suites)
for n in $ALL; do
	[ "${SOC[$n]:-}" = bcm2711 ] || continue
	o=$( { cat "$REPO/scripts/node/ble-lib-254.sh"; echo ': P6; ble_state'; } | timeout 60 ssh -o BatchMode=yes -o LogLevel=ERROR -o ConnectTimeout=8 "root@$n" sh -s 2>&1 | tr -d '\r')
	if grep -q '^STATE clean' <<< "$o"; then ok "P6 $n BLE harness state clean"
	elif grep -q '^FAIL' <<< "$o"; then while read -r l; do f "P6 $n ${l#FAIL }"; done < <(grep '^FAIL' <<< "$o")
	else ok "P6 $n BLE: $(grep '^STATE' <<< "$o" | head -1) (no harness leftovers)"; fi
done
if [ "$FEATURE_MODE" = --destructive ]; then
	. "$REPO/scripts/lib/ble-254.sh"
	for n in "$BLE_PERIPH" "$BLE_CENTRAL"; do [ -n "$n" ] && [ "${SOC[$n]:-}" = bcm2711 ] || f "P6 BLE node $n is not a bcm2711 (a Pi 3 carries no BLE build)"; done
	o=$(ble_tools_check) && ok "P6 ${o#ok   }" || f "P6 $(sed 's/^FAIL //' <<< "$o")"
	o=$(MSYS_NO_PATHCONV=1 $(ble_py_cmd) "$(ble_ah_path)" --selftest 2>&1) && ok "P6 ble-ah.py selftest (DV_PY)" || f "P6 ble-ah.py --selftest failed: $(tail -1 <<< "$o")"
	if [ -n "$BLE_PERIPH" ]; then
		BLE_RUN_ID=preflight$$; BLE_DIR=/tmp/run/batman-dv/bt/$BLE_RUN_ID
		o=$(ble_stage "$BLE_PERIPH" periph 2>&1) && ok "P6 tools staged + run on $BLE_PERIPH (btmgmt / btmon 5.72, libraries present)" || f "P6 staging probe on $BLE_PERIPH: $(grep FAIL <<< "$o" | head -1)"
		S "$BLE_PERIPH" ": P6c; d=$BLE_DIR; [ -d \"\$d\" ] && ls \"\$d\" | tr '\n' ' ' && rm -rf \"\$d\"" >/dev/null
	fi
fi

# ---- P7 logread flood: 200 lines in < 60 s by the node's own clock; nodes up < 600 s are waited for (max 10 min)
for n in $ALL; do
	w=0
	while :; do
		r=$(S "$n" ': P7; u=$(cut -d. -f1 /proc/uptime); t=$(logread -l 200 | head -1 | cut -c1-24); echo "$u|$t|$(date "+%a %b %e %H:%M:%S %Y")"')
		u=${r%%|*}; isint "$u" || { f "P7 $n uptime unreadable"; break; }
		[ "$u" -ge 600 ] && break
		[ $w -ge 600 ] && { f "P7 $n still up < 600 s after a 10-min wait"; break; }
		sleep 30; w=$((w + 30))
	done
	isint "$u" && [ "$u" -ge 600 ] || continue
	t=$(cut -d'|' -f2 <<< "$r"); now=$(cut -d'|' -f3 <<< "$r")
	ts=$(date -d "$t" +%s 2>/dev/null); tn=$(date -d "$now" +%s 2>/dev/null)
	if ! isint "$ts" || ! isint "$tn"; then f "P7 $n logread timestamps unreadable ([$t] / [$now])"; continue; fi
	d=$((tn - ts))
	if [ $d -lt 0 ]; then f "P7 $n clock went backwards (oldest of the last 200 log lines is in the future: $t > $now)"
	elif [ $d -lt 60 ]; then f "P7 $n logread flood: 200 lines in ${d}s (#286)"
	else ok "P7 $n log rate: 200 lines in ${d}s"; fi
done

# ---- P8 (#290 'node clock near midnight') deliberately not checked: node clocks are not trustworthy (04 2025-07,
#      02 2026-10) and the fixed-path log reader it protected (#264 overlay) is gone — reason recorded in #290.
[ $bad = 0 ] && { echo "PREFLIGHT PASS"; exit 0; }
echo "PREFLIGHT FAILED — not starting"; exit 1
