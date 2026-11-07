#!/bin/bash
# scripts/test-h4-offline-254.sh — the #254 H4 offline tests in one run (docs/design/254-h4-harness.md §1.2, §16), no
# node: the undo executor in a user + mount namespace (tests/judges/h4/test-undo-lib.sh; WSL / Linux only — CI's
# runner has no unprivileged user namespaces), the offline judges, and the host tools' selftests. Run by
# daily-validation (suite harness-h4-254). A tool missing or a selftest that ran nothing is a FAIL.
#   bash scripts/test-h4-offline-254.sh        -> "N passed, M failed", rc 1 on any FAIL
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
# the venv lives in the repo owner's home: daily-validation's WSL delegation runs as the distro's default user (root,
# HOME=/root; 2026-11-03 full run: "no python ... at /root/.batman-dv/...")
OWNER_HOME=$(getent passwd "$(stat -c %U "$REPO")" | cut -d: -f6)
PY=${H4_PY:-${OWNER_HOME:-$HOME}/.batman-dv/peer-venv/bin/python}
P=0; F=0
tok() { echo "ok   $1"; P=$((P + 1)); }
tbad() { echo "FAIL $1"; F=$((F + 1)); }
[ -x "$PY" ] || { tbad "no python with the pinned closure at $PY (H4_PY)"; echo "$P passed, $F failed"; exit 1; }
# <label> <pattern the last line must match> <cmd...>
t() { local l=$1 want=$2 o; shift 2; o=$("$@" 2>&1); local rc=$?
	if [ $rc = 0 ] && grep -qE "$want" <<< "$(tail -3 <<< "$o")"; then tok "$l: $(tail -1 <<< "$o")"; else tbad "$l (rc $rc): $(tail -2 <<< "$o" | tr '\n' '|')"; fi; }
t "undo executor (namespace)" '^[1-9][0-9]* PASS / 0 FAIL$' bash "$REPO/tests/judges/h4/test-undo-lib.sh"
t "offline judges" '^[1-9][0-9]* PASS / 0 FAIL$' "$PY" "$REPO/tests/judges/h4/test-judges.py"
cd "$REPO/tests/tools/peer" || { tbad "no tests/tools/peer"; exit 1; }
t "peer.py (vectors + fake bridge)" 'peer.py selftest: [1-9][0-9]* checks, 0 failed' "$PY" peer.py --selftest
for m in netobj nodecert blebridge httprelay benchstore signrel; do t "$m" "$m selftest: [1-9][0-9]* checks, 0 failed" "$PY" "$m.py" --selftest; done
# the P3 test table (appendix A -> p3-units.tsv -> p3-how.tsv -> p3-manual-rows.md) is what the design gives now
t "P3 unit table (gen-p3-units --check)" '^gen-p3-units: ok, [1-9][0-9]* rows in [1-9][0-9]* units' python3 "$REPO/scripts/dv/gen-p3-units.py" --check
echo "$P passed, $F failed"; [ $F = 0 ]
