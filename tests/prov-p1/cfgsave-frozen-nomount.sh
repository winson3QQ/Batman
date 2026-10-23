#!/bin/bash
# tests/prov-p1/cfgsave-frozen-nomount.sh <batman-config-save> — WSL/CI root. #254 round-7 A-M6: a frozen node's
# --on-join does not rw-mount p5 on every tick (#263 M0). PROV_SRC = product files/ dir.
set -u
CS=$1; W=$(mktemp -d); trap 'umount $W/m 2>/dev/null; losetup -d $LOOP 2>/dev/null; rm -rf $W' EXIT
SRC=${PROV_SRC:-$(cd "$(dirname "$1")/../.." && pwd)}   # files/ of the product tree (override for a copied file)
truncate -s 64M $W/p5.img; LOOP=$(losetup -f --show $W/p5.img); mkfs.ext4 -q -F $W/p5.img
mkdir -p $W/prov $W/m $W/bin $W/run; chmod 700 $W/run
cat > $W/rundir.sh <<X
batman_rundir(){ return 0; }
RUNDIR=$W/run
X
cat > $W/bin/mount <<X
#!/bin/sh
echo "\$*" >> $W/mounts.log; exec /usr/bin/mount "\$@"
X
chmod +x $W/bin/mount
sed -e "s#^DEV=/dev/mmcblk0p5#DEV=$LOOP#" -e "s#^PROVD=/etc/batman-prov#PROVD=$W/prov#" -e "s#/usr/lib/batman/prov-lock.sh#$SRC/usr/lib/batman/prov-lock.sh#g" -e "s#/usr/lib/batman/rundir.sh#$W/rundir.sh#g" "$CS" > $W/cs; chmod +x $W/cs
mk_ident(){ d=$1; mkdir -p $d; for f in node.key ecdh.key node.cert claim.secret backend sn; do head -c 40 /dev/urandom > $d/$f; done; (cd $d && sha256sum node.key ecdh.key node.cert claim.secret backend sn > sha256); }
mk_rec(){ printf '\xa1\x01\x01%s' "$1" > $W/prov.cbor; sha=$(sha256sum < $W/prov.cbor | cut -c1-64); echo "v=1 state=$2 gen=$3 sha=$sha" > $W/prov.meta; }
mk_ident $W/idY; mk_rec y claimed 2
"$W/cs" --prov-only --prov-file $W/prov.cbor --prov-meta $W/prov.meta --prov-identity $W/idY >/dev/null 2>&1
mount $LOOP $W/m; : > $W/m/.seeded; echo 1 > $W/m/schema_version; : > $W/m/overrides.uci; umount $W/m
mk_ident $W/prov/identity; cp $W/prov.meta $W/prov.cbor $W/prov/
fails=0
PATH=$W/bin:$PATH "$W/cs" --on-join >/dev/null 2>&1; r1=$?; n1=$(grep -vc ro $W/mounts.log 2>/dev/null)
PATH=$W/bin:$PATH "$W/cs" --on-join > $W/o2 2>&1; r2=$?; n2=$(grep -vc ro $W/mounts.log 2>/dev/null)
PATH=$W/bin:$PATH "$W/cs" --on-join >/dev/null 2>&1; n3=$(grep -vc ro $W/mounts.log 2>/dev/null)
echo "tick1 rc=$r1 rw-mounts=$n1; tick2 rc=$r2 rw-mounts=$n2; tick3 rw-mounts=$n3; tick2 says: $(tail -1 $W/o2)"
[ "$r1" = 1 ] && [ "$r2" = 1 ] || { echo "FAIL on-join must refuse (rc 1) while frozen"; fails=1; }
[ "$n1" -ge 1 ] && [ "$n3" = "$n1" ] && echo "ok   frozen: only the first tick rw-mounted p5" || { echo "FAIL frozen node rw-mounts p5 on later ticks ($n1 -> $n3)"; fails=1; }
# another write mode (still mismatched) clears the marker -> the next on-join looks again (and re-freezes)
"$W/cs" --save >/dev/null 2>&1; [ -e $W/run/cfgsave-frozen ] && { echo "FAIL --save left the frozen marker"; fails=1; } || echo "ok   --save drops the frozen marker"
[ $fails = 0 ] && echo "M6 RESULT: PASS" || echo "M6 RESULT: FAIL"
