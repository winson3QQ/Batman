#!/bin/bash
# tests/prov-p3/cfgsave-ssid.sh <batman-config-save> — WSL/CI root (loop device). #254 P3 (254-p3-impl §3.3, B5-m5):
#   the phone AP's ssid (wireless.default_radio0.ssid) is persisted to p5 with the other PRESERVE keys;
#   an ssid with an UNSAFE character is NOT persisted and NOT stale (--check fresh, like an empty value);
#   control: an UNSAFE character in a key that is not exempt (the mesh key) still makes --check stale (rc 5).
# PROV_SRC = product files/ dir. uci is a stub reading $W/uci.vals. Zero cases = FAIL.
# Negative control: main's batman-config-save does not persist the ssid (case 1 FAILs).
set -u
[ "$(id -u)" = 0 ] || { echo "FAIL needs root (loop device)"; echo "PASS=0 FAIL=1"; exit 1; }
W=$(mktemp -d)
trap 'umount $W/m 2>/dev/null; losetup -d $LOOP 2>/dev/null; rm -rf $W' EXIT
SRC=${PROV_SRC:-$(cd "$(dirname "$1")/../.." && pwd)}
truncate -s 64M $W/p5.img; LOOP=$(losetup -f --show $W/p5.img); mkfs.ext4 -q -F $W/p5.img
mkdir -p $W/prov $W/m $W/bin $W/run; chmod 755 $W/run; chmod 700 $W/prov
sed "s#^RUNDIR=/tmp/run/batman#RUNDIR=$W/run/batman#" "$SRC/usr/lib/batman/rundir.sh" > $W/rundir.sh
sed -e "s#^DEV=/dev/mmcblk0p5#DEV=$LOOP#" -e "s#^PROVD=/etc/batman-prov#PROVD=$W/prov#" \
	-e "s#/usr/lib/batman/prov-lock.sh#$SRC/usr/lib/batman/prov-lock.sh#g" -e "s#/usr/lib/batman/rundir.sh#$W/rundir.sh#g" "$1" > $W/cs
chmod +x $W/cs
printf '#!/bin/sh\necho "HEALTH    [OK] OK — joined"\n' > $W/bin/halow-status
cat > $W/bin/uci <<EOF
#!/bin/sh
echo "uci \$*" >> $W/uci.log
while :; do case "\$1" in -q) shift ;; -P) shift 2 ;; *) break ;; esac; done
[ "\$1" = get ] || exit 1
awk -v k="\$2" 'index(\$0, k "=") == 1 { print substr(\$0, length(k) + 2); f = 1; exit } END { exit !f }' $W/uci.vals
EOF
chmod +x $W/bin/halow-status $W/bin/uci
export PATH=$W/bin:$PATH
pass=0; fail=0
okk(){ pass=$((pass+1)); echo "ok   $*"; }; bad(){ fail=$((fail+1)); echo "FAIL $*"; }
vals(){   # $1 = ssid, $2 = mesh key
	cat > $W/uci.vals <<EOF
system.@system[0].hostname=BCM2711-6c89
wireless.default_radio1.mesh_id=bench-n0
wireless.default_radio1.key=$2
wireless.default_radio0.key=Abcdefgh1234
wireless.default_radio0.ssid=$1
wireless.radio1.channel=40
wireless.radio1.country=US
EOF
}
p5(){ mount -o ro $LOOP $W/m; cat $W/m/overrides.uci; umount $W/m; }
mount $LOOP $W/m; : > $W/m/.seeded; echo 1 > $W/m/schema_version; : > $W/m/overrides.uci; umount $W/m
# 1. the ssid is persisted
vals "Team 1" meshkey12345; $W/cs --save >/dev/null 2>&1
p5 | grep -qx "set wireless.default_radio0.ssid='Team 1'" && okk "ssid persisted to p5" || bad "ssid not in p5: $(p5 | tr '\n' ' ')"
$W/cs --check >/dev/null 2>&1; [ $? = 0 ] && okk "--check fresh after the save" || bad "--check not fresh after the save"
# 2. a changed ssid -> stale, named by key
vals "Team 2" meshkey12345; o=$($W/cs --check 2>&1); rc=$?
[ "$rc" = 5 ] && grep -q "wireless.default_radio0.ssid" <<< "$o" && okk "changed ssid -> stale, key named" || bad "changed ssid: rc $rc $o"
# 3. an UNSAFE ssid: not persisted, not stale
vals "Tom's AP" meshkey12345; $W/cs --save >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && okk "--save with an UNSAFE ssid rc 0" || bad "--save with an UNSAFE ssid rc $rc"
p5 | grep -q "default_radio0.ssid" && bad "an UNSAFE ssid was written to p5" || okk "an UNSAFE ssid is not in p5"
o=$($W/cs --check 2>&1); rc=$?
[ "$rc" = 0 ] && okk "--check fresh with an UNSAFE ssid (not stale forever)" || bad "UNSAFE ssid -> --check rc $rc: $o"
# 4. control: an UNSAFE character in the mesh key is still stale (the exemption is the ssid only)
vals "Team 1" "mesh'key12345"; o=$($W/cs --check 2>&1); rc=$?
[ "$rc" = 5 ] && grep -q "unpersistable" <<< "$o" && okk "control: UNSAFE mesh key -> stale (unpersistable)" || bad "control mesh key: rc $rc $o"
echo "PASS=$pass FAIL=$fail"
[ "$pass" -gt 0 ] && [ "$fail" = 0 ]
