# shellcheck shell=sh
# scripts/node/slotlock-lib-254.sh — node side (busybox ash) of the #254 S5 slot flock for the harness (254-p3-impl
# §3.7.3: batman-slot's write / arm / disarm / bootinfo / apply / stage-root / commit / rollback / precheck-node hold
# an exclusive flock on $RUNDIR/batman-slot.flock, fd 9, inherited by every child). The ONE copy: host scripts send it
# as the head of a remote command (scripts/lib/slotlock-254.sh: SLOTLK), node scripts get it prepended
# ({ cat this; cat script; } | ssh node sh -s). Defines functions and SLK_RD only; runs nothing.
#
#   slk_take             take the slot flock on fd 9 for the rest of this shell (a boot FAT is mounted only under it,
#                        or a concurrent slot write meets EBUSY mid-write). Bounded: `flock -n` up to SLK_TRIES
#                        (default 25) times, `sleep 1` apart — busybox flock has no -w, and the target busybox sleep
#                        takes no fractions (CONFIG_FLOAT_DURATION off). rc 0 = held, or nothing to take:
#                          - no rundir.sh or no flock (an image before #280): no slot flock exists;
#                          - rundir.sh + flock but a batman-slot before S5 (#280-era images): the lock is taken and
#                            nobody else honours it (those images serialise with their mkdir lock) — harmless.
#                        rc 1 = it printed "SLOTLK-BUSY <why>": do NO FAT work; the unit judges INVALID (not a
#                        product result). The run dir is made / checked by the node's own batman_rundir, and the open
#                        is `command exec` inside a group, so a failed open never ends the remote shell.
#   slk_scan <token> <lo:hi>
#                        SLK_H = every process (but this shell) with the lock file open, as pid:comm:ours|other.
#                        ours = its environment carries DV_SLK=<token> (a verb this script started, or a child it
#                        left), or it started inside <lo:hi> (boot clock ticks, slk_ticks: taken before a step that
#                        another process ran — the helper — and when it reported done; a process from that window
#                        still holding the file was started BY the step). "-" = that test is off.
#   slk_free <secs> <token> <lo:hi>
#                        after a lock-holding verb returned: within <secs> (checks at 0, 1, … <secs> s) an exclusive
#                        `flock -n` on the lock file (opened read-only, never created) succeeds AND no "ours" process
#                        has the file open. Prints one line and returns:
#                          0 "SLKFREE ok t=<s>"            free, nothing of ours holds it
#                          1 "SLKFREE leak holders=<…>"    one of ours still has it open (a child that kept fd 9)
#                          2 "SLKFREE nofile"              no lock file (the verb never took the lock)
#                          3 "SLKFREE other holders=<…>"   held by someone else only (contention: retry / INVALID)
#   slk_ticks            the boot clock now, in ticks (100 Hz, /proc/uptime)
SLK_RD=${SLK_RD:-/usr/lib/batman/rundir.sh}
slk_take(){
	[ -r "$SLK_RD" ] && command -v flock >/dev/null 2>&1 || return 0
	# shellcheck disable=SC1090  # the node's rundir.sh
	. "$SLK_RD" || { echo "SLOTLK-BUSY cannot read $SLK_RD"; return 1; }
	batman_rundir 2>/dev/null || { echo "SLOTLK-BUSY run dir $RUNDIR unusable"; return 1; }
	{ command exec 9>>"$RUNDIR/batman-slot.flock"; } 2>/dev/null || { echo "SLOTLK-BUSY cannot open $RUNDIR/batman-slot.flock"; return 1; }
	SLK_N=1
	while ! flock -n 9; do
		[ "$SLK_N" -ge "${SLK_TRIES:-25}" ] && { slk_scan - -; echo "SLOTLK-BUSY held by another for ${SLK_N} tries: ${SLK_H:-?}"; return 1; }
		SLK_N=$((SLK_N + 1)); sleep 1
	done
	return 0
}
slk_ticks(){ awk '{ printf "%d\n", $1 * 100 }' /proc/uptime; }
slk_scan(){
	SLK_H=""
	for _slk_p in /proc/[0-9]*; do
		[ "${_slk_p#/proc/}" = "$$" ] && continue
		# shellcheck disable=SC2010  # /proc/<pid>/fd names are numbers; ls -l prints the link targets (busybox: no stat)
		ls -l "$_slk_p/fd" 2>/dev/null | grep -qx -- ".* -> $RUNDIR/batman-slot.flock" || continue
		_slk_w=other
		if [ "$1" != - ] && tr '\0' '\n' < "$_slk_p/environ" 2>/dev/null | grep -qx "DV_SLK=$1"; then _slk_w=ours
		elif [ "$2" != - ]; then
			_slk_s=$(sed 's/.*) //' "$_slk_p/stat" 2>/dev/null | cut -d' ' -f20)
			[ -n "$_slk_s" ] && [ "$_slk_s" -ge "${2%%:*}" ] && [ "$_slk_s" -le "${2#*:}" ] && _slk_w=ours
		fi
		SLK_H="$SLK_H ${_slk_p#/proc/}:$(cat "$_slk_p/comm" 2>/dev/null):$_slk_w"
	done
	SLK_H=${SLK_H# }
}
slk_free(){
	# shellcheck disable=SC1090
	[ -n "${RUNDIR:-}" ] || { [ -r "$SLK_RD" ] && . "$SLK_RD"; }
	[ -e "$RUNDIR/batman-slot.flock" ] || { echo "SLKFREE nofile"; return 2; }
	_slk_t=0
	while :; do
		if ( exec 8<"$RUNDIR/batman-slot.flock" && flock -n 8 ) 2>/dev/null; then
			slk_scan "$2" "$3"
			case " $SLK_H" in *":ours"*) ;; *) echo "SLKFREE ok t=$_slk_t"; return 0 ;; esac
		fi
		[ "$_slk_t" -ge "$1" ] && break
		_slk_t=$((_slk_t + 1)); sleep 1
	done
	slk_scan "$2" "$3"
	case " $SLK_H" in *":ours"*) echo "SLKFREE leak holders=$SLK_H"; return 1 ;; esac
	echo "SLKFREE other holders=${SLK_H:-none-listed}"; return 3
}
