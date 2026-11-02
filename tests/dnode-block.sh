#!/bin/bash
# tests/dnode-block.sh — scripts/dv/prov-dv-254.sh dnode_blocked (254-h23 §3 NEEDS-PERSON; review B-M1), plus the check
# that daily-validation's suite() calls it before running a command. No network. Zero cases = FAIL.
set -u
R=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/dv/prov-dv-254.sh
. "$R/scripts/dv/prov-dv-254.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; n=0; f=0
want(){ n=$((n + 1)); if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: [$2] want [$3]"; f=$((f + 1)); fi; }
b(){ dnode_blocked "$@" >/dev/null && echo blocked || echo runs; }
want "no needs-person file -> runs"              "$(b D 'bchk_x 10.41.1.3' "$T" 10.41.1.3)" runs
echo "NEEDS-PERSON prov-x (r1): restore failed" > "$T/needs-person.txt"
want "D suite on DNODE after NEEDS-PERSON -> blocked" "$(b D 'bchk_x 10.41.1.3 a' "$T" 10.41.1.3)" blocked
want "the line names the reason"                 "$(dnode_blocked D 'bchk_x 10.41.1.3' "$T" 10.41.1.3)" "FAIL blocked: DNODE 10.41.1.3 was handed to a person earlier in this run — NEEDS-PERSON prov-x (r1): restore failed"
want "a non-D suite still runs"                  "$(b '' 'chk_x 10.41.1.3' "$T" 10.41.1.3)" runs
want "a D suite on another node still runs"      "$(b D 'bchk_x 10.41.1.1' "$T" 10.41.1.3)" runs
want "10.41.1.30 is not 10.41.1.3"               "$(b D 'bchk_x 10.41.1.30' "$T" 10.41.1.3)" runs
want "an IP at the end of the command"           "$(b D 'bchk_x 10.41.1.3' "$T" 10.41.1.3)" blocked
: > "$T/needs-person.txt"; want "an empty needs-person file -> runs" "$(b D 'bchk_x 10.41.1.3' "$T" 10.41.1.3)" runs
# suite() must consult it before the eval of the command
s=$(awk '/^suite\(\) \{/,/^}/' "$R/scripts/daily-validation.sh")
a=$(grep -n 'dnode_blocked' <<< "$s" | head -1 | cut -d: -f1); e=$(grep -n 'eval "\$cmd"' <<< "$s" | head -1 | cut -d: -f1)
want "suite() calls dnode_blocked before eval \$cmd" "$([ -n "$a" ] && [ -n "$e" ] && [ "$a" -lt "$e" ] && echo yes || echo no)" yes
echo "DNODE-BLOCK cases=$n fails=$f"; [ "$n" -gt 0 ] && [ "$f" = 0 ]
