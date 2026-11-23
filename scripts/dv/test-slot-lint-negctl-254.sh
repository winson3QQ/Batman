#!/bin/bash
# scripts/dv/test-slot-lint-negctl-254.sh [BASE] — the negative control of test-slot-guard-254.sh's lints (#254 v1.6 group 4
# §4.3, §13.8, §15), a one-off PR proof (not part of the daily suite: once later work edits a scanned line, the b885a2c
# run names that line too). It runs this checkout's test-slot-guard-254.sh with ROOT = an export of BASE (default main
# b885a2c, the tree before the conversion) and compares what lints (1)-(3) name ("NAMED <lint> <file><TAB><text>") with
# the independent list scripts/dv/data/slot-sites-converted.txt (the converted v16g4-sites.md rows), as a multiset:
#   - every expected entry named, nothing else named (lint 3 rows of group `text` that have no hit on BASE — the new
#     message lines this PR adds — are counted and listed, not compared: §15);
#   - and this checkout itself names nothing (all lints PASS).
# WSL / Linux (test-slot-guard needs busybox). Prints "NEGCTL PASS" / "NEGCTL FAIL"; rc 1 on FAIL.
set -u
H=$(cd "$(dirname "$0")/../.." && pwd); BASE=${1:-b885a2c}
X=$(mktemp -d); trap 'rm -rf "$X"' EXIT
# BASE: a commit (exported with git archive), or a directory that already holds such an export (WSL's git cannot read a
# worktree checked out by Windows git: export it there with `git archive b885a2c scripts tests feed | tar -x -C <dir>`)
if [ -d "$BASE" ]; then cp -a "$BASE/." "$X/"
else git -C "$H" archive "$BASE" scripts tests feed/batman-provision/files/usr/lib/batman | tar -x -C "$X" || { echo "NEGCTL FAIL cannot export $BASE"; exit 1; }; fi
[ -f "$X/scripts/dv/prov-254.sh" ] || { echo "NEGCTL FAIL no scripts/ in the $BASE export"; exit 1; }
CONV=$H/scripts/dv/data/slot-sites-converted.txt
[ -s "$CONV" ] || { echo "NEGCTL FAIL $CONV missing"; exit 1; }
ROOT=$X bash "$H/scripts/dv/test-slot-guard-254.sh" > "$X/old.out" 2>&1 </dev/null; orc=$?
bash "$H/scripts/dv/test-slot-guard-254.sh" > "$X/new.out" 2>&1 </dev/null; nrc=$?
grep -E '^NAMED (1|2|3) ' "$X/old.out" | sed -E 's/^NAMED ([123]) /\1\t/' | LC_ALL=C sort > "$X/got"
grep -v '^#' "$CONV" | cut -f2- | LC_ALL=C sort > "$X/want"
nt=$(grep -c '^NAMED 3t ' "$X/old.out")
echo "on $BASE: test-slot-guard rc=$orc, $(tail -1 "$X/old.out")"
echo "  named by lints (1)-(3): $(grep -c . "$X/got") (lint 1: $(grep -c '^1' "$X/got"), lint 2: $(grep -c '^2' "$X/got"), lint 3: $(grep -c '^3' "$X/got")); expected (slot-sites-converted.txt): $(grep -c . "$X/want")"
echo "  new text rows with no hit on $BASE (group text, not compared): $nt"
grep '^NAMED 3t ' "$X/old.out" | cut -c1-140 | sed 's/^/    /'
r=0
if d=$(diff "$X/want" "$X/got"); then echo "  the named set equals the converted rows exactly"
else echo "  DIFFERENT (< expected only, > named only):"; echo "$d" | grep '^[<>]' | cut -c1-200 | sed 's/^/    /'; r=1; fi
[ "$orc" != 0 ] || { echo "  test-slot-guard PASSED on $BASE — the lints do not discriminate"; r=1; }
if [ "$nrc" = 0 ] && ! grep -q '^NAMED' "$X/new.out"; then echo "on this checkout: $(tail -1 "$X/new.out"), nothing named"
else echo "on this checkout: rc=$nrc $(tail -1 "$X/new.out"); named: $(grep -c '^NAMED' "$X/new.out")"; r=1; fi
[ $r = 0 ] && echo "NEGCTL PASS" || echo "NEGCTL FAIL"; exit $r
