#!/bin/bash
# tests/vectors/219-protocol/ci-check.sh — the protocol-vector gate (#254 PR-H1 §4.2), run by CI (vectors-219)
# and by hand. PY = a Python with requirements.txt installed (CI: --require-hashes --no-deps).
#   1. verify.py passes, and its count is at least MIN_CHECKS (a silently deleted check fails the gate)
#   2. gen.py reproduces vectors.json byte for byte
#   3. negative control: one flipped byte in psk_replay must make verify.py fail ON the psk_replay checks,
#      with no Python traceback (a crash is not a rejection)
# Exit 0 = all three held.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
PY=${PY:-python3}
MIN_CHECKS=${MIN_CHECKS:-195}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
rc=0
cd "$HERE" || exit 1

"$PY" verify.py vectors.json > "$W/verify.out" 2>&1; v=$?
last=$(tail -1 "$W/verify.out")
n=$(printf '%s\n' "$last" | sed -n 's/^\([0-9][0-9]*\) checks: ALL PASSED$/\1/p')
if [ $v -ne 0 ] || [ -z "$n" ]; then
  echo "FAIL verify.py rc=$v, last line: $last"; grep '^FAIL ' "$W/verify.out" | head -20; rc=1
elif [ "$n" -lt "$MIN_CHECKS" ]; then
  echo "FAIL verify.py ran $n checks, fewer than MIN_CHECKS=$MIN_CHECKS (a check was removed?)"; rc=1
else
  echo "ok   verify.py: $n checks, all passed (>= $MIN_CHECKS)"
fi

if "$PY" gen.py > "$W/gen.json" 2> "$W/gen.err" && cmp -s "$W/gen.json" vectors.json; then
  echo "ok   gen.py reproduces vectors.json byte for byte"
else
  echo "FAIL gen.py output differs from vectors.json (or gen.py failed)"; head -5 "$W/gen.err"; rc=1
fi

# negative control: flip the last hex digit of psk_replay.psk_replay
"$PY" - vectors.json "$W/neg.json" <<'PYEOF'
import json, sys
v = json.load(open(sys.argv[1], encoding="utf-8"))
h = v["psk_replay"]["psk_replay"]
v["psk_replay"]["psk_replay"] = h[:-1] + format(int(h[-1], 16) ^ 1, "x")
json.dump(v, open(sys.argv[2], "w", encoding="utf-8"), indent=2)
PYEOF
"$PY" verify.py "$W/neg.json" > "$W/neg.out" 2>&1; nv=$?
if [ $nv -eq 0 ]; then
  echo "FAIL negative control: verify.py accepted a tampered psk_replay"; rc=1
elif grep -q 'Traceback' "$W/neg.out"; then
  echo "FAIL negative control: verify.py crashed instead of rejecting"; grep -A3 Traceback "$W/neg.out" | head -8; rc=1
elif ! grep -q '^FAIL psk_replay' "$W/neg.out"; then
  echo "FAIL negative control: verify.py failed, but not on a psk_replay check:"; grep '^FAIL ' "$W/neg.out" | head -5; rc=1
else
  echo "ok   negative control: tampered psk_replay rejected ($(grep -c '^FAIL ' "$W/neg.out") FAIL lines, e.g. $(grep -m1 '^FAIL psk_replay' "$W/neg.out"))"
fi
exit $rc
