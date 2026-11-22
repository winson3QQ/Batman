#!/bin/bash
# scripts/dv/test-deadman-254.sh — offline test of the role deadmen's reboot (#254 v1.6 group 4 §4.2 rows 36-38, §13.1,
# §15): the REAL scripts/node/ble-lib-254.sh with the REAL role script (ble-central-254.sh, ble-periph-254.sh,
# bt-uart-305.sh), driven through cmd_dm_fire (the deadman) and cmd_recover (ble-recover), under busybox sh, in a mount
# namespace with tmpfs over /tmp and /opt (the lib's own fixed paths /tmp/run/batman-dv/… and /opt/batdata/log/… are
# used as on the node and nothing reaches the host's). Stubbed on PATH: batman-slot (logs, never reboots) and vcmailbox
# (the tryboot flag in a file; STUB_DISARM_FAIL=1: the clear does not take). bootid / up_s are the real ones.
# 3 roles x 2 callers x {flag clears, flag does not clear}:
#   clears      -> the reboot is called, the lease goes
#   not cleared -> rc 3, no reboot, the lease and the dirty marker kept, dm-refused marked, the p6 line written,
#                  ble-recover prints RECOVER-REFUSED and no RECOVERED; ble_state names dm-refused; acquire refuses
# Namespace as tests/judges/h4/test-undo-lib.sh: real root -> a private mount namespace only (a user namespace would
# lose DAC on the repo owner's 0750 home); otherwise user + mount namespace. Neither available = FAIL, never a skip.
# ROOT=<tree> tests another checkout (negative control: ROOT=<b885a2c export> must FAIL).
#   bash scripts/dv/test-deadman-254.sh   -> "N PASS / M FAIL", rc 1 on any FAIL
set -u
REPO=$(cd "$(dirname "$0")/../.." && pwd); ROOT=${ROOT:-$REPO}
BB=$(command -v busybox) || { echo "FAIL no busybox (the node shell)"; echo "0 PASS / 1 FAIL"; exit 1; }
if [ "${DMT_INNER:-0}" != 1 ]; then
	[ "$(id -u)" = 0 ] && exec unshare --mount --propagation private env DMT_INNER=1 ROOT="$ROOT" bash "$0" "$@"
	exec unshare --user --map-root-user --mount --propagation private env DMT_INNER=1 ROOT="$ROOT" bash "$0" "$@"
fi
pass=0; fails=0
ok(){ echo "PASS $*"; pass=$((pass + 1)); }; no(){ echo "FAIL $*"; fails=$((fails + 1)); }
mount -t tmpfs -o mode=755 none /tmp && mount -t tmpfs -o mode=755 none /opt || { echo "FAIL tmpfs over /tmp and /opt"; echo "0 PASS / 1 FAIL"; exit 1; }
# the sandbox must be in place before anything is written: /tmp and /opt of THIS namespace are the fresh tmpfs mounts
for m in /tmp /opt; do
	t=$(awk -v m="$m" '$5 == m { for (i = 7; i <= NF; i++) if ($i == "-") { fs = $(i + 1); break } } END { print fs }' /proc/self/mountinfo)
	[ "$t" = tmpfs ] && [ -z "$(ls -A "$m")" ] || { echo "FAIL sandbox: $m is [$t] / not empty — not running"; echo "0 PASS / 1 FAIL"; exit 1; }
done
ok "sandbox: /tmp and /opt are empty tmpfs mounts of this namespace"
W=/tmp/dmt; mkdir -p "$W/bin" /opt/batdata/log; chmod 755 /opt/batdata/log
cat > "$W/bin/batman-slot" <<'X'
#!/bin/sh
echo "batman-slot $*" >> /tmp/dmt/log
case "$1" in active) echo A ;; is-trial) exit 1 ;; esac
exit 0
X
cat > "$W/bin/vcmailbox" <<'X'
#!/bin/sh
case "$1" in
	0x00038064) echo disarm >> /tmp/dmt/log; [ -n "${STUB_DISARM_FAIL:-}" ] || echo 0 > /tmp/dmt/flag ;;
	0x00030064) printf '0x0000001c 0x80000000 0x00030064 0x00000004 0x80000004 0x%08x 0x00000000\n' "$(cat /tmp/dmt/flag)" ;;
esac
X
printf '#!/bin/sh\nexit 0\n' > "$W/bin/logger"
chmod 755 "$W/bin/"*
H=/tmp/run/batman-dv; BT=$H/bt; ST=$H/ble-state; DMLOG=/opt/batdata/log/ble-dm-254.log
BOOT=$(cat /proc/sys/kernel/random/boot_id)
# setup <role script> <marker>: a fresh node: run dir with the lib + the role, an expired lease of run R1 of this boot,
# the role's dirty marker, the flag armed (1)
setup() {
	rm -rf /tmp/run "$W/log" "$DMLOG"; : > "$W/log"; echo 1 > "$W/flag"
	mkdir -p -m 700 /tmp/run "$H" "$BT" "$ST" "$BT/R1"
	cp "$ROOT/scripts/node/ble-lib-254.sh" "$ROOT/scripts/node/$1" "$BT/R1/" || return 1
	echo "R1 $BOOT 0" > "$BT/lease"
	echo "$BOOT R1" > "$ST/$2"
}
nodesh() { PATH="$W/bin:$PATH" "$BB" sh "$@"; }
rebooted() { grep -q '^batman-slot reboot committed' "$W/log"; }
# dmfire <role>: the deadman as dm_arm starts it: its own process group, the dm record naming that group
dmfire() { PATH="$W/bin:$PATH" setsid -w "$BB" sh -c 'echo "R1 $2 $$" > "$3/dm"; exec "$1" sh "$4" dm-fire R1 0 "$5"' x "$BB" "$BOOT" "$ST" "$BT/R1/$1" "$BT/lease" </dev/null >/dev/null 2>&1; }
for role in ble-central-254.sh:irk-exposed:ble-dm-254 ble-periph-254.sh:irk-exposed:ble-dm-254 bt-uart-305.sh:bt305-dirty:bt305-dm; do
	r=${role%%:*}; mk=${role#*:}; mk=${mk%%:*}; why=${role##*:}
	[ -f "$ROOT/scripts/node/$r" ] || { no "$r missing in $ROOT"; continue; }
	for fl in "" 1; do
		lbl="$r $([ -n "$fl" ] && echo "flag NOT cleared" || echo "flag clears")"
		# --- the deadman (cmd_dm_fire)
		setup "$r" "$mk" || { no "$lbl: setup"; continue; }
		STUB_DISARM_FAIL=$fl; export STUB_DISARM_FAIL
		dmfire "$r"; rc=$?
		if [ -z "$fl" ]; then
			rebooted && grep -q "^batman-slot reboot committed $why$" "$W/log" && [ ! -e "$BT/lease" ] && grep -q '^disarm$' "$W/log" \
				&& ok "dm-fire $lbl: disarmed, the lease removed, batman-slot reboot committed $why" \
				|| no "dm-fire $lbl: rc=$rc lease=$([ -e "$BT/lease" ] && echo kept || echo gone) log=[$(tr '\n' ' ' < "$W/log")]"
		else
			[ "$rc" = 3 ] && ! rebooted && [ -e "$BT/lease" ] && [ -e "$ST/$mk" ] && [ -e "$ST/dm-refused" ] \
				&& grep -q 'run=R1 deadman: tryboot not cleared — no reboot, lease kept' "$DMLOG" 2>/dev/null \
				&& ok "dm-fire $lbl: rc 3, no reboot, lease + $mk kept, dm-refused marked, p6 line written" \
				|| no "dm-fire $lbl: rc=$rc rebooted=$(rebooted && echo YES || echo no) lease=$([ -e "$BT/lease" ] && echo kept || echo GONE) dm-refused=$([ -e "$ST/dm-refused" ] && echo y || echo n) p6=[$(tail -1 "$DMLOG" 2>/dev/null)]"
			# what the next run sees: ble_state names it (preflight P6), and acquire refuses on the kept lease
			o=$(RUN_ID=R1 nodesh "$BT/R1/$r" state 2>&1)
			grep -q '^FAIL leftover: dm-refused marker (run R1)' <<< "$o" && ! grep -q '^STATE clean' <<< "$o" \
				&& ok "dm-fire $lbl: ble_state FAILs naming dm-refused (and the remedy)" || no "dm-fire $lbl: ble_state [$(grep -E '^(FAIL|STATE)' <<< "$o" | tr '\n' '|')]"
			[ "$mk" = bt305-dirty ] && { grep -q '^FAIL leftover: bt305-dirty marker of this boot' <<< "$o" && ok "dm-fire $lbl: ble_state names bt305-dirty" || no "dm-fire $lbl: ble_state does not name bt305-dirty"; }
			mkdir -p -m 700 "$BT/R2"; cp "$BT/R1/"* "$BT/R2/"
			o=$(RUN_ID=R2 nodesh "$BT/R2/$r" acquire 60 2>&1); rc=$?
			[ "$rc" != 0 ] && grep -q 'run R1 did not clean up' <<< "$o" && ok "dm-fire $lbl: the next acquire refuses (the kept lease: run ble-recover first)" || no "dm-fire $lbl: acquire after a refusal: rc=$rc [$o]"
		fi
		# --- ble-recover (cmd_recover)
		setup "$r" "$mk" || { no "$lbl: setup"; continue; }
		o=$(RUN_ID=R1 nodesh "$BT/R1/$r" recover 2>&1); rc=$?
		if [ -z "$fl" ]; then
			rebooted && [ ! -e "$BT/lease" ] && ok "recover $lbl: disarmed, the lease removed, rebooted" \
				|| no "recover $lbl: rc=$rc lease=$([ -e "$BT/lease" ] && echo kept || echo gone) log=[$(tr '\n' ' ' < "$W/log")] [$(tail -2 <<< "$o" | tr '\n' '|')]"
		else
			[ "$rc" = 3 ] && ! rebooted && [ -e "$BT/lease" ] && [ -e "$ST/$mk" ] && grep -q '^RECOVER-REFUSED deadman: tryboot not cleared' <<< "$o" && ! grep -q '^RECOVERED' <<< "$o" \
				&& ok "recover $lbl: rc 3, RECOVER-REFUSED (no RECOVERED), no reboot, lease + $mk kept" \
				|| no "recover $lbl: rc=$rc rebooted=$(rebooted && echo YES || echo no) lease=$([ -e "$BT/lease" ] && echo kept || echo GONE) [$(tail -3 <<< "$o" | tr '\n' '|')]"
		fi
	done
done
unset STUB_DISARM_FAIL
echo "$pass PASS / $fails FAIL"; [ "$fails" = 0 ]
