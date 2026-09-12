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

# The running slot's boot partition is mounted at /boot; the other one has to be mounted.
# autoboot.txt only ever exists on bootA, so "read /boot/autoboot.txt" is wrong whenever the
# node is running slot B.
boot_cat() {                         # $1 = A|B, $2 = filename
  local want=$1 f=$2 part
  if [ "$want" = "$SLOT0" ]; then sshn "cat /boot/$f"; return; fi
  part=$([ "$want" = A ] && echo 1 || echo 3)
  sshn "mkdir -p /mnt/_ab; mount -t vfat -o ro /dev/mmcblk0p$part /mnt/_ab >/dev/null 2>&1; cat /mnt/_ab/$f; umount /mnt/_ab"
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
    if timeout 2 ping -c1 -W1 "$NODE" >/dev/null 2>&1; then
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

echo "=== A/B self-test against $NODE ==="
SLOT0=$(slot)
is_slot "$SLOT0" || { echo "FATAL: $NODE did not report a usable batman_slot (got '${SLOT0:0:60}')."; echo "Either it is unreachable or it is not an A/B card built by build-gpt-ab-card.sh. Refusing."; exit 2; }
PART0=$(be32 partition)
[[ $PART0 =~ ^[0-9]+$ ]] || { echo "FATAL: could not read chosen/bootloader/partition. Refusing."; exit 2; }
echo "running slot=$SLOT0 firmware partition=$PART0"

echo
echo "--- static invariants ---"
AB=$(boot_cat A autoboot.txt)
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
elif [ "$AB_TRY" = 3 ]; then
  bad "[tryboot] boot_partition=3 is the GPT index; the firmware counts only bootable FAT partitions, so bootB is 2 (#133)"
else
  ok "[tryboot] boot_partition=$AB_TRY is a plausible firmware index"
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
if T=$(reboot_wait tryboot); then
  S=$(slot); P=$(be32 partition); TB=$(be32 tryboot)
  if ! is_slot "$S"; then bad "node came back but did not report a usable batman_slot (got '${S:0:40}')"
  elif [ "$S" != "$SLOT0" ]; then ok "tryboot switched $SLOT0 -> $S (partition=$P, tryboot=$TB, ${T}s)"
  else bad "tryboot did not switch: still slot $S, partition=$P (silent no-op — check boot_partition numbering, #133)"; fi
else
  bad "node did not come back after tryboot ($T)"
fi

if T=$(reboot_wait plain); then
  S=$(slot)
  if ! is_slot "$S"; then bad "node came back but did not report a usable batman_slot (got '${S:0:40}')"
  elif [ "$S" = "$SLOT0" ]; then ok "plain reboot returned to the committed slot $S (${T}s)"
  else bad "trial boot stuck: expected $SLOT0, got $S"; fi
else
  bad "node did not come back after a plain reboot ($T)"
fi

if [ "$MODE" != --destructive ]; then
  echo
  echo "(skipping the failure cases; pass --destructive to run them)"
  echo "================ $PASS passed, $FAIL failed ================"
  [ "$FAIL" -eq 0 ]; exit
fi

[ "$SLOT0" = A ] || { echo; echo "FATAL: destructive cases break the INACTIVE slot and expect a fallback to slot A."; echo "Commit back to slot A first. Refusing."; exit 2; }

echo
echo "--- destructive 1/2: inactive slot unbootable by the firmware ---"
bootb_rw 'mv /mnt/_ab/start4.elf /mnt/_ab/start4.selftest' >/dev/null
if [ -z "$(bootb_rw 'ls /mnt/_ab/start4.selftest' | grep start4.selftest)" ]; then
  bad "could not stage the fw-fallback case (bootB not writable?) — skipping it rather than reporting a pass"
else
  if T=$(reboot_wait tryboot); then
    S=$(slot)
    [ "$S" = A ] && ok "firmware fell back to slot A (${T}s)" || bad "expected fallback to A, got '${S:0:40}'"
  else
    bad "node did not come back — the firmware-level fallback did not happen ($T)"
  fi
  bootb_rw 'mv /mnt/_ab/start4.selftest /mnt/_ab/start4.elf' >/dev/null
fi
if [ -n "$(bootb_rw 'ls /mnt/_ab/start4.elf' | grep -w start4.elf)" ]; then
  ok "restored bootB/start4.elf"
else
  bad "bootB/start4.elf NOT restored — slot B is left unbootable by the firmware, fix it before using this card"
fi

echo
echo "--- destructive 2/2: inactive slot boots but its rootfs is unusable ---"
# The saved block lives HERE, not on the node: the node's /tmp is tmpfs and every case under
# test reboots it, so a backup left there is gone exactly when it is needed.
sshraw 'dd if=/dev/mmcblk0p4 bs=1M count=1 2>/dev/null' > "$HEADFILE"
if [ "$(stat -c%s "$HEADFILE")" != 1048576 ]; then
  bad "could not save rootB's head — refusing to damage it, so this case did not run"
else
  sshn 'dd if=/dev/zero of=/dev/mmcblk0p4 bs=1M count=1 conv=fsync 2>/dev/null; sync' >/dev/null
  if T=$(reboot_wait tryboot); then
    S=$(slot)
    [ "$S" = A ] && ok "kernel panicked and the node returned to slot A on its own (${T}s)" \
                 || bad "expected recovery to A, got '${S:0:40}'"
  else
    bad "node never came back — this is the bare-rootwait dead hang; cmdline needs rootwait=N panic=N (#133) ($T)"
  fi
  sshraw 'dd of=/dev/mmcblk0p4 bs=1M conv=fsync 2>/dev/null; sync' < "$HEADFILE"
  RB=$(sshn 'dd if=/dev/mmcblk0p4 bs=4 count=1 2>/dev/null | hexdump -C' | head -1 | awk '{print $2$3$4$5}')
  [ "$RB" = "68737173" ] && ok "restored rootB (squashfs magic back)" || bad "rootB NOT restored — head is '$RB', re-flash it"
fi

echo
echo "================ $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
