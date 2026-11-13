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
#                        takes no fractions (CONFIG_FLOAT_DURATION off). Exports DV_SLK_HOLD=<this shell's pid> first:
#                        every child of a harness holder carries it (slk_legit). rc 0 = held, or nothing to take:
#                          - no rundir.sh or no flock (an image before #280): no slot flock exists;
#                          - rundir.sh + flock but a batman-slot before S5 (#280-era images): the lock is taken and
#                            nobody else honours it (those images serialise with their mkdir lock) — harmless.
#                        rc 1 = it printed one "SLOTLK-BUSY <why>" line and did NO FAT work:
#                          "SLOTLK-BUSY LEAK ..."  the lock is held by an orphan (slk_orphans): a leaked fd 9 that
#                                                  blocks every slot verb (rc 14) until it exits or the node reboots —
#                                                  the unit judges FAIL (host slk_leak; review r3 A-MAJOR-2);
#                          any other SLOTLK-BUSY     held by a legitimate writer (a batman-slot, a harness holder), the
#                                                  run dir unusable, the open failed: the unit judges INVALID.
#                        The run dir is made / checked by the node's own batman_rundir, and the open is `command exec`
#                        inside a group, so a failed open never ends the remote shell.
#   slk_scan <token> <lo:hi>
#                        SLK_H = every process (but this shell) with the lock file open, as pid:comm:ours|writer|other.
#                        "Open" = one of its /proc/<pid>/fd links reads back (readlink) as exactly the lock path — not
#                        a path that merely ends in it (review r2 B-m2).
#                        ours   = its environment carries DV_SLK=<token> (a verb this script started, or a child it
#                                 left), or it started inside <lo:hi> (boot clock ticks, slk_ticks: taken before the step
#                                 and when it reported done; a process from that window still holding the file was
#                                 started BY the step — also a child that lost the token, e.g. `env -i`, review r3
#                                 A-m1);
#                        writer = started inside <lo:hi> but it is, or descends from, a LIVE batman-slot that has no
#                                 batman-provhelper (SLK_HELPER; "-" = none counts) among its ancestors: another
#                                 legitimate writer (autocommit, joinwatch, an operator, the app while FB6 runs) or a
#                                 child of one — contention, not the step's leak (review r2 B-m3). A child such a writer
#                                 left after it exited (re-parented to init) cannot be told from the step's own and
#                                 counts as ours;
#                        other  = everything else. "-" = that test is off.
#   slk_orphans          while the lock is held: SLK_O = the holders (pid:comm) that have the lock file open in two
#                        scans 1 s apart (same pid, same start time) and that no legitimate holder explains (slk_legit);
#                        SLK_W = the legitimate ones. rc 0 = at least one orphan and the lock still held after the
#                        second scan. The readers (rundir.sh slot_busy, the helper's otaBusy) take a shared lock for a
#                        moment only and do not survive two scans.
#   slk_legit <pid>      rc 0 when <pid> is, or descends from, a batman-slot (by comm, or argv[0] / argv[1] ending in
#                        /batman-slot: `sh /usr/sbin/batman-slot`), or is a harness holder: a shell whose command line
#                        runs slk_take (SLOTLK), or a process carrying DV_SLK_HOLD=<pid> of such a live shell. (Its own
#                        environ shows only what it was started with, so the SLOTLK shell is known by its command
#                        line; a child left by a harness shell that has gone is an orphan like any other.)
#   slk_free <secs> <token> <lo:hi>
#                        after a lock-holding verb returned: within <secs> (checks at 0, 1, … <secs> s) an exclusive
#                        `flock -n` on the lock file (opened read-only, never created) succeeds AND no "ours" process
#                        has the file open. Prints one line and returns:
#                          0 "SLKFREE ok t=<s>"            free, nothing of ours holds it
#                          1 "SLKFREE leak holders=<…>"    one of ours still has it open (a child that kept fd 9)
#                          2 "SLKFREE nofile"              no lock file (the verb never took the lock)
#                          3 "SLKFREE other holders=<…>"   held by a legitimate writer only (contention, retry / INVALID)
#                          4 "SLKFREE orphan holders=<…>"  held by an orphan (slk_orphans): a leaked fd 9 from before the
#                                                          step, or from anyone — FAIL (review r3 A-MAJOR-2)
#   slk_ticks            the boot clock now, in ticks (100 Hz, /proc/uptime)
# Note: the lock file stays in $RUNDIR for the whole boot once any batman-slot created it, so "the lock is free after
# the verb" does not prove the verb took it (review r3 A-m3) — that is the source structure's job (s5-lock-lint).
SLK_RD=${SLK_RD:-/usr/lib/batman/rundir.sh}
slk_take(){
	[ -r "$SLK_RD" ] && command -v flock >/dev/null 2>&1 || return 0
	# shellcheck disable=SC1090  # the node's rundir.sh
	. "$SLK_RD" || { echo "SLOTLK-BUSY cannot read $SLK_RD"; return 1; }
	batman_rundir 2>/dev/null || { echo "SLOTLK-BUSY run dir $RUNDIR unusable"; return 1; }
	DV_SLK_HOLD=$$; export DV_SLK_HOLD
	{ command exec 9>>"$RUNDIR/batman-slot.flock"; } 2>/dev/null || { echo "SLOTLK-BUSY cannot open $RUNDIR/batman-slot.flock"; return 1; }
	SLK_N=1
	while ! flock -n 9; do
		if [ "$SLK_N" -ge "${SLK_TRIES:-25}" ]; then
			if slk_orphans; then
				echo "SLOTLK-BUSY LEAK the slot flock is held >= ${SLK_N} s by$SLK_O — no batman-slot among its ancestors, not the harness: a leaked fd 9; every slot verb is rc 14 until it exits or the node reboots${SLK_W:+ (also open by$SLK_W)}"
			else slk_scan - -; echo "SLOTLK-BUSY held by another for ${SLK_N} tries: ${SLK_H:-?}"; fi
			return 1
		fi
		SLK_N=$((SLK_N + 1)); sleep 1
	done
	return 0
}
slk_ticks(){ awk '{ printf "%d\n", $1 * 100 }' /proc/uptime; }
# slk_anc <pid> <name>: rc 0 when a process named <name> is <pid> or one of its ancestors (pid 1 excluded); SLK_A = its
# pid. Named = comm (the kernel keeps 15 chars: a 15-char comm that <name> starts with counts), or argv[0] / argv[1]
# is <name> or ends in /<name> (a script run as `sh /path/<name>`, a binary started by its path)
slk_anc(){
	_slk_a=$1; _slk_i=0; SLK_A=""
	while [ "$_slk_i" -lt 32 ]; do
		case "$_slk_a" in "" | 0 | 1 | *[!0-9]*) return 1 ;; esac
		_slk_n=$(cat "/proc/$_slk_a/comm" 2>/dev/null)
		if [ -n "$_slk_n" ] && { [ "$_slk_n" = "$2" ] || { [ "${#_slk_n}" -ge 15 ] && [ "${2#"$_slk_n"}" != "$2" ]; }; } \
			|| tr '\0' '\n' < "/proc/$_slk_a/cmdline" 2>/dev/null | head -2 | awk -v n="$2" '$0 == n || substr($0, length($0) - length(n)) == "/" n { f = 1 } END { exit !f }'; then
			SLK_A=$_slk_a; return 0
		fi
		_slk_a=$(sed 's/.*) //' "/proc/$_slk_a/stat" 2>/dev/null | cut -d' ' -f2); _slk_i=$((_slk_i + 1))
	done
	return 1
}
# slk_helper_anc <pid>: rc 0 when batman-provhelper (SLK_HELPER; "-" = never) is <pid> or one of its ancestors. By
# argv as well as comm: the helper's comm is "batman-provhelp" (15 chars), never "batman-provhelper" (review r3)
slk_helper_anc(){ [ "${SLK_HELPER:-batman-provhelper}" != - ] && slk_anc "$1" "${SLK_HELPER:-batman-provhelper}"; }
slk_start(){ sed 's/.*) //' "/proc/$1/stat" 2>/dev/null | cut -d' ' -f20; }
# slk_open </proc/pid>: rc 0 when one of its fds reads back as exactly the lock file (a cheap filter first: the name
# anywhere in a link target, then each fd's exact target)
slk_open(){
	# shellcheck disable=SC2010  # /proc/<pid>/fd names are numbers; ls -l prints the link targets (busybox: no stat)
	ls -l "$1/fd" 2>/dev/null | grep -qF batman-slot.flock || return 1
	for _slk_f in "$1"/fd/*; do
		[ "$(readlink "$_slk_f" 2>/dev/null)" = "$RUNDIR/batman-slot.flock" ] && return 0
	done
	return 1
}
slk_scan(){
	SLK_H=""
	for _slk_p in /proc/[0-9]*; do
		[ "${_slk_p#/proc/}" = "$$" ] && continue
		slk_open "$_slk_p" || continue
		_slk_w=other; _slk_c=$(cat "$_slk_p/comm" 2>/dev/null)
		if [ "$1" != - ] && tr '\0' '\n' < "$_slk_p/environ" 2>/dev/null | grep -qxF "DV_SLK=$1"; then _slk_w=ours
		elif [ "$2" != - ]; then
			_slk_s=$(slk_start "${_slk_p#/proc/}")
			if [ -n "$_slk_s" ] && [ "$_slk_s" -ge "${2%%:*}" ] && [ "$_slk_s" -le "${2#*:}" ]; then
				_slk_w=ours
				slk_anc "${_slk_p#/proc/}" batman-slot && ! slk_helper_anc "$SLK_A" && _slk_w=writer
			fi
		fi
		SLK_H="$SLK_H ${_slk_p#/proc/}:$_slk_c:$_slk_w"
	done
	SLK_H=${SLK_H# }
}
# slk_holders: SLK_L = " pid:starttime " of every process (but this shell) with the lock file open. Not in a command
# substitution: a subshell of a shell that holds fd 9 would list itself.
slk_holders(){
	SLK_L=" "
	for _slk_p in /proc/[0-9]*; do
		[ "${_slk_p#/proc/}" = "$$" ] && continue
		slk_open "$_slk_p" && SLK_L="$SLK_L${_slk_p#/proc/}:$(slk_start "${_slk_p#/proc/}") "
	done
}
slk_legit(){
	slk_anc "$1" batman-slot && return 0
	tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null | grep -q 'slk_take' && return 0
	_slk_d=$(tr '\0' '\n' < "/proc/$1/environ" 2>/dev/null | sed -n 's/^DV_SLK_HOLD=//p' | head -1)
	case "$_slk_d" in "" | *[!0-9]*) return 1 ;; esac
	tr '\0' ' ' < "/proc/$_slk_d/cmdline" 2>/dev/null | grep -q 'slk_take'
}
slk_orphans(){
	SLK_O=""; SLK_W=""
	slk_holders; _slk_1=$SLK_L; sleep 1; slk_holders
	for _slk_e in $SLK_L; do
		case "$_slk_1" in *" $_slk_e "*) ;; *) continue ;; esac
		_slk_p=${_slk_e%%:*}; _slk_c=$(cat "/proc/$_slk_p/comm" 2>/dev/null)
		if slk_legit "$_slk_p"; then SLK_W="$SLK_W $_slk_p:$_slk_c"; else SLK_O="$SLK_O $_slk_p:$_slk_c"; fi
	done
	[ -n "$SLK_O" ] || return 1
	# still held now (not a holder that let go between the scans)
	( exec 8<"$RUNDIR/batman-slot.flock" && flock -n 8 ) 2>/dev/null && { SLK_O=""; return 1; }
	return 0
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
	slk_orphans && { echo "SLKFREE orphan holders=${SLK_O# } (no batman-slot among its ancestors, not the harness: a leaked fd 9)${SLK_W:+ also open by:$SLK_W}"; return 4; }
	echo "SLKFREE other holders=${SLK_H:-none-listed}"; return 3
}
