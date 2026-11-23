#!/bin/sh
# scripts/node/ud9-watch-254.sh — #254 v1.6 group 4 PR B, UD9 (docs/design/254-v16-ud.md §1.5): the position watcher.
# Root, staged with the prov scripts (stage-check sha). Started by prov-update-254.sh in ONE ssh call:
#   setsid sh <staged>/ud9-watch-254.sh <mode> <run> <SQ> <bdev> </dev/null >/dev/null 2>&1 & echo $! > ud9.pid
#   then `prov-lease-254.sh undo-add kill-pg $! ud9-watch`, and only after that `touch ud9.go`.
#   mode  observe | kill | cut      run  the unit's run id      SQ  root.squashfs bytes      bdev  B's root partition
# It never decides PASS / FAIL: it writes result lines in place into /opt/batdata/log/dv-ud9-<run>.log (root 0600,
# pre-sized to 4 KiB of spaces and synced ONCE before any stream exists; each line then `dd conv=notrunc,fsync` of the
# log alone — no global sync after the start) and to syslog (tag ud9-watch):
#   UD9-OBS fd1=<dev> pos=<p1>,<p2>,<p3> sq=<SQ> result=ok|bad       (observe: fd 1 is bdev and pos grows)
#   UD9-FIRE mode=kill pos=<p1> pos_final=<pf> sq=<SQ> orphan=<pid>   (kill: written AFTER the SIGKILL of the helper)
#   UD9-FIRE mode=cut pos=<p1> sq=<SQ> t0=<uptime>  then  UD9-PRE-B pos=<p2> fsync_s=<s>  then a pos re-read p3 with no
#                                                                      I/O before `echo b > /proc/sysrq-trigger`
#   UD9-MISS <why>                                                     (pgid, stop, timeout, gone, late …: no action)
# It acts only on a `dd` started after itself whose parent is a uid-0 `batman-slot write`, with of=/dev/, not
# if=/dev/zero (clear_root's dd), and fd 0 a pipe; once (one-shot); nothing before ud9.go exists; 900 s deadline by
# /proc/uptime, or earlier when ud9.stop appears. A local unprivileged process or uid 471 cannot steer it: the helper
# pid comes from procd (ubus) and is checked by /proc/<pid>/exe and uid 0; its files are root-only.
# UD9_TEST_ROOT (scripts/dv/test-ud9-watch-254.sh only, never set on a node): /proc, the log dir, the run dir and the
# sysrq file are read under it; UD9_KILL and UD9_MYSTART replace kill and the own start time there.
set -u
MODE=${1:-}; RUN=${2:-}; SQ=${3:-}; BDEV=${4:-}
UR=${UD9_TEST_ROOT:-}
PROC=$UR/proc; LOGD=$UR/opt/batdata/log; RD=$UR/tmp/run/batman-dv/$RUN
KILLC=kill; [ -n "$UR" ] && KILLC=${UD9_KILL:-kill}
case "$MODE" in observe|kill|cut) ;; *) echo "usage: ud9-watch-254.sh observe|kill|cut <run> <SQ> <bdev>"; exit 2 ;; esac
case "$RUN" in ''|*[!A-Za-z0-9_-]*) exit 2 ;; esac
case "$SQ" in ''|*[!0-9]*) exit 2 ;; esac
case "$BDEV" in /dev/mmcblk0p[0-9]) ;; *) exit 2 ;; esac
[ -n "$UR" ] || [ "$(id -u)" = 0 ] || exit 2
LATE=$((SQ - 8388608)); HALF=$((SQ / 2))
LOG=$LOGD/dv-ud9-$RUN.log
# centiseconds; the fraction loses one leading 0 first: "08" / "09" are invalid octal in $(( )) (ash and dash), and an
# empty T0 put the 900 s deadline at uptime 900 s
upc() { read -r _u _ < "$PROC/uptime"; _s=${_u%.*}; _c=${_u#*.}; _c=${_c#0}; echo $(( _s * 100 + ${_c:-0} )); }
_n=0
wline() {	# one 128-byte slot in place, fsync of the log only; then syslog
	printf '%-127.127s\n' "$1" | dd of="$LOG" bs=128 seek=$_n count=1 conv=notrunc,fsync 2>/dev/null; _n=$((_n + 1))
	logger -t ud9-watch "$1" 2>/dev/null
	return 0
}
miss() { wline "UD9-MISS $*"; exit 1; }
# a catchable signal leaves its line (device run 2026-11-23 ud36d: the observe watcher vanished during the real write with
# no line at all; SIGKILL — the OOM killer — still leaves none, the host then reads dmesg)
for _sg in HUP INT TERM PIPE USR1 USR2; do trap "wline 'UD9-MISS signal $_sg'; exit 1" "$_sg"; done
# ---- the log first, while no stream exists: pre-sized, one sync, never again
umask 077
[ -d "$LOGD" ] && [ ! -L "$LOGD" ] || exit 3
[ -e "$LOG" ] || [ -L "$LOG" ] && { logger -t ud9-watch "UD9-MISS log exists: $LOG" 2>/dev/null; exit 3; }
dd if=/dev/zero bs=4096 count=1 2>/dev/null | tr '\0' ' ' > "$LOG" || exit 3
sync
# ---- a process-group leader of its own (setsid), so the journal's kill-pg reaches every child
ME=$$; set -- $(cat "/proc/$ME/stat" 2>/dev/null | sed 's/.*) //')
[ "${3:-}" = "$$" ] || miss "pgid pid=$$ pgid=${3:-?}"
MYST=${20:-0}; [ -n "$UR" ] && MYST=${UD9_MYSTART:-$MYST}
T0=$(upc); DL=$((T0 + 90000))
# ---- nothing before ud9.go (registered first); ud9.stop or the deadline end it
while [ ! -e "$RD/ud9.go" ]; do
	[ -e "$RD/ud9.stop" ] && miss "stop before go"
	[ "$(upc)" -ge "$DL" ] && miss "timeout (no ud9.go)"
	sleep 1
done
# ---- find a fresh stream dd by kernel facts
statf() { _x=$(cat "$PROC/$1/stat" 2>/dev/null) || return 1; _x=${_x##*) }; echo "$_x"; }
isdd() {	# <pid>: rc 0 = the stream dd of a uid-0 batman-slot write, started after this watcher; sets PP
	_p=$1; read -r _c < "$PROC/$_p/comm" 2>/dev/null || return 1; [ "$_c" = dd ] || return 1
	set -- $(statf "$_p") || return 1; PP=$2; [ "${20:-0}" -gt "$MYST" ] 2>/dev/null || return 1
	_cl=$(tr '\0' ' ' < "$PROC/$_p/cmdline" 2>/dev/null)
	case "$_cl" in *if=/dev/zero*) return 1 ;; *of=/dev/*) ;; *) return 1 ;; esac
	case "$(readlink "$PROC/$_p/fd/0" 2>/dev/null)" in pipe:*) ;; *) return 1 ;; esac
	_pu=$(sed -n 's/^Uid:[[:space:]]*\([0-9]*\).*/\1/p' "$PROC/$PP/status" 2>/dev/null); [ "$_pu" = 0 ] || return 1
	_pc=$(tr '\0' ' ' < "$PROC/$PP/cmdline" 2>/dev/null)
	case "$_pc" in *batman-slot\ write*) return 0 ;; esac
	return 1
}
pos() {	# <pid>: fdinfo/1 pos, builtins only (no subprocess between the samples)
	_ps=""; while read -r _k _v; do [ "$_k" = pos: ] && { _ps=$_v; break; }; done < "$PROC/$1/fdinfo/1" 2>/dev/null
	echo "$_ps"
}
DD=""
while [ -z "$DD" ]; do
	[ -e "$RD/ud9.stop" ] && miss "stop"
	[ "$(upc)" -ge "$DL" ] && miss "timeout"
	for d in "$PROC"/[0-9]*; do isdd "${d##*/}" && { DD=${d##*/}; break; }; done
done
ORPH=$PP
# kill: the helper pid from procd, checked before the trigger point (no lookup between the trigger and the kill)
if [ "$MODE" = kill ]; then
	HP=$(ubus call service list '{"name":"batman-provhelper"}' 2>/dev/null | sed -n 's/.*"pid":[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1)
	case "$HP" in ''|*[!0-9]*) miss "no helper pid from procd" ;; esac
	[ "$(readlink "$PROC/$HP/exe" 2>/dev/null)" = /usr/bin/batman-provhelper ] || miss "pid $HP is not /usr/bin/batman-provhelper"
	[ "$(sed -n 's/^Uid:[[:space:]]*\([0-9]*\).*/\1/p' "$PROC/$HP/status" 2>/dev/null)" = 0 ] || miss "pid $HP is not uid 0"
fi
if [ "$MODE" = observe ]; then
	F1=$(readlink "$PROC/$DD/fd/1" 2>/dev/null); a=""; last=-1; i=0
	while [ $i -lt 200000 ] && [ -d "$PROC/$DD" ]; do
		p=$(pos "$DD"); i=$((i + 1))
		case "$p" in ''|*[!0-9]*) continue ;; esac
		[ "$p" -gt "$last" ] || continue
		a="$a${a:+,}$p"; last=$p
		[ "$(echo "$a" | tr ',' '\n' | wc -l)" -ge 3 ] && break
	done
	r=bad; [ "$F1" = "$BDEV" ] && [ "$(echo "$a" | tr ',' '\n' | wc -l)" -ge 3 ] && r=ok
	wline "UD9-OBS fd1=${F1:-none} pos=${a:-none} sq=$SQ result=$r"; exit 0
fi
# kill / cut: wait for the middle of the stream
while :; do
	p1=$(pos "$DD")
	case "$p1" in ''|*[!0-9]*) [ -d "$PROC/$DD" ] || miss "gone (the stream ended before SQ/2)"; continue ;; esac
	[ "$p1" -ge "$LATE" ] && miss "late pos=$p1 sq=$SQ"
	[ "$p1" -ge "$HALF" ] && break
	[ -e "$RD/ud9.stop" ] && miss "stop"
done
if [ "$MODE" = kill ]; then
	$KILLC -9 "$HP"
	pf=$p1; while [ -d "$PROC/$DD" ]; do q=$(pos "$DD"); case "$q" in ''|*[!0-9]*) ;; *) pf=$q ;; esac; done
	wline "UD9-FIRE mode=kill pos=$p1 pos_final=$pf sq=$SQ orphan=$ORPH dd=$DD"
	exit 0
fi
# cut
u0=$(upc); wline "UD9-FIRE mode=cut pos=$p1 sq=$SQ t0=$u0"; u1=$(upc)
p2=$(pos "$DD"); case "$p2" in ''|*[!0-9]*) p2=none ;; esac
d=$((u1 - u0)); wline "UD9-PRE-B pos=$p2 fsync_s=$((d / 100)).$((d % 100 / 10))$((d % 10))"
p3=""; while read -r _k _v; do [ "$_k" = pos: ] && { p3=$_v; break; }; done < "$PROC/$DD/fdinfo/1" 2>/dev/null
case "$p3" in ''|*[!0-9]*) miss "late p3=none" ;; esac
[ "$p3" -ge "$LATE" ] && miss "late p3=$p3"
echo b > "$UR/proc/sysrq-trigger"
exit 0
