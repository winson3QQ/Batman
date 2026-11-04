#!/bin/bash
# scripts/dv/eh13-pre-254.sh — #254 H4 E-H13 pre-step on 04 (docs/design/254-h4-harness.md §8.1, F-H49), before the
# on-site E-H13: does `batman-slot apply` take the bad-rootfs payload (s_major 0xFFFF, magic kept), and does a
# `batman-slot stage-root` right after it (no reboot in between) disarm tryboot and invalidate B?
# A normal prov unit (pr_begin: P9, lease, dirty snapshot; pr_end wrote-b: restore cycle, B back to V, finish):
#   1. V's payload (from $PR_OUT) -> bad root.squashfs (p3-payloads.sh badroot) -> bad payload tar (SHA256SUMS line of
#      root.squashfs replaced); offline acceptance must PASS first
#   2. on 04: unpack to /opt/batdata/dv-h4e13/bad; nosq = bad without root.squashfs (SHA256SUMS keeps its line,
#      metadata size= gives the streamed size); shutdown.reason registered for removal (undo rm-file)
#   3. batman-slot apply bad      -> rc 0, "armed as one-shot tryboot", the tryboot flag reads 1
#   4. batman-slot stage-root nosq (at once, no reboot) -> stdout = B's root device, tryboot flag 0, BATMAN-BAD on B's FAT
#   5. pr_end wrote-b: restore cycle (one reboot back to A committed), B rewritten with V (OTA + trial + back to A),
#      slot-B.protected = V, no BATMAN-BAD on B
# An unplanned reboot between 3 and 4 boots the bad B -> panic -> panic=10 -> back to A: safe, the pre-step is redone.
# Changes on 04: slot B written twice (bad, then V), its trial booted once (the V rewrite), 3-4 reboots in all; p6 holds
# ~260 MB of payload during the run (removed). Git Bash.
PR_UNIT=prov-eh13pre-254
. "$(dirname "$0")/prov-254.sh"
E=/opt/batdata/dv-h4e13
VCGET='vcmailbox 0x00030064 4 4 0 2>/dev/null | awk "{print \$6}"'

pr_begin 5400 || exit 1
V=$PR_V; o=$(pr_payload "$V") || { pr_abort "payload $V: $o"; exit 1; }; pr_payload "$V" >/dev/null
# 1. the bad payload, in WSL (unsquashfs / the generator run there); not in WSL /tmp: it can be gone by the next wsl call
TW=$(wsl_ mktemp -d /home/yello/.batman-dv/e13.XXXXXX | tr -d "\r")
# plain arguments only: shell code given to wsl.exe is expanded twice (2026-11-03: the inline version lost every $)
o=$(wsl_ bash "$REPO_WSL/scripts/dv/data/p3-payloads.sh" badpayload "$PR_OUT_WSL/$V/ekh-bcm2711/batman-$V-ekh-bcm2711-ab-payload.tar.gz" "$PSHA" "$TW/bad.tar.gz" 2>&1 | tr -d "\r")
say "$(echo $o)"
grep -q "^FAIL" <<< "$o" && { wsl_ rm -rf "$TW"; pr_abort "bad payload: $(grep ^FAIL <<< "$o")"; exit 1; }
grep -q "ok   unsquashfs -s refuses it" <<< "$o" && grep -q "ok   repacked tar carries the bad rootfs" <<< "$o" || { wsl_ rm -rf "$TW"; pr_abort "bad payload not built: $o"; exit 1; }
BSHA=$(sed -n "s/^PAYLOAD-SHA //p" <<< "$o")
ok "bad payload built (offline acceptance PASS), sha ${BSHA:0:16}"

# 2. on 04
q "rm -rf $E; mkdir -m 700 $E"
cat "//wsl.localhost/Ubuntu-24.04$TW/bad.tar.gz" | timeout 600 ssh $SSHO root@$NODE "cat > $E/bad.tar.gz" || { pr_abort "upload"; exit 1; }
wsl_ rm -rf "$TW"
[ "$(qr "sha256sum < $E/bad.tar.gz | cut -c1-64")" = "$BSHA" ] || { pr_abort "bad payload sha on the node"; exit 1; }
o=$(q "set -e; cd $E; mkdir bad nosq; tar -xzf bad.tar.gz -C bad; rm bad.tar.gz; cp -a bad/boot bad/SHA256SUMS bad/metadata nosq/; grep -c ^size= nosq/metadata; ls nosq")
say "nosq: $(echo $o)"; grep -q '^1$' <<< "$o" || { pr_abort "nosq has no size= in metadata: $o"; exit 1; }
o=$(q '. /usr/lib/batman/rundir.sh; [ -e "$RUNDIR/shutdown.reason" ] && echo "PRE $(cat $RUNDIR/shutdown.reason)" || echo NONE'); say "shutdown.reason before: $o"
[ "$o" = NONE ] || { pr_abort "a shutdown.reason exists before the arm (removing it later would lose it): $o"; exit 1; }
o=$(pl undo-add rm-shutdown-reason 2>&1); say "$o"; grep -q '^UNDO-ADDED' <<< "$o" || { pr_abort "undo-add shutdown.reason: $o"; exit 1; }
[ "$(qr "$VCGET")" = 0x00000000 ] || say "NOTE tryboot flag before apply: $(qr "$VCGET")"

# 3. apply the bad payload: accepted, armed
o=$(QT=900 q "batman-slot apply $E/bad 2>&1; echo rc=\$?"); say "apply: $(tail -4 <<< "$o" | tr '\n' '|')"
grep -q '^rc=0$' <<< "$o" && grep -q 'armed as one-shot tryboot' <<< "$o" && ok "apply takes the bad-rootfs payload and arms tryboot" || { pr_abort "apply: $(echo $o)"; exit 1; }
f=$(qr "$VCGET"); [ "$((f))" = 1 ] && ok "tryboot flag reads 1 after apply" || no "tryboot flag after apply: [$f]"

# 4. stage-root at once: disarm + invalidate B
o=$(QT=600 q "batman-slot stage-root $E/nosq 2>/dev/null; echo rc=\$?"); say "stage-root: $(echo $o)"
grep -q '^rc=0$' <<< "$o" && grep -qE '^/dev/mmcblk0p4$' <<< "$o" && ok "stage-root prints B's root device only" || no "stage-root: $(echo $o)"
f=$(qr "$VCGET"); [ "$((f))" = 0 ] && ok "tryboot flag 0 after stage-root (disarmed)" || no "tryboot flag after stage-root: [$f]"
o=$(qr 'm=$(mktemp -d); mount -o ro /dev/mmcblk0p3 $m && { ls $m | grep -c "^BATMAN-BAD$"; umount $m; }; rmdir $m')
[ "$o" = 1 ] && ok "B's boot FAT carries BATMAN-BAD" || no "BATMAN-BAD on B: [$o]"
o=$(QT=200 pl undo); grep -qx 'UNDO undo_run host end rc=0' <<< "$o" && ok "undo: shutdown.reason removed" || no "undo: $(echo $o)"
q "rm -rf $E"

# 5. back to S0: restore cycle, B = V again, finish
pr_end wrote-b
o=$(qr 'm=$(mktemp -d); mount -o ro /dev/mmcblk0p3 $m && { ls $m | grep -c "^BATMAN-BAD$"; umount $m; }; rmdir $m')
[ "$o" = 0 ] && ok "B's boot FAT has no BATMAN-BAD after the rewrite" || no "BATMAN-BAD on B after the rewrite: [$o]"
pr_result
