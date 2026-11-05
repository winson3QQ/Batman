#!/bin/bash
# tests/judges/h3-judges.sh — negative controls for the H3 review fixes (#254), run on the host with the REAL functions
# cut out of the unit files and their node calls stubbed: each case breaks one property and wants the check to say so.
#   pr_release (scripts/dv/prov-254.sh): NEEDS-PERSON makes no radio / provd write; a failed lease release FAILs; this
#     run's deadman lines beyond PR_DM_BASE FAIL (round 1 A-M1/A-M2/B-M3, round 2 A)
#   pxok (scripts/dv/prov-provd-wbox-254.sh): a failed connect / ssh is never "closed at once" (round 1 B-M1)
#   the L71 flip block (scripts/dv/prov-netjoin-254.sh): a judge with no end line FAILs (round 1 B-M6)
#   bond_verdict (scripts/dv/ble-254.sh): 04's DHKeyCheck = accepted, also when a PairingFailed follows
# Prints "ok"/"FAIL" per case and "h3-judges: <n> passed, <m> failed"; exit 1 on any failure.
set -u
REPO=${REPO:-$(cd "$(dirname "$0")/../.." && pwd)}
pass=0; bad=0
tok(){ echo "ok   $*"; pass=$((pass + 1)); }; tbad(){ echo "FAIL $*"; bad=$((bad + 1)); }
# <file> <name>: one function's text — a one-line function ends on its own line; nothing else is ever printed (an
# extraction that ran on would eval the rest of a unit file)
fn(){ awk -v n="$2" '!p && $0 ~ "^"n"\\(\\)" {p=1; print; if ($0 ~ /; }[[:space:]]*(#.*)?$/) exit; next} p {print} p && /^}/ {exit}' "$1"; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT

# ---- pr_release with every node call stubbed (calls logged to $W/calls)
src=$(fn "$REPO/scripts/dv/prov-254.sh" pr_release); [ -n "$src" ] || { tbad "pr_release not found"; exit 1; }
rel(){	# <PR_PERSON> <release answer> <deadman count> <PR_DM_BASE>: run pr_release, print its lines
	( RUN=r1 PR_UNIT=t PCD=/x PR_PAY=/y PR_PERSON=$1 PR_DM_BASE=$4 fails=0
	  say(){ echo "SAY $*"; }; ok(){ echo "PASS $*"; }; no(){ echo "FAIL $*"; }; pr_unlock(){ :; }
	  pw(){ echo "pw $*" >> "$W/calls"; echo "UNBIND-ALL ok"; }
	  q(){ echo "q $*" >> "$W/calls"; }
	  pl(){ echo "pl $*" >> "$W/calls"; case "$1" in release) echo "$RELA" ;; renew) echo "ARMED $2 s" ;; undo) echo "${UNDOA:-UNDO undo_run host end rc=0}" ;; radio-restore) echo "RADIO clean" ;; provd-reset) echo "PROVD ok pid=1" ;; *) echo "STATE x" ;; esac; }
	  qr(){ echo "$DMN"; }
	  RELA=$2 DMN=$3; eval "$src"; pr_release )
}
: > "$W/calls"; o=$(rel 0 RELEASED 0 0)
grep -q '^pl radio-restore' "$W/calls" && grep -q '^pl provd-reset' "$W/calls" && ! grep -q '^FAIL' <<< "$o" \
	&& tok "pr_release (control): a normal end restores radio + provd, releases, no FAIL" || tbad "pr_release control: [$(echo $o)] calls [$(tr '\n' '|' < "$W/calls")]"
: > "$W/calls"; o=$(rel 1 RELEASED 0 0)
! grep -qE '^pl (radio-restore|provd-reset|renew|undo)|^q rm' "$W/calls" && grep -q '^pl release' "$W/calls" && grep -q '^pw unbind-all' "$W/calls" \
	&& tok "pr_release NEEDS-PERSON: no radio / provd / rm write, binds and lease go" || tbad "pr_release NEEDS-PERSON calls: [$(tr '\n' '|' < "$W/calls")]"
# 254-h4 §5.7: the host-mode undo runs under a renewed lease; something it left is a FAIL
: > "$W/calls"; o=$(rel 0 RELEASED 0 0)
grep -q '^pl renew 1200' "$W/calls" && grep -q '^pl undo$' "$W/calls" && tok "pr_release: renew + host-mode undo before the release" || tbad "pr_release undo calls: [$(tr '\n' '|' < "$W/calls")]"
o=$(UNDOA='UNDO FAIL 2 link-del h4v0 (rc 1)' rel 0 RELEASED 0 0); grep -q '^FAIL undo: UNDO FAIL 2 link-del' <<< "$o" && tok "pr_release: an undo that left something FAILs" || tbad "pr_release with a failed undo: [$(echo $o)]"
o=$(UNDOA=$'UNDO seg1 rm /tmp/batman-fault.x undo_run host end rc=0\nUNDO FAIL 2 link-del h4v0 (rc 1)\nUNDO undo_run host end rc=1' rel 0 RELEASED 0 0); grep -q '^FAIL undo: UNDO FAIL 2 link-del' <<< "$o" && tok "pr_release: an end line inside another line is not the end line" || tbad "pr_release with a forged end line: [$(echo $o)]"
o=$(rel 0 "FAIL lease is not ours or expired" 0 0)
grep -q '^FAIL lease release failed' <<< "$o" && tok "pr_release: a failed lease release FAILs" || tbad "pr_release with a failed release: [$(echo $o)]"
o=$(rel 0 RELEASED 2 0); grep -q '^FAIL the prov deadman acted' <<< "$o" && tok "pr_release: 2 deadman lines, none expected -> FAIL" || tbad "deadman lines not caught: [$(echo $o)]"
o=$(rel 0 RELEASED 2 2); grep -q '^FAIL the prov deadman acted' <<< "$o" && tbad "deadman lines all expected (PR_DM_BASE=2) still FAILed" || tok "pr_release: deadman lines up to PR_DM_BASE are expected"
o=$(rel 0 RELEASED 3 2); grep -q '^FAIL the prov deadman acted' <<< "$o" && tok "pr_release: one deadman line beyond PR_DM_BASE -> FAIL" || tbad "a deadman line after the expected ones not caught: [$(echo $o)]"

# ---- pxok: proxy.go prints "CONN-ERR <err>" and exits 3 when the dial fails; the PXR wrapper adds "T=<ms>ms rc=<rc>"
pxsrc=$(fn "$REPO/scripts/dv/prov-provd-wbox-254.sh" pxok); [ "$(grep -c . <<< "$pxsrc")" = 1 ] || { tbad "pxok extraction gave $(grep -c . <<< "$pxsrc") lines"; exit 1; }; eval "$pxsrc"
pxok "$(printf 'T=9ms rc=0')" && tok "pxok (control): a connection provd closed" || tbad "pxok rejects a clean close"
pxok "$(printf 'CONN-ERR dial unixpacket /nonexistent/gatt.sock: connect: no such file or directory\nT=5ms rc=3')" && tbad "pxok accepts a failed connect" || tok "pxok: a failed connect (CONN-ERR, rc 3) is not a measurement"
pxok "" && tbad "pxok accepts an empty answer (ssh failed)" || tok "pxok: no output at all (ssh failed) is not a measurement"
pxok "$(printf 'T=7ms rc=255')" && tbad "pxok accepts rc 255" || tok "pxok: rc 255 (ssh error) is not a measurement"

# ---- the L71 flip block: the lines from `if inwin flip` to its `fi`, with inwin / ok / no stubbed
blk=$(awk '/if inwin flip; then/ {p=1} p {print} p && /fi$/ {exit}' "$REPO/scripts/dv/prov-netjoin-254.sh")
[ -n "$blk" ] || tbad "the L71 flip block was not found"
flip(){ ( inwin(){ return 0; }; ok(){ echo "PASS $*"; }; no(){ echo "FAIL $*"; }; o=$1; eval "$blk" ); }
o=$(flip "$(printf 'PASS bondable on: withdrawn\nPROV-P2 flip fails=0')"); ! grep -q '^FAIL' <<< "$o" && tok "L71 flip (control): a finished judge, no FAIL" || tbad "L71 flip control: [$(echo $o)]"
o=$(flip "$(printf 'PASS bondable on: withdrawn')"); grep -q 'judge did not finish' <<< "$o" && tok "L71 flip: a judge cut off (no end line) FAILs" || tbad "L71 flip without the end line: [$(echo $o)]"

# ---- bond_verdict
eval "$(fn "$REPO/scripts/dv/ble-254.sh" bond_verdict)"
v=$(bond_verdict a "$(printf 'ROUND a pair-result: failed\na 04 SMP TX PairingDHKeyCheck\na 04 SMP TX PairingFailed reason=0x0b')")
[ "$v" = accepted ] && tok "bond_verdict: DHKeyCheck then PairingFailed = accepted" || tbad "bond_verdict DHKeyCheck+Failed: $v"
v=$(bond_verdict a "$(printf 'ROUND a pair-result: Pairing with X failed. status 0x05\na 04 SMP TX PairingFailed reason=0x0c')")
[ "$v" = refused:0x0c ] && tok "bond_verdict: PairingFailed only = refused:0x0c" || tbad "bond_verdict refused: $v"

echo "h3-judges: $pass passed, $bad failed"
[ $bad = 0 ]
