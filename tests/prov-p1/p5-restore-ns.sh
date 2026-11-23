#!/bin/bash
# tests/prov-p1/p5-restore-ns.sh — scripts/node/prov-base-254.sh p5-restore with p5 left mounted (254-v16-group4 §3.2,
# §13.6, §15), run UNMODIFIED in a private mount namespace in WSL / Linux. No test seam: the script writes the absolute
# /dev/mmcblk0p5 and reads /proc/mounts, so the sandbox gives it
#   - a tmpfs /dev (mode 0755) with regular files null / zero / urandom and a regular file mmcblk0p5 (the "partition");
#   - a tmpfs /tmp (and /tmp/run inside it), and a tmpfs /mnt (for chk_202's /mnt/dv-p5) — nothing is created on the host;
#   - leftover p5 mounts as tmpfs mounts whose SOURCE is /dev/mmcblk0p5, so the namespace's /proc/mounts shows them as p5;
#   - the other inputs (snapshot, rundir.sh) under PROV_BASE_TEST_ROOT.
# Namespace as tests/judges/h4/test-undo-lib.sh:12-15: real root -> `unshare -m` (a user namespace would lose DAC override
# on the repo owner's 0750 home); otherwise `unshare -Urm`. Neither works -> FAIL (never a skip). The sandbox is checked
# before any case: /dev is another device than the host's, the last /dev mount is tmpfs, /dev/mmcblk0p5 is a regular
# file and not a block device. Any check that cannot be made is a FAIL.
#   bash tests/prov-p1/p5-restore-ns.sh                    -> "p5-restore-ns: N passed, M failed", rc 1 on any FAIL
#   P5_SCRIPT=<file> P5_EXPECT=main bash tests/prov-p1/p5-restore-ns.sh
#       the negative control: <file> is main's prov-base-254.sh; it must FAIL the fix's cases, and for a harness leftover
#       it must print exactly "FAIL p5 is mounted" (any other die makes the control INVALID)
set -u
REPO=$(cd "$(dirname "$0")/../.." && pwd)
SCRIPT=${P5_SCRIPT:-$REPO/scripts/node/prov-base-254.sh}
if [ "${P5NS_INNER:-0}" != 1 ]; then
	[ -r "$SCRIPT" ] || { echo "FAIL no script $SCRIPT"; echo "p5-restore-ns: 0 passed, 1 failed"; exit 1; }
	command -v unshare >/dev/null || { echo "FAIL no unshare"; echo "p5-restore-ns: 0 passed, 1 failed"; exit 1; }
	HOSTDEV=$(stat -c %d /dev) || { echo "FAIL stat /dev"; echo "p5-restore-ns: 0 passed, 1 failed"; exit 1; }
	if [ "$(id -u)" = 0 ]; then NS="unshare --mount --propagation private"; else NS="unshare --user --map-root-user --mount --propagation private"; fi
	$NS true 2>/dev/null || { echo "FAIL namespace not available ($NS): this test needs one (WSL / Linux), it is not skipped"; echo "p5-restore-ns: 0 passed, 1 failed"; exit 1; }
	exec $NS env P5NS_INNER=1 P5NS_HOSTDEV="$HOSTDEV" P5_SCRIPT="$SCRIPT" P5_EXPECT="${P5_EXPECT:-fix}" bash "$0" "$@"
fi

pass=0; fail=0
ok(){ echo "ok   $*"; pass=$((pass + 1)); }; no(){ echo "FAIL $*"; fail=$((fail + 1)); }
end(){ echo "p5-restore-ns: $pass passed, $fail failed"; [ "$fail" = 0 ]; exit $?; }
SH=$(command -v busybox >/dev/null && echo "busybox sh" || echo sh)   # the node runs busybox ash
# /tmp is covered first, then everything read from the host (the script under test, random bytes) is staged into it
# before /mnt (the repo may live there) and /dev are covered: nothing is written on the host
mount -t tmpfs -o mode=0755 none /tmp || { no "tmpfs over /tmp"; end; }
S=/tmp/stage; mkdir -p /tmp/run "$S" || { no "mkdir in the namespace /tmp"; end; }
cp "$P5_SCRIPT" "$S/prov-base.sh" && head -c 65536 /dev/urandom > "$S/urandom" && head -c 2097152 /dev/urandom > "$S/p5.img" || { no "staging"; end; }
mount -t tmpfs -o mode=0755 none /mnt || { no "tmpfs over /mnt"; end; }
mount -t tmpfs -o mode=0755 none /dev || { no "tmpfs over /dev"; end; }
: > /dev/null && : > /dev/zero && cp "$S/urandom" /dev/urandom && chmod 666 /dev/null /dev/zero /dev/urandom && : > /dev/mmcblk0p5 || { no "the sandbox /dev files"; end; }
# ---- the sandbox check: refuse every case unless it holds
d=$(stat -c %d /dev) || { no "stat /dev in the namespace"; end; }
[ -n "$P5NS_HOSTDEV" ] && [ "$d" != "$P5NS_HOSTDEV" ] && ok "sandbox: /dev is device $d, the host's is $P5NS_HOSTDEV" || { no "sandbox: /dev device [$d] = host [$P5NS_HOSTDEV]"; end; }
t=$(awk '{ for (i = 1; i <= NF; i++) if ($i == "-") { if ($5 == "/dev") t = $(i + 1); break } } END { print t }' /proc/self/mountinfo) || { no "mountinfo unreadable"; end; }
[ "$t" = tmpfs ] && ok "sandbox: the last /dev mount is tmpfs" || { no "sandbox: the last /dev mount is [$t]"; end; }
[ -f /dev/mmcblk0p5 ] && [ ! -b /dev/mmcblk0p5 ] && ok "sandbox: /dev/mmcblk0p5 is a regular file, not a block device" || { no "sandbox: /dev/mmcblk0p5 is not the fake file"; end; }

RUN=p5ns1; TR=/tmp/ptr; D=$TR/opt/batdata/dv-prov/$RUN; LOCK=/tmp/run/batman/cfgsave.lock; DVD=/tmp/run/batman-dv
mkdir -p "$TR/usr/lib/batman" "$TR/opt/batdata/state" "$D" /tmp/run/batman
echo 'RUNDIR=/tmp/run/batman' > "$TR/usr/lib/batman/rundir.sh"
cp "$S/p5.img" "$D/p5.img"; WANT=$(sha256sum < "$D/p5.img" | cut -c1-64); echo "$WANT" > "$D/p5.img.sha"
p5mounts(){ awk '$1 == "/dev/mmcblk0p5" {print $2}' /proc/mounts | tr '\n' ' '; }
leftover(){ mkdir -p "$1" && mount -t tmpfs /dev/mmcblk0p5 "$1"; }   # a p5 mount as /proc/mounts shows it
reset(){	# a clean start: no p5 mount, the fake partition empty, no lock
	local m; for m in $(awk '$1 == "/dev/mmcblk0p5" {print $2}' /proc/mounts); do umount "$m" 2>/dev/null; done
	: > /dev/mmcblk0p5; rm -rf "$LOCK"
}
OUT=""; RC=0
restore(){ OUT=$(cd / && PROV_BASE_TEST_ROOT=$TR $SH /tmp/stage/prov-base.sh p5-restore "$RUN" 2>&1); RC=$?; }
holder_gone(){ ! grep -qa 'batman-config-save-dvhol[d]' /proc/[0-9]*/cmdline 2>/dev/null; }   # [d]: not grep's own argv
untouched(){ [ ! -s /dev/mmcblk0p5 ]; }
restored(){ [ "$(sha256sum < /dev/mmcblk0p5 | cut -c1-64)" = "$WANT" ]; }
show(){ echo "$OUT" | sed 's/^/      | /'; }

if [ "$P5_EXPECT" = main ]; then
	# ---- negative control on main: a harness leftover -> exactly "FAIL p5 is mounted" (no name), p5 untouched
	reset; M=$DVD/pbm.ns1; leftover "$M"; restore; show
	if [ "$OUT" = "FAIL p5 is mounted" ] && [ "$RC" != 0 ]; then ok "main: pbm. leftover -> exactly 'FAIL p5 is mounted' (rc $RC), the mount is not named (control valid)"
	else no "main: INVALID control: expected exactly 'FAIL p5 is mounted', got rc $RC [$OUT]"; fi
	case "$OUT" in *"$M"*) no "main named the mount" ;; esac
fi

# ---- 1. a harness pbm. leftover: printed, unmounted, the image restored into the fake partition
reset; M=$DVD/pbm.ns1; leftover "$M"; restore; show
[ "$RC" = 0 ] && grep -qx "P5-MOUNTED $M" <<< "$OUT" && grep -qx "P5-UNMOUNTED $M" <<< "$OUT" && grep -q "^P5-RESTORED $RUN sha=${WANT:0:16}" <<< "$OUT" && [ -z "$(p5mounts)" ] && restored && [ ! -e "$LOCK" ] && holder_gone \
	&& ok "pbm. leftover: P5-MOUNTED + P5-UNMOUNTED, restored (sha ${WANT:0:16}), lock dropped" || no "pbm. leftover: rc $RC mounts [$(p5mounts)] restored=$(restored && echo y || echo n) lock=$([ -e "$LOCK" ] && echo held || echo gone)"
# ---- 2. chk_202's /mnt/dv-p5: unmounted too
reset; M=/mnt/dv-p5; leftover "$M"; restore; show
[ "$RC" = 0 ] && grep -qx "P5-UNMOUNTED $M" <<< "$OUT" && [ -z "$(p5mounts)" ] && restored && ok "/mnt/dv-p5 leftover: unmounted, restored" || no "/mnt/dv-p5 leftover: rc $RC mounts [$(p5mounts)]"
# ---- 3. two harness leftovers (p5ro. and ch1.): both unmounted
reset; leftover "$DVD/p5ro.ns3"; leftover "$DVD/ch1.ns3"; restore; show
[ "$RC" = 0 ] && [ "$(grep -c '^P5-UNMOUNTED ' <<< "$OUT")" = 2 ] && [ -z "$(p5mounts)" ] && restored && ok "two harness leftovers: both unmounted, restored" || no "two harness leftovers: rc $RC mounts [$(p5mounts)]"
# ---- 4. a product mount (cfgsave-mnt.) -> named, FAIL, still mounted, p5 not written, lock dropped
reset; M=/tmp/run/batman/cfgsave-mnt.ns4; leftover "$M"; restore; show
[ "$RC" != 0 ] && grep -qx "P5-MOUNTED $M" <<< "$OUT" && grep -qx "P5-NOT-HARNESS $M" <<< "$OUT" && grep -q "^FAIL .*$M" <<< "$OUT" && [ "$(p5mounts)" = "$M " ] && untouched && [ ! -e "$LOCK" ] && holder_gone \
	&& ok "cfgsave-mnt. mount: named, FAIL, left mounted, p5 not written, lock dropped" || no "cfgsave-mnt. mount: rc $RC mounts [$(p5mounts)] untouched=$(untouched && echo y || echo n) lock=$([ -e "$LOCK" ] && echo held || echo gone)"
# ---- 5. a product mount next to a harness one -> nothing unmounted
reset; leftover "$DVD/pbm.ns5"; M=/tmp/run/batman/autocommit.p5; leftover "$M"; restore; show
[ "$RC" != 0 ] && grep -qx "P5-NOT-HARNESS $M" <<< "$OUT" && ! grep -q '^P5-UNMOUNTED' <<< "$OUT" && [ "$(p5mounts | wc -w)" = 2 ] && untouched && [ ! -e "$LOCK" ] \
	&& ok "product + harness mount: the product one named, FAIL, nothing unmounted" || no "product + harness mount: rc $RC mounts [$(p5mounts)]"
# ---- 6. a prefix look-alike (/tmp/run/batman-dvx/) is not the harness's
reset; M=/tmp/run/batman-dvx/pbm.ns6; leftover "$M"; restore; show
[ "$RC" != 0 ] && grep -qx "P5-NOT-HARNESS $M" <<< "$OUT" && [ "$(p5mounts)" = "$M " ] && untouched && ok "look-alike prefix /tmp/run/batman-dvx/: named, FAIL, left mounted" || no "look-alike prefix: rc $RC mounts [$(p5mounts)]"
# ---- 7. a busy harness mount (a process with its cwd inside) -> named, FAIL, still mounted, lock dropped
reset; M=$DVD/p5s.ns7; leftover "$M"; (cd "$M" && exec sleep 60) & BP=$!; sleep 0.3; restore; kill "$BP" 2>/dev/null; wait "$BP" 2>/dev/null; show
[ "$RC" != 0 ] && grep -q "^P5-BUSY $M" <<< "$OUT" && grep -q "^FAIL .*$M" <<< "$OUT" && [ "$(p5mounts)" = "$M " ] && untouched && [ ! -e "$LOCK" ] && holder_gone \
	&& ok "busy harness mount: P5-BUSY named, FAIL, still mounted, p5 not written, lock dropped" || no "busy harness mount: rc $RC mounts [$(p5mounts)] lock=$([ -e "$LOCK" ] && echo held || echo gone)"
# ---- 8. no p5 mount: restored as before
reset; restore; show
[ "$RC" = 0 ] && ! grep -q '^P5-MOUNTED' <<< "$OUT" && restored && ok "no p5 mount: restored, no P5-MOUNTED line" || no "no p5 mount: rc $RC"
reset
end
