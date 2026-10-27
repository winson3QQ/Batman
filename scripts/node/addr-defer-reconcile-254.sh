#!/bin/sh
# scripts/node/addr-defer-reconcile-254.sh — #254 B-M4 (254-p1-impl.md §13.8.2) reconcile path, white-box, on a
# COMMITTED node. Runs as root, DETACHED on the node (`setsid sh <this> <case> [flip] > <log> 2>&1 &`; the host polls
# the log for a final RESULT / FLIP line), so an ssh drop cannot cut it in half. busybox ash.
# Every exit path removes the bind mount, releases the lock (verified with flock -n) and starts joinwatch; the host
# reboots the node afterwards (said.* markers, start counters live in the run dir for the rest of the boot).
#   r1        induce "committed boot, openmanetd still carries the deferral env" -> joinwatch's reconcile must
#             re-register openmanetd (env gone, starts +1, log line, new pid) within 60 s
#   r1 flip   same, with reconcile a no-op (bind-mounted decider) -> env must STAY for 60 s
#   r2        same induction, then hold procd's openmanetd flock -> reconcile's start blocks -> "HUNG: the openmanetd
#             start sent" once, not before 60 s after the start; releasing the lock lets the start finish
#   r2 flip   same, with START_HANG_S=100000 -> no HUNG line within 110 s
# Output: PASS/FAIL lines, then "RESULT <case> PASS|FAIL" (normal) or "FLIP <case> VALID|INVALID" (flip).
set -u
CASE=${1:-}; FLIP=${2:-}
case "$CASE" in r1|r2) ;; *) echo "usage: $0 r1|r2 [flip]"; exit 2 ;; esac
[ "$(id -u)" = 0 ] || { echo "FAIL root only"; exit 2; }
# LK: procd's own per-service lock (upstream /lib/functions/procd.sh: exec 1000>/var/lock/procd_<name>.lock) — the
# lock r2 must hold. /var/lock is 1777, so it is used only as procd's root-owned regular file with one link.
D=/usr/libexec/batman-addr-defer; LK=/var/lock/procd_openmanetd.lock
# shellcheck disable=SC2012,SC2046  # busybox has no stat
[ -f "$LK" ] && [ ! -L "$LK" ] && set -- $(ls -ln "$LK") && [ "$2" = 1 ] && [ "$3" = 0 ] || { echo "FAIL $LK is not procd's root-owned lock file (one link, no symlink)"; exit 2; }
# shellcheck source=/dev/null
. /usr/lib/batman/rundir.sh 2>/dev/null; [ -n "${RUNDIR:-}" ] && [ -d "$RUNDIR" ] || { echo "FAIL no run dir"; exit 2; }
mkdir -p -m 0700 "$RUNDIR-dv" && W=$(mktemp -d "$RUNDIR-dv/adr.XXXXXX") || { echo "FAIL cannot make a scratch dir in $RUNDIR-dv"; exit 2; }
TAGN="$CASE${FLIP:+-$FLIP}"
f=0; ok(){ echo "PASS $*"; }; no(){ echo "FAIL $*"; f=1; }
# fin [VALID|INVALID]: restore FIRST (a failed restore turns the verdict into FAIL / INVALID), then the verdict, then DONE
fin(){ v=${1:-INVALID}; cleanup || { f=1; v=INVALID; }
	if [ "$FLIP" = flip ]; then echo "FLIP $TAGN $v"; else [ "$f" = 0 ] && echo "RESULT $TAGN PASS" || echo "RESULT $TAGN FAIL"; fi; echo DONE; }
st(){ "$D" status 2>/dev/null; }
env_of(){ st | sed -n 's/.* env=\([a-z]*\) .*/\1/p'; }
starts(){ n=$(cat "$RUNDIR/addr-defer.starts" 2>/dev/null); echo "${n:-0}"; }
upt(){ cut -d. -f1 /proc/uptime; }
locked(){ ! flock -n "$LK" true 2>/dev/null; }   # someone holds procd's openmanetd lock
since(){ logread | sed -n "/$logmark/,\$p"; }
HOLD=""
unbind_all(){	# retry, then lazy; verify
	i=0; while grep -q " $D " /proc/mounts && [ $i -lt 5 ]; do umount "$D" 2>/dev/null || sleep 1; i=$((i + 1)); done
	grep -q " $D " /proc/mounts && umount -l "$D" 2>/dev/null
	! grep -q " $D " /proc/mounts
}
release_lock(){	# our holder must be gone; the lock itself may be taken briefly by the start that was waiting on it
	[ -n "$HOLD" ] || { ! locked || { i=0; while locked && [ $i -lt 30 ]; do sleep 1; i=$((i + 1)); done; ! locked; }; return; }
	kill "$HOLD" 2>/dev/null; i=0; while kill -0 "$HOLD" 2>/dev/null && [ $i -lt 10 ]; do sleep 1; i=$((i + 1)); done
	kill -0 "$HOLD" 2>/dev/null && return 1; HOLD=""
	i=0; while locked && [ $i -lt 30 ]; do sleep 1; i=$((i + 1)); done
	! locked
}
CLEANED=0
cleanup(){	# idempotent; rc 1 when anything could not be restored
	[ "$CLEANED" = 1 ] && return "$CLEANRC"; CLEANRC=0
	unbind_all || { echo "FAIL cleanup: decider still bind-mounted"; CLEANRC=1; }
	release_lock || { echo "FAIL cleanup: $LK still held"; CLEANRC=1; }
	/etc/init.d/joinwatch start >/dev/null 2>&1; sleep 2
	pgrep -f /usr/bin/joinwatch >/dev/null || { echo "FAIL cleanup: joinwatch not running"; CLEANRC=1; }
	echo "cleanup: $(st) bind=$(grep -c " $D " /proc/mounts) locked=$(locked && echo y || echo n) starts=$(starts) said_hung=$([ -e "$RUNDIR/addr-defer.said.hung" ] && echo y || echo n)"
	rm -rf "$W"; CLEANED=1; return "$CLEANRC"
}
CLEANRC=0
trap cleanup EXIT
trap 'trap - EXIT; echo "FAIL interrupted"; f=1; fin; exit 1' INT TERM HUP PIPE
# one instance at a time (fd 8 stays open for the whole run)
exec 8>"$RUNDIR-dv/adr.lock"; flock -n 8 || { echo "FAIL another addr-defer-reconcile run is active"; echo DONE; trap - EXIT; rm -rf "$W"; exit 2; }
bindover(){ mount --bind "$1" "$D" && grep -q " $D " /proc/mounts; }

# --- 0. preconditions: committed, resting state, nothing left from an earlier run
batman-slot is-trial >/dev/null 2>&1; [ $? = 1 ] || { no "not a committed slot"; fin; exit 1; }
grep -q " $D " /proc/mounts && { no "decider already bind-mounted"; fin; exit 1; }
locked && { no "$LK already held"; fin; exit 1; }
s=$(st); pf=$(cat "$RUNDIR/addr-defer.start.pid" 2>/dev/null); echo "pre: $s starts=$(starts) start.pid=[$pf]"
case "$s" in "want=stock env=absent openmanetd=up") ok "resting state";; *) no "not at rest: $s"; fin; exit 1;; esac
[ ! -e "$RUNDIR/addr-defer.said.hung" ] || { no "HUNG already said this boot (reboot first)"; fin; exit 1; }
[ -z "$pf" ] || ! kill -0 "${pf%% *}" 2>/dev/null || { no "start.pid ${pf%% *} is alive (pid reuse or a running start)"; fin; exit 1; }

# --- 1. induce the wrong state: joinwatch stopped, a decider that says "defer" to the init hook only
cp -p "$D" "$W/real"
printf '#!/bin/sh\n[ -z "${1:-}" ] && exit 0\nexec /bin/sh %s "$@"\n' "$W/real" > "$W/fake-defer"; chmod 755 "$W/fake-defer"
/etc/init.d/joinwatch stop >/dev/null 2>&1; sleep 1
pgrep -f /usr/bin/joinwatch >/dev/null && { no "joinwatch did not stop"; fin; exit 1; }
p0=$(pidof openmanetd)
bindover "$W/fake-defer" || { no "bind fake decider"; fin; exit 1; }
/etc/init.d/openmanetd start >/dev/null 2>&1
# wait for the restarted instance itself, not only procd's env record: openmanetd is briefly down while procd restarts
# it (r1 flip 2026-10-26 08:41 read "env=present openmanetd=down" right after the env flipped)
t=$(upt); while [ "$(st)" != "want=stock env=present openmanetd=up" ] && [ $(( $(upt) - t )) -lt 30 ]; do sleep 1; done; sleep 2
unbind_all || { no "unbind fake decider"; fin; exit 1; }
s=$(st); p1=$(pidof openmanetd); n0=$(starts)
# a failed induction leaves openmanetd with env=present: cleanup starts joinwatch, whose reconcile clears it
case "$s" in "want=stock env=present openmanetd=up") ok "induced: $s (openmanetd pid $p0 -> $p1)";; *) no "induction failed: $s (joinwatch will reconcile it)"; fin; exit 1;; esac

# --- 2. the variant under test
if [ "$FLIP" = flip ]; then
	if [ "$CASE" = r1 ]; then
		printf '#!/bin/sh\n[ "${1:-}" = reconcile ] && exit 0\nexec /bin/sh %s "$@"\n' "$W/real" > "$W/variant"
	else
		sed 's/^START_HANG_S=60 /START_HANG_S=100000 /' "$W/real" > "$W/variant"
		grep -q '^START_HANG_S=100000 ' "$W/variant" || { no "flip variant: START_HANG_S line not found"; fin; exit 1; }
	fi
	chmod 755 "$W/variant"; bindover "$W/variant" || { no "bind variant"; fin; exit 1; }
fi
if [ "$CASE" = r2 ]; then
	# hold procd's per-service lock the way any local process could; the holder IS $! (no forked child keeps the fd)
	sh -c 'exec 9<"$1"; flock 9; exec sleep 900' _ "$LK" </dev/null >/dev/null 2>&1 &
	HOLD=$!; t=$(upt); while ! locked && [ $(( $(upt) - t )) -lt 5 ]; do sleep 1; done
	locked && ok "holding $LK (pid $HOLD)" || { no "lock not held"; fin; exit 1; }
fi
logmark="adr-$(cut -c1-8 /proc/sys/kernel/random/uuid)-$(upt)"; logger -t addr-defer-test "$logmark"
t0=$(upt); /etc/init.d/joinwatch start >/dev/null 2>&1

# --- 3. observe (all windows in real seconds from t0)
el(){ echo $(( $(upt) - t0 )); }
if [ "$CASE" = r1 ]; then
	while [ "$(env_of)" = present ] && [ "$(el)" -lt 60 ]; do sleep 1; done
	e=$(el); s=$(st); n1=$(starts)
	since | grep -q "$logmark" || { no "log mark $logmark rotated out of logread"; fin INVALID; exit 1; }
	lg=$(since | grep -c "re-registering it (start $((n0 + 1))/3)")
	echo "after ${e}s: $s starts=$n0->$n1 logline=$lg"
	if [ "$FLIP" = flip ]; then
		case "$s" in *"env=present"*) r=VALID; echo "reconcile disabled -> env stayed present ${e}s";; *) r=INVALID; echo "env cleared without reconcile: $s";; esac
		unbind_all || no "unbind variant"
		t=$(upt); while [ "$(env_of)" = present ] && [ $(( $(upt) - t )) -lt 60 ]; do sleep 1; done
		echo "restore: $(st) after $(( $(upt) - t ))s"; [ "$(env_of)" = absent ] || { no "restore: env still present"; r=INVALID; }
		fin "$r"; exit 0
	fi
	case "$s" in "want=stock env=absent openmanetd=up") ok "reconciled in ${e}s: $s";; *) no "not reconciled in 60 s: $s";; esac
	[ "$n1" = $((n0 + 1)) ] && ok "starts $n0 -> $n1" || no "starts $n0 -> $n1 (want +1)"
	[ "$lg" -ge 1 ] && ok "log: re-registering it (start $((n0 + 1))/3)" || no "no re-register log line"
	p2=$(pidof openmanetd); [ -n "$p2" ] && [ "$p2" != "$p1" ] && ok "openmanetd restarted ($p1 -> $p2)" || no "openmanetd pid $p1 -> $p2"
else
	while ! since | grep -q "HUNG: the openmanetd start sent" && [ "$(el)" -lt 110 ]; do sleep 1; done
	e=$(el)
	since | grep -q "$logmark" || { no "log mark $logmark rotated out of logread"; fin INVALID; exit 1; }
	hl=$(since | grep -c "HUNG: the openmanetd start sent"); s=$(st)
	sp=$(cat "$RUNDIR/addr-defer.start.pid" 2>/dev/null)
	echo "after ${e}s: hung_lines=$hl $s starts=$n0->$(starts) start.pid=[$sp] locked=$(locked && echo y || echo n)"
	if [ "$FLIP" = flip ]; then
		[ "$hl" = 0 ] && r=VALID || r=INVALID
		# order: joinwatch off (a tick with the REAL decider would now say HUNG and block r2 this boot), unbind the
		# variant BEFORE releasing the lock (the released start runs the init hook = the decider); joinwatch back last
		/etc/init.d/joinwatch stop >/dev/null 2>&1; sleep 1; pgrep -f /usr/bin/joinwatch >/dev/null && { no "joinwatch did not stop"; r=INVALID; }
		unbind_all || { no "unbind variant"; r=INVALID; }
	else
		[ "$hl" = 1 ] && ok "HUNG logged once at ${e}s" || no "HUNG lines: $hl (want 1)"
		# the start was sent at the first reconcile after t0 (start.pid's uptime); HUNG needs >= 60 s after it
		spt=${sp#* }; case "$spt" in ''|*[!0-9]*) no "start.pid has no start uptime: [$sp]";; *)
			[ "$spt" -ge "$t0" ] && ok "start.pid written by this run (start at uptime $spt >= t0 $t0)" || no "start.pid predates this run ($spt < $t0)";; esac
		ns=$(since | sed -n 's/.*HUNG: the openmanetd start sent \([0-9]*\) s ago.*/\1/p' | head -1)
		[ "${ns:-0}" -ge 60 ] && ok "HUNG line says the start was sent ${ns} s ago (>= 60)" || no "HUNG line age [${ns}] < 60"
		case "$s" in *"env=present"*) ok "env still present while the lock is held";; *) no "env changed while locked: $s";; esac
		sleep 20; hl2=$(since | grep -c "HUNG: the openmanetd start sent")
		[ "$hl2" = 1 ] && ok "HUNG said once only (still 1 after 20 s more)" || no "HUNG repeated: $hl2"
	fi
	release_lock && ok "lock holder gone, lock free" || no "lock still held after kill"
	t=$(upt); while [ "$(env_of)" = present ] && [ $(( $(upt) - t )) -lt 60 ]; do sleep 1; done
	s=$(st); echo "after release $(( $(upt) - t ))s: $s"
	case "$s" in "want=stock env=absent openmanetd=up") ok "after release the start went through: $s";; *) no "after release: $s"; [ "$FLIP" = flip ] && r=INVALID;; esac
	if [ "$FLIP" = flip ]; then
		/etc/init.d/joinwatch start >/dev/null 2>&1
		[ -e "$RUNDIR/addr-defer.said.hung" ] && { echo "NOTE said.hung exists: r2 cannot follow in this boot"; r=INVALID; }
		fin "$r"; exit 0
	fi
fi
fin; exit "$f"
