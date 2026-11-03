# shellcheck shell=sh
# scripts/node/prov-undo-lib-254.sh — #254 H4 undo executor (docs/design/254-h4-harness.md §5.7). Sourced by
# prov-lease-254.sh after ble-lib-254.sh (staged with it, the same stage-check). busybox ash.
#
# Journal: one action per line  "<id> <state> <bind> <action> [args...]"  (state todo|done; bind - | slot:<A|B> | boot:<id>)
#   tmpfs  $UJT/<run>/journal   (root 0700; NOT under $BT/<run>: gc_rundirs / release remove that)
#   p6     $UJP/<run>/journal   (root 0700; actions that survive a reboot, with their uci backups) — registered there
#                               BEFORE the change is made
# Units register with `prov-lease-254.sh undo-add <action> [args]` (under the lease); the lib picks the journal and the
# bind. Closed list of actions; every line is validated again when it runs: a bad line = CRIT, skipped, left in place.
# undo_run <run> host|deadman|recover:
#   host     the host's own restore (prov-lease-254.sh undo, under the lease lock); writes $BT/undo-doing.<run>
#   deadman  role_fire_restore inside dm-fire (same process: no renew, no setsid)
#   recover  ble-recover, for every run with a journal
#   deadman / recover first stop a stuck host executor (§5.7), then segment 1 (disarm: shell / Go faults, killpoints,
#   unbind-all, helper / provd back to release, kill-pg), then segment 2 (journal, newest first; each action under lim
#   in a subshell without the lock fd; `done` rewritten atomically after each). A `restoring` marker: segment 1 only.
# Log: /opt/batdata/log/dv-undo-<run>.log — action names and arguments only (no action carries a secret).
UJT=/tmp/run/batman-dv/undo
UJP=/opt/batdata/state/dv-undo
UKD=/tmp/run/batman-prov-test
UCNT=/tmp/run/batman-dv/undo-test
U_PENDING=""	# P3 defines the pending-update path (pending-del): until then the action is refused (CRIT)
U_DEVOPEN=""	# P3 defines the dev-open flag path (rm-file): until then only /tmp/run/batman-dv/ paths

urun_ok() { case "$1" in ""|*[!A-Za-z0-9_-]*) return 1 ;; esac; }
ulog() {	# <run> <msg>: the run's undo log on p6 (same checks as dm_log), and stdout
	echo "UNDO $2"
	_ld=/opt/batdata/log; _lf=$_ld/dv-undo-$1.log
	[ -d "$_ld" ] && [ ! -L "$_ld" ] && [ "$(ls -ldn "$_ld" | awk '{print $3}')" = 0 ] || return 0
	[ -e "$_lf" ] && ! file_ok "$_lf" && return 0
	( umask 077; echo "$(date) boot=$(bootid | cut -c1-8) $2" >> "$_lf" ) 2>/dev/null; sync
}
udir() {	# <base> <run>: create (root 0700, mkdir without -p) and check both levels; prints the run dir
	for _d in "$1" "$1/$2"; do
		[ -e "$_d" ] || [ -L "$_d" ] || mkdir -m 700 "$_d" 2>/dev/null || { fail "cannot create $_d"; return 1; }
		dir_ok "$_d" drwx------ || { fail "$_d is not a root 0700 directory"; return 1; }
	done; echo "$1/$2"
}
ujournals() { for _j in "$UJT/$1/journal" "$UJP/$1/journal"; do [ -f "$_j" ] && file_ok "$_j" && echo "$_j"; done; }
uslot() { batman-slot active 2>/dev/null; }

# ---- validation (§5.7 "每一行的參數驗證"): rc 0 = valid
u_dev_ok() { case "$1" in *[!a-z0-9.-]*) return 1 ;; h4[a-z0-9]*|phy9h4|q0|q0.0|phy1-ap0) return 0 ;; esac; return 1; }
u_path_ok() {	# rm-file: under /tmp/run/batman-dv/ (no .., no symlink anywhere on the path) or the dev-open flag
	[ -n "$U_DEVOPEN" ] && [ "$1" = "$U_DEVOPEN" ] && return 0
	case "$1" in /tmp/run/batman-dv/?*) ;; *) return 1 ;; esac
	case "$1" in *..*|*//*|*/) return 1 ;; esac
	case "$1" in *[!A-Za-z0-9._/-]*) return 1 ;; esac
	_p=$1; while [ "$_p" != /tmp/run ] && [ "$_p" != / ]; do [ -L "$_p" ] && return 1; _p=$(dirname "$_p"); done
	return 0
}
u_name_ok() { case "$1" in ""|*[!$2]*) return 1 ;; esac; return 0; }	# <s> <bracket class body, unquoted: a range>, e.g. a-z_
uvalid() {	# <run> <action> [args...]
	_vr=$1; _va=$2; shift 2
	case "$_va" in
	fw-start|bt-start|p5-save) [ $# = 0 ] ;;
	uci-revert) [ $# = 1 ] && u_name_ok "$1" a-z_ ;;
	uci-restore) [ $# = 2 ] && u_name_ok "$1" a-z_ && u_name_ok "${2##*.}" 0-9 \
		&& [ "$2" = "$UJP/$_vr/uci.$1.${2##*.}" ] && file_ok "$2" ;;
	nft-del-table) [ $# = 2 ] && case "$1" in inet|ip|ip6|bridge|netdev|arp) true ;; *) false ;; esac \
		&& u_name_ok "$2" a-z0-9_ && [ "$2" != fw4 ] ;;
	link-master) [ $# = 2 ] && u_dev_ok "$1" && case "$2" in br-ahwlan|docker0) true ;; *) false ;; esac ;;
	link-del) [ $# = 1 ] && u_dev_ok "$1" ;;
	netns-del) [ $# = 1 ] && u_name_ok "$1" a-z0-9 && case "$1" in h4*) true ;; *) false ;; esac ;;
	svc-start|svc-enable) [ $# = 1 ] && u_name_ok "$1" a-z0-9_- && [ -f "/etc/init.d/$1" ] && [ ! -L "/etc/init.d/$1" ] ;;
	rm-file) [ $# = 1 ] && u_path_ok "$1" ;;
	kill-pg) [ $# = 2 ] && isint "$1" && [ "$1" -gt 1 ] && u_name_ok "$2" a-z0-9- ;;
	pending-del) [ $# = 0 ] && [ -n "$U_PENDING" ] ;;
	ap-restore) false ;;	# P3 (key 20): C0 written back through halow-setkey; refused before P3
	test-count) [ $# -ge 1 ] && [ $# -le 2 ] && u_name_ok "$1" a-z0-9- && { [ $# = 1 ] || [ "$2" = stall ] || [ "$2" = fail ] || [ "$2" = slow ]; } ;;
	*) false ;;
	esac
}
# where a newly registered action goes, and what it is bound to (§5.7 "撐過重開")
uwhere() { case "$1" in uci-restore|svc-enable) echo "p6 slot:$(uslot)" ;; p5-save) echo "p6 -" ;; kill-pg) echo "tmp boot:$(bootid)" ;; *) echo "tmp -" ;; esac; }
umaxid() { cat "$UJT/$1/journal" "$UJP/$1/journal" 2>/dev/null | awk 'BEGIN{m=0} $1+0>m{m=$1+0} END{print m}'; }
ujwrite() {	# <journal> <line>: append atomically (copy + mv), sync (p6)
	_t=$1.tmp; { [ -f "$1" ] && cat "$1"; echo "$2"; } > "$_t" && chmod 600 "$_t" && mv "$_t" "$1" && sync
}
# undo_add <run> <action> [args...]: register (the caller holds the lease lock). uci-restore takes only <pkg>: the backup
# (`uci export <pkg>`) is written into the run's p6 dir here, before the caller changes anything.
undo_add() {
	_ar_=$1; shift; urun_ok "$_ar_" || { fail "bad run id"; return 1; }
	_wb=$(uwhere "$1"); _w=${_wb%% *}; _b=${_wb#* }
	[ "$_w" = p6 ] && _base=$UJP || _base=$UJT
	case "$_b" in slot:) fail "no active slot (batman-slot active)"; return 1 ;; esac
	_rd=$(udir "$_base" "$_ar_") || { echo "$_rd"; return 1; }
	_id=$(( $(umaxid "$_ar_") + 1 ))
	if [ "$1" = uci-restore ]; then
		[ $# = 2 ] && u_name_ok "$2" a-z_ || { fail "usage: undo-add uci-restore <pkg>"; return 1; }
		_bk=$_rd/uci.$2.$_id
		if ( umask 077; uci -q export "$2" > "$_bk.tmp" ) && [ -s "$_bk.tmp" ] && mv "$_bk.tmp" "$_bk" && sync; then :
		else rm -f "$_bk.tmp"; fail "uci export $2"; return 1; fi
		set -- uci-restore "$2" "$_bk"
	fi
	uvalid "$_ar_" "$@" || { fail "undo-add refused (closed list / arguments): $*"; return 1; }
	ujwrite "$_rd/journal" "$_id todo $_b $*" || { fail "cannot write $_rd/journal"; return 1; }
	echo "UNDO-ADDED $_id $_w $_b $*"
}
umark_done() {	# <journal> <id>
	awk -v id="$2" '$1==id && $2=="todo" {$2="done"} {print}' "$1" > "$1.tmp" && chmod 600 "$1.tmp" && mv "$1.tmp" "$1" && sync
}

# ---- actions (each idempotent; rc 0 = the state is back and checked) ------------------------------------------------
ubudget() { case "$1" in fw-start) echo 120 ;; p5-save) echo 180 ;; svc-start|svc-enable|bt-start) echo 60 ;; uci-*) echo 30 ;; test-count) echo 120 ;; *) echo 20 ;; esac; }
umaster() { basename "$(readlink "/sys/class/net/$1/master" 2>/dev/null)" 2>/dev/null; }
uns_has() { ip netns list 2>/dev/null | awk '{print $1}' | grep -qx "$1"; }
uact() {	# <run> <mode> <action> [args...]   (the caller runs it in a subshell without fd 9)
	_xr=$1; _xm=$2; _xa=$3; shift 3
	case "$_xa" in
	fw-start)
		nft list table inet fw4 >/dev/null 2>&1 && return 0
		/etc/init.d/firewall start >/dev/null 2>&1
		[ -x /etc/init.d/dockerd ] && /etc/init.d/dockerd enabled 2>/dev/null && /etc/init.d/dockerd restart >/dev/null 2>&1
		nft list table inet fw4 >/dev/null 2>&1 ;;
	uci-revert) uci -q revert "$1"; [ -z "$(uci -q changes "$1")" ] ;;
	uci-restore)
		uci -q revert "$1"; uci -q import "$1" < "$2" && uci -q commit "$1" || return 1
		uci -q export "$1" | cmp -s - "$2" ;;
	nft-del-table) nft list table "$1" "$2" >/dev/null 2>&1 && nft delete table "$1" "$2"; ! nft list table "$1" "$2" >/dev/null 2>&1 ;;
	link-master)
		[ -e "/sys/class/net/$1" ] || return 1
		[ "$(umaster "$1")" = "$2" ] || ip link set dev "$1" master "$2"
		[ "$(umaster "$1")" = "$2" ] ;;
	link-del) [ -e "/sys/class/net/$1" ] && ip link del dev "$1"; [ ! -e "/sys/class/net/$1" ] ;;
	netns-del) uns_has "$1" && ip netns del "$1"; ! uns_has "$1" ;;
	svc-start) "/etc/init.d/$1" start >/dev/null 2>&1 ;;
	svc-enable) "/etc/init.d/$1" enable >/dev/null 2>&1; "/etc/init.d/$1" enabled ;;
	bt-start)
		pidof dbus-daemon >/dev/null || /etc/init.d/dbus start >/dev/null 2>&1
		pidof bluetoothd >/dev/null || { /etc/init.d/bluetoothd start >/dev/null 2>&1; sleep 3; }
		pidof bluetoothd >/dev/null ;;
	p5-save) batman-config-save --save >/dev/null 2>&1; batman-config-save --check >/dev/null 2>&1 ;;
	rm-file) rm -f "$1"; [ ! -e "$1" ] ;;
	pending-del) rm -f "$U_PENDING"; [ ! -e "$U_PENDING" ] ;;
	test-count)	# test-h4-undo.sh only: count each execution; "stall" hangs the HOST executor (no lim); "fail" fails;
			# "slow" takes 90 s in host mode (the lease runs out while the host executor works)
		[ -d "$UCNT" ] || mkdir -m 700 "$UCNT"; ( umask 077; echo "$_xm $1" >> "$UCNT/$_xr.count" )
		[ "${2:-}" = fail ] && return 1
		[ "${2:-}" = stall ] && [ "$_xm" = host ] && sleep 1500
		[ "${2:-}" = slow ] && [ "$_xm" = host ] && sleep 90
		return 0 ;;
	*) return 1 ;;
	esac
}

# ---- segment 1: disarm (always first, whatever the journal says) ----------------------------------------------------
useg1() {	# <run>; sets _s1=1 on a failed assertion
	_r=$1; _hf=0; _pf=0
	[ -e "$UKD/fault.helper" ] && _hf=1
	{ [ -e "$UKD/fault.provd" ] || [ -e "$UKD/provd.env" ]; } && _pf=1
	for _f in /tmp/batman-fault.*; do { [ -e "$_f" ] || [ -L "$_f" ]; } || continue; rm -f "$_f"; ulog "$_r" "seg1 rm $_f"; done
	if [ -e "$UKD" ] || [ -L "$UKD" ]; then rm -rf "$UKD"; ulog "$_r" "seg1 rm -rf $UKD (faults, killpoint, provd.env)"; fi
	if [ -f "$DIR/prov-wbox-254.sh" ]; then
		_o=$( (RUN_ID=$_r lim 180 sh "$DIR/prov-wbox-254.sh" unbind-all) 9>&- 2>&1 | tr '\n' ' ')
		ulog "$_r" "seg1 unbind-all: $_o"
	fi
	# helper / provd back to the release binary, without a test switch (§5.1 "關閉")
	_hp=$(pidof batman-provhelper | awk '{print $1}')
	if [ $_hf = 1 ] || { [ -n "$_hp" ] && ! cmp -s "/proc/$_hp/exe" /rom/usr/bin/batman-provhelper; }; then
		( lim 60 /etc/init.d/batman-provhelper restart >/dev/null 2>&1 ) 9>&-; sleep 3; ulog "$_r" "seg1 helper restarted"
	fi
	_hp=$(pidof batman-provhelper | awk '{print $1}')
	if [ -n "$_hp" ] && cmp -s "/proc/$_hp/exe" /rom/usr/bin/batman-provhelper; then :
	else ulog "$_r" "FAIL seg1 helper (pid ${_hp:-none}) is not the release helper"; _s1=1; fi
	if provd_present; then
		_pp=$(provd_pid)
		if [ $_pf = 1 ] || [ -z "$_pp" ] || ! cmp -s "/proc/$_pp/exe" /rom/usr/bin/batman-provd \
			|| tr '\0' '\n' < "/proc/$_pp/environ" 2>/dev/null | grep -q -E "$PROVD_KEYS"; then
			( provd_restart ) 9>&-; ulog "$_r" "seg1 provd restarted"
			_n=0; while [ $_n -lt 15 ]; do _q=$(provd_pid); [ -n "$_q" ] && [ "$_q" != "$_pp" ] && break; sleep 1; _n=$((_n + 1)); done
		fi
		_pp=$(provd_pid)
		if [ -n "$_pp" ] && cmp -s "/proc/$_pp/exe" /rom/usr/bin/batman-provd && ! tr '\0' '\n' < "/proc/$_pp/environ" 2>/dev/null | grep -q -E "$PROVD_KEYS"; then :
		else ulog "$_r" "FAIL seg1 provd (pid ${_pp:-none}) is not the release provd without test switches"; _s1=1; fi
	fi
	# kill-pg lines of this boot (the group leader's cmdline checked first)
	_me=$(cut -d' ' -f5 /proc/$$/stat)
	for _j in $(ujournals "$_r"); do
		awk '$2=="todo" && $4=="kill-pg" {print $1, $3, $5, $6}' "$_j" > "$_j.kp"
		while read -r _id _b _pg _tag; do
			if ! uvalid "$_r" kill-pg "$_pg" "$_tag"; then ulog "$_r" "CRIT line $_id: kill-pg $_pg $_tag refused"; _s1=1; continue; fi
			if [ "$_b" != "boot:$(bootid)" ]; then umark_done "$_j" "$_id"; ulog "$_r" "seg1 kill-pg $_pg: another boot, void"; continue; fi
			[ "$_pg" = "$_me" ] && { ulog "$_r" "CRIT line $_id: kill-pg of my own group"; _s1=1; continue; }
			if [ -d "/proc/$_pg" ] && tr '\0' ' ' < "/proc/$_pg/cmdline" 2>/dev/null | grep -q -- "$_tag"; then
				if pg_kill "$_pg"; then ulog "$_r" "seg1 kill-pg $_pg ($_tag)"; else ulog "$_r" "FAIL seg1 kill-pg $_pg did not exit"; _s1=1; continue; fi
			else ulog "$_r" "seg1 kill-pg $_pg ($_tag): not running"; fi
			umark_done "$_j" "$_id"
		done < "$_j.kp"
		rm -f "$_j.kp"
	done
}

# ---- stuck host executor (deadman / recover) ------------------------------------------------------------------------
ugroup_alive() { for _s in /proc/[0-9]*/stat; do [ "$(cut -d' ' -f5 "$_s" 2>/dev/null)" = "$1" ] && return 0; done; return 1; }
ukids_alive() {	# <pid>: a direct child that is not a zombie
	for _s in /proc/[0-9]*/stat; do
		_f=$(cut -d' ' -f3,4 "$_s" 2>/dev/null); [ "${_f#* }" = "$1" ] && [ "${_f% *}" != Z ] && return 0
	done; return 1
}
ustop_host() {	# <run>: rc 0 = no host executor left; 1 = it could not be stopped (NEEDS-PERSON)
	_df=$BT/undo-doing.$1; [ -f "$_df" ] || return 0
	read -r _hpid _hpg _hb < "$_df"
	if [ "$_hb" = "$(bootid)" ] && isint "$_hpid" && [ -d "/proc/$_hpid" ] && tr '\0' ' ' < "/proc/$_hpid/cmdline" 2>/dev/null | grep -q 'prov-lease-254.sh undo'; then :
	else rm -f "$_df"; return 0; fi
	_me=$(cut -d' ' -f5 /proc/$$/stat)
	if isint "$_hpg" && [ "$_hpg" -gt 1 ] && [ "$_hpg" != "$_me" ]; then :; else ulog "$1" "FAIL host executor pgid [$_hpg] refused"; return 1; fi
	ulog "$1" "host executor $_hpid (group $_hpg) still running: SIGSTOP, wait for its current tool, TERM the group"
	kill -STOP "$_hpid" 2>/dev/null
	_n=0; while [ $_n -lt "${UNDO_KID_WAIT:-330}" ] && ukids_alive "$_hpid"; do sleep 1; _n=$((_n + 1)); done
	kill -TERM "-$_hpg" 2>/dev/null; kill -CONT "$_hpid" 2>/dev/null
	_n=0; while [ $_n -lt 10 ] && ugroup_alive "$_hpg"; do sleep 1; _n=$((_n + 1)); done
	ugroup_alive "$_hpg" && { ulog "$1" "NEEDS-PERSON host executor group $_hpg did not exit"; return 1; }
	rm -f "$_df"; ulog "$1" "host executor group $_hpg gone"; return 0
}

# ---- segment 2 and the entry point ----------------------------------------------------------------------------------
undo_run() {	# <run> <mode> -> rc 0 = nothing left; 1 = something left / failed (logged)
	_ur=$1; _um=$2; urun_ok "$_ur" || { fail "bad run id"; return 1; }
	_rc=0; _s1=0
	ulog "$_ur" "undo_run $_um start"
	if [ "$_um" = host ]; then
		trap '' HUP PIPE
		echo "$$ $(cut -d' ' -f5 /proc/$$/stat) $(bootid)" > "$BT/undo-doing.$_ur"
	elif ! ustop_host "$_ur"; then
		useg1 "$_ur"; ulog "$_ur" "NEEDS-PERSON segment 2 not run (a host executor is still alive)"; return 1
	fi
	useg1 "$_ur"; [ $_s1 = 0 ] || _rc=1
	if [ -e "$BT/restoring.$_ur" ]; then
		ulog "$_ur" "restoring marker: segment 2 left to pr_restore"
	else
		_slot=$(uslot); _res=$(mktemp "$UJT.res.XXXXXX") || { ulog "$_ur" "FAIL mktemp"; return 1; }
		for _j in $(ujournals "$_ur"); do awk -v j="$_j" '$2=="todo" && $4!="kill-pg" {print $1, j}' "$_j"; done | sort -rn > "$_res.ids"
		while read -r _id _j; do
			set -- $(awk -v id="$_id" '$1==id' "$_j"); _b=$3; shift 3
			uvalid "$_ur" "$@" || { ulog "$_ur" "CRIT line $_id refused: $*"; echo CRIT >> "$_res"; continue; }
			case "$_b" in
			slot:*) [ "$_b" = "slot:$_slot" ] || { ulog "$_ur" "NEEDS-PERSON line $_id ($*) is bound to $_b, running $_slot"; echo LEFT >> "$_res"; continue; } ;;
			boot:*) [ "$_b" = "boot:$(bootid)" ] || { umark_done "$_j" "$_id"; ulog "$_ur" "line $_id ($*): another boot, void"; continue; } ;;
			esac
			if [ "$_um" = host ] && [ "$1" = test-count ] && [ "${3:-}" = stall ]; then
				( uact "$_ur" "$_um" "$@" ) 9>&- </dev/null >/dev/null 2>&1; _xrc=$?	# test hook: a tool that escapes lim
			else
				( lim "$(ubudget "$1")" uact "$_ur" "$_um" "$@" ) 9>&- </dev/null >/dev/null 2>&1; _xrc=$?
			fi
			if [ $_xrc = 0 ]; then umark_done "$_j" "$_id"; ulog "$_ur" "done $_id $*"
			else ulog "$_ur" "FAIL $_id $* (rc $_xrc)"; echo LEFT >> "$_res"; fi
		done < "$_res.ids"
		grep -q . "$_res" && _rc=1; rm -f "$_res" "$_res.ids"
	fi
	# nothing left -> the journals (and the backups) go; anything left stays for P9 / the next preflight
	_left=0; for _j in $(ujournals "$_ur"); do grep -q '^[0-9]* todo ' "$_j" && _left=1; done
	if [ $_left = 0 ]; then
		for _d in "$UJT/$_ur" "$UJP/$_ur"; do [ -d "$_d" ] && { ulog "$_ur" "journal dir $_d removed ($(ls "$_d" | tr '\n' ' '))"; rm -rf "$_d"; }; done; sync
	else _rc=1; ulog "$_ur" "left: $(cat $(ujournals "$_ur") | grep '^[0-9]* todo ' | tr '\n' '|')"; fi
	[ "$_um" = host ] && rm -f "$BT/undo-doing.$_ur"
	ulog "$_ur" "undo_run $_um end rc=$_rc"
	return $_rc
}
# what is left of any run (P9 reads this; the next run's preflight replays it under its own lease)
undo_pending() {
	for _d in "$UJT"/*/ "$UJP"/*/; do
		[ -d "$_d" ] || continue; _pr=$(basename "$_d"); urun_ok "$_pr" || continue
		[ -f "$_d/journal" ] && awk -v r="$_pr" '$2=="todo" {print "UNDO-PENDING " r " " $0}' "$_d/journal"
	done
	return 0
}
undo_runs() { undo_pending | awk '{print $2}' | sort -u; }
