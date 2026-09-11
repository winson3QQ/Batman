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
# With --destructive it also induces the two failure classes that #133 found, each of which
# must recover on its own, and restores what it broke (4 reboots total, ~6 min):
#
#   fw-fallback    the inactive slot cannot be booted BY THE FIRMWARE  -> falls back
#   kernel-panic   the inactive slot boots but its rootfs is unusable  -> panics and returns
#
# The second one is the reason `rootwait=20 panic=10` exists: with a bare `rootwait` the node
# hangs forever instead, silently, because procd never starts and the watchdog is never armed.
set -uo pipefail

NODE=${1:?usage: ab-selftest.sh <node-addr> [--destructive]}
MODE=${2:-}
case "$MODE" in ""|--inspect-only|--destructive) ;; *) echo "unknown mode: $MODE"; exit 2 ;; esac
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $*"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $*"; }

sshn() { timeout 30 ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 \
                       -o BatchMode=yes -o LogLevel=ERROR "root@$NODE" "$@" 2>&1; }
# Binary-safe variant: sshn folds stderr into stdout, which corrupts a disk image in transit.
sshraw() { timeout 120 ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 \
                       -o BatchMode=yes -o LogLevel=ERROR "root@$NODE" "$@"; }
# The saved block lives HERE, not on the node: the node's /tmp is tmpfs and every case
# under test reboots it, so a backup left there is gone exactly when it is needed.
HEADFILE=$(mktemp); trap 'rm -f "$HEADFILE"' EXIT
be32() { sshn "hexdump -C /proc/device-tree/chosen/bootloader/$1" | head -1 | awk '{print $5}' | sed 's/^0*//;s/^$/0/'; }
slot() { sshn 'tr " " "\n" < /proc/cmdline | grep -o "batman_slot=."' | tr -d '\r' | cut -d= -f2; }

reboot_wait() {                       # $1 = tryboot|plain ; $2 = max seconds
  local mode=$1 max=${2:-180} i
  [ "$mode" = tryboot ] && sshn 'vcmailbox 0x00038064 4 4 1 >/dev/null'
  sshn '(sleep 1; reboot) >/dev/null 2>&1 &' >/dev/null
  sleep 12
  for ((i=12; i<max; i+=5)); do
    if timeout 2 ping -c1 -W1 "$NODE" >/dev/null 2>&1; then
      ssh-keygen -f ~/.ssh/known_hosts -R "$NODE" >/dev/null 2>&1; sleep 4; echo "$i"; return 0
    fi
    sleep 5
  done
  echo "TIMEOUT"; return 1
}

mountb() { sshn "mkdir -p /mnt/_ab; mount -t vfat /dev/mmcblk0p$1 /mnt/_ab" >/dev/null; }
umountb() { sshn 'sync; umount /mnt/_ab' >/dev/null; }

echo "=== A/B self-test against $NODE ==="
SLOT0=$(slot)
[ -n "$SLOT0" ] || { echo "FATAL: $NODE reports no batman_slot — this is not an A/B card built by build-gpt-ab-card.sh. Refusing."; exit 2; }
PART0=$(be32 partition)
echo "running slot=$SLOT0 firmware partition=$PART0"

echo
echo "--- static invariants ---"
AB=$(sshn 'cat /boot/autoboot.txt')
grep -q '^tryboot_a_b=1' <<<"$AB" && ok "tryboot_a_b=1 present" || bad "tryboot_a_b=1 missing — A/B switching is inert"
grep -q '^\[tryboot\]' <<<"$AB" && ok "[tryboot] section present" || bad "[tryboot] section missing"
AB_ALL=$(awk '/^\[all\]/{s=1;next}/^\[/{s=0}s&&/^boot_partition=/{sub(/.*=/,"");print;exit}' <<<"$AB")
AB_TRY=$(awk '/^\[tryboot\]/{s=1;next}/^\[/{s=0}s&&/^boot_partition=/{sub(/.*=/,"");print;exit}' <<<"$AB")
[ "$AB_ALL" = "$PART0" ] \
  && ok "autoboot.txt [all]=$AB_ALL agrees with the slot actually booted ($PART0)" \
  || bad "autoboot.txt [all]=$AB_ALL but the firmware booted partition $PART0 — a fallback happened and autoboot.txt was never repaired (#133)"
[ "$AB_TRY" = 3 ] \
  && bad "[tryboot] boot_partition=3 is the GPT index; the firmware counts only bootable FAT partitions, so bootB is 2 (#133)" \
  || ok "[tryboot] boot_partition=$AB_TRY is not the GPT index"

for p in 1 3; do
  S=$([ "$p" = 1 ] && echo A || echo B)
  if [ "$p" = 1 ]; then CL=$(sshn 'cat /boot/cmdline.txt'); else mountb 3; CL=$(sshn 'cat /mnt/_ab/cmdline.txt'); umountb; fi
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
T=$(reboot_wait tryboot) && {
  S=$(slot); P=$(be32 partition); TB=$(be32 tryboot)
  [ "$S" != "$SLOT0" ] && ok "tryboot switched $SLOT0 -> $S (partition=$P, tryboot=$TB, ${T}s)" \
                       || bad "tryboot did not switch: still slot $S, partition=$P (silent no-op — check boot_partition numbering, #133)"
} || bad "node did not return after tryboot"

T=$(reboot_wait plain) && {
  S=$(slot)
  [ "$S" = "$SLOT0" ] && ok "plain reboot returned to the committed slot $S (${T}s)" \
                      || bad "trial boot stuck: expected $SLOT0, got $S"
} || bad "node did not return after a plain reboot"

if [ "$MODE" != --destructive ]; then
  echo
  echo "(skipping the failure cases; pass --destructive to run them)"
  echo "================ $PASS passed, $FAIL failed ================"
  [ "$FAIL" -eq 0 ]; exit
fi

[ "$SLOT0" = A ] || { echo; echo "FATAL: destructive cases break the INACTIVE slot and expect a fallback to slot A."; echo "Commit back to slot A first. Refusing."; exit 2; }

echo
echo "--- destructive 1/2: inactive slot unbootable by the firmware ---"
mountb 3; sshn 'mv /mnt/_ab/start4.elf /mnt/_ab/start4.selftest' >/dev/null; umountb
T=$(reboot_wait tryboot) && {
  S=$(slot)
  [ "$S" = A ] && ok "firmware fell back to slot A (${T}s)" || bad "expected fallback to A, got $S"
} || bad "node did not return — the firmware-level fallback did not happen"
mountb 3; sshn 'mv /mnt/_ab/start4.selftest /mnt/_ab/start4.elf' >/dev/null; umountb
ok "restored bootB/start4.elf"

echo
echo "--- destructive 2/2: inactive slot boots but its rootfs is unusable ---"
sshraw 'dd if=/dev/mmcblk0p4 bs=1M count=1 2>/dev/null' > "$HEADFILE"
[ "$(stat -c%s "$HEADFILE")" = 1048576 ] || { echo "FATAL: could not save rootB's head; refusing to damage it"; exit 2; }
sshn 'dd if=/dev/zero of=/dev/mmcblk0p4 bs=1M count=1 conv=fsync 2>/dev/null; sync' >/dev/null
T=$(reboot_wait tryboot) && {
  S=$(slot)
  [ "$S" = A ] && ok "kernel panicked and the node returned to slot A on its own (${T}s)" \
               || bad "expected recovery to A, got $S"
} || bad "node never came back — this is the bare-rootwait dead hang; cmdline needs rootwait=N panic=N (#133)"
sshraw 'dd of=/dev/mmcblk0p4 bs=1M conv=fsync 2>/dev/null; sync' < "$HEADFILE"
RB=$(sshn 'dd if=/dev/mmcblk0p4 bs=4 count=1 2>/dev/null | hexdump -C' | head -1 | awk '{print $2$3$4$5}')
[ "$RB" = "68737173" ] && ok "restored rootB (squashfs magic back)" || bad "rootB NOT restored — head is $RB, re-flash it"

echo
echo "================ $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
