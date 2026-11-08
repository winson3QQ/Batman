#!/bin/bash
# app/rust/batman-proto/test-all.sh — the crate's regular test suite: BOTH builds (design §4.1 / §6: the trust policy is
# the Cargo feature `dev-trust`, so `cargo test` alone compiles the dev-build tests out). Each build must run and pass a
# non-zero number of tests, the dev-only and field-only trust tests must each have run, and the release feature tree
# must carry neither `dev-trust` nor `test-vectors`. Anything missing is a FAIL, never a clean result.
set -u
cd "$(dirname "$0")" || exit 2
CARGO=${CARGO:-cargo}
fail=0
run(){ # <name> <must-run test> [cargo args]
	local name=$1 must=$2; shift 2
	local out passed failed
	out=$($CARGO test "$@" -- --test-threads=4 2>&1); local rc=$?
	passed=$(grep -E '^test result:' <<< "$out" | sed -E 's/.* ([0-9]+) passed; ([0-9]+) failed.*/\1/' | paste -sd+ | bc)
	failed=$(grep -E '^test result:' <<< "$out" | sed -E 's/.* ([0-9]+) passed; ([0-9]+) failed.*/\2/' | paste -sd+ | bc)
	if [ "$rc" != 0 ] || [ "${failed:-1}" != 0 ]; then echo "FAIL $name: cargo rc=$rc failed=${failed:-?}"; grep -E 'FAILED|panicked|^error' <<< "$out" | head -5; fail=1
	elif [ "${passed:-0}" -le 0 ]; then echo "FAIL $name: no test ran"; fail=1
	elif ! grep -q "^test $must \.\.\. ok$" <<< "$out"; then echo "FAIL $name: $must did not run"; fail=1
	else echo "PASS $name: $passed tests"; fi
}
run field-build first_contact_field_build_refuses_dev_certificates
run dev-build first_contact_dev_build_accepts_dev_tofu --features dev-trust
n=$($CARGO tree -e features,no-dev 2>/dev/null | grep -cE 'dev-trust|test-vectors')
if [ "$n" = 0 ] && $CARGO tree -e features,no-dev >/dev/null 2>&1; then echo "PASS release feature tree: no dev-trust / test-vectors"
else echo "FAIL release feature tree: $n line(s) with dev-trust / test-vectors"; fail=1; fi
[ "$fail" = 0 ] && echo "ALL PASS" || echo "SUITE FAIL"
exit "$fail"
