#!/bin/bash
# tests/prov-p1/cfgsave-txn-save.sh <batman-config-save> — WSL/CI root (loop device). #254 wireless-txn §7 / §11:
#   --save --txn TOK is accepted only while the run-dir marker AND /etc/batman-prov/.txn both carry TOK
#   (the helper's Finish persists before it removes .txn); without --txn a live transaction still blocks --save;
#   --save / --if-healthy / --on-join re-read the txn sequence right before the p5 write and abort when a transaction
#   started meanwhile (white-box: a test-only hook line is sed-inserted into the COPY just before the re-check).
# v8 (§15.3 / §15.6): --check reports rc 5 "p5 stale: an unfinished network change (.txn)" while .txn exists (the OTA
#   freshness gate refuses); modes without --txn require the sequence "none none" right after their live-transaction
#   check (white-box: a second hook just before SEQ0 is read); .txn counts by existence (a dangling symlink too).
# PROV_SRC = product files/ dir. Test-only edits of the copy: p5 = a loop device, PROVD / rundir.sh in the test dir.
# Negative control: the shipped batman-config-save FAILs the --txn and the re-check cases. Zero cases run = FAIL.
set -u
[ "$(id -u)" = 0 ] || { echo "FAIL needs root (loop device)"; echo "PASS=0 FAIL=1"; exit 1; }
W=$(mktemp -d); LOOP2=""; LOOP3=""
trap 'grep " $W/" /proc/mounts | cut -d" " -f2 | xargs -r -n1 umount 2>/dev/null; umount $W/m 2>/dev/null; losetup -d $LOOP 2>/dev/null; [ -z "$LOOP2" ] || losetup -d $LOOP2; [ -z "$LOOP3" ] || losetup -d $LOOP3; rm -rf $W' EXIT
SRC=${PROV_SRC:-$(cd "$(dirname "$1")/../.." && pwd)}   # files/ of the product tree (override for a copied file)
truncate -s 64M $W/p5.img; LOOP=$(losetup -f --show $W/p5.img); mkfs.ext4 -q -F $W/p5.img
mkdir -p $W/prov $W/m $W/bin $W/run; chmod 755 $W/run; chmod 700 $W/prov
sed "s#^RUNDIR=/tmp/run/batman#RUNDIR=$W/run/batman#" "$SRC/usr/lib/batman/rundir.sh" > $W/rundir.sh
sed -e "s#^DEV=/dev/mmcblk0p5#DEV=$LOOP#" -e "s#^PROVD=/etc/batman-prov#PROVD=$W/prov#" \
	-e "s#/usr/lib/batman/prov-lock.sh#$SRC/usr/lib/batman/prov-lock.sh#g" -e "s#/usr/lib/batman/rundir.sh#$W/rundir.sh#g" \
	-e '/^# txn sequence re-check, right before the p5 write/i [ -n "${CS_TEST_HOOK:-}" ] \&\& eval "$CS_TEST_HOOK"' \
	-e 's/SEQ0=\$(txn_seq) ;;/{ [ -z "${CS_TEST_HOOK0:-}" ] || eval "$CS_TEST_HOOK0"; }; SEQ0=$(txn_seq) ;;/' "$1" > $W/cs; chmod +x $W/cs
grep -q CS_TEST_HOOK0 $W/cs || echo "note: no SEQ0 read in this config-save (pre-wireless-txn) — the HOOK0 cases cannot inject"
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

# ---- v8 §15.3: --check while .txn exists -> rc 5 (the OTA freshness gate refuses) ---------------------------------------
clean; t 0 --save; t 0 --check                                         # control: fresh without .txn
txnf $TOK; t 5 --check
echo "$out" | grep -q '^batman-config-save: p5 stale: an unfinished network change (.txn)' && okk "--check names the unfinished network change" || bad "--check text: $(echo "$out" | tail -1)"
rm -f $TX; ln -s $W/nowhere $TX; t 5 --check                           # existence decides (a dangling symlink too)
clean; t 0 --check                                                     # control: back to fresh once .txn is gone

# ---- v8 §15.6 (B m1): a transaction that starts between the live-transaction check and SEQ0 -----------------------------
clean; sentinel
CS_TEST_HOOK0="mkdir -p $W/run/batman; printf $TOK > $MK" t 1 --save
has_sentinel && okk "--save: marker appeared before SEQ0 -> refused, p5 untouched" || bad "--save: marker appeared before SEQ0 but p5 was written"
clean; out=$(CS_TEST_HOOK0="printf $TOK > $MK" "$W/cs" --save 2>&1)
echo "$out" | grep -q "provisioning transaction in progress — next tick" && okk "--save refusal says 'in progress — next tick'" || bad "--save SEQ0 refusal text: $(echo "$out" | tail -1)"
clean; sentinel
CS_TEST_HOOK0="printf '$TOK 1 2 network/join\nprev - - -\n' > $TX" t 1 --on-join
has_sentinel && okk "--on-join: .txn appeared before SEQ0 -> refused, p5 untouched" || bad "--on-join: .txn appeared before SEQ0 but p5 was written"
clean; sentinel
CS_TEST_HOOK0="mkdir -p $W/run/batman; printf $TOK > $MK" t 1 --if-healthy
has_sentinel && okk "--if-healthy: marker appeared before SEQ0 -> refused, p5 untouched" || bad "--if-healthy: marker appeared before SEQ0 but p5 was written"
# --txn is unaffected by the "none none" rule
clean; marker $TOK; txnf $TOK; CS_TEST_HOOK0=":" t 0 --save --txn $TOK
# B m11: .txn counts by existence in the live-transaction check too (a dangling symlink blocks --on-join at once)
clean; sentinel; ln -s $W/nowhere $TX; t 1 --on-join
has_sentinel && okk "--on-join with a dangling .txn symlink: refused, p5 untouched" || bad "--on-join with a dangling .txn symlink wrote p5"

# ---- code review 2 (B MAJOR-1): .txn -> rc 5 BEFORE the p5 checks (unmountable / not ext4 / no p5 / bypass) ----------
# not ext4: a zeroed loop device (HEAD: "p5 SKIP not-ext4" rc 3 -> the OTA gate writes skip:, not blocking)
truncate -s 8M $W/raw.img; LOOP2=$(losetup -f --show $W/raw.img)
# unmountable ext4: the magic stays, the superblock counters in front of it are zeroed (HEAD: "p5 error mount" rc 1)
truncate -s 64M $W/bad.img; mkfs.ext4 -q -F $W/bad.img; dd if=/dev/zero of=$W/bad.img bs=1 seek=1024 count=56 conv=notrunc 2>/dev/null
LOOP3=$(losetup -f --show $W/bad.img)
for v in "raw:$LOOP2" "bad:$LOOP3" "nop5:$W/no-such-p5"; do
	sed "s#^DEV=$LOOP#DEV=${v#*:}#" $W/cs > $W/cs.${v%%:*}; chmod +x $W/cs.${v%%:*}
done
cx(){ out=$("$W/cs.$1" --check 2>&1); rc=$?; }
clean; cx raw; [ $rc = 3 ] && okk "control: not-ext4 p5, no .txn -> rc 3" || bad "control not-ext4: rc=$rc $(echo "$out" | tail -1)"
clean; cx bad; [ $rc = 1 ] && okk "control: unmountable p5, no .txn -> rc 1" || bad "control unmountable: rc=$rc $(echo "$out" | tail -1)"
txnf $TOK
for k in raw bad nop5; do
	cx $k
	if [ $rc = 5 ] && echo "$out" | grep -q '^batman-config-save: p5 stale: an unfinished network change (.txn)'; then okk ".txn + $k p5: --check rc 5 'unfinished network change'"
	else bad ".txn + $k p5: rc=$rc :: $(echo "$out" | tail -1)"; fi
done

# ---- review 3 (B m5 / A m8): SIGTERM to the process group while p5 is mounted rw mid-save (batman-provhelper's Exec
# deadline). Run under busybox ash in its own session (pgid = pid), park it in the hook just before the p5 write.
clean; sentinel; rm -f $W/at-hook
setsid busybox sh -c "CS_TEST_HOOK='touch $W/at-hook; sleep 20' exec busybox sh $W/cs --save" > $W/term.out 2>&1 & tp=$!
i=0; while [ ! -f $W/at-hook ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
[ -f $W/at-hook ] && okk "TERM test: the save reached the hook with p5 mounted rw ($(grep -c " $W/run/batman/cfgsave-mnt" /proc/mounts) mount)" || bad "TERM test: the hook was never reached :: $(tail -2 $W/term.out | tr '\n' ' ')"
kill -TERM -- -$tp 2>/dev/null; wait $tp; trc=$?
[ $trc = 143 ] && okk "TERM: exit 143" || bad "TERM: rc=$trc (want 143)"
grep -q " $W/run/batman/cfgsave-mnt" /proc/mounts && bad "TERM: p5 is STILL mounted ($(grep " $W/run/batman/cfgsave-mnt" /proc/mounts | cut -d' ' -f2))" || okk "TERM: p5 unmounted"
grep -q "^$LOOP " /proc/mounts && bad "TERM: $LOOP still mounted somewhere" || okk "TERM: $LOOP not mounted anywhere"
[ -d $W/run/batman/cfgsave.lock ] && bad "TERM: cfgsave.lock left behind" || okk "TERM: lock released"
mount -o ro $LOOP $W/m; st=$(ls -d $W/m/.stage.* 2>/dev/null | wc -l); tmpf=$(find $W/m -name '*.tmp' | wc -l); umount $W/m
[ "$st" = 0 ] && okk "TERM: no stage left on p5" || bad "TERM: $st stage dir(s) left on p5"
[ "$tmpf" = 0 ] && okk "TERM: no temp file left on p5" || bad "TERM: $tmpf temp file(s) on p5"
has_sentinel && okk "TERM: p5 overrides untouched (killed before the write)" || bad "TERM: p5 overrides changed"
t 0 --save
# the identity is renamed into place from the stage (control: the files arrive and the stage is empty afterwards)
mount -o ro $LOOP $W/m; st=$(ls -d $W/m/.stage.* 2>/dev/null | wc -l); umount $W/m
[ "$st" = 0 ] && okk "after the next --save: no stage left" || bad "after --save: $st stage dir(s)"
clean
echo "PASS=$pass FAIL=$fail"; [ $pass -gt 0 ] && [ $fail = 0 ]
