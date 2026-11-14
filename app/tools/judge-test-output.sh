#!/bin/bash
# app/tools/judge-test-output.sh — judge a saved test log by what ran, never by the runner's exit status alone
# (`go test` on a package with no tests and `cargo test -- --ignored` with nothing ignored both exit 0).
#   go    <log> <Name,Name,...>   `go test -v` output: every named test has a top-level "--- PASS: <Name> (", the
#                     number of top-level "--- PASS" is exactly the number of names (a renamed, swapped or extra test
#                     FAILs), no "--- FAIL" at any depth, no "FAIL" line, at least one "ok" package line
#   cargo <log> <N>   `cargo test --test <one target>` output: exactly one "test result:" line, and it reads
#                     "ok. N passed; 0 failed; 0 ignored"
#   --selftest        both judges on good and bad synthetic logs (0 tests, one short, a renamed / swapped / extra
#                     test, a failure, an ignored test)
# The go names and the cargo N are exact on purpose for these two small fixed suites (adding a test there means
# editing the workflow in the same PR). The big suites (test-all.sh, kotlin-unit-tests.sh) are judged "> 0 and every
# must-run name", not by totals.
set -u
judge(){ # <go> <log> <names> | <cargo> <log> <N>
	local kind=$1 log=$2 n=$3 pass failn okn lines name miss want
	[ -s "$log" ] || { echo "FAIL $kind: log $log is missing or empty"; return 1; }
	case $kind in
	go)
		pass=$(grep -cE '^--- PASS: ' "$log"); failn=$(grep -cE '^\s*--- FAIL: |^FAIL(\s|$)' "$log"); okn=$(grep -cE '^ok\s' "$log")
		miss=; want=0
		for name in ${n//,/ }; do
			want=$((want + 1)); grep -qE "^--- PASS: $name \(" "$log" || miss="$miss $name"
		done
		if [ "$want" -gt 0 ] && [ "$pass" = "$want" ] && [ -z "$miss" ] && [ "$failn" = 0 ] && [ "$okn" -ge 1 ]; then
			echo "PASS go: all $want named top-level tests passed, 0 failed"
		else echo "FAIL go: top-level passed=$pass (want $want)${miss:+ not passed:$miss} fail lines=$failn ok packages=$okn"; return 1; fi ;;
	cargo)
		lines=$(grep -cE '^test result: ' "$log")
		if [ "$lines" = 1 ] && grep -qE "^test result: ok\. $n passed; 0 failed; 0 ignored; " "$log"; then echo "PASS cargo: $n passed; 0 failed; 0 ignored"
		else echo "FAIL cargo: want one line 'test result: ok. $n passed; 0 failed; 0 ignored', got $lines: $(grep -E '^test result: ' "$log" | cut -c1-80 | paste -sd'|')"; return 1; fi ;;
	*) echo "usage: $0 go <log> <Name,...> | cargo <log> <N> | --selftest"; return 2 ;;
	esac
}
if [ "${1:-}" = --selftest ]; then
	t=$(mktemp -d); bad=0
	t_case(){ # <want rc> <name> <kind> <N> ; log on stdin
		cat > "$t/log"; out=$(judge "$3" "$t/log" "$4"); rc=$?
		if [ "$rc" = "$1" ]; then echo "ok   $2 -> rc=$rc $out"; else echo "BAD  $2 -> rc=$rc (want $1) $out"; bad=1; fi
	}
	N8=TestT1,TestT2,TestT3,TestT4,TestT5,TestT6,TestT7,TestT8
	gp(){ local i; for i in "$@"; do echo "=== RUN   $i"; echo "--- PASS: $i (0.00s)"; done; }
	okl(){ echo PASS; echo "ok  	batman-sigverify	0.5s"; }
	{ gp TestT{1..8}; okl; } | t_case 0 "go the 8 named passed" go $N8
	{ gp TestT{1..7}; okl; } | t_case 1 "go 7 passed (one test gone)" go $N8
	{ gp TestT{1..7} TestT8x; okl; } | t_case 1 "go one test renamed (TestT8 -> TestT8x)" go $N8
	{ gp TestT{1..7} TestT1; okl; } | t_case 1 "go one test swapped for a second TestT1 (count right, name missing)" go $N8
	{ gp TestT{1..8} TestT9; okl; } | t_case 1 "go an extra test" go $N8
	{ gp TestT{1..8}; echo "    --- PASS: TestT8/sub (0.00s)"; okl; } | t_case 0 "go subtests are not counted" go $N8
	{ gp TestT{1..7}; echo "--- FAIL: TestT8 (0.00s)"; echo FAIL; echo "FAIL	batman-sigverify	0.5s"; } | t_case 1 "go one failed" go $N8
	{ gp TestT{1..8}; echo "    --- FAIL: TestT8/sub (0.00s)"; echo "ok  	batman-sigverify	0.5s"; } | t_case 1 "go a failed subtest" go $N8
	echo "?   	batman-sigverify	[no test files]" | t_case 1 "go no test files" go $N8
	{ echo "testing: warning: no tests to run"; echo PASS; echo "ok  	batman-sigverify	0.1s [no tests to run]"; } | t_case 1 "go 0 tests ran" go $N8
	{ gp TestT{1..8}; okl; } | t_case 1 "go an empty name list" go ","
	echo "test result: ok. 3 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.34s" | t_case 0 "cargo 3 passed" cargo 3
	echo "test result: ok. 2 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.34s" | t_case 1 "cargo 2 passed" cargo 3
	echo "test result: ok. 0 passed; 0 failed; 3 ignored; 0 measured; 0 filtered out; finished in 0.00s" | t_case 1 "cargo 0 ran (--ignored forgotten)" cargo 3
	echo "test result: ok. 3 passed; 0 failed; 1 ignored; 0 measured; 0 filtered out; finished in 0.34s" | t_case 1 "cargo one ignored" cargo 3
	echo "test result: FAILED. 2 passed; 1 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.34s" | t_case 1 "cargo one failed" cargo 3
	echo "error: no test target named noise_live" | t_case 1 "cargo no result line" cargo 3
	: > "$t/log"; out=$(judge cargo "$t/log" 3); rc=$?; if [ "$rc" = 1 ]; then echo "ok   empty log -> rc=1 $out"; else echo "BAD  empty log -> rc=$rc"; bad=1; fi
	rm -rf "$t"
	[ "$bad" = 0 ] && echo "selftest: 18/18 ok" || echo "selftest: FAIL"
	exit "$bad"
fi
[ $# = 3 ] || { echo "usage: $0 go <log> <Name,...> | cargo <log> <N> | --selftest"; exit 2; }
judge "$1" "$2" "$3"
