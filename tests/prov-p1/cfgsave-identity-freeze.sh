#!/bin/bash
# tests/prov-p1/cfgsave-identity-freeze.sh <batman-config-save> — WSL/CI root (loop device). #254 P-U6: an identity
# mismatch freezes every write mode; --check reports it (round-6 A-M2/B-M2/B-m3). PROV_SRC = product files/ dir.
set -u
W=$(mktemp -d); trap 'umount $W/m 2>/dev/null; losetup -d $LOOP 2>/dev/null; rm -rf $W' EXIT
SRC=${PROV_SRC:-$(cd "$(dirname "$1")/../.." && pwd)}   # files/ of the product tree (override for a copied file)
truncate -s 64M $W/p5.img; LOOP=$(losetup -f --show $W/p5.img); mkfs.ext4 -q -F $W/p5.img
mkdir -p $W/lib $W/prov $W/m
sed -e "s#^DEV=/dev/mmcblk0p5#DEV=$LOOP#" -e "s#^PROVD=/etc/batman-prov#PROVD=$W/prov#" -e "s#/usr/lib/batman/prov-lock.sh#$SRC/usr/lib/batman/prov-lock.sh#g" "$1" > $W/cs; chmod +x $W/cs
pass=0; fail=0
t(){ local want=$1; shift; out=$("$W/cs" "$@" 2>&1); rc=$?; if [ "$rc" = "$want" ]; then pass=$((pass+1)); echo "ok   rc=$rc  $*"; else fail=$((fail+1)); echo "FAIL rc=$rc want=$want  $* :: $(echo "$out" | tail -2)"; fi; }
mk_ident(){ d=$1; mkdir -p $d; for f in node.key ecdh.key node.cert claim.secret backend sn; do head -c 40 /dev/urandom > $d/$f; done; (cd $d && sha256sum node.key ecdh.key node.cert claim.secret backend sn > sha256); }
mk_rec(){ printf '\xa1\x01\x01%s' "$1" > $W/prov.cbor; sha=$(sha256sum < $W/prov.cbor | cut -c1-64); echo "v=1 state=$2 gen=$3 sha=$sha" > $W/prov.meta; }
# p5 holds identity Y + a seeded config; the overlay holds identity X
mk_ident $W/idY; mk_rec y claimed 2
t 0 --prov-only --prov-file $W/prov.cbor --prov-meta $W/prov.meta --prov-identity $W/idY
mount $LOOP $W/m; : > $W/m/.seeded; echo 1 > $W/m/schema_version; : > $W/m/overrides.uci; umount $W/m
mk_ident $W/prov/identity; cp $W/prov.meta $W/prov/prov.meta; cp $W/prov.cbor $W/prov/prov.cbor
t 1 --on-join
t 1 --save
t 5 --check
out=$("$W/cs" --check 2>&1); echo "$out" | grep -q "prov-identity (" && { pass=$((pass+1)); echo "ok   --check says prov-identity"; } || { fail=$((fail+1)); echo "FAIL --check text: $out"; }
# a different identity offered to --prov-only is refused (identities are written once)
mk_ident $W/idZ; t 1 --prov-only --prov-file $W/prov.cbor --prov-meta $W/prov.meta --prov-identity $W/idZ
# negative control: the SAME identity on both sides -> writes go through again
rm -rf $W/prov/identity; cp -a $W/idY $W/prov/identity
t 0 --save
# p5 without identity while the overlay has one -> --check stale (missing)
mount $LOOP $W/m; rm -rf $W/m/identity/prov; umount $W/m
out=$("$W/cs" --check 2>&1); rc=$?; [ $rc = 5 ] && echo "$out" | grep -q "prov-identity-missing" && { pass=$((pass+1)); echo "ok   --check rc=5 prov-identity-missing"; } || { fail=$((fail+1)); echo "FAIL missing: rc=$rc $out"; }
echo "PASS=$pass FAIL=$fail"; [ $fail = 0 ]
