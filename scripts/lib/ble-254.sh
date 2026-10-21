# shellcheck shell=bash
# scripts/lib/ble-254.sh — host side of the #254 BLE suites (PR-H1, docs/design/254-h1-harness.md).
# Sourced by daily-validation.sh, dv-preflight.sh and the tests. Needs: REPO.
# Env: DV_BT_TOOLS (dir with btmgmt, btmon, SHA256SUMS; default ~/batman-dv-tools/bluez-5.72),
#      DV_PY (a Python with `cryptography`; Git Bash default = the WSL venv), BLE_RUN_ID (default: generated).
DV_BT_TOOLS=${DV_BT_TOOLS:-$HOME/batman-dv-tools/bluez-5.72}
BLE_RUN_ID=${BLE_RUN_ID:-dv$(date +%s)p$$}
BLE_DIR=/tmp/run/batman-dv/bt/$BLE_RUN_ID
BLE_SSHO=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR -o ConnectTimeout=8)

# host monotonic seconds (/proc/uptime exists under Git Bash and WSL; bash $SECONDS follows the wall clock)
mono() { cut -d. -f1 /proc/uptime; }

# the Python that runs scripts/ble-ah.py, and the path of that script as THAT Python sees it
ble_py_cmd() {
	if [ -n "${DV_PY:-}" ]; then echo "$DV_PY"; return; fi
	case "$(uname -o 2>/dev/null)" in
		Msys|Cygwin) echo "wsl -d Ubuntu-24.04 -u yello -- /home/yello/venv-219/bin/python" ;;
		*) echo "/home/yello/venv-219/bin/python" ;;
	esac
}
ble_ah_path() {
	case "$REPO" in
		//wsl.localhost/*) local p=${REPO#//wsl.localhost/}; echo "/${p#*/}/scripts/ble-ah.py" ;;
		*) echo "$REPO/scripts/ble-ah.py" ;;
	esac
}
# ble_ah <addr>... ; stdin = the IRK line (never an argument)
ble_ah() { MSYS_NO_PATHCONV=1 $(ble_py_cmd) "$(ble_ah_path)" "$@"; }

# run a staged node script: ble_n <node> <secs> <periph|central> <cmd> [args]   (stdin passes through)
ble_n() {
	local n=$1 t=$2 role=$3; shift 3
	timeout "$t" ssh "${BLE_SSHO[@]}" "root@$n" "RUN_ID=$BLE_RUN_ID sh $BLE_DIR/ble-$role-254.sh $*"
}

# tools: SHA256SUMS in the tools dir must match both files (preflight P6 prints them)
ble_tools_check() {
	local d=$DV_BT_TOOLS
	[ -f "$d/btmgmt" ] && [ -f "$d/btmon" ] && [ -f "$d/SHA256SUMS" ] || { echo "FAIL DV_BT_TOOLS=$d lacks btmgmt / btmon / SHA256SUMS (scripts/dv-bt-tools.sh <bluez build dir>)"; return 1; }
	(cd "$d" && sha256sum -c --quiet SHA256SUMS) >/dev/null 2>&1 || { echo "FAIL $d/SHA256SUMS does not match its files"; return 1; }
	local f m
	for f in btmgmt btmon; do
		m=$(od -An -tx1 -j0 -N4 "$d/$f" | tr -d ' \n'); [ "$m" = 7f454c46 ] || { echo "FAIL $d/$f is not an ELF file"; return 1; }
		m=$(od -An -tx1 -j18 -N2 "$d/$f" | tr -d ' \n'); [ "$m" = b700 ] || { echo "FAIL $d/$f is not aarch64 (e_machine $m)"; return 1; }
	done
	echo "ok   tools: $(cd "$d" && tr '\n' ' ' < SHA256SUMS | cut -c1-200)"
}

# stage <node> <periph|central>: run dir (root 0700), files, chmod, stage-check incl. sha compare
ble_stage() {
	local n=$1 role=$2 f files o
	files=("$REPO/scripts/node/ble-lib-254.sh" "$REPO/scripts/node/ble-$role-254.sh")
	[ "$role" = periph ] && files+=("$DV_BT_TOOLS/btmgmt" "$DV_BT_TOOLS/btmon")
	{ cat "$REPO/scripts/node/ble-lib-254.sh"; echo "scratch; d=\$BT/$BLE_RUN_ID; [ -e \"\$d\" ] && { echo \"FAIL \$d exists\"; exit 1; }; mkdir -m 700 \"\$d\" && echo STAGED-DIR"; } \
		| timeout 30 ssh "${BLE_SSHO[@]}" "root@$n" sh -s | grep -q STAGED-DIR || { echo "FAIL could not create $BLE_DIR on $n"; return 1; }
	scp -q "${BLE_SSHO[@]}" "${files[@]}" "root@$n:$BLE_DIR/" || { echo "FAIL scp to $n failed"; return 1; }
	timeout 20 ssh "${BLE_SSHO[@]}" "root@$n" "chmod 700 $BLE_DIR/*" || { echo "FAIL chmod on $n"; return 1; }
	o=$(ble_n "$n" 60 "$role" stage-check) || { echo "$o"; return 1; }
	for f in "${files[@]}"; do
		local h; h=$(sha256sum "$f" | cut -c1-64)
		grep -q "^$h  $(basename "$f")\$" <<< "$o" || { echo "FAIL $(basename "$f") on $n differs from the host copy"; return 1; }
	done
	echo "ok   staged $role on $n ($BLE_RUN_ID)"
}

# ble_recover <node> <periph|central>: clean up after an interrupted run (preflight P6 points here)
ble_recover() { ble_stage "$1" "$2" && ble_n "$1" 300 "$2" recover; }

# random advertising name per run: BatmanT-<6 hex>
ble_name() { echo "BatmanT-$(od -An -tx1 -N3 /dev/urandom | tr -d ' \n')"; }
