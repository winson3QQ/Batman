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
# every test gets stdin from /dev/null: a stub that drains stdin (test-bench-p5's ssh) waited forever on an inherited
# open pipe when the suite ran from a background shell (2026-11-09)
t() { local l=$1 want=$2 o; shift 2; o=$("$@" 2>&1 </dev/null); local rc=$?
	if [ $rc = 0 ] && grep -qE "$want" <<< "$(tail -3 <<< "$o")"; then tok "$l: $(tail -1 <<< "$o")"; else tbad "$l (rc $rc): $(tail -2 <<< "$o" | tr '\n' '|')"; fi; }
t "undo executor (namespace)" '^[1-9][0-9]* PASS / 0 FAIL$' bash "$REPO/tests/judges/h4/test-undo-lib.sh"
t "offline judges" '^[1-9][0-9]* PASS / 0 FAIL$' "$PY" "$REPO/tests/judges/h4/test-judges.py"
cd "$REPO/tests/tools/peer" || { tbad "no tests/tools/peer"; exit 1; }
t "peer.py (vectors + fake bridge)" 'peer.py selftest: [1-9][0-9]* checks, 0 failed' "$PY" peer.py --selftest
for m in netobj nodecert blebridge httprelay benchstore signrel; do t "$m" "$m selftest: [1-9][0-9]* checks, 0 failed" "$PY" "$m.py" --selftest; done
# the P3 test table (appendix A -> p3-units.tsv -> p3-how.tsv -> p3-manual-rows.md) is what the design gives now
t "bench_ip + p5_ap_back (stubbed node)" '^[1-9][0-9]* passed, 0 failed$' bash "$REPO/scripts/dv/test-bench-p5-254.sh"
t "rollback guard + field-anchored slot match + lint" '^================ test-slot-guard: [1-9][0-9]* passed, 0 failed' bash "$REPO/scripts/dv/test-slot-guard-254.sh"
# #254 v1.6 group 4 §13.1 / §15: the role deadmen through the real cmd_dm_fire / cmd_recover, in a mount namespace
t "role deadmen: a tryboot that will not clear -> no reboot, lease kept (namespace)" '^[1-9][0-9]* PASS / 0 FAIL$' bash "$REPO/scripts/dv/test-deadman-254.sh"
t "restore / finish path (nodes.txt line, A found by MAC, finish NEEDS-PERSON)" '^================ test-restore: [1-9][0-9]* passed, 0 failed' bash "$REPO/scripts/dv/test-restore-254.sh"
# #254 g4 §1 / §2 / §16: the ac-flap P3 judge, the host-derived misc-* mutants (each FAILs its named case; CRLF /
# work-tree / non-fitting patch / zero rows FAIL), wslx's retry of a WSL launcher failure only
t "acflap_judge (P3 rule, synthetic inputs)" '^TEST-ACFLAP: [1-9][0-9]* passed, 0 failed$' bash "$REPO/scripts/dv/test-acflap-254.sh"
t "derive_misc + misc-* mutants vs autocommit-mesh-arm" '^TEST-DERIVE-MISC: [1-9][0-9]* passed, 0 failed$' bash "$REPO/tests/wbox/test-derive-misc.sh"
t "dv-prov-tools wslx retry (stub wsl.exe)" '^TEST-WSLX: [1-9][0-9]* passed, 0 failed$' bash "$REPO/tests/wbox/test-wslx-retry.sh"
# 254-v16-group4 §3, §13.3, §13.6, §15: the 02 slot contract (pr_begin stub, the helpers' refusal, the PR_USES_02 lint)
# and the node p5 restore with p5 left mounted, run unmodified in a mount namespace (FAILs where none can be made)
t "02 slot contract (pr_begin before pr_acquire, as02 / restore02 / part 1 refusal, PR_USES_02 lint)" '^================ test-pr02: [1-9][0-9]* passed, 0 failed' bash "$REPO/scripts/dv/test-pr02-254.sh"
t "p5 restore with p5 mounted (mount namespace, harness mounts only)" '^p5-restore-ns: [1-9][0-9]* passed, 0 failed$' bash "$REPO/tests/prov-p1/p5-restore-ns.sh"
# #254 v1.6 g4 PR B (docs/design/254-v16-ud.md §9): provclient (go vet + test as the repo owner: its module cache), the
# helper decoder check (the real node.Handle, offline module cache), the stdout / stderr contract (root), signrel is
# above; the generators; the undo actions in a mount namespace; the UD9 watcher on a stub /proc; the unit's judges and
# host flows; the manual recovery block's dry run
OWNER=$(stat -c %U "$REPO"); GO=$OWNER_HOME/go/pkg/mod/golang.org/toolchain@v0.0.1-go1.26.4.linux-amd64/bin/go
asowner(){ if [ "$(id -u)" = 0 ] && [ "$OWNER" != root ]; then runuser -u "$OWNER" -- env HOME="$OWNER_HOME" PATH="$(dirname "$GO"):/usr/bin:/bin" GOTOOLCHAIN=local "$@"; else env PATH="$(dirname "$GO"):$PATH" GOTOOLCHAIN=local "$@"; fi; }
gotest(){ (cd "$1" && asowner env GOFLAGS="$2" GOPROXY=off go vet ./... && asowner env GOFLAGS="$2" GOPROXY=off go test -count=1 ./... 2>&1 | tail -3); }
t "provclient go vet + test (bodies, key-1 reasons, sha / version, no passphrase-derived output, golden vectors)" '^ok[[:space:]]+batman-provclient' gotest "$REPO/tests/tools/provclient" -mod=vendor
t "provclient-helpercheck: the vectors through the real node.Handle (pre-UD shape ESchema 20, new shape past the schema)" '^ok[[:space:]]+batman-provclient-helpercheck' gotest "$REPO/tests/tools/provclient-helpercheck" -mod=mod
if [ "$(id -u)" = 0 ]; then t "provclient black-box: exec / proxy stdout byte-identical, caps on stderr only (root)" '^provclient-blackbox: 3 passed, 0 failed$' env GO="$GO" bash "$REPO/tests/tools/provclient/blackbox.sh"
else tbad "provclient black-box needs root (node mode drops to uid 471)"; fi
t "UD payload generators: per-generator acceptance + negative controls" '^test-p3-payloads: [1-9][0-9]* passed, 0 failed$' bash "$REPO/scripts/dv/test-p3-payloads-254.sh"
t "undo: ssid-restore / rm-hold / undo-done / replay order (namespace)" '^[1-9][0-9]* PASS / 0 FAIL$' bash "$REPO/tests/judges/h4/test-undo-ud-254.sh"
t "UD9 watcher on a stub /proc (go gate, fresh dd only, kill / cut order, no global sync, p3 re-read)" '^test-ud9-watch: [1-9][0-9]* passed, 0 failed$' bash "$REPO/scripts/dv/test-ud9-watch-254.sh"
t "prov-update-254 judges + host flows (pr_pc refusal, cut poll, undo before restore)" '^test-prov-update: [1-9][0-9]* passed, 0 failed$' env H4_PY="$PY" bash "$REPO/scripts/dv/test-prov-update-254.sh"
t "UD-RECOVER block dry run (stub node, real prov-254.sh)" '^test-ud-recover: [1-9][0-9]* passed, 0 failed$' bash "$REPO/scripts/dv/test-ud-recover-254.sh"
t "P3 unit table (gen-p3-units --check)" '^gen-p3-units: ok, [1-9][0-9]* rows in [1-9][0-9]* units' python3 "$REPO/scripts/dv/gen-p3-units.py" --check
echo "$P passed, $F failed"; [ $F = 0 ]
