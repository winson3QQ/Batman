#!/bin/bash
# tests/prov-p1/cfgsave-txn-save.sh <batman-config-save> — WSL/CI root (loop device). #254 wireless-txn §7 / §11:
#   --save --txn TOK is accepted only while the run-dir marker AND /etc/batman-prov/.txn both carry TOK
#   (the helper's Finish persists before it removes .txn); without --txn a live transaction still blocks --save;
#   --save / --if-healthy / --on-join re-read the txn sequence right before the p5 write and abort when a transaction
#   started meanwhile (white-box: a test-only hook line is sed-inserted into the COPY just before the re-check).
# PROV_SRC = product files/ dir. Test-only edits of the copy: p5 = a loop device, PROVD / rundir.sh in the test dir.
# Negative control: the shipped batman-config-save FAILs the --txn and the re-check cases. Zero cases run = FAIL.
set -u
[ "$(id -u)" = 0 ] || { echo "FAIL needs root (loop device)"; echo "PASS=0 FAIL=1"; exit 1; }
W=$(mktemp -d); trap 'umount $W/m 2>/dev/null; losetup -d $LOOP 2>/dev/null; rm -rf $W' EXIT
SRC=${PROV_SRC:-$(cd "$(dirname "$1")/../.." && pwd)}   # files/ of the product tree (override for a copied file)
truncate -s 64M $W/p5.img; LOOP=$(losetup -f --show $W/p5.img); mkfs.ext4 -q -F $W/p5.img
mkdir -p $W/prov $W/m $W/bin $W/run; chmod 755 $W/run; chmod 700 $W/prov
sed "s#^RUNDIR=/tmp/run/batman#RUNDIR=$W/run/batman#" "$SRC/usr/lib/batman/rundir.sh" > $W/rundir.sh
sed -e "s#^DEV=/dev/mmcblk0p5#DEV=$LOOP#" -e "s#^PROVD=/etc/batman-prov#PROVD=$W/prov#" \
	-e "s#/usr/lib/batman/prov-lock.sh#$SRC/usr/lib/batman/prov-lock.sh#g" -e "s#/usr/lib/batman/rundir.sh#$W/rundir.sh#g" \
	-e '/^# txn sequence re-check, right before the p5 write/i [ -n "${CS_TEST_HOOK:-}" ] \&\& eval "$CS_TEST_HOOK"' "$1" > $W/cs; chmod +x $W/cs
printf '#!/bin/sh\necho "HEALTH    [OK] OK — joined"\n' > $W/bin/halow-status; chmod +x $W/bin/halow-status
export PATH=$W/bin:$PATH
pass=0; fail=0
okk(){ pass=$((pass+1)); echo "ok   $*"; }; bad(){ fail=$((fail+1)); echo "FAIL $*"; }
t(){ local want=$1; shift; out=$("$W/cs" "$@" 2>&1); rc=$?; if [ "$rc" = "$want" ]; then okk "rc=$rc  $*"; else bad "rc=$rc want=$want  $* :: $(echo "$out" | tail -2 | tr '\n' ' ')"; fi; }
MK=$W/run/batman/prov-txn; TX=$W/prov/.txn
TOK=0123456789abcdef0123456789abcdef; OTHER=fedcba9876543210fedcba9876543210
marker(){ mkdir -p $W/run/batman; chmod 700 $W/run/batman; printf '%s' "$1" > $MK; chmod 600 $MK; }
txnf(){ printf '%s 3 4 network/join\nprev - - -\nradio disabled=0\n' "$1" > $TX; chmod 600 $TX; }
clean(){ rm -f $MK $TX; }
sentinel(){ mount $LOOP $W/m; echo "set sentinel='x'" > $W/m/overrides.uci; umount $W/m; }
has_sentinel(){ mount -o ro $LOOP $W/m; grep -q sentinel $W/m/overrides.uci; r=$?; umount $W/m; return $r; }
# seeded p5
mount $LOOP $W/m; : > $W/m/.seeded; echo 1 > $W/m/schema_version; : > $W/m/overrides.uci; umount $W/m

# ---- --save --txn ---------------------------------------------------------------------------------------------------
clean; t 0 --save                                                      # control: no transaction
marker $TOK; txnf $TOK; sentinel
t 0 --save --txn $TOK                                                  # Finish's save: marker + .txn carry the token
has_sentinel && bad "--save --txn TOK did not write p5" || okk "--save --txn TOK wrote p5"
t 0 --save --promote-lkg --txn $TOK                                    # options in any order
t 1 --save --txn $OTHER                                                # another token
txnf $OTHER; t 1 --save --txn $TOK                                     # marker TOK, .txn OTHER
txnf $TOK; rm -f $MK; t 1 --save --txn $TOK                            # .txn only (no marker: not this helper's live txn)
marker $TOK; rm -f $TX; t 1 --save --txn $TOK                          # marker only
txnf $TOK; t 1 --save --txn                                            # missing token
t 1 --save --txn none                                                  # "none" can never be a live token
t 1 --save --txn "$TOK x"                                              # not hex
t 1 --save --bogus                                                     # unknown option still refused
s0=$(date +%s); t 1 --save; s1=$(date +%s)                             # without --txn a live transaction still blocks
[ $((s1 - s0)) -ge 9 ] && okk "--save without --txn waited ~10 s ($((s1 - s0)) s)" || bad "--save without --txn did not wait ($((s1 - s0)) s)"

# ---- the txn sequence re-check (right before the p5 write) ------------------------------------------------------------
clean; sentinel
CS_TEST_HOOK="mkdir -p -m 700 $W/run/batman; printf $TOK > $MK" t 1 --save
has_sentinel && okk "--save: marker appeared before the write -> p5 untouched" || bad "--save: marker appeared but p5 was written"
clean; out=$(CS_TEST_HOOK="printf $TOK > $MK" "$W/cs" --save 2>&1)
echo "$out" | grep -q "provisioning transaction started — next tick" && okk "--save abort says 'next tick'" || bad "--save abort text: $(echo "$out" | tail -1)"
clean; sentinel
CS_TEST_HOOK="printf '$TOK 1 2 network/leave\nprev - - -\n' > $TX" t 1 --on-join
has_sentinel && okk "--on-join: .txn appeared before the write -> p5 untouched" || bad "--on-join: .txn appeared but p5 was written"
clean; sentinel
CS_TEST_HOOK="mkdir -p -m 700 $W/run/batman; printf $TOK > $MK" t 1 --if-healthy
has_sentinel && okk "--if-healthy: marker appeared before the write -> p5 untouched" || bad "--if-healthy: marker appeared but p5 was written"
clean; marker $TOK; txnf $TOK; sentinel
CS_TEST_HOOK="printf $OTHER > $MK" t 1 --save --txn $TOK               # a NEW transaction replaced the marker
has_sentinel && okk "--save --txn: marker changed before the write -> p5 untouched" || bad "--save --txn: marker changed but p5 was written"
# controls: an empty hook -> each mode writes
clean; sentinel; CS_TEST_HOOK=":" t 0 --save
has_sentinel && bad "control --save did not write" || okk "control: --save with a no-op hook writes p5"
clean; sentinel; CS_TEST_HOOK=":" t 0 --if-healthy
clean; sentinel; out=$(CS_TEST_HOOK=":" "$W/cs" --on-join 2>&1); rc=$?
case $rc in 0|4) okk "control: --on-join with a no-op hook rc=$rc" ;; *) bad "control --on-join rc=$rc :: $(echo "$out" | tail -1)" ;; esac
clean
echo "PASS=$pass FAIL=$fail"; [ $pass -gt 0 ] && [ $fail = 0 ]
