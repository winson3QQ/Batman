#!/bin/bash
# tests/known-failures.sh — scripts/dv/known-failures.sh (254-h23 §4 known-failures, expiry column). No network
# (KF_NO_GH=1). Zero cases = FAIL.
set -u
R=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/dv/known-failures.sh
. "$R/scripts/dv/known-failures.sh"
export KF_NO_GH=1
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; n=0; f=0
# shellcheck disable=SC2254  # $3 is a glob on purpose
want(){ n=$((n + 1)); case "$2" in $3) echo "ok   $1 ($2)" ;; *) echo "FAIL $1: [$2] want $3"; f=$((f + 1)) ;; esac; }
TAB=$'\t'
printf 'FAIL thing: the known symptom here\n' > "$T/s.log"
printf 's1%s^FAIL thing: the known symptom%s254%sexpires=2099-01-01\n' "$TAB" "$TAB" "$TAB" > "$T/ok.txt"
want "a valid unexpired entry -> known"            "$(kf_classify s1 "$T/s.log" "$T/ok.txt" 2026-10-28)" 'known #254*'
printf 's1%s^FAIL thing: the known symptom%s254%sexpires=2026-10-27\n' "$TAB" "$TAB" "$TAB" > "$T/old.txt"
want "an expired entry -> NEW (expired)"           "$(kf_classify s1 "$T/s.log" "$T/old.txt" 2026-10-28)" 'new (the entry for #254 2026-10-27 has expired*'
want "an entry valid through its own date -> known" "$(kf_classify s1 "$T/s.log" "$T/old.txt" 2026-10-27)" 'known #254*'
printf 'FAIL restore failed: 04 left dirty\n' > "$T/r.log"; printf 's1%s.%s254%sexpires=2099-01-01\n' "$TAB" "$TAB" "$TAB" > "$T/any.txt"
want "never-known lines stay NEW"                  "$(kf_classify s1 "$T/r.log" "$T/any.txt" 2026-10-28)" 'new (never-known*'
: > "$T/empty.log"; want "no FAIL lines -> NEW"     "$(kf_classify s1 "$T/empty.log" "$T/ok.txt" 2026-10-28)" 'new (no FAIL lines*'
o=$(kf_check "$T/ok.txt"); r=$?;  want "kf_check: a well-formed file"          "rc=$r" 'rc=0'
printf 's1%s^FAIL x%s254\n' "$TAB" "$TAB" > "$T/m3.txt"; o=$(kf_check "$T/m3.txt"); r=$?
want "kf_check: a missing 4th column -> FAIL"      "rc=$r $o" 'rc=1 FAIL known-failures: line 1 has not exactly 4 TAB columns*'
printf 's1%s^FAIL x%s254%s2099-01-01\n' "$TAB" "$TAB" "$TAB" > "$T/b1.txt"; o=$(kf_check "$T/b1.txt"); r=$?
want "kf_check: no expires= prefix -> FAIL"        "rc=$r $o" 'rc=1 FAIL known-failures: line 1 4th column*'
printf 's1%s^FAIL x%s254%sexpires=2026-13-40\n' "$TAB" "$TAB" "$TAB" > "$T/b2.txt"; o=$(kf_check "$T/b2.txt"); r=$?
want "kf_check: not a real date -> FAIL"           "rc=$r $o" 'rc=1 FAIL known-failures: line 1 4th column*'
printf 's1%s^FAIL x%s25a%sexpires=2099-01-01\n' "$TAB" "$TAB" "$TAB" > "$T/b3.txt"; o=$(kf_check "$T/b3.txt"); r=$?
want "kf_check: issue not a number -> FAIL"        "rc=$r $o" 'rc=1 FAIL known-failures: line 1 issue*'
o=$(kf_check "$R/scripts/validation-known-failures.txt"); r=$?; want "the real list is well-formed" "rc=$r $o" 'rc=0*'
echo "KNOWN-FAILURES cases=$n fails=$f"; [ "$n" -gt 0 ] && [ "$f" = 0 ]
