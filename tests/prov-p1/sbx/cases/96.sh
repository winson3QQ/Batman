#!/bin/sh
# tests/prov-p1/sbx/cases/96.sh — prov-unit-96 (254-p1-impl §5.1; 254-stage1-impl §4.3): the real
# /etc/uci-defaults/96-batman-config-migrate run against a real ext4 p5 (the sandbox loop) for every exit × p5 provisioning
# record × p6 last_known_state × dev-open. Expected values come from the design, not from the product's functions:
#   p5 readable (exits unseeded / restored): LOCK when prov.meta is well-formed with state claimed|member, or present but
#     malformed / sha mismatch / too new; otherwise today's 4b
#   p5 unreadable (exits bypass / no-p5 / not-ext4 / mount-failed): LOCK when p6 last_known_state is claimed|member
#   LOCK = lock-status LOCKED, dropbear PasswordAuth=off + RootPasswordAuth=off, ttylogin=1, an empty root password -> "!";
#   dev-open does NOT exempt it. today's 4b on this base (no key, no root password) = UNPROVISIONED, or DEV-OPEN.
#   every exit writes /etc/.batman-prov-restore "<boot_id> <exit> prov=<copy> state=<s> lock=<word>"; bypass exits 1.
# SBX_MUTANT (each must make this case FAIL, §5.1's negative controls):
#   meta-bad-unlock   prov_lock_decision: a malformed meta no longer locks
#   p6-unlock         prov_lock_decision: an unreadable p5 never locks on p6's last_known_state
#   devopen-exempt    96: dev-open skips the provisioning lock
#   skip-decision     96: the bypass exit leaves without finish96 (no decision, no record)
DEV=/dev/mmcblk0p5; n=0; f=0; M=${SBX_MUTANT:--}
ok(){ n=$((n + 1)); }; no(){ n=$((n + 1)); f=$((f + 1)); echo "FAIL $*"; }
[ -b $DEV ] || { echo "FAIL no p5"; echo "CASE 96 cases=0 fails=1"; exit 1; }
BOOT=$(cat /proc/sys/kernel/random/boot_id)
# a mutated prov-lock.sh is bound over the product's for the whole case
case "$M" in
	meta-bad-unlock) cp /usr/lib/batman/prov-lock.sh /sbx/run/pl.sh && sed -i 's/bad:\*) echo LOCK; return ;;//' /sbx/run/pl.sh ;;
	p6-unlock) cp /usr/lib/batman/prov-lock.sh /sbx/run/pl.sh && sed -i '/^\telse$/{n;s/case "\$4" in claimed|member) echo LOCK; return ;; esac/:/}' /sbx/run/pl.sh ;;
esac
if [ -f /sbx/run/pl.sh ]; then
	cmp -s /sbx/run/pl.sh /usr/lib/batman/prov-lock.sh && { echo "FAIL mutant $M did not change prov-lock.sh"; echo "CASE 96 cases=0 fails=1"; exit 1; }
	mount --bind /sbx/run/pl.sh /usr/lib/batman/prov-lock.sh || { echo "FAIL bind mutant"; echo "CASE 96 cases=0 fails=1"; exit 1; }
fi
reset(){
	grep -q ' /etc overlay ' /proc/mounts && umount /etc
	rm -rf /sbx/run/o; mkdir -p /sbx/run/o/u /sbx/run/o/w
	mount -t overlay overlay -o lowerdir=/sbx/etc.lower,upperdir=/sbx/run/o/u,workdir=/sbx/run/o/w /etc || { echo "FAIL overlay /etc"; exit 1; }
	rm -rf /opt/batdata/* /tmp/run/batman /tmp/96* 2>/dev/null; mkdir -p /opt/batdata/state /opt/batdata/log
	[ -b $DEV ] || mv /dev/.p5 $DEV
	printf 'console=serial0,115200 root=PARTUUID=00000000-0002 rootfstype=squashfs batman_slot=A\n' > /sbx/run/cmdline
	case "$M" in
		devopen-exempt) sed -i 's/^\tif \[ "\$(prov_lock_decision /\tif [ ! -f \/etc\/batman-dev-open ] \&\& [ "$(prov_lock_decision /' /etc/uci-defaults/96-batman-config-migrate ;;
		skip-decision) sed -i 's/finish96 bypass 1/exit 1/' /etc/uci-defaults/96-batman-config-migrate ;;
	esac
	case "$M" in devopen-exempt|skip-decision)
		cmp -s /etc/uci-defaults/96-batman-config-migrate /sbx/etc.lower/uci-defaults/96-batman-config-migrate \
			&& { echo "FAIL mutant $M did not change 96"; echo "CASE 96 cases=0 fails=1"; exit 1; } ;;
	esac
}
# p5 <how> <prov>: how = ext4 (seeded) | ext4u (unseeded) ; prov = absent|legacy|unclaimed|claimed|member|badfmt|badsha|toonew
p5(){
	mkfs.ext4 -q -F -L batconfig $DEV >/dev/null 2>&1 || { echo "FAIL mkfs"; return 1; }
	mkdir -p /sbx/run/m && mount -t ext4 $DEV /sbx/run/m || { echo "FAIL mount p5 rw"; return 1; }
	[ "$1" = ext4 ] && { echo 1 > /sbx/run/m/schema_version; : > /sbx/run/m/.seeded; }
	if [ "$2" != absent ]; then
		head -c 200 /dev/urandom > /sbx/run/m/prov.cbor; h=$(sha256sum < /sbx/run/m/prov.cbor | cut -c1-64); s=$2
		case "$2" in
			badfmt) printf 'v=1 state=CLAIMED! gen=1 sha=%s\n' "$h" > /sbx/run/m/prov.meta ;;
			badsha) printf 'v=1 state=claimed gen=1 sha=%064d\n' 0 > /sbx/run/m/prov.meta ;;
			toonew) printf 'v=2 state=claimed gen=1 sha=%s\n' "$h" > /sbx/run/m/prov.meta ;;
			*) printf 'v=1 state=%s gen=1 sha=%s\n' "$s" "$h" > /sbx/run/m/prov.meta ;;
		esac
	fi
	sync; umount /sbx/run/m
}
expect(){	# <exit> <prov> <lks> <devopen> -> E_LOCK (1|0) E_WORD E_PROV E_RC
	case "$1" in unseeded|restored) rd=1 ;; *) rd=0 ;; esac
	E_LOCK=0
	if [ $rd = 1 ]; then case "$2" in claimed|member|badfmt|badsha|toonew) E_LOCK=1 ;; esac
	else case "$3" in claimed|member) E_LOCK=1 ;; esac; fi
	if [ $E_LOCK = 1 ]; then E_WORD=LOCKED; elif [ "$4" = 1 ]; then E_WORD=DEV-OPEN; else E_WORD=UNPROVISIONED; fi
	E_PROV=none
	[ $rd = 1 ] && case "$2" in legacy|unclaimed|claimed|member) E_PROV=record ;; badfmt|badsha|toonew) E_PROV=bad ;; esac
	E_RC=0; [ "$1" = bypass ] && E_RC=1
}
one(){	# <exit> <prov> <lks> <devopen>
	ex=$1; pv=$2; lk=$3; dv=$4; tag="exit=$ex prov=$pv lks=$lk devopen=$dv"
	reset
	case "$ex" in
		restored) p5 ext4 "$pv" ;;
		unseeded) p5 ext4u "$pv" ;;
		# overwrite in place: /proc/cmdline is a bind of this inode (sed -i would make a new file the bind never sees)
		bypass) p5 ext4 "$pv"; printf 'console=serial0,115200 root=PARTUUID=00000000-0002 rootfstype=squashfs batman_slot=A batman_bypass=1\n' > /sbx/run/cmdline ;;
		no-p5) mv $DEV /dev/.p5 ;;
		not-ext4) dd if=/dev/zero of=$DEV bs=64k count=32 2>/dev/null ;;
		mount-failed) p5 ext4 "$pv"; printf '\377\377\377\377' | dd of=$DEV bs=1 seek=1048 conv=notrunc 2>/dev/null ;;   # s_log_block_size = garbage, magic kept
	esac
	[ "$lk" != - ] && echo "$BOOT helper $lk $lk - -" > /opt/batdata/state/prov-state
	[ "$dv" = 1 ] && : > /etc/batman-dev-open
	[ "$ex" != bypass ] || grep -q batman_bypass=1 /proc/cmdline || { no "$tag: the fake /proc/cmdline does not carry batman_bypass=1"; return; }
	sh /etc/uci-defaults/96-batman-config-migrate >/dev/null 2>&1; rc=$?
	expect "$ex" "$pv" "$lk" "$dv"
	r=$(cat /etc/.batman-prov-restore 2>/dev/null); set -- $r
	got_ex=${2:-}; got_prov=${3#prov=}; got_lock=${5#lock=}
	ls=$(cat /opt/batdata/state/lock-status 2>/dev/null)
	pa=$(uci -q get dropbear.@dropbear[0].PasswordAuth); ra=$(uci -q get dropbear.@dropbear[0].RootPasswordAuth); tl=$(uci -q get system.@system[0].ttylogin)
	rp=$(grep '^root:' /etc/shadow | cut -d: -f2)
	bad=""
	[ "${1:-}" = "$BOOT" ] || bad="$bad record-boot_id[$1]"
	[ "$got_ex" = "$ex" ] || bad="$bad exit[$got_ex]"
	[ "$rc" = "$E_RC" ] || bad="$bad rc[$rc]"
	[ "$got_lock" = "$E_WORD" ] || bad="$bad record-lock[$got_lock]"
	[ "$ls" = "$E_WORD" ] || bad="$bad lock-status[$ls]"
	[ "$got_prov" = "$E_PROV" ] || bad="$bad prov[$got_prov]"
	if [ $E_LOCK = 1 ]; then
		[ "$pa:$ra:$tl" = "off:off:1" ] || bad="$bad dropbear/tty[$pa:$ra:$tl]"
		[ "$rp" = "!" ] || bad="$bad root[$rp]"
	else
		[ "$pa" != off ] || bad="$bad PasswordAuth-off-without-lock"
	fi
	if [ -z "$bad" ]; then ok; else no "$tag: want lock=$E_WORD prov=$E_PROV rc=$E_RC; got$bad"; fi
}
for dv in 0 1; do
	for ex in restored unseeded; do for pv in absent legacy unclaimed claimed member badfmt badsha toonew; do for lk in - claimed; do one $ex $pv $lk $dv; done; done; done
	for ex in bypass no-p5 not-ext4 mount-failed; do for lk in - legacy unclaimed claimed member; do one $ex claimed $lk $dv; done; done
done
grep -q ' /etc overlay ' /proc/mounts && umount /etc
echo "CASE 96 cases=$n fails=$f"
