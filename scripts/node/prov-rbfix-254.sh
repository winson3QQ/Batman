#!/bin/sh
# scripts/node/prov-rbfix-254.sh <boot id at the arm's start (8 hex)> [run dir] — the recovery ONLY (254-h23 §23.2):
# the rollback arm is gone without a RESULT line and [all] != fw-part A. Run detached like the arm; writes its pid to
# <run dir>/rbfix.pid (P9 FAILs while it is alive) and exactly one RESULT= line:
#   INVALID <why>   not on A / rebooted since the arm started (then [all] decides what booted: no commit here — P9 and
#                   the recovery of §22.1 take over) / a batman-slot process is running (slot_lock) — nothing done
#   FIXED a=…       `/usr/sbin/batman-slot commit` (3 tries) put [all] back to fw-part A
#   FAIL a=…        it did not
# PRB_ROOT / PRB_BOOTID / PRB_PROC (tests only, never on a node): prefix the product paths / the boot_id file / /proc.
trap '' HUP PIPE
R=${PRB_ROOT:-}; D=${2:-$(dirname "$0")}; P=${PRB_PROC:-/proc}
echo $$ > "$D/rbfix.pid.tmp" && mv "$D/rbfix.pid.tmp" "$D/rbfix.pid"
r(){ echo "RESULT=$*"; exit 0; }
. "$R/usr/lib/batman/bootfacts.sh" || r "INVALID no bootfacts library"
BS=$R/usr/sbin/batman-slot
[ "$("$BS" active)" = A ] || r "INVALID not running on A"
b=$(cut -c1-8 "${PRB_BOOTID:-/proc/sys/kernel/random/boot_id}" 2>/dev/null)
[ -n "${1:-}" ] && [ "$b" = "$1" ] || r "INVALID rebooted since the arm started (boot $1 -> ${b:-unreadable}): no commit here"
for c in "$P"/[0-9]*/cmdline; do
	p=${c%/cmdline}; p=${p##*/}; [ "$p" = $$ ] && continue
	tr '\0' ' ' 2>/dev/null < "$c" | grep -q 'batman-slot' && r "INVALID a batman-slot process is running (pid $p) — its slot_lock"
done
fa=$("$BS" fw-part A)
i=0; while [ $i -lt 3 ]; do "$R/usr/sbin/batman-slot" commit >/dev/null 2>&1 && break; sleep 5; i=$((i + 1)); done
a=$(bf_ab_all)
[ "$a" = "$fa" ] && r "FIXED a=$a fw-part-A=$fa"
r "FAIL a=$a fw-part-A=$fa"
