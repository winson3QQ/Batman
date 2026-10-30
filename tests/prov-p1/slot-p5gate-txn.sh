#!/bin/bash
# tests/prov-p1/slot-p5gate-txn.sh <batman-slot> — #254 wireless-txn §15.3: batman-slot's OTA freshness gate refuses
# while an unfinished network change (.txn) exists, with its own message, and the stale-p5 override does NOT pass it
# (an OTA would drop the per-slot .txn: the new slot's wireless would never be reconciled with the record). An ordinary
# stale key still dies and still honours the override (control). p5_freshness_gate is extracted from the product file
# and run under busybox ash with die / warn / allowed / p5_verdict_write and batman-config-save stubbed.
# Negative control: the shipped batman-slot says "STALE … (an)" and lets the override through -> FAIL. Zero cases = FAIL.
# Code review 2: the same holds in STAGE 2 (the sysupgrade ramfs / -F path reads the stage-1 verdict through
# p5_verdict_gate: stale:txn is never passed by allow-stale-p5 there either), and one deliberate override exists for a
# node whose HaLow is dead: allow-unfinished-txn passes in both stages with the "DROPPED in the new slot" warning.
set -u
SL=$(readlink -f "${1:?usage: $0 <batman-slot>}")
cases=0; fails=0
ok(){ cases=$((cases + 1)); echo "ok   $*"; }; bad(){ cases=$((cases + 1)); fails=$((fails + 1)); echo "FAIL $*"; }
command -v busybox >/dev/null || { echo "FAIL busybox missing"; echo "SLOT-P5GATE-TXN cases=0 fails=1"; exit 1; }
[ -s "$SL" ] || { echo "FAIL no product file [$SL]"; echo "SLOT-P5GATE-TXN cases=0 fails=1"; exit 1; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fn=$(awk '/^p5_freshness_gate\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$SL")
[ -n "$fn" ] || { echo "FAIL p5_freshness_gate not found in $SL"; echo "SLOT-P5GATE-TXN cases=0 fails=1"; exit 1; }
mkdir -p "$W/bin"
# run <config-save --check output> <rc> <allowed names, e.g. "STALE_P5 UNFINISHED_TXN"> -> "rc=<n> verdict=<v> out=<last line>"
run(){
	printf '#!/bin/sh\nprintf "%%s\\n" "%s"\nexit %s\n' "$1" "$2" > "$W/bin/batman-config-save"; chmod +x "$W/bin/batman-config-save"
	cat > "$W/t.sh" <<EOF
die(){ echo "DIE: \$*"; exit 1; }
warn(){ echo "WARN: \$*"; }
allowed(){ case " $3 " in *" \$1 "*) return 0 ;; esac; return 1; }
p5_verdict_write(){ echo "\$1" > "$W/verdict"; }
P5_STALE_HINT="(hint)"; RUNDIR=$W
$(grep -E '^P5_(TXN_OVERRIDE_HINT|TXN_DROP_WARN)=' "$SL")
$fn
p5_freshness_gate; echo "PASSED-GATE"
EOF
	: > "$W/verdict"
	o=$(PATH="$W/bin:$PATH" busybox ash "$W/t.sh" 2>&1); r=$?
	echo "rc=$r verdict=$(cat "$W/verdict") out=$(printf '%s\n' "$o" | tail -1)"
}
touch "$W/wireless"   # the gate reads /etc/config/wireless only for -r; the real one exists on the host or not:
[ -r /etc/config/wireless ] || sed_note="(stage 1 reached through a test copy of /etc/config/wireless)"
TXN="batman-config-save: p5 stale: an unfinished network change (.txn) — the helper finishes it"
if [ ! -r /etc/config/wireless ]; then
	# the stage-1 branch needs a readable /etc/config/wireless; run the extracted function with the path rewritten
	fn=$(printf '%s\n' "$fn" | sed "s#/etc/config/wireless#$W/wireless#")
fi
r=$(run "$TXN" 5 ""); case "$r" in "rc=1 verdict=stale:txn out=DIE: an unfinished network change"*) ok ".txn: refused with its own message [$r]" ;; *) bad ".txn: [$r]" ;; esac
r=$(run "$TXN" 5 STALE_P5); case "$r" in "rc=1 verdict=stale:txn out=DIE: an unfinished network change"*) ok ".txn + stale override: still refused [$r]" ;; *) bad ".txn + override let through: [$r]" ;; esac
S5="batman-config-save: p5 stale: wireless.radio1.channel"
r=$(run "$S5" 5 ""); case "$r" in "rc=1 verdict=stale:wireless.radio1.channel out=DIE: p5 (config) is STALE"*) ok "control: an ordinary stale key dies [$r]" ;; *) bad "control stale: [$r]" ;; esac
r=$(run "$S5" 5 STALE_P5); case "$r" in "rc=0 verdict=stale-allowed out=PASSED-GATE"*) ok "control: the override still works for an ordinary stale key [$r]" ;; *) bad "control override: [$r]" ;; esac
r=$(run "batman-config-save: p5 fresh" 0 ""); case "$r" in "rc=0 verdict=fresh out=PASSED-GATE"*) ok "control: fresh passes [$r]" ;; *) bad "control fresh: [$r]" ;; esac
# stage 1: the dedicated override
r=$(run "$TXN" 5 UNFINISHED_TXN); case "$r" in "rc=0 verdict=txn-allowed out=PASSED-GATE"*) ok "stage 1: .txn + allow-unfinished-txn passes [$r]" ;; *) bad "stage 1 allow-unfinished-txn: [$r]" ;; esac
o=$(PATH="$W/bin:$PATH" busybox ash "$W/t.sh" 2>&1)
case "$o" in *"WARN: OVERRIDE allow-unfinished-txn: the unfinished network change (.txn) is DROPPED in the new slot — re-push the network from the app after the OTA"*) ok "stage 1: allow-unfinished-txn warns loudly" ;; *) bad "stage 1 override warning missing: $(printf '%s' "$o" | head -2 | tr '\n' ' ')" ;; esac
r=$(run "$S5" 5 UNFINISHED_TXN); case "$r" in "rc=1 verdict=stale:wireless.radio1.channel out=DIE: p5 (config) is STALE"*) ok "control: allow-unfinished-txn does not pass an ordinary stale key [$r]" ;; *) bad "allow-unfinished-txn passed an ordinary stale key: [$r]" ;; esac

# ---- stage 2: the verdict written by stage 1 decides (no batman-config-save / wireless in the ramfs) ----------------------
vg=$(awk '/^p5_verdict_gate\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$SL")
fn2=$(awk '/^p5_freshness_gate\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$SL" | sed "s#/etc/config/wireless#$W/no-wireless#")
consts=$(grep -E '^P5_(TXN_OVERRIDE_HINT|TXN_DROP_WARN)=' "$SL")
[ -n "$vg" ] || bad "p5_verdict_gate not found"
# run2 <verdict> <allowed names> -> "rc=<n> out=<last line>"
run2(){
	mkdir -p "$W/rd"; chmod 700 "$W/rd"
	echo "$1 $(cut -d. -f1 /proc/uptime)" > "$W/rd/p5-check.rc"
	cat > "$W/t2.sh" <<EOF
die(){ echo "DIE: \$*"; exit 1; }
warn(){ echo "WARN: \$*"; }
otalog_k(){ :; }
allowed(){ case " $2 " in *" \$1 "*) return 0 ;; esac; return 1; }
P5_STALE_HINT="(hint)"; RUNDIR=$W/rd; P5VERDICT=$W/rd/p5-check.rc; P5VERDICT_MAX_AGE=600
$consts
$vg
$fn2
p5_freshness_gate; echo "PASSED-GATE"
EOF
	o=$(PATH="/usr/bin:/bin" busybox ash "$W/t2.sh" 2>&1); r=$?
	echo "rc=$r out=$(printf '%s\n' "$o" | tail -1)"
}
r=$(run2 stale:txn ""); case "$r" in "rc=1 out=DIE: an unfinished network change"*) ok "stage 2: stale:txn refused [$r]" ;; *) bad "stage 2 stale:txn: [$r]" ;; esac
r=$(run2 stale:txn STALE_P5); case "$r" in "rc=1 out=DIE: an unfinished network change"*) ok "stage 2: stale:txn + allow-stale-p5 still refused [$r]" ;; *) bad "stage 2: allow-stale-p5 let stale:txn through: [$r]" ;; esac
run2 stale:txn UNFINISHED_TXN >/dev/null; r=$(run2 stale:txn UNFINISHED_TXN)
case "$r" in "rc=0 out=PASSED-GATE"*) ok "stage 2: stale:txn + allow-unfinished-txn passes [$r]" ;; *) bad "stage 2 allow-unfinished-txn: [$r]" ;; esac
o=$(PATH="/usr/bin:/bin" busybox ash "$W/t2.sh" 2>&1)
case "$o" in *"WARN: OVERRIDE allow-unfinished-txn: the unfinished network change (.txn) is DROPPED in the new slot"*) ok "stage 2: allow-unfinished-txn warns loudly" ;; *) bad "stage 2 override warning missing: $(printf '%s' "$o" | head -2 | tr '\n' ' ')" ;; esac
r=$(run2 stale:wireless.radio1.channel STALE_P5); case "$r" in "rc=0 out=PASSED-GATE"*) ok "control: stage 2 allow-stale-p5 still passes an ordinary stale key [$r]" ;; *) bad "control stage 2 override: [$r]" ;; esac
r=$(run2 stale:wireless.radio1.channel UNFINISHED_TXN); case "$r" in "rc=1 out=DIE: p5 (config) is STALE"*) ok "control: stage 2 allow-unfinished-txn does not pass an ordinary stale key [$r]" ;; *) bad "stage 2 allow-unfinished-txn passed stale: [$r]" ;; esac
r=$(run2 fresh ""); case "$r" in "rc=0 out=PASSED-GATE"*) ok "control: stage 2 fresh passes [$r]" ;; *) bad "control stage 2 fresh: [$r]" ;; esac
echo "SLOT-P5GATE-TXN cases=$cases fails=$fails ${sed_note:-}"
[ "$cases" -gt 0 ] && [ "$fails" = 0 ]
