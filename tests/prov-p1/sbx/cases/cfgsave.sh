#!/bin/sh
# tests/prov-p1/sbx/cases/cfgsave.sh — prov-unit-cfgsave (254-p1-impl §5.1; 254-stage1-impl §4.2 / §4.3): the real
# /usr/bin/batman-config-save against a real ext4 p5 (the sandbox loop). Cases not already in the loop-device CI tests
# (cfgsave-identity-freeze / -frozen-nomount / -provget-rc10):
#   --prov-get rc table: 11 no p5, 3 bypass, 12 not ext4 (via --prov-get's own probe), 1 mount failed, 7 unseeded no prov,
#     9 seeded no prov, 10 sha mismatch, 10 meta missing (cbor alone), 14 too new, 13 identity incomplete, 0 complete
#     (and what it copies)
#   --prov-only: malformed meta / cbor > 64 KiB / sha mismatch / incomplete identity -> rc 1, p5 untouched; on an unseeded
#     p5 -> rc 0, .seeded still absent, no overrides, identity written; an existing identity is not overwritten; .seeded of a
#     seeded p5 untouched; ENOSPC on the cbor -> rc != 0 and --prov-get still reads the OLD generation
#   --save / --on-join / --seed leave prov.cbor, prov.meta, identity/prov byte-identical
#   --check: overlay prov.meta != p5 -> rc 5 "p5 stale: prov", also on an UNSEEDED p5; identity mismatch -> rc 5
#   final_rc: --on-join with p5 == live and root "!" -> 0 (not 4); root "" -> 4 (control)
#   a live .txn: --on-join rc 1 "transaction in progress"; without it the tick proceeds
# SBX_MUTANT (each must make this case FAIL): meta-first (prov.meta written before prov.cbor), onjoin-prov (--on-join
#   writes the overlay prov.meta to p5), check-late (--check compares prov only after the unseeded exit)
DEV=/dev/mmcblk0p5; CS=/usr/bin/batman-config-save; n=0; f=0; M=${SBX_MUTANT:--}; MNTP=/sbx/run/m; W=/sbx/run/w
ok(){ n=$((n + 1)); }; no(){ n=$((n + 1)); f=$((f + 1)); echo "FAIL $*"; }
chk(){ if eval "$2"; then ok; else no "$1"; fi; }   # <label> <shell test>
IDF="node.key ecdh.key node.cert claim.secret backend sn"
case "$M" in
	meta-first) cp $CS /sbx/run/cs && sed -i 's|^\tcp "\$PF" "\$MNT/prov.cbor.tmp"|\tcp "$PM" "$MNT/prov.meta"; sync; cp "$PF" "$MNT/prov.cbor.tmp"|' /sbx/run/cs ;;
	onjoin-prov) cp $CS /sbx/run/cs && sed -i 's|^mv "\$STAGE/schema_version" "\$MNT/schema_version"$|&\n[ "$mode" = --on-join ] \&\& cp /etc/batman-prov/prov.meta "$MNT/prov.meta" 2>/dev/null|' /sbx/run/cs ;;
	check-late) cp $CS /sbx/run/cs && sed -i 's|^\tprov_compare "\$MNT"$|\t:|; s|^\t\[ -f "\$MNT/.seeded" \] \|\| { say "p5 unseeded"; exit 7; }$|&\n\tprov_compare "$MNT"|' /sbx/run/cs ;;
esac
if [ -f /sbx/run/cs ]; then
	cmp -s /sbx/run/cs $CS && { echo "FAIL mutant $M did not change batman-config-save"; echo "CASE cfgsave cases=0 fails=1"; exit 1; }
	chmod 755 /sbx/run/cs; mount --bind /sbx/run/cs $CS || { echo "FAIL bind mutant"; echo "CASE cfgsave cases=0 fails=1"; exit 1; }
fi
reset(){
	grep -q ' /etc overlay ' /proc/mounts && umount /etc
	rm -rf /sbx/run/o $W; mkdir -p /sbx/run/o/u /sbx/run/o/w $W
	mount -t overlay overlay -o lowerdir=/sbx/etc.lower,upperdir=/sbx/run/o/u,workdir=/sbx/run/o/w /etc || { echo "FAIL overlay /etc"; exit 1; }
	rm -rf /opt/batdata/* /tmp/run/batman /tmp/run/batman-* 2>/dev/null; mkdir -p /opt/batdata/state /opt/batdata/log
	[ -b $DEV ] || mv /dev/.p5 $DEV
	printf 'console=serial0,115200 root=PARTUUID=00000000-0002 rootfstype=squashfs batman_slot=A\n' > /sbx/run/cmdline
	echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDvsbxtestkeyonlyforthesandboxxxxxxxxxxxxxxxx dv-sbx" > /etc/dropbear/authorized_keys
}
mnt(){ mkdir -p $MNTP && mount -t ext4 $DEV $MNTP; }
umnt(){ sync; umount $MNTP; }
fmt(){ mkfs.ext4 -q -F -L batconfig $DEV >/dev/null 2>&1; }
# rec <dir> <state> <gen> [cbor bytes]: a well-formed record (prov.cbor + prov.meta) in <dir>
rec(){ head -c "${4:-300}" /dev/urandom > "$1/prov.cbor"; printf 'v=1 state=%s gen=%s sha=%s\n' "$2" "$3" "$(sha256sum < "$1/prov.cbor" | cut -c1-64)" > "$1/prov.meta"; }
ident(){ mkdir -p "$1"; for x in $IDF; do head -c 64 /dev/urandom > "$1/$x"; done; ( cd "$1" && sha256sum $IDF > sha256 ); }
p5(){	# <seeded 0|1> <prov none|ok|badsha|cborsolo|toonew> <identity 0|1>
	fmt; mnt || { echo "FAIL mount p5"; return 1; }
	[ "$1" = 1 ] && { echo 1 > $MNTP/schema_version; : > $MNTP/.seeded; }
	case "$2" in
		ok) rec $MNTP claimed 3 ;;
		badsha) rec $MNTP claimed 3; head -c 10 /dev/urandom >> $MNTP/prov.cbor ;;
		cborsolo) head -c 300 /dev/urandom > $MNTP/prov.cbor ;;
		toonew) rec $MNTP claimed 3; sed -i 's/^v=1 /v=2 /' $MNTP/prov.meta ;;
	esac
	[ "$3" = 1 ] && ident $MNTP/identity/prov
	umnt
}
pget(){ rm -rf $W/g; $CS --prov-get $W/g >/dev/null 2>&1; echo $?; }
sums(){ mnt && { ( cd $MNTP && sha256sum prov.cbor prov.meta identity/prov/* 2>/dev/null; ls -a | tr '\n' ' ' ); umnt; }; }
# ---------- --prov-get rc table ----------
reset; p5 1 ok 1; mv $DEV /dev/.p5; chk "prov-get no p5 -> 11" '[ "$(pget)" = 11 ]'
reset; p5 1 ok 1; printf 'console=serial0 batman_slot=A batman_bypass=1\n' > /sbx/run/cmdline; r=$(pget); chk "prov-get bypass -> 3 [$r]" '[ "$r" = 3 ]'
reset; dd if=/dev/zero of=$DEV bs=64k count=32 2>/dev/null; r=$(pget); chk "prov-get not ext4 -> 12 [$r]" '[ "$r" = 12 ]'
reset; p5 1 ok 1; printf '\377\377\377\377' | dd of=$DEV bs=1 seek=1048 conv=notrunc 2>/dev/null; r=$(pget); chk "prov-get mount failed -> 1 [$r]" '[ "$r" = 1 ]'
reset; p5 0 none 0; r=$(pget); chk "prov-get unseeded no prov -> 7 [$r]" '[ "$r" = 7 ]'
reset; p5 1 none 0; r=$(pget); chk "prov-get seeded no prov -> 9 [$r]" '[ "$r" = 9 ]'
reset; p5 1 badsha 1; r=$(pget); chk "prov-get sha mismatch -> 10 [$r]" '[ "$r" = 10 ]'
chk "prov-get 10 does not hand over the record" '[ ! -e $W/g/prov.cbor ]'
reset; p5 1 cborsolo 1; r=$(pget); chk "prov-get cbor without meta -> 10 [$r]" '[ "$r" = 10 ]'
reset; p5 1 toonew 1; r=$(pget); chk "prov-get too new -> 14 [$r]" '[ "$r" = 14 ]'
reset; p5 1 ok 0; r=$(pget); chk "prov-get identity missing -> 13 [$r]" '[ "$r" = 13 ]'
reset; p5 1 ok 1; r=$(pget); chk "prov-get complete -> 0 [$r]" '[ "$r" = 0 ]'
chk "prov-get 0 copies cbor, meta and the 7 identity files" '[ -f $W/g/prov.cbor ] && [ -f $W/g/prov.meta ] && [ "$(ls $W/g/identity | wc -l)" = 7 ]'
# ---------- --prov-only ----------
po(){ $CS --prov-only --prov-file "$1" --prov-meta "$2" ${3:+--prov-identity "$3"} > $W/po.out 2>&1; echo $?; }
reset; p5 0 none 0; s0=$(sums); mkdir -p $W/r; rec $W/r claimed 1
printf 'v=1 state=claimed gen=1 sha=XYZ\n' > $W/bad.meta; r=$(po $W/r/prov.cbor $W/bad.meta); chk "prov-only malformed meta -> 1 [$r]" '[ "$r" = 1 ]'
head -c 70000 /dev/urandom > $W/big.cbor; printf 'v=1 state=claimed gen=1 sha=%s\n' "$(sha256sum < $W/big.cbor | cut -c1-64)" > $W/big.meta
r=$(po $W/big.cbor $W/big.meta); chk "prov-only cbor > 64 KiB -> 1 [$r]" '[ "$r" = 1 ]'
head -c 300 /dev/urandom > $W/other.cbor; r=$(po $W/other.cbor $W/r/prov.meta); chk "prov-only sha mismatch -> 1 [$r]" '[ "$r" = 1 ]'
ident $W/id; rm $W/id/backend; r=$(po $W/r/prov.cbor $W/r/prov.meta $W/id); chk "prov-only incomplete identity -> 1 [$r]" '[ "$r" = 1 ]'
chk "refused --prov-only calls left p5 untouched" '[ "$(sums)" = "$s0" ]'
ident $W/id2; r=$(po $W/r/prov.cbor $W/r/prov.meta $W/id2); chk "prov-only on an unseeded p5 -> 0 [$r]" '[ "$r" = 0 ]'
mnt; chk "unseeded p5 stays unseeded, no overrides, identity + record written" '[ ! -e $MNTP/.seeded ] && [ ! -e $MNTP/overrides.uci ] && cmp -s $MNTP/identity/prov/sn $W/id2/sn && cmp -s $MNTP/prov.meta $W/r/prov.meta'; umnt
ident $W/id3; mkdir -p $W/r2; rec $W/r2 member 2
# identities are written once (P-U6): another identity is refused outright, p5 unchanged
r=$(po $W/r2/prov.cbor $W/r2/prov.meta $W/id3); mnt; chk "a different identity is refused, p5 unchanged [$r: $(tail -1 $W/po.out)]" '[ "$r" = 1 ] && cmp -s $MNTP/identity/prov/sn $W/id2/sn && cmp -s $MNTP/prov.meta $W/r/prov.meta'; umnt
# the same identity with a newer record: the record is written, the identity files are not rewritten
mnt; is0=$(cd $MNTP/identity/prov && ls -ln; sha256sum *); umnt
r=$(po $W/r2/prov.cbor $W/r2/prov.meta $W/id2); mnt; chk "same identity + gen 2: record written, identity untouched [$r]" '[ "$r" = 0 ] && cmp -s $MNTP/prov.meta $W/r2/prov.meta && [ "$(cd $MNTP/identity/prov && ls -ln; sha256sum *)" = "$is0" ]'; umnt
reset; p5 1 ok 1; mnt; sd=$(ls -ln $MNTP/.seeded; sha256sum < $MNTP/.seeded); umnt; mkdir -p $W/r; rec $W/r claimed 4
r=$(po $W/r/prov.cbor $W/r/prov.meta); mnt; chk ".seeded of a seeded p5 untouched by --prov-only [$r]" '[ "$r" = 0 ] && [ "$(ls -ln $MNTP/.seeded; sha256sum < $MNTP/.seeded)" = "$sd" ]'; umnt
# ENOSPC on the cbor: fill p5 so a 60 KiB cbor cannot be written but a meta could
# a 16 KiB gap file, then fill in 4 KiB files until ENOSPC (synced each round: delayed allocation on the arm64 runner
# left room after one big dd — CI run 40697592657), then free exactly the gap
reset; p5 1 ok 1; mnt; dd if=/dev/zero of=$MNTP/gap bs=1k count=16 2>/dev/null; sync
i=0; while dd if=/dev/zero of=$MNTP/fill.$i bs=4k count=64 2>/dev/null; do sync; i=$((i + 1)); done; sync
j=0; while dd if=/dev/zero of=$MNTP/top.$j bs=1k count=1 2>/dev/null; do j=$((j + 1)); done; sync; rm -f $MNTP/gap; sync
head -c 40000 /dev/urandom > $MNTP/probe 2>/dev/null && pr=fits || pr=enospc; rm -f $MNTP/probe; umnt
chk "ENOSPC setup: a 40 KB file no longer fits on p5 [$pr]" '[ "$pr" = enospc ]'
mkdir -p $W/r; rec $W/r claimed 9 61440; r=$(po $W/r/prov.cbor $W/r/prov.meta); g=$(pget); m=$(cat $W/g/prov.meta 2>/dev/null)
chk "ENOSPC on the cbor: --prov-only fails [$r], --prov-get still the old generation [$g: $m]" '[ "$r" != 0 ] && [ "$g" = 0 ] && case "$m" in *" gen=3 "*) true ;; *) false ;; esac'
# ---------- --save / --on-join / --seed leave prov alone ----------
reset; p5 1 ok 1; s0=$(sums | head -n 9)
r=$($CS --save >/dev/null 2>&1; echo $?); chk "--save rc 0 and prov.* + identity/prov byte-identical [rc $r]" '[ "$r" = 0 ] && [ "$(sums | head -n 9)" = "$s0" ]'
# a REAL --on-join write (a live value changed) while the overlay holds a different prov.meta: the tick must not carry
# prov to p5 (run 1: with nothing to write it took the "unchanged" exit and the onjoin-prov mutant passed)
mkdir -p /etc/batman-prov; rec /etc/batman-prov claimed 8; uci set system.@system[0].hostname="sbx$(head -c 3 /dev/urandom | od -An -tx1 | tr -d ' \n')"; uci commit system
o=$($CS --on-join 2>&1); r=$?; chk "--on-join really wrote (rc $r: $(echo "$o" | tail -1)) and prov.* + identity/prov byte-identical" 'case "$r" in 0|4) echo "$o" | grep -q "saved (--on-join)" && [ "$(sums | head -n 9)" = "$s0" ] ;; *) false ;; esac'
reset; p5 0 ok 1; s0=$(sums | head -n 9)
$CS --seed >/dev/null 2>&1; r=$?; mnt; sd=$([ -e $MNTP/.seeded ] && echo y); umnt
chk "--seed on an unseeded p5 with a record: seeded, prov untouched [rc $r seeded=$sd]" '[ "$sd" = y ] && [ "$(sums | head -n 9)" = "$s0" ]'
# ---------- --check ----------
ovl(){ mkdir -p /etc/batman-prov; rec /etc/batman-prov "$1" "$2"; }
reset; p5 1 ok 1; $CS --save >/dev/null 2>&1; ovl claimed 7; o=$($CS --check 2>&1); r=$?
chk "--check overlay prov.meta != p5 -> 5 'p5 stale: prov' [rc $r]" '[ "$r" = 5 ] && echo "$o" | grep -q "p5 stale: prov"'
reset; p5 0 ok 1; ovl claimed 7; o=$($CS --check 2>&1); r=$?
chk "--check on an UNSEEDED p5 with stale prov -> 5, not 7 [rc $r]" '[ "$r" = 5 ] && echo "$o" | grep -q "p5 stale: prov"'
reset; p5 1 ok 1; $CS --save >/dev/null 2>&1; mnt; mkdir -p /etc/batman-prov; cp $MNTP/prov.meta $MNTP/prov.cbor /etc/batman-prov/; umnt; ident /etc/batman-prov/identity
o=$($CS --check 2>&1); r=$?; chk "--check identity mismatch -> 5 [rc $r]" '[ "$r" = 5 ] && echo "$o" | grep -q "prov-identity"'
reset; p5 1 ok 1; $CS --save >/dev/null 2>&1; mnt; mkdir -p /etc/batman-prov; cp $MNTP/prov.meta $MNTP/prov.cbor /etc/batman-prov/; cp -a $MNTP/identity/prov /etc/batman-prov/identity; umnt
r=$($CS --check >/dev/null 2>&1; echo $?); chk "--check in sync -> 0 [rc $r]" '[ "$r" = 0 ]'
# ---------- final_rc ----------
setroot(){ awk -v p="$1" 'BEGIN{FS=OFS=":"} /^root:/ {$2=p} {print}' /etc/shadow > /sbx/run/sh && cat /sbx/run/sh > /etc/shadow; }
reset; p5 1 none 0; setroot '!'; $CS --save >/dev/null 2>&1; r=$($CS --on-join >/dev/null 2>&1; echo $?); chk "--on-join, p5 == live, root ! -> 0 [rc $r]" '[ "$r" = 0 ]'
reset; p5 1 none 0; setroot ''; $CS --save >/dev/null 2>&1; r=$($CS --on-join >/dev/null 2>&1; echo $?); chk "control: --on-join, p5 == live, root empty -> 4 [rc $r]" '[ "$r" = 4 ]'
# ---------- .txn yield ----------
reset; p5 1 none 0; mkdir -p /etc/batman-prov; : > /etc/batman-prov/.txn; o=$($CS --on-join 2>&1); r=$?
chk "--on-join with a live .txn -> 1 'transaction in progress' [rc $r]" '[ "$r" = 1 ] && echo "$o" | grep -q "transaction in progress"'
rm -f /etc/batman-prov/.txn; o=$($CS --on-join 2>&1); r=$?; chk "control: without the .txn the tick proceeds [rc $r]" '! echo "$o" | grep -q "transaction in progress"'
grep -q ' /etc overlay ' /proc/mounts && umount /etc
echo "CASE cfgsave cases=$n fails=$f"
