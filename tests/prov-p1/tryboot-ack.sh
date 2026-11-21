#!/bin/bash
# tests/prov-p1/tryboot-ack.sh <batman-slot> <bootfacts.sh> — #254 L175 (docs/design/254-v16-group1.md §1): a tryboot
# GET (`vcmailbox 0x00030064 4 4 0`) counts only when the firmware handled the tag (word 5 = 0x80000004). Firmware that
# does not know the tag leaves word 5 = 4 and word 6 = the request's 0, which was read as "not armed".
# One table of answers runs through bf_get (the real bootfacts.sh) and through disarm_tryboot / arm_tryboot extracted
# from the real batman-slot, on layout pi4 and pi3 (pi3 must stay exactly as before: unsupported, P-U14), plus the
# "bootfacts.sh missing" case. No root, no node. A run that executes zero cases FAILs.
# Negative control: main 4b61b3c's pair -> FAIL on the pi4 unacknowledged rows (bf_get 0, disarm ok, arm "did not arm").
set -u
BS=$(readlink -f "${1:?usage: $0 <batman-slot> <bootfacts.sh>}"); BF=$(readlink -f "${2:?}")
[ -f "$BS" ] && [ -f "$BF" ] || { echo "FAIL missing $BS or $BF"; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; fails=0; cases=0
ok(){ echo "ok   $*"; }; no(){ echo "FAIL $*"; fails=$((fails+1)); }
mkdir -p "$T/lib" "$T/nolib" "$T/bin"; cp "$BF" "$T/lib/bootfacts.sh"; chmod 755 "$T/lib" "$T/nolib"
# vcmailbox stub: the GET prints $ANS; the SET prints nothing
cat > "$T/bin/vcmailbox" <<'STUB'
#!/bin/sh
[ "$1" = 0x00030064 ] && [ -n "${ANS:-}" ] && echo "$ANS"
exit 0
STUB
chmod 755 "$T/bin/vcmailbox"
fx(){ awk -v f="$1" '$0 ~ "^"f"\\(\\) *\\{" {p=1} p {print} p && /^\}/ {exit}' "$BS"; }
for f in disarm_tryboot arm_tryboot; do [ -n "$(fx $f)" ] || { no "$f() missing from $BS"; echo "TRYBOOT-ACK cases=0 fails=1"; exit 1; }; done
# the library loader as batman-slot defines it (BATLIB from BATMAN_LIB, bf_lib); absent on an old batman-slot
loader=$(sed -n '/^BATLIB=/,/^bf_lib()/p' "$BS")   # BATLIB=, lib_ok(), the BATMAN_LIB check, bf_lib()
# run <what: get|disarm|arm> <layout> <lib dir> -> one line: the result / DIE msg / WARN msg + "ARMED"/"CLEARED"
run(){
	(
		export PATH="$T/bin:$PATH" BATMAN_LIB="$3" RUNDIR="$T/run"; mkdir -p "$T/run"
		die(){ echo "DIE $*" >&2; exit 1; }; warn(){ echo "WARN $*" >&2; }
		st(){ :; }; otalog_k(){ :; }; fault(){ return 1; }; ota_thr(){ :; }; fw_part(){ :; }; ab_section(){ :; }; sync(){ :; }
		layout(){ echo "$L"; }; L=$2; T=B
		if [ "$1" = get ]; then . "$3/bootfacts.sh" 2>/dev/null; type bf_get >/dev/null 2>&1 || { echo "NOLIB"; exit 0; }; bf_get; exit 0; fi
		eval "$loader"
		eval "$(fx disarm_tryboot)"; eval "$(fx arm_tryboot)"
		if [ "$1" = disarm ]; then disarm_tryboot && echo CLEARED; else arm_tryboot >/dev/null && echo ARMED; fi
	) 2>&1 | tr '\n' ' ' | sed 's/ *$//'
}
# check <label> <what> <layout> <lib> <ANS> <ERE the result must match>
check(){
	local o; cases=$((cases+1)); o=$(ANS="$5" run "$2" "$3" "$4")
	if grep -qE "$6" <<< "$o"; then ok "$1: [$o]"; else no "$1: [$o] does not match /$6/"; fi
}
A1='12 0x80000000 0x00030064 4 0x80000004 0x00000001 0x00000000'
A0='12 0x80000000 0x00030064 4 0x80000004 0x00000000 0x00000000'
UN='12 0x80000000 0x00030064 4 0x00000004 0x00000000 0x00000000'
BAD='12 0x80000001 0x00030064 4 0x00000004 0x00000000 0x00000000'
L="$T/lib"
# bf_get (layout-independent; its callers act on a Pi 4 only)
check "bf_get answered 1"       get pi4 "$L" "$A1" '^1$'
check "bf_get answered 0"       get pi4 "$L" "$A0" '^0$'
check "bf_get unacknowledged"   get pi4 "$L" "$UN" '^unknown$'
check "bf_get code not ok"      get pi4 "$L" "$BAD" '^unknown$'
check "bf_get empty"            get pi4 "$L" "" '^unknown$'
# pi4 disarm
check "pi4 disarm answered 0"   disarm pi4 "$L" "$A0" '^CLEARED$'
check "pi4 disarm answered 1"   disarm pi4 "$L" "$A1" '^DIE tryboot flag still armed'
check "pi4 disarm unacked"      disarm pi4 "$L" "$UN" '^WARN tryboot GET not handled .*cleared blind CLEARED$'
check "pi4 disarm code not ok"  disarm pi4 "$L" "$BAD" '^WARN cannot read the tryboot flag back.*cleared blind CLEARED$'
check "pi4 disarm no lib"       disarm pi4 "$T/nolib" "$A0" '^WARN bootfacts.sh missing.*cleared blind CLEARED$'
# pi4 arm
check "pi4 arm answered 1"      arm pi4 "$L" "$A1" '^ARMED$'
check "pi4 arm answered 0"      arm pi4 "$L" "$A0" '^DIE tryboot flag did not arm \(GET returned 0x00000000\)'
check "pi4 arm unacked"         arm pi4 "$L" "$UN" '^DIE tryboot GET not handled by this firmware'
check "pi4 arm code not ok"     arm pi4 "$L" "$BAD" '^WARN cannot read the tryboot flag back.*armed blind as before ARMED$'
check "pi4 arm no lib"          arm pi4 "$T/nolib" "$A1" '^DIE bootfacts.sh missing'
# pi3: exactly as before (word 5 not looked at; no library needed)
check "pi3 disarm unacked"      disarm pi3 "$T/nolib" "$UN" '^CLEARED$'
check "pi3 disarm code not ok"  disarm pi3 "$T/nolib" "$BAD" '^DIE cannot read the tryboot flag back'
check "pi3 arm answered 1"      arm pi3 "$T/nolib" "$A1" '^ARMED$'
check "pi3 arm unacked"         arm pi3 "$T/nolib" "$UN" '^DIE tryboot flag did not arm \(GET returned 0x00000000\)'
check "pi3 arm code not ok"     arm pi3 "$T/nolib" "$BAD" '^DIE cannot read the tryboot flag back'
# BATMAN_LIB is honoured only for a directory writable by nobody else: a group-writable one falls back to the default
chmod 775 "$T/lib"; cases=$((cases+1))
o=$(BATMAN_LIB="$T/lib" sh -c "$loader"'; echo "$BATLIB"')
[ "$o" = /usr/lib/batman ] && ok "BATMAN_LIB group-writable -> ignored ($o)" || no "BATMAN_LIB group-writable honoured ($o)"
chmod 755 "$T/lib"
# … and so is a directory whose bootfacts.sh is group-writable (the sourced file is checked too; code review A m7 / B m6)
chmod 664 "$T/lib/bootfacts.sh"; cases=$((cases+1))
o=$(BATMAN_LIB="$T/lib" sh -c "$loader"'; echo "$BATLIB"')
[ "$o" = /usr/lib/batman ] && ok "BATMAN_LIB with a group-writable bootfacts.sh -> ignored ($o)" || no "BATMAN_LIB with a group-writable bootfacts.sh honoured ($o)"
chmod 644 "$T/lib/bootfacts.sh"
echo "TRYBOOT-ACK cases=$cases fails=$fails"
[ $cases -gt 0 ] && [ $fails = 0 ]
