#!/bin/bash
# Hardware self-test for the GPT A/B card (#133). Run against a BENCH node, never a field one.
#
#   scripts/ab-selftest.sh <node-addr> [--inspect-only|--destructive]
#
#   --inspect-only  static invariants only, NO reboots — safe to run on a schedule
#   (default)       static invariants + the happy path (2 reboots, ~2 min)
#   --destructive   also induces the failure classes below (4 reboots, ~6 min)
#
# Scheduled runs should use --inspect-only: it catches a card that has drifted (autoboot.txt
# edited by hand, or a fallback that was never reconciled) without power-cycling a node.
#
# With --destructive it induces the two failure classes #133 found, each of which must recover
# on its own, and restores what it broke:
#
#   fw-fallback    the inactive slot cannot be booted BY THE FIRMWARE  -> falls back
#   kernel-panic   the inactive slot boots but its rootfs is unusable  -> panics and returns
#
# The second one is the reason `rootwait=20 panic=10` exists: with a bare `rootwait` the node
# hangs forever instead, silently, because procd never starts and the watchdog is never armed.
#
# Both card layouts (`batman-slot layout`): pi4 (GPT, EEPROM bootloader) and pi3 (hybrid MBR + p7
# firmware partition, #209). On pi3 the fw-fallback case may HANG the board (no EEPROM to fall back)
# and needs a power pull, so it runs only as `ATTENDED=1 scripts/ab-selftest.sh <node> --destructive`
# from a terminal; without that it is reported as a FAIL ("not run"), never as a pass.
# Every reboot this script causes first drops a one-boot `autocommit-skip-once` token on p6 so
# batman-autocommit (v2.2) cannot commit or revert the trial under the test.
#
# Every assertion here is a string comparison against remote output, so an empty or error
# string must never be allowed to satisfy one — a self-test that passes vacuously is worse
# than no self-test. Values are validated, not just compared.
set -uo pipefail

NODE=${1:?usage: ab-selftest.sh <node-addr> [--inspect-only|--destructive]}
MODE=${2:-}
case "$MODE" in ""|--inspect-only|--destructive) ;; *) echo "unknown mode: $MODE"; exit 2 ;; esac

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $*"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $*"; }

# Our own known_hosts, never the operator's. A slot switch legitimately changes the node's
# dropbear host key, so the pin has to be dropped between reboots; doing that to a personal
# ~/.ssh/known_hosts would silently weaken trust for every other use of that address.
KH=$(mktemp); HEADFILE=$(mktemp); trap 'rm -f "$KH" "$HEADFILE"' EXIT

SSHOPTS=(-o UserKnownHostsFile="$KH" -o StrictHostKeyChecking=accept-new
         -o ConnectTimeout=8 -o BatchMode=yes -o LogLevel=ERROR)
sshn()   { timeout 30 ssh "${SSHOPTS[@]}" "root@$NODE" "$@" 2>&1; }
# Binary-safe: sshn folds stderr into stdout, which corrupts a disk image in transit.
sshraw() { timeout 120 ssh "${SSHOPTS[@]}" "root@$NODE" "$@"; }

be32() {                             # big-endian u32 from device-tree, as DECIMAL
  local h
  h=$(sshn "hexdump -C /proc/device-tree/chosen/bootloader/$1" | head -1 | awk '{print $2$3$4$5}')
  [[ $h =~ ^[0-9a-f]{8}$ ]] || { echo ""; return 1; }
  echo $((16#$h))
}
slot()    { sshn 'tr " " "\n" < /proc/cmdline | grep -o "batman_slot=."' | tr -d '\r' | cut -d= -f2; }
boot_id() { sshn 'cat /proc/sys/kernel/random/boot_id' | tr -d '\r'; }
is_slot() { [[ ${1:-} =~ ^[AB]$ ]]; }

# bootA is ALWAYS mounted at /boot (p1) regardless of the running slot; bootB (p3) is not
# mounted. The read must key off the REQUESTED slot's fixed partition, NOT the running slot.
# The old SLOT0-keyed form silently broke on a node running slot B: for want=A it tried to
# mount the busy p1 (already at /boot) -> mount fails -> read nothing; for want=B it cat'd
# /boot (which is bootA) -> wrong file. Every static invariant then FAILed although the card
# was fine — caught on manet01 (running slot B) during #173 validation.
boot_cat() {                         # $1 = A|B, $2 = filename
  local want=$1 f=$2
  if [ "$want" = A ]; then sshn "cat /boot/$f"; return; fi
  sshn "mkdir -p /mnt/_ab; mount -t vfat -o ro /dev/mmcblk0p3 /mnt/_ab >/dev/null 2>&1; cat /mnt/_ab/$f; umount /mnt/_ab"
}
bootb_rw() { sshn "mkdir -p /mnt/_ab; mount -t vfat /dev/mmcblk0p3 /mnt/_ab && { $1 ; }; sync; umount /mnt/_ab"; }

reboot_wait() {                      # $1 = tryboot|plain ; $2 = max seconds
  local mode=$1 max=${2:-180} i before after
  before=$(boot_id)
  [[ $before =~ ^[0-9a-f-]{36}$ ]] || { echo "NOBOOTID"; return 1; }
  [ "$mode" = tryboot ] && sshn 'vcmailbox 0x00038064 4 4 1 >/dev/null' >/dev/null
  sshn '(sleep 1; reboot) >/dev/null 2>&1 &' >/dev/null
  sleep 12
  for ((i=12; i<max; i+=5)); do
    # Liveness by ssh, not ping: `ping -c1 -W1` is Linux-only (Windows/Git-Bash ping.exe rejects the
    # flags), and an IPv6 link-local bench node ("fe80::…%if") is reached over ssh anyway. ssh-up also
    # means sshd is ready, which is what the boot_id read below needs. (#133 portability)
    if timeout 6 ssh "${SSHOPTS[@]}" "root@$NODE" true >/dev/null 2>&1; then
      ssh-keygen -f "$KH" -R "$NODE" >/dev/null 2>&1
      after=$(boot_id)
      # A node that never rebooted answers instantly with the SAME boot_id. Accepting that
      # would let every destructive assertion below pass without the case ever running.
      if [[ $after =~ ^[0-9a-f-]{36}$ ]] && [ "$after" != "$before" ]; then echo "$i"; return 0; fi
    fi
    sleep 5
  done
  echo "TIMEOUT"; return 1
}
# batman-autocommit (ab-autocommit v2.2) would otherwise commit (or revert) a healthy trial under us —
# then "plain reboot returns to the committed slot" sees B committed. Before every reboot this script
# causes, drop a one-boot `autocommit-skip-once` token on p6; after it, prove the token was consumed.
# A token that survives would later disarm a REAL OTA's gate (#209 S5 review): it is removed here, and
# batman-slot apply / platform_check_image also remove any leftover before a real write.
skip_arm()  { sshn '[ -d /opt/batdata/state ] && : > /opt/batdata/state/autocommit-skip-once && sync && echo ARMED' | grep -q ARMED \
                || bad "could not drop the autocommit skip-once token (no /opt/batdata/state?) — autocommit may act under this test"; }
skip_check() { if sshn '[ -e /opt/batdata/state/autocommit-skip-once ] && echo LEFT' | grep -q LEFT; then
                 bad "skip-once token NOT consumed by the boot (autocommit too old, or p6 not mounted) — removed now"
                 sshn 'rm -f /opt/batdata/state/autocommit-skip-once; sync' >/dev/null; fi; }
# reboot with the token: sets RB_T (seconds or TIMEOUT/NOBOOTID), returns reboot_wait's status
rb() { local rc; skip_arm; RB_T=$(reboot_wait "$1" "${2:-180}"); rc=$?; [ $rc -eq 0 ] && skip_check; return $rc; }
# after a manual power pull: wait for a boot_id different from $1 (taken before the case started)
reboot_wait_up() {                   # $1 = boot_id before ; $2 = max seconds
  local before=$1 max=${2:-240} i after
  for ((i=0; i<max; i+=5)); do
    if timeout 6 ssh "${SSHOPTS[@]}" "root@$NODE" true >/dev/null 2>&1; then
      ssh-keygen -f "$KH" -R "$NODE" >/dev/null 2>&1
      after=$(boot_id)
      if [[ $after =~ ^[0-9a-f-]{36}$ ]] && [ "$after" != "$before" ]; then echo "$i"; return 0; fi
    fi
    sleep 5
  done
  echo "TIMEOUT"; return 1
}

echo "=== A/B self-test against $NODE ==="
SLOT0=$(slot)
is_slot "$SLOT0" || { echo "FATAL: $NODE did not report a usable batman_slot (got '${SLOT0:0:60}')."; echo "Either it is unreachable or it is not an A/B card built by build-gpt-ab-card.sh. Refusing."; exit 2; }
PART0=$(be32 partition)
[[ $PART0 =~ ^[0-9]+$ ]] || { echo "FATAL: could not read chosen/bootloader/partition. Refusing."; exit 2; }
LAYOUT=$(sshn 'batman-slot layout' | tr -d '\r')
if ! [[ $LAYOUT =~ ^pi[34]$ ]]; then
  # A pre-#209 batman-slot has no `layout`; it only ever ran on Pi 4 GPT cards. Accept that one case
  # for --inspect-only (so the fleet can be baselined before its upgrade) — anything else is refused.
  # No reboots there: its autocommit ignores the skip-once token, so a live run would let it commit
  # the trial under the test AND leave the token on p6 to disarm the node's next real OTA.
  if sshn 'cat /proc/device-tree/compatible' | grep -q bcm2711; then
    LAYOUT=pi4; echo "NOTE: pre-#209 batman-slot on a bcm2711 node — treating the card as pi4, inspect-only"
    [ "$MODE" = --inspect-only ] || { echo "FATAL: a pre-#209 node allows only --inspect-only (see the comment above). Refusing."; exit 2; }
  else
    echo "FATAL: batman-slot layout gave '${LAYOUT:0:60}' and the node is not a bcm2711. Refusing."; exit 2
  fi
fi
echo "running slot=$SLOT0 firmware partition=$PART0 layout=$LAYOUT"

echo
echo "--- static invariants ---"
# pi4: autoboot.txt lives on bootA. pi3: on the firmware partition p7, which stays unmounted except
# for short read-only looks like this one (#209 v4.3 D3).
# The trap unmounts p7 even when the ssh session is cut: a p7 left mounted makes batman-slot refuse
# every later commit (write_autoboot_pi3), and the next OTA trial would then be reverted.
P7RO='m=/mnt/_p7; mkdir -p $m; trap "umount $m 2>/dev/null" EXIT HUP INT TERM; mount -t vfat -o ro /dev/mmcblk0p7 $m >/dev/null 2>&1 || { echo NOMOUNT; exit; }'
if [ "$LAYOUT" = pi3 ]; then
  AB=$(sshn "$P7RO; cat \$m/autoboot.txt")
else
  AB=$(boot_cat A autoboot.txt)
fi
grep -q '^tryboot_a_b=1' <<<"$AB" && ok "tryboot_a_b=1 present" || bad "tryboot_a_b=1 missing — A/B switching is inert"
grep -q '^\[tryboot\]' <<<"$AB" && ok "[tryboot] section present" || bad "[tryboot] section missing"
AB_ALL=$(awk '/^\[all\]/{s=1;next}/^\[/{s=0}s&&/^boot_partition=/{sub(/.*=/,"");print;exit}' <<<"$AB")
AB_TRY=$(awk '/^\[tryboot\]/{s=1;next}/^\[/{s=0}s&&/^boot_partition=/{sub(/.*=/,"");print;exit}' <<<"$AB")

if ! [[ $AB_ALL =~ ^[0-9]+$ ]]; then
  bad "autoboot.txt has no numeric [all] boot_partition (got '$AB_ALL')"
elif [ "$AB_ALL" = "$PART0" ]; then
  ok "autoboot.txt [all]=$AB_ALL agrees with the slot actually booted ($PART0)"
else
  bad "autoboot.txt [all]=$AB_ALL but the firmware booted partition $PART0 — a fallback happened and autoboot.txt was never repaired (#133)"
fi
if ! [[ $AB_TRY =~ ^[0-9]+$ ]]; then
  bad "autoboot.txt has no numeric [tryboot] boot_partition (got '$AB_TRY') — A/B switching is inert"
elif [ "$LAYOUT" = pi3 ]; then
  # pi3 numbers partitions by hybrid-MBR entry: 1 = p7 (firmware), 2 = bootA, 3 = bootB (E0f/E0d)
  if [[ $AB_ALL =~ ^[23]$ ]] && [[ $AB_TRY =~ ^[23]$ ]] && [ "$AB_ALL" != "$AB_TRY" ]; then
    ok "pi3 [all]=$AB_ALL [tryboot]=$AB_TRY are the two slot MBR entries"
  else
    bad "pi3 autoboot.txt [all]=$AB_ALL [tryboot]=$AB_TRY — want the two slot MBR entries 2 and 3, different"
  fi
  FP=$(sshn "batman-slot fw-part $SLOT0" | tr -d '\r')
  [ "$FP" = "$AB_ALL" ] && ok "pi3 [all]=$AB_ALL is slot $SLOT0's MBR entry (batman-slot fw-part)" \
                        || bad "pi3 [all]=$AB_ALL but batman-slot fw-part $SLOT0 = '${FP:0:60}'"
elif [ "$AB_TRY" = 3 ]; then
  bad "[tryboot] boot_partition=3 is the GPT index; the firmware counts only bootable FAT partitions, so bootB is 2 (#133)"
else
  ok "[tryboot] boot_partition=$AB_TRY is a plausible firmware index"
fi

# the same sanity every slot op runs first: layout vs SoC, FAT count, pi3 hybrid MBR, DT vs cmdline
V=$(sshn 'batman-slot verify')
if grep -q 'verify ok' <<<"$V"; then ok "batman-slot verify: ${V##*verify ok }"
elif grep -q 'usage:' <<<"$V"; then bad "batman-slot has no 'verify' (pre-#209 image) — the card sanity checks cannot run; upgrade the node"
else bad "batman-slot verify refused: ${V:0:200}"; fi

if [ "$LAYOUT" = pi3 ]; then
  # p7 must hold an allow-listed bootcode.bin, autoboot.txt with tryboot_a_b, and a config.txt (an
  # absent one stops the boot — E0g V1-V3). Checked on the node against its own allow-list.
  P7=$(sshn "$P7RO"'
    h=$(sha256sum $m/bootcode.bin 2>/dev/null | cut -d" " -f1)
    grep -q "^$h  bootcode.bin$" /usr/share/batman/firmware-allowlist-bcm2710.sha256 2>/dev/null && echo BOOTCODE_OK || echo "BOOTCODE_BAD:$h"
    [ -f $m/config.txt ] && echo CONFIG_OK || echo CONFIG_MISSING
    grep -q "^tryboot_a_b=1" $m/autoboot.txt 2>/dev/null && echo AUTOBOOT_OK || echo AUTOBOOT_BAD')
  grep -q BOOTCODE_OK <<<"$P7" && ok "p7 bootcode.bin is on the firmware allow-list" || bad "p7 bootcode.bin not allow-listed / unreadable: ${P7:0:120}"
  grep -q CONFIG_OK <<<"$P7" && ok "p7 config.txt present" || bad "p7 config.txt missing — the Pi 3 will not boot (E0g)"
  grep -q AUTOBOOT_OK <<<"$P7" && ok "p7 autoboot.txt has tryboot_a_b=1" || bad "p7 autoboot.txt unreadable or without tryboot_a_b=1"
fi

for S in A B; do
  CL=$(boot_cat "$S" cmdline.txt)
  if ! grep -q "batman_slot=$S" <<<"$CL"; then
    bad "slot $S cmdline.txt unreadable or missing its batman_slot marker — the checks below would pass vacuously"
    continue
  fi
  ok "slot $S cmdline.txt read and carries batman_slot=$S"
  grep -Eq '(^| )rootwait=[1-9][0-9]*( |$)' <<<"$CL" && ok "slot $S rootwait is bounded" \
    || bad "slot $S has no rootwait=N — a bad slot then hangs forever instead of recovering (#133)"
  grep -Eq '(^| )rootwait( |$)' <<<"$CL" && bad "slot $S has a BARE rootwait (#133)" || ok "slot $S has no bare rootwait"
  grep -Eq '(^| )panic=[1-9][0-9]*( |$)' <<<"$CL" && ok "slot $S has panic=N" || bad "slot $S has no panic=N (#133)"
done

if [ "$MODE" = --inspect-only ]; then
  echo
  echo "(inspect-only: no reboots performed)"
  echo "================ $PASS passed, $FAIL failed ================"
  [ "$FAIL" -eq 0 ]; exit
fi

echo
echo "--- live: tryboot switches slots, and the trial is one-shot ---"
if rb tryboot; then
  T=$RB_T; S=$(slot); P=$(be32 partition); TB=$(be32 tryboot)
  if ! is_slot "$S"; then bad "node came back but did not report a usable batman_slot (got '${S:0:40}')"
  elif [ "$S" != "$SLOT0" ]; then ok "tryboot switched $SLOT0 -> $S (partition=$P, tryboot=$TB, ${T}s)"
  else bad "tryboot did not switch: still slot $S, partition=$P (silent no-op — check boot_partition numbering, #133)"; fi
else
  bad "node did not come back after tryboot ($RB_T)"
fi

if rb plain; then
  T=$RB_T; S=$(slot)
  if ! is_slot "$S"; then bad "node came back but did not report a usable batman_slot (got '${S:0:40}')"
  elif [ "$S" = "$SLOT0" ]; then ok "plain reboot returned to the committed slot $S (${T}s)"
  else bad "trial boot stuck: expected $SLOT0, got $S"; fi
else
  bad "node did not come back after a plain reboot ($RB_T)"
fi

if [ "$MODE" != --destructive ]; then
  echo
  echo "(skipping the failure cases; pass --destructive to run them)"
  echo "================ $PASS passed, $FAIL failed ================"
  [ "$FAIL" -eq 0 ]; exit
fi

# The interlock has to test the slot the node is on RIGHT NOW, not the one it booted with.
# Nothing above aborts — every failure path calls `bad`, which only counts — so a tryboot that
# got stuck, or a plain-reboot timeout, leaves the node RUNNING slot B while $SLOT0 still says
# A. Both destructive cases below address bootB/rootB by fixed path (p3/p4), so clearing this
# guard on a stale value means destroying the slot the node is currently running from, in a
# script whose banner promises it only touches the inactive one. Re-read before each case.
require_inactive_B() {                # $1 = which case, for the message
  local cur
  cur=$(slot)
  is_slot "$cur" || { echo; echo "FATAL: cannot read the node's current slot (got '${cur:0:40}') — refusing to touch p3/p4 ($1)."; exit 2; }
  [ "$cur" = A ] || { echo; echo "FATAL: destructive cases break the INACTIVE slot and expect a fallback to slot A."; echo "The node is running slot $cur right now, so p3/p4 are the ACTIVE slot. Refusing ($1)."; echo "Commit back to slot A first."; exit 2; }
}

[ "$SLOT0" = A ] || { echo; echo "FATAL: destructive cases break the INACTIVE slot and expect a fallback to slot A."; echo "Commit back to slot A first. Refusing."; exit 2; }
require_inactive_B "destructive 1/2"

echo
echo "--- destructive 1/2: inactive slot unbootable by the firmware ---"
# pi4: start4.elf (the EEPROM bootloader falls back — #133). pi3: BOTH start.elf and start_cd.elf —
# which one bootB's firmware picks depends on bootB's own config (gpu_mem), which may differ from the
# running slot's, so both go (#209 §4 row 143: whether bootcode then falls back, hangs, or boots B on
# yet another start file is exactly what this case finds out).
# On a pi3 a hang needs a power pull, so the case runs only with ATTENDED=1 and a terminal.
STARTFS=start4.elf
[ "$LAYOUT" = pi3 ] && STARTFS="start.elf start_cd.elf"
STAGE=1
if [ "$LAYOUT" = pi3 ] && { [ "${ATTENDED:-0}" != 1 ] || ! [ -r /dev/tty ]; }; then
  bad "pi3 fw-fallback case needs ATTENDED=1 and a terminal (a hang needs someone to pull power) — not run"; STAGE=0
fi
if [ "$STAGE" = 1 ]; then
  for f in $STARTFS; do bootb_rw "mv /mnt/_ab/$f /mnt/_ab/$f.selftest" >/dev/null; done
  L=$(bootb_rw "ls /mnt/_ab" | tr -d '\r')
  for f in $STARTFS; do grep -qx "$f.selftest" <<<"$L" || STAGE=2; done
fi
if [ "$STAGE" = 2 ]; then
  bad "could not stage the fw-fallback case (bootB not writable?) — skipping it rather than reporting a pass"
  for f in $STARTFS; do bootb_rw "[ -e /mnt/_ab/$f.selftest ] && mv /mnt/_ab/$f.selftest /mnt/_ab/$f" >/dev/null; done
elif [ "$STAGE" = 1 ]; then
  BID0=$(boot_id)
  if rb tryboot 240; then R=up
  elif [ "$LAYOUT" = pi3 ]; then
    echo "  .. node did not come back in 240s — the firmware hung on bootB (expected 'ACT flashes, no fallback')."
    read -r -p "  >> Pull the node's power, plug it back in, then press Enter: " _ < /dev/tty
    if RB_T=$(reboot_wait_up "$BID0" 240); then R=power; skip_check; else R=dead; fi
  else R=dead; fi
  T=$RB_T; S=$(slot)
  case "$R:$S" in
    up:A)    ok "firmware fell back to slot A on its own (${T}s)" ;;
    power:A) ok "firmware HUNG without $STARTFS; after a power pull the node came back on slot A — recovery needs a site visit (record in §4 row 143)" ;;
    *:B)     if sshn 'batman-slot is-trial >/dev/null; echo rc=$?' | grep -q 'rc=0'; then
               bad "slot B BOOTED without $STARTFS — the firmware used another start file, so this case tested nothing; B is still an uncommitted trial, a plain reboot returns to A"
             else
               bad "slot B BOOTED without $STARTFS AND is now committed (skip-once not honoured?) — rolling back to A"
               sshn 'batman-slot rollback' >/dev/null || bad "rollback to A refused — fix by hand before using this card"
             fi
             rb plain || bad "plain reboot after the B boot did not come back ($RB_T)" ;;
    *)       bad "node did not come back ($R, slot '${S:0:40}') — the firmware-level fallback did not happen" ;;
  esac
  for f in $STARTFS; do bootb_rw "mv /mnt/_ab/$f.selftest /mnt/_ab/$f" >/dev/null; done
  # Inside the staged branch on purpose. When staging failed, the files were never renamed, so this
  # check would print a green "restored" line for a restore that never ran.
  L=$(bootb_rw "ls /mnt/_ab" | tr -d '\r'); RST=1
  for f in $STARTFS; do grep -qx "$f" <<<"$L" || RST=0; done
  [ "$RST" = 1 ] && ok "restored bootB/{$STARTFS}" \
                 || bad "bootB start file(s) NOT restored ($STARTFS) — slot B is left unbootable by the firmware, fix it before using this card"
fi

echo
echo "--- destructive 2/2: inactive slot boots but its rootfs is unusable ---"
# Case 1/2 can itself leave the node on B (a fallback that did not happen), and its failure
# path only counted a FAIL. Re-check before zeroing p4.
require_inactive_B "destructive 2/2"
# The saved block lives HERE, not on the node: the node's /tmp is tmpfs and every case under
# test reboots it, so a backup left there is gone exactly when it is needed.
sshraw 'dd if=/dev/mmcblk0p4 bs=1M count=1 2>/dev/null' > "$HEADFILE"
if [ "$(stat -c%s "$HEADFILE")" != 1048576 ]; then
  bad "could not save rootB's head — refusing to damage it, so this case did not run"
else
  sshn 'dd if=/dev/zero of=/dev/mmcblk0p4 bs=1M count=1 conv=fsync 2>/dev/null; sync' >/dev/null
  if rb tryboot; then
    T=$RB_T; S=$(slot)
    [ "$S" = A ] && ok "kernel panicked and the node returned to slot A on its own (${T}s)" \
                 || bad "expected recovery to A, got '${S:0:40}'"
  else
    bad "node never came back — this is the bare-rootwait dead hang; cmdline needs rootwait=N panic=N (#133) ($RB_T)"
  fi
  sshraw 'dd of=/dev/mmcblk0p4 bs=1M conv=fsync 2>/dev/null; sync' < "$HEADFILE"
  RB=$(sshn 'dd if=/dev/mmcblk0p4 bs=4 count=1 2>/dev/null | hexdump -C' | head -1 | awk '{print $2$3$4$5}')
  [ "$RB" = "68737173" ] && ok "restored rootB (squashfs magic back)" || bad "rootB NOT restored — head is '$RB', re-flash it"
fi

echo
echo "================ $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
