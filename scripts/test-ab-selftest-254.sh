#!/bin/bash
# scripts/test-ab-selftest-254.sh — offline test of scripts/ab-selftest.sh under a busy #254 S5 slot lock (review r2
# A-m7 / B-m7). No node: ssh is a stub that plays a healthy Pi 4 A/B card (slot A, pi4 layout, bootB as a directory,
# reboots change the boot_id, rootB's head saved / restored), and answers chosen slot-locked calls (SLOTLK: the n-th
# call carrying `slk_take || exit 1`) with SLOTLK-BUSY, as the node lib does when the lock stays held. Cases:
#   inspect-only: clean -> rc 0; B's cmdline read busy -> those checks SKIP, rc 3 + SKIP-REASON, no FAIL; busy + a real
#     FAIL (batman-slot verify refused) -> rc 1, the FAIL shown, the busy only a note
#   destructive: clean -> rc 0, bootB restored; the restore's mv busy once -> retried, restored, rc 0; the restore busy
#     for good -> FAIL "NOT restored", rc 1 (never INVALID / SKIP); the staging busy -> the fw-fallback case SKIP, rc 3,
#     bootB left as it was
# sleep is a stub (no waits). Zero cases = FAIL.
set -u
R=$(cd "$(dirname "$0")/.." && pwd)
P=0; F=0
has(){ if grep -qE -- "$3" <<< "$2"; then echo "ok   $1"; P=$((P + 1)); else echo "FAIL $1: lacks /$3/"; printf '%s\n' "$2" | sed 's/^/      /' | tail -25; F=$((F + 1)); fi; }
hasnt(){ if grep -qE -- "$3" <<< "$2"; then echo "FAIL $1: has /$3/"; printf '%s\n' "$2" | grep -E -- "$3" | sed 's/^/      /' | head -10; F=$((F + 1)); else echo "ok   $1"; P=$((P + 1)); fi; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
B=$T/bin; ST=$T/st; mkdir -p "$B" "$ST"; export ST
printf '#!/bin/sh\nexit 0\n' > "$B/sleep"
cat > "$B/ssh" <<'EOF'
#!/bin/bash
c=${*: -1}
case "$c" in *'slk_take || exit 1'*)
	n=$(( $(cat "$ST/lkn" 2>/dev/null || echo 0) + 1 )); echo $n > "$ST/lkn"
	if grep -qx "$n" "$ST/busy" 2>/dev/null || { [ -f "$ST/busyfrom" ] && [ "$n" -ge "$(cat "$ST/busyfrom")" ]; }; then
		echo "SLOTLK-BUSY held by another for 25 tries: 812:batman-slot:other"; exit 1; fi
	p=${c#*'slk_take || exit 1'}
	p=$(printf '%s' "$p" | sed -e 's#mount -t vfat[^&;]*/mnt/_ab#true#g' -e 's#umount /mnt/_ab#true#g' -e "s#/mnt/_ab#$ST/bootb#g")
	exec bash -c "$p" ;;
esac
case "$c" in
	true) exit 0 ;;
	*'/proc/cmdline'*) echo "batman_slot=A" ;;
	*'kernel/random/boot_id'*) cat "$ST/bootid" ;;
	*'(sleep 1; reboot)'*) cat /proc/sys/kernel/random/uuid > "$ST/bootid" ;;
	*'chosen/bootloader/partition'*) echo "00000000  00 00 00 01                                       |....|" ;;
	*'chosen/bootloader/tryboot'*) echo "00000000  00 00 00 00                                       |....|" ;;
	'batman-slot layout') echo pi4 ;;
	'batman-slot verify') cat "$ST/verify" ;;
	'cat /boot/autoboot.txt') printf '[all]\ntryboot_a_b=1\nboot_partition=1\n[tryboot]\nboot_partition=2\n' ;;
	'cat /boot/cmdline.txt') echo "console=tty1 root=/dev/mmcblk0p2 batman_slot=A rootwait=20 panic=10" ;;
	*'autocommit-skip-once && sync && echo ARMED'*) echo ARMED ;;
	*'autocommit-skip-once ] && echo LEFT'*) ;;
	*vcmailbox*) ;;
	*'bootloader_version | sed'*) echo 1760000000 ;;
	*'bootloader_version | head -1'*) echo "2025/10/09 12:00:00" ;;
	*'dd if=/dev/mmcblk0p4 bs=1M count=1'*) head -c 1048576 /dev/zero ;;
	*'dd if=/dev/zero of=/dev/mmcblk0p4'*) ;;
	*'dd of=/dev/mmcblk0p4'*) cat > /dev/null ;;
	*'dd if=/dev/mmcblk0p4 bs=4 count=1'*) echo "00000000  68 73 71 73                                       |hsqs|" ;;
	*) echo "STUB: unknown command [$c]" >&2; exit 99 ;;
esac
EOF
chmod +x "$B"/*
reset(){ rm -rf "${ST:?}"/*; mkdir -p "$ST/bootb"; echo "console=tty1 root=/dev/mmcblk0p4 batman_slot=B rootwait=20 panic=10" > "$ST/bootb/cmdline.txt"
	: > "$ST/bootb/start4.elf"; : > "$ST/bootb/config.txt"; cat /proc/sys/kernel/random/uuid > "$ST/bootid"; echo "batman-slot: verify ok pi4 2 FAT" > "$ST/verify"; }
ab(){ o=$(PATH="$B:$PATH" bash "$R/scripts/ab-selftest.sh" 192.0.2.9 "$@" 2>&1); rc=$?; o="$o
rc=$rc"; }
reset; ab --inspect-only
has "inspect clean -> rc 0" "$o" "^rc=0$"
has "inspect clean -> slot B read (no skip)" "$o" "ok   slot B cmdline.txt read"
hasnt "inspect clean -> no stub miss" "$o" "STUB: unknown"
reset; echo 1 > "$ST/busy"; ab --inspect-only
has "inspect, B read busy -> SKIP those checks" "$o" "SKIP slot B cmdline.txt checks .* slot lock was busy"
has "inspect, B read busy -> rc 3 + SKIP-REASON" "$o" "^SKIP-REASON: ab-selftest: 1 check"
has "inspect, B read busy -> rc 3" "$o" "^rc=3$"
hasnt "inspect, B read busy -> no FAIL line" "$o" "^  FAIL"
reset; echo 1 > "$ST/busy"; echo "batman-slot: refusing, the hybrid MBR does not match" > "$ST/verify"; ab --inspect-only
has "inspect, busy + a real FAIL -> the FAIL shown" "$o" "^  FAIL batman-slot verify refused"
has "inspect, busy + a real FAIL -> rc 1 (not INVALID / SKIP)" "$o" "^rc=1$"
has "inspect, busy + a real FAIL -> the busy is a note" "$o" "^NOTE: the slot lock was busy 1 time"
hasnt "inspect, busy + a real FAIL -> no SKIP-REASON" "$o" "^SKIP-REASON"
# destructive: slot-locked calls in order: 1 B cmdline read, 2 stage mv, 3 stage ls, 4 restore mv, 5 restore ls
reset; ab --destructive
has "destructive clean -> restored bootB" "$o" "ok   restored bootB/\{start4.elf\}"
has "destructive clean -> rc 0" "$o" "^rc=0$"
hasnt "destructive clean -> no stub miss" "$o" "STUB: unknown"
reset; echo 4 > "$ST/busy"; ab --destructive
has "restore mv busy once -> retried" "$o" "slot lock busy for a bootB restore step, try 1 of 3"
has "restore mv busy once -> restored" "$o" "ok   restored bootB/\{start4.elf\}"
has "restore mv busy once -> rc 0" "$o" "^rc=0$"
has "restore busy once -> the file really back" "$(ls "$ST/bootb")" "^start4.elf$"
reset; echo 4 > "$ST/busyfrom"; ab --destructive
has "restore busy for good -> FAIL NOT restored" "$o" "^  FAIL bootB start file\(s\) NOT restored"
has "restore busy for good -> rc 1" "$o" "^rc=1$"
hasnt "restore busy for good -> not reported as a skip" "$o" "^SKIP-REASON"
reset; echo 2 > "$ST/busy"; ab --destructive
has "staging busy -> the fw-fallback case SKIP" "$o" "SKIP fw-fallback case \(staging bootB"
has "staging busy -> rc 3" "$o" "^rc=3$"
hasnt "staging busy -> no FAIL" "$o" "^  FAIL"
has "staging busy -> bootB as it was" "$(ls "$ST/bootb" | tr '\n' ' ')" "^cmdline.txt config.txt start4.elf $"
echo "AB-SELFTEST-BUSY $P passed, $F failed"
[ "$P" -gt 0 ] && [ "$F" = 0 ]
