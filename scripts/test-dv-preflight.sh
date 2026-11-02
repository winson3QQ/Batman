#!/bin/bash
# scripts/test-dv-preflight.sh — offline negative controls for scripts/dv-preflight.sh (#254 PR-H1 §4.10 N9).
# A fake `ssh` answers each remote command by its ": P<n>;" tag from per-node files; no node, no network.
# Each case changes ONE thing from a good baseline and must turn PREFLIGHT PASS into a FAIL naming that thing.
# Run by daily-validation (harness self-test) and CI. Exit 0 = all cases behaved.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin" "$W/resp"
cat > "$W/bin/ssh" <<'FAKE'
#!/bin/bash
# fake ssh: find root@<node>, then answer by tag from $FAKE_RESP/<node>.<tag> (default files: $FAKE_RESP/_.<tag>)
node=""; cmd=""
while [ $# -gt 0 ]; do case "$1" in -o) shift 2;; root@*) node=${1#root@}; shift; cmd="$*"; break;; *) shift;; esac; done
[ -n "$cmd" ] && [ "$cmd" != "sh -s" ] || cmd=$(cat)
ans() { if [ -f "$FAKE_RESP/$node.$1" ]; then cat "$FAKE_RESP/$node.$1"; elif [ -f "$FAKE_RESP/_.$1" ]; then cat "$FAKE_RESP/_.$1"; else exit 255; fi; }
case "$cmd" in
	*": P9;"*) ans P9;;
	*": P3;"*) ans P3;; *": P3b;"*) ans P3b;; *": P5k;"*) ans P5k;; *": P5v;"*) ans P5v;;
	*": P6;"*) ans P6;; *": P7;"*) ans P7;; *"P=/opt"*|*"payload precheck"*|*"metadata"*) ans PRE;;
	*) exit 0;;
esac
FAKE
chmod +x "$W/bin/ssh"
export PATH="$W/bin:$PATH" FAKE_RESP="$W/resp"
base() {
	rm -f "$W/resp"/*
	echo 'v=1.5.12-wsl.9 t=1 s=A h=[] c=raspberrypi,4-model-b brcm,bcm2711 ' > "$W/resp/_.P3"
	echo A > "$W/resp/_.P3b"
	echo STATE clean > "$W/resp/_.P6"
	printf 'INFO slot=A is_trial=1 ver=x\nP9 clean\n' > "$W/resp/_.P9"
	echo "900|Wed Jul 16 10:00:00 2025|Wed Jul 16 12:00:00 2025" > "$W/resp/_.P7"
	printf 'metadata: x\nnode runs v from /dev/mmcblk0p2\nOK\n' > "$W/resp/_.PRE"
	echo 6.6.138 > "$W/resp/_.P5k"; echo 1.5.12-wsl.9 > "$W/resp/_.P5v"
	printf 'xx vermagic=6.6.138 SMP mod_unload aarch64 xx' > "$W/ko-1.5.12-wsl.9.ko"
}
ENV0=(REPO="$REPO" BENCH_NODE=n2 MESH_NODE=n4 OTS_NODE=n4 DESTRUCTIVE_NODE=n4 IPERF_PEER=n2 AB_MODE=--destructive FEATURE_MODE=--daily
      DV_T263_KO="$W/ko-1.5.12-wsl.9.ko" DV_T263_NODE=n2)
P=0; F=0
run() { env "${ENV0[@]}" "$@" bash "$REPO/scripts/dv-preflight.sh" 2>&1; }
want_pass() { base; o=$(run "$@"); if grep -q '^PREFLIGHT PASS' <<< "$o"; then echo "ok   baseline PASS"; P=$((P + 1)); else echo "FAIL baseline did not pass"; grep 'PREFLIGHT FAIL' <<< "$o"; F=$((F + 1)); fi; }
case_() {	# <name> <text that the FAIL must contain> <setup cmd> [env overrides...]
	local name=$1 txt=$2 setup=$3; shift 3
	base; eval "$setup"; o=$(run "$@"); r=$?
	if [ $r != 0 ] && grep -q "^PREFLIGHT FAIL: .*$txt" <<< "$o"; then echo "ok   $name -> FAIL ($txt)"; P=$((P + 1))
	else echo "FAIL $name: rc=$r, no 'PREFLIGHT FAIL ... $txt'"; grep 'PREFLIGHT' <<< "$o" | head -4; F=$((F + 1)); fi
}
want_pass
mkdir -p "$W/archive/scripts" "$W/archive/feed" "$W/archive/tests"; cp "$REPO/scripts/dv-preflight.sh" "$W/archive/scripts/"; cp -r "$REPO/scripts/node" "$REPO/scripts/lib" "$W/archive/scripts/"; touch "$W/archive/scripts/daily-validation.sh"
case_ "harness is a git archive (no .git)" "not a git checkout" ":" REPO="$W/archive"
case_ "BENCH == MESH" "BENCH_NODE == MESH_NODE" ":" MESH_NODE=n2
case_ "IPERF_PEER == MESH" "IPERF_PEER == MESH_NODE" ":" IPERF_PEER=n4
case_ "fleet versions differ" "fleet versions differ" "echo 'v=1.5.12-wsl.2 t=1 s=A h=[] c=bcm2711 ' > \$W/resp/n2.P3"
case_ "node is an uncommitted trial" "uncommitted trial" "echo 'v=1.5.12-wsl.9 t=0 s=B h=[] c=bcm2711 ' > \$W/resp/n4.P3"
case_ "leftover hold-commit flag" "leftover autocommit-hold-commit" "echo 'v=1.5.12-wsl.9 t=1 s=A h=[1.5.12-wsl.2] c=bcm2711 ' > \$W/resp/n2.P3"
case_ "BENCH on slot B (destructive)" "needs slot A" "echo B > \$W/resp/_.P3b"
case_ "FI payload is not the running build" "FI payload on n4" "printf 'ERR payload is not the build this node runs\n' > \$W/resp/_.PRE"
case_ "DV_T263_KO unset" "DV_T263_KO unset" ":" DV_T263_KO=
case_ "DV_T263_KO for another kernel" "vermagic" "echo 6.6.999 > \$W/resp/_.P5k"
case_ "DV_T263_KO from another build" "does not name the build" "echo 1.5.12-wsl.10 > \$W/resp/_.P5v"
case_ "BLE leftover (flipped marker)" "leftover: flipped" "printf 'FAIL leftover: flipped marker\n' > \$W/resp/n4.P6"
case_ "BLE_PERIPH is not DNODE (feature destructive)" "must be DNODE" ":" FEATURE_MODE=--destructive BLE_PERIPH=n2 BLE_CENTRAL=n4
case_ "logread flood" "logread flood" "echo '900|Wed Jul 16 11:59:30 2025|Wed Jul 16 12:00:00 2025' > \$W/resp/n2.P7"
case_ "node clock went backwards" "clock went backwards" "echo '900|Wed Jul 16 12:10:00 2025|Wed Jul 16 12:00:00 2025' > \$W/resp/n2.P7"
# P9 (#254 254-h23 §4.7 / §23.4): the node judge's verdict lines (the judge itself: tests/prov-p1/p9-judge.sh)
case_ "P9 [all] points at a wbox slot" "P9 n4 \[all\] points at slot B, a -wbox image" "printf 'FAIL [all] points at slot B, a -wbox image (x) — on the release slot run: batman-slot commit\nP9 fails=1\n' > \$W/resp/n4.P9"
case_ "P9 [all] unreadable" "P9 n2 \[all\] boot_partition unreadable" "printf 'FAIL [all] boot_partition unreadable or not 1|2 ([])\nP9 fails=1\n' > \$W/resp/n2.P9"
case_ "P9 dirty flag (an interrupted prov run)" "P9 n4 dv-prov-dirty" "printf 'FAIL dv-prov-dirty [r1 ab snap]: run restore\nP9 fails=1\n' > \$W/resp/n4.P9"
case_ "P9 rollback arm still running" "P9 n4 a rollback arm is still running" "printf 'FAIL a rollback arm is still running (x pid 9)\nP9 fails=1\n' > \$W/resp/n4.P9"
case_ "P9 judge gives no verdict" "P9 n2 judge gave no verdict" "printf 'INFO half a reply\n' > \$W/resp/n2.P9"
p9note(){	# <name> <P9 reply> <grep for the line that must be printed>: PASS overall and that line present
	base; printf "$2" > "$W/resp/n4.P9"; o=$(run); r=$?
	if [ $r = 0 ] && grep -q '^PREFLIGHT PASS' <<< "$o" && grep -q "$3" <<< "$o"; then echo "ok   $1"; P=$((P + 1)); else echo "FAIL $1: rc=$r"; grep -E 'PREFLIGHT|P9' <<< "$o" | head -4; F=$((F + 1)); fi; }
p9note "P9 release trial: PASS, no warn" 'INFO trial in progress (DT tryboot=1, slot B)\nP9 clean\n' 'P9 n4 note: trial in progress'
p9note "P9 stale fallback: WARN, still PASS" 'WARN [all] points at slot A, not the running B (stale fallback)\nP9 clean\n' '^preflight warn: P9 n4 \[all\] points at slot A'
p9note "P9 pre-gate image: a note, still PASS" "INFO pre-gate image (batman-slot has no wbox gate): -wbox units FAIL 'pre-gate image' before any OTA\nP9 clean\n" 'P9 n4 note: pre-gate image'
p9note "P9 golden Pi 4: not applicable, PASS" 'INFO [all] check not applicable (not a Pi 4 A/B card)\nP9 clean\n' '^preflight ok: P9 n4 prov / wbox state clean'
base; printf 'INFO trial in progress (DT tryboot=1, slot B)\nP9 clean\n' > "$W/resp/n4.P9"; o=$(run)
grep -q '^preflight warn' <<< "$o" && { echo "FAIL P9 release trial printed a warn"; F=$((F + 1)); } || { echo "ok   P9 release trial prints no warn"; P=$((P + 1)); }
case_ "node unreachable" "not reachable" "rm -f \$W/resp/_.P3; echo 'v=1.5.12-wsl.9 t=1 s=A h=[] c=bcm2711 ' > \$W/resp/n4.P3"
echo "$P passed, $F failed"
[ "$F" = 0 ] && [ "$P" -gt 0 ]
