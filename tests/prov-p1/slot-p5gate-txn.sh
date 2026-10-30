#!/bin/bash
# tests/prov-p1/slot-p5gate-txn.sh <batman-slot> — #254 wireless-txn §15.3: batman-slot's OTA freshness gate refuses
# while an unfinished network change (.txn) exists, with its own message, and the stale-p5 override does NOT pass it
# (an OTA would drop the per-slot .txn: the new slot's wireless would never be reconciled with the record). An ordinary
# stale key still dies and still honours the override (control). p5_freshness_gate is extracted from the product file
# and run under busybox ash with die / warn / allowed / p5_verdict_write and batman-config-save stubbed.
# Negative control: the shipped batman-slot says "STALE … (an)" and lets the override through -> FAIL. Zero cases = FAIL.
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
# run <config-save --check output> <rc> <allow 0|1> -> "rc=<n> verdict=<v> out=<last line>"
run(){
	printf '#!/bin/sh\nprintf "%%s\\n" "%s"\nexit %s\n' "$1" "$2" > "$W/bin/batman-config-save"; chmod +x "$W/bin/batman-config-save"
	cat > "$W/t.sh" <<EOF
die(){ echo "DIE: \$*"; exit 1; }
warn(){ echo "WARN: \$*"; }
allowed(){ [ "$3" = 1 ]; }
p5_verdict_write(){ echo "\$1" > "$W/verdict"; }
P5_STALE_HINT="(hint)"; RUNDIR=$W
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
r=$(run "$TXN" 5 0); case "$r" in "rc=1 verdict=stale:txn out=DIE: an unfinished network change"*) ok ".txn: refused with its own message [$r]" ;; *) bad ".txn: [$r]" ;; esac
r=$(run "$TXN" 5 1); case "$r" in "rc=1 verdict=stale:txn out=DIE: an unfinished network change"*) ok ".txn + stale override: still refused [$r]" ;; *) bad ".txn + override let through: [$r]" ;; esac
S5="batman-config-save: p5 stale: wireless.radio1.channel"
r=$(run "$S5" 5 0); case "$r" in "rc=1 verdict=stale:wireless.radio1.channel out=DIE: p5 (config) is STALE"*) ok "control: an ordinary stale key dies [$r]" ;; *) bad "control stale: [$r]" ;; esac
r=$(run "$S5" 5 1); case "$r" in "rc=0 verdict=stale-allowed out=PASSED-GATE"*) ok "control: the override still works for an ordinary stale key [$r]" ;; *) bad "control override: [$r]" ;; esac
r=$(run "batman-config-save: p5 fresh" 0 0); case "$r" in "rc=0 verdict=fresh out=PASSED-GATE"*) ok "control: fresh passes [$r]" ;; *) bad "control fresh: [$r]" ;; esac
echo "SLOT-P5GATE-TXN cases=$cases fails=$fails ${sed_note:-}"
[ "$cases" -gt 0 ] && [ "$fails" = 0 ]
