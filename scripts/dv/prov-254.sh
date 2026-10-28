# shellcheck shell=bash disable=SC2034  # a library: its globals are read by the unit scripts
# scripts/dv/prov-254.sh — host side of the #254 prov tier-B units (docs/design/254-h23-harness.md §4.3; p1-impl §4.2–
# §4.5). Sourced by scripts/dv/prov-<unit>-254.sh, from Git Bash on the Windows host (key auth, LAN). The caller sets
# PR_UNIT and sources this file; then
#   pr_begin <secs> [upper=<variant>] [helper=<variant>[:killpoint=<p>]]
#            P9 subset -> host lock -> stage + prov lease <secs> + deadman -> snap (dirty) -> (upper-helper, push-helper)
#   pr_ota_b <payload-version> <target-slot> [nohold]
#            payload checks on the host -> push + node sha -> hold flag (== the payload's BATMAN_VERSION, cmp) ->
#            `sysupgrade -n` -> landing assertions (target slot, DT tryboot=1, hold effective, no DISCARDED);
#            a missed landing: disarm, clear the hold, retry once, then pr_needs_person
#   pr_find  wait for the node (fixed address + eth MAC), re-stage, re-acquire the lease with the remaining budget
#   pr_lease_renew <+secs>    lease + deadman, same lock
#   pr_wait_reverted          (REVERT units) TRIAL-REVERTED within the trial's own deadline + DEFER_MAX + 120 s
#   back_to_a                 leave a B trial / B committed for A (rollback + reboot committed)
#   pr_restore                p5 + overlay back, reboot committed, compare diffs=0
#   pr_brewrite               B back to V (sysupgrade -n V + hold -> HELD -> back_to_a)
#   pr_end [revert] [wrote-b] the four steps of §4.3 (bad-slot, restore, brewrite when needed, finish + lease release +
#                             02 still a neighbour and not rebooted)
#   pr_abort <why>            restore; when that fails too: pr_needs_person
#   pr_needs_person <step>    NEEDS-PERSON line + $DV_DIR/needs-person.txt, DNODE_BLOCKED=1, return 1
# Every judgement line is "PASS ..." / "FAIL ..." / "INVALID ..." / "NEEDS-PERSON ..."; pr_result prints the verdict.
set -u
NODE=${NODE:-10.41.1.3}; PEER=${PEER:-10.41.1.1}; MAC=${MAC:-88:a2:9e:b5:6c:89}
REPO=${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
PR_OUT=${PR_OUT:-//wsl.localhost/Ubuntu-24.04/home/yello/out}; PR_OUT_WSL=${PR_OUT_WSL:-/home/yello/out}
REPO_WSL=${REPO#//wsl.localhost/Ubuntu-24.04}   # the repo as WSL sees it (scripts/dv/wsl-rootfs.sh runs there)
PR_UNIT=${PR_UNIT:?PR_UNIT = the unit name (prov-<x>-254)}
case "$PR_UNIT" in prov-*-254) ;; *) echo "FAIL bad PR_UNIT $PR_UNIT"; exit 2 ;; esac
RUN=${RUN:-p$(echo "${PR_UNIT#prov-}" | tr -dc 'a-z0-9' | cut -c1-14)$(date +%m%d%H%M%S)}
SSHO="-o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 -o LogLevel=ERROR"
PRD=/tmp/run/batman-dv/bt/$RUN          # node: staged scripts (root 0700); gone with every reboot -> pr_find re-stages
PB=$REPO/scripts/node/prov-base-254.sh
HOLDF=/opt/batdata/state/autocommit-hold-commit
LOCKD=${TEMP:?TEMP unset — the host lock lives in the per-user temp dir}/batman-dv-04.lock
PR_PAY=/opt/batdata/dv-prov-ota.tar.gz   # node: the payload being installed (one at a time; removed by pr_release)
fails=0; invalid=0; PR_BEGUN=0; PR_SNAPPED=0; PR_WROTE_B=0; PR_RESTORING=0; PR_DEADLINE=0; PR_WBOX_VER=""
DNODE_BLOCKED=${DNODE_BLOCKED:-0}
say(){ echo "[$(date +%H:%M:%S) $PR_UNIT $RUN] $*"; }
ok(){ echo "PASS $PR_UNIT: $*"; }; no(){ echo "FAIL $PR_UNIT: $*"; fails=$((fails + 1)); }
inv(){ echo "INVALID $PR_UNIT: $*"; invalid=$((invalid + 1)); }
mono(){ cut -d. -f1 /proc/uptime; }
# q: one ssh (state changes are never retried); qr: read-only, retried on connection errors (255 / timeout)
q(){ timeout "${QT:-120}" ssh $SSHO root@$NODE "$@" 2>/dev/null | tr -d '\r'; }
qr(){ local o rc i; for i in 1 2 3 4 5 6; do o=$(timeout 90 ssh $SSHO root@$NODE "$@" 2>/dev/null); rc=$?; case $rc in 255|124) sleep 10 ;; *) printf '%s' "$o" | tr -d '\r'; [ -n "$o" ] && echo; return $rc ;; esac; done; return 255; }
qp(){ timeout 60 ssh $SSHO root@$PEER "$@" 2>/dev/null | tr -d '\r'; }
nb(){ timeout 900 ssh $SSHO root@$NODE "${PB_ENV:-}" sh -s -- "$@" < "$PB" 2>&1 | tr -d '\r'; }
pl(){ q "RUN_ID=$RUN sh $PRD/prov-lease-254.sh $*"; }
pw(){ QT=${QT:-180} q "RUN_ID=$RUN sh $PRD/prov-wbox-254.sh $*"; }
wsl_(){ MSYS_NO_PATHCONV=1 wsl.exe -d Ubuntu-24.04 -u yello -- "$@"; }
# the node's state line; mac first, so a stale ARP entry can never make a step act on 02 (same version)
ST='echo "mac=$(cat /sys/class/net/eth0/address 2>/dev/null) slot=$(batman-slot active) ver=$(sed -n s/^BATMAN_VERSION=//p /etc/batman-build) trial_rc=$(batman-slot is-trial >/dev/null 2>&1; echo $?) dt_try=$(hexdump -v -e "1/1 \"%02x\"" /proc/device-tree/chosen/bootloader/tryboot 2>/dev/null) hold=[$(cat /opt/batdata/state/autocommit-hold-commit 2>/dev/null)] held=$(. /usr/lib/batman/rundir.sh; ls $RUNDIR/autocommit.ctl/hold-commit 2>/dev/null | wc -l) badslot=[$(cat /opt/batdata/state/bad-slot 2>/dev/null)] protA=[$(cat /opt/batdata/state/slot-A.protected 2>/dev/null)] protB=[$(cat /opt/batdata/state/slot-B.protected 2>/dev/null)] up=$(cut -d. -f1 /proc/uptime) boot=$(cut -c1-8 /proc/sys/kernel/random/boot_id)"'
DISARM='vcmailbox 0x00038064 4 4 0 >/dev/null 2>&1; r=$(vcmailbox 0x00030064 4 4 0 2>/dev/null); set -- $r; echo "tryboot_flag=${6:-?}"'
# field <state line> <key>: the value of key=value (values never contain spaces; bracketed values keep the brackets)
field(){ printf ' %s\n' "$1" | sed -n "s/.* $2=\([^ ]*\).*/\1/p" | head -1; }

# ---- host lock (one dv run against 04 at a time; the same lock as chain1) ---------------------------------------------
pr_lock(){ mkdir "$LOCKD" 2>/dev/null || { echo "FAIL another dv run holds $LOCKD"; exit 1; }; }
pr_unlock(){ rmdir "$LOCKD" 2>/dev/null; return 0; }

# ---- staging + lease ------------------------------------------------------------------------------------------------
pr_stage(){
	local f o h
	o=$( { cat "$REPO/scripts/node/ble-lib-254.sh"; echo "scratch; d=\$BT/$RUN; [ -e \"\$d\" ] && { echo \"FAIL \$d exists\"; exit 1; }; mkdir -m 700 \"\$d\" && echo STAGED-DIR"; } | timeout 30 ssh $SSHO root@$NODE sh -s 2>&1 | tr -d '\r')
	grep -q STAGED-DIR <<< "$o" || { echo "FAIL could not create $PRD: $o"; return 1; }
	scp -q $SSHO "$REPO/scripts/node/ble-lib-254.sh" "$REPO/scripts/node/prov-lease-254.sh" "$REPO/scripts/node/prov-wbox-254.sh" root@$NODE:$PRD/ || { echo "FAIL scp of the node scripts"; return 1; }
	q "chmod 700 $PRD/*"; o=$(pl stage-check) || { echo "$o"; return 1; }
	for f in ble-lib-254.sh prov-lease-254.sh prov-wbox-254.sh; do
		h=$(sha256sum < "$REPO/scripts/node/$f" | cut -c1-64)
		grep -q "^$h  $f\$" <<< "$o" || { echo "FAIL $f on the node differs from the host copy"; return 1; }
	done
	return 0
}
# pr_acquire <secs>: stage (this boot) + lease; the host keeps the run's deadline (budget) across reboots
pr_acquire(){
	local o; o=$(pr_stage) || { echo "$o"; return 1; }
	o=$(pl acquire "$1"); grep -q '^LEASE ' <<< "$o" || { echo "FAIL lease: $o"; return 1; }
	say "$o"; return 0
}
pr_lease_renew(){	# <+secs>: lease and deadman now + secs; the run deadline moves too
	local s=${1#+} o; o=$(pl renew "$s"); grep -q '^ARMED' <<< "$o" || { no "lease renew +$s: $o"; return 1; }
	PR_DEADLINE=$(( $(mono) + s )); return 0
}

# ---- finding the node after a reboot ----------------------------------------------------------------------------------
# pr_find [<secs>] [<exclude-boot8>]: the node at $NODE with our MAC, uptime >= 60 s and steady (3 reads, same boot);
# then re-stage and re-acquire the lease with the remaining budget (>= 600 s). Sets PR_STATE.
pr_find(){
	local max=${1:-900} ex=${2:-none} t0 k=0 p="" o b u rem
	t0=$(mono); PR_STATE=""
	while [ $(( $(mono) - t0 )) -lt "$max" ]; do
		o=$(timeout 30 ssh $SSHO root@$NODE "$ST" 2>/dev/null | tr -d '\r')
		b=$(field "$o" boot); u=$(field "$o" up)
		if [ -n "$o" ] && [ "$(field "$o" mac)" = "$MAC" ] && [ "$b" != "$ex" ] && [ "${u:-0}" -ge 60 ] 2>/dev/null && { [ $k = 0 ] || [ "$b" = "$p" ]; }; then
			k=$((k + 1)); p=$b; [ $k -ge 3 ] && { PR_STATE=$o; break; }
		else k=0; fi
		sleep 5
	done
	[ -n "$PR_STATE" ] || { say "node not found steady at $NODE within ${max}s"; return 1; }
	rem=$(( PR_DEADLINE - $(mono) )); [ "$rem" -lt 600 ] && rem=600
	pr_acquire "$rem" || return 1
	PR_DEADLINE=$(( $(mono) + rem )); return 0
}

# ---- payloads -------------------------------------------------------------------------------------------------------
# pr_payload <version>: PAYF (host path), PSHA, PSTAMP (etc/batman-build read from the payload's own root.squashfs, in
# WSL: unsquashfs needs a seekable file, F44) — the payload must match its build dir's SHA256SUMS and say <version>
pr_payload(){
	local v=$1 d sums b
	d="$PR_OUT/$v/ekh-bcm2711"; sums=$d/SHA256SUMS
	PAYF=$d/batman-$v-ekh-bcm2711-ab-payload.tar.gz
	[ -f "$sums" ] && [ -f "$PAYF" ] || { echo "FAIL no payload / SHA256SUMS for $v in $d"; return 1; }
	PSHA=$(sha256sum < "$PAYF" | cut -c1-64)
	grep -q "^$PSHA  batman-$v-ekh-bcm2711-ab-payload\.tar\.gz\$" "$sums" || { echo "FAIL $PAYF does not match its SHA256SUMS"; return 1; }
	b=$PR_OUT_WSL/$v/ekh-bcm2711/batman-$v-ekh-bcm2711-ab-payload.tar.gz
	# the stamp is EXTRACTED and must be a regular file in a real etc/ (no -cat: a symlink is never followed; review r2 B-n4)
	PSTAMP=$(wsl_ bash "$REPO_WSL/scripts/dv/wsl-rootfs.sh" stamp "$b" | tr -d '\r') \
		&& [ -n "$PSTAMP" ] || { echo "FAIL cannot read etc/batman-build (a regular file) from $v's root.squashfs"; return 1; }
	[ "$(sed -n 's/^BATMAN_VERSION=//p' <<< "$PSTAMP")" = "$v" ] || { echo "FAIL $v's rootfs says BATMAN_VERSION=$(sed -n 's/^BATMAN_VERSION=//p' <<< "$PSTAMP")"; return 1; }
	return 0
}
# pr_rootfs_cat <version> <path>: one file of the payload's rootfs on stdout (WSL)
pr_rootfs_cat(){ wsl_ bash "$REPO_WSL/scripts/dv/wsl-rootfs.sh" cat "$PR_OUT_WSL/$1/ekh-bcm2711/batman-$1-ekh-bcm2711-ab-payload.tar.gz" "$2"; }
# pr_wbox_checks <version>: a -wbox payload is pushed only when it carries the product gate, its own witness, and the
# protected set (the slot decision code) byte-equal to the normal build of the same rc (254-h23 §19.3, §22.4)
PROTSET="usr/sbin/batman-slot usr/bin/batman-autocommit etc/init.d/batman-autocommit usr/lib/batman/otatrace.sh usr/lib/batman/rundir.sh usr/lib/batman/bootfacts.sh usr/lib/batman/meshjoin.sh"
pr_wbox_checks(){
	local v=$1 name base f a b c wit files n=0 sv
	# the product's rule (batman-slot wbox_stamp): BATMAN_WBOX=<x> OR a version naming .wbox- is a wbox image; the two
	# must agree here, or the payload is refused (review r2 A-m4 / B-n4)
	name=$(sed -n 's/^BATMAN_WBOX=//p' <<< "$PSTAMP"); sv=$(sed -n 's/^BATMAN_VERSION=//p' <<< "$PSTAMP")
	case "$sv" in *.wbox-*) [ -n "$name" ] && [ "${sv##*.wbox-}" = "$name" ] || { echo "FAIL $v: version names wbox variant ${sv##*.wbox-} but BATMAN_WBOX=[$name]"; return 1; } ;;
		*) [ -z "$name" ] || { echo "FAIL $v: BATMAN_WBOX=$name but the version does not name it"; return 1; }; return 0 ;; esac
	case "$name" in misc-*) echo "FAIL $v is a misc-* variant (dry-run only, never installed; §19.3)"; return 1 ;; esac
	pr_rootfs_cat "$v" usr/sbin/batman-slot | grep -q 'holds a -wbox test image' || { echo "FAIL pre-gate image: $v's batman-slot has no wbox gate"; return 1; }
	base=${v%.wbox-$name}; [ "$base" != "$v" ] || { echo "FAIL $v does not end in .wbox-$name"; return 1; }
	# the normal build of the same rc: the same version without the wbox suffix (with or without .dirty)
	b=""; for c in "$base" "${base%.dirty}"; do [ -f "$PR_OUT/$c/ekh-bcm2711/SHA256SUMS" ] && { b=$c; break; }; done
	[ -n "$b" ] || { echo "FAIL no normal build $base next to $v (protected-set comparison)"; return 1; }
	for f in $PROTSET; do
		# each side read in full and non-empty first: two failed reads hash equal (e3b0c442…) — never a pass (r2 A-m3)
		a=$(set -o pipefail; pr_rootfs_cat "$v" "$f" | sha256sum | cut -c1-64) && c=$(set -o pipefail; pr_rootfs_cat "$b" "$f" | sha256sum | cut -c1-64) \
			|| { echo "FAIL $v / $b: cannot read the protected $f"; return 1; }
		case "$a$c" in *e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855*) echo "FAIL $v / $b: the protected $f is empty or missing"; return 1 ;; esac
		[ "$a" = "$c" ] || { echo "FAIL $v: protected $f differs from the normal build $b"; return 1; }
	done
	if [ "$name" != test ]; then
		wit=$(sed -n 's/^# wbox-witness: //p' "$REPO/tests/wbox/$name.patch" | head -1)
		files=$(sed -n 's#^+++ b/feed/[^/]*/files/##p' "$REPO/tests/wbox/$name.patch")
		grep -q '^+++ b/feed/batman-prov/src/' "$REPO/tests/wbox/$name.patch" && files="$files usr/bin/batman-provhelper"
		for f in $files; do n=$(( n + $(pr_rootfs_cat "$v" "$f" 2>/dev/null | grep -ac -- "$wit") )); done
		[ "$n" -ge 1 ] || { echo "FAIL $v: witness $wit not found in its rootfs ($files)"; return 1; }
	fi
	PR_WBOX_VER=$v
	echo "wbox $name: gate present, protected set == $b, witness ok"; return 0
}

# ---- OTA into the other slot ----------------------------------------------------------------------------------------
pr_ota_b(){	# <payload-version> <target-slot> [nohold]
	local v=$1 tgt=$2 hold=1 try o s b0 hv
	shift 2; for o in "$@"; do case "$o" in
		nohold) [ "$PR_UNIT" = prov-wbox-nocommit-254 ] || { no "nohold is only for prov-wbox-nocommit-254"; return 1; }; hold=0 ;;
		*) no "pr_ota_b: bad option $o"; return 1 ;; esac; done
	o=$(pr_payload "$v") || { no "payload $v: $o"; return 1; }
	pr_payload "$v" >/dev/null
	o=$(pr_wbox_checks "$v") || { no "$o"; return 1; }; [ -n "$o" ] && { say "$o"; PR_WBOX_VER=$v; }
	hv=$(sed -n 's/^BATMAN_VERSION=//p' <<< "$PSTAMP")
	for try in 1 2; do
		s=$(qr "$ST"); say "before OTA ($v -> $tgt, try $try): $s"
		[ "$(field "$s" slot)" != "$tgt" ] && [ "$(field "$s" trial_rc)" = 1 ] || { no "OTA precondition: committed on the other slot ($s)"; return 1; }
		[ "$(q "df -k /opt/batdata | awk 'NR==2 {print \$4}'")" -gt 400000 ] 2>/dev/null || { no "p6 has < 400 MB free for the payload"; return 1; }
		scp -q $SSHO "$PAYF" root@$NODE:$PR_PAY.part && q "mv $PR_PAY.part $PR_PAY" || { no "payload upload"; return 1; }
		[ "$(qr "sha256sum < $PR_PAY | cut -c1-64")" = "$PSHA" ] || { no "payload sha on the node"; return 1; }
		if [ $hold = 1 ]; then
			q "printf '%s\n' '$hv' > $HOLDF; sync"
			[ "$(qr "cat $HOLDF")" = "$hv" ] || { no "hold flag read-back"; return 1; }
		fi
		PR_WROTE_B=1; b0=$(field "$s" boot)
		q "setsid sh -c 'sysupgrade -n $PR_PAY >/opt/batdata/dv-prov-sysup.log 2>&1' </dev/null >/dev/null 2>&1 &"
		say "sysupgrade -n sent ($hv, hold=$hold)"
		pr_find 900 "$b0" || { pr_needs_person "no node after the OTA reboot"; return 1; }
		pr_lease_renew +900 || return 1
		s=$PR_STATE; say "landed: $s"
		if [ "$(field "$s" slot)" = "$tgt" ] && [ "$(field "$s" ver)" = "$hv" ] && [ "$(field "$s" trial_rc)" = 0 ] && [ "$(field "$s" dt_try)" = 00000001 ]; then
			[ $hold = 0 ] && { ok "landed in the $tgt trial of $hv (no hold: prov-wbox-nocommit-254)"; return 0; }
			o=$(qr '. /usr/lib/batman/rundir.sh; echo "disc=$([ -e $RUNDIR/autocommit.hold-discarded ] && echo 1 || echo 0) dlog=$(grep -c "HOLD-COMMIT-DISCARDED boot=$(cut -c1-8 /proc/sys/kernel/random/boot_id)" /opt/batdata/log/autocommit.log 2>/dev/null)"')
			if [ "$o" = "disc=0 dlog=0" ]; then
				[ "$(field "$s" held)" = 1 ] && [ "$(field "$s" hold)" = "[]" ] || { no "hold not effective in the trial ($s)"; back_to_a; return 1; }
				ok "landed in the $tgt trial of $hv, hold effective"; return 0
			fi
			no "HOLD-COMMIT-DISCARDED ($o)"
			if [ "$(qr 'batman-slot is-trial >/dev/null 2>&1; echo $?')" = 0 ]; then back_to_a; else pr_needs_person "the $tgt slot was committed after a discarded hold — run: batman-slot rollback; batman-slot reboot committed"; fi
			return 1
		fi
		say "missed landing (want slot=$tgt ver=$hv trial) — disarm, clear the hold"
		q "$DISARM; rm -f $HOLDF; sync" | sed 's/^/    /'
		[ "$(field "$s" trial_rc)" = 0 ] && back_to_a
	done
	pr_needs_person "OTA to $tgt missed its landing twice"; return 1
}
# back_to_a: from a B trial (or B committed) to A committed
back_to_a(){
	local s b0 o; s=$(qr "$ST"); b0=$(field "$s" boot)
	[ "$(field "$s" slot)" = B ] || { say "back_to_a: already on $(field "$s" slot)"; PR_STATE=$s; return 0; }
	o=$(q 'batman-slot rollback >/dev/null 2>&1 && { (batman-slot reboot committed prov-dv-254 </dev/null >/dev/null 2>&1 &); echo SENT; }')
	say "back_to_a: ${o:-rollback refused}"; grep -q SENT <<< "$o" || return 1
	pr_find 900 "$b0" || return 1
	[ "$(field "$PR_STATE" slot)" = A ] && [ "$(field "$PR_STATE" trial_rc)" = 1 ] || { say "back_to_a: not A committed: $PR_STATE"; return 1; }
	return 0
}
# pr_wait_held [max-uptime]: the trial reports HELD (healthy, held for operator acceptance)
pr_wait_held(){ local max=${1:-480} u; while :; do qr 'logread | grep -q "is healthy and HELD"' && return 0; u=$(qr 'cut -d. -f1 /proc/uptime'); [ "${u:-0}" -ge "$max" ] && return 1; sleep 10; done; }
# pr_wait_reverted: (REVERT units) TRIAL-REVERTED; budget = the trial's deadline + DEFER_MAX 600 + 120 s (F42); HELD
# instead = the mutant had no effect; a hard reboot without TRIAL-REVERTED (trial panic) = INVALID, not "no effect"
pr_wait_reverted(){
	local dl b0 t0 o s
	dl=$(qr '. /usr/lib/batman/rundir.sh; cat $RUNDIR/autocommit.deadline 2>/dev/null'); b0=$(field "$(qr "$ST")" boot)
	case "$dl" in ''|*[!0-9]*) no "no autocommit deadline in the trial"; return 1 ;; esac
	t0=$(mono); say "waiting for TRIAL-REVERTED (deadline uptime ${dl}s + 600 + 120)"
	while :; do
		o=$(timeout 30 ssh $SSHO root@$NODE 'logread | grep -E "is healthy and HELD|revert deferred:" | tail -2' 2>/dev/null | tr -d '\r')
		grep -q "is healthy and HELD" <<< "$o" && { no "the trial is HELD — the mutant had no effect"; back_to_a; return 1; }
		grep -q "revert deferred:" <<< "$o" && pr_lease_renew +600 >/dev/null
		s=$(timeout 30 ssh $SSHO root@$NODE "$ST" 2>/dev/null | tr -d '\r')
		[ -n "$s" ] && [ "$(field "$s" boot)" != "$b0" ] && break
		[ $(( $(mono) - t0 )) -gt $(( dl + 600 + 120 + 300 )) ] && { no "no revert within the budget"; return 1; }
		sleep 10
	done
	pr_find 900 "$b0" || return 1
	o=$(qr "grep 'TRIAL-REVERTED' /opt/batdata/log/autocommit.log | tail -1; tail -3 /opt/batdata/log/boot-reasons.log")
	if grep -q "TRIAL-REVERTED" <<< "$o" && [ "$(field "$PR_STATE" slot)" = A ]; then ok "TRIAL-REVERTED, back on A: $(head -1 <<< "$o")"; return 0; fi
	grep -qiE 'panic|watchdog' <<< "$o" && { inv "trial panic (hard reboot, no TRIAL-REVERTED): $o"; return 1; }
	no "no TRIAL-REVERTED after the trial ($o)"; return 1
}

# ---- restore ----------------------------------------------------------------------------------------------------------
# pr_compare <tag>: manifest + compare against the snapshot (joinwatch stopped meanwhile: p5 is not rw-mounted under the
# manifest); PR_CMP = the compare output; rc 0 = diffs=0
pr_compare(){
	local o="" i
	q "mkdir -p -m 0700 /tmp/run/batman-dv"; scp -q $SSHO "$REPO/tests/prov-p1/overlay-allow.txt" root@$NODE:/tmp/run/batman-dv/overlay-allow.txt
	q "/etc/init.d/joinwatch stop >/dev/null 2>&1"
	for i in 1 2 3; do nb manifest "$RUN" "$1" >/dev/null; o=$(nb compare "$RUN" "$1"); grep -q "p5 unreadable" <<< "$o" || break; sleep 10; done
	q "/etc/init.d/joinwatch start >/dev/null 2>&1"; PR_CMP=$o
	grep -q "diffs=0" <<< "$o"
}
# pr_restore_cycle [skip]: p5 + overlay back (PROV_BASE_SKIP=<skip> for a negative control), reboot committed, find;
# PR_RCYCLE_OUT = the restore output. rc 1 = a step failed (not the compare: the caller judges that)
pr_restore_cycle(){
	local o s b0 skip=${1:-}
	s=$(qr "$ST"); if [ "$(field "$s" trial_rc)" = 0 ]; then back_to_a || { pr_needs_person "restore: cannot leave the trial"; return 1; }; s=$PR_STATE; fi
	[ "$(field "$s" slot)" = A ] && [ "$(field "$s" trial_rc)" = 1 ] || { pr_needs_person "restore: not on A committed ($s)"; return 1; }
	pr_lease_renew +1800 || return 1
	pl restoring set >/dev/null
	o=$(pw unbind-all); say "unbind: $(echo $o)"
	q "rm -f $HOLDF $PR_PAY; rm -rf /tmp/run/batman-prov-test"
	o=$(PB_ENV=${skip:+PROV_BASE_SKIP=$skip} nb p5-restore "$RUN"); PR_RCYCLE_OUT=$o; say "$(echo "$o" | tail -1)"; grep -q "^P5-RESTORED $RUN " <<< "$o" || { no "p5 restore"; return 1; }
	o=$(PB_ENV=${skip:+PROV_BASE_SKIP=$skip} nb overlay-restore "$RUN"); PR_RCYCLE_OUT="$PR_RCYCLE_OUT
$o"; echo "$o" | grep -E "EXTRA-REMOVED|OVERLAY|SKIP" | tail -10 | sed 's/^/    /'
	grep -q "^OVERLAY-RESTORED $RUN" <<< "$o" || { no "overlay restore"; return 1; }
	b0=$(field "$s" boot); q "(batman-slot reboot committed prov-dv-254 </dev/null >/dev/null 2>&1 &)"
	pr_find 900 "$b0" || { pr_needs_person "restore: no node after the reboot"; return 1; }
	return 0
}
pr_restore(){
	PR_RESTORING=1
	pr_restore_cycle || return 1
	pr_compare after; echo "$PR_CMP" | tail -20 | sed 's/^/    /'
	grep -q "diffs=0" <<< "$PR_CMP" || { no "S0 not restored — snapshot and dirty flag kept"; return 1; }
	ok "S0 restored (p5 / overlay / uci / identity / p6 state)"; PR_RESTORING=0; return 0
}
pr_brewrite(){
	local s
	say "B back to V ($PR_V)"
	pr_ota_b "$PR_V" B || return 1
	if pr_wait_held 480; then ok "B trial of V HELD"; else no "B trial of V not HELD by uptime 480 s"; back_to_a; return 1; fi
	back_to_a || return 1
	s=$(qr "$ST"); [ "$(field "$s" protB)" = "[$PR_V]" ] && ok "slot-B.protected = V" || { no "slot-B.protected after the rewrite: $s"; return 1; }
	q "rm -f $PR_PAY"; return 0
}

# ---- needs-person / abort / end -------------------------------------------------------------------------------------
pr_needs_person(){
	local m="NEEDS-PERSON $PR_UNIT ($RUN): $* — snapshot /opt/batdata/dv-prov/$RUN and the dirty flag are kept on $NODE"
	echo "$m"; [ -n "${DV_DIR:-}" ] && echo "$m" >> "$DV_DIR/needs-person.txt"
	DNODE_BLOCKED=1; fails=$((fails + 1)); PR_PERSON=1; return 1
}
pr_finish_snap(){ local o; o=$(nb finish "$RUN"); say "$(echo "$o" | tail -1)"; grep -q "^FINISHED $RUN" <<< "$o" && PR_SNAPPED=0; }
pr_release(){
	local o
	o=$(pw unbind-all 2>/dev/null); q "rm -rf /tmp/run/batman-prov-test; rm -f $PR_PAY"
	o=$(pl release); grep -q RELEASED <<< "$o" && say "lease released" || say "lease release: $o"
	PR_BEGUN=0; pr_unlock
}
pr_abort(){
	no "ABORT: $*"
	if [ "$PR_SNAPPED" = 1 ]; then
		if pr_restore; then
			# a failed B rewrite keeps the snapshot and the dirty flag for the person (finish only when B is V again)
			if [ "$PR_WROTE_B" = 1 ] && ! pr_brewrite; then pr_needs_person "abort ($*): B rewrite failed"; pr_release; return 1; fi
			pr_finish_snap
		else pr_needs_person "abort ($*): restore failed"; PR_BEGUN=0; pr_unlock; return 1; fi
	fi
	pr_release; return 1
}
pr_end(){	# [revert] [wrote-b]
	local revert=0 o s b
	for o in "$@"; do case "$o" in revert) revert=1 ;; wrote-b) PR_WROTE_B=1 ;; esac; done
	if [ $revert = 1 ]; then
		b=$(qr 'cat /opt/batdata/state/bad-slot 2>/dev/null'); say "bad-slot: [$b]"
		if [ "$b" = "slot=B version=$PR_WBOX_VER" ]; then q 'rm -f /opt/batdata/state/bad-slot; sync'; ok "bad-slot = the reverted wbox trial (removed)"
		else pr_needs_person "bad-slot [$b] is not slot=B version=$PR_WBOX_VER"; return 1; fi
	fi
	pr_restore || { pr_needs_person "pr_end: restore failed"; return 1; }
	s=$(qr "$ST")
	if [ "$PR_WROTE_B" = 1 ] || [ "$(field "$s" protB)" != "[$PR_V]" ]; then pr_brewrite || { pr_needs_person "pr_end: B rewrite failed"; return 1; }
	else [ "$(qr "$PROTB_LS")" = "$PR_PROTB_LS" ] && ok "slot-B.protected = V, untouched" || no "slot-B.protected changed"; fi
	pr_finish_snap || no "finish"
	if [ -n "${OWNER:-}" ]; then pr_keys_drop; [ "$(wsl_ bash -c "[ -e $WSLK ] && echo left" | tr -d '\r')" = left ] && no "run keys still in $WSLK" || ok "run keys removed"; fi
	pr_release
	pr_peer_after
}
PROTB_LS='ls -ln --full-time /opt/batdata/state/slot-B.protected 2>/dev/null || ls -ln /opt/batdata/state/slot-B.protected'
pr_peer_after(){	# 02: a neighbour of 04 again (180 s window) and not rebooted (in a run over 3600 s a joinwatch reboot = WARN)
	local t0 b; t0=$(mono)
	while [ $(( $(mono) - t0 )) -lt 180 ]; do qr 'batctl n 2>/dev/null | tail -n +3 | grep -q .' && break; sleep 10; done
	qr 'batctl n 2>/dev/null | tail -n +3 | grep -q .' && ok "02 is a mesh neighbour of 04" || no "02 not a neighbour of 04 within 180 s"
	b=$(qp 'cut -c1-8 /proc/sys/kernel/random/boot_id')
	if [ "$b" = "$PR_PEER_BOOT" ]; then ok "02 not rebooted"
	elif [ $(( $(mono) - PR_T0 )) -gt 3600 ] && [ "$(qp 'echo "$(batman-slot active) $(batman-slot is-trial >/dev/null 2>&1; echo $?)"')" = "A 1" ]; then echo "WARN $PR_UNIT: 02 rebooted during a run over 3600 s (joinwatch, F33) and is back on A committed"
	else no "02 rebooted (boot $PR_PEER_BOOT -> ${b:-unreachable})"; fi
}
pr_result(){ say "RESULT fails=$fails invalid=$invalid"
	if [ "$fails" = 0 ] && [ "$invalid" = 0 ]; then echo "UNIT $PR_UNIT PASS"; return 0; fi
	[ "$fails" = 0 ] && { echo "UNIT $PR_UNIT INVALID"; return 2; }; echo "UNIT $PR_UNIT FAIL"; return 1; }

# ---- begin ------------------------------------------------------------------------------------------------------------
pr_p9(){	# the P9 subset of pr_begin: S0 slot condition, nothing left of an earlier run, 02 a neighbour
	local s o r=0
	s=$(qr "$ST"); say "04: $s"
	[ "$(field "$s" mac)" = "$MAC" ] || { echo "FAIL 04 not at $NODE (mac [$(field "$s" mac)])"; return 1; }
	[ "$(field "$s" slot)" = A ] && [ "$(field "$s" trial_rc)" = 1 ] || { echo "FAIL 04 not A committed"; r=1; }
	[ "$(field "$s" hold)" = "[]" ] && [ "$(field "$s" badslot)" = "[]" ] || { echo "FAIL hold flag / bad-slot present"; r=1; }
	case "$(field "$s" ver)$(field "$s" protA)" in *wbox*) echo "FAIL the committed slot carries a wbox image"; r=1 ;; esac
	case "$(field "$s" protB)" in *wbox*) echo "FAIL slot B carries a wbox image — restore it with pr_brewrite"; r=1 ;; esac
	o=$(qr 'echo "dirty=[$(cat /opt/batdata/state/dv-prov-dirty 2>/dev/null)] norm=[$(cat /opt/batdata/state/dv-prov-normalising 2>/dev/null)] binds=$(awk "index(\$4, \"/batman-dv/wbox/\")" /proc/self/mountinfo | wc -l) kpdir=$([ -e /tmp/run/batman-prov-test ] && echo 1 || echo 0) marker=$(/usr/bin/batman-provhelper --version 2>/dev/null | grep -c BATMAN_PROV_TEST_BUILD_7f3a) helper=$(pidof batman-provhelper >/dev/null && echo up || echo down) leases=[$(cat /tmp/run/batman-dv/bt/lease-prov /tmp/run/batman-dv/bt/lease 2>/dev/null | tr "\n" " ")] peers=$(batctl n 2>/dev/null | tail -n +3 | grep -c .)"')
	say "04: $o"
	case "$o" in *"dirty=[] norm=[] binds=0 kpdir=0 marker=0 helper=up "*) ;; *) echo "FAIL leftovers of an earlier run / helper not up: $o"; r=1 ;; esac
	[ "$(field "$o" peers)" -ge 1 ] 2>/dev/null || { echo "FAIL 02 is not a mesh neighbour of 04"; r=1; }
	return $r
}
# pr_begin <secs> [upper=<variant-file>:<sha>] [helper=<variant-file>:<sha>[:killpoint=<p>]]
pr_begin(){
	local secs=$1 o a; shift
	pr_lock; PR_T0=$(mono); PR_BEGUN=1
	trap 'pr_on_exit' EXIT; trap 'say "host interrupted"; exit 130' INT TERM
	o=$(pr_p9); echo "$o"; grep -q '^FAIL' <<< "$o" && { PR_BEGUN=0; pr_unlock; no "preconditions"; return 1; }
	PR_V=$(field "$(qr "$ST")" ver); PR_PEER_BOOT=$(qp 'cut -c1-8 /proc/sys/kernel/random/boot_id')
	PR_PROTB_LS=$(qr "$PROTB_LS")
	[ -n "$PR_PEER_BOOT" ] || { PR_BEGUN=0; pr_unlock; no "02 unreachable at $PEER"; return 1; }
	PR_DEADLINE=$(( $(mono) + secs )); o=$(pr_acquire "$secs") || { echo "$o"; PR_BEGUN=0; pr_unlock; no "lease"; return 1; }; echo "$o"
	q "mkdir -p -m 0700 /tmp/run/batman-dv"; scp -q $SSHO "$REPO/tests/prov-p1/overlay-allow.txt" root@$NODE:/tmp/run/batman-dv/overlay-allow.txt
	o=$(nb snap "$RUN"); say "$(echo "$o" | tail -1)"; grep -q "^SNAP $RUN" <<< "$o" || { pr_release; no "snap"; return 1; }
	PR_SNAPPED=1
	for a in "$@"; do case "$a" in
		upper=*) pr_upper_helper "${a#upper=}" || { pr_abort "upper-helper"; return 1; } ;;
		helper=*) pr_push_helper "${a#helper=}" || { pr_abort "push-helper"; return 1; } ;;
		*) pr_abort "pr_begin: bad argument $a"; return 1 ;;
	esac; done
	return 0
}
pr_on_exit(){ local rc=$?
	if [ "$PR_BEGUN" = 1 ] && [ "${PR_PERSON:-0}" = 1 ]; then pr_release   # a person takes over: no second restore
	elif [ "$PR_BEGUN" = 1 ]; then
		if [ "$PR_SNAPPED" = 1 ] && [ "$PR_RESTORING" = 0 ]; then no "unexpected exit (rc $rc) — restoring"; pr_abort "unexpected exit"; else pr_release; fi
	fi
	pr_unlock; }

# ---- test helpers (scripts/dv-prov-tools.sh puts them in $PR_TOOLS/<V>/<variant>/batman-provhelper + SHA256SUMS) ------
PR_TOOLS=${DV_PROV_TEST:-$HOME/batman-dv-tools/prov-test}
# pr_helper_push <variant>: the variant's helper into the node's W dir (sha checked on both ends); sets HF_SHA
pr_helper_push(){
	local v=$1 d o
	d=$PR_TOOLS/$PR_V/$v
	[ -f "$d/batman-provhelper" ] && [ -f "$d/SHA256SUMS" ] || { no "no test helper $v for $PR_V in $d (scripts/dv-prov-tools.sh)"; return 1; }
	(cd "$d" && sha256sum -c --quiet SHA256SUMS) >/dev/null 2>&1 || { no "$d/SHA256SUMS does not match"; return 1; }
	HF_SHA=$(sha256sum < "$d/batman-provhelper" | cut -c1-64)
	o=$(pw prep) || { no "W dir: $o"; return 1; }
	scp -q $SSHO "$d/batman-provhelper" root@$NODE:/tmp/run/batman-dv/wbox/$RUN/$v || { no "scp of helper $v"; return 1; }
	q "chmod 700 /tmp/run/batman-dv/wbox/$RUN/$v"
	return 0
}
pr_upper_helper(){	# <variant>
	local o; pr_helper_push "$1" || return 1
	o=$(pw upper-helper "$1" "$HF_SHA"); say "$o"; grep -q '^UPPER-HELPER' <<< "$o" || { no "upper-helper $1: $o"; return 1; }
	ok "upper helper $1 placed"; return 0
}
pr_push_helper(){	# <variant>[:killpoint=<p>]
	local v=${1%%:*} kp="" o
	case "$1" in *:killpoint=*) kp=killpoint=${1#*:killpoint=} ;; esac
	pr_helper_push "$v" || return 1
	o=$(pw push-helper "$v" "$HF_SHA" $kp); say "$o"
	grep -q '^PUSHED' <<< "$o" || { no "push-helper $1: $o"; return 1; }
	ok "helper $v bound and running${kp:+ ($kp armed)}"; return 0
}

# ---- owner keys, provclient on the node, claim (254-p1-impl §4.2; the claim-lock unit's prov-lib-254.sh, per run) ------
TOOLS=${DV_PROV_TOOLS:-/c/Users/yello/batman-dv-tools/prov}; TOOLS_WSL=${DV_PROV_TOOLS_WSL:-/home/yello/batman-dv-tools/prov}
LABKEY=${LABKEY:-$HOME/.ssh/id_ed25519}
WSLK=/home/yello/.batman-dv/prov-keys/$RUN      # per-run owner keys (WSL ext4, 0600); pr_release removes them
PCD=/tmp/run/batman-dvpc.$RUN                    # node: provclient (root 0711; it drops to uid 471)
# pr_keys: owner / enc / attacker keys for this run in WSL; OWNER / ENC / ATK = their public keys (hex)
pr_keys(){
	wsl_ bash -c "umask 077; mkdir -p $WSLK && $TOOLS_WSL/provclient-amd64 keygen $WSLK/owner.pem > $WSLK/owner.pub && $TOOLS_WSL/provclient-amd64 keygen $WSLK/enc.pem > $WSLK/enc.pub && $TOOLS_WSL/provclient-amd64 keygen $WSLK/attacker.pem > $WSLK/attacker.pub" \
		|| { no "owner key generation"; return 1; }
	OWNER=$(wsl_ cat $WSLK/owner.pub | tr -d '\r'); ENC=$(wsl_ cat $WSLK/enc.pub | tr -d '\r'); ATK=$(wsl_ cat $WSLK/attacker.pub | tr -d '\r')
	[ ${#OWNER} = 130 ] && [ ${#ENC} = 130 ] && [ ${#ATK} = 130 ] || { no "owner keys"; return 1; }
}
# pr_pc_place: provclient-arm64 into $PCD (root 0711, made without -p: a pre-existing dir is refused), sha checked
# against the tools' SHA256SUMS. tmpfs: again after every reboot.
pr_pc_place(){
	local s
	(cd "$TOOLS" && sha256sum -c --quiet SHA256SUMS) || { no "$TOOLS/SHA256SUMS does not verify"; return 1; }
	s=$(sha256sum < "$TOOLS/provclient-arm64" | cut -c1-64)
	q "mkdir -p -m 0700 /tmp/run/batman-dv"
	scp -q $SSHO "$TOOLS/provclient-arm64" root@$NODE:/tmp/run/batman-dv/pc.$RUN.upload || { no "provclient upload"; return 1; }
	[ "$(q "set -e; mkdir -m 0711 $PCD; mv /tmp/run/batman-dv/pc.$RUN.upload $PCD/provclient; chown root:root $PCD $PCD/provclient; chmod 0755 $PCD/provclient; [ \"\$(sha256sum < $PCD/provclient | cut -c1-64)\" = $s ] && echo PCOK")" = PCOK ] \
		|| { no "provclient placement in $PCD (pre-existing dir / sha)"; return 1; }
}
# pr_pc <key> [FD3=<node-side sh producing the fd-3 lines>] [PRE=<sh>] [POST=<sh>] [ENV=v ...] -- <op> [args]:
# provclient on the node; its SIGN lines go to the WSL signer; the fd-3 producer runs ON the node (a mesh key never
# crosses to the host). PRE / POST run in the SAME ssh session around it (a bind that must not outlive the op even if
# the op locks new logins out: prov-claim-kp-254's empty authorized_keys).
pr_pc(){
	local key=$1 fd3="" pre="" post="" envs="" f W SIGNP line sig out=""; shift
	while [ "$1" != -- ]; do case "$1" in FD3=*) fd3=${1#FD3=} ;; PRE=*) pre=${1#PRE=} ;; POST=*) post=${1#POST=} ;; *) envs="$envs $1" ;; esac; shift; done; shift
	f=$(mktemp -d)/p; mkfifo "$f"
	coproc SIGNP { wsl_ "$TOOLS_WSL/provclient-amd64" sign "$WSLK/$key"; }
	exec {W}<>"$f"
	local cmd="$envs $PCD/provclient node $*"
	[ -n "$fd3" ] && cmd="exec 4<&0; { $fd3; } | $envs $PCD/provclient node $* 3<&0 0<&4"
	[ -n "$pre$post" ] && cmd="${pre:+$pre >&2; }$cmd; ${post:+$post >&2}"
	while IFS= read -r line; do
		line=$(printf '%s' "$line" | tr -d '\r')
		case "$line" in
			SIGN\ *) echo "$line" >&"${SIGNP[1]}"; IFS= read -r -t 30 sig <&"${SIGNP[0]}" || sig=ERR; printf '%s\n' "$sig" | tr -d '\r' >&"$W" ;;
			*) out="$out$line
" ;;
		esac
	done < <(ssh $SSHO root@$NODE "$cmd" < "$f" 2>&1)
	exec {W}>&-; kill "$SIGNP_PID" 2>/dev/null; rm -rf "${f%/p}"
	printf '%s' "$out"
}
# pk_proof: the lab key authenticates by PUBLICKEY (a claim turns password / none off): proven on a temporary
# publickey-only listener of the same dropbear (port 2222, a tagged nft rule), removed again and asserted
PKO="-o BatchMode=yes -o ConnectTimeout=6 -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o PreferredAuthentications=publickey -o PubkeyAuthentication=yes -o IdentitiesOnly=yes -i $LABKEY -o LogLevel=VERBOSE"
NONEO="-o BatchMode=yes -o ConnectTimeout=6 -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o PreferredAuthentications=none -o PubkeyAuthentication=no -o LogLevel=ERROR"
pk_proof(){ local r=1 o
	q 'mkdir -p -m 0700 /tmp/run/batman-dv; pid=/tmp/run/batman-dv/dv-pk.pid; [ -s $pid ] && kill $(cat $pid) 2>/dev/null; nft -a list chain inet fw4 input 2>/dev/null | grep -q dv-pk-proof || nft insert rule inet fw4 input tcp dport 2222 accept comment "dv-pk-proof" 2>/dev/null; dropbear -s -g -p 2222 -P $pid && sleep 1 && [ -s $pid ] && echo LISTEN' | grep -q LISTEN || { echo "    pk_proof: listener did not start"; return 1; }
	o=$(timeout 30 ssh -p 2222 $PKO root@$NODE 'echo PKOK' 2>&1 | tr -d '\r')
	if grep -qE 'Authenticated to .* using "publickey"' <<< "$o" && grep -q PKOK <<< "$o"; then
		timeout 30 ssh -p 2222 $NONEO root@$NODE 'echo NONEOK' 2>&1 | grep -q "Permission denied" && r=0 || echo "    pk_proof: 'none' not denied on the publickey-only listener (probe invalid)"
	else echo "    pk_proof: no publickey authentication on the listener"; fi
	o=$(q 'pid=/tmp/run/batman-dv/dv-pk.pid; kill $(cat $pid) 2>/dev/null; rm -f $pid; for h in $(nft -a list chain inet fw4 input 2>/dev/null | sed -n "s/.*dv-pk-proof.*# handle \([0-9]*\).*/\1/p"); do nft delete rule inet fw4 input handle $h; done; sleep 1; echo "left=$(nft -a list chain inet fw4 input 2>/dev/null | grep -c dv-pk-proof) listen=$(netstat -ltn 2>/dev/null | grep -c ":2222 ")"')
	[ "$o" = "left=0 listen=0" ] || { echo "    pk_proof: cleanup incomplete ($o)"; r=1; }
	return $r; }
# pr_claim: legacy -> claimed with this run's owner key (publickey proven first: the claim turns password login off)
pr_claim(){
	local r
	pk_proof || { no "publickey not proven — not claiming"; return 1; }
	r=$(pr_pc owner.pem -- claim "$OWNER" "$ENC"); echo "$r" | sed 's/^/    /'
	grep -q "RESULT claim.verify code=0 " <<< "$r" || { no "claim: $r"; return 1; }
	ok "claimed with this run's owner key"
}
# pr_info: "state=<s> gen=<g> owners=<n> rm=<r>"
pr_info(){ pr_pc owner.pem -- info | sed -n 's/^RESULT info.state code=0 state=\([a-z]*\) gen=\([0-9]*\) owners=\([0-9]*\) rm=\([a-z0-9]*\).*/state=\1 gen=\2 owners=\3 rm=\4/p'; }
pr_keys_drop(){ wsl_ rm -rf "$WSLK"; q "rm -rf $PCD"; }

# ---- member on a random test mesh (254-p1-impl §4.4 single node: 04 alone, channel unchanged, never JOINED) ----------
# pr_member: claim + net-apply --first (key made on the node) -> member; then, as every member -> OTA (§4.3 F33),
# batman-slot reboot committed. Sets PR_MEMBER_GEN (the generation after the join).
pr_member(){
	local mesh r i s b0
	mesh="dvm-$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
	PR_FD3="umask 077; s=\$(head -c 16 /dev/urandom | hexdump -v -e '1/1 \"%02x\"'); printf 'mesh_id=%s\nchannel=%s\nbw=2\nsae=%s\n' '$mesh' \"\$(uci -q get wireless.radio1.channel)\" \"\$s\""
	pr_keys && pr_pc_place && pr_claim || return 1
	r=$(pr_pc owner.pem FD3="$PR_FD3" -- net-apply --first "$OWNER"); grep -q "RESULT net.apply code=0 " <<< "$r" || { no "join: $r"; return 1; }
	i=$(pr_info); case " $i " in *" state=member "*) ;; *) no "not member after the join: $i"; return 1 ;; esac
	PR_MEMBER_GEN=$(sed -n 's/.*gen=\([0-9]*\).*/\1/p' <<< "$i"); PR_MESH=$mesh
	PR_NETCFG=$(sed -n 's/^NETCFG //p' <<< "$r")   # the signed v1 net_config: the prev of a later network/update
	ok "member of the test mesh $mesh (gen $PR_MEMBER_GEN)"
	s=$(qr "$ST"); b0=$(field "$s" boot)
	q "(batman-slot reboot committed prov-dv-254 </dev/null >/dev/null 2>&1 &)"
	pr_find 900 "$b0" || return 1
	pr_pc_place || return 1
	return 0
}
# pr_trial_line <ERE> [tries]: the first logread line of this boot matching ERE (polled; the trial's autocommit logs it
# once at its start)
pr_trial_line(){ local t=0 r; while [ $t -lt "${2:-30}" ]; do r=$(qr "logread | grep -m1 -E '$1'"); [ -n "$r" ] && { echo "$r"; return 0; }; sleep 10; t=$((t + 1)); done; return 1; }

# ---- killpoints (254-h23 §4.1.1, §16.1) -------------------------------------------------------------------------------
# pr_killpoint <point> <provclient op args...>: the test helper bound with the point armed -> the op (the owner signs) ->
# the node must die mid-transaction by sysrq "b". Judged by §16.1: (a) armed + file consumed (push-helper asserts it),
# (b) no reply to the op, (c) no "killpoint <p>: fallback" in a host-side `logread -f` stream, (d) a new boot_id,
# (f) boot-reasons UNCLEAN with "hints: sysrq" (absent = INVALID: the console capture is off). (e) — the state the node
# comes back in — is the unit's own judgement.
pr_killpoint(){
	local p=$1 b0 lf lp r o; shift
	pr_push_helper "test:killpoint=$p" || return 1
	ok "(a) killpoint $p armed by the bound test helper, the file consumed"
	b0=$(field "$(qr "$ST")" boot)
	lf=$(mktemp); timeout 900 ssh $SSHO root@$NODE 'logread -f' > "$lf" 2>/dev/null & lp=$!
	sleep 2
	r=$(pr_pc owner.pem FD3="$PR_FD3" -- "$@"); say "trigger output: $(echo "$r" | grep -v '^NETCFG' | tr '\n' '|' | cut -c1-200)"
	grep -q '^RESULT' <<< "$r" && no "(b) the op got a reply — killpoint $p did not fire" || ok "(b) no reply to the op (the node went down)"
	pr_find 900 "$b0" || { kill $lp 2>/dev/null; no "(d) no node after the killpoint"; return 1; }
	kill $lp 2>/dev/null; wait $lp 2>/dev/null
	ok "(d) boot_id changed ($b0 -> $(field "$PR_STATE" boot))"
	grep -q "killpoint $p: fallback" "$lf" && no "(c) 'killpoint $p: fallback' seen — sysrq did not work" || ok "(c) no fallback line in the logread stream ($(wc -l < "$lf") lines)"
	rm -f "$lf"
	o=$(qr 'tail -1 /opt/batdata/log/boot-reasons.log')
	case "$o" in *UNCLEAN*"hints: sysrq"*) ok "(f) boot-reasons: UNCLEAN, hints: sysrq" ;; *) inv "(f) boot-reasons without the sysrq hint: $o" ;; esac
	pr_pc_place || return 1
	return 0
}
