#!/bin/sh
# scripts/node/prov-rbarm-254.sh <wbox version> — the rollback arm of prov-wbox-nocommit-254 (docs/design/254-h23-harness.md
# §20.3, §21.1), run DETACHED on the node (setsid, HUP/PIPE ignored) so an ssh drop cannot cut it between the rollback and
# its recovery. Prints exactly one RESULT= line:
#   INVALID <why>          a precondition failed (pre-gate image, B not the wbox, [all] not 1|2, not on A) — no rollback done
#   PASS …                 rollback refused with "holds a -wbox test image", [all] unchanged
#   FAIL-RECOVERED …       the rollback was accepted or [all] moved (gate regression) — `batman-slot commit` on A put [all] back
#   FAIL-NEEDS-PERSON …    … and [all] could not be put back (no reboot is done)
#   INVALID rc=… msg=…     refused for another reason (build stamp unreadable, lock gate, power …)
# PRB_ROOT / PRB_STATE (tests only, never on a node): prefix /usr/sbin/batman-slot and the bootfacts library / the p6 state dir.
trap '' HUP PIPE
R=${PRB_ROOT:-}; ST=${PRB_STATE:-/opt/batdata/state}
. "$R/usr/lib/batman/bootfacts.sh" || { echo "RESULT=INVALID no bootfacts library"; exit 0; }
r(){ echo "RESULT=$*"; exit 0; }
BS=$R/usr/sbin/batman-slot
grep -q 'holds a -wbox test image' "$BS" || r "INVALID pre-gate image"
[ "$(cat "$ST/slot-B.protected" 2>/dev/null)" = "${1:-}" ] || r "INVALID slot-B.protected [$(cat "$ST/slot-B.protected" 2>/dev/null)] != ${1:-}"
a0=$(bf_ab_all); case "$a0" in 1|2) ;; *) r "INVALID bf_ab_all [$a0]" ;; esac
[ "$("$BS" active)" = A ] || r "INVALID not running on A"
o=$("$BS" rollback 2>&1); rc=$?
a1=$(bf_ab_all)
# the recovery check comes FIRST: an accepted rollback, or a moved [all] even with rc != 0 (write_autoboot writes, then
# reads back — a failure after the write lands here, v11 A-m4)
if [ "$rc" = 0 ] || [ "$a1" != "$a0" ]; then
	i=0; while [ $i -lt 3 ]; do "$BS" commit >/dev/null 2>&1 && break; sleep 5; i=$((i + 1)); done
	a2=$(bf_ab_all)
	[ "$a2" = "$a0" ] && r "FAIL-RECOVERED rc=$rc a0=$a0 a1=$a1 a2=$a2 out=$(echo "$o" | tail -1)"
	r "FAIL-NEEDS-PERSON rc=$rc a0=$a0 a1=$a1 a2=$a2"
fi
case "$o" in *"holds a -wbox test image"*) r "PASS rc=$rc a0=$a0 a1=$a1 msg=$(echo "$o" | tail -1)" ;; esac
r "INVALID rc=$rc msg=$(echo "$o" | tail -1)"
