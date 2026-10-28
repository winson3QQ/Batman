#!/bin/sh
# scripts/node/prov-wbox-254.sh — #254 test-helper binds and killpoints on the node (docs/design/254-h23-harness.md
# §3, §4.5). Staged with prov-lease-254.sh; run as  RUN_ID=<run> sh <dir>/prov-wbox-254.sh <cmd>  under the prov lease.
# Helper variants are pushed by the host into W=/tmp/run/batman-dv/wbox/<run>/ (root 0700) and checked by sha here.
#   prep                            create W (an existing W must already be root 0700, not a symlink)
#   bind <file in W> <sha> <dst>    bind-mount W/<file> over <dst> (wbox.list: "bind <dst>")
#   unbind-all                      umount EVERY harness bind (any run: /proc/self/mountinfo root under
#                                   /batman-dv/wbox/), restart the helper when one was armed or bound, rm -rf the
#                                   killpoint dir; prints each step. The deadman and pr_end / pr_abort call it.
#   list                            the harness binds now mounted, wbox.list, the killpoint dir
#   upper-helper <file> <sha>       copy W/<file> to /usr/bin/batman-provhelper (lands in the overlay upper, survives a
#                                   reboot; overlay-restore / the deadman remove it). Refused while any bind is mounted.
#   arm-killpoint <point>           write /tmp/run/batman-prov-test/killpoint (dir root 0700, file 0600)
#   push-helper <file> <sha> [killpoint=<point>]
#                                   killpoint file (if given) -> bind W/<file> over the helper -> ONE restart -> assert:
#                                   `--version` line 2 = the prov_test marker, /proc/<pid>/exe sha = <sha>, and (with a
#                                   killpoint) "killpoint <point>: armed" logged by THIS pid (wbox.list: "armed <point>")
# busybox ash; no bashisms.
SELF=$(readlink -f "$0"); DIR=$(dirname "$SELF")
. "$DIR/ble-lib-254.sh"
RUN_ID=${RUN_ID:-}
WB=/tmp/run/batman-dv/wbox; W=$WB/$RUN_ID; LIST=$W/wbox.list
KD=/tmp/run/batman-prov-test; HB=/usr/bin/batman-provhelper
MARKER=BATMAN_PROV_TEST_BUILD_7f3a

harness_binds() { awk 'index($4, "/batman-dv/wbox/") {print $5}' /proc/self/mountinfo; }   # field 4 = the root inside the tmpfs: /run/batman-dv/wbox/<run>/<file>
hpid() { pidof batman-provhelper | awk '{print $1}'; }
helper_restart() {	# -> new pid on stdout; the old pid must be gone and a new one up within 20 s
	_o=$(hpid); /etc/init.d/batman-provhelper restart >/dev/null 2>&1
	_n=0; while [ $_n -lt 20 ]; do _p=$(hpid); [ -n "$_p" ] && [ "$_p" != "$_o" ] && { echo "$_p"; return 0; }; sleep 1; _n=$((_n + 1)); done
	return 1
}
wdir() {	# W: root 0700, not a symlink; WB likewise (created here only if absent: mkdir without -p)
	for d in "$WB" "$W"; do
		[ -e "$d" ] || mkdir -m 700 "$d" || die "cannot create $d"
		dir_ok "$d" drwx------ || die "$d is not a root 0700 directory (pre-existing / symlink?)"
	done
}
wfile() {	# $1 file name in W, $2 sha -> the checked path
	case "$1" in ''|*/*|.*) die "bad file name [$1]" ;; esac
	f=$W/$1; file_ok "$f" || die "$f is not a root regular file with one link"
	[ "$(sha256sum < "$f" | cut -c1-64)" = "$2" ] || die "$f sha does not match"
	chmod 755 "$f"; echo "$f"
}
kp_write() {	# $1 point
	case "$1" in txn-[1-5]|claim-after-persist|claim-before-shadow) ;; *) die "unknown killpoint [$1]" ;; esac
	if [ -e "$KD" ] || [ -L "$KD" ]; then dir_ok "$KD" drwx------ || die "$KD exists and is not a root 0700 directory"
	else mkdir -m 700 "$KD" || die "cannot create $KD"; fi
	( umask 077; printf '%s\n' "$1" > "$KD/killpoint.tmp" ) && mv "$KD/killpoint.tmp" "$KD/killpoint" || die "cannot write the killpoint file"
	file_ok "$KD/killpoint" && [ "$(ls -ln "$KD/killpoint" | awk '{print $1}')" = "-rw-------" ] || die "killpoint file is not root 0600"
}

c=${1:-}; [ $# -gt 0 ] && shift
[ -n "$RUN_ID" ] || die "RUN_ID unset"; case "$RUN_ID" in *[!A-Za-z0-9_-]*) die "bad RUN_ID" ;; esac
case "$c" in
prep)
	wdir; echo "PREP $W"
	;;
bind)
	[ $# = 3 ] || die "usage: bind <file> <sha> <dst>"
	# the targets the §6.2 units bind over; nothing of the slot-decision code but autocommit (misc dry-run arm), never
	# batman-slot (review r2 A-m5). /etc/banner: the harness smoke test.
	case "$3" in /usr/bin/batman-provhelper|/usr/bin/batman-autocommit|/usr/bin/halow-setkey|/usr/bin/batman-config-save|/etc/banner) ;;
		*) die "bind target $3 is not on the list (provhelper, autocommit, halow-setkey, batman-config-save, banner)" ;; esac
	wdir; f=$(wfile "$1" "$2") || { echo "$f"; exit 1; }
	[ -f "$3" ] && [ ! -L "$3" ] || die "bind target $3 is not a regular file"
	mount --bind "$f" "$3" || die "mount --bind $f $3 failed"
	echo "bind $3" >> "$LIST"; echo "BOUND $3 <- $1"
	;;
unbind-all)
	r=0; restart=0
	[ -f "$LIST" ] && grep -q '^armed ' "$LIST" && restart=1
	for m in $(harness_binds | sort -r); do
		umount "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || { echo "FAIL umount $m"; r=1; continue; }
		echo "UNBOUND $m"; [ "$m" = "$HB" ] && restart=1
	done
	[ -n "$(harness_binds)" ] && { echo "FAIL harness binds left: $(harness_binds | tr '\n' ' ')"; r=1; }
	rm -rf "$KD"
	if [ $restart = 1 ]; then p=$(helper_restart) && echo "HELPER-RESTARTED pid=$p" || { echo "FAIL helper did not come back after the unbind"; r=1; }; fi
	rm -f "$LIST"
	[ $r = 0 ] && echo "UNBIND-ALL ok"; exit $r
	;;
list)
	echo "BINDS $(harness_binds | tr '\n' ' ')"; [ -f "$LIST" ] && sed 's/^/LIST /' "$LIST"
	[ -e "$KD" ] && echo "KILLPOINT-DIR $(ls -A "$KD" | tr '\n' ' ')"; exit 0
	;;
upper-helper)
	[ $# = 2 ] || die "usage: upper-helper <file> <sha>"
	[ -z "$(harness_binds)" ] || die "a harness bind is mounted (upper-helper must come before any bind)"
	wdir; f=$(wfile "$1" "$2") || { echo "$f"; exit 1; }
	cp "$f" "$HB.dvnew" && chmod 755 "$HB.dvnew" && mv "$HB.dvnew" "$HB" && sync || die "copy to $HB failed"
	[ "$(sha256sum < /overlay/upper/usr/bin/batman-provhelper 2>/dev/null | cut -c1-64)" = "$2" ] || die "the copy is not in the upper"
	echo "upper $1" >> "$LIST"; echo "UPPER-HELPER $1 (effective after the next helper start)"
	;;
arm-killpoint)
	[ $# = 1 ] || die "usage: arm-killpoint <point>"; kp_write "$1"; echo "KILLPOINT-FILE $1"
	;;
push-helper)
	[ $# -ge 2 ] || die "usage: push-helper <file> <sha> [killpoint=<point>]"
	wdir; f=$(wfile "$1" "$2") || { echo "$f"; exit 1; }; kp=""
	case "${3:-}" in "") ;; killpoint=*) kp=${3#killpoint=} ;; *) die "bad argument [$3]" ;; esac
	[ -z "$(harness_binds | grep -x "$HB")" ] || die "$HB is already bound"
	[ -n "$kp" ] && kp_write "$kp"
	mount --bind "$f" "$HB" || die "mount --bind over $HB failed"
	echo "bind $HB" >> "$LIST"
	t0=$(date +%s); p=$(helper_restart) || die "helper did not restart"
	v=$("$HB" --version 2>/dev/null | sed -n 2p)
	[ "$v" = "$MARKER" ] || die "--version line 2 is [$v], not the prov_test marker"
	[ "$(sha256sum < "/proc/$p/exe" | cut -c1-64)" = "$2" ] || die "/proc/$p/exe is not the pushed helper"
	if [ -n "$kp" ]; then
		n=0; while [ $n -lt 15 ]; do logread | grep -q "batman-provhelper\[$p\]: killpoint $kp: armed" && break; sleep 1; n=$((n + 1)); done
		[ $n -lt 15 ] || die "pid $p logged no 'killpoint $kp: armed' (log: $(logread | grep "batman-provhelper\[$p\]" | tail -3 | tr '\n' '|'))"
		[ ! -e "$KD/killpoint" ] || die "the killpoint file is still there (the helper did not read it)"
		echo "armed $kp" >> "$LIST"
	fi
	echo "PUSHED $1 pid=$p${kp:+ armed=$kp} (restart at $t0)"
	;;
*) echo "usage: RUN_ID=<run> prov-wbox-254.sh bind|unbind-all|list|upper-helper|arm-killpoint|push-helper ..."; exit 2 ;;
esac
