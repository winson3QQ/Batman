#!/bin/bash
# scripts/negctl-old-slot-254.sh — #254 PR-H1 negative control N3 (docs/design/254-h1-harness.md §4.10):
# boot <node> into its OLD slot-B build as a HELD trial, run the tier-A BLE judges there (they must FAIL: no BLE
# build), and come back to slot A. Never commits slot B. Not part of daily-validation (one-off PR evidence).
#   scripts/negctl-old-slot-254.sh <node>        (FI_PAYLOAD = the node's copy of the slot-B payload)
# Safety (design v8): the hold flag carries the PAYLOAD's version (read from slot B's own /etc/batman-build),
# the trial is checked to be held before anything else, every return to A goes through back_to_a (a node-side
# conditional: only on slot B), and the EXIT trap acts by PHASE (pre / ota / trial / returned).
# Exit 0 = the judges failed on the old build for the expected reasons and the node is back on A, committed.
# Exit 2 = could not run (hold not effective, trial not reached) — the node was sent back; not a PASS/FAIL.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
NODE=${1:?usage: negctl-old-slot-254.sh <node>}
export FI_PAYLOAD=${FI_PAYLOAD:-/opt/batdata/ota.tar.gz}
# fault-injection's readers only (q, waitboot, settle, ota_boot, bootid, slot); its EXIT trap is replaced below
# shellcheck disable=SC1091
FI_SOURCE_ONLY=1 . "$REPO/scripts/fault-injection.sh" "$NODE" --case r1 --no-tenant || exit 1
trap - EXIT
PHASE=pre; FLAGSET=0; V2=""; V9=""; B_START=""; RC=0; MAXWAIT=${NEGCTL_MAXWAIT:-2280}
say() { echo "[$(date +%H:%M:%S) $PHASE] $*"; }
flag_clear() {	# only ever before the OTA was sent (design v6 B-M1)
	q 'rm -f /opt/batdata/state/autocommit-hold-commit; sync' >/dev/null
	q '[ ! -e /opt/batdata/state/autocommit-hold-commit ]' && say "hold flag cleared (read back)" || { say "FAIL hold flag still present after rm"; RC=1; }
}
state_line() { q 'echo "slot=$(batman-slot active) ver=$(sed -n s/^BATMAN_VERSION=//p /etc/batman-build) trial_rc=$(batman-slot is-trial >/dev/null 2>&1; echo $?) hold=[$(cat /opt/batdata/state/autocommit-hold-commit 2>/dev/null)] boot=$(cut -c1-8 /proc/sys/kernel/random/boot_id)"' | tr -d '\r'; }
# THE ONLY place rollback is called: node-side, in one command, only when the node runs slot B (E34)
back_to_a() {
	local b0; b0=$(bootid)
	o=$(q "if [ \"\$(batman-slot active)\" = B ]; then v=\$(sed -n 's/^BATMAN_VERSION=//p' /etc/batman-build); [ \"\$v\" = '$V2' ] || echo \"UNEXPECTED VERSION \$v\"; batman-slot rollback && { (batman-slot reboot committed negctl-254 </dev/null >/dev/null 2>&1 &); echo SENT; }; else echo NOT-ON-B; fi" | tr -d '\r')
	say "back_to_a: $(echo "$o" | tr '\n' ' ')"
	grep -q SENT <<< "$o" || return 0
	waitboot "$b0" 600 || { say "FAIL node did not reboot after back_to_a"; RC=1; return 1; }
	settle 300 || { say "FAIL node not stably reachable after back_to_a"; RC=1; return 1; }
	PHASE=returned; say "returned: $(state_line)"
}
on_exit() {
	local rc=$?
	case "$PHASE" in
		pre) [ "$FLAGSET" = 1 ] && flag_clear ;;		# only a flag WE wrote; a pre-existing one stays
		ota)		# never clear the flag now: wait (bounded) for the new boot, then decide
			say "interrupted after the OTA was sent — waiting up to ${MAXWAIT}s for the new boot (the hold flag stays: it is V2-only and harmless)"
			waitboot "$B_START" "$MAXWAIT" && settle 300 && {
				case "$(slot)" in B) back_to_a ;; *) say "the new boot is on A (trial did not switch) — nothing to undo" ;; esac; }
			;;
		trial) back_to_a ;;
		returned) : ;;
	esac
	say "final: $(state_line)"
	say "if a hold flag is still listed above: clear it only when trial_rc=1 and the node is on A (rm /opt/batdata/state/autocommit-hold-commit)"
	rm -rf "$FI_TMP"
	[ "$RC" != 0 ] && exit "$RC"; exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT TERM		# Ctrl-C / kill still run on_exit
export NEGCTL_MAINPID=$$

# ---- 1. preconditions (read-only)
say "node $NODE, payload $FI_PAYLOAD"
s=$(state_line); say "start: $s"
case "$s" in *"slot=A "*"trial_rc=1 hold=[] "*) ;; *) say "FAIL precondition: want slot A, committed, no hold flag"; exit 1;; esac
V9=$(nodever)
o=$(QT=600 q "P=$FI_PAYLOAD; d=\$(mktemp -d); mount -t squashfs -o ro /dev/mmcblk0p4 \$d || exit 1; v=\$(sed -n 's/^BATMAN_VERSION=//p' \$d/etc/batman-build); umount \$d; rmdir \$d; p=\$(cat /opt/batdata/state/slot-B.protected 2>/dev/null); t=\$(mktemp); tar -xzf \$P -O root.squashfs > \$t; sz=\$(wc -c < \$t); a=\$(sha256sum < \$t | cut -c1-64); rm -f \$t; b=\$(head -c \$sz /dev/mmcblk0p4 | sha256sum | cut -c1-64); echo \"V=\$v P=\$p SAME=\$([ \"\$a\" = \"\$b\" ] && echo yes || echo no) VERIFY=\$(batman-slot verify >/dev/null 2>&1 && echo ok || echo bad) T=\$(cat /opt/batdata/state/autocommit.timeout 2>/dev/null || echo default)\"" | tr -d '\r')
say "slot B: $o"
V2=$(sed -n 's/^V=\([^ ]*\) .*/\1/p' <<< "$o")
[ -n "$V2" ] && grep -q "P=$V2 " <<< "$o" || { say "FAIL slot-B version from /etc/batman-build [$V2] and slot-B.protected disagree — stopping (design v5 B-M1)"; exit 1; }
grep -q 'SAME=yes' <<< "$o" || { say "FAIL $FI_PAYLOAD is not byte-identical to slot B — stopping"; exit 1; }
grep -q 'VERIFY=ok' <<< "$o" || { say "FAIL batman-slot verify"; exit 1; }
[ "$V2" != "$V9" ] || { say "FAIL slot B runs the same build as A ($V2): no old version to test"; exit 1; }
before=$(q 'echo "p5=$(sha256sum /dev/mmcblk0p5 | cut -c1-16)"; echo "uci=$(uci -q show network | sha256sum | cut -c1-16)/$(uci -q show wireless | sha256sum | cut -c1-16)"; (cd /opt/batdata/state && for f in *; do [ -f "$f" ] && echo "state $f $(sha256sum < "$f" | cut -c1-16)"; done); echo "overlayA=$(find /overlay/upper -type f 2>/dev/null | sort | xargs sha256sum 2>/dev/null | sha256sum | cut -c1-16)"' | tr -d '\r')
say "recorded:"; echo "$before" | sed 's/^/    /'

# ---- 2. hold flag = V2 (the PAYLOAD's version — the old autocommit holds only on a version match, E28)
FLAGSET=1; q "echo '$V2' > /opt/batdata/state/autocommit-hold-commit; sync" >/dev/null
[ "$(q 'cat /opt/batdata/state/autocommit-hold-commit' | tr -d '\r')" = "$V2" ] || { say "FAIL hold flag did not read back as $V2"; exit 1; }
say "hold flag = $V2"

# ---- 3. OTA into slot B (the documented OTA path; byte-identical content)
B_START=$(bootid); [ -n "$B_START" ] || { say "FAIL boot_id unreadable"; exit 1; }
PHASE=ota
ota_boot N3 "$B_START" || { say "FAIL OTA did not reach a new stable boot"; exit 1; }

# ---- 4. is the trial held? (else back to A at once; any later commit window must not be given)
o=$(q "$RDR"'echo "slot=$(batman-slot active) ver=$(sed -n s/^BATMAN_VERSION=//p /etc/batman-build) trial_rc=$(batman-slot is-trial >/dev/null 2>&1; echo $?) committed=$([ -f "$R/autocommit.committed" ] && echo yes || echo no) held=$([ -f "$R/autocommit.ctl/hold-commit" ] && echo yes || echo no) p6flag=$([ -e /opt/batdata/state/autocommit-hold-commit ] && echo yes || echo no) deadline=$(cat "$R/autocommit.deadline" 2>/dev/null) discarded=$(grep -c HOLD-COMMIT-DISCARDED /opt/batdata/log/autocommit.log 2>/dev/null)"' | tr -d '\r')
say "trial: $o"
if grep -q "slot=B ver=$V2 trial_rc=0 committed=no held=yes p6flag=no" <<< "$o"; then
	PHASE=trial
else
	say "hold NOT effective (or the trial is not slot B / $V2) — back to A now; N3 could not run"
	PHASE=trial; back_to_a; RC=2; exit 2
fi

# ---- 5. the tier-A judges on the old build: they must FAIL, for the expected reasons
j=$(cat "$REPO/scripts/node/ble-lib-254.sh" "$REPO/scripts/node/ble-privacy-254.sh" | timeout 90 ssh $S "root@$NODE" sh -s 2>&1); jr=$?
echo "$j" | sed 's/^/    ble-privacy-254: /'
t=$(timeout 60 ssh $S "root@$NODE" sh -s < "$REPO/scripts/node/prov-tools-254.sh" 2>&1); tr_=$?
echo "$t" | sed 's/^/    prov-tools-254: /'
if [ $jr != 0 ] && grep -qE '^FAIL (batman-sc missing|bluetoothd is not running|no .current settings:. line)' <<< "$j"; then
	say "NEGCTL: ble-privacy-254 FAILs on $V2 (old build) for the expected reason: $(grep -m1 '^FAIL' <<< "$j")"
else
	say "FAIL N3: ble-privacy-254 did not fail on the old build for the expected reason (rc=$jr)"; RC=1
fi
say "prov-tools-254 on $V2: rc=$tr_ (recorded; not expected to differ — the tools predate #254)"

# ---- 6/7. back to A, compare
back_to_a
s=$(state_line); say "after: $s"
case "$s" in *"slot=A ver=$V9 trial_rc=1 hold=[] "*) say "node back on A, $V9, committed, no hold flag";; *) say "FAIL node is not back on A / $V9 / committed / flag-free"; RC=1;; esac
q 'batctl n 2>/dev/null | tail -n +3 | grep -q .' && say "mesh: neighbours present" || { say "FAIL no mesh neighbour after return"; RC=1; }
cat "$REPO/scripts/node/ble-lib-254.sh" "$REPO/scripts/node/ble-privacy-254.sh" | timeout 90 ssh $S "root@$NODE" sh -s | tail -1 | sed 's/^/    tier A after return: /'
after=$(q 'echo "p5=$(sha256sum /dev/mmcblk0p5 | cut -c1-16)"; echo "uci=$(uci -q show network | sha256sum | cut -c1-16)/$(uci -q show wireless | sha256sum | cut -c1-16)"; (cd /opt/batdata/state && for f in *; do [ -f "$f" ] && echo "state $f $(sha256sum < "$f" | cut -c1-16)"; done); echo "overlayA=$(find /overlay/upper -type f 2>/dev/null | sort | xargs sha256sum 2>/dev/null | sha256sum | cut -c1-16)"' | tr -d '\r')
d=$(diff <(echo "$before") <(echo "$after"))
if [ -z "$d" ]; then say "no difference in p5 / uci / state / slot-A overlay"
else say "differences (reported, expected ones: slot-B.protected removed by the OTA, bad-slot on a revert path, autocommit/otatrace logs):"; echo "$d" | sed 's/^/    /'; fi
exit $RC
