#!/bin/bash
# tests/prov-p1/batman-slot-rollback-gate.sh <batman-slot> <prov-lock.sh> — #254 claim-lock fix §8: `batman-slot
# rollback` never makes a slot the default that cannot keep a claimed / member node locked (no ENABLED
# batman-prov-lock in its rootfs). rollback_lock_gate is extracted from the real file and run with the REAL prov-lock.sh
# (overlay meta + p6 field 3 parsing), its paths pointed at a sandbox; mount = a copy of a directory standing in for
# the target squashfs. No root, no node. A run that executes zero cases FAILs.
# Negative control: a batman-slot without the gate (e.g. main 92f091c / 1.5.13) -> FAIL "rollback_lock_gate missing".
set -u
BS=$(readlink -f "${1:?usage: $0 <batman-slot> <prov-lock.sh>}"); LIB=$(readlink -f "${2:?}")
[ -f "$BS" ] && [ -f "$LIB" ] || { echo "FAIL missing $BS or $LIB"; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; fails=0; cases=0
ok(){ echo "ok   $*"; }; no(){ echo "FAIL $*"; fails=$((fails+1)); }
fn=$(awk '/^rollback_lock_gate\(\) \{/,/^\}/' "$BS")
[ -n "$fn" ] || { no "rollback_lock_gate() missing from $BS"; echo "BATMAN-SLOT-ROLLBACK-GATE cases=0 fails=1"; exit 1; }
# the gate must run before the [all] switch (a check after write_autoboot protects nothing)
rb=$(awk '/^cmd_rollback\(\) \{/,/^\}/' "$BS")
g=$(echo "$rb" | grep -n 'rollback_lock_gate "\$T"' | head -1 | cut -d: -f1); w=$(echo "$rb" | grep -n 'write_autoboot' | head -1 | cut -d: -f1)
cases=$((cases+1)); [ -n "$g" ] && [ -n "$w" ] && [ "$g" -lt "$w" ] && ok "cmd_rollback gates the target slot before write_autoboot" || no "cmd_rollback: gate line=${g:-none} write_autoboot line=${w:-none}"
# the lib with its fixed paths moved into the sandbox (the parsing itself is unchanged)
sed -e "s#/proc/mounts#$T/mounts#g" -e "s#/opt/batdata/state#$T/bd/state#g" "$LIB" > "$T/prov-lock.sh"
gate=$(echo "$fn" | sed -e "s#/usr/lib/batman/prov-lock.sh#$T/prov-lock.sh#g" -e "s#/etc/batman-prov#$T/ov#g" -e "s#mktemp -d /tmp/#mktemp -d $T/#")
# mk <overlay: absent|bad|toonew|legacy|unclaimed|claimed|member> <p6 field 3|-(p6 not mounted)> <target: locked|initonly|rconly|none>
mk(){
	rm -rf "$T/ov" "$T/bd" "$T/slotB" "$T"/.rbgate.*; mkdir -p "$T/ov" "$T/bd/state" "$T/slotB/etc/init.d" "$T/slotB/etc/rc.d"
	case "$1" in
		absent) ;;
		bad) echo garbage > "$T/ov/prov.meta" ;;
		toonew) echo "v=2 state=unclaimed gen=1 sha=$(printf '%064d' 0)" > "$T/ov/prov.meta" ;;
		*) printf 'cbor-%s' "$1" > "$T/ov/prov.cbor"; echo "v=1 state=$1 gen=2 sha=$(sha256sum < "$T/ov/prov.cbor" | cut -c1-64)" > "$T/ov/prov.meta" ;;
	esac
	if [ "$2" = - ]; then : > "$T/mounts"; else echo "/dev/mmcblk0p6 /opt/batdata ext4 rw 0 0" > "$T/mounts"; echo "bootid helper $2 legacy - 1" > "$T/bd/state/prov-state"; fi
	case "$3" in
		locked) : > "$T/slotB/etc/init.d/batman-prov-lock"; ln -s ../init.d/batman-prov-lock "$T/slotB/etc/rc.d/S13batman-prov-lock" ;;
		initonly) : > "$T/slotB/etc/init.d/batman-prov-lock" ;;
		rconly) ln -s ../init.d/batman-prov-lock "$T/slotB/etc/rc.d/S13batman-prov-lock" ;;
	esac
}
echo "$gate" > "$T/gate.sh"
cat > "$T/stubs.sh" <<'STUBS'
die(){ echo "DIE $*" >> "$LOG"; exit 1; }
warn(){ echo "WARN $*" >> "$LOG"; }
st(){ echo "st $*" >> "$LOG"; }
allowed(){ [ "$G_ALLOW" = 1 ]; }
slot_rootdev(){ echo "$G_T/slot$1"; }
mount(){ local _d _s; eval "_d=\${$#}; _s=\${$(($# - 1))}"; echo "mount $*" >> "$LOG"; [ "$G_MOUNTFAIL" = 1 ] && return 32; cp -a "$_s"/. "$_d"/; }   # locals: a real mount cannot touch the gate's variables
umount(){ echo "umount $1" >> "$LOG"; rm -rf "${1:?}"/*; }
STUBS
# run [ALLOW] [MOUNTFAIL]: rc + log of DIE / WARN / st / mount lines
run(){
	rm -f "$T/log"
	env -i PATH=/usr/bin:/bin LOG="$T/log" G_T="$T" G_ALLOW="${1:-0}" G_MOUNTFAIL="${2:-0}" \
		bash -c '. "$G_T/stubs.sh"; . "$G_T/gate.sh"; rollback_lock_gate B; echo PASSED >> "$LOG"' </dev/null >/dev/null 2>&1
	RC=$?
}
passed(){ [ "$RC" = 0 ] && grep -q '^PASSED$' "$T/log"; }
refused(){ [ "$RC" != 0 ] && grep -q '^DIE ' "$T/log" && ! grep -q '^PASSED$' "$T/log"; }
mounted(){ grep -q '^mount ' "$T/log"; }
clean(){ ! ls -d "$T"/.rbgate.* >/dev/null 2>&1; }   # no temp dir left behind, refused or not
expect(){ cases=$((cases+1)); if eval "$2"; then ok "$1"; else no "$1 — rc=$RC log=[$(tr '\n' ' ' < "$T/log" 2>/dev/null)]"; fi; }

# not gated: legacy / unclaimed / no record, p6 agreeing -> rollback goes on, the target is not even read
for s in absent legacy unclaimed; do mk "$s" - none; run
	expect "overlay $s, p6 not mounted: not gated (no mount)" 'passed && ! mounted'; done
mk unclaimed unclaimed none; run; expect "unclaimed / p6 unclaimed: not gated" 'passed && ! mounted'
# gated, target keeps the lock -> allowed, traced, temp dir gone
for s in claimed member; do mk "$s" - locked; run
	expect "overlay $s, target has enabled batman-prov-lock: allowed" 'passed && mounted && grep -q "ROLLBACK-LOCK-GATE target=B ok=1" "$T/log" && clean'; done
# gated, target cannot keep the lock -> refused, nothing switched, temp dir gone
for t in none initonly rconly; do mk claimed - "$t"; run
	expect "overlay claimed, target $t: refused" 'refused && grep -q "cannot keep this claimed node locked" "$T/log" && clean'; done
mk member - none; run; expect "overlay member, target none: refused" 'refused && clean'
# the overlay may lie / be unreadable: p6 field 3 or a bad / too-new record still gates (fail-secure)
mk unclaimed claimed none; run; expect "overlay unclaimed but p6 claimed: refused" 'refused'
mk absent member none; run; expect "overlay absent but p6 member: refused" 'refused'
mk bad - none; run; expect "overlay meta bad: refused" 'refused && grep -q "state bad/" "$T/log"'
mk toonew - none; run; expect "overlay meta too new: refused" 'refused'
mk bad - locked; run; expect "overlay meta bad, target locked: allowed" 'passed'
# the target rootfs cannot be read -> refused (never "could not check, go on")
mk claimed - locked; run 0 1; expect "target rootfs unmountable: refused, temp dir removed" 'refused && grep -q "cannot read slot B" "$T/log" && clean'
# operator override: allowed, warned + traced, target not read
mk claimed - none; run 1; expect "override UNLOCKED_ROLLBACK: allowed, warned, no mount" 'passed && ! mounted && grep -q "^WARN rollback lock gate overridden" "$T/log" && grep -q "override=1" "$T/log"'
# no lib (an image without prov-lock.sh) -> not gated (nothing to be claimed by)
mk claimed - none; rm -f "$T/prov-lock.sh"; run; expect "no prov-lock.sh: not gated" 'passed && ! mounted'
echo "BATMAN-SLOT-ROLLBACK-GATE cases=$cases fails=$fails"; [ "$cases" -gt 0 ] && [ $fails = 0 ]
