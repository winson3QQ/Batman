#!/bin/bash
# tests/prov-p1/cfgsave-stage-enospc.sh <batman-config-save> — WSL/CI root (loop device, device-mapper for the EIO cases).
# docs/design/cfgsave-stage-enospc.md: a save that cannot be written completely must never be reported as saved, and
# must never leave a 0-byte file on p5. Black box: the REAL script (paths substituted only, as cfgsave-txn-save.sh; two
# test hooks inserted at comment anchors), under busybox sh with busybox's file tools (the node's), against a real ext4
# formatted like the image build (scripts/build-ab-image.sh: mkfs.ext4 -b 4096 -L batconfig). Each case: --seed OLD,
# live config -> NEW, then one fault:
#   K = 0..12 free 4 KiB blocks (p5 filled, probed ENOSPC, K blocks freed);
#   a read-only remount after staging (hook 1, before the publish);
#   dm `error` (all I/O) at hook 1, also after a 6 s pause (a journal commit lands between staging and the error);
#   dm-flakey error_writes at hook 1 with --nolockfs (the stage data is still dirty: it fails at writeback);
#   dm-flakey error_writes at hook 2 (after the stage fsync, before the renames: only the journal / metadata fail);
#   data blocks only: every block FREE after the seed fails writes, the journal and the metadata are fine (loaded
#   before the run; review A E4);
#   modes --on-join, --save, --if-healthy (+ --save --promote-lkg and a first --seed on an unseeded full p5).
# PASS per case: EITHER "saved" + rc 0 + p5 == NEW (overrides, schema, lkg per mode, every identity file) and the boot
# reader (96's own valid_batch + Lane-B selection, extracted verbatim) picks NEW and --check says fresh; OR no "saved",
# rc 15, the LAST stderr line is the "p5 NOT saved" explanation (and says "unchanged", never "PARTLY", when p5 did not
# change), every p5 file byte-identical to before (a stage left on a read-only / failing device is reported, not
# judged), the reader picks OLD, --check says stale, no on-join cache, and the next --on-join tick does not skip as
# "unchanged". Never a 0-byte file (other than .seeded) outside a leftover stage, in either branch.
# Further cases: --check with a full run dir -> rc 5 "unverifiable"; the --on-join backoff after a failed save (one
# attempt per 300 s, no rw mount while backing off); a stale .stage.<pid> / .wprobe / .wprobe.<pid> removed by the next
# save (a .wprobe DIRECTORY: only the cleanup removes it); on the no-lock path (RDOK=0, no cleanup) a .wprobe symlink
# to a file outside p5 is never written through, and a .wprobe directory or an immutable .wprobe file (a stand-in for
# another lock-less writer's probe) does not fail the save; two real concurrent lock-less saves never give the false
# "p5 refuses writes" text; the
# on-join cache dropped by a failed save; values with a newline / CR -> rc 6 (the rest saved) or skipped (ssid);
# white-box: a staged batch the boot reader would reject -> rc 15 with its own message. Lint: batch_ok awk == 96's.
# Round 3 (review A-r2 / B-r2): a read-only remount / write errors after the FIRST rename (hook 3) -> "may be PARTLY",
# every p5 file the OLD or the NEW copy; no fsync tool -> rc 15, p5 unchanged; an incomplete stage list (hook 4) -> rc
# 15 before any rename; an immutable stage file (its rm in the cleanup must fail) -> the explanation is still the last
# stderr line (deterministic control); --check whose ro mount fails after a failed save -> rc 5; a CR is kept (rc 0).
# Round 4 (review B-r3): --check on an ext4 p5 that does not mount read-only -> rc 5 with or without a failed save; on
# a p5 whose superblock cannot be read (dm `error`) -> rc 5 (--prov-get rc 1), with or without the marker; a readable
# non-ext4 p5 still gives rc 3 (--prov-get 12).
# Round 5 (review B-r4 MAJOR-1 / MINOR-1, A-r4 F1): a HEALTHY p5 that is busy — mounted rw elsewhere (fresh and stale
# variants: the true verdict through that mount, never "unverifiable"), mounted ro elsewhere, mounted at a path that
# cannot be compared (rc 5 "busy … could not be compared"), a concurrent save holding the lock (rc 8); the "does not
# mount" text carries the mount error; --seed refuses an unreadable superblock (no mkfs) but formats a zeroed p5.
# Round 6 (review A-r5 / B-r5): a tmpfs stacked on the other mountpoint and a non-p5 fs mounted with p5's NAME as its
# source (p5 itself corrupt) never give a verdict from the wrong fs; a p5 held only by a subdirectory bind has its own
# rc 5 text. Harness: one instance per host (flock on /run/cfgsave-stage-enospc.lock, bounded wait, then FAIL); the dm
# device is named after this run's own mktemp dir; udevadm settle before every mkfs / dm switch; a case whose device is
# still mounted FAILs with the evidence (mountinfo, holders, fuser); mkfs is retried (bounded) only while the device is
# NOT mounted in our namespace; teardown removes the dm device with --retry and FAILs loudly ("LEAK") if the dm device
# or the loop survives. CFGSAVE_TEST_LEAK=1 (test of the test) keeps the device open at exit to show the LEAK FAIL.
# The whole test runs in its own PRIVATE mount namespace (it re-execs itself under `unshare -m --propagation private`):
# a process that creates a mount namespace while one of our mounts exists would otherwise copy that mount and hold the
# device ("in use by the system" at the next mkfs; seen twice, design §8). No unshare: FAIL with CFGSAVE_REQUIRE_DM=1.
# CFGSAVE_REQUIRE_DM=1 (CI, scripts/test-prov-p1-stubs.sh): no device-mapper or no flakey target is a FAIL; otherwise
# the EIO cases are skipped with a note. CFGSAVE_BB=<cmd> runs the script and its applets under another busybox (for
# example the node's aarch64 build under qemu-user).
# Negative controls: 4eba26d (pre-fix) and 6d65ecd (round 1) FAIL the cases listed in the design §8. Zero cases run =
# FAIL; a loop device or a filled p5 that cannot be set up = FAIL.
set -u
fail=0; pass=0; skip=""
okk(){ pass=$((pass + 1)); echo "ok   $*"; }; bad(){ fail=$((fail + 1)); echo "FAIL $*"; }
die(){ echo "FAIL setup: $*"; echo "PASS=$pass FAIL=$((fail + 1))"; exit 1; }
[ "$(id -u)" = 0 ] || die "needs root (loop device)"
[ $# -ge 1 ] && [ -f "$1" ] || die "usage: cfgsave-stage-enospc.sh <batman-config-save>"
if [ "${CFGSAVE_PRIVATE_NS:-}" != 1 ]; then
	if command -v unshare >/dev/null 2>&1; then
		export CFGSAVE_PRIVATE_NS=1; exec unshare -m --propagation private bash "$0" "$@"
		die "unshare -m --propagation private failed"
	fi
	[ "${CFGSAVE_REQUIRE_DM:-0}" = 1 ] && die "CFGSAVE_REQUIRE_DM=1: no unshare — this test must run in its own private mount namespace"
	echo "note: no unshare: running in the host mount namespace (another process can copy our mounts and hold the device)"
else
	[ "$(readlink /proc/self/ns/mnt)" != "$(readlink /proc/1/ns/mnt)" ] || die "CFGSAVE_PRIVATE_NS=1 but this is the host mount namespace"
	echo "private mount namespace $(readlink /proc/self/ns/mnt) (host $(readlink /proc/1/ns/mnt))"
fi
for c in losetup mkfs.ext4 dumpe2fs busybox mount umount truncate stat; do command -v $c >/dev/null 2>&1 || die "missing host tool $c"; done
CSIN=$(readlink -f "$1")
SRC=${PROV_SRC:-$(cd "$(dirname "$CSIN")/../.." && pwd)}   # files/ of the product tree
F96=$SRC/etc/uci-defaults/96-batman-config-migrate
[ -f "$F96" ] && [ -f "$SRC/usr/lib/batman/rundir.sh" ] && [ -f "$SRC/usr/lib/batman/prov-lock.sh" ] || die "product tree $SRC lacks 96 / rundir.sh / prov-lock.sh"
BB=${CFGSAVE_BB:-busybox}
# one instance per host: dm / loop devices and the udev queue are host-wide (review A-r5 F2 / B-r5 MINOR-4)
LOCKF=/run/cfgsave-stage-enospc.lock
exec 9>>"$LOCKF" || die "cannot open the host lock $LOCKF"
lw=$(date +%s); flock -w "${CFGSAVE_LOCK_WAIT:-1800}" 9 || die "another instance holds $LOCKF for more than ${CFGSAVE_LOCK_WAIT:-1800} s"
echo "host lock $LOCKF taken after $(( $(date +%s) - lw )) s"
settle(){ command -v udevadm >/dev/null 2>&1 && udevadm settle 2>/dev/null; return 0; }
W=$(mktemp -d); LOOP=""; DMN=""
# teardown: settle (udev probes a new fs right after mkfs and holds the device: a plain remove gets EBUSY, review A-r5
# F1), remove with --retry, then PROVE the dm device and the loop are gone; a leak is a loud FAIL, never silent
cleanup(){
	grep " $W/" /proc/mounts | cut -d' ' -f2 | sort -r | xargs -r -n1 umount 2>/dev/null
	leak=""
	if [ -n "$DMN" ]; then settle; dmsetup resume "$DMN" 2>/dev/null; dmsetup remove --retry "$DMN" >/dev/null 2>&1; settle
		dmsetup info "$DMN" >/dev/null 2>&1 && leak="$leak dm:$DMN($(dmsetup info -c --noheadings -o open "$DMN" 2>/dev/null | tr -d ' ') open)"; fi
	[ -z "$LOOP" ] || losetup -d "$LOOP" 2>/dev/null
	[ -z "$(losetup -j "$W/p5.img" 2>/dev/null)" ] || leak="$leak loop:$(losetup -j "$W/p5.img" | cut -d: -f1 | tr '\n' ' ')"
	if grep -q " $W/" /proc/mounts; then leak="$leak mounts:$(grep " $W/" /proc/mounts | cut -d' ' -f2 | tr '\n' ' ')"; else rm -rf "$W"; fi
	if [ -n "$leak" ]; then echo "FAIL teardown: LEAK$leak — left on the host"; echo "PASS=$pass FAIL=$((fail + 1))"; exit 1; fi
}
trap cleanup EXIT
truncate -s 16M $W/p5.img; LOOP=$(losetup -f --show $W/p5.img) || die "losetup"
[ -b "$LOOP" ] || die "no loop block device"
SECT=$(( $(stat -c %s $W/p5.img) / 512 ))
DEV=$LOOP
# named after this run's own mktemp dir: unique across concurrent runs and PID namespaces ($$ is not; review A-r5 F2)
if command -v dmsetup >/dev/null 2>&1 && dmsetup create "cfgenospc-$(basename "$W")" --table "0 $SECT linear $LOOP 0" 2>/dev/null; then
	DMN=cfgenospc-$(basename "$W"); DEV=/dev/mapper/$DMN; settle; [ -b "$DEV" ] || die "dm device $DEV missing"
else skip="no device-mapper on this host (dmsetup create failed): the EIO cases are NOT run"; fi
FLAKEY=0; if [ -n "$DMN" ]; then modprobe dm_flakey 2>/dev/null; dmsetup targets 2>/dev/null | grep -q '^flakey' && FLAKEY=1; fi
[ -z "$DMN" ] || [ "$FLAKEY" = 1 ] || skip="no dm-flakey target: the write-only EIO cases are NOT run"
if [ -n "$skip" ]; then
	[ "${CFGSAVE_REQUIRE_DM:-0}" = 1 ] && die "CFGSAVE_REQUIRE_DM=1: $skip"
	echo "note: $skip"
fi
# load first (it only fills the inactive table), then suspend + resume; resume on any failure: a device left SUSPENDED
# hangs every later I/O, the EXIT trap included (review A-r2 F7)
dmtab(){ settle; dmsetup load "$DMN" --table "0 $SECT $1" && dmsetup suspend "$DMN" && dmsetup resume "$DMN" || { dmsetup resume "$DMN" 2>/dev/null; return 1; }; }
mkdir -p $W/prov $W/m $W/bin $W/sbin/cs-wb $W/run $W/dropbear $W/openmanet $W/uci.over; chmod 755 $W/run; chmod 700 $W/prov
# the node's file tools: busybox applets (the product runs busybox ash + busybox coreutils). The node's busybox has an
# `fsync` applet (CONFIG_FSYNC=y); a busybox without one gets a shim running the same syscall (coreutils `sync FILE`).
for a in cp mv mkdir find rm cat cmp grep sed awk head cut tr sha256sum hexdump mktemp ls rmdir chmod sort wc sync id tail od df fsync; do
	if $BB $a --help >/dev/null 2>&1 || [ "$a" != fsync ]; then printf '#!/bin/sh\nexec %s %s "$@"\n' "$BB" "$a" > $W/bin/$a
	else printf '#!/bin/sh\nexec /bin/sync -- "$@"\n' > $W/bin/$a; echo "note: $BB has no fsync applet: shim = coreutils sync FILE (fsync)"; fi
	chmod +x $W/bin/$a
done
cat > $W/bin/uci <<EOF
#!/bin/sh
for k; do :; done
[ -f "$W/uci.over/\$k" ] && { cat "$W/uci.over/\$k"; exit 0; }
awk -v k="\$k=" 'index(\$0, k) == 1 { print substr(\$0, length(k) + 1); f = 1; exit } END { exit !f }' $W/uci.db
EOF
printf '#!/bin/sh\necho "HEALTH    [OK] OK — joined"\n' > $W/bin/halow-status
chmod +x $W/bin/uci $W/bin/halow-status
sed "s#^RUNDIR=/tmp/run/batman#RUNDIR=$W/run/batman#" "$SRC/usr/lib/batman/rundir.sh" > $W/rundir.sh
# hook 1: after staging, before the publish (anchor: the txn re-check comment). hook 2: right before the first rename
# (anchor: the publish comment; 4eba26d spells it "# identity files: renamed from the stage").
sed -e "s#^DEV=/dev/mmcblk0p5#DEV=$DEV#" -e "s#^PROVD=/etc/batman-prov#PROVD=$W/prov#" \
	-e "s#/usr/lib/batman/prov-lock.sh#$SRC/usr/lib/batman/prov-lock.sh#g" -e "s#/usr/lib/batman/rundir.sh#$W/rundir.sh#g" \
	-e "s#/etc/dropbear/#$W/dropbear/#g" -e "s#/etc/openmanet/#$W/openmanet/#g" -e "s#/etc/shadow#$W/shadow#g" \
	-e '/^# txn sequence re-check, right before the p5 write/i [ -n "${CS_TEST_HOOK:-}" ] \&\& eval "$CS_TEST_HOOK"' \
	-E -e '/^# (publish: )?identity files:? renamed from the stage/i [ -n "${CS_TEST_HOOK2:-}" ] \&\& eval "$CS_TEST_HOOK2"' \
	-e '/^mv "\$STAGE\/overrides.uci" "\$MNT\/overrides.uci"/i [ -n "${CS_TEST_HOOK3:-}" ] \&\& eval "$CS_TEST_HOOK3"' \
	-e '/^# fsync every stage file BEFORE the first rename/i [ -n "${CS_TEST_HOOK4:-}" ] \&\& eval "$CS_TEST_HOOK4"' "$CSIN" > $W/sbin/batman-config-save
# hooks 1-3 have anchors in every version (4eba26d included); hook 4 (before the stage fsync) only where there is one
for h in CS_TEST_HOOK: CS_TEST_HOOK2 CS_TEST_HOOK3; do grep -q "\${$h" $W/sbin/batman-config-save || die "could not insert test hook ${h%:} (anchor gone)"; done
H4OK=0; grep -q 'CS_TEST_HOOK4' $W/sbin/batman-config-save && H4OK=1
export PATH=$W/bin:/usr/sbin:/usr/bin:/sbin:/bin
PRESERVE=$(sed -n '/^PRESERVE="$/,/^"$/p' "$CSIN" | sed '1d;$d')
[ -n "$PRESERVE" ] || die "no PRESERVE list in $CSIN"
CSX=$W/sbin/batman-config-save
cs(){ $BB sh $CSX "$@"; }
# live config generation <tag>: uci values, root hash, identity files (the host key and config.yml change too)
live(){ cat > $W/uci.db <<EOF
system.@system[0].hostname=node$1
wireless.default_radio1.mesh_id=mesh-$1
wireless.default_radio1.key=meshkey-$1-0123456789
wireless.default_radio0.key=apkey-$1-0123456789
wireless.default_radio0.ssid=ap-$1
wireless.radio1.channel=28
wireless.radio1.country=US
network.ahwlan.ipaddr=10.41.7.${2:-5}
network.ahwlan.proto=static
openmanetd.config.dhcpconfigured=1
openmanetd.config.roipconfigured=0
dhcp.lan.start=100
EOF
	head -c 83 /dev/urandom > $W/dropbear/dropbear_ed25519_host_key; head -c 805 /dev/urandom > $W/dropbear/dropbear_rsa_host_key
	echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIenospctest$1 dv@cfgsave-stage-enospc" > $W/dropbear/authorized_keys
	printf 'node:\n  name: %s\n' "$1" > $W/openmanet/config.yml
	echo "root:\$6\$saltsalt\$HASH$1:20000:0:99999:7:::" > $W/shadow
	for t in $PRESERVE; do v=$(uci -q get "$t") && [ -n "$v" ] && printf "set %s='%s'\n" "$t" "$v"; done > $W/expect.$1
}
DEVMM=$(ls -lnL "$DEV" | awk '{ sub(/,$/, "", $5); print $5 ":" $6; exit }')
devmounted(){ awk -v d="$DEVMM" '$3 == d' /proc/self/mountinfo; }
# evidence for a setup failure (review A-r5 F2 / B-r5 MINOR-4): who holds or mounts the device
evidence(){
	echo "  evidence for $DEV ($DEVMM):"
	[ -z "$DMN" ] || dmsetup info -c "$DMN" 2>&1 | sed 's/^/    dmsetup: /'
	echo "    holders: $(ls /sys/block/"$(basename "$(readlink -f "$DEV")")"/holders 2>/dev/null | tr '\n' ' ')"
	devmounted | sed 's/^/    mountinfo: /'
	echo "    mountinfo of pids: $(grep -l " $DEVMM " /proc/[0-9]*/mountinfo 2>/dev/null | head -5 | tr '\n' ' ')"
	command -v fuser >/dev/null 2>&1 && fuser -vm "$DEV" 2>&1 | sed 's/^/    fuser: /'
	return 0
}
# before each case: the device must not be mounted (a leftover mount is a product or test bug: FAIL that case with evidence)
devfree(){ [ -z "$(devmounted)" ] && return 0; echo "  $DEV is still MOUNTED at the start of a case:"; evidence; return 1; }
# mkfs with a bounded retry, ONLY while the device is not mounted in our namespace (a transient exclusive hold, e.g. udev's
# probe); a mount of it here FAILs at once, so the retry cannot hide an umount bug
mkfs_p5(){ local i=0
	while :; do settle
		mkfs.ext4 -q -F -b 4096 -L batconfig $DEV 2> $W/mkfs.err && return 0
		devfree || return 1
		i=$((i + 1)); [ $i -ge 15 ] && { echo "  mkfs failed 15x: $(tail -1 $W/mkfs.err)"; evidence; return 1; }
		echo "note: mkfs on $DEV failed ($(tail -1 $W/mkfs.err)); not mounted here: retry $i/15 in 2 s"; sleep 2
	done; }
mnt(){ mount -t ext4 "$@" $DEV $W/m || { evidence; return 1; }; }
hashes(){ ( cd $W/m && find . -path ./lost+found -prune -o -type f -print | LC_ALL=C sort | while IFS= read -r f; do echo "$(sha256sum < "$f" | cut -c1-16) $(wc -c < "$f") $f"; done; find . -path ./lost+found -prune -o -type d -print | LC_ALL=C sort ); }
# the boot reader: 96's own valid_batch() and Lane-B selection block, verbatim, against the mounted p5 -> the fragment it applies
reader(){ (
	ALLOWED_PKGS="system wireless network openmanetd mesh11sd"; SUPPORTED_SCHEMA=1; MNT=$W/m
	vb=$(sed -n '/^valid_batch() {/,/^}/p' "$F96"); sel=$(sed -n '/^schema=\$(cat "\$MNT\/schema_version"/,/^fi$/p' "$F96")
	[ -n "$vb" ] && [ -n "$sel" ] || { echo "READER-NOT-FOUND"; exit; }
	eval "$vb"; eval "$sel"
	[ -f "$MNT/.seeded" ] || { echo "unseeded"; exit; }
	[ -n "$FRAG" ] || { echo "none"; exit; }
	echo "$SRC"; cat "$FRAG"
) }
# fill <K>: leave exactly K usable 4 KiB blocks (root's view; ext4's own reserved clusters are not usable)
fill(){
	mnt || return 1
	i=0; while [ $i -lt 64 ]; do dd if=/dev/zero of=$W/m/f.$i bs=4k count=1 2>/dev/null || break; i=$((i + 1)); done; sync
	dd if=/dev/zero of=$W/m/big bs=64k 2>/dev/null; sync
	for r in 1 2 3; do j=0; while dd if=/dev/zero of=$W/m/g.$r.$j bs=4k count=1 conv=fsync 2>/dev/null; do j=$((j + 1)); done; rm -f $W/m/g.$r.$j; sync; done
	pr=fits; head -c 1 /dev/zero > $W/m/probe 2>/dev/null && sync && [ -s $W/m/probe ] || pr=ENOSPC; rm -f $W/m/probe; sync
	k=0; while [ $k -lt "$1" ]; do rm -f $W/m/f.$k; k=$((k + 1)); done; sync; umount $W/m
	[ "$pr" = ENOSPC ] && [ "$i" = 64 ]
}
# datafail: a dm table where every block that is FREE now fails writes (error_writes), everything else linear (review A E4)
datafail_table(){
	fr=$(dumpe2fs $DEV 2>/dev/null | sed -n 's/^  *Free blocks: //p' | tr ',' '\n' | tr -d ' ' | grep .)
	[ -n "$fr" ] || return 1
	: > $W/tab; pos=0
	for r in $fr; do case $r in *-*) a=${r%-*}; b=${r#*-} ;; *) a=$r; b=$r ;; esac
		[ "$a" -gt "$pos" ] && echo "$((pos * 8)) $(((a - pos) * 8)) linear $LOOP $((pos * 8))" >> $W/tab
		echo "$((a * 8)) $(((b - a + 1) * 8)) flakey $LOOP $((a * 8)) 0 3600 1 error_writes" >> $W/tab; pos=$((b + 1)); done
	[ $((pos * 8)) -lt $SECT ] && echo "$((pos * 8)) $((SECT - pos * 8)) linear $LOOP $((pos * 8))" >> $W/tab
	dmsetup load $DMN $W/tab && dmsetup suspend $DMN && dmsetup resume $DMN || { dmsetup resume $DMN 2>/dev/null; return 1; }
}
restore_dev(){ grep " $W/run/" /proc/mounts | cut -d' ' -f2 | xargs -r -n1 umount -l 2>/dev/null; dmtab "linear $LOOP 0"; }
lastline_ok(){ tail -1 $W/err | grep -q 'p5 NOT saved'; }
# the directories the last stderr line says it could not remove, and the directories a hash diff added: they must be
# the SAME set, and the diff must add nothing else (review of cdee8b0, B-3)
listed_dirs(){ tail -1 $W/err | sed -n 's/.*could not remove: *//p' | sed 's/[;(].*//' | tr ' ' '\n' | grep . | sort; }
dirs_only_listed(){	# <diff lines> -> rc 0 if they only add directories and exactly the listed ones
	printf '%s\n' "$1" | grep . | grep -qv '^> \./' && return 1
	[ "$(printf '%s\n' "$1" | sed -n 's|^> \./||p' | sort)" = "$(listed_dirs)" ] && [ -n "$(listed_dirs)" ]
}
# one case: <label> <seed: 1 = seeded OLD first, 0 = unseeded> <kind> <mode...>
NCASE=0
case_run(){
	local label=$1 seeded=$2 kind=$3; shift 3; NCASE=$((NCASE + 1))
	devfree || { bad "$label: setup: $DEV still mounted"; return; }; mkfs_p5 || { bad "$label: setup mkfs"; return; }
	rm -rf $W/run/batman
	live OLD 5
	if [ "$seeded" = 1 ]; then o=$(cs --seed 2>&1) && echo "$o" | grep -q 'saved (--seed)' || { bad "$label: setup --seed OLD: $(echo "$o" | tail -1)"; return; }; fi
	rm -rf $W/run/batman   # a fresh boot: no on-join cache, no counters
	live NEW 9
	hook=":"; hook2=":"
	NLF="dmsetup load $DMN --table '0 $SECT flakey $LOOP 0 0 3600 1 error_writes' && dmsetup suspend --nolockfs --noflush $DMN && dmsetup resume $DMN || dmsetup resume $DMN"
	case "$kind" in
		ok|datafail) ;;
		ro) hook='mount -o remount,ro "$MNT"' ;;
		eio) hook="dmsetup load $DMN --table '0 $SECT error' && dmsetup suspend --noflush $DMN && dmsetup resume $DMN || dmsetup resume $DMN" ;;
		eio6) hook="sleep 6; dmsetup load $DMN --table '0 $SECT error' && dmsetup suspend --noflush $DMN && dmsetup resume $DMN || dmsetup resume $DMN" ;;
		eiow) hook=$NLF ;;
		eiowp) hook2=$NLF ;;
		*) fill "$kind" || { bad "$label: setup could not fill p5 to $kind free blocks"; return; } ;;
	esac
	mnt -o ro || { bad "$label: setup mount"; return; }; h0=$(hashes); umount $W/m
	if [ "$kind" = datafail ]; then datafail_table || { restore_dev; bad "$label: setup datafail table"; return; }; fi
	CS_TEST_HOOK=$hook CS_TEST_HOOK2=$hook2 cs "$@" > $W/out 2> $W/err; rc=$?
	case "$kind" in eio*|datafail) restore_dev || { bad "$label: dm table restore"; return; } ;; esac
	mnt -o ro || { bad "$label: mount after the run failed"; return; }
	h1=$(hashes); rd=$(reader)
	zero=$(cd $W/m && find . \( -path ./lost+found -o -path './.stage.*' \) -prune -o -type f -size 0 ! -name .seeded -print | tr '\n' ' ')
	stage=$(cd $W/m && ls -d .stage.* .wprobe* 2>/dev/null | tr '\n' ' ')
	stgleft=$(cd $W/m && ls -d .stage.* 2>/dev/null | tr '\n' ' ')
	why=""
	[ -z "$zero" ] || why="$why 0-byte:[$zero]"
	if grep -q "saved ($1)" $W/out; then
		v=saved
		[ "$rc" = 0 ] || why="$why saved-but-rc=$rc"
		cmp -s $W/m/overrides.uci $W/expect.NEW || why="$why overrides!=NEW"
		[ "$(cat $W/m/schema_version 2>/dev/null)" = 1 ] || why="$why schema!=1"
		for f in dropbear/dropbear_ed25519_host_key dropbear/dropbear_rsa_host_key dropbear/authorized_keys openmanet/config.yml; do cmp -s $W/$f $W/m/identity/$f || why="$why identity/$f!=live"; done
		cmp -s $W/shadow $W/m/identity/shadow-root || why="$why shadow-root!=live"
		case "$*" in --save) want=OLD ;; *) want=NEW ;; esac
		[ "$seeded" = 0 ] && want=NEW
		cmp -s $W/m/lkg/overrides.uci $W/expect.$want || why="$why lkg!=$want"
		[ "$rd" = "overrides.uci@1
$(cat $W/expect.NEW)" ] || why="$why reader!=NEW[$(echo "$rd" | head -2 | tr '\n' '|')]"
		[ -z "$stage" ] || why="$why stage-left:[$stage]"
	else
		v="not-saved"
		[ "$rc" = 15 ] || why="$why rc=$rc(want 15)"
		lastline_ok || why="$why last-stderr-line:[$(tail -1 $W/err | cut -c1-80)]"
		# a stage left on p5 must be named in the text (review of a87baa3, A-3). Not judged where the product cannot know:
		# on the final-sync path (STAGE is cleared before the probe) and on a device with I/O errors (eio*, datafail): there
		# `rm -rf` of the stage returns 0 in memory and the removal never reaches the card (seen: eio6 x3, the stage was
		# committed before the error), so the leftover appears only after a remount (design §3)
		case "$kind" in eio*|datafail) stgleft="" ;; esac
		if [ -n "$stgleft" ] && ! tail -1 $W/err | grep -q 'p5 refuses writes now' && ! tail -1 $W/err | grep -q 'its stage \.stage\.'; then
			why="$why stage-left-but-not-named:[$stgleft]"; fi
		# a read-only or failing device cannot have its stage removed: that leftover is reported, not judged
		case "$kind" in ro|eio*|datafail) h1=$(echo "$h1" | grep -v '\./\.stage\.') ;; esac
		# after a journal abort a rename that returned 0 may not be on the card: eio* / datafail may say "may be PARTLY"
		# with p5 unchanged (review A-r2 F1); a read-only remount keeps every completed rename, so ro may not
		if [ "$h1" = "$h0" ]; then case "$kind:$(tail -1 $W/err)" in eio*:*"may be PARTLY"*|datafail:*"may be PARTLY"*) ;; *PARTLY*) why="$why says-PARTLY-but-p5-unchanged" ;; esac
		else	# the one accepted change: empty directories this run made and could not remove (an I/O error), when the text
			# names them (CI run of PR #381: a first --seed whose rename failed on a journal abort); anything else FAILs
			dd=$(diff <(echo "$h0") <(echo "$h1") | grep '^[<>]')
			if ! tail -1 $W/err | grep -q 'except empty directories it could not remove' || ! dirs_only_listed "$dd"; then
				why="$why p5-changed:[$(echo "$dd" | head -4 | tr '\n' '|')] listed:[$(listed_dirs | tr '\n' ' ')]"; fi
		fi
		if [ "$seeded" = 1 ]; then [ "$rd" = "overrides.uci@1
$(cat $W/expect.OLD)" ] || why="$why reader!=OLD[$(echo "$rd" | head -2 | tr '\n' '|')]"
		else [ "$rd" = unseeded ] || why="$why reader!=unseeded[$rd]"; fi
		[ ! -e $W/run/batman/cfgsave-onjoin.state ] || why="$why on-join-cache-recorded"
	fi
	umount $W/m
	if [ "$seeded" = 1 ]; then
		o=$(cs --check 2>&1); crc=$?
		case "$v:$crc" in saved:0|not-saved:5) ;; *) why="$why --check-rc=$crc" ;; esac
		if [ "$v" = not-saved ] && [ "$1" = --on-join ]; then
			case "$kind" in eio*|datafail) ;; *) o=$(cs --on-join 2>&1); echo "$o" | grep -q 'unchanged (--on-join' && why="$why next-tick-skipped[$(echo "$o" | tail -1)]" ;; esac
		fi
	fi
	if [ -z "$why" ]; then okk "$label: $v rc=$rc$([ -n "$stage" ] && echo " (left on the $kind device: $stage)")$([ "$v" = not-saved ] && echo " :: $(tail -1 $W/err | sed 's/^batman-config-save: //' | cut -c1-110)")"
	else bad "$label: $v rc=$rc ::$why :: out=[$(tr '\n' ' ' < $W/out | cut -c1-120)] err=[$(tail -1 $W/err | cut -c1-160)]"; fi
}
# setup for the stand-alone cases: fresh p5 seeded OLD, live NEW, fresh run dir
fresh(){ devfree || return 1; mkfs_p5 || return 1; rm -rf $W/run/batman $W/uci.over/*; live OLD 5; cs --seed >/dev/null 2>&1 || return 1; rm -rf $W/run/batman; live NEW 9; }
mcount(){ dumpe2fs -h $DEV 2>/dev/null | sed -n 's/^Mount count: *//p'; }
# ---- lint: the stage check is the reader's own ---------------------------------------------------------------------
awkof(){ sed -n "/^$2() {/,/^}/p" "$1" | sed -n "/awk/,/' \"\$1\"/p" | sed '1d;$d'; }
a96=$(awkof "$F96" valid_batch); acs=$(awkof "$CSIN" batch_ok)
if [ -n "$a96" ] && [ "$a96" = "$acs" ]; then okk "lint: batch_ok awk == 96 valid_batch awk ($(echo "$a96" | wc -l) lines)"; else bad "lint: config-save has no batch_ok identical to 96's valid_batch awk"; fi
# ---- fault matrix ---------------------------------------------------------------------------------------------------
for m in --on-join --save --if-healthy; do
	case_run "$m control (room)" 1 ok $m
	for k in 0 1 2 3 4 5 6 7 8 9 10 11 12; do case_run "$m K=$k" 1 $k $m; done
	case_run "$m read-only after staging" 1 ro $m
	if [ -n "$DMN" ]; then
		case_run "$m EIO (all I/O) after staging" 1 eio $m
		case_run "$m EIO (all I/O) after staging + 6 s" 1 eio6 $m
	fi
	if [ "$FLAKEY" = 1 ]; then
		case_run "$m EIO (writes only, stage still dirty) after staging" 1 eiow $m
		case_run "$m EIO (writes only) after the stage fsync, before the renames" 1 eiowp $m
		case_run "$m data blocks only fail (journal + metadata fine)" 1 datafail $m
	fi
done
for k in 1 4 8; do case_run "--save --promote-lkg K=$k" 1 $k --save --promote-lkg; done
[ "$FLAKEY" = 1 ] && case_run "--save --promote-lkg data blocks only fail" 1 datafail --save --promote-lkg
for k in 0 2 5 9 12; do case_run "--seed (unseeded p5) K=$k" 0 $k --seed; done
[ "$FLAKEY" = 1 ] && case_run "--seed (unseeded p5) data blocks only fail" 0 datafail --seed
case_run "--seed (unseeded p5) control" 0 ok --seed
NCASE=$((NCASE + 1))
# ---- --check with a full run dir: rc 5 "unverifiable" (the OTA gate blocks on 5; review A-F2) -----------------------
if fresh; then
	mount -t tmpfs -o size=256k,mode=755 tmpfs $W/run && mkdir -m 700 $W/run/batman && dd if=/dev/zero of=$W/run/fill bs=4k 2>/dev/null
	o=$(cs --check 2>&1); r=$?
	umount $W/run
	[ "$r" = 5 ] && echo "$o" | grep -q 'p5 stale: unverifiable' && okk "--check, run dir full: rc 5 [$(echo "$o" | tail -1)]" || bad "--check, run dir full: rc $r [$(echo "$o" | tail -1)] (want 5 'p5 stale: unverifiable')"
	o=$(cs --check 2>&1); r=$?; [ "$r" = 5 ] && okk "control: --check with room says stale (live NEW, p5 OLD) rc 5" || bad "control --check rc $r"
else bad "--check run-dir-full: setup"; fi
NCASE=$((NCASE + 1))
# ---- --on-join backoff after a failed save (review B MAJOR-1): one attempt per 300 s, no rw mount while backing off ---
if fresh && fill 0; then
	o=$(cs --on-join 2>&1); r1=$?; mc1=$(mcount)
	o2=$(cs --on-join 2>&1); r2=$?; mc2=$(mcount)
	sf=$W/run/batman/cfgsave-save.failed
	if [ -f $sf ]; then read -r t s < $sf; echo "$((t - 301)) $s" > $sf; fi
	o3=$(cs --on-join 2>&1); r3=$?; mc3=$(mcount)
	[ "$r1" = 15 ] && [ "$r2" = 1 ] && echo "$o2" | grep -q 'backing off' && [ "$mc2" = "$mc1" ] && [ "$r3" = 15 ] && [ "$mc3" -gt "$mc2" ] \
		&& okk "--on-join backoff: tick 1 rc 15, tick 2 rc 1 backing off (no mount: count $mc1 -> $mc2), after 300 s tick 3 tries again (rc 15, count $mc3)" \
		|| bad "--on-join backoff: rc $r1/$r2/$r3 mounts $mc1/$mc2/$mc3 :: tick 2 [$(echo "$o2" | tail -1)]"
	mnt && rm -f $W/m/big && umount $W/m
	o=$(cs --save 2>&1); r=$?
	[ "$r" = 0 ] && [ ! -e $sf ] && o=$(cs --on-join 2>&1) && ! echo "$o" | grep -q 'backing off' \
		&& okk "--on-join backoff: a successful --save clears it, the next tick runs [$(echo "$o" | tail -1)]" || bad "--on-join backoff not cleared by a successful save: rc $r [$(echo "$o" | tail -1)]"
else bad "--on-join backoff: setup"; fi
NCASE=$((NCASE + 1))
# ---- a stale .stage.<pid> / .wprobe.<pid> is removed by the next save (review A-F9 / B MAJOR-1) ----------------------
if fresh && mnt; then
	# .wprobe as a DIRECTORY (an old leftover; the probe uses new random names): only the cleanup at the rw mount removes
	# it (review of cdee8b0, A-2: dropping "$MNT"/.wprobe from that cleanup must FAIL this case)
	mkdir -p $W/m/.stage.99999/identity $W/m/.wprobe && dd if=/dev/zero of=$W/m/.stage.99999/identity/junk bs=4k count=40 2>/dev/null && : > $W/m/.wprobe.99999 && : > $W/m/.wprobe/x; umount $W/m
	if fill 0; then
		o=$(cs --save 2>&1); r=$?
		mnt -o ro; left=$(cd $W/m && ls -d .stage.* .wprobe* 2>/dev/null | tr '\n' ' '); ov=$(cmp -s $W/m/overrides.uci $W/expect.NEW && echo NEW || echo not-NEW); umount $W/m
		[ "$r" = 0 ] && [ -z "$left" ] && [ "$ov" = NEW ] && okk "stale .stage.99999 (40 blocks) + .wprobe/ + .wprobe.99999 on a full p5: removed, the save fits (rc 0, p5 NEW)" \
			|| bad "stale stage: rc $r left=[$left] overrides $ov [$(echo "$o" | tail -1)]"
	else bad "stale stage: fill"; fi
else bad "stale stage: setup"; fi
NCASE=$((NCASE + 1))
# a read-only run leaves its stage behind; the next save (room) removes it: stages never pile up
if fresh; then
	CS_TEST_HOOK='mount -o remount,ro "$MNT"' cs --save >/dev/null 2>&1
	mnt -o ro; l1=$(cd $W/m && ls -d .stage.* 2>/dev/null | tr '\n' ' '); umount $W/m
	o=$(cs --save 2>&1); r=$?
	mnt -o ro; l2=$(cd $W/m && ls -d .stage.* 2>/dev/null | tr '\n' ' '); umount $W/m
	[ -n "$l1" ] && [ -z "$l2" ] && [ "$r" = 0 ] && okk "a ro run left [$l1]; the next save removed it (rc 0)" || bad "stage pile-up: after ro [$l1], after the next save [$l2] rc $r"
else bad "stage pile-up: setup"; fi
NCASE=$((NCASE + 1))
# ---- the on-join cache is dropped by a failed save (review B MINOR-2) ------------------------------------------------
if fresh; then
	live OLD 5; o=$(cs --on-join 2>&1); c1=$([ -f $W/run/batman/cfgsave-onjoin.state ] && echo y || echo n)
	live NEW 9; fill 0 || bad "on-join cache: fill"
	o=$(cs --on-join 2>&1); r=$?; c2=$([ -f $W/run/batman/cfgsave-onjoin.state ] && echo y || echo n)
	[ "$c1" = y ] && [ "$r" = 15 ] && [ "$c2" = n ] && okk "on-join cache: written by a good tick, removed by the failed one (rc 15)" || bad "on-join cache: before=$c1 failed-tick rc $r after=$c2"
else bad "on-join cache: setup"; fi
# ---- values with a newline / CR: rc 6, the value reported, the rest saved; an ssid is skipped (review A-F5 / B MINOR-1)
nlcase(){	# <label> <key> <value printf format> <want rc> <want check rc>
	NCASE=$((NCASE + 1))
	fresh || { bad "$1: setup"; return; }
	grep -vF "set $2=" $W/expect.NEW > $W/expect.NL
	printf "$3" > "$W/uci.over/$2"
	o=$(cs --save 2>&1); r=$?
	mnt -o ro; ov=$(cmp -s $W/m/overrides.uci $W/expect.NL && echo ok || echo bad); rd=$(reader | head -1); umount $W/m
	o2=$(cs --check 2>&1); r2=$?
	rm -f "$W/uci.over/$2"
	rep=y; [ "$4" = 6 ] && { echo "$o" | grep 'cannot persist' | grep -qF "$2" || rep=n; }
	[ "$r" = "$4" ] && [ "$ov" = ok ] && [ "$rd" = overrides.uci@1 ] && [ "$r2" = "$5" ] && [ "$rep" = y ] \
		&& okk "$1: --save rc $r, the rest saved, reader overrides@1, --check rc $r2" || bad "$1: --save rc $r (want $4) overrides=$ov reader=$rd reported=$rep --check rc $r2 (want $5) [$(echo "$o" | tail -1 | cut -c1-120)]"
}
nlcase "hostname with a newline" 'system.@system[0].hostname' 'node\nNEW' 6 5
# a CR is kept (review A-r2 F2: uci stores and restores it, valid_batch accepts the line): rc 0, the byte saved as is
NCASE=$((NCASE + 1))
if fresh; then
	printf 'meshkey-NEW\r' > "$W/uci.over/wireless.default_radio1.key"
	sed "s/^set wireless.default_radio1.key=.*/set wireless.default_radio1.key='meshkey-NEW$(printf '\r')'/" $W/expect.NEW > $W/expect.CR
	o=$(cs --save 2>&1); r=$?
	mnt -o ro; ov=$(cmp -s $W/m/overrides.uci $W/expect.CR && echo ok || echo bad); rd=$(reader | head -1); cr=$(grep -c "$(printf '\r')" $W/m/overrides.uci); umount $W/m
	o2=$(cs --check 2>&1); r2=$?; rm -f "$W/uci.over/wireless.default_radio1.key"
	[ "$r" = 0 ] && [ "$ov" = ok ] && [ "$cr" = 1 ] && [ "$rd" = overrides.uci@1 ] && [ "$r2" = 0 ] \
		&& okk "mesh key with a CR: --save rc 0, the CR byte saved as is, reader overrides@1, --check rc 0" || bad "mesh key with a CR: --save rc $r overrides=$ov cr-lines=$cr reader=$rd --check rc $r2 [$(echo "$o" | tail -1 | cut -c1-100)]"
else bad "CR case: setup"; fi
nlcase "ssid with a newline (skipped like any UNSAFE ssid)" 'wireless.default_radio0.ssid' 'ap\nNEW' 0 0
# ---- white-box: a staged batch the boot reader would reject -> rc 15 with its own message, p5 unchanged --------------
NCASE=$((NCASE + 1))
sed 's/^network\.ahwlan\.proto$/&\ndhcp.lan.start/' $W/sbin/batman-config-save > $W/sbin/cs-wb/batman-config-save
if ! cmp -s $W/sbin/batman-config-save $W/sbin/cs-wb/batman-config-save && fresh; then
	mnt -o ro; h0=$(hashes); umount $W/m
	CSX=$W/sbin/cs-wb/batman-config-save; o=$(cs --save 2>$W/err); r=$?; CSX=$W/sbin/batman-config-save
	mnt -o ro; h1=$(hashes); umount $W/m
	[ "$r" = 15 ] && tail -1 $W/err | grep -q "boot reader" && [ "$h1" = "$h0" ] && okk "white-box: a PRESERVE key outside 96's packages -> rc 15 [$(tail -1 $W/err | cut -c21-120)], p5 unchanged" \
		|| bad "white-box batch_ok: rc $r p5 $([ "$h1" = "$h0" ] && echo unchanged || echo CHANGED) [$(tail -1 $W/err | cut -c1-140)]"
else bad "white-box batch_ok: setup (PRESERVE anchor network.ahwlan.proto gone?)"; fi
# ---- a fault after the FIRST rename (hook 3): "may be PARTLY", every p5 file the OLD or the NEW copy (review A-r2 F1) --
# each identity file / overrides / schema on p5 is byte-identical to the OLD or the NEW copy; never a 0-byte file
oldnew(){	# -> "" when every published file is OLD or NEW, else the offenders
	for f in identity/dropbear/dropbear_ed25519_host_key identity/dropbear/dropbear_rsa_host_key identity/dropbear/authorized_keys identity/openmanet/config.yml identity/shadow-root overrides.uci lkg/overrides.uci schema_version; do
		cmp -s $W/m/$f $W/old/$f || cmp -s $W/m/$f $W/new/$f || printf '%s ' "$f"; done; }
snap(){ mkdir -p $W/$1/identity/dropbear $W/$1/identity/openmanet $W/$1/lkg; cp $W/dropbear/* $W/$1/identity/dropbear/; cp $W/openmanet/config.yml $W/$1/identity/openmanet/; cp $W/shadow $W/$1/identity/shadow-root; cp $W/expect.$2 $W/$1/overrides.uci; cp $W/expect.$2 $W/$1/lkg/overrides.uci; echo 1 > $W/$1/schema_version; }
partcase(){	# <label> <kind ro|eiow> <mode>
	NCASE=$((NCASE + 1)); rm -rf $W/old $W/new
	devfree || { bad "$1: setup: $DEV still mounted"; return; }; mkfs_p5 || { bad "$1: setup mkfs"; return; }
	rm -rf $W/run/batman $W/uci.over/*; live OLD 5; cs --seed >/dev/null 2>&1 || { bad "$1: setup seed"; return; }; snap old OLD
	rm -rf $W/run/batman; live NEW 9; snap new NEW
	case "$2" in ro) h3='mount -o remount,ro "$MNT"' ;; *) h3="dmsetup load $DMN --table '0 $SECT flakey $LOOP 0 0 3600 1 error_writes' && dmsetup suspend --nolockfs --noflush $DMN && dmsetup resume $DMN || dmsetup resume $DMN" ;; esac
	CS_TEST_HOOK3=$h3 cs $3 > $W/out 2> $W/err; r=$?
	[ "$2" = ro ] || restore_dev || { bad "$1: dm restore"; return; }
	mnt -o ro || { bad "$1: mount after"; return; }
	off=$(oldnew); zero=$(cd $W/m && find . \( -path ./lost+found -o -path './.stage.*' \) -prune -o -type f -size 0 ! -name .seeded -print | tr '\n' ' ')
	idnew=$(cmp -s $W/m/identity/shadow-root $W/new/identity/shadow-root && echo NEW || echo OLD); ovs=$(cmp -s $W/m/overrides.uci $W/new/overrides.uci && echo NEW || echo OLD); umount $W/m
	why=""
	[ "$r" = 15 ] || why="$why rc=$r"; lastline_ok || why="$why last-line"
	[ -z "$off" ] || why="$why neither-OLD-nor-NEW:[$off]"; [ -z "$zero" ] || why="$why 0-byte:[$zero]"
	if [ "$2" = ro ]; then	# a ro remount keeps the completed renames: identity NEW, overrides OLD, and the text says so
		tail -1 $W/err | grep -q 'may be PARTLY' || why="$why text:[$(tail -1 $W/err | cut -c1-90)]"
		[ "$ovs" = OLD ] || why="$why overrides-published"; [ "$idnew" = NEW ] || why="$why ro-kept-no-rename"
	else	# write errors: the later renames still succeed in memory, the journal aborts at the sync -> the probe reports it
		tail -1 $W/err | grep -qE 'may be PARTLY|the renames returned 0 but p5 refuses writes now' || why="$why text:[$(tail -1 $W/err | cut -c1-90)]"
	fi
	[ -z "$why" ] && okk "$1: rc 15 'may be PARTLY', p5 identity=$idnew overrides=$ovs, every file OLD or NEW" || bad "$1:$why"
}
partcase "--save read-only after the first renames" ro --save
partcase "--on-join read-only after the first renames" ro --on-join
if [ "$FLAKEY" = 1 ]; then
	partcase "--save EIO (writes only) after the first renames" eiow --save
	partcase "--on-join EIO (writes only) after the first renames" eiow --on-join
fi
# ---- no fsync tool -> rc 15, p5 unchanged (review A-r2 F3 / B-r2 MINOR-3) -------------------------------------------
NCASE=$((NCASE + 1))
mkdir -p $W/bin.nofsync; cp -a $W/bin/. $W/bin.nofsync/; rm -f $W/bin.nofsync/fsync
NFP=$W/bin.nofsync:/usr/sbin:/usr/bin:/sbin:/bin
# the shell is always the HOST busybox here: a CFGSAVE_BB under qemu-user -L <rootfs> sees the rootfs's /bin/fsync through
# the sysroot (the node has it too), so fsync cannot be hidden from it; the product's check is a plain `command -v`
if [ -n "$(PATH=$NFP command -v fsync)" ] || busybox fsync --help >/dev/null 2>&1; then bad "no-fsync case: cannot hide fsync on this host ($(PATH=$NFP command -v fsync) / host busybox applet)"
elif fresh; then
	mnt -o ro; h0=$(hashes); umount $W/m
	o=$(PATH=$NFP busybox sh $W/sbin/batman-config-save --save 2>$W/err); r=$?
	mnt -o ro; h1=$(hashes); umount $W/m
	[ "$r" = 15 ] && tail -1 $W/err | grep -q 'no fsync tool' && [ "$h1" = "$h0" ] && okk "no fsync tool: rc 15 [$(tail -1 $W/err | cut -c21-110)], p5 unchanged" \
		|| bad "no fsync tool: rc $r p5 $([ "$h1" = "$h0" ] && echo unchanged || echo CHANGED) [$(tail -1 $W/err | cut -c1-120)] [$(echo "$o" | tail -1)]"
else bad "no-fsync case: setup"; fi
# ---- an incomplete stage list before the fsync (hook 4) -> rc 15 before any rename, p5 unchanged (review A-r2 F5) -----
NCASE=$((NCASE + 1))
if [ "$H4OK" != 1 ]; then bad "stage-list count: this config-save has no '# fsync every stage file BEFORE the first rename' anchor (no fsync step)"
elif fresh; then
	mnt -o ro; h0=$(hashes); umount $W/m
	CS_TEST_HOOK4='rm -f "$STAGE/lkg.uci"' cs --on-join > $W/out 2> $W/err; r=$?
	mnt -o ro; h1=$(hashes); umount $W/m
	[ "$r" = 15 ] && tail -1 $W/err | grep -q 'listing the stage for fsync.*p5 is unchanged' && [ "$h1" = "$h0" ] && okk "a stage file missing before the fsync: rc 15 [$(tail -1 $W/err | cut -c21-120)], p5 unchanged" \
		|| bad "stage-list count: rc $r p5 $([ "$h1" = "$h0" ] && echo unchanged || echo CHANGED) [$(tail -1 $W/err | cut -c1-140)]"
else bad "stage-list count: setup"; fi
# ---- deterministic control for "the explanation is the LAST stderr line" (review A-r2 F4): an immutable stage file ----
# makes its rename fail (EPERM) AND every later rm of the stage fail: the not_saved line must still be the last one
NCASE=$((NCASE + 1))
if ! command -v chattr >/dev/null 2>&1; then bad "last-line control: no chattr on this host"
elif fresh; then
	CS_TEST_HOOK2='chattr +i "$STAGE/overrides.uci"' cs --save > $W/out 2> $W/err; r=$?
	mnt && { find $W/m/.stage.* -type f -exec chattr -i {} + 2>/dev/null; rm -rf $W/m/.stage.*; umount $W/m; }
	[ "$r" = 15 ] && lastline_ok && okk "immutable stage file: rc 15, the last stderr line is the explanation [$(tail -1 $W/err | cut -c21-110)]" \
		|| bad "last-line control: rc $r last=[$(tail -1 $W/err | cut -c1-140)]"
else bad "last-line control: setup"; fi
# ---- --check on an ext4 p5 whose ro mount fails 3x -> rc 5, with or without a failed save (B-r2 MINOR-2 / B-r3 MINOR-4)
NCASE=$((NCASE + 1))
if fresh; then
	cs --check >/dev/null 2>&1   # creates the run dir
	printf '\377\377\377\377' | dd of=$DEV bs=1 seek=1048 conv=notrunc 2>/dev/null   # s_log_block_size: no longer mounts, magic intact
	o1=$(cs --check 2>&1); r1=$?
	( umask 077; echo "$(cut -d. -f1 /proc/uptime) staging" > $W/run/batman/cfgsave-save.failed )
	o2=$(cs --check 2>&1); r2=$?
	rm -f $W/run/batman/cfgsave-save.failed
	[ "$r1" = 5 ] && echo "$o1" | grep -qE 'p5 stale: unverifiable \(p5 does not mount read-only: .*[a-z].*\)$' \
		&& okk "--check, ext4 p5 unmountable, no failed save: rc 5 [$(echo "$o1" | tail -1 | cut -c21-120)]" \
		|| bad "--check unmountable without the marker: rc $r1 [$(echo "$o1" | tail -1)] (want 5 'does not mount read-only')"
	[ "$r2" = 5 ] && echo "$o2" | grep -qE 'p5 stale: unverifiable \(p5 does not mount read-only: .+; a save failed earlier this boot: staging\)' \
		&& okk "--check, ext4 p5 unmountable after a failed save: rc 5 names it [$(echo "$o2" | tail -1 | cut -c21-140)]" \
		|| bad "--check unmountable with the marker: rc $r2 [$(echo "$o2" | tail -1)]"
else bad "--check unmountable: setup"; fi
# ---- a superblock that cannot be READ (dm error) is not "not ext4" (review B-r3 MINOR-1) ------------------------------
NCASE=$((NCASE + 1))
if [ -z "$DMN" ]; then bad "unreadable superblock: needs device-mapper"
elif fresh; then
	cs --check >/dev/null 2>&1   # creates the run dir
	if dmtab error && blockdev --flushbufs $DEV 2>/dev/null; then
		o1=$(cs --check 2>&1); r1=$?
		( umask 077; echo "$(cut -d. -f1 /proc/uptime) staging" > $W/run/batman/cfgsave-save.failed )
		o2=$(cs --check 2>&1); r2=$?
		rm -f $W/run/batman/cfgsave-save.failed
		rm -rf $W/pg1; o3=$(cs --prov-get $W/pg1 2>&1); r3=$?
		restore_dev || bad "unreadable superblock: dm restore"
		for x in "1:$r1" "2:$r2"; do eval "o=\$o${x%%:*}"; r=${x#*:}
			[ "$r" = 5 ] && echo "$o" | grep -q 'p5 stale: unverifiable (p5 unreadable' \
				&& okk "--check, superblock unreadable ($([ "${x%%:*}" = 1 ] && echo 'no marker' || echo 'after a failed save')): rc 5 [$(echo "$o" | tail -1 | cut -c21-120)]" \
				|| bad "--check unreadable superblock ($([ "${x%%:*}" = 1 ] && echo 'no marker' || echo marker)): rc $r [$(echo "$o" | tail -1)] (want 5 'p5 unreadable')"
		done
		[ "$r3" = 1 ] && echo "$o3" | grep -q 'p5 error unreadable' && okk "--prov-get, superblock unreadable: rc 1 'p5 unreadable' class [$(echo "$o3" | tail -1 | cut -c21-100)]" \
			|| bad "--prov-get unreadable superblock: rc $r3 [$(echo "$o3" | tail -1)] (want 1)"
	else restore_dev; bad "unreadable superblock: could not switch the dm table / flush the buffers"; fi
else bad "unreadable superblock: setup"; fi
# control: a READABLE non-ext4 p5 (zeroed) is still "SKIP not-ext4" rc 3 (--prov-get 12)
NCASE=$((NCASE + 1))
if fresh; then
	dd if=/dev/zero of=$DEV bs=64k count=32 2>/dev/null; sync
	o=$(cs --check 2>&1); r=$?; rm -rf $W/pg2; o4=$(cs --prov-get $W/pg2 2>&1); r4=$?
	[ "$r" = 3 ] && echo "$o" | grep -q 'p5 SKIP not-ext4' && [ "$r4" = 12 ] && okk "control: a readable non-ext4 p5: --check rc 3 'SKIP not-ext4', --prov-get rc 12" \
		|| bad "control non-ext4: --check rc $r [$(echo "$o" | tail -1)] --prov-get rc $r4"
else bad "control non-ext4: setup"; fi
# ---- a HEALTHY p5 that is busy (review B-r4 MAJOR-1 / MINOR-1) -----------------------------------------------------
# mounted rw elsewhere (a writer killed before its EXIT trap, an operator, a lockless writer): ro,noload gets EBUSY;
# --check must give the TRUE verdict through that mount — fresh after a save, stale after a live change — not rc 5
# "unverifiable"
busycase(){	# <label> <mount opts> <want: fresh|stale|busy> [<mountpoint>]
	NCASE=$((NCASE + 1)); local mp=${4:-$W/other}
	fresh || { bad "$1: setup"; return; }
	cs --save >/dev/null 2>&1 || { bad "$1: setup save"; return; }
	[ "$3" = stale ] && live NEW 9   # new host keys: p5 now lags the live identity
	mkdir -p "$mp" && mount -t ext4 -o "$2" $DEV "$mp" || { bad "$1: setup mount $2 at $mp"; return; }
	o=$(cs --check 2>&1); r=$?
	umount "$mp"
	case "$3:$r" in
		fresh:0) echo "$o" | grep -q 'p5 fresh' && okk "$1: --check rc 0 fresh [$(echo "$o" | head -1 | cut -c21-110)]" || bad "$1: rc 0 without 'p5 fresh' [$o]" ;;
		stale:5) echo "$o" | grep -q 'p5 stale: ' && ! echo "$o" | grep -q unverifiable && okk "$1: --check rc 5 stale, the real verdict [$(echo "$o" | tail -1 | cut -c21-110)]" || bad "$1: rc 5 but [$(echo "$o" | tail -1)]" ;;
		busy:5) echo "$o" | grep -q 'p5 stale: unverifiable (p5 busy (mounted at .*) and could not be compared)' && okk "$1: --check rc 5 [$(echo "$o" | tail -1 | cut -c21-130)]" || bad "$1: rc 5 but [$(echo "$o" | tail -1)]" ;;
		*) bad "$1: --check rc $r (want $3) [$(echo "$o" | tail -1)]" ;;
	esac
}
busycase "healthy p5 mounted rw elsewhere, p5 == live" rw fresh
busycase "healthy p5 mounted rw elsewhere, live changed" rw stale
busycase "healthy p5 mounted ro elsewhere, p5 == live" ro fresh
busycase "healthy p5 mounted rw at a path mountinfo escapes (a blank)" rw busy "$W/other dir"
# a concurrent save holding the lock: --check waits 5 s, then rc 8 lock-busy (it never mounts)
NCASE=$((NCASE + 1))
if fresh; then
	CS_TEST_HOOK='sleep 9' cs --save > $W/bg.out 2>&1 &
	bgp=$!; sleep 2
	o=$(cs --check 2>&1); r=$?
	wait $bgp; rb=$?
	[ "$r" = 8 ] && echo "$o" | grep -q 'lock-busy' && [ "$rb" = 0 ] && okk "a concurrent save holds the lock: --check rc 8 lock-busy, the save then rc 0" \
		|| bad "concurrent save: --check rc $r [$(echo "$o" | tail -1)] save rc $rb"
else bad "concurrent save: setup"; fi
# ---- --seed on an unreadable superblock: refused, no mkfs; on a readable zeroed p5: formatted and seeded --------------
NCASE=$((NCASE + 1))
if [ -z "$DMN" ]; then bad "--seed unreadable: needs device-mapper"
elif fresh; then
	mnt -o ro; h0=$(hashes); umount $W/m
	if dmtab error && blockdev --flushbufs $DEV 2>/dev/null; then
		o=$(cs --seed 2>&1); r=$?
		restore_dev || bad "--seed unreadable: dm restore"
		mnt -o ro; h1=$(hashes); umount $W/m
		[ "$r" != 0 ] && echo "$o" | grep -q "refusing --seed: p5's superblock cannot be read" && ! echo "$o" | grep -q 'batman-config-save: formatting' && [ "$h1" = "$h0" ] \
			&& okk "--seed, superblock unreadable: refused rc $r, no mkfs attempted, p5 intact [$(echo "$o" | tail -1 | cut -c21-120)]" \
			|| bad "--seed unreadable: rc $r p5 $([ "$h1" = "$h0" ] && echo intact || echo CHANGED) [$(echo "$o" | tr '\n' ' ' | cut -c1-200)]"
	else restore_dev; bad "--seed unreadable: could not switch the dm table"; fi
else bad "--seed unreadable: setup"; fi
NCASE=$((NCASE + 1))
dd if=/dev/zero of=$DEV bs=64k count=32 2>/dev/null; sync; rm -rf $W/run/batman $W/uci.over/*; live OLD 5
o=$(cs --seed 2>&1); r=$?
if [ "$r" = 0 ] && echo "$o" | grep -q 'batman-config-save: formatting' && echo "$o" | grep -q 'saved (--seed)' && mnt -o ro; then
	cmp -s $W/m/overrides.uci $W/expect.OLD && okk "control: --seed on a readable zeroed p5 formats and seeds (rc 0)" || bad "control zeroed --seed: overrides wrong"; umount $W/m
else bad "control zeroed --seed: rc $r [$(echo "$o" | tr '\n' ' ' | cut -c1-200)]"; fi
# ---- the bind used for a busy p5 must really be read-only (review A-r6 F1 / B-r6 MINOR-1): a `mount` whose remount
# fails (a shim in front of the real one for this case) -> rc 5 busy, never a verdict through an rw bind
# (run under dash for this case: busybox sh resolves `mount` to its applet, never to a PATH shim)
NCASE=$((NCASE + 1))
mkdir -p $W/bin.noremount
printf '#!/bin/sh\ncase " $* " in *remount*) echo "mount: remount refused (test shim)" >&2; exit 1 ;; esac\nexec %s "$@"\n' "$(command -v mount)" > $W/bin.noremount/mount
chmod +x $W/bin.noremount/mount
if fresh && cs --save >/dev/null 2>&1; then
	mkdir -p $W/other && mount -t ext4 -o rw $DEV $W/other || bad "remount shim: setup mount"
	# under dash: busybox sh prefers its own `mount` applet over PATH, so the shim would never be called
	if command -v dash >/dev/null 2>&1; then o=$(PATH=$W/bin.noremount:$PATH dash "$CSX" --check 2>&1); r=$?; else o="no dash on this host"; r=99; fi
	umount $W/other
	[ "$r" = 5 ] && echo "$o" | grep -q 'p5 stale: unverifiable (p5 busy (mounted at .*) and could not be compared)' && ! echo "$o" | grep -q 'compared through' \
		&& okk "busy p5, the bind cannot be made read-only: rc 5 busy, no verdict through an rw bind" \
		|| bad "remount shim: --check rc $r [$(echo "$o" | tr '\n' ' ' | cut -c1-200)] (want rc 5 busy)"
else bad "remount shim: setup"; fi
# ---- a first --seed whose renames fail and whose new directories cannot be removed: the text must not say "unchanged"
# (CI run of PR #381). Deterministic: every staged identity file immutable (its rename fails, EPERM) and the new
# identity/ append-only (its subdirectories cannot be removed again).
NCASE=$((NCASE + 1))
if ! command -v chattr >/dev/null 2>&1; then bad "seed dirs left: no chattr"
elif devfree && mkfs_p5; then
	rm -rf $W/run/batman $W/uci.over/*; live NEW 9
	mnt -o ro; h0=$(hashes); umount $W/m
	CS_TEST_HOOK2='chattr +i "$STAGE"/identity/dropbear/* "$STAGE"/identity/openmanet/* "$STAGE"/identity/shadow-root; chattr +a "$MNT/identity"' \
		cs --seed > $W/out 2> $W/err; r=$?
	mnt && { chattr -a $W/m/identity 2>/dev/null; find $W/m/.stage.* -type f -exec chattr -i {} + 2>/dev/null; rm -rf $W/m/.stage.*; umount $W/m; }
	mnt -o ro; h1=$(hashes); rd=$(reader); umount $W/m
	dd=$(diff <(echo "$h0") <(echo "$h1") | grep '^[<>]')
	# the immutable stage files cannot be removed either: the text must say the stage stays (review of cdee8b0, B-1)
	[ "$r" = 15 ] && tail -1 $W/err | grep -q 'p5 is unchanged except empty directories it could not remove:.*identity' && dirs_only_listed "$dd" \
		&& tail -1 $W/err | grep -q '; its stage \.stage\.[0-9]* stays (removed by the next save that holds the lock)' && [ "$rd" = unseeded ] \
		&& okk "first --seed, renames fail, new dirs + the stage stay: rc 15, the text names them exactly [$(tail -1 $W/err | cut -c21-200)]" \
		|| bad "seed dirs left: rc $r [$(tail -1 $W/err | cut -c1-220)] diff=[$(echo "$dd" | tr '\n' '|' | cut -c1-120)] listed=[$(listed_dirs | tr '\n' ' ')] reader=$rd"
else bad "seed dirs left: setup"; fi
# ---- no lock (RDOK=0: the run dir is unusable, so the stale-name cleanup does not run): a .wprobe symlink to a file
# outside p5 must not be written through (review of cdee8b0, A-1 / B-4)
NCASE=$((NCASE + 1))
if fresh && mnt; then
	echo ORIGINAL > $W/outside; ln -s $W/outside $W/m/.wprobe; umount $W/m
	chmod 777 $W/run   # rundir.sh refuses a group/other-writable parent -> RDOK=0: no lock, no cleanup
	o=$(cs --save 2>&1); r=$?
	chmod 755 $W/run
	mnt -o ro; pl=$(ls -la $W/m/.wprobe 2>/dev/null | cut -c1); umount $W/m
	[ "$r" = 0 ] && [ ! -e $W/run/batman ] && [ "$(cat $W/outside)" = ORIGINAL ] \
		&& okk "no lock, a .wprobe symlink to a file outside p5: saved rc 0, the target untouched (the link: [${pl:-gone}])" \
		|| bad "wprobe symlink: rc $r target=[$(cat $W/outside)] left=[$pl] no-lock-path=$([ -e $W/run/batman ] && echo NO-the-run-dir-was-made || echo yes) [$(echo "$o" | tail -1 | cut -c1-120)]"
	rm -f $W/outside
else bad "wprobe symlink: setup"; fi
# no lock + a leftover at the old fixed probe name: a .wprobe DIRECTORY, and an immutable .wprobe file (a deterministic
# stand-in for another lock-less writer's probe that exists at that moment) -> the save is rc 0, never the false
# "p5 refuses writes now" (review of a87baa3, A-1 / B-1)
probename(){	# <label> <setup on the mounted p5>
	NCASE=$((NCASE + 1))
	if fresh && mnt; then
		( cd $W/m && eval "$2" ) || bad "$1: setup"; umount $W/m
		chmod 777 $W/run; o=$(cs --save 2>&1); r=$?; chmod 755 $W/run
		mnt && { chattr -i $W/m/.wprobe 2>/dev/null; rm -rf $W/m/.wprobe; umount $W/m; }
		[ "$r" = 0 ] && ! echo "$o" | grep -q 'refuses writes now' && okk "no lock, $1: saved rc 0" \
			|| bad "$1: rc $r [$(echo "$o" | tail -1 | cut -c1-150)]"
	else bad "$1: setup"; fi
}
probename "a .wprobe directory" 'mkdir .wprobe && : > .wprobe/x'
command -v chattr >/dev/null 2>&1 && probename "an immutable .wprobe file (another writer's probe)" ': > .wprobe && chattr +i .wprobe' || bad "immutable .wprobe: no chattr"
# two REAL concurrent lock-less saves, 10 pairs: neither may report the false "refuses writes now" text (with a fixed
# probe name they can collide; the window is narrow, so this is best effort — the stand-in above is the deterministic one)
NCASE=$((NCASE + 1))
if fresh; then
	chmod 777 $W/run; nfalse=0; nbad=0
	for i in 1 2 3 4 5 6 7 8 9 10; do
		cs --save > $W/c1 2>&1 & p1=$!; cs --save > $W/c2 2>&1 & p2=$!; wait $p1; r1=$?; wait $p2; r2=$?
		grep -q 'refuses writes now' $W/c1 $W/c2 && nfalse=$((nfalse + 1))
		{ [ "$r1" = 0 ] && [ "$r2" = 0 ]; } || nbad=$((nbad + 1))
	done
	chmod 755 $W/run
	[ "$nfalse" = 0 ] && okk "10 pairs of concurrent lock-less saves: no false 'refuses writes now' (pairs with an rc != 0: $nbad)" \
		|| bad "concurrent lock-less saves: $nfalse of 10 pairs reported 'refuses writes now'"
else bad "concurrent lock-less: setup"; fi
# ---- the busy lookup must not read a filesystem that is not p5 (review B-r5 MINOR-1) ---------------------------------
# A: a tmpfs stacked on the mountpoint where p5 is mounted rw: reading through that path would read the tmpfs
NCASE=$((NCASE + 1))
if fresh && cs --save >/dev/null 2>&1; then
	mkdir -p $W/other && mount -t ext4 -o rw $DEV $W/other && mount -t tmpfs tmpfs $W/other || bad "stacked: setup mounts"
	o=$(cs --check 2>&1); r=$?
	umount $W/other; umount $W/other
	[ "$r" = 5 ] && echo "$o" | grep -q 'p5 stale: unverifiable (p5 busy (mounted at .*) and could not be compared)' \
		&& okk "a tmpfs stacked on p5's mountpoint: no verdict from the tmpfs, rc 5 [$(echo "$o" | tail -1 | cut -c21-130)]" \
		|| bad "stacked tmpfs: --check rc $r [$(echo "$o" | tr '\n' ' ' | cut -c1-200)] (want rc 5 busy)"
else bad "stacked tmpfs: setup"; fi
# B: a NON-p5 fs mounted with p5's name as its source (a copy of a good p5 in a tmpfs), while p5 itself is corrupt
NCASE=$((NCASE + 1))
if fresh && cs --save >/dev/null 2>&1; then
	mkdir -p $W/fake && mount -t tmpfs "$DEV" $W/fake && mnt -o ro && cp -a $W/m/. $W/fake/ && umount $W/m || bad "named fake: setup"
	printf '\377\377\377\377' | dd of=$DEV bs=1 seek=1048 conv=notrunc 2>/dev/null   # p5: magic intact, no longer mounts
	o=$(cs --check 2>&1); r=$?
	umount $W/fake
	[ "$r" = 5 ] && echo "$o" | grep -q 'p5 stale: unverifiable (p5 does not mount read-only: ' && ! echo "$o" | grep -q 'compared through' \
		&& okk "a tmpfs whose source is named like p5 (p5 corrupt): not taken for p5, rc 5 does not mount [$(echo "$o" | tail -1 | cut -c21-110)]" \
		|| bad "named fake: --check rc $r [$(echo "$o" | tr '\n' ' ' | cut -c1-200)] (want rc 5 'does not mount', no verdict from the fake)"
else bad "named fake: setup"; fi
# C: p5 held only by a subdirectory bind of an rw mount that was itself unmounted (review B-r5 MINOR-2)
NCASE=$((NCASE + 1))
if fresh && cs --save >/dev/null 2>&1; then
	mkdir -p $W/other $W/part && mount -t ext4 -o rw $DEV $W/other && mount --bind $W/other/identity $W/part && umount $W/other || bad "subdir bind: setup"
	o=$(cs --check 2>&1); r=$?
	umount $W/part
	[ "$r" = 5 ] && echo "$o" | grep -q 'p5 stale: unverifiable (p5 busy (held by a bind mount of a part of it at ' \
		&& okk "p5 held only by a subdirectory bind: rc 5 with its own text [$(echo "$o" | tail -1 | cut -c21-130)]" \
		|| bad "subdir bind: --check rc $r [$(echo "$o" | tail -1)] (want 'held by a bind mount of a part of it')"
else bad "subdir bind: setup"; fi
[ -z "$skip" ] || echo "note: $skip"
[ "$NCASE" -gt 0 ] || bad "no case ran"
# test of the test: keep the dm device open past the exit, so the teardown must report a LEAK (review A-r5 F1)
[ "${CFGSAVE_TEST_LEAK:-0}" = 1 ] && [ -n "$DMN" ] && { sleep 40 < "$DEV" 9>&- & echo "note: CFGSAVE_TEST_LEAK=1: $DEV held open by pid $! past the exit"; }
echo "PASS=$pass FAIL=$fail"; [ $pass -gt 0 ] && [ $fail = 0 ]
