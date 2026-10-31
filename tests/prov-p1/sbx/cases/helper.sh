#!/bin/sh
# tests/prov-p1/sbx/cases/helper.sh — prov-unit-helper (254-p1-impl §5.1; 254-stage1-impl §4.2 table): the real
# batman-provhelper --boot (prov_test build) against the real batman-config-save and a real p5 (the sandbox loop),
# overlay /etc reset per scenario. Every rc of the table, what the helper does, and the identity-generation rule
# (an identity is generated ONLY for rc 7 / rc 9 with no identity in the overlay and none on p5):
#   7 fresh card -> generated, unclaimed, persisted (p5 then answers --prov-get 0)        0 + overlay -> in sync
#   0, no overlay -> restored from p5     9 no overlay -> generated, legacy     9 + overlay -> re-persisted, no generation
#   10 no overlay -> unknown(prov-corrupt), nothing generated     10 + overlay (p5 gen <= overlay) -> re-persisted
#   13 no overlay -> unknown(identity-lost), nothing generated     3 bypass / 11 no p5 / 12 not ext4 / 14 too new
#   1 mount failed: + overlay -> kept the overlay; no overlay -> unknown(p5-unreadable)
#   identity mismatch (overlay and p5 identities differ) -> unknown(identity-mismatch) before any generation compare
# SBX_MUTANT (dv-sbx builds /sbx/helper-<mutant> from tests/prov-p1/sbx/mutants/helper-<mutant>.sed; each must FAIL):
#   rc9-gen (rc 9 generates even with a complete overlay), rc10-gen (rc 10 generates when the overlay is missing),
#   gen-first (the identity-mismatch check is skipped: generations compared first)
DEV=/dev/mmcblk0p5; H=/usr/bin/batman-provhelper; n=0; f=0; M=${SBX_MUTANT:--}; MP=/sbx/run/m; S=/sbx/run/save
ok(){ n=$((n + 1)); }; no(){ n=$((n + 1)); f=$((f + 1)); echo "FAIL $*"; }
if [ "$M" != - ]; then
	[ -x "/sbx/helper-$M" ] || { echo "FAIL no mutant helper /sbx/helper-$M"; echo "CASE helper cases=0 fails=1"; exit 1; }
	mount --bind "/sbx/helper-$M" $H || { echo "FAIL bind mutant helper"; echo "CASE helper cases=0 fails=1"; exit 1; }
fi
mkdir -p $S $MP
reset(){	# <overlay: none|<saved name>>
	grep -q ' /etc overlay ' /proc/mounts && umount /etc
	rm -rf /sbx/run/o; mkdir -p /sbx/run/o/u /sbx/run/o/w
	mount -t overlay overlay -o lowerdir=/sbx/etc.lower,upperdir=/sbx/run/o/u,workdir=/sbx/run/o/w /etc || { echo "FAIL overlay /etc"; exit 1; }
	rm -rf /opt/batdata/* /tmp/run/batman /tmp/run/batman-* 2>/dev/null; mkdir -p /opt/batdata/state /opt/batdata/log
	. /usr/lib/batman/rundir.sh && batman_rundir   # the run dir an early init makes on a node (helper: no run dir -> unknown(no-rundir))
	[ -b $DEV ] || mv /dev/.p5 $DEV
	printf 'console=serial0,115200 root=PARTUUID=00000000-0002 rootfstype=squashfs batman_slot=A\n' > /sbx/run/cmdline
	[ "$1" != none ] && cp -a "$S/ovl.$1" /etc/batman-prov
	return 0
}
fresh(){ mkfs.ext4 -q -F -L batconfig $DEV >/dev/null 2>&1; }
seeded(){ fresh; mount -t ext4 $DEV $MP && { echo 1 > $MP/schema_version; : > $MP/.seeded; sync; umount $MP; }; }
img(){ dd if="$S/p5.$1" of=$DEV bs=1M 2>/dev/null; }             # restore a saved p5 image
saveimg(){ dd if=$DEV of="$S/p5.$1" bs=1M 2>/dev/null; }
onp5(){ mount -t ext4 $DEV $MP && { sh -c "cd $MP && $1"; sync; umount $MP; }; }   # <shell run inside the mounted p5>
boot(){ L=$($H --boot 2>&1 | grep 'boot rc=' | tail -1); L=${L#*boot }; }
key(){ [ -e /etc/batman-prov/identity/node.key ] && echo key || echo nokey; }
want(){	# <label> <ERE the "rc=… verdict=… action=…" line must match> [key|nokey]
	if echo "$L" | grep -qE "$2" && { [ -z "${3:-}" ] || [ "$(key)" = "$3" ]; }; then ok; else no "$1: [$L] key=$(key) want /$2/ ${3:-}"; fi
}
pget(){ rm -rf /sbx/run/g; /usr/bin/batman-config-save --prov-get /sbx/run/g >/dev/null 2>&1; echo $?; }
# --- 7: a fresh card generates; save it (identity A) as the base of the others
reset none; fresh; boot
want "rc 7 fresh card" '^rc=7 verdict=unclaimed action=generated identity, unclaimed, persist rc=0$' key
r=$(pget); [ "$r" = 0 ] && ok || no "after rc 7 the record and identity are on p5 (--prov-get $r)"
saveimg A; cp -a /etc/batman-prov "$S/ovl.A"
# identity B: a second fresh card (for the mismatch scenario)
reset none; fresh; boot; cp -a /etc/batman-prov "$S/ovl.B"
# --- 0
reset A; img A; boot; want "rc 0 + overlay" '^rc=0 verdict=unclaimed action=in sync$' key
reset none; img A; boot; want "rc 0, no overlay" '^rc=0 verdict=unclaimed action=restored identity \+ record from p5$' key
reset B; img A; boot; want "identity mismatch" '^rc=0 verdict=unknown\(identity-mismatch\) ' key
# --- 9
reset none; seeded; boot; want "rc 9, no overlay" '^rc=9 verdict=legacy action=generated identity, legacy, persist rc=0$' key
reset A; seeded; boot; want "rc 9 + overlay: no generation" '^rc=9 verdict=unclaimed action=re-persisted the whole overlay record, rc=0$' key
[ "$(cat /etc/batman-prov/identity/sn 2>/dev/null)" = "$(cat "$S/ovl.A/identity/sn" 2>/dev/null)" ] && ok || no "rc 9 + overlay: the overlay identity was replaced"
# --- 10
reset none; img A; onp5 'head -c 7 /dev/urandom >> prov.cbor'; boot; want "rc 10, no overlay: nothing generated" '^rc=10 verdict=unknown\(prov-corrupt\) ' nokey
reset A; img A; onp5 'head -c 7 /dev/urandom >> prov.cbor'; boot; want "rc 10 + overlay" '^rc=10 verdict=unclaimed action=p5 record corrupt \(p5 gen 1 <= overlay 1\): re-persisted' key
# --- 13
reset none; img A; onp5 'rm -rf identity/prov'; boot; want "rc 13, no overlay: nothing generated" '^rc=13 verdict=unknown\(identity-lost\) ' nokey
# --- 3 / 11 / 12 / 14 / 1
reset none; img A; printf 'console=serial0 batman_slot=A batman_bypass=1\n' > /sbx/run/cmdline; boot; want "bypass" '^rc=3 verdict=unknown\(bypass\) ' nokey
reset none; mv $DEV /dev/.p5; boot; want "no p5" '^rc=11 verdict=unknown\(no-p5\) ' nokey
reset none; dd if=/dev/zero of=$DEV bs=64k count=32 2>/dev/null; boot; want "not ext4" '^rc=12 verdict=unknown\(p5-not-ext4\) ' nokey
reset none; img A; onp5 'sed -i "s/^v=1 /v=2 /" prov.meta'; boot; want "too new" '^rc=14 verdict=unknown\(too-new\) ' nokey
reset A; img A; printf '\377\377\377\377' | dd of=$DEV bs=1 seek=1048 conv=notrunc 2>/dev/null; boot; want "mount failed + overlay" '^rc=1 verdict=unclaimed action=p5 unreadable: kept the overlay' key
reset none; img A; printf '\377\377\377\377' | dd of=$DEV bs=1 seek=1048 conv=notrunc 2>/dev/null; boot; want "mount failed, no overlay" '^rc=1 verdict=unknown\(p5-unreadable\) ' nokey
grep -q ' /etc overlay ' /proc/mounts && umount /etc
echo "CASE helper cases=$n fails=$f"
