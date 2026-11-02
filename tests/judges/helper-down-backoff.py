#!/usr/bin/env python3
"""The helper-down arm's backoff judge (scripts/node/prov-p2-254.sh, the awk program after `r=$(echo "$b" | awk`)
run on the real 04 sequence and on sequences that lack the property: each of those must not be judged ok."""
import re, subprocess, sys
s = open(sys.argv[1], encoding='utf-8').read()
m = re.search(r"r=\$\(echo \"\$b\" \| awk '(.*?)'\)\n", s, re.S)
if not m:
    print("FAIL the helper-down awk program was not found"); sys.exit(1)
cases = [("1 2 4 8 10 10 ", True, "real 04 sequence (2026-11-01)"), ("1 1 1 1 1 1 ", False, "no growth"),
         ("1 2 4 ", False, "too few lines"), ("2 4 8 10 10 ", False, "does not start at 1 s"),
         ("1 2 4 8 16 32 ", False, "no 10 s cap"), ("1 2 4 8 8 8 ", False, "capped below 10 s"), ("", False, "nothing logged")]
bad = 0
for inp, want, why in cases:
    out = subprocess.run(['awk', m.group(1)], input=inp, capture_output=True, text=True).stdout.strip()
    ok = (out == "ok") == want
    bad += not ok
    print(("ok  " if ok else "FAIL") + f" helper-down backoff [{inp.strip()}] -> {out!r} ({why})")
sys.exit(1 if bad else 0)
