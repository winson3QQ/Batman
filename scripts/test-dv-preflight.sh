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
case_ "node unreachable" "not reachable" "rm -f \$W/resp/_.P3; echo 'v=1.5.12-wsl.9 t=1 s=A h=[] c=bcm2711 ' > \$W/resp/n4.P3"
echo "$P passed, $F failed"
[ "$F" = 0 ] && [ "$P" -gt 0 ]
