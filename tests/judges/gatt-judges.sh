#!/bin/bash
# tests/judges/gatt-judges.sh — offline negative controls of prov-gatt-254's shell pieces (#254; the prov-gatt-254 design
# §3, §4.4, §7), run on the host with the REAL functions cut out of the files and their node / host calls stubbed:
#   dm_rm_scratch (scripts/node/prov-lease-254.sh): removes this run's two scratch dirs (after SIGINT to their *.pid
#     jobs), never another run's, never anything for a malformed run id, a symlink as a link (not followed)
#   gl_take / gl_release (scripts/dv/prov-gatt-254.sh): a live lock is refused, a stale one taken over only with no
#     bridge running; the lock is KEPT while an orphan runs (review A2-m7 / A3-m6)
#   hex_ok / addr_ok (scripts/node/prov-p2-central-254.sh): only hex / a MAC reach bluetoothctl's command stream
# Prints "ok"/"FAIL" per case and "gatt-judges: <n> passed, <m> failed"; exit 1 on any failure.
set -u
REPO=${REPO:-$(cd "$(dirname "$0")/../.." && pwd)}
pass=0; bad=0
tok(){ echo "ok   $*"; pass=$((pass + 1)); }; tbad(){ echo "FAIL $*"; bad=$((bad + 1)); }
fn(){ awk -v n="$2" '!p && $0 ~ "^"n"\\(\\)" {p=1; print; if ($0 ~ /; }[[:space:]]*(#.*)?$/) exit; next} p {print} p && /^}/ {exit}' "$1"; }
W=$(mktemp -d); trap 'kill $SLP 2>/dev/null; rm -rf "$W"' EXIT
SLP=""

# ---- dm_rm_scratch, with /tmp/run moved into $W
src=$(fn "$REPO/scripts/node/prov-lease-254.sh" dm_rm_scratch | sed "s#/tmp/run/#$W/run/#g")
[ -n "$src" ] || { tbad "dm_rm_scratch not found"; exit 1; }
eval "$src"
mkdir -p "$W/run/batman-dvpc.r1" "$W/run/batman-dv/wbox/r1" "$W/run/batman-dvpc.r2" "$W/keep"
echo snoop > "$W/run/batman-dvpc.r1/g-m1.snoop"; echo x > "$W/keep/precious"
# job control on while it starts: a non-interactive shell's background job would ignore SIGINT and prove nothing
set -m; sleep 30 & SLP=$!; set +m; echo "$SLP" > "$W/run/batman-dvpc.r1/live.pid"
o=$(dm_rm_scratch r1)
sleep 0.5
[ ! -e "$W/run/batman-dvpc.r1" ] && [ ! -e "$W/run/batman-dv/wbox/r1" ] && tok "dm_rm_scratch: this run's provclient dir and W dir are gone ($(echo $o))" || tbad "dm_rm_scratch left: $(ls "$W/run" "$W/run/batman-dv/wbox")"
kill -0 "$SLP" 2>/dev/null && tbad "dm_rm_scratch: the job of a *.pid file was not signalled" || tok "dm_rm_scratch: the *.pid job got SIGINT"
[ -d "$W/run/batman-dvpc.r2" ] && tok "dm_rm_scratch: another run's dir is untouched" || tbad "dm_rm_scratch removed another run's dir"
for badid in "" "../keep" "r1/../../keep" "a b" "*"; do
	o=$(dm_rm_scratch "$badid")
	[ -f "$W/keep/precious" ] && [ -z "$o" ] && tok "dm_rm_scratch [$badid]: refused, nothing removed" || tbad "dm_rm_scratch [$badid] removed something: $o"
done
mkdir -p "$W/run/target"; echo y > "$W/run/target/f"; ln -s "$W/run/target" "$W/run/batman-dvpc.r3"
o=$(dm_rm_scratch r3)
[ ! -L "$W/run/batman-dvpc.r3" ] && [ -f "$W/run/target/f" ] && tok "dm_rm_scratch: a symlinked dir is removed as a link, its target kept" || tbad "dm_rm_scratch followed a symlink"
# negative control: the same checks on a broken copy (no run-id check) must fail the malformed-id case
bsrc=$(sed 's#case "\$1" in .*esac#:#' <<< "$src"); eval "${bsrc/dm_rm_scratch()/dm_bad()}"
mkdir -p "$W/run/batman-dvpc." 2>/dev/null; o=$(dm_bad "")
[ -n "$o" ] && tok "negative control: without the run-id check an empty id removes a dir (the check matters)" || tbad "negative control did not bite"

# ---- gl_take / gl_release with the host calls stubbed
for f in gl_take gl_release host_boot; do s=$(fn "$REPO/scripts/dv/prov-gatt-254.sh" $f); [ -n "$s" ] || { tbad "$f not found"; exit 1; }; eval "$s"; done
say(){ echo "SAY $*"; }; no(){ echo "NO $*"; }
GL="$W/lock"; RUN=t1; GL_HELD=0; WINB=0; WSLP=0; : "$RUN"   # RUN: read by the eval'd gl_take
orph_win(){ echo "$WINB"; }; orph_wsl(){ echo "$WSLP"; }
o=$(gl_take; echo "held=$GL_HELD"); grep -q 'held=1' <<< "$o" && [ -f "$GL/owner" ] && tok "gl_take: a free lock is taken (owner written)" || tbad "gl_take free: $o"
sleep 60 & LIVE=$!
echo "pid=$LIVE boot=$(host_boot) start=1 run=other" > "$GL/owner"
o=$(gl_take; echo "rc=$?"); grep -q 'rc=1' <<< "$o" && grep -q 'held by a live run' <<< "$o" && tok "gl_take: a live owner's lock is refused" || tbad "gl_take live: $o"
kill $LIVE 2>/dev/null; wait $LIVE 2>/dev/null
o=$(gl_take; echo "rc=$? held=$GL_HELD"); grep -q 'taking over a stale' <<< "$o" && grep -q 'rc=0 held=1' <<< "$o" && tok "gl_take: a dead owner's lock is printed and taken over" || tbad "gl_take stale: $o"
echo "pid=999999 boot=1 start=1 run=old" > "$GL/owner"; WINB=1
o=$(gl_take; echo "rc=$?"); grep -q 'rc=1' <<< "$o" && grep -q 'still runs' <<< "$o" && tok "gl_take: a stale lock with a bridge running is NOT taken over" || tbad "gl_take stale+bridge: $o"
WINB=0; GL_HELD=1; echo "pid=$$ boot=1 start=1" > "$GL/owner"; WSLP=1
o=$(gl_release; echo "rc=$?"); [ -f "$GL/owner" ] && grep -q 'KEPT' <<< "$o" && tok "gl_release: an orphan peer keeps the lock" || tbad "gl_release with an orphan: $o"
WSLP=0; gl_release; [ ! -e "$GL" ] && tok "gl_release: no orphan -> lock removed" || tbad "gl_release clean left $GL"

# ---- hex_ok / addr_ok
for f in hex_ok addr_ok; do s=$(fn "$REPO/scripts/node/prov-p2-central-254.sh" $f); [ -n "$s" ] || { tbad "$f not found"; exit 1; }; eval "$s"; done
for h in 030000 "0300$(printf '%064d' 0)"; do hex_ok "$h" && tok "hex_ok accepts [${h:0:12}…]" || tbad "hex_ok refused a good frame"; done
for h in "" 0 "03 00" "0A00" "03000x" "$(printf '%0490d' 0)" "$(printf '03\nremove 00')" "03;pair"; do
	hex_ok "$h" && tbad "hex_ok accepted [$h]" || tok "hex_ok refuses [$(printf '%s' "$h" | tr '\n' '~' | cut -c1-16)]"
done
addr_ok "AA:BB:CC:DD:EE:0F" && tok "addr_ok accepts a MAC" || tbad "addr_ok refused a MAC"
for a in "aa:bb:cc:dd:ee:ff" "AA:BB:CC:DD:EE" "AA:BB:CC:DD:EE:FF;remove" "$(printf 'AA:BB:CC:DD:EE:FF\nquit')" ""; do
	addr_ok "$a" && tbad "addr_ok accepted [$a]" || tok "addr_ok refuses [$(printf '%s' "$a" | tr '\n' '~')]"
done

# ---- judge_lines: the judge's lines reach the unit's counters (a pipe would run it in a subshell and lose them)
s=$(fn "$REPO/scripts/dv/prov-gatt-254.sh" judge_lines); [ -n "$s" ] || { tbad "judge_lines not found"; exit 1; }; eval "$s"
ok(){ :; }; no(){ fails=$((fails + 1)); }; inv(){ invalid=$((invalid + 1)); }; say(){ :; }
J=$'PASS gatt q1: a\nFAIL gatt q1: b\nINVALID gatt q1: c\nINFO gatt q1: central X\nVERDICT case=q1 FAIL'
fails=0; invalid=0; JV=""; judge_lines < <(printf '%s\n' "$J")
[ "$fails" = 1 ] && [ "$invalid" = 1 ] && [ "$JV" = FAIL ] && tok "judge_lines (as the unit calls it, < <(...)): 1 FAIL, 1 INVALID, verdict FAIL counted" || tbad "judge_lines counters fails=$fails invalid=$invalid JV=$JV"
fails=0; invalid=0; JV=""; printf '%s\n' "$J" | judge_lines
[ "$fails" = 0 ] && tok "negative control: the same lines through a pipe are lost (why the unit never pipes into judge_lines)" || tbad "a pipe kept the counters?"
grep -nE '\| *judge_lines' "$REPO/scripts/dv/prov-gatt-254.sh" | grep -q . && tbad "prov-gatt-254.sh pipes into judge_lines: $(grep -nE '\| *judge_lines' "$REPO/scripts/dv/prov-gatt-254.sh" | head -2)" || tok "prov-gatt-254.sh never pipes into judge_lines"

echo "gatt-judges: $pass passed, $bad failed"
[ "$bad" = 0 ]
