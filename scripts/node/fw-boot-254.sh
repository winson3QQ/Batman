# shellcheck shell=sh
# scripts/node/fw-boot-254.sh — ON a node, read-only: daily-validation suite prov-fw-boot-254 (#254 P3 S5; 254-p3-impl
# §3.8.1 "三道關" (2), §3.8.2, §3.7.3; 254-h4-harness §8.3 / A.12). Sent as
#   { cat scripts/node/slotlock-lib-254.sh scripts/node/fw-boot-254.sh; } | ssh root@node sh -s
# Every daily run, so after every boot the suite sees. On this boot:
#   FB1  the firewall: `inet fw4` loaded (an error in our ruleset-post include fails fw4's whole transaction: no
#        firewall at all, F70), and both include tables present: `bridge batman_http`, `inet batman_http_in`;
#   FB2  the ruleset fw4 builds now, includes and all, passes `nft -c` (`fw4 print | nft -c -f -`, 254-h4 §8.3 "rc 閘門",
#        both boards; check mode: nothing is loaded) — table / priority clashes between fw4 and our include show here;
#   FB4  each rule of the image's include is loaded exactly once, found by its comment (the comments are read from the
#        image's own file /rom/usr/share/nftables.d/ruleset-post/batman-http.nft — never a hand copy; a reload must not
#        duplicate, F70); the include the firewall reads is the image's (overlay copy = FAIL);
#   FB5  provd running -> its upload tmpfs is mounted at the init's BDIR with the init's own mount options (read from
#        /etc/init.d/batman-provd: nodev,nosuid,noexec,mode=0700,nr_inodes=16,size=<board>,uid/gid; size shown by the
#        kernel in KiB, rounded up to 4 KiB pages), fs tmpfs, BDIR not a symlink. provd not running = recorded, not judged;
#   FB6  the read-only lock-holding verbs RELEASE the slot flock: `batman-slot bootinfo A`, `bootinfo B`,
#        `precheck-node`, each run with DV_SLK=<token>, then within 1 s `flock -n` on $RUNDIR/batman-slot.flock succeeds
#        and no process of the verb's (carrying the token, or started between just before the verb and its return: a
#        child that lost the token, e.g. `env -i`, review r3 A-m1) has the file open (slotlock-lib slk_free). It proves
#        the release, NOT that the verb took the lock: the lock file stays in the run dir for the whole boot once any
#        batman-slot made it, so a verb that never locks also finds it free afterwards (review r3 A-m3; that the verbs
#        lock is the source structure's check, tests/prov-p1/s5-lock-lint.sh). The lock is judged whatever the verb
#        answered: a refusal of the node's state (precheck-node 10-12 / 13 / 15-18, or detect_layout's 17 before any
#        verb, e.g. a Pi 4 plain reboot onto the wrong slot) is an INFO line, not a FAIL of the lock (review r2
#        A-MAJOR-2). rc 14, or the lock held after the verb by another process, is retried 5 x; still so, the cause
#        decides (the user's rule: a product state that blocks updates on the node is RED, INVALID only when the harness
#        cannot tell):
#          - the lock held by an orphan — a process with the lock file open in two scans 1 s apart, no batman-slot among
#            itself and its ancestors, not the harness (slotlock-lib slk_orphans): FAIL "a leaked fd 9" (every slot
#            verb is rc 14 until it exits or the node reboots; review r3 A-MAJOR-2);
#          - the lock held by a batman-slot (or a child of one) or a harness holder: INVALID (a legitimate writer);
#          - rc 14 with the lock FREE and a slot's boot FAT (mmcblk0p1 / p3, by major:minor in /proc/self/mountinfo,
#            as batman-slot's tboot_elsewhere reads it) mounted anywhere but /boot: FAIL naming the mount point — every
#            slot verb refuses (rc 14) until it is unmounted or the node reboots (review r3 B-M1);
#          - rc 14 with the lock free and nothing mounted elsewhere (precheck-node's batman-config-save lock-busy, or a
#            holder that just left): INVALID.
#        No lock file after a verb that failed = INVALID (it stopped before the lock); after one that succeeded = FAIL.
#        NOT run (one "NOT-RUN" line, no verdict) while the node is in an uncommitted trial that batman-autocommit is
#        gating (`batman-slot is-trial` rc 0 — it takes no lock — and autocommit's main, $RUNDIR/autocommit.run/pid,
#        alive): a verb holding the lock then makes autocommit's `batman-slot commit` rc 14, which resets its healthy
#        count and delays the commit (review r3 B-m5). A trial nobody gates (autocommit gone: a #133 stale fallback)
#        is run as usual.
#        Side effects (254-h4 A.12): the verbs hold the slot flock for their length (up to 5 tries each, 2 s apart);
#        precheck-node runs `batman-config-save --check`, mounts p5 read-only, and rewrites the p5 verdict file
#        ($RUNDIR/p5-check.rc) as sysupgrade stage 1 does (its current truth); `bootinfo B` mounts B's boot FAT
#        read-only at /mnt/slotboot.<its pid> in the HOST mount namespace for the length of the verb. Should this remote
#        shell be killed meanwhile (the host's ssh timeout — ⚠️ not seen on a node: the verb runs in the background with
#        its output on /dev/null and normally finishes and unmounts by its own EXIT trap), that mount can stay — and
#        every later slot verb is rc 14 (tboot_elsewhere) until it goes. So each verb's pid is recorded in
#        /tmp/run/batman-dv/fw-boot-254.pids (only when that directory is root's, mode 0700, not a symlink) and the next
#        run unmounts /mnt/slotboot.<pid> of a recorded pid that is no longer a running batman-slot — our own leftovers
#        only, under the slot lock; an unrecorded /mnt/slotboot.<pid> is never touched (it is then judged by the rc 14
#        rule above).
# A pre-S5 image (batman-slot without the slot flock) -> one FAIL line "pre-S5 image <ver>: ..." and nothing judged: a
# KNOWN entry with an expiry in scripts/validation-known-failures.txt (like pre-P1b / pre-P2), NEW after it (review r2
# B-MAJOR-1). Waits until uptime >= 120 s (fw4 / provd start). Prints PASS / FAIL / INVALID / INFO / NOT-RUN lines and
# "RESULT prov-fw-boot-254 PASS|FAIL|INVALID".
# FB_ROOT (offline tests only) prefixes every file path; FB_PROVD / FB_UMOUNT / FB_UID (offline tests only) are the provd
# process name, the umount command (a host busybox runs its own applets before PATH) and the pid directory's owner (0);
# commands come from PATH.
U=prov-fw-boot-254
FR=${FB_ROOT:-}
PN=${FB_PROVD:-batman-provd}
UM=${FB_UMOUNT:-umount}
FU=${FB_UID:-0}
fails=0; invs=0
ok(){ echo "PASS $U: $*"; }; no(){ echo "FAIL $U: $*"; fails=$((fails + 1)); }; inv(){ echo "INVALID $U: $*"; invs=$((invs + 1)); }
result(){ if [ "$fails" -gt 0 ]; then echo "RESULT $U FAIL"; exit 1; elif [ "$invs" -gt 0 ]; then echo "RESULT $U INVALID"; exit 2; fi
	echo "RESULT $U PASS"; exit 0; }
V=$(sed -n 's/^BATMAN_VERSION=//p' "$FR/etc/batman-build" 2>/dev/null)
BOARD=$(sed -n 's/^BATMAN_BOARD=//p' "$FR/etc/batman-build" 2>/dev/null)
up(){ cut -d. -f1 "$FR/proc/uptime"; }
echo "INFO $U: version=$V board=$BOARD boot=$(cut -c1-8 "$FR/proc/sys/kernel/random/boot_id" 2>/dev/null) up=$(up)s"
grep -q '^slot_lock()' "$FR/usr/sbin/batman-slot" 2>/dev/null || { no "pre-S5 image ${V:-?}: batman-slot has no slot flock (slot_lock) — S5's firewall include, upload tmpfs and lock are not in it"; result; }
i=0; while [ "$(up)" -lt 120 ] && [ $i -lt 30 ]; do sleep 5; i=$((i + 1)); done

# ---- FB1 / FB2 / FB4 the firewall and the include
command -v nft >/dev/null 2>&1 || { no "no nft on the node"; result; }
nft list table inet fw4 >/dev/null 2>&1 && ok "FB1 inet fw4 loaded (the firewall is up)" || no "FB1 inet fw4 missing: no firewall on this boot (F70: a bad ruleset-post include fails the whole fw4 load)"
if ! command -v fw4 >/dev/null 2>&1; then no "FB2 no fw4 on the node"
else
	fp=$(fw4 print 2>/dev/null); fpr=$?
	if [ "$fpr" != 0 ] || [ -z "$fp" ]; then no "FB2 fw4 print failed (rc $fpr, $(printf '%s' "$fp" | wc -c) bytes)"
	else
		e=$(printf '%s\n' "$fp" | nft -c -f - 2>&1); er=$?
		[ "$er" = 0 ] && ok "FB2 fw4 print | nft -c -f -: rc 0 (the ruleset fw4 builds, include and all, is valid)" || no "FB2 fw4 print | nft -c -f -: rc $er: $(printf '%s\n' "$e" | head -3 | tr '\n' '|')"
	fi
fi
NF=/usr/share/nftables.d/ruleset-post/batman-http.nft
if [ ! -f "$FR/rom$NF" ]; then no "FB4 the image has no $NF (/rom): S5 installs it"
else
	if [ ! -f "$FR$NF" ]; then no "FB4 $NF missing from the running root (fw4 loads nothing)"
	elif ! cmp -s "$FR/rom$NF" "$FR$NF"; then no "FB4 $NF differs from the image's (/rom): an overlay copy is what fw4 loads"
	else ok "FB4 $NF is the image's"; fi
	# table|comment for every rule in the image's file
	rules=$(awk '/^table /{ t = $2 " " $3 } /comment "/{ s = $0; sub(/.*comment "/, "", s); sub(/".*/, "", s); if (t != "") print t "|" s }' "$FR/rom$NF")
	for tb in "bridge batman_http" "inet batman_http_in"; do
		c=$(printf '%s\n' "$rules" | grep -c "^$tb|")
		[ "$c" -gt 0 ] || { no "FB4 the image's include has no commented rule in table $tb — nothing to check it by"; continue; }
		l=$(nft list table $tb 2>/dev/null)
		[ -n "$l" ] || { no "FB1 table $tb missing (the include did not load)"; continue; }
		ok "FB1 table $tb loaded"
		res=$(printf '%s\n' "$rules" | grep "^$tb|" | while IFS='|' read -r _ cm; do
			k=$(printf '%s\n' "$l" | grep -cF "comment \"$cm\"")
			[ "$k" = 1 ] && echo "PASS $U: FB4 $tb: rule \"$cm\" loaded once" || echo "FAIL $U: FB4 $tb: rule \"$cm\" loaded $k times (want 1)"
		done)
		printf '%s\n' "$res"; fails=$((fails + $(printf '%s\n' "$res" | grep -c '^FAIL')))
	done
fi

# ---- FB5 provd's upload tmpfs
IN=$FR/etc/init.d/batman-provd
if ! pidof "$PN" >/dev/null 2>&1; then echo "INFO $U: FB5 batman-provd not running on this boot — its upload tmpfs is not judged"
elif ! grep -q '^_bulk_mount()' "$IN" 2>/dev/null; then no "FB5 $IN has no _bulk_mount (an S5 image mounts provd's upload tmpfs)"
else
	BD=$(sed -n 's/^BDIR=//p' "$IN" | head -1)
	OP=$(sed -n 's/.*mount -t tmpfs -o \([^ ]*\) .*/\1/p' "$IN" | head -1)
	SZ=$(grep "$BOARD" "$IN" | sed -n 's/.*sz=\([0-9][0-9]*\).*/\1/p' | head -1)
	if [ -z "$BD" ] || [ -z "$OP" ] || [ -z "$SZ" ]; then no "FB5 cannot read BDIR [$BD] / the mount options [$OP] / the size for $BOARD [$SZ] from $IN"
	else
		ln=$(awk -v d="$BD" '$2 == d' "$FR/proc/mounts")
		set -- $ln
		if [ -L "$FR$BD" ]; then no "FB5 $BD is a symlink"
		elif [ -z "$ln" ]; then no "FB5 provd runs but $BD is not mounted (D-15: no upload; the init could not mount it)"
		elif [ "$(printf '%s\n' "$ln" | wc -l)" != 1 ]; then no "FB5 $BD is mounted more than once (stacked): $(echo $ln)"
		elif [ "$3" != tmpfs ]; then no "FB5 $BD is $3, not tmpfs"
		else
			have=",$4,"; miss=""
			for o in $(echo "$OP" | tr ',' ' '); do
				case "$o" in
					mode=0*) o=mode=${o#mode=0} ;;
					size=*) o=size=$(( (SZ + 4095) / 4096 * 4 ))k ;;
				esac
				case "$have" in *",$o,"*) ;; *) miss="$miss $o" ;; esac
			done
			[ -z "$miss" ] && ok "FB5 $BD: tmpfs with the init's options ($OP; size=$SZ B)" || no "FB5 $BD mount options lack:$miss (mounted: $4)"
		fi
	fi
fi

# ---- FB6 the read-only lock-holding verbs release the slot flock
# shellcheck disable=SC1090  # the node's rundir.sh (SLK_RD only in the offline tests)
[ -r "${SLK_RD:-/usr/lib/batman/rundir.sh}" ] && . "${SLK_RD:-/usr/lib/batman/rundir.sh}"
type slk_free >/dev/null 2>&1 || { no "FB6 the slot-lock lib was not sent with this script"; result; }
# our own leftovers first (see the header): /mnt/slotboot.<pid> of a pid an earlier run recorded, no longer batman-slot
PD=$FR/tmp/run/batman-dv; PF=$PD/fw-boot-254.pids; rec=""
mnt_has(){ awk -v m="$1" '$2 == m { f = 1 } END { exit !f }' "$FR/proc/mounts" 2>/dev/null; }
[ -e "$PD" ] || mkdir -m 0700 -p "$PD" 2>/dev/null
# ours = a real directory (not a symlink), owned by root (FB_UID in the offline tests), mode 0700 exactly (review r3 B-m1)
pd_ours(){ [ -d "$PD" ] && [ ! -L "$PD" ] || return 1
	# shellcheck disable=SC2046  # the fields of one ls -ldn line
	set -- $(ls -ldn "$PD" 2>/dev/null); [ "${1:-}" = drwx------ ] && [ "${3:-}" = "$FU" ]; }
if pd_ours && [ ! -L "$PF" ]; then
	rec=1
	for p in $(grep -x '[0-9][0-9]*' "$PF" 2>/dev/null); do
		mp=/mnt/slotboot.$p
		mnt_has "$mp" || continue
		[ "$(cat "/proc/$p/comm" 2>/dev/null)" = batman-slot ] && continue   # still running: not a leftover
		if ( slk_take >/dev/null && $UM "$FR$mp" ) 2>/dev/null; then rmdir "$FR$mp" 2>/dev/null
			echo "INFO $U: FB6 unmounted $mp — left by an earlier run's batman-slot (pid $p, gone: that remote shell was killed)"
		else no "FB6 $mp is still mounted, left by an earlier run's batman-slot (pid $p), and could not be unmounted: every slot verb is rc 14 until it goes"; fi
	done
	: > "$PF" 2>/dev/null || rec=""
else echo "INFO $U: FB6 $PD is not a directory of ours (root's, 0700, not a symlink): verb pids not recorded (a leftover mount after a kill is not cleaned next run)"; fi
# fb_elsewhere: "<dev> (<maj:min>) is mounted at <mp>" for each slot boot FAT (p1 = A, p3 = B) mounted outside /boot —
# batman-slot's tboot_elsewhere (mounted_at: field 3 major:minor, field 5 mount point of /proc/self/mountinfo)
fb_elsewhere(){ for d in mmcblk0p1 mmcblk0p3; do
	mm=$(cat "$FR/sys/class/block/$d/dev" 2>/dev/null); [ -n "$mm" ] || continue
	awk -v mm="$mm" -v d="$d" '$3 == mm && $5 != "/boot" { printf "%s (%s) is mounted at %s; ", d, mm, $5 }' "$FR/proc/self/mountinfo" 2>/dev/null
done; }
# fb_busy <verb>: rc 14 or the lock held after it, 5 tries: name the cause (see the header) — FAIL or INVALID
fb_busy(){
	if ( exec 8<"$RUNDIR/batman-slot.flock" && flock -n 8 ) 2>/dev/null; then
		el=$(fb_elsewhere)
		if [ -n "$el" ]; then no "FB6 batman-slot $1: rc 14 x 5 with the slot flock free — ${el%; }: every slot verb (bootinfo, write, arm, apply) refuses with rc 14 (tboot_elsewhere) until it is unmounted or the node reboots"
		else inv "FB6 batman-slot $1: rc 14 x 5 but the slot flock is free and no slot boot FAT is mounted outside /boot (precheck-node's batman-config-save lock-busy, or a holder that just left): $2"; fi
	elif slk_orphans; then no "FB6 batman-slot $1: the slot flock is held through 5 tries by$SLK_O — no batman-slot among its ancestors, not the harness: a leaked fd 9; every slot verb is rc 14 until it exits or the node reboots${SLK_W:+ (also open by$SLK_W)}"
	else inv "FB6 batman-slot $1: the lock stayed busy for 5 tries, held by a legitimate writer (a batman-slot or a child of one, or the harness):${SLK_W:- none listed} — contention, not judged ($2)"; fi
}
# shellcheck disable=SC2034  # read by the lib (slk_helper_anc)
SLK_HELPER=-   # no helper step here: any live batman-slot that is not this script's verb is another writer
# a trial autocommit is gating: do not take the lock in its commit window (see the header)
it=$(batman-slot is-trial >/dev/null 2>&1 </dev/null; echo $?)
acp=$(cat "$RUNDIR/autocommit.run/pid" 2>/dev/null)
if [ "$it" = 0 ] && case "$acp" in "" | *[!0-9]*) false ;; *) tr '\0' ' ' < "/proc/$acp/cmdline" 2>/dev/null | grep -q batman-autocommit ;; esac; then
	echo "NOT-RUN $U: FB6 this boot is an uncommitted trial (batman-slot is-trial rc 0) that batman-autocommit (pid $acp) is gating — the lock-holding verbs are not run now: holding the slot flock would make its commit rc 14 and reset its healthy count; the next run after the commit judges the lock"
	result
fi
[ "$it" = 0 ] && echo "INFO $U: FB6 an uncommitted trial (is-trial rc 0) that no batman-autocommit gates (a #133 stale fallback?) — the verbs run as usual"
for vb in "bootinfo A" "bootinfo B" "precheck-node"; do
	tok=fb$(slk_ticks).$(echo "$vb" | tr -dc 'a-zA-Z'); t=1; r=""; o=""; fr=""
	while [ $t -le 5 ]; do
		t0=$(slk_ticks)
		# shellcheck disable=SC2086  # $vb is the verb and its argument
		DV_SLK=$tok batman-slot $vb >/dev/null 2>&1 </dev/null & bp=$!
		[ -n "$rec" ] && echo "$bp" >> "$PF"
		wait "$bp"; r=$?
		if mnt_has "/mnt/slotboot.$bp"; then
			no "FB6 batman-slot $vb (pid $bp, rc $r) returned but left /mnt/slotboot.$bp mounted (its EXIT trap did not unmount)"
			$UM "$FR/mnt/slotboot.$bp" 2>/dev/null && rmdir "$FR/mnt/slotboot.$bp" 2>/dev/null
		fi
		if [ "$r" = 14 ]; then o="rc 14 (the lock was held when it started, or a slot boot FAT is mounted elsewhere)"; t=$((t + 1)); sleep 2; continue; fi
		# the verb's window: from just before it to now (a child that lost the token is still the verb's)
		o=$(slk_free 1 "$tok" "$t0:$(slk_ticks)"); fr=$?
		[ "$fr" = 3 ] && { t=$((t + 1)); sleep 2; continue; }
		break
	done
	if [ "$r" = 14 ] || [ "$fr" = 3 ]; then fb_busy "$vb" "$o"; continue; fi
	case "$vb:$r" in
		bootinfo*:0 | precheck-node:0 | precheck-node:1[012]) ;;
		*) echo "INFO $U: FB6 batman-slot $vb rc $r — a refusal of this node's state (13 bad slot, 15 boot config, 16 p5 not seeded, 17 fw override / stale fallback #133, 18 a mount failed); the lock is judged all the same" ;;
	esac
	case "$o" in
		"SLKFREE ok"*) ok "FB6 batman-slot $vb (rc $r): the slot flock is free <= 1 s after it (${o#SLKFREE })" ;;
		"SLKFREE leak"*) no "FB6 batman-slot $vb (rc $r) left the slot flock held by its own process(es): ${o#SLKFREE leak }" ;;
		"SLKFREE nofile"*)
			if [ "$r" = 0 ]; then no "FB6 batman-slot $vb (rc 0): no lock file afterwards — it did not take the slot flock"
			else inv "FB6 batman-slot $vb: rc $r and no lock file — it stopped before the slot flock, nothing to judge"; fi ;;
		"SLKFREE orphan"*) no "FB6 batman-slot $vb (rc $r): the slot flock is held by an orphan — ${o#SLKFREE orphan }; every slot verb is rc 14 until it exits or the node reboots" ;;
		*) inv "FB6 batman-slot $vb: the lock check printed [$o]" ;;
	esac
done
result
