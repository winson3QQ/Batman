#!/bin/sh
# scripts/node/prov-p9-254.sh — #254 preflight P9 on a node (docs/design/254-h23-harness.md §4.7, §22.2, §23.4):
# what an earlier prov run may have left behind, and whether a -wbox TEST image could become (or is) the default.
# Read-only (a temporary read-only mount of the other slot's squashfs under a mktemp dir, removed). Run as root via
# `ssh node sh -s`; every line is FAIL / WARN / INFO / ok; the last line is "P9 clean" or "P9 fails=<n>".
# busybox ash.
set -u
# P9_TEST_ROOT (tests/prov-p1/p9-judge.sh only, never set on a node): every fixed path below is read under it
P9R=${P9_TEST_ROOT:-}; MI=${P9R:+$P9R/mountinfo}; MI=${MI:-/proc/self/mountinfo}
[ -n "$P9R" ] || [ "$(id -u)" = 0 ] || { echo "FAIL P9 root only"; echo "P9 fails=1"; exit 1; }
fails=0
no(){ echo "FAIL $*"; fails=$((fails + 1)); }
ST=$P9R/opt/batdata/state; BT=$P9R/tmp/run/batman-dv/bt
KPD=$P9R/tmp/run/batman-prov-test
iswbox(){ [ -f "$1" ] && [ ! -L "$1" ] && grep -q '^BATMAN_VERSION=' "$1" || return 2   # same rule as batman-slot wbox_stamp
	grep -q '^BATMAN_WBOX=.' "$1" && return 0; sed -n 's/^BATMAN_VERSION=//p' "$1" | grep -q '\.wbox-' && return 0; return 1; }
alive(){ case "$1" in ''|*[!0-9]*) return 1 ;; esac; [ -d "/proc/$1" ]; }

act=$(batman-slot active 2>/dev/null); batman-slot is-trial >/dev/null 2>&1; tr=$?
ver=$(sed -n "s/^BATMAN_VERSION=//p" $P9R/rom/etc/batman-build 2>/dev/null)
echo "INFO slot=$act is_trial=$tr ver=$ver"
# --- the running image and the committed slot
iswbox $P9R/rom/etc/batman-build; r=$?
[ "$r" = 2 ] && no "the running image's /rom/etc/batman-build is unreadable"
[ "$r" = 0 ] && [ "$tr" = 1 ] && no "the COMMITTED running slot $act is a -wbox test image ($ver) — commit a release image on a release slot; never run a prov unit here"
[ "$r" = 0 ] && [ "$tr" != 1 ] && echo "INFO running a -wbox trial ($ver)"
for s in A B; do
	p=$(cat "$ST/slot-$s.protected" 2>/dev/null)
	case "$p" in *wbox*)
		if [ "$s" = "$act" ] && [ "$tr" = 1 ]; then no "slot-$s.protected names a wbox image ($p) on the committed slot"
		else no "slot $s holds a -wbox image ($p) — restore it: scripts/dv/prov-254.sh pr_brewrite (B back to V)"; fi ;;
	esac
done
[ "$tr" = 1 ] && [ -z "$(cat "$ST/slot-$act.protected" 2>/dev/null)" ] && echo "WARN slot-$act.protected is missing on the committed slot"
# --- [all] (§23.4): only on a Pi 4 A/B card
if [ "$(batman-slot layout 2>/dev/null)" = pi4 ] && [ -f $P9R/boot/autoboot.txt ]; then
	. $P9R/usr/lib/batman/bootfacts.sh 2>/dev/null
	x=$(bf_ab_all "$P9R/boot"); fa=$(batman-slot fw-part A 2>/dev/null); fb=$(batman-slot fw-part B 2>/dev/null)
	case "$x" in 1|2) ;; *) no "[all] boot_partition unreadable or not 1|2 ([$x])" ;; esac
	[ -n "$fa" ] && [ -n "$fb" ] && [ -n "$act" ] || no "batman-slot fw-part / active unreadable (A=[$fa] B=[$fb] active=[$act])"
	S=""; [ "$x" = "$fa" ] && S=A; [ "$x" = "$fb" ] && S=B
	trialnow=0; [ "$(bf_dt tryboot)" = 00000001 ] && [ "$tr" = 0 ] && trialnow=1
	[ $trialnow = 1 ] && echo "INFO trial in progress (DT tryboot=1, slot $act)"
	# [all] == the running slot outside a trial = an ordinary committed node: nothing to judge
	if [ -n "$S" ] && { [ "$S" != "$act" ] || [ $trialnow = 1 ]; }; then
		dev=/dev/mmcblk0p2; [ "$S" = B ] && dev=/dev/mmcblk0p4
		{
			mkdir -p -m 700 $P9R/tmp/run/batman-dv 2>/dev/null; m=$(mktemp -d $P9R/tmp/run/batman-dv/p9.XXXXXX)
			if mount -t squashfs -o ro "$dev" "$m" 2>/dev/null; then
				iswbox "$m/etc/batman-build"; w=$?; sv=$(sed -n 's/^BATMAN_VERSION=//p' "$m/etc/batman-build" 2>/dev/null)
				umount "$m"; rmdir "$m"
				p=$(cat "$ST/slot-$S.protected" 2>/dev/null)
				case "$w" in
					0) no "[all] points at slot $S, a -wbox image ($sv) — on the release slot run: batman-slot commit" ;;
					2) no "[all] points at slot $S whose build stamp is unreadable" ;;
					1) [ -n "$p" ] && [ "$p" != "$sv" ] && no "slot-$S.protected [$p] != slot $S's own stamp [$sv]"
					   [ $trialnow = 0 ] && echo "WARN [all] points at slot $S, not the running $act (stale fallback / Pi 4 EEPROM booted the wrong slot) — $sv" ;;
				esac
			else rmdir "$m" 2>/dev/null; no "[all] points at slot $S but its squashfs ($dev) cannot be mounted"; fi
		}
	fi
	[ -z "$S" ] && [ -n "$x" ] && no "[all]=$x is neither slot's firmware partition (A=$fa B=$fb)"
else echo "INFO [all] check not applicable (not a Pi 4 A/B card)"; fi
# --- the helper
m=$(grep -c BATMAN_PROV_TEST_BUILD_7f3a $P9R/usr/bin/batman-provhelper 2>/dev/null); [ "${m:-0}" = 0 ] || no "the running helper carries the prov_test marker"
hp=$(pidof batman-provhelper | awk '{print $1}')
[ -n "$hp" ] && logread 2>/dev/null | grep -q "batman-provhelper\[$hp\]: killpoint .*: armed" && no "helper pid $hp has a killpoint armed"
$P9R/usr/bin/batman-provhelper --version >/dev/null 2>&1 || echo "INFO pre-P1b helper (no --version): units that need the seams FAIL 'pre-P1b image'"
grep -q 'holds a -wbox test image' $P9R/usr/sbin/batman-slot 2>/dev/null || echo "INFO pre-gate image (batman-slot has no wbox gate): -wbox units FAIL 'pre-gate image' before any OTA"
# --- leftovers of a prov run
d=$(cat "$ST/dv-prov-dirty" 2>/dev/null)
# #254 v1.6 g4 PR B (docs/design/254-v16-ud.md §7, §7.1): a prov-update-254 run (RUN = p + update254 + %m%d%H%M%S,
# prov-254.sh RUN=) left mid-arm is NEEDS-PERSON: its manual recovery block is printed between UD-RECOVER-BEGIN / -END,
# with @DEAD@ = that run and @V@ = slot A's version, both validated whole (no "/", "&" or newline can reach sed);
# @NODE@ is filled by the host (pr_p9, dv-preflight). Any other run id gets the generic line.
r=${d%% *}; v=$(cat "$ST/slot-A.protected" 2>/dev/null)
udr=0; s0=""
case "$r" in pupdate254[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) udr=1 ;; esac
case "$v" in ''|*[!A-Za-z0-9.+-]*) udr=0 ;; esac
[ "${#v}" -le 80 ] || udr=0
# @S0@ (v9 B m3): the state= field of the dead run's SNAPSHOT prov.meta (its upper tar) — the record pr_begin judged —
# exactly legacy / claimed / member; the snapshot's prov-state field 3, when it exists, must agree. Else the generic line.
if [ $udr = 1 ]; then
	SD=$P9R/opt/batdata/dv-prov/$r
	s0=$(tar -xOf "$SD/upper.tar" ./etc/batman-prov/prov.meta 2>/dev/null | head -1 | sed -n 's/.* state=\([a-z]*\).*/\1/p; s/^state=\([a-z]*\).*/\1/p' | head -1)
	case "$s0" in legacy|claimed|member) ;; *) udr=0 ;; esac
	if [ -f "$SD/snap/state/prov-state" ]; then [ "$(cut -d' ' -f3 "$SD/snap/state/prov-state")" = "$s0" ] || udr=0; fi
fi
if [ -n "$d" ] && [ $udr = 1 ]; then
	no "dv-prov-dirty [$d]: run $r of prov-update-254 stopped mid-arm — NEEDS-PERSON: the manual recovery between UD-RECOVER-BEGIN and UD-RECOVER-END below (docs/design/254-v16-ud.md §7.1), step by step"
	nm=$(head -1 $P9R/etc/batman-prov/prov.meta 2>/dev/null)
	nk=$(hexdump -v -e '1/1 "%02x"' $P9R/etc/batman-prov/prov.cbor 2>/dev/null | grep -o '584104[0-9a-f]\{128\}' | grep -c .)
	echo "UD-OWNERS now: state=$(echo " $nm" | sed -n 's/.* state=\([a-z]*\).*/\1/p') gen=$(echo " $nm" | sed -n 's/.* gen=\([0-9]*\).*/\1/p') owner_keys=$nk; snapshot: state=$s0"
	echo "UD-RECOVER-BEGIN $r"
	sed -e "s/@DEAD@/$r/g" -e "s/@V@/$v/g" -e "s/@S0@/$s0/g" <<'UDREC'
# --- step 0a: host lock. If a step prints "a stale lock (host crash / TaskStop)", check that no harness runs, then run the
#     rm -rf that message names (prov-254.sh:181-188).
# --- step 0b: read-only state (no lease needed)
ssh root@@NODE@ 'cut -c1-8 /proc/sys/kernel/random/boot_id; cut -d. -f1 /proc/uptime; batman-slot active;
  batman-slot is-trial; echo trial_rc=$?; cat /opt/batdata/state/dv-prov-dirty; cat /tmp/run/batman-dv/bt/lease-prov 2>&1;
  ls -la /tmp/run/batman-dv/bt/@DEAD@ 2>&1; cat /tmp/run/batman-dv/@DEAD@/ud9.pid 2>&1'
#   - lease-prov names @DEAD@ in THIS boot with expiry > uptime: its lease and deadman are live. Wait until
#     uptime >= expiry + 60 (up to ~2 h for the trial arm; the deadman then replays @DEAD@'s journal and removes the
#     lease, ble-lib-254.sh:349-363). Repeat 0b. No later step may run before that: every acquire would refuse
#     (ble-lib-254.sh:302-305).
#   - a later step's acquire prints "run @DEAD@ did not clean up (lease expired, no deadman left)": stop here.
#     NEEDS-PERSON beyond this block. The prov lease has no recover command (section 7.1 note).
#   - the dead run's staging dir is NOT removed by hand: the next acquire's gc_rundirs removes it once no lease and no
#     live deadman names it, and prints its listing (ble-lib-254.sh:317-326).
# --- step 0b2: only if 0b printed a pid from ud9.pid (same boot only; after a reboot the pidfile and the watcher are gone).
#     busybox kill takes no "--" (ble-lib-254.sh pg_kill): the group is "-<pid>"; every member is waited for <= 10 s.
ssh root@@NODE@ 'p=$(cat /tmp/run/batman-dv/@DEAD@/ud9.pid 2>/dev/null); case "$p" in ""|*[!0-9]*) echo NO-PID; exit 0;; esac;
  [ -d /proc/$p ] || { echo GONE; exit 0; }; set -- $(cat /proc/$p/stat);
  if [ "$5" = "$p" ] && tr "\0" " " < /proc/$p/cmdline | grep -q ud9-watch-254.sh; then kill -TERM "-$p"; n=0;
  while [ $n -lt 10 ]; do a=0; for s in /proc/[0-9]*/stat; do [ "$(cut -d" " -f5 "$s" 2>/dev/null)" = "$p" ] && { a=1; break; }; done;
  [ $a = 0 ] && break; n=$((n + 1)); sleep 1; done; [ $a = 0 ] && echo KILLED || echo STILL-ALIVE; else echo NOT-THE-WATCHER; fi'
# --- step 0c: only if 0b shows slot B. A held trial: wait for its revert, then repeat 0b. A committed B, or a trial
#     without hold: back to A FIRST, with a lease but WITHOUT the journal replay (pr_stage + pl acquire, not
#     pr_acquire). back_to_a's own pr_find then acquires and replays on A, after the reboot.
PR_UNIT=prov-update-254 bash -c '. scripts/dv/prov-254.sh; pr_lock; PR_DEADLINE=$(( $(mono) + 3600 )); r=1
  pr_stage && pl acquire 3600 | grep -q "^LEASE " && { back_to_a; r=$?; }; pl release; pr_unlock; exit $r'
# --- step 1: replay @DEAD@'s journal under a NEW run id (undo-replay skips its own run, prov-lease-254.sh:100);
#     the lease is released whether the replay succeeded or not
PR_UNIT=prov-update-254 bash -c '. scripts/dv/prov-254.sh; pr_lock; PR_DEADLINE=$(( $(mono) + 3600 )); pr_acquire 3600; r=$?
  pl release; pr_unlock; exit $r'
# --- step 2: restore @DEAD@'s snapshot, rewrite B, finish. PR_WROTE_B is set after sourcing (prov-254.sh:47 resets
#     it); PR_DM_BASE = the dead run's deadman lines already logged (prov-254.sh:569-571). A refused acquire ends the
#     step at once: pr_release would act on @DEAD@'s lease if it were still live (review v7 A m1)
PR_UNIT=prov-update-254 RUN=@DEAD@ PR_V=@V@ PR_BASE=member PR_S0_STATE=@S0@ bash -c '. scripts/dv/prov-254.sh
  PR_WROTE_B=1; pr_lock; PR_DEADLINE=$(( $(mono) + 7200 ))
  PR_DM_BASE=$(qr "grep -c \"run=@DEAD@ prov deadman\" /opt/batdata/log/ble-dm-254.log 2>/dev/null"); PR_DM_BASE=${PR_DM_BASE:-0}
  pr_acquire 7200 || { pr_unlock; exit 1; }
  PR_BEGUN=1; PR_SNAPPED=1; PR_FINAL=1 pr_restore && pr_brewrite && pr_finish_snap; r=$?; pr_release; exit $r'
# --- step 3: read-only end evidence, as pr_end gives it: status phase 0, no reason, no sha (section 4.1); no watcher
PR_UNIT=prov-update-254 bash -c '. scripts/dv/prov-254.sh; pr_lock; PR_DEADLINE=$(( $(mono) + 600 )); pr_acquire 600 &&
  pr_h0 && pr_pc_place && pr_pc h0.pem -- update-status "$H0" | grep "^RESULT update.status"
  q "ps w | grep \"[u]d9-watch\" || echo NO-WATCHER"; ud_owner_scan; pl release; pr_keys_drop; pr_unlock'
#     ud_owner_scan prints prov.meta's v / state / gen / rm, the record sha and the owner fingerprints; compare them
#     with ~/.batman-dv/ud-s0/@DEAD@.txt (state=@S0@ and the same owners expected)
UDREC
	echo "UD-RECOVER-END $r"
elif [ -n "$d" ]; then no "dv-prov-dirty [$d]: run scripts/dv/prov-254.sh restore for that run (snapshot /opt/batdata/dv-prov/<run>)"; fi
# the UD unit's leftovers (254-v16-ud §4.3 "P9 scope"): FAIL when the dirty flag names a prov-update-254 run (with the
# recovery above), WARN otherwise; a live UD9 watcher and a pending undo journal on any node
gl() { if [ $udr = 1 ]; then no "$* — run $r: the UD-RECOVER block"; else echo "WARN $*"; fi; }
for c in $P9R/proc/[0-9]*/cmdline; do
	[ -f "$c" ] || continue
	tr '\0' ' ' < "$c" 2>/dev/null | grep -q 'ud9-watch-254\.sh' && { c=${c%/cmdline}; no "a ud9-watch is alive (pid ${c##*/}): kill its group (the UD-RECOVER block, step 0b2)"; }
done
pend=$(for j in $P9R/tmp/run/batman-dv/undo/*/journal $P9R/opt/batdata/state/dv-undo/*/journal; do [ -f "$j" ] && grep -q '^[0-9]* todo ' "$j" && basename "$(dirname "$j")"; done | sort -u | tr '\n' ' ')
[ -n "$pend" ] && echo "WARN undo journal pending: $pend(a node rebooted mid-arm, or the host died; the next run replays it under its lease)"
if [ "$act" = A ] || [ "$act" = B ]; then
	oth=B; [ "$act" = B ] && oth=A
	for t in 1 2 3; do bi=$(batman-slot bootinfo "$oth" 2>/dev/null); brc=$?; [ $brc != 14 ] && break; sleep "${P9_RETRY_S:-10}"; done
	case "$bi" in *bad=1*) gl "slot $oth is BAD (bootinfo bad=1)" ;; esac
	[ "$brc" = 14 ] && echo "INFO bootinfo $oth busy (rc 14) three times: not judged"
fi
if [ -n "$r" ] && [ -d "$P9R/opt/batdata/dv-prov/$r/snap/state" ]; then
	sn=$P9R/opt/batdata/dv-prov/$r/snap/state
	if [ -e "$sn/update-last" ]; then cmp -s "$sn/update-last" "$ST/update-last" || gl "update-last differs from run $r's snapshot copy"
	elif [ -e "$ST/update-last" ]; then gl "update-last present, absent in run $r's snapshot"; fi
fi
[ "$tr" = 1 ] && [ -e "$ST/autocommit-hold-commit" ] && gl "the hold flag $ST/autocommit-hold-commit is set on a committed boot"
uc=$(uci changes 2>/dev/null | wc -l); [ "${uc:-0}" -gt 0 ] && gl "uci has $uc staged change(s) (uci changes)"
for t in 1 2 3 4; do cso=$(batman-config-save --check 2>&1); csr=$?; [ $csr = 8 ] && [ $t -lt 4 ] && { sleep "${P9_RETRY_S:-5}"; continue; }; break; done
case "$csr" in
	0) ;;
	5) gl "batman-config-save --check rc 5 (p5 stale): $(echo "$cso" | tail -1 | cut -c1-120)" ;;
	3|7) echo "INFO batman-config-save --check rc $csr: $(echo "$cso" | tail -1 | cut -c1-120)" ;;
	8) echo "INFO batman-config-save --check rc 8 (busy) after 3 retries: not judged" ;;
	*) echo "INFO batman-config-save --check rc $csr" ;;
esac
n=$(cat "$ST/dv-prov-normalising" 2>/dev/null); [ -n "$n" ] && no "dv-prov-normalising [$n]: pr_normalise was interrupted — check the slots, then rm $ST/dv-prov-normalising"
b=$(awk 'index($4, "/batman-dv/wbox/") {print $5}' "$MI" | tr '\n' ' '); [ -n "$b" ] && no "harness bind mounts left: $b (prov-wbox-254.sh unbind-all)"
[ -e "$KPD" ] && no "the killpoint dir $KPD exists (left behind by a prov run)"
# provd reads provd.env only at start: removing the dir does not take a switch away (254-p2-impl L83)
if [ -z "$P9R" ]; then for p in $(pidof batman-provd); do
	tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | grep -q -E '^(SOCK_ONLY|FAST_FAKE_DELAY_MS|NO_BRUTE_LIMIT|GATT_ENCRYPT_CTRL|ADV_LEN_TEST|ADV_ID_OFF)=' && no "batman-provd pid $p runs with a prov_test switch from an earlier run: /etc/init.d/batman-provd restart"
done; fi
[ -f $P9R/opt/batdata/dv-prov/ch1-deadman.sh ] && no "chain-1 dead-man left on p6 (/opt/batdata/dv-prov/ch1-deadman.sh)"
bs=$(cat "$ST/bad-slot" 2>/dev/null); [ -n "$bs" ] && no "bad-slot [$bs] — $(case "$bs" in *wbox*) echo "a reverted wbox trial: rm $ST/bad-slot after checking";; *) echo "may be a normalise residue; check, then rm $ST/bad-slot";; esac)"
for f in $(ls -d $P9R/tmp/run/batman-dv/*/rbarm.pid $P9R/tmp/run/batman-dv/*/rbfix.pid 2>/dev/null); do alive "$(cat "$f")" && no "a rollback arm is still running ($f pid $(cat "$f"))"; done
for f in "$BT/lease-prov" "$BT/lease"; do
	[ -f "$f" ] || continue; set -- $(cat "$f")
	[ "${2:-}" = "$(cat /proc/sys/kernel/random/boot_id)" ] && no "${f##*/} of run $1 still present (expires at uptime ${3:-?})"
done
for f in $P9R/tmp/run/batman-dv/ble-state/dm $P9R/tmp/run/batman-dv/ble-state/dm.new; do
	[ -f "$f" ] && set -- $(cat "$f") && alive "${3:-}" && grep -q dm-fire "/proc/$3/cmdline" 2>/dev/null && no "a deadman is armed (${f##*/}: $*)"
done
# --- recorded only
t=$(cat "$ST/autocommit.timeout" 2>/dev/null); [ -n "$t" ] && [ "$t" -gt 600 ] 2>/dev/null && echo "INFO p6 autocommit.timeout=$t (> 600: every REVERT unit waits longer)"
echo "INFO kernel.sysrq=$(cat /proc/sys/kernel/sysrq 2>/dev/null)"
[ $fails = 0 ] && echo "P9 clean" || echo "P9 fails=$fails"
[ $fails = 0 ]
