#!/bin/sh
# scripts/node/prov-rbarm-254.sh <wbox version> [run dir] — the rollback arm of prov-wbox-nocommit-254
# (docs/design/254-h23-harness.md §20.3, §22.1, §23.1, §23.2). Started DETACHED by scripts/node/prov-rbarm-launch-254.sh
# (`trap '' HUP PIPE; setsid sh … &`) so the ssh session dying cannot cut it between the rollback and its recovery.
# It writes its own pid to <run dir>/rbarm.pid first (preflight P9 FAILs while it is alive), sleeps PRB_SLEEP (10) s so
# the harness can kill the ssh session inside that window (§23.1), and prints T lines (node uptime) and exactly one
# RESULT= line:
#   INVALID <why>          a precondition failed — no rollback done: pre-gate image, not A, A not committed, [all] !=
#                          fw-part A, B not the wbox, vcgencmd missing / unreadable / under-voltage, batpower CRIT
#   PASS …                 rollback refused with "holds a -wbox test image", [all] unchanged
#   FAIL-RECOVERED …       the rollback was accepted or [all] moved (gate regression) — `batman-slot commit` on A put
#                          [all] back; omd=ok|down = openmanetd running within PRB_OMD_WAIT (30) s after the recovery
#   FAIL-NEEDS-PERSON …    … and [all] could not be put back (no reboot is done)
#   INVALID rc=… msg=…     refused for another reason (build stamp unreadable, lock gate, power …)
# PRB_ROOT / PRB_STATE (tests only, never on a node): prefix the product paths / the p6 state dir.
trap '' HUP PIPE
R=${PRB_ROOT:-}; ST=${PRB_STATE:-/opt/batdata/state}; D=${2:-$(dirname "$0")}
echo $$ > "$D/rbarm.pid.tmp" && mv "$D/rbarm.pid.tmp" "$D/rbarm.pid"
up(){ cut -d' ' -f1 /proc/uptime; }
echo "T start=$(up)"
sleep "${PRB_SLEEP:-10}"
echo "T awake=$(up)"
r(){ echo "RESULT=$*"; exit 0; }
. "$R/usr/lib/batman/bootfacts.sh" || r "INVALID no bootfacts library"
. "$R/usr/lib/batman/rundir.sh" 2>/dev/null || r "INVALID no rundir library"
BS=$R/usr/sbin/batman-slot
tb(){ sed -n '/^\[tryboot\]/,/^\[/s/^boot_partition=//p' "${PRB_BOOT:-/boot}/autoboot.txt" 2>/dev/null | head -n 1; }
grep -q 'holds a -wbox test image' "$BS" || r "INVALID pre-gate image"
[ "$("$BS" active)" = A ] || r "INVALID not running on A"
"$BS" is-trial >/dev/null 2>&1; [ $? = 1 ] || r "INVALID A is not committed (is-trial rc != 1)"
fa=$("$BS" fw-part A); a0=$(bf_ab_all)
case "$fa" in 1|2) ;; *) r "INVALID fw-part A [$fa]" ;; esac
[ "$a0" = "$fa" ] || r "INVALID bf_ab_all [$a0] != fw-part A [$fa]"
[ "$(cat "$ST/slot-B.protected" 2>/dev/null)" = "${1:-}" ] || r "INVALID slot-B.protected [$(cat "$ST/slot-B.protected" 2>/dev/null)] != ${1:-}"
# the supply, by batman-slot's own rule (power_ok is internal, :280-300): 3 samples, bit 0; unknown = INVALID (fail-closed)
command -v vcgencmd >/dev/null 2>&1 || r "INVALID vcgencmd missing — supply unknown"
n=0; while [ $n -lt 3 ]; do
	t=$(vcgencmd get_throttled 2>/dev/null | sed -n 's/.*=0x//p')
	case "$t" in ''|*[!0-9a-fA-F]*) r "INVALID get_throttled unreadable [$t]" ;; esac
	[ $(( 0x$t & 0x1 )) -eq 0 ] || r "INVALID under-voltage now (throttled=0x$t)"
	n=$((n + 1)); [ $n -lt 3 ] && sleep 1
done
if [ -r "$RUNDIR/batpower.state" ] && "$R/etc/init.d/batpower" running >/dev/null 2>&1; then
	[ "$(cut -d' ' -f1 "$RUNDIR/batpower.state")" = CRIT ] && r "INVALID batpower reports CRIT (write_autoboot would die and hide a regression)"
fi
t0=$(tb)
echo "T rollback=$(up)"
o=$("$BS" rollback 2>&1); rc=$?
echo "T rolled=$(up)"
a1=$(bf_ab_all); t1=$(tb)
# the recovery check comes FIRST: an accepted rollback, or a moved [all] even with rc != 0 (write_autoboot writes, then
# reads back — a failure after the write lands here, v11 A-m4)
if [ "$rc" = 0 ] || [ "$a1" != "$a0" ]; then
	i=0; while [ $i -lt 3 ]; do "$R/usr/sbin/batman-slot" commit >/dev/null 2>&1 && break; sleep 5; i=$((i + 1)); done
	a2=$(bf_ab_all)
	if [ "$a2" = "$fa" ]; then
		# addr_defer_release restarts openmanetd in the background after a commit (batman-slot :754-768)
		w=0; omd=down; while [ $w -lt "${PRB_OMD_WAIT:-30}" ]; do "$R/etc/init.d/openmanetd" running >/dev/null 2>&1 && { omd=ok; break; }; sleep 1; w=$((w + 1)); done
		r "FAIL-RECOVERED rc=$rc a0=$a0 a1=$a1 a2=$a2 tryboot=$t0>$t1 omd=$omd out=$(echo "$o" | tail -1)"
	fi
	r "FAIL-NEEDS-PERSON rc=$rc a0=$a0 a1=$a1 a2=$a2 tryboot=$t0>$t1 — [all] points at the wbox slot: rule out power first, then on A: /usr/sbin/batman-slot commit; do NOT reboot before that"
fi
case "$o" in *"holds a -wbox test image"*) r "PASS rc=$rc a0=$a0 a1=$a1 tryboot=$t0>$t1 msg=$(echo "$o" | tail -1)" ;; esac
r "INVALID rc=$rc msg=$(echo "$o" | tail -1)"
