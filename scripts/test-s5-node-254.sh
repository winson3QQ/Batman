#!/bin/bash
# scripts/test-s5-node-254.sh — offline tests of the #254 S5 daily node checks (scripts/node/fw-boot-254.sh +
# scripts/node/slotlock-lib-254.sh under busybox ash / dash, and the host judges in scripts/dv/s5-254.sh). No node:
# FB_ROOT is a fixture tree; nft, fw4, batman-slot, umount are stubs on PATH, provd a dummy process with a name unique
# to this run (FB_PROVD); ssh is a stub for the host-side aggregation.
#   prov-fw-boot-254: good (ekh-bcm2711 and ekh-bcm2710) -> PASS; pre-S5 -> one FAIL line, KNOWN until the entry's
#     expiry and NEW after it (kf_classify on the real list); fw4 / a table missing, a rule loaded twice, an overlay
#     include, a commented-rule-less include -> FAIL; fw4 print failing / its ruleset refused by nft -c -> FAIL FB2;
#     upload tmpfs without noexec / wrong size / not mounted / stacked / an unknown board -> FAIL, provd not running ->
#     recorded, not judged; FB6: a verb whose child keeps fd 9 -> FAIL (the negative control of the lock-release
#     check), also when the verb refuses (rc 16); a verb that refuses the node's state AFTER taking the lock (rc 16 /
#     17) -> still judged, PASS; detect_layout's 17 before the lock -> INVALID without a lock file, PASS with one; a
#     verb rc 0 that never takes the lock -> FAIL; a verb leaving B's FAT mounted -> FAIL; the lock held for 5 tries
#     by an orphan (no batman-slot ancestor, not the harness) -> FAIL "a leaked fd 9", by a batman-slot -> INVALID
#     (review r3 A-MAJOR-2); rc 14 x 5 with the lock free and B's FAT mounted at /mnt/_ab -> FAIL naming it, with
#     nothing mounted elsewhere -> INVALID (review r3 B-M1); a verb's child started by `env -i` (no token) keeping fd 9
#     -> FAIL (the step window, review r3 A-m1); an uncommitted trial autocommit gates -> NOT-RUN, no verb run; a trial
#     nobody gates -> run (review r3 B-m5); an earlier run's leftover /mnt/slotboot.<dead pid> -> unmounted (INFO), a
#     live batman-slot's mount untouched, an UNRECORDED dead pid's mount untouched; a pid dir of mode 0755 or of
#     another owner -> not used (review r3 B-m1); the verb pids recorded
#   chk_fw_boot_254 / s5_sum: PASS -> rc 0; INVALID -> SKIP-REASON rc 3; FAIL or no verdict -> rc 1; no node -> rc 1
#   release-key-254 (rk_judge, LoadTrust's rule): T + serial + bench stamp -> PASS; T without the stamp / stamp without
#     T / unknown stamp value / bench without .bench / no stamp / not a point / pub without serial / serial without
#     pub / a bad serial / no answer -> FAIL; none (both absent), another root + serial -> PASS; status key 15 trust
#     agreeing -> PASS, disagreeing -> FAIL; RK_Q on fixture files (bench, no serial file, a two-line serial, CRLF,
#     none)
# Safe to run several at once on one host (review r2 A-m1 / B-m1): every process it starts has a name of this run or is
# killed by its recorded pid; nothing is killed by name. Zero cases = FAIL.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
P=0; F=0
has(){ if grep -qE -- "$3" <<< "$2"; then echo "ok   $1"; P=$((P + 1)); else echo "FAIL $1: lacks /$3/"; printf '%s\n' "$2" | sed 's/^/      /' | head -30; F=$((F + 1)); fi; }
hasnt(){ if grep -qE -- "$3" <<< "$2"; then echo "FAIL $1: has /$3/"; printf '%s\n' "$2" | sed 's/^/      /' | head -30; F=$((F + 1)); else echo "ok   $1"; P=$((P + 1)); fi; }
command -v flock >/dev/null || { echo "FAIL no flock on this host"; echo "S5-NODE 0 passed, 1 failed"; exit 1; }
T=$(mktemp -d)
killrec(){ local f; for f in "$T/pids" "$T/st/kids"; do [ -f "$f" ] && xargs -r kill < "$f" 2>/dev/null; : > "$f" 2>/dev/null; done; return 0; }
trap 'killrec; jobs -p | xargs -r kill 2>/dev/null; rm -rf "$T"' EXIT
B=$T/bin; ST=$T/st; FR=$T/root; mkdir -p "$B" "$ST" "$T/run"; chmod 755 "$T/run"
cat > "$T/rundir.sh" <<EOF
RUNDIR=$T/run/batman
batman_rundir(){ mkdir -m 700 "\$RUNDIR" 2>/dev/null; [ -d "\$RUNDIR" ]; }
EOF
export SLK_RD=$T/rundir.sh ST
# ---- stubs
cat > "$B/nft" <<'EOF'
#!/bin/sh
if [ "$1 $2 $3" = "-c -f -" ]; then grep -q BROKEN && { echo "Error: syntax error, unexpected junk" >&2; exit 1; }; exit 0; fi
[ "$1 $2" = "list table" ] || exit 1
f="$ST/nft.$3.$4"; [ -f "$f" ] || { echo "Error: No such file or directory" >&2; exit 1; }; cat "$f"
EOF
cat > "$B/fw4" <<'EOF'
#!/bin/sh
[ "$1" = print ] && [ -f "$ST/fw4.out" ] && { cat "$ST/fw4.out"; exit 0; }
exit 1
EOF
# umount <FB_ROOT><mountpoint>: drops that line from the fixture's /proc/mounts (and logs the call)
cat > "$B/umount" <<'EOF'
#!/bin/sh
m=${1#"$FB_ROOT"}; echo "$m" >> "$ST/umount.log"
awk -v m="$m" '$2 != m' "$FB_ROOT/proc/mounts" > "$FB_ROOT/proc/mounts.new" && mv "$FB_ROOT/proc/mounts.new" "$FB_ROOT/proc/mounts"
EOF
# provd: a real process with this run's own name (Ubuntu's busybox ash runs its own pidof applet before PATH; the node's
# busybox has no SH_STANDALONE, but a real process works for both). Killed by pid, never by name.
PN=bp${T##*.}; export FB_PROVD=$PN FB_UMOUNT=$B/umount   # bp + mktemp's random suffix: unique per run
FB_UID=$(id -u); export FB_UID   # the pid directory's owner (root on a node)
cp "$(command -v sleep)" "$T/$PN"
# the long sleeps (a verb's leaked child, the outside holder): a copy of sleep named for this run, so another
# instance's (or an older version's) kill-by-name cannot reach them
SLP=$T/sl${T##*.}; cp "$(command -v sleep)" "$SLP"; export SLP
provd_up(){ [ -n "${PP:-}" ] && kill -0 "$PP" 2>/dev/null || { "$T/$PN" 300 & PP=$!; echo "$PP" >> "$T/pids"; }; sleep 0.2; }
provd_down(){ [ -n "${PP:-}" ] && kill "$PP" 2>/dev/null; wait "$PP" 2>/dev/null; PP=""; sleep 0.2; }
# batman-slot: modes (in $ST/slot) good | leak (a child keeps fd 9) | nolock (rc 0, no lock) | die17 (detect_layout's 17,
# before the lock) | rc16 / rc17 (a refusal after the lock) | leak16 (both) | mountleft (bootinfo B leaves its FAT mounted)
# | envleak (a child started by `env -i`, without the token, keeps fd 9) | rc14 (tboot_elsewhere: rc 14 after the lock).
# is-trial: rc 0 when $ST/trial exists, else 1 (it takes no lock); every call is logged in $ST/calls
cat > "$B/batman-slot" <<'EOF'
#!/bin/sh
. "$SLK_RD"; m=$(cat "$ST/slot" 2>/dev/null); echo "$*" >> "$ST/calls"
[ "$1" = is-trial ] && { [ -f "$ST/trial" ] && exit 0; exit 1; }
case "$1" in bootinfo | precheck-node) ;; *) exit 2 ;; esac
[ "$m" = die17 ] && exit 17
[ "$m" = nolock ] && exit 0
batman_rundir; exec 9>>"$RUNDIR/batman-slot.flock"; flock -n 9 || exit 14
[ "$m" = rc14 ] && exit 14
case "$m" in leak | leak16) "$SLP" 3 & echo $! >> "$ST/kids" ;; envleak) env -i "$SLP" 3 & echo $! >> "$ST/kids" ;; esac
p=$$; [ "$m" = mountleft ] && [ "$1 $2" = "bootinfo B" ] && echo "/dev/mmcblk0p3 /mnt/slotboot.$p vfat ro,relatime 0 0" >> "$FB_ROOT/proc/mounts"
case "$m" in rc16 | leak16) exit 16 ;; rc17) exit 17 ;; esac
[ "$1" = precheck-node ] && exit 12
exit 0
EOF
chmod +x "$B"/*
# ---- the fixture tree
HTTP='add table bridge batman_http
delete table bridge batman_http
table bridge batman_http {
	chain input {
		type filter hook input priority -10; policy accept;
		iifname != "phy*" meta mark set meta mark & 0xfeffffff comment "batman-http: clear"
		iifname "phy*" meta mark set meta mark | 0x01000000 comment "batman-http: mark"
	}
}
add table inet batman_http_in
delete table inet batman_http_in
table inet batman_http_in {
	chain input {
		type filter hook input priority -10; policy accept;
		tcp dport 8095 meta iifname != "br-ahwlan" counter drop comment "batman-http: iif"
		tcp dport 8095 meta mark & 0x01000000 == 0 counter drop comment "batman-http: mark-drop"
	}
}'
INIT='BDIR=/tmp/run/batman-provd-bulk
_bulk_mount() {
	case "$(sed -n s/^BATMAN_BOARD=//p /etc/batman-build 2>/dev/null)" in
	ekh-bcm2711 | ekh-bcm2710) sz=252619530 ;;
	*) return 1 ;;
	esac
	mount -t tmpfs -o nodev,nosuid,noexec,mode=0700,nr_inodes=16,size=$sz,uid=471,gid=471 batman-provd-bulk "$BDIR"
}'
MNT='batman-provd-bulk /tmp/run/batman-provd-bulk tmpfs rw,nosuid,nodev,noexec,relatime,size=246700k,nr_inodes=16,mode=700,uid=471,gid=471 0 0'
good(){
	killrec; rm -rf "$FR" "${ST:?}"/* "$T/run/batman"; mkdir -p "$FR/etc/init.d" "$FR/proc/sys/kernel/random" "$FR/usr/sbin" "$FR/rom/usr/share/nftables.d/ruleset-post" "$FR/usr/share/nftables.d/ruleset-post" "$FR/tmp/run/batman-provd-bulk" "$FR/mnt"
	printf 'BATMAN_VERSION=1.5.14-wsl.26+abc.fwdef\nBATMAN_BOARD=%s\n' "${1:-ekh-bcm2711}" > "$FR/etc/batman-build"
	echo "500.10 900.00" > "$FR/proc/uptime"; echo "0123456789ab-x" > "$FR/proc/sys/kernel/random/boot_id"
	printf '#!/bin/sh\nslot_lock() {\n:\n}\n' > "$FR/usr/sbin/batman-slot"
	printf '%s\n' "$HTTP" > "$FR/rom/usr/share/nftables.d/ruleset-post/batman-http.nft"; cp "$FR/rom/usr/share/nftables.d/ruleset-post/batman-http.nft" "$FR/usr/share/nftables.d/ruleset-post/"
	printf '%s\n' "$INIT" > "$FR/etc/init.d/batman-provd"
	printf 'proc /proc proc rw 0 0\n%s\n' "$MNT" > "$FR/proc/mounts"
	# the slot boot FATs as batman-slot's tboot_elsewhere reads them: p1 (A) at /boot only
	mkdir -p "$FR/proc/self" "$FR/sys/class/block/mmcblk0p1" "$FR/sys/class/block/mmcblk0p3"
	echo 179:1 > "$FR/sys/class/block/mmcblk0p1/dev"; echo 179:3 > "$FR/sys/class/block/mmcblk0p3/dev"
	printf '22 1 0:19 / /proc rw,nosuid - proc proc rw\n31 22 179:1 / /boot rw,noatime - vfat /dev/mmcblk0p1 rw\n' > "$FR/proc/self/mountinfo"
	echo 'table inet fw4 { }' > "$ST/nft.inet.fw4"; printf 'table inet fw4 {\n}\ninclude "/usr/share/nftables.d/ruleset-post/batman-http.nft"\n' > "$ST/fw4.out"
	printf 'table bridge batman_http {\n\tchain input {\n\t\tiifname != "phy*" meta mark set meta mark & 0xfeffffff comment "batman-http: clear"\n\t\tiifname "phy*" meta mark set meta mark | 0x01000000 comment "batman-http: mark"\n\t}\n}\n' > "$ST/nft.bridge.batman_http"
	printf 'table inet batman_http_in {\n\tchain input {\n\t\ttcp dport 8095 iifname != "br-ahwlan" counter packets 0 bytes 0 drop comment "batman-http: iif"\n\t\ttcp dport 8095 meta mark & 0x01000000 == 0x00000000 counter packets 0 bytes 0 drop comment "batman-http: mark-drop"\n\t}\n}\n' > "$ST/nft.inet.batman_http_in"
	provd_up; echo good > "$ST/slot"
}
run(){ cat "$REPO/scripts/node/slotlock-lib-254.sh" "$REPO/scripts/node/fw-boot-254.sh" | PATH="$B:$PATH" FB_ROOT=$FR $SHX 2>&1; echo "rc=$?"; }
deadpid(){ sleep 0 & local p=$!; wait $p; echo $p; }
SHS="dash"; command -v busybox >/dev/null && SHS="busybox_ash dash"
for s in $SHS; do
	case $s in busybox_ash) SHX="busybox ash -s" ;; *) SHX="dash -s" ;; esac; k=${s%%_*}
	good; o=$(run)
	has "$k good node -> RESULT PASS" "$o" "^RESULT prov-fw-boot-254 PASS"
	has "$k good: FB1 fw4" "$o" "^PASS .*FB1 inet fw4 loaded"
	has "$k good: FB2 fw4 print | nft -c" "$o" "^PASS .*FB2 fw4 print \| nft -c -f -: rc 0"
	has "$k good: FB4 each of the 4 rules once" "$(grep -c 'loaded once' <<< "$o")" "^4$"
	has "$k good: FB5 the tmpfs options" "$o" "^PASS .*FB5 /tmp/run/batman-provd-bulk: tmpfs"
	has "$k good: FB6 three verbs, lock free" "$(grep -c '^PASS .*FB6 .*free <= 1 s' <<< "$o")" "^3$"
	hasnt "$k good: no FAIL / INVALID" "$o" "^(FAIL|INVALID)"
	has "$k good: the three verb pids recorded" "$(grep -cx '[0-9][0-9]*' "$FR/tmp/run/batman-dv/fw-boot-254.pids" 2>/dev/null)" "^3$"
	good ekh-bcm2710; o=$(run)
	has "$k bcm2710 good node -> RESULT PASS (two-board rule)" "$o" "^RESULT prov-fw-boot-254 PASS"
	has "$k bcm2710: FB5 the size read for its board" "$o" "^PASS .*FB5 .*size=252619530 B"
	good ekh-bcm2712; o=$(run); has "$k an unknown board -> FAIL FB5 (no size for it)" "$o" "^FAIL .*FB5 cannot read .* the size for ekh-bcm2712 \[\]"
	good; printf '#!/bin/sh\nmkdir_lock() { :; }\n' > "$FR/usr/sbin/batman-slot"; o=$(run)
	has "$k pre-S5 image -> one FAIL line" "$o" "^FAIL prov-fw-boot-254: pre-S5 image 1.5.14-wsl.26.*: batman-slot has no slot flock \(slot_lock\)"
	has "$k pre-S5 -> RESULT FAIL rc 1" "$(echo $o)" "RESULT prov-fw-boot-254 FAIL rc=1"
	has "$k pre-S5: exactly one FAIL, no PASS / INVALID" "$(grep -cE '^(PASS|FAIL|INVALID)' <<< "$o")" "^1$"
	good; rm "$ST/nft.inet.fw4"; o=$(run); has "$k fw4 missing -> FAIL FB1" "$o" "^FAIL .*FB1 inet fw4 missing"
	has "$k fw4 missing -> RESULT FAIL" "$o" "^RESULT prov-fw-boot-254 FAIL"
	good; echo BROKEN >> "$ST/fw4.out"; o=$(run); has "$k fw4's ruleset refused by nft -c -> FAIL FB2" "$o" "^FAIL .*FB2 fw4 print \| nft -c -f -: rc 1: Error: syntax error"
	good; rm "$ST/fw4.out"; o=$(run); has "$k fw4 print failing -> FAIL FB2" "$o" "^FAIL .*FB2 fw4 print failed \(rc 1"
	good; rm "$ST/nft.bridge.batman_http"; o=$(run); has "$k bridge table missing -> FAIL" "$o" "^FAIL .*table bridge batman_http missing"
	good; sed -i 's/\(comment "batman-http: iif"\)/\1\n\t\ttcp dport 8095 drop comment "batman-http: iif"/' "$ST/nft.inet.batman_http_in"; o=$(run)
	has "$k a rule loaded twice -> FAIL" "$o" '^FAIL .*rule "batman-http: iif" loaded 2 times'
	good; echo "# local edit" >> "$FR/usr/share/nftables.d/ruleset-post/batman-http.nft"; o=$(run); has "$k overlay include -> FAIL" "$o" "^FAIL .*differs from the image"
	good; sed -i 's/ comment "[^"]*"//' "$FR/rom/usr/share/nftables.d/ruleset-post/batman-http.nft"; cp "$FR/rom/usr/share/nftables.d/ruleset-post/batman-http.nft" "$FR/usr/share/nftables.d/ruleset-post/"; o=$(run)
	has "$k include without rule comments -> FAIL (nothing to check by)" "$o" "^FAIL .*no commented rule in table bridge batman_http"
	good; sed -i 's/noexec,//' "$FR/proc/mounts"; o=$(run); has "$k tmpfs without noexec -> FAIL" "$o" "^FAIL .*FB5 .* lack: noexec"
	good; sed -i 's/size=246700k/size=262144k/' "$FR/proc/mounts"; o=$(run); has "$k tmpfs of another size -> FAIL" "$o" "^FAIL .*FB5 .* lack: size=246700k"
	good; printf 'proc /proc proc rw 0 0\n' > "$FR/proc/mounts"; o=$(run); has "$k provd up, tmpfs not mounted -> FAIL" "$o" "^FAIL .*FB5 provd runs but .* is not mounted"
	good; printf '%s\n%s\n' "$MNT" "$MNT" > "$FR/proc/mounts"; o=$(run); has "$k tmpfs stacked -> FAIL" "$o" "^FAIL .*FB5 .* mounted more than once"
	good; provd_down; o=$(run); has "$k provd not running -> recorded" "$o" "^INFO .*FB5 batman-provd not running"
	has "$k provd not running -> the rest still PASS" "$o" "^RESULT prov-fw-boot-254 PASS"
	good; echo leak > "$ST/slot"; o=$(run); has "$k a verb's child keeps fd 9 -> FAIL FB6 (negative control)" "$o" "^FAIL .*FB6 batman-slot bootinfo A .* left the slot flock held by its own process"
	has "$k leak -> RESULT FAIL" "$o" "^RESULT prov-fw-boot-254 FAIL"
	# review r2 A-MAJOR-2: a refusal of the node's state after the lock is not a FAIL of the lock
	good; echo rc16 > "$ST/slot"; o=$(run); has "$k verbs rc 16 after taking the lock -> PASS (judged by the lock)" "$o" "^RESULT prov-fw-boot-254 PASS"
	has "$k rc 16: the lock judged for all three verbs" "$(grep -c '^PASS .*FB6 .*(rc 16): the slot flock is free' <<< "$o")" "^3$"
	has "$k rc 16: recorded as the node's state" "$o" "^INFO .*FB6 batman-slot precheck-node rc 16 — a refusal of this node's state"
	good; echo rc17 > "$ST/slot"; o=$(run); has "$k verbs rc 17 after taking the lock -> PASS" "$o" "^RESULT prov-fw-boot-254 PASS"
	good; echo leak16 > "$ST/slot"; o=$(run); has "$k rc 16 + a child keeping fd 9 -> still FAIL (the lock check is not skipped)" "$o" "^FAIL .*FB6 batman-slot bootinfo A \(rc 16\) left the slot flock held"
	good; echo die17 > "$ST/slot"; o=$(run); has "$k detect_layout 17 before the lock, no lock file -> INVALID" "$o" "^INVALID .*FB6 batman-slot bootinfo A: rc 17 and no lock file"
	has "$k die17, no lock file -> RESULT INVALID (not FAIL)" "$o" "^RESULT prov-fw-boot-254 INVALID"
	good; echo die17 > "$ST/slot"; mkdir -m 700 "$T/run/batman"; : > "$T/run/batman/batman-slot.flock"; o=$(run)
	has "$k detect_layout 17, a lock file from earlier -> PASS (the lock is free)" "$o" "^RESULT prov-fw-boot-254 PASS"
	good; echo nolock > "$ST/slot"; o=$(run); has "$k a verb rc 0 that never takes the lock -> FAIL nofile" "$o" "^FAIL .*FB6 .*\(rc 0\): no lock file afterwards"
	good; echo mountleft > "$ST/slot"; o=$(run); has "$k bootinfo B leaving its FAT mounted -> FAIL" "$o" "^FAIL .*FB6 batman-slot bootinfo B \(pid [0-9]+, rc 0\) returned but left /mnt/slotboot.[0-9]+ mounted"
	has "$k mountleft: unmounted again" "$(grep -c slotboot "$FR/proc/mounts")" "^0$"
	# an earlier run's leftover (that remote shell killed): a dead recorded pid -> unmounted; a live batman-slot -> untouched
	good; d=$(deadpid); mkdir -p "$T/live"; cp "$(command -v sleep)" "$T/live/batman-slot"; "$T/live/batman-slot" 30 & lp=$!; echo "$lp" >> "$T/pids"
	mkdir -m 700 -p "$FR/tmp/run/batman-dv"; printf '%s\n%s\nx1\n' "$d" "$lp" > "$FR/tmp/run/batman-dv/fw-boot-254.pids"
	printf '/dev/mmcblk0p3 /mnt/slotboot.%s vfat ro 0 0\n/dev/mmcblk0p3 /mnt/slotboot.%s vfat ro 0 0\n' "$d" "$lp" >> "$FR/proc/mounts"; o=$(run)
	has "$k leftover of a dead recorded pid -> unmounted (INFO)" "$o" "^INFO .*FB6 unmounted /mnt/slotboot.$d — left by an earlier run"
	has "$k leftover: gone from the mounts" "$(grep -c "/mnt/slotboot.$d " "$FR/proc/mounts")" "^0$"
	has "$k a live batman-slot's mount is untouched" "$(grep -c "/mnt/slotboot.$lp " "$FR/proc/mounts")" "^1$"
	has "$k leftover run -> RESULT PASS" "$o" "^RESULT prov-fw-boot-254 PASS"
	kill "$lp" 2>/dev/null; wait "$lp" 2>/dev/null
	# review r3 B-m1: a mount of an UNRECORDED dead pid is not ours -> left alone (only recorded pids are ever unmounted)
	good; d=$(deadpid); mkdir -m 700 -p "$FR/tmp/run/batman-dv"; : > "$FR/tmp/run/batman-dv/fw-boot-254.pids"
	printf '/dev/mmcblk0p3 /mnt/slotboot.%s vfat ro 0 0\n' "$d" >> "$FR/proc/mounts"; o=$(run)
	has "$k an unrecorded /mnt/slotboot.<dead pid> is left mounted" "$(grep -c "/mnt/slotboot.$d " "$FR/proc/mounts")" "^1$"
	hasnt "$k unrecorded: never passed to umount" "$(cat "$ST/umount.log" 2>/dev/null)" "slotboot.$d\$"
	hasnt "$k unrecorded: no 'unmounted' line" "$o" "unmounted /mnt/slotboot.$d"
	good; ln -s "$T" "$FR/tmp/run/batman-dv"; o=$(run)
	has "$k a symlinked pid dir -> not used (INFO), the run goes on" "$o" "^INFO .*FB6 .* is not a directory of ours"
	has "$k symlinked pid dir -> RESULT PASS" "$o" "^RESULT prov-fw-boot-254 PASS"
	# review r3 B-m1: mode 0755, or another owner -> not ours: nothing recorded, a recorded dead pid's mount not touched
	for c in mode owner; do
		good; d=$(deadpid); mkdir -m 700 -p "$FR/tmp/run/batman-dv"; echo "$d" > "$FR/tmp/run/batman-dv/fw-boot-254.pids"
		printf '/dev/mmcblk0p3 /mnt/slotboot.%s vfat ro 0 0\n' "$d" >> "$FR/proc/mounts"
		if [ $c = mode ]; then chmod 755 "$FR/tmp/run/batman-dv"; o=$(run); else o=$(FB_UID=$((FB_UID + 4242)) run); fi
		has "$k pid dir of another $c -> not used (INFO)" "$o" "^INFO .*FB6 .* is not a directory of ours"
		has "$k pid dir of another $c -> its recorded mount not touched" "$(grep -c "/mnt/slotboot.$d " "$FR/proc/mounts")" "^1$"
		has "$k pid dir of another $c -> no verb pid written to it" "$(cat "$FR/tmp/run/batman-dv/fw-boot-254.pids")" "^$d\$"
	done
	# review r3 A-m1: a child the verb started with `env -i` (no DV_SLK token) keeps fd 9 -> still the verb's: FAIL
	good; echo envleak > "$ST/slot"; o=$(run)
	has "$k an env -i child keeping fd 9 -> FAIL FB6 (the step window)" "$o" "^FAIL .*FB6 batman-slot bootinfo A \(rc 0\) left the slot flock held by its own process"
	# review r3 B-m5: a trial autocommit gates -> NOT-RUN, no verb run; a trial nobody gates -> the verbs run
	good; : > "$ST/trial"; mkdir -p "$T/ac" "$T/run/batman/autocommit.run"; cp "$(command -v sleep)" "$T/ac/batman-autocommit"
	"$T/ac/batman-autocommit" 30 & ap=$!; echo "$ap" >> "$T/pids"; echo "$ap" > "$T/run/batman/autocommit.run/pid"; o=$(run)
	has "$k a trial autocommit gates -> NOT-RUN line" "$o" "^NOT-RUN prov-fw-boot-254: FB6 this boot is an uncommitted trial .* batman-autocommit \(pid $ap\)"
	has "$k gated trial -> no lock-holding verb run" "$(grep -cv '^is-trial' "$ST/calls")" "^0$"
	has "$k gated trial -> RESULT PASS (FB1-FB5 judged)" "$o" "^RESULT prov-fw-boot-254 PASS"
	kill "$ap" 2>/dev/null; wait "$ap" 2>/dev/null
	good; : > "$ST/trial"; o=$(run)
	has "$k a trial nobody gates -> the verbs run, judged" "$(grep -c '^PASS .*FB6 .*free <= 1 s' <<< "$o")" "^3$"
	has "$k ungated trial -> INFO" "$o" "^INFO .*FB6 an uncommitted trial .* that no batman-autocommit gates"
	# the lock held through the tries (a fast sleep for these cases only). The holder IS the process (exec), so killing
	# its pid frees the lock; each case starts only once it holds the lock.
	# review r3 A-MAJOR-2: by an orphan (no batman-slot among its ancestors, not the harness) -> FAIL, a leaked fd 9
	good; mkdir -p "$T/run/batman"; chmod 700 "$T/run/batman"; ( flock -x 7; exec "$SLP" 30 ) 7>>"$T/run/batman/batman-slot.flock" & hp=$!; echo "$hp" >> "$T/pids"
	i=0; while flock -n "$T/run/batman/batman-slot.flock" true && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
	printf '#!/bin/sh\nexec /bin/sleep 0.05\n' > "$B/sleep"; chmod +x "$B/sleep"; o=$(run); rm -f "$B/sleep"; kill $hp 2>/dev/null; wait $hp 2>/dev/null
	has "$k lock held by an orphan -> FAIL FB6 leaked fd 9" "$o" "^FAIL .*FB6 batman-slot bootinfo A: the slot flock is held through 5 tries by $hp:${SLP##*/} .* a leaked fd 9"
	has "$k held by an orphan -> RESULT FAIL" "$o" "^RESULT prov-fw-boot-254 FAIL"
	# by a batman-slot (a legitimate writer, e.g. a 600 s write) -> INVALID
	good; mkdir -p "$T/run/batman" "$T/live"; chmod 700 "$T/run/batman"; cp "$(command -v sleep)" "$T/live/batman-slot"
	( flock -x 7; exec "$T/live/batman-slot" 30 ) 7>>"$T/run/batman/batman-slot.flock" & hp=$!; echo "$hp" >> "$T/pids"
	i=0; while flock -n "$T/run/batman/batman-slot.flock" true && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
	printf '#!/bin/sh\nexec /bin/sleep 0.05\n' > "$B/sleep"; chmod +x "$B/sleep"; o=$(run); rm -f "$B/sleep"; kill $hp 2>/dev/null; wait $hp 2>/dev/null
	has "$k lock held by a batman-slot -> INVALID FB6 (a legitimate writer)" "$o" "^INVALID .*FB6 batman-slot bootinfo A: the lock stayed busy for 5 tries, held by a legitimate writer .* $hp:batman-slot"
	has "$k held by a batman-slot -> RESULT INVALID" "$o" "^RESULT prov-fw-boot-254 INVALID"
	# review r3 B-M1: rc 14 x 5 with the lock free and B's boot FAT mounted at /mnt/_ab (tboot_elsewhere) -> FAIL
	good; echo rc14 > "$ST/slot"; echo '40 31 179:3 / /mnt/_ab ro,relatime - vfat /dev/mmcblk0p3 ro' >> "$FR/proc/self/mountinfo"
	printf '#!/bin/sh\nexec /bin/sleep 0.05\n' > "$B/sleep"; chmod +x "$B/sleep"; o=$(run); rm -f "$B/sleep"
	has "$k rc 14, lock free, B's FAT at /mnt/_ab -> FAIL naming it" "$o" "^FAIL .*FB6 batman-slot bootinfo A: rc 14 x 5 with the slot flock free — mmcblk0p3 \(179:3\) is mounted at /mnt/_ab: every slot verb"
	has "$k B's FAT elsewhere -> RESULT FAIL" "$o" "^RESULT prov-fw-boot-254 FAIL"
	good; echo rc14 > "$ST/slot"
	printf '#!/bin/sh\nexec /bin/sleep 0.05\n' > "$B/sleep"; chmod +x "$B/sleep"; o=$(run); rm -f "$B/sleep"
	has "$k rc 14, lock free, nothing mounted elsewhere -> INVALID (cannot tell)" "$o" "^INVALID .*FB6 batman-slot bootinfo A: rc 14 x 5 but the slot flock is free and no slot boot FAT is mounted outside /boot"
	has "$k rc 14, nothing elsewhere -> RESULT INVALID" "$o" "^RESULT prov-fw-boot-254 INVALID"
done
# ---- host side: chk_fw_boot_254 aggregation (ssh stub) and rk_judge
# shellcheck source=scripts/dv/s5-254.sh
. "$REPO/scripts/dv/s5-254.sh"
# shellcheck source=scripts/dv/known-failures.sh
. "$REPO/scripts/dv/known-failures.sh"
cat > "$B/ssh" <<'EOF'
#!/bin/sh
[ -f "$ST/ssh.exec" ] && exec dash -s
cat >/dev/null; cat "$ST/ssh.out"; exit 0
EOF
chmod +x "$B/ssh"
fb(){ printf '%s\n' "$@" > "$ST/ssh.out"; o=$(PATH="$B:$PATH" chk_fw_boot_254 n1 2>&1; echo "rc=$?"); }
fb "PASS prov-fw-boot-254: x" "RESULT prov-fw-boot-254 PASS"; has "host: PASS -> rc 0" "$o" "rc=0$"
fb "INVALID prov-fw-boot-254: busy" "RESULT prov-fw-boot-254 INVALID"; has "host: INVALID -> SKIP-REASON, rc 3" "$(echo $o)" "SKIP-REASON: prov-fw-boot-254: 1 node.* INVALID.* rc=3$"
fb "FAIL prov-fw-boot-254: x" "RESULT prov-fw-boot-254 FAIL"; has "host: FAIL -> rc 1" "$o" "rc=1$"
fb "NOT-RUN prov-fw-boot-254: FB6 trial" "RESULT prov-fw-boot-254 PASS"; has "host: a NOT-RUN line carries the node" "$o" "^NOT-RUN n1: prov-fw-boot-254: FB6 trial"
fb "PASS prov-fw-boot-254: x"; has "host: no RESULT line -> FAIL rc 1" "$(echo $o)" "FAIL prov-fw-boot-254: n1: no verdict.* rc=1$"
o=$(chk_fw_boot_254 2>&1; echo "rc=$?"); has "host: no node -> FAIL rc 1" "$(echo $o)" "FAIL prov-fw-boot-254: no node checked rc=1"
# pre-S5 end to end (the node script on the pre-S5 fixture behind the ssh stub) -> the suite log -> kf_classify against
# the real list: KNOWN before the entry's expiry, NEW after it (review r2 B-MAJOR-1)
good; printf '#!/bin/sh\nmkdir_lock() { :; }\n' > "$FR/usr/sbin/batman-slot"; : > "$ST/ssh.exec"
o=$(PATH="$B:$PATH" FB_ROOT=$FR chk_fw_boot_254 10.41.80.13 2>&1; echo "rc=$?"); rm -f "$ST/ssh.exec"; printf '%s\n' "$o" > "$T/fwboot.log"
has "host: pre-S5 node -> its FAIL line with the node" "$o" "^FAIL 10.41.80.13: prov-fw-boot-254: pre-S5 image 1.5.14-wsl.26"
has "host: pre-S5 node -> rc 1 (a FAIL, not a SKIP)" "$o" "^rc=1$"
hasnt "host: pre-S5 node -> no SKIP-REASON" "$o" "SKIP-REASON"
KX=$(awk -F'\t' '$1 == "prov-fw-boot-254" { sub(/^expires=/, "", $4); print $4; exit }' "$REPO/scripts/validation-known-failures.txt")
has "known-failures: prov-fw-boot-254 has an entry with an expiry" "$KX" "^20[0-9]{2}-[0-9]{2}-[0-9]{2}$"
c=$(KF_NO_GH=1 kf_classify prov-fw-boot-254 "$T/fwboot.log" "$REPO/scripts/validation-known-failures.txt" "$KX"); has "kf: pre-S5 on the expiry day -> KNOWN #254" "$c" "^known #254"
c=$(KF_NO_GH=1 kf_classify prov-fw-boot-254 "$T/fwboot.log" "$REPO/scripts/validation-known-failures.txt" "$(date -d "$KX + 1 day" +%F)"); has "kf: pre-S5 the day after the expiry -> NEW (expired)" "$c" "^new \(the entry for #254 $KX has expired"
printf 'FAIL 10.41.80.13: prov-fw-boot-254: FB1 inet fw4 missing: no firewall\n' > "$T/fw2.log"
c=$(KF_NO_GH=1 kf_classify prov-fw-boot-254 "$T/fw2.log" "$REPO/scripts/validation-known-failures.txt" "$KX"); has "kf: any other prov-fw-boot-254 FAIL -> NEW" "$c" "^new \(unmatched"
TP=$(tr -d '\r\n' < "$REPO/tests/keys/T.pub"); R1=04$(printf '%0128d' 7); TF=$(rk_fpr "$TP")
rk(){ o=$(rk_judge n1 "$1" "${2:-$TP}" "${3:-}"; echo "rc=$?"); }
rk "RK ver=1.5.14-wsl.26+a.fwb.bench bench=T pub=$TP ser=1 stamp=rom"; has "rk: bench stamp + T + serial -> PASS" "$(echo $o)" "^PASS .*bench build, trusts T.* rc=0$"
rk "RK ver=1.5.14-wsl.26+a.fwb bench=- pub=$TP ser=1 stamp=rom"; has "rk: T without the bench stamp -> FAIL" "$(echo $o)" "^FAIL .*trusts the TEST root T but its stamp is not a bench build.* rc=1$"
rk "RK ver=1.5.14-wsl.26+a.fwb.bench bench=T pub=- ser=- stamp=rom"; has "rk: bench stamp, no T -> FAIL" "$(echo $o)" "^FAIL .*stamp says bench .* does not trust T.* rc=1$"
rk "RK ver=1.5.14-wsl.26+a.fwb.bench bench=T pub=$R1 ser=1 stamp=rom"; has "rk: bench stamp, another root -> FAIL" "$(echo $o)" "^FAIL .*stamp says bench.* rc=1$"
rk "RK ver=1.5.14-rel.3+a.fwb bench=X pub=$R1 ser=1 stamp=rom"; has "rk: unknown BATMAN_BENCH_TRUST -> FAIL" "$(echo $o)" "^FAIL .*BATMAN_BENCH_TRUST=\[X\].* rc=1$"
rk "RK ver=1.5.14-wsl.26+a.fwb bench=T pub=$TP ser=1 stamp=rom"; has "rk: bench without .bench in the version -> FAIL" "$(echo $o)" "^FAIL .*lacks .bench.* rc=1$"
rk "RK ver= bench=- pub=- ser=- stamp=none"; has "rk: no stamp -> FAIL" "$(echo $o)" "^FAIL .*no image stamp.* rc=1$"
rk "RK ver=1.5.14-wsl.26+a.fwb bench=- pub=empty ser=1 stamp=rom"; has "rk: an empty key file -> FAIL bad" "$(echo $o)" "^FAIL .*bad for the helper.* rc=1$"
rk ""; has "rk: no answer -> FAIL" "$(echo $o)" "^FAIL .*no answer.* rc=1$"
rk "RK ver=1.5.14-wsl.26+a.fwb bench=- pub=- stamp=rom"; has "rk: an answer without ser= (an old RK_Q) -> FAIL" "$(echo $o)" "^FAIL .*lacks pub= / ser=.* rc=1$"
rk "RK ver=1.5.14-wsl.26+a.fwb bench=- pub=- ser=- stamp=rom"; has "rk: no key, no serial, no bench -> PASS trusts none" "$(echo $o)" "^PASS .*trusts none.* rc=0$"
rk "RK ver=1.5.14-rel.3+a.fwb bench=- pub=$R1 ser=3 stamp=rom"; has "rk: another root + serial, no bench -> PASS" "$(echo $o)" "^PASS .*not T.* rc=0$"
rk "RK ver=1.5.14-wsl.26+a.fwb bench=- pub=- ser=- stamp=rom" "04zz"; has "rk: a broken harness T.pub -> FAIL, not a PASS" "$(echo $o)" "^FAIL .*T.pub is not one P-256 point.* rc=1$"
# LoadTrust (release.go:113-123): one file only = bad, not "trusts T" / "trusts none" (review r2 A-m2 / B-m10)
rk "RK ver=1.5.14-wsl.26+a.fwb.bench bench=T pub=$TP ser=- stamp=rom"; has "rk: T without release-min-serial -> FAIL bad (was PASS trusts T)" "$(echo $o)" "^FAIL .*bad for the helper.* rc=1$"
rk "RK ver=1.5.14-wsl.26+a.fwb bench=- pub=- ser=1 stamp=rom"; has "rk: release-min-serial without a pub -> FAIL bad (was PASS none)" "$(echo $o)" "^FAIL .*bad for the helper.* rc=1$"
rk "RK ver=1.5.14-rel.3+a.fwb bench=- pub=$R1 ser=0 stamp=rom"; has "rk: serial 0 -> FAIL bad" "$(echo $o)" "^FAIL .*bad for the helper.* rc=1$"
rk "RK ver=1.5.14-rel.3+a.fwb bench=- pub=$R1 ser=01 stamp=rom"; has "rk: serial with a leading 0 -> FAIL bad" "$(echo $o)" "^FAIL .*bad for the helper.* rc=1$"
rk "RK ver=1.5.14-rel.3+a.fwb bench=- pub=lines ser=1 stamp=rom"; has "rk: a two-line pub -> FAIL bad" "$(echo $o)" "^FAIL .*bad for the helper.* rc=1$"
# status key 15 cross-check (the helper's own reading)
rk "RK ver=1.5.14-wsl.26+a.fwb.bench bench=T pub=$TP ser=1 stamp=rom" "" "$TF"; has "rk: status trust = T's fingerprint -> PASS agrees" "$(echo $o)" "^PASS .*status trust=$TF agrees.* rc=0$"
rk "RK ver=1.5.14-wsl.26+a.fwb.bench bench=T pub=$TP ser=1 stamp=rom" "" none; has "rk: status trust none but /rom has T -> FAIL" "$(echo $o)" "^FAIL .*status key 15 trust=\[none\] but /rom gives \[$TF\].* rc=1$"
rk "RK ver=1.5.14-rel.3+a.fwb bench=- pub=$R1 ser=1 stamp=rom" "" bad; has "rk: status trust bad (e.g. off-curve) -> FAIL" "$(echo $o)" "^FAIL .*trust=\[bad\].* rc=1$"
rk "RK ver=1.5.14-wsl.26+a.fwb bench=- pub=- ser=- stamp=rom" "" none; has "rk: none and status none -> PASS agrees" "$(echo $o)" "^PASS .*trusts none.*status trust=none agrees.* rc=0$"
# RK_Q against fixture files (the /rom paths rewritten into a temp tree)
mkdir -p "$T/rk/rom/usr/share/batman" "$T/rk/rom/etc"; RD=$T/rk/rom/usr/share/batman
printf 'BATMAN_VERSION=1.5.14-wsl.26+a.fwb.bench\nBATMAN_BENCH_TRUST=T\n' > "$T/rk/rom/etc/batman-build"; cp "$REPO/tests/keys/T.pub" "$RD/release-root.pub"; echo 1 > "$RD/release-min-serial"
q=${RK_Q//\/rom\//$T/rk/rom/}
qs(){ if command -v busybox >/dev/null; then busybox sh -c "$q"; else sh -c "$q"; fi; }
l=$(qs); rk "$l"; has "rk: RK_Q on a bench fixture -> PASS" "$(echo $o)" "^PASS .*bench build.* rc=0$"
rm "$RD/release-min-serial"; l=$(qs); rk "$l"; has "rk: RK_Q, T without a release-min-serial file -> FAIL bad" "$(echo $o)" "^FAIL .*bad for the helper.*release-min-serial=\[-\].* rc=1$"
printf '1\n2\n' > "$RD/release-min-serial"; l=$(qs); rk "$l"; has "rk: RK_Q, a two-line serial -> FAIL bad" "$(echo $o)" "^FAIL .*release-min-serial=\[lines\].* rc=1$"
printf '1\r\n' > "$RD/release-min-serial"; l=$(qs); rk "$l"; has "rk: RK_Q, a CRLF serial -> FAIL bad" "$(echo $o)" "^FAIL .*release-min-serial=\[1_\].* rc=1$"
printf '1' > "$RD/release-min-serial"; l=$(qs); rk "$l"; has "rk: RK_Q, a serial without a newline -> PASS (one line)" "$(echo $o)" "^PASS .*bench build.* rc=0$"
printf 'BATMAN_VERSION=1.5.14-wsl.26+a.fwb\n' > "$T/rk/rom/etc/batman-build"
l=$(qs); rk "$l"; has "rk: RK_Q on T without the stamp -> FAIL" "$(echo $o)" "^FAIL .*TEST root T.* rc=1$"
rm "$RD/release-root.pub" "$RD/release-min-serial"; l=$(qs); rk "$l"; has "rk: RK_Q with no key files -> PASS none" "$(echo $o)" "^PASS .*trusts none.* rc=0$"
echo "S5-NODE $P passed, $F failed"
[ "$P" -gt 0 ] && [ "$F" = 0 ]
