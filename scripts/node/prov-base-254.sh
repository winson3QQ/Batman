#!/bin/sh
# scripts/node/prov-base-254.sh — #254 PR-H2 baseline snapshot / compare / restore on the node
# (docs/design/254-p1-impl.md §4.5). Runs as root via `ssh node sh -s -- <cmd> <run_id>`; the host side
# (scripts/dv/prov-254.sh) owns reboots, waits and slot moves. busybox ash; no bashisms.
#
#   snap <run>          record S0: p5 image + file manifest, the committed slot's overlay (tar + manifest + uci export),
#                       p6 state files (content or "absent"), marker, dirty flag
#   manifest <run> <tag> write the CURRENT manifests to <run>/now-<tag>/ (no snapshot needed)
#   compare <run> <tag> compare <run>/now-<tag>/ with the snapshot; prints DIFF lines; rc 0 = none
#   p5-restore <run>    dd the p5 image back under the config-save lock, verify sha uncached
#   overlay-restore <run> write the snapshot tar over the live upper, delete extras, restore p6 state
#   strip-p5-prov <run> (prov-legacy-upgrade only) delete p5 prov.* and identity/prov, the rest unchanged (§4.5.6)
#   state-set <run> ble-ok present|absent  (autocommit (8) only) helper stopped or in a trial; the snapshot restores it
#   finish <run>        after a passing compare: print and remove snapshot, marker, dirty flag
# PROV_BASE_SKIP=p5 | extra (the prov-base-254 unit's negative controls only, 254-h23 §6.2): p5-restore writes
# nothing / overlay-restore keeps the extras; each prints a SKIP line, and the following compare must FAIL.
# The config-save lock is held by a process whose argv contains "batman-config-save" (F34: config-save
# takes over a lock whose holder's cmdline does not match), and only while joinwatch / helper are stopped.
set -u
CMD=${1:-}; RUN=${2:-}
case "$RUN" in ''|*[!A-Za-z0-9_-]*) echo "FAIL bad run id"; exit 2 ;; esac
[ "${#RUN}" -le 40 ] || { echo "FAIL run id too long"; exit 2; }
[ "$(id -u)" = 0 ] || { echo "FAIL root only"; exit 2; }
BASE=${PROV_BASE_TEST_ROOT:-}/opt/batdata/dv-prov; D=$BASE/$RUN; ST=${PROV_BASE_TEST_ROOT:-}/opt/batdata/state
# the config-save lock lives in the root-only run dir: resolved through rundir.sh (#280), fail-closed when absent.
# PROV_BASE_TEST_ROOT (CI / WSL tests only, never set on a node) prefixes the library path too.
RDL=${PROV_BASE_TEST_ROOT:-}/usr/lib/batman/rundir.sh
# shellcheck source=/dev/null
[ -r "$RDL" ] && . "$RDL" || { echo "FAIL no $RDL (pre-#280 image)"; exit 2; }
LOCK=$RUNDIR/cfgsave.lock; P5=/dev/mmcblk0p5
DVD=$RUNDIR-dv   # harness scratch next to the run dir: /tmp/run/batman-dv (root 0755 /tmp/run, procd)
DIRTY=$ST/dv-prov-dirty; MARK=/etc/.dv-prov-mark-$RUN
STATEFILES="lock-status mesh-expected mesh-joined prov-state prov-counters ble-ok ota-armed.mesh autocommit-hold-commit autocommit-hold-once autocommit-skip-once bad-slot"
HOLDER=$DVD/batman-config-save-dvhold
umask 077
say() { echo "$*"; }
die() { echo "FAIL $*"; exit 1; }
bootid() { cut -c1-8 /proc/sys/kernel/random/boot_id; }

lock_take() {
	mkdir -p "$DVD"
	# the holder must KEEP its own argv: config-save takes the lock over from a holder whose cmdline lacks
	# "batman-config-save" (F34-lock). `exec sleep` replaced it with "sleep 1800" (E1c dry run on 04, 2026-10-21).
	printf '#!/bin/sh\n# holder of the config-save lock for prov-base-254 (name must contain batman-config-save)\nwhile :; do sleep 5; done\n' > "$HOLDER"
	chmod 700 "$HOLDER"
	i=0; until mkdir "$LOCK" 2>/dev/null; do
		i=$((i + 1)); [ "$i" -ge 30 ] && die "config-save lock busy for 30 s (pid $(cat "$LOCK/pid" 2>/dev/null))"; sleep 1
	done
	# plain `&` (no setsid: a forking setsid would make $! the wrong pid); the child's cmdline only becomes
	# "sh .../batman-config-save-dvhold" once it has exec'd, so the check retries (2026-10-23: p5-restore on 04
	# read the parent shell's cmdline right after the fork and died)
	"$HOLDER" </dev/null >/dev/null 2>&1 &
	HPID=$!
	echo "$HPID" > "$LOCK/pid"; cut -d. -f1 /proc/uptime > "$LOCK/uptime"
	i=0; until tr '\0' ' ' < "/proc/$HPID/cmdline" 2>/dev/null | grep -q batman-config-save; do
		i=$((i + 1)); [ "$i" -ge 4 ] && { rm -rf "$LOCK"; kill "$HPID" 2>/dev/null; die "lock holder cmdline does not match ($(tr '\0' ' ' < "/proc/$HPID/cmdline" 2>/dev/null))"; }
		sleep 1
	done
}
lock_drop() { [ -n "${HPID:-}" ] || return 0; kill "$HPID" 2>/dev/null; rm -rf "$LOCK"; HPID=""; }   # only a lock WE hold

svc() {	# $1 stop|start, rest = services that exist
	a=$1; shift
	for s in "$@"; do [ -x "/etc/init.d/$s" ] && "/etc/init.d/$s" "$a" >/dev/null 2>&1; done; return 0
}

# --- manifests -------------------------------------------------------------------------------------
# one line per entry: <type> <mode> <uid:gid> <sha|target|rdev> <path>; sorted; path relative to the root
tree_manifest() {	# $1 root dir
	( cd "$1" || exit 1
	  # busybox here has no stat / comm (02 probe 2026-10-21): type, mode, owner come from `ls -lnd`
	  # review A-m10: a line is "<fields> <path>" and readers take the LAST field, so a name with a space / tab / newline
	  # would be read as another path (overlay-restore would rm -rf it). Such a name is a BADNAME line and rc 3 (fail-closed).
	  find . -mindepth 1 2>/dev/null | sort | { bad=0; while IFS= read -r p; do
		case "$p" in ./*) ;; *) echo "BADNAME ${p#./}"; bad=1; continue ;; esac   # the tail of a name with a newline
		case "$p" in *" "*|*"	"*) echo "BADNAME ${p#./}"; bad=1; continue ;; esac
		[ -e "$p" ] || [ -L "$p" ] || { echo "BADNAME ${p#./}"; bad=1; continue; }   # the head of a name with a newline
		set -- $(ls -lnd "$p" 2>/dev/null); m="$1 $3:$4"
		case "$1" in
			-*) h=$(sha256sum < "$p" | cut -c1-64) ;;
			l*) h="->$(readlink "$p")" ;;
			c*|b*) h="dev=$5$6" ;;
			*) h="-" ;;
		esac
		echo "$m $h ${p#./}"
	  done; [ "$bad" = 0 ]; } )
}
uci_exports() {	# normalised: `uci export` per config file, in name order
	for f in $(ls /etc/config 2>/dev/null | sort); do echo "=== $f"; uci -q export "$f" 2>/dev/null; done
}
p5_manifest() {	# $1 out file; mounts p5 ro,noload
	m=$(mktemp -d "$DVD/p5ro.XXXXXX") || return 1
	mount -t ext4 -o ro,noload "$P5" "$m" 2>/dev/null || { rmdir "$m"; return 1; }
	tree_manifest "$m" > "$1"; r=$?
	umount "$m"; rmdir "$m"; return $r
}
state_record() {	# $1 out dir
	mkdir -p "$1"
	for f in $STATEFILES; do
		if [ -e "$ST/$f" ]; then cp -p "$ST/$f" "$1/$f"; else : > "$1/$f.absent"; fi
	done
}
manifests_to() {	# $1 out dir
	mkdir -p "$1"
	p5_manifest "$1/p5.manifest" || echo "p5 unreadable" > "$1/p5.manifest"
	tree_manifest /overlay/upper > "$1/upper.manifest" || die "upper: $(grep -c '^BADNAME' "$1/upper.manifest") path name(s) with whitespace or a newline (BADNAME lines in $1/upper.manifest) — a manifest line cannot represent them (review A-m10)"
	uci_exports > "$1/uci.export"
	state_record "$1/state"
	{ echo "slot=$(batman-slot active)"; echo "ver=$(sed -n 's/^BATMAN_VERSION=//p' /etc/batman-build)"
	  echo "hostkey=$(for k in /etc/dropbear/dropbear_*_host_key; do dropbearkey -y -f "$k" 2>/dev/null | sed -n 's/^Fingerprint: //p'; done | sort | tr '\n' ' ')"
	  echo "ahwlan=$(uci -q get network.ahwlan.ipaddr)"; echo "dhcpconfigured=$(uci -q get openmanetd.config.dhcpconfigured)"
	  echo "protB=$(cat "$ST/slot-B.protected" 2>/dev/null)"; } > "$1/identity"
}

# state_cmp <name> <snap file> <now file>: prints nothing when equal under the file's rule, else "snap=.. now=..".
# Files that carry a boot_id cannot be byte-equal after any reboot (round-7 B-M6), so each has an explicit rule:
#   prov-state      "<boot_id> <writer> <lks> <verdict> <members> <mesh_expect>": field 1 dropped (rewritten every boot)
#   ble-ok          content = the boot_id of the last boot with a healthy BLE stack: presence only
#   ota-armed.mesh  "<arm boot> <slot> <mode>": autocommit CONSUMES it at its decision (present -> absent is allowed);
#                   it must never appear, and when both exist slot + mode must match
#   everything else whole-file sha (prefix only in the output)
state_cmp() {
	a=absent; b=absent
	case "$1" in
	prov-state|ota-armed.mesh)
		[ -e "$2" ] && a="$(cut -d' ' -f2- "$2" | head -n 1)"
		[ -e "$3" ] && b="$(cut -d' ' -f2- "$3" | head -n 1)"
		[ "$1" = ota-armed.mesh ] && [ -e "$2" ] && [ ! -e "$3" ] && return 0 ;;
	ble-ok)
		[ -e "$2" ] && a=present; [ -e "$3" ] && b=present ;;
	*)
		[ -e "$2" ] && a=$(sha256sum < "$2" | cut -c1-16); [ -e "$3" ] && b=$(sha256sum < "$3" | cut -c1-16) ;;
	esac
	[ "$a" = "$b" ] || echo "snap=[$a] now=[$b]"
}

case "$CMD" in
snap)
	[ ! -e "$D" ] || die "snapshot $D already exists"
	# a snap that dies part-way removes what it created and restarts joinwatch (unless told to keep it stopped)
	trap 'if [ "${SNAP_DONE:-0}" != 1 ]; then [ -d "$D" ] && { echo "snap failed: removing partial $D: $(ls "$D" | tr "\n" " ")"; rm -rf "$D"; rm -f "$MARK"; }; lock_drop; [ "${KEEP_JOINWATCH_STOPPED:-0}" = 1 ] || svc start joinwatch; fi' EXIT
	[ ! -e "$DIRTY" ] || die "dirty flag present: $(cat "$DIRTY")"
	SL=$(batman-slot active); case "$SL" in A|B) ;; *) die "active slot unreadable [$SL]" ;; esac   # either slot (#254 claim-lock: the rc lands on B)
	batman-slot is-trial >/dev/null 2>&1; [ $? = 1 ] || die "slot $SL is not committed"
	mkdir -p "$D" && chmod 700 "$BASE" "$D"
	svc stop joinwatch
	lock_take
	p5_manifest "$D/p5.manifest" || { lock_drop; svc start joinwatch; die "p5 not mountable ro"; }
	dd if="$P5" of="$D/p5.img" bs=1M 2>/dev/null || { lock_drop; svc start joinwatch; die "p5 dd failed"; }
	sha256sum < "$D/p5.img" | cut -c1-64 > "$D/p5.img.sha"
	: > "$MARK"; chmod 600 "$MARK"			# before the overlay record: the manifest includes it (A-m10)
	tar -C /overlay/upper -cf "$D/upper.tar" . 2>"$D/tar.err" || { lock_drop; svc start joinwatch; die "upper tar failed: $(head -2 "$D/tar.err")"; }
	manifests_to "$D/snap"
	echo "$RUN $(bootid) snap" > "$DIRTY"; sync
	SNAP_DONE=1
	lock_drop
	[ "${KEEP_JOINWATCH_STOPPED:-0}" = 1 ] || svc start joinwatch
	say "SNAP $RUN p5=$(cat "$D/p5.img.sha" | cut -c1-16) upper_entries=$(wc -l < "$D/snap/upper.manifest") tar=$(wc -c < "$D/upper.tar")B"
	;;
manifest)
	TAG=${3:-x}; case "$TAG" in *[!A-Za-z0-9_-]*) die "bad tag" ;; esac
	[ -d "$D/snap" ] || die "no snapshot $RUN"
	rm -rf "$D/now-$TAG"; manifests_to "$D/now-$TAG"; say "MANIFEST $RUN $TAG"
	;;
compare)
	TAG=${3:-x}; [ -d "$D/now-$TAG" ] || die "no manifest now-$TAG"
	ALLOW=${ALLOW_FILE:-$DVD/overlay-allow.txt}
	n=0
	# allow-list (tests/prov-p1/overlay-allow.txt, pushed by the host): "<kind> <ERE on the relative path> # evidence"
	# kind content = the entry may differ in content/mode but must exist in both; kind exists = may appear/vanish
	AC=$(awk '!/^#/ && $1=="content" {printf "%s%s", s, $2; s="|"}' "$ALLOW" 2>/dev/null)
	AE=$(awk '!/^#/ && $1=="exists"  {printf "%s%s", s, $2; s="|"}' "$ALLOW" 2>/dev/null)
	mkdir -p "$DVD" && T=$(mktemp -d "$DVD/cmp.XXXXXX") && : > "$T/d" || die "compare: cannot write under $DVD (fail-closed, round-8 A-m12)"
	for f in p5.manifest upper.manifest uci.export identity; do
		# set difference without comm: "- " = only in the snapshot, "+ " = only now (multiset-aware)
		awk 'NR==FNR{a[$0]++; next} {if (a[$0]) a[$0]--; else print "+ " $0} END{for (k in a) for (i=0;i<a[k];i++) print "- " k}' \
			"$D/snap/$f" "$D/now-$TAG/$f" | sort -k2 > "$T/d" || die "compare: diff of $f failed (fail-closed)"
		[ -f "$D/snap/$f" ] && [ -f "$D/now-$TAG/$f" ] || die "compare: $f missing on one side (fail-closed)"
		if [ "$f" = upper.manifest ]; then
			# an allowed path drops out only when the rule allows the kind of difference seen
			awk -v AC="${AC:-^$}" -v AE="${AE:-^$}" '
				{ p=$NF; side=$1; seen[p]=seen[p] side; line[NR]=$0; path[NR]=p }
				END { for (i=1;i<=NR;i++) { p=path[i]
					both=(index(seen[p],"+") && index(seen[p],"-"))
					if (AE != "^$" && p ~ AE) continue
					if (both && AC != "^$" && p ~ AC) continue
					print line[i] } }' "$T/d" > "$T/e"
			mv "$T/e" "$T/d"
		fi
		[ -s "$T/d" ] && { sed "s|^|DIFF $f |" "$T/d"; n=$((n + $(wc -l < "$T/d"))); }
	done
	rm -rf "$T"
	for f in $STATEFILES; do
		d=$(state_cmp "$f" "$D/snap/state/$f" "$D/now-$TAG/state/$f")
		[ -z "$d" ] || { echo "DIFF state $f $d"; n=$((n + 1)); }
	done
	say "COMPARE $RUN $TAG diffs=$n"; [ "$n" = 0 ]
	;;
p5-restore)
	[ -f "$D/p5.img" ] || die "no p5 image"
	want=$(cat "$D/p5.img.sha"); [ "$(sha256sum < "$D/p5.img" | cut -c1-64)" = "$want" ] || die "snapshot image sha mismatch"
	svc stop joinwatch batman-provhelper batman-provd
	if [ "${PROV_BASE_SKIP:-}" = p5 ]; then say "SKIP p5 write (PROV_BASE_SKIP=p5, negative control)"; say "P5-RESTORED $RUN sha=SKIPPED"; exit 0; fi
	lock_take
	grep -q "^$P5 " /proc/mounts && { lock_drop; die "p5 is mounted"; }
	dd if="$D/p5.img" of="$P5" bs=1M conv=fsync 2>/dev/null || { lock_drop; die "p5 dd write failed"; }
	sz=$(wc -c < "$D/p5.img"); mb=$(( sz / 1048576 ))
	# uncached read-back, same method as batman-slot raw_read_mb (direct I/O, else drop caches first)
	got=$( { dd if="$P5" bs=1M count="$mb" iflag=direct 2>/dev/null || { echo 3 > /proc/sys/vm/drop_caches; dd if="$P5" bs=1M count="$mb" 2>/dev/null; }; } | sha256sum | cut -c1-64)
	lock_drop
	[ "$got" = "$want" ] || die "p5 read-back sha $got != $want"
	say "P5-RESTORED $RUN sha=$(echo "$want" | cut -c1-16)"
	;;
overlay-restore)
	[ -f "$D/upper.tar" ] || die "no upper tar"
	sl=$(sed -n 's/^slot=//p' "$D/snap/identity"); [ -n "$sl" ] && [ "$(batman-slot active)" = "$sl" ] || die "not on the snapshot's slot [$sl] (active $(batman-slot active)) — the live upper is another slot's"
	svc stop joinwatch batman-provhelper batman-provd openmanetd tailscale tailscaled cron uhttpd dockerd
	tar -C /overlay/upper -xpf "$D/upper.tar" 2>"$D/untar.err" || die "untar failed: $(head -2 "$D/untar.err")"
	# delete what the snapshot did not have (printed first), except allow-listed paths
	tree_manifest /overlay/upper > /tmp/run/batman-dv/now.manifest || die "overlay-restore: path name(s) with whitespace or a newline in the upper: $(grep -c '^BADNAME' /tmp/run/batman-dv/now.manifest) — extras are NOT removed by name (review A-m10)"
	awk '{print $NF}' /tmp/run/batman-dv/now.manifest > /tmp/run/batman-dv/now.paths
	awk '{print $NF}' "$D/snap/upper.manifest" > /tmp/run/batman-dv/snap.paths
	if [ "${PROV_BASE_SKIP:-}" = extra ]; then say "SKIP extra removal (PROV_BASE_SKIP=extra, negative control)"; else
	awk 'NR==FNR{s[$0]=1; next} !($0 in s)' /tmp/run/batman-dv/snap.paths /tmp/run/batman-dv/now.paths | sort -r | while IFS= read -r p; do
		echo "EXTRA-REMOVED $p"; rm -rf "/overlay/upper/$p"
	done; fi
	for f in $STATEFILES; do
		if [ -e "$D/snap/state/$f" ]; then cp -p "$D/snap/state/$f" "$ST/$f"; else rm -f "$ST/$f"; fi
	done
	sync; echo 3 > /proc/sys/vm/drop_caches
	say "OVERLAY-RESTORED $RUN (reboot now)"
	;;
strip-p5-prov)
	# 254-p1-impl §4.5.6, prov-legacy-upgrade-254 only: a pre-P1 p5 made from this one — ro check prov.meta is there,
	# delete ONLY prov.* and identity/prov/, ro assert both gone and every other entry unchanged. Inside a snapshotted
	# unit (the restore puts p5 back), under the config-save lock, helper / provd / joinwatch stopped.
	[ -d "$D/snap" ] || die "no snapshot $RUN (strip-p5-prov only inside a snapshotted unit)"
	svc stop joinwatch batman-provhelper batman-provd
	lock_take
	grep -q "^$P5 " /proc/mounts && { lock_drop; die "p5 is mounted"; }
	m=$(mktemp -d "$DVD/p5w.XXXXXX") || { lock_drop; die "no temp dir"; }
	mount -t ext4 -o ro,noload "$P5" "$m" 2>/dev/null || { rmdir "$m"; lock_drop; die "p5 not mountable ro"; }
	[ -f "$m/prov.meta" ] || { umount "$m"; rmdir "$m"; lock_drop; die "p5 has no prov.meta (nothing to strip)"; }
	others(){ ( cd "$1" && find . | grep -v -e '^\./prov\.' -e '^\./identity/prov$' -e '^\./identity/prov/' | sort ); }
	b4=$(others "$m"); umount "$m"
	mount -t ext4 "$P5" "$m" 2>/dev/null || { rmdir "$m"; lock_drop; die "p5 not mountable rw"; }
	echo "STRIP $(cd "$m" && ls -d prov.* identity/prov 2>/dev/null | tr '\n' ' ')"
	rm -f "$m"/prov.*; rm -rf "$m/identity/prov"; sync; umount "$m"
	mount -t ext4 -o ro,noload "$P5" "$m" 2>/dev/null || { rmdir "$m"; lock_drop; die "p5 not mountable ro after the strip"; }
	left=$(cd "$m" && ls -d prov.* identity/prov 2>/dev/null | tr '\n' ' '); af=$(others "$m"); umount "$m"; rmdir "$m"
	lock_drop
	svc start batman-provhelper joinwatch
	[ -z "$left" ] || die "still on p5 after the strip: $left"
	[ "$af" = "$b4" ] || die "the strip changed other p5 entries"
	say "STRIPPED $RUN (prov.* and identity/prov gone, $(echo "$b4" | wc -l) other entries unchanged)"
	;;
state-set)
	# autocommit (8) only (254-h23 §4.4 p6 ble-ok row): set or drop a p6 state file the harness may steer. Only inside a
	# unit (the snapshot puts it back) and only where nothing writes it back: the helper writes ble-ok on a committed
	# slot (F14), so there it must be stopped first; a trial never writes it.
	[ -d "$D" ] || die "no snapshot (state-set only inside a unit)"
	f=${3:-}; v=${4:-}
	case "$f" in ble-ok) ;; *) die "state-set: $f is not settable" ;; esac
	if batman-slot is-trial >/dev/null 2>&1; then :
	elif pidof batman-provhelper >/dev/null 2>&1; then die "state-set: the helper runs on a committed slot (it would write $f back) — stop it first"; fi
	case "$v" in
	absent) rm -f "$ST/$f" ;;
	present) cat /proc/sys/kernel/random/boot_id > "$ST/$f.dv" && mv "$ST/$f.dv" "$ST/$f" ;;
	*) die "state-set: value must be present|absent" ;;
	esac
	sync; [ "$v" = absent ] && [ -e "$ST/$f" ] && die "state-set: $f still there"
	say "STATE-SET $f=$v"
	;;
finish)
	[ -d "$D" ] || die "no snapshot"
	echo "removing: $(ls "$D" | tr '\n' ' ') $MARK $DIRTY"
	rm -rf "$D"; rm -f "$MARK" "$DIRTY"; sync; say "FINISHED $RUN"
	;;
*) echo "usage: prov-base-254.sh snap|manifest|compare|p5-restore|overlay-restore|strip-p5-prov|state-set|finish <run_id> [tag]"; exit 2 ;;
esac
