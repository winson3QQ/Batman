#!/bin/bash
# tests/prov-p1/cfgsave-provget-rc10.sh <batman-config-save> — WSL/CI root. #254 round-8 A-m10/B-m1: --prov-get on a
# corrupt record (rc 10) hands over the raw meta + identity, never the cbor. PROV_SRC = product files/ dir.
set -u
CS=$1; W=$(mktemp -d); trap 'umount $W/m 2>/dev/null; losetup -d $LOOP 2>/dev/null; rm -rf $W' EXIT
SRC=${PROV_SRC:-$(cd "$(dirname "$1")/../.." && pwd)}   # files/ of the product tree (override for a copied file)
truncate -s 64M $W/p5.img; LOOP=$(losetup -f --show $W/p5.img); mkfs.ext4 -q -F $W/p5.img
mkdir -p $W/prov $W/m $W/run; chmod 700 $W/run
printf 'batman_rundir(){ return 0; }\nRUNDIR=%s/run\n' "$W" > $W/rundir.sh
sed -e "s#^DEV=/dev/mmcblk0p5#DEV=$LOOP#" -e "s#^PROVD=/etc/batman-prov#PROVD=$W/prov#" -e "s#/usr/lib/batman/prov-lock.sh#$SRC/usr/lib/batman/prov-lock.sh#g" -e "s#/usr/lib/batman/rundir.sh#$W/rundir.sh#g" "$CS" > $W/cs; chmod +x $W/cs
mk_ident(){ d=$1; mkdir -p $d; for f in node.key ecdh.key node.cert claim.secret backend sn; do head -c 40 /dev/urandom > $d/$f; done; (cd $d && sha256sum node.key ecdh.key node.cert claim.secret backend sn > sha256); }
printf '\xa1\x01\x01y' > $W/prov.cbor; sha=$(sha256sum < $W/prov.cbor | cut -c1-64); echo "v=1 state=claimed gen=5 sha=$sha" > $W/prov.meta
mk_ident $W/idY
"$W/cs" --prov-only --prov-file $W/prov.cbor --prov-meta $W/prov.meta --prov-identity $W/idY >/dev/null 2>&1 || { echo "FAIL setup --prov-only"; exit 1; }
mount $LOOP $W/m; printf 'X' >> $W/m/prov.cbor; umount $W/m     # cbor no longer matches its sha
"$W/cs" --prov-get $W/out > $W/o 2>&1; rc=$?
fails=0
[ "$rc" = 10 ] && echo "ok   rc 10 ($(tail -1 $W/o))" || { echo "FAIL rc=$rc want 10"; fails=1; }
[ -f $W/out/prov.meta ] && grep -q "gen=5" $W/out/prov.meta && echo "ok   raw meta handed over (gen readable)" || { echo "FAIL no meta in the --prov-get dir"; fails=1; }
[ -f $W/out/identity/sha256 ] && cmp -s $W/out/identity/sha256 $W/idY/sha256 && echo "ok   identity handed over" || { echo "FAIL no identity in the --prov-get dir"; fails=1; }
[ ! -e $W/out/prov.cbor ] && echo "ok   corrupt cbor NOT copied" || { echo "FAIL corrupt cbor copied"; fails=1; }
[ $fails = 0 ] && echo "RC10 RESULT: PASS" || echo "RC10 RESULT: FAIL"
