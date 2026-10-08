#!/bin/bash
# scripts/test-harness-265.sh — offline stub test of the validation harness's reachability logic (#265 v1.2):
#   fault-injection.sh  q() retry / UNREAD -> UNDETERMINED (never PASS), settle(), wait_revert(), wait_held()
#   lib/fleet-settle.sh fast path / slow path / timeout -> FAIL row + node leaves the fleet
# A fake `ssh` replays a scenario file: one line per call, "<rc>|<stdout>". No node, no network.
# Run by daily-validation (harness-265) and CI. Exit 0 = all checks passed.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin"
cat > "$W/bin/ssh" <<'FAKE'
#!/bin/bash
# fake ssh: pops the next "<rc>|<out>" line of $FAKE_SCEN; counts calls in $FAKE_SCEN.n
n=$(cat "$FAKE_SCEN.n" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$FAKE_SCEN.n"
l=$(sed -n "${n}p" "$FAKE_SCEN")
[ -n "$l" ] || l=$(tail -1 "$FAKE_SCEN")          # past the end: repeat the last line
rc=${l%%|*}; out=${l#*|}
[ -n "$out" ] && printf '%s\n' "$out"
exit "$rc"
FAKE
chmod +x "$W/bin/ssh"
export PATH="$W/bin:$PATH"
P=0; F=0
tok(){ echo "ok   $1"; P=$((P+1)); }
tbad(){ echo "FAIL $1"; F=$((F+1)); }
scen(){ export FAKE_SCEN="$W/scen.$1"; printf '%s\n' "${@:2}" > "$FAKE_SCEN"; rm -f "$FAKE_SCEN.n"; }
calls(){ cat "$FAKE_SCEN.n" 2>/dev/null || echo 0; }

# ---------- fault-injection.sh functions ----------
# shellcheck disable=SC1091
FI_SOURCE_ONLY=1 . "$REPO/scripts/fault-injection.sh" testnode --case r1
trap 'rm -rf "$W" "$FI_TMP"' EXIT          # replace the script's EXIT trap (restore_node) — no node here
sleep(){ :; }                               # the retry/poll waits, instantly
no(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }

# 1 q retries a connection failure (255) and returns the eventual reading; nothing recorded unreadable
unread_reset; scen q1 '255|' '255|' '0|hello'
o=$(q cat x); rc=$?
[ "$o" = hello ] && [ $rc = 0 ] && [ ! -s "$UNREADF" ] && [ "$(calls)" = 3 ] && tok "q: 255,255,ok -> reading after 3 calls" || tbad "q retry (o=$o rc=$rc calls=$(calls))"
# 2 a command's own rc (1) is passed through, never retried
unread_reset; scen q2 '1|'
q false; rc=$?
[ $rc = 1 ] && [ "$(calls)" = 1 ] && [ ! -s "$UNREADF" ] && tok "q: rc 1 passed through, 1 call" || tbad "q rc passthrough (rc=$rc calls=$(calls))"
# 3 all attempts fail -> rc 255 + recorded; and it survives a $(...) pipeline subshell (review F2)
unread_reset; scen q3 '255|'
v=$(q 'batman-slot active' | tr -d x); rc=$?
[ $rc = 255 ] && [ -z "$v" ] && grep -q 'batman-slot active' "$UNREADF" && [ "$(calls)" = 6 ] && tok "q: 6x255 -> rc 255, recorded through a \$(q|tr) subshell" || tbad "q unreadable (rc=$rc calls=$(calls) unread=$(cat "$UNREADF"))"
# 4 undetermined: FAILs with UNDETERMINED/not verified (NEVER_KNOWN words), never a PASS
FAIL=0; PASS=0; o=$(undetermined R9; echo "rc=$?")
echo "$o" | grep -q 'FAIL R9 UNDETERMINED: node unreadable (batman-slot active' && echo "$o" | grep -q 'not verified' && echo "$o" | grep -q 'rc=0' \
  && tok "undetermined: prints an UNDETERMINED ... not verified FAIL" || tbad "undetermined output [$o]"
unread_reset; undetermined R9 && tbad "undetermined fired with nothing unreadable" || tok "undetermined: silent when everything was read"
# 5 a hung session (timeout rc 124) is retried like 255
unread_reset; scen q5 '124|' '0|x'
o=$(q a); [ "$o" = x ] && [ "$(calls)" = 2 ] && tok "q: rc 124 (hung, timed out) retried" || tbad "q 124 (o=$o calls=$(calls))"

# 6 settle: uptime < 60 does not count; three same-boot answers do
scen s1 '0|b1 30' '0|b1 70' '0|b1 75' '0|b1 80'
settle 5 && [ "$(calls)" = 4 ] && tok "settle: uptime floor, then 3 same-boot answers" || tbad "settle basic (calls=$(calls))"
# 7 settle: a reboot in between restarts the count; an empty answer resets it
scen s2 '0|b1 70' '0|b1 75' '0|b2 61' '0|b2 66' '255|' '0|b2 70' '0|b2 75' '0|b2 80'
settle 5 && [ "$(calls)" = 8 ] && tok "settle: boot change and a dropped answer restart the count" || tbad "settle reset (calls=$(calls))"
# 8 settle: never stable -> rc 1 within its budget
scen s3 '255|'
settle 2; [ $? = 1 ] && tok "settle: unreachable -> fails at its budget" || tbad "settle timeout"

# 9 wait_revert: an empty read is NOT a new boot (review F1); a real change is
DEFER_MAX=0; scen w1 '255|' '0|B0 -' '255|' '0|B1 -'
wait_revert R1 B0 100; rc=$?
[ $rc = 0 ] && [ "$(calls)" = 4 ] && tok "wait_revert: empty reads skipped, returns on the real boot change" || tbad "wait_revert (rc=$rc calls=$(calls))"
# 10 wait_revert: a commit seen meanwhile = rc 2
scen w2 '0|B0 -' '0|B0 C'
wait_revert R1 B0 100; [ $? = 2 ] && tok "wait_revert: commit seen -> rc 2" || tbad "wait_revert commit"

# 11 wait_held: held for 60 s of host time -> 0 (SECONDS advanced by hand: sleep is a no-op here)
FAIL=0
sleep(){ SECONDS=$((SECONDS + ${1:-0})); }
H="held for operator acceptance (batman-autocommit release)"
scen h1 "0|B0 100 - mesh not joined" "0|B0 110 - $H" "0|B0 120 - $H" "0|B0 130 - $H" "0|B0 140 - $H" "0|B0 150 - $H" "0|B0 160 - $H" "0|B0 170 - $H"
o=$(wait_held R3 B0 600); rc=$?
[ $rc = 0 ] && echo "$o" | grep -q 'HELD for' && tok "wait_held: held 60 s -> ok" || tbad "wait_held ok (rc=$rc o=$o)"
# 12 wait_held: a reboot meanwhile is a FAIL
scen h2 "0|B0 100 - $H" "0|B9 20 - "
o=$(wait_held R3 B0 600); [ $? = 1 ] && echo "$o" | grep -q 'rebooted/reverted' && tok "wait_held: reboot -> FAIL" || tbad "wait_held reboot [$o]"
# 13 wait_held: committed while held is a FAIL
scen h3 "0|B0 100 C $H"
o=$(wait_held R3 B0 600); [ $? = 1 ] && echo "$o" | grep -q 'committed while HELD' && tok "wait_held: commit while held -> FAIL" || tbad "wait_held commit [$o]"
# 14 wait_held: never held before deadline-120 -> FAIL
scen h4 "0|B0 470 - mesh not joined" "0|B0 490 - mesh not joined"
o=$(wait_held R3 B0 600); [ $? = 1 ] && echo "$o" | grep -q 'not healthy-and-held' && tok "wait_held: never held -> FAIL" || tbad "wait_held never [$o]"
sleep(){ :; }

# ---------- lib/fleet-settle.sh ----------
DIR=$W/dv; mkdir -p "$DIR"; NFAIL=0; FAILED=(); ROWS=()
UPS=""   # nodes that answer `up`
up(){ case " $UPS " in *" $1 "*) return 0;; esac; return 1; }
fssh(){ ssh x "$3"; }
# shellcheck disable=SC1091
. "$REPO/scripts/lib/fleet-settle.sh"
# 15 fleet_init keeps only reachable nodes, de-duplicated
UPS="n1 n2"; FLEET=""; fleet_init n1 n2 n1 n3 "" >/dev/null
[ "$FLEET" = "n1 n2" ] && tok "fleet_init: reachable, de-duplicated" || tbad "fleet_init [$FLEET]"
# 16 fast path: non-destructive suite, all up -> no ssh at all
scen f1 '0|zz 100'
fleet_settle s1 ""; [ "$(calls)" = 0 ] && [ "$NFAIL" = 0 ] && tok "fleet_settle: fast path, no slow probe" || tbad "fast path (calls=$(calls))"
# 17 slow path for a declared-destructive suite even when all are up
scen f2 '0|bb 100'
fleet_settle s2 D >/dev/null; [ "$(calls)" = 6 ] && [ "$NFAIL" = 0 ] && [ "$FLEET" = "n1 n2" ] && tok "fleet_settle: D -> 3 probes per node" || tbad "slow path D (calls=$(calls) fleet=$FLEET)"
# 18 a node down after a plain suite triggers the slow path
UPS="n1"; scen f3 '0|bb 100'
fleet_settle s3 "" >/dev/null; [ "$(calls)" = 6 ] && [ "$NFAIL" = 0 ] && tok "fleet_settle: node down -> slow path" || tbad "slow path down (calls=$(calls))"
# 19 timeout: FAIL row + log FAIL line + node removed
FLEET_SETTLE_MAX=1; FLEET="n1"; scen f4 '255|'
fleet_settle ramoops-173 D >/dev/null
[ "$NFAIL" = 1 ] && [ -z "$FLEET" ] && [ "${FAILED[0]}" = fleet-settle-after-ramoops-173 ] && grep -q '^FAIL fleet node n1' "$DIR/fleet-settle-after-ramoops-173.log" \
  && tok "fleet_settle: timeout -> FAIL row, FAIL line in its log, node leaves the fleet" || tbad "timeout (NFAIL=$NFAIL fleet=$FLEET)"
# 20 an empty fleet costs nothing
scen f5 '0|bb 100'; fleet_settle s5 D; [ "$(calls)" = 0 ] && tok "fleet_settle: empty fleet -> no-op" || tbad "empty fleet"

echo "================ test-harness-265: $P passed, $F failed ================"
[ "$F" = 0 ]
