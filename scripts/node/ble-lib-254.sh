# shellcheck shell=sh
# scripts/node/ble-lib-254.sh — shared node-side helpers for the #254 BLE suites (PR-H1, docs/design/254-h1-harness.md).
# Sourced by ble-periph-254.sh / ble-central-254.sh (staged into $BT/<run_id>/) and concatenated in front of the
# read-only tier-A judge (sent with `sh -s`). busybox ash: no stat, no `timeout`, flock without -w (E1, E38).
# Output contract: every judgement line starts with a TAG; "FAIL <reason>" lines are what the harness counts.
# The IRK is printed by exactly one command (`irk`); nothing here echoes it, and it never goes into an argv.

H=/tmp/run/batman-dv
BT=$H/bt
ST=$H/ble-state
DMLOG=/opt/batdata/log/ble-dm-254.log
# the lease file: $BT/lease for a BLE run, $BT/lease-prov for a prov run (scripts/node/prov-lease-254.sh sets it before
# any call). The two exclude each other: an acquire FAILs while the OTHER one is live (254-h23 §3). One deadman record.
LEASE=${LEASE:-$BT/lease}

fail() { echo "FAIL $*"; }
die() { echo "FAIL $*"; exit 1; }
clean() { sed 's/\x1b\[[0-9;]*m//g; s/\r//g'; }
bootid() { cat /proc/sys/kernel/random/boot_id; }
up_s() { cut -d. -f1 /proc/uptime; }
isint() { case "$1" in ""|*[!0-9]*) return 1;; esac; }

# "mode uid links" of a path without following a symlink at the leaf (ls -ldn; no stat on the node)
lsinfo() { ls -ldn "$1" 2>/dev/null | awk '{print $1, $3, $2}'; }
# the path is a real directory owned by root with exactly the given permission string (e.g. drwx------)
dir_ok() { [ -d "$1" ] && [ ! -L "$1" ] && [ "$(lsinfo "$1")" = "$2 0 $(ls -ldn "$1" | awk '{print $2}')" ]; }
# a regular root-owned file, not a symlink, link count 1
file_ok() { [ -f "$1" ] && [ ! -L "$1" ] && set -- $(lsinfo "$1") && [ "$2" = 0 ] && [ "$3" = 1 ]; }

# harness scratch: root-only, created 0700 (the HDS rule of daily-validation.sh)
scratch() {
	{ [ -d "$H" ] || mkdir -m 700 "$H"; } && [ -O "$H" ] && [ ! -L "$H" ] || die "harness scratch $H unusable"
	for d in "$BT" "$ST"; do
		{ [ -d "$d" ] || mkdir -m 700 "$d"; } && [ -O "$d" ] && [ ! -L "$d" ] || die "harness dir $d unusable"
	done
}

# lim <secs> <cmd...>: run with a time limit (no `timeout` on the node, E1); a hang is killed and reported — a
# deadman must never freeze on one stuck tool (2026-10-20: btmgmt hung on stdin=/dev/null inside the deadman)
lim() {
	_t=$1; shift; "$@" & _p=$!; _n=0
	while [ -d "/proc/$_p" ] && [ $_n -lt "$_t" ]; do sleep 1; _n=$((_n + 1)); done
	if [ -d "/proc/$_p" ]; then kill "$_p" 2>/dev/null; echo "FAIL timeout after ${_t}s: $*"; return 124; fi
	wait "$_p"
}

# ---- current settings: ONLY the `current settings:` line, as tokens (design §4.3 #2; supported settings: lists all)
# mgmt.info segfaults now and then too (04, 2026-10-21 02:08: "Segmentation fault", no output -> a false precondition
# FAIL in the RPA N5b run): read-only, so up to 3 reads; still nothing = unreadable (the caller FAILs)
settings() {
	for _i in 1 2 3; do
		_s=$(bluetoothctl mgmt.info 2>/dev/null | clean | sed -n 's/^[[:space:]]*current settings:[[:space:]]*//p' | head -1)
		[ -n "$_s" ] && { echo "$_s"; return 0; }
	done; return 1
}
has_tok() { case " $1 " in *" $2 "*) return 0;; esac; return 1; }
# non-interactive `bluetoothctl mgmt.advinfo` segfaults now and then without output (E39: 04 4/30, 02 1/31,
# 2026-10-20; mgmt.info 0/60) -> up to 3 reads; still nothing = unreadable (the caller FAILs). Read-only, so a retry
# cannot change what is read.
adv_instances() {
	for _i in 1 2 3; do
		_a=$(bluetoothctl mgmt.advinfo 2>/dev/null | clean | sed -n 's/^Instances list with \([0-9][0-9]*\) item.*/\1/p' | head -1)
		[ -n "$_a" ] && { echo "$_a"; return 0; }
	done; return 1
}

# ---- batman-sc (patch 900 status file) — one judge for preflight, tier A and tier B (design A-m14)
sc_check() {	# prints "FAIL ..." lines; rc 0 = ok
	f=/var/lib/bluetooth/batman-sc r=0
	file_ok "$f" || { fail "batman-sc missing or not a root regular file"; return 1; }
	[ "$(ls -ln "$f" | awk '{print $1}')" = "-rw-------" ] || { fail "batman-sc mode is not 0600"; r=1; }
	l=$(cat "$f"); pid=$(pidof bluetoothd)
	for kv in "boot_id=$(bootid)" "pid=$pid" "mode=2" "status=0"; do
		case " $l " in *" $kv "*) ;; *) fail "batman-sc: want $kv, have [$l]"; r=1;; esac
	done
	[ -n "$pid" ] || { fail "bluetoothd is not running"; r=1; }
	return $r
}

# ---- lock: busybox flock has no -w -> bounded retries of -n (E38). fd 9 = $BT/lock
lock() {	# $1 = seconds to wait (default 30)
	exec 9>>"$BT/lock" || die "cannot open $BT/lock"
	n=0; while ! flock -n 9; do n=$((n + 1)); [ $n -ge "${1:-30}" ] && return 1; sleep 1; done; return 0
}
unlock() { flock -u 9 2>/dev/null; exec 9>&-; }

# ---- lease: "<run_id> <boot_id> <expiry_uptime>" in $BT/lease (design §4.7)
lease_read() { [ -f "$LEASE" ] && cat "$LEASE"; }
lease_valid_for() {	# $1 run_id: lease is ours, this boot, not expired
	set -- "$1" $(lease_read)
	[ "$2" = "$1" ] && [ "$3" = "$(bootid)" ] && isint "$4" && [ "$(up_s)" -lt "$4" ]
}
lease_write() { echo "$1 $(bootid) $(( $(up_s) + $2 ))" > "$LEASE.tmp" && mv "$LEASE.tmp" "$LEASE"; }
# other_lease: the lease file of the other kind; other_live: it is held in this boot and not expired (prints it)
other_lease() { if [ "$LEASE" = "$BT/lease-prov" ]; then echo "$BT/lease"; else echo "$BT/lease-prov"; fi; }
other_live() {
	_o=$(other_lease); [ -f "$_o" ] || return 1
	set -- $(cat "$_o"); [ "${2:-}" = "$(bootid)" ] && isint "${3:-}" && [ "$(up_s)" -lt "$3" ] && echo "${_o##*/} of run $1 until uptime $3"
}

# ---- markers in $ST (boot-scoped: a marker from an earlier boot is void — tmpfs survives no reboot anyway)
mark_set() { echo "$(bootid) $2" > "$ST/$1"; }
mark_here() { [ -f "$ST/$1" ] && [ "$(cut -d' ' -f1 "$ST/$1")" = "$(bootid)" ]; }
mark_clear() { rm -f "$ST/$1"; }

# ---- deadman records: "<run_id> <boot_id> <pgid>" in $ST/dm and $ST/dm.new
dm_rec_alive() {	# $1 file -> rc 0 if the recorded group is alive in this boot
	[ -f "$1" ] || return 1
	set -- $(cat "$1"); [ "$2" = "$(bootid)" ] && isint "$3" && [ -d "/proc/$3" ] && grep -q dm-fire "/proc/$3/cmdline" 2>/dev/null
}
pg_kill() {	# $1 pgid: TERM the whole group (busybox kill takes no "--", E25), then wait <= 10 s for every member
	isint "$1" || return 1
	kill -TERM "-$1" 2>/dev/null
	n=0; while [ $n -lt 10 ]; do
		alive=0; for s in /proc/[0-9]*/stat; do [ "$(cut -d' ' -f5 "$s" 2>/dev/null)" = "$1" ] && alive=1 && break; done
		[ $alive = 0 ] && return 0; n=$((n + 1)); sleep 1
	done; return 1
}
dm_cancel_rec() {	# $1 file: kill the group it records (if it is a deadman of this boot); remove the record
	[ -f "$1" ] || return 0
	if dm_rec_alive "$1"; then set -- "$1" $(cat "$1"); pg_kill "$4" || { fail "deadman group $4 did not exit within 10 s"; return 1; }; fi
	rm -f "$1"
}
# arm: record old groups, start the new one, cancel the old ones (always >= 1 deadman alive, design A-w1).
# $1 run_id, $2 seconds, $3 script that implements `dm-fire`. Caller holds the lock and extends the lease to $2-5.
dm_arm() {
	old_dm=""; old_new=""
	[ -f "$ST/dm" ] && old_dm=$(cat "$ST/dm")
	[ -f "$ST/dm.new" ] && old_new=$(cat "$ST/dm.new")
	setsid sh "$3" dm-fire "$1" "$2" "$LEASE" </dev/null >/dev/null 2>&1 9>&- &		# 9>&-: the deadman must not inherit the lock fd
	np=$!; sleep 1
	pg=$(cut -d' ' -f5 "/proc/$np/stat" 2>/dev/null)
	isint "$pg" || die "deadman did not start"
	echo "$1 $(bootid) $pg" > "$ST/dm.new.tmp" && mv "$ST/dm.new.tmp" "$ST/dm.new"
	for rec in "$old_dm" "$old_new"; do
		[ -n "$rec" ] || continue
		set -- $rec
		[ "$2" = "$(bootid)" ] && [ "$3" != "$pg" ] && [ -d "/proc/$3" ] && grep -q dm-fire "/proc/$3/cmdline" 2>/dev/null && { pg_kill "$3" || die "old deadman group $3 did not exit"; }
	done
	[ "${BLE_TEST_STOP_BEFORE_MV:-0}" = 1 ] && { echo "TEST: stopped before mv dm.new dm (N7b)"; return 0; }
	mv "$ST/dm.new" "$ST/dm"
}
dm_log() {	# one line on p6 before a deadman reboot (design §4.7): root dir, no symlink, link count 1
	d=/opt/batdata/log
	[ -d "$d" ] && [ ! -L "$d" ] && [ "$(ls -ldn "$d" | awk '{print $3}')" = 0 ] || return 0
	[ -e "$DMLOG" ] && ! file_ok "$DMLOG" && return 0
	echo "$(date) boot=$(bootid | cut -c1-8) run=$1 $2" >> "$DMLOG"; sync
}

# ---- state summary (preflight P6 / tier A #5): "STATE ..." lines, "FAIL ..." for anything left behind
ble_state() {
	r=0
	mark_here flipped && { fail "leftover: flipped marker (an interrupted tier-B run left SC-only off?)"; r=1; }
	mark_here irk-exposed && { fail "leftover: irk-exposed marker of this boot (the IRK leaked in a tier-B run and was not voided; run ble-recover or reboot)"; r=1; }
	if [ -f "$BT/lease" ]; then
		set -- $(lease_read)
		if [ "$2" = "$(bootid)" ]; then fail "leftover: BLE lease of run $1 (expires at uptime $3, now $(up_s))"; r=1; fi
	fi
	for rec in "$ST/dm" "$ST/dm.new"; do dm_rec_alive "$rec" && { fail "leftover: live deadman ($(cat "$rec"))"; r=1; }; done
	for p in $(pidof btmon bluetoothctl); do
		grep -q "$BT/" "/proc/$p/cmdline" 2>/dev/null && { fail "leftover: harness process $p ($(tr '\0' ' ' < /proc/$p/cmdline | cut -c1-80))"; r=1; }
		[ -f "/proc/$p/environ" ] && tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | grep -q '^BATMAN_DV_BLE=' && { fail "leftover: harness process $p"; r=1; }
	done
	if pidof bluetoothd >/dev/null; then
		a=$(adv_instances 2>/dev/null); if [ -z "$a" ]; then fail "adv instances not readable (bluetoothctl mgmt.advinfo gave no list in 3 tries)"; r=1
		elif [ "$a" != 0 ]; then fail "leftover: $a advertising instance(s) registered"; r=1; fi
	else
		echo "STATE adv: not readable (bluetoothd down)"
	fi
	[ $r = 0 ] && echo "STATE clean"
	return $r
}

# ---- shared commands of the two tier-B scripts (staged in $BT/<run_id>/; $SELF = that script) ---------------------
# acquire <secs>: take the lease or explain who has it (design §4.7)
cmd_acquire() {
	isint "${1:-}" || die "usage: acquire <seconds>"
	scratch; lock 30 || die "BLE lock busy for 30 s"
	_ol=$(other_live) && { unlock; die "the node is held by another kind of test: $_ol"; }
	if [ -f "$LEASE" ]; then
		set -- "$1" $(lease_read)
		if [ "$2" != "$RUN_ID" ] && [ "$3" = "$(bootid)" ]; then
			if isint "$4" && [ "$(up_s)" -lt "$4" ]; then unlock; die "another BLE test (run $2) holds the lease until uptime $4"; fi
			for rec in "$ST/dm" "$ST/dm.new"; do dm_rec_alive "$rec" && { unlock; die "the lease of run $2 expired but its deadman is still pending"; }; done
			unlock; die "run $2 did not clean up (lease expired, no deadman left): run ble-recover first"
		fi
	fi
	gc_rundirs
	lease_write "$RUN_ID" "$1"; dm_arm "$RUN_ID" "$(( $1 + 5 ))" "$SELF"; unlock
	echo "LEASE $RUN_ID until uptime $(( $(up_s) + $1 ))"
}
# run dirs of finished runs (no lease of theirs, no live deadman of theirs): printed, then removed (design §4.7)
gc_rundirs() {
	for d in "$BT"/*/; do
		[ -d "$d" ] || continue; r=$(basename "$d"); [ "$r" = "$RUN_ID" ] && continue
		[ -L "${d%/}" ] && continue
		set -- $(lease_read); [ "${1:-}" = "$r" ] && [ "${2:-}" = "$(bootid)" ] && continue
		live=0; for rec in "$ST/dm" "$ST/dm.new"; do [ -f "$rec" ] && set -- $(cat "$rec") && [ "$1" = "$r" ] && dm_rec_alive "$rec" && live=1; done
		[ $live = 1 ] && continue
		echo "GC run dir $r: $(ls "$d" | tr '\n' ' ')"; rm -rf "${BT:?}/$r"
	done
}
# arm <secs>: extend lease + replace the deadman (before every state change)
cmd_arm() {
	isint "${1:-}" || die "usage: arm <seconds>"
	lock 30 || die "BLE lock busy for 30 s"; lease_valid_for "$RUN_ID" || { unlock; die "lease is not ours or expired"; }
	lease_write "$RUN_ID" "$1"; dm_arm "$RUN_ID" "$(( $1 + 5 ))" "$SELF"; unlock
	echo "ARMED $1 s"
}
# every other command runs under the lock with a valid lease of this run
held() { lock 30 || die "BLE lock busy for 30 s"; lease_valid_for "$RUN_ID" || { unlock; die "lease is not ours or expired"; }; }
cmd_release() {
	lock 30 || die "BLE lock busy for 30 s"
	lease_valid_for "$RUN_ID" || { unlock; die "lease is not ours or expired"; }
	dm_cancel_rec "$ST/dm.new" && dm_cancel_rec "$ST/dm" || { unlock; die "could not cancel the deadman"; }
	rm -f "$LEASE"; unlock
	rm -rf "${BT:?}/$RUN_ID"
	echo "RELEASED"
}
# dm-fire <run_id> <secs>: the deadman body. Acts only if the lease is still that run's, expired, and this group is
# the recorded deadman (dm or dm.new); waits for the lock up to 10 min, then acts without it (stuck holder).
cmd_dm_fire() {
	run=$1; [ -n "${3:-}" ] && LEASE=$3; sleep "$2"
	me=$(cut -d' ' -f5 /proc/$$/stat)
	got=0; n=0; while [ $n -lt 20 ]; do lock 30 && { got=1; break; }; n=$((n + 1)); done
	if [ $got = 0 ]; then dm_log "$run" "deadman: lock stuck 10 min — killing run $run groups, restoring without the lock"; kill_run_groups "$run"; fi
	set -- $(lease_read)
	[ "$1" = "$run" ] && [ "$2" = "$(bootid)" ] || { [ $got = 1 ] && unlock; exit 0; }
	isint "$3" && [ "$(up_s)" -ge "$3" ] || { [ $got = 1 ] && unlock; exit 0; }
	mine=0; for rec in "$ST/dm" "$ST/dm.new"; do [ -f "$rec" ] && set -- $(cat "$rec") && [ "$3" = "$me" ] && mine=1; done
	[ $mine = 1 ] || { [ $got = 1 ] && unlock; exit 0; }
	kill_run_groups "$run"
	role_fire_restore "$run"		# role-specific; may reboot (irk-exposed)
	rm -f "$LEASE" "$ST/dm" "$ST/dm.new"
	[ $got = 1 ] && unlock; exit 0
}
# recover (design §4.7 `ble-recover`): under the lock, ignore whose lease it is; stop every harness process group
# of every run, then the role's restore (a leaked IRK => reboot), drop lease / deadman records / finished run dirs
cmd_recover() {
	lock 60 || echo "WARN lock busy for 60 s — recovering without it"
	for rec in "$ST/dm" "$ST/dm.new"; do dm_rec_alive "$rec" && { set -- $(cat "$rec"); echo "RECOVER kill deadman group $3"; pg_kill "$3"; }; rm -f "$rec"; done
	for d in "$BT"/*/; do [ -d "$d" ] && kill_run_groups "$(basename "$d")"; done
	echo "RECOVER state before: $(ls "$ST" 2>/dev/null | tr '\n' ' ') lease=[$(lease_read)]"
	rm -f "$BT"/*/*.snoop
	role_fire_restore recover
	rm -f "$BT/lease"; RUN_ID=recover gc_rundirs
	unlock 2>/dev/null; echo "RECOVERED"; ble_state
}
# kill every process group this run started (recorded as $BT/<run>/*.pg)
kill_run_groups() { for pgf in "$BT/$1"/*.pg; do [ -f "$pgf" ] && pg_kill "$(cat "$pgf")"; rm -f "$pgf"; done; }
# start a detached, recorded process group: bg_start <name> <cmd...>  (env BATMAN_DV_BLE=1 marks harness processes)
bg_start() {
	n=$1; shift
	BATMAN_DV_BLE=1 setsid "$@" </dev/null >/dev/null 2>&1 9>&- &
	p=$!; sleep 1; pg=$(cut -d' ' -f5 "/proc/$p/stat" 2>/dev/null)
	isint "$pg" || { fail "could not start $n"; return 1; }
	echo "$pg" > "$BT/$RUN_ID/$n.pg"
}
bg_stop() { [ -f "$BT/$RUN_ID/$1.pg" ] || return 0; pg_kill "$(cat "$BT/$RUN_ID/$1.pg")" || return 1; rm -f "$BT/$RUN_ID/$1.pg"; }
wait_bluetoothd() {	# $1 = old pid ("" = any): up to 20 s for a new bluetoothd + valid batman-sc + hci0
	n=0; while [ $n -lt 20 ]; do
		p=$(pidof bluetoothd); if [ -n "$p" ] && [ "$p" != "${1:-}" ] && sc_check >/dev/null 2>&1 && [ -n "$(settings)" ]; then echo "$p"; return 0; fi
		n=$((n + 1)); sleep 1
	done; return 1
}
# stdin = logs fetched to the host; FAIL if any spelling of this node's IRK is in them (design §4.7 canary)
cmd_canary() {
	f=$(ls /var/lib/bluetooth/*/identity 2>/dev/null | head -1); [ -f "$f" ] || die "no identity file"
	k=$(sed -n 's/^IdentityResolvingKey=//p' "$f" | tr 'A-F' 'a-f'); [ ${#k} = 32 ] || die "identity has no 32-hex IRK"
	pat="$BT/$RUN_ID/canary.pat"; ( umask 077; : > "$pat" )
	r=$(echo "$k" | sed 's/../& /g' | awk '{for(i=NF;i>0;i--) printf "%s", $i; print ""}')
	for x in "$k" "$r"; do
		echo "$x"; echo "$x" | sed 's/../&:/g; s/:$//'; echo "$x" | sed 's/../& /g; s/ $//'
	done >> "$pat"
	unset k r
	h=$(grep -i -c -F -f "$pat"); rm -f "$pat"
	[ "${h:-0}" = 0 ] && echo "CANARY clean" || die "CANARY: this node's IRK appears in $h fetched log line(s)"
}
