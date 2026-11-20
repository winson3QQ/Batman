#!/bin/bash
# scripts/test-dv-bt-uart-305.sh — offline self-test of the #305 judges (no node, no hardware). Sources
# scripts/node/bt-uart-305.sh with BT305_LIB_ONLY=1 against fixtures, and the host verdict of scripts/dv/bt-uart-305.sh.
# Every judge gets a good case AND a bad case (a judge that cannot fail proves nothing). Last line: "... fails=N".
set -u
REPO=${REPO:-$(cd "$(dirname "$0")/.." && pwd)}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0; n=0
ok() { n=$((n + 1)); echo "ok   $*"; }
bad() { n=$((n + 1)); fails=$((fails + 1)); echo "FAIL $*"; }
cp "$REPO/scripts/node/ble-lib-254.sh" "$REPO/scripts/node/bt-uart-305.sh" "$T/"

# run a snippet inside the node library (busybox-ash compatible code, run here with sh)
lib() { (cd "$T" && cat > drive.sh <<EOF
BT305_LIB_ONLY=1
BT305_AF=$T/af BT305_SER=$T/ser BT305_DTC=$T/dtc BT305_BBUILD=$T/bb BT305_KMSG=$T/kmsg BT305_KDEV=$T/kdev RUN_ID=run1
export BT305_AF BT305_SER BT305_DTC BT305_BBUILD BT305_KMSG BT305_KDEV
. ./bt-uart-305.sh
$1
EOF
sh drive.sh 2>&1); }

# ---- gate ---------------------------------------------------------------------------------------------------------
printf 'raspberrypi,4-model-b\0brcm,bcm2711\0' > "$T/dtc"
echo 'BATMAN_FEATURES=a,b,mini-uart-autoflow(#305)' > "$T/bb"; echo 'hw=0xcf cache=0xcf writes=4 last=0xcf,0x03,0x8b,0xcf' > "$T/af"
o=$(lib 'gate; echo rc=$?'); [ "$(echo "$o" | tail -1)" = rc=0 ] && ok "gate: rc image with autoflow -> go" || bad "gate rc image: $o"
echo 'BATMAN_FEATURES=a,b' > "$T/bb"
o=$(lib 'gate; echo rc=$?'); case "$o" in *"FAIL pre-305 image: test not applicable to this kernel"*rc=1) ok "gate: pre-305 image -> the one KNOWN line";; *) bad "gate pre-305: $o";; esac
grep -qxE '^FAIL pre-305 image: test not applicable to this kernel$' <<< "$(echo "$o" | head -1)" && ok "gate line matches the known-failures ERE" || bad "gate line does not match the known-failures ERE"
o=$(BT305_FORCE=1 lib 'gate; echo rc=$?'); case "$o" in *"NOTE --force"*rc=0) ok "gate: --force bypasses the short-circuit";; *) bad "gate force: $o";; esac
echo 'BATMAN_FEATURES=mini-uart-autoflow(#305)' > "$T/bb"; rm -f "$T/af"
o=$(lib 'gate; echo rc=$?'); case "$o" in *"FAIL autoflow missing on a 305 image"*rc=1) ok "gate: marker without autoflow -> NEW line";; *) bad "gate marker/no-autoflow: $o";; esac
echo 'BATMAN_FEATURES=x,mini-uart-autoflow(#305)x' > "$T/bb"
o=$(lib 'gate; echo rc=$?'); case "$o" in *"FAIL pre-305 image"*) ok "gate: a marker lookalike is not the marker";; *) bad "gate lookalike: $o";; esac
printf 'raspberrypi,3-model-a-plus\0brcm,bcm2837\0' > "$T/dtc"
o=$(lib 'gate; echo rc=$?'); case "$o" in *"NA not a bcm2711 board"*rc=2) ok "gate: bcm2710 -> NA";; *) bad "gate bcm2710: $o";; esac
printf 'raspberrypi,4-model-b\0brcm,bcm2711\0' > "$T/dtc"

# ---- /proc/tty/driver/serial --------------------------------------------------------------------------------------
cat > "$T/ser" <<'EOF'
serinfo:1.0 driver revision:
0: uart:16550 mmio:0xFE215040 irq:33 tx:623255 rx:34279022 fe:2 oe:40 RTS|CTS|DTR
EOF
o=$(lib 'ser_get && echo "oe=$S_OE fe=$S_FE pe=$S_PE bo=$S_BO rx=$S_RX"'); [ "$o" = "oe=40 fe=2 pe=0 bo=0 rx=34279022" ] && ok "ser_get: present fields + absent = 0" || bad "ser_get: [$o]"
echo 'serinfo:1.0 driver revision:' > "$T/ser"
o=$(lib 'ser_get; echo rc=$?'); [ "$o" = rc=1 ] && ok "ser_get: missing mini UART line -> rc 1 (FAIL, never 0)" || bad "ser_get missing line: [$o]"
echo '0: uart:PL011 rev3 mmio:0xFE201000 irq:32 tx:1 rx:2 oe:9' > "$T/ser"
o=$(lib 'ser_get; echo rc=$?'); [ "$o" = rc=1 ] && ok "ser_get: a PL011 line is not the mini UART" || bad "ser_get PL011: [$o]"

# ---- sysfs witness + sequences ------------------------------------------------------------------------------------
echo 'hw=0x03 cache=0xcf writes=19 last=0x03,0x8b,0xcf,0x03,0xcf,0x03,0x8b,0xcf' > "$T/af"
o=$(lib 'af_get && echo "$AF_HW $AF_CACHE $AF_W $(tail_k "$AF_LAST" 4)"'); [ "$o" = "0x03 0xcf 19 0xcf,0x03,0x8b,0xcf" ] && ok "af_get + tail_k" || bad "af_get: [$o]"
o=$(lib 'tail_k "0x8b,0xcf,0x03,0x8b,0x03" 2'); [ "$o" = "0x8b,0x03" ] && ok "tail_k: no-P2 unbind pair" || bad "tail_k: [$o]"
echo 'garbage' > "$T/af"
o=$(lib 'af_get; echo rc=$?'); [ "$o" = rc=1 ] && ok "af_get: malformed -> rc 1" || bad "af_get malformed: [$o]"

# ---- kmsg counting between markers --------------------------------------------------------------------------------
cat > "$T/kmsg" <<'EOF'
6,100,1,-;Bluetooth: hci0: Frame reassembly failed (-84)
12,101,2,-;bt305: start run1 load
3,102,3,-;Bluetooth: hci0: command 0x200c tx timeout
3,103,4,-;Bluetooth: hci0: Frame reassembly failed (-84)
12,104,5,-;bt305: mark run1 r1
3,105,6,-;Bluetooth: hci0: BCM: Reset failed (-110)
12,106,7,-;bt305: mark run1 e1
3,107,8,-;Bluetooth: hci0: command 0x0c03 tx timeout
12,108,9,-;bt305: end run1
3,109,9,-;Bluetooth: hci0: command 0x0c03 tx timeout
EOF
o=$(lib 'echo "$(km_count "hci0: .*tx timeout") $(km_count "hci0: Frame reassembly") $(km_count "hci0: .*(tx timeout|failed)" r1 e1)"'); [ "$o" = "2 1 1" ] && ok "km_count: only between start/end; per-iteration window" || bad "km_count: [$o] (want 2 1 1)"

# ---- kmsg_start / kmsg_stop for real (a FIFO stands in for /dev/kmsg; a holder keeps it open read-write) ---------
# The judge must PASS when the reader lives to the end: pg_kill (ble-lib-254.sh) sets the global $alive, which once
# made kmsg_stop report "capture incomplete" on every healthy run (found on the nodes, 2026-10-25).
kfifo() { rm -f "$T/kdev"; mkfifo "$T/kdev"; (exec sleep 30 <> "$T/kdev") & KH=$!; }	# O_RDWR: writes never block (like /dev/kmsg)
kfifo
o=$(lib 'kmsg_start t; kmsg_mark a; kmsg_stop; echo "KM_OK=$KM_OK"; [ -e "$DIR/kmsg.pg" ] && echo pg-left'); kill $KH 2>/dev/null
case "$o" in *KM_OK=1*pg-left*) bad "kmsg_stop: left kmsg.pg behind";; *KM_OK=1*) ok "kmsg_stop: live reader + both markers -> KM_OK=1";; *) bad "kmsg_stop healthy: [$o]";; esac
grep -q 'bt305: end run1' "$T/kmsg" && ok "kmsg capture holds the end marker" || bad "kmsg capture lacks the end marker"
kfifo
o=$(lib 'kmsg_start t; pg_kill "$(cat "$DIR/kmsg.pg")"; kmsg_stop; echo "KM_OK=$KM_OK"'); kill $KH 2>/dev/null
case "$o" in *KM_OK=0*) ok "kmsg_stop: reader dead before the end -> KM_OK=0";; *) bad "kmsg_stop dead reader: [$o]";; esac
kfifo
o=$(lib 'kmsg_start t; echo "cat: read error: Broken pipe" >> "$KMSG"; kmsg_stop; echo "KM_OK=$KM_OK"'); kill $KH 2>/dev/null
case "$o" in *KM_OK=0*) ok "kmsg_stop: EPIPE in the capture -> KM_OK=0";; *) bad "kmsg_stop EPIPE: [$o]";; esac
kfifo
o=$(lib 'echo "12,610,24133960,-;tr: write error: Broken pipe" > "$KDEV"; kmsg_start t; kmsg_stop; echo "KM_OK=$KM_OK"'); kill $KH 2>/dev/null
case "$o" in *KM_OK=1*) ok "kmsg_stop: an old kmsg RECORD saying 'Broken pipe' is not an overrun";; *) bad "kmsg_stop record with Broken pipe: [$o]";; esac

# ---- settings -----------------------------------------------------------------------------------------------------
o=$(lib 'PR="readinfo_powered=1 settings=powered,le,secure-conn,privacy hci_version=status0 ms=1"; settings_ok && echo good'); [ "$o" = good ] && ok "settings_ok: privacy + secure-conn, no bondable" || bad "settings good: [$o]"
o=$(lib 'PR="readinfo_powered=1 settings=powered,bondable,le,secure-conn,privacy hci_version=status0 ms=1"; settings_ok; echo rc=$?'); case "$o" in *bondable*rc=1) ok "settings_ok: bondable -> FAIL";; *) bad "settings bondable: [$o]";; esac
o=$(lib 'PR="readinfo_powered=1 settings=powered,le,secure-conn hci_version=status0 ms=1"; settings_ok; echo rc=$?'); case "$o" in *privacy*rc=1) ok "settings_ok: no privacy -> FAIL";; *) bad "settings privacy: [$o]";; esac

o=$(lib 'PR="readinfo_powered=1 settings=powered,le,secure-conn,privacy hci_version=status0 ms=1"; mgmt_up && echo up'); [ "$o" = up ] && ok "mgmt_up: powered mgmt state -> up" || bad "mgmt_up good: [$o]"
o=$(lib 'PR="readinfo_powered=err(noreply) settings=unknown hci_version=status0 ms=4"; mgmt_up; echo rc=$?'); [ "$o" = rc=1 ] && ok "mgmt_up: HCI answers but mgmt not yet -> not up" || bad "mgmt_up noreply: [$o]"

# ---- host flip verdict --------------------------------------------------------------------------------------------
. "$REPO/scripts/dv/bt-uart-305.sh"
mode=flip node=test
v() { rc=0; bt305_verdict "$@" >/dev/null; echo $rc; }
[ "$(v T2 $'FAIL det-oe +7\nFAIL det-txto +7' '^FAIL (load-|kmsg capture)' '^FAIL det-oe' '^FAIL det-txto')" = 0 ] && ok "verdict T2: oe + txto -> VALID" || bad "verdict T2 valid"
[ "$(v T2 $'FAIL det-oe +7' '^FAIL (load-|kmsg capture)' '^FAIL det-oe' '^FAIL det-txto')" = 1 ] && ok "verdict T2: oe only -> INVALID (each channel must fire)" || bad "verdict T2 oe-only"
[ "$(v T2 $'FAIL det-oe +7\nFAIL det-txto +7\nFAIL load-rx 900 B/s < 10000' '^FAIL (load-|kmsg capture)' '^FAIL det-oe' '^FAIL det-txto')" = 1 ] && ok "verdict T2: with a load FAIL -> INVALID" || bad "verdict T2 load"
[ "$(v T3 $'FAIL seq-bind 1: [x]' '' '^FAIL seq-unbind')" = 1 ] && ok "verdict T3: no seq-unbind -> INVALID" || bad "verdict T3"
[ "$(v T3b $'FLIP close waited 30140 ms without P2' 'flip-invalid' '^FLIP close waited')" = 0 ] && ok "verdict T3b: waited -> VALID" || bad "verdict T3b valid"
[ "$(v T3b $'FAIL flip-invalid: without P2 the close took only 120 ms' 'flip-invalid' '^FLIP close waited')" = 1 ] && ok "verdict T3b: flip-invalid -> INVALID" || bad "verdict T3b invalid"

# ---- #329 advertising interval after a rebind: adv_sys_check (docs/design/329-adv-interval.md §8 T1b, §11) -----------
# sysconfig-04-wsl32.txt is a real readout (04, wsl.32: 0008 / 0008); the a000 / f000 one is that readout edited by hand
AS=$REPO/tests/fixtures/advint-329/sysconfig-04-wsl32.txt; ASV='1.5.14-wsl.32+4c0078c.fw45def04.bench'
printf '[General]\n#MinAdvertisementInterval = 0x00A0\n' > "$T/nokey.conf"; printf '[LE]\nMinAdvertisementInterval = 0x00A0\n' > "$T/key.conf"
echo "BATMAN_VERSION=$ASV" > "$T/abb"; mkdir -p "$T/as"
sed 's/\(Type: 0x000a.*Value: \)0008/\1a000/; s/\(Type: 0x000b.*Value: \)0008/\1f000/' "$AS" > "$T/as/good"
cp "$AS" "$T/as/old"; sed -n '1,/Type: 0x000a/p' "$AS" > "$T/as/cut"; : > "$T/as/empty"
echo "FAIL timeout after 4s: sh -c : | bluetoothctl mgmt.read-sysconfig" > "$T/as/timeout"
{ sed -n '1,/Type: 0x000b/p' "$T/as/good"; echo "Segmentation fault"; } > "$T/as/died"
sed 's/\(Type: 0x000a.*Value: \)0008/\1a000/' "$AS" > "$T/as/minonly"; sed 's/\(Type: 0x000b.*Value: \)0008/\1f000/' "$AS" > "$T/as/maxonly"
# as_case <name> <main.conf> <readout of try 1..5, by name> <want: the lines printed>
as_case() { local name=$1 conf=$2 want=$4 i=0 r o; rm -f "$T"/as/try.*
	for r in $3; do i=$((i + 1)); cp "$T/as/$r" "$T/as/try.$i"; done
	o=$(ADV_INT_BUILD="$T/abb" lib 'pidof() { return 0; }; sleep() { :; }; adv_sys_read() { cat "'"$T"'/as/try.$AS_TRIES" 2>/dev/null; }
		adv_sys_check "'"$conf"'" && pass "rebind 3: $AS_MSG" || no "rebind 3: $AS_MSG"; echo "DET rebind 3: adv sysconfig tries=$AS_TRIES unreadable=$AS_UNR"')
	[ "$o" = "$want" ] && ok "adv sysconfig: $name" || bad "adv sysconfig: $name: [$o]"; }
AS_OLD="FAIL rebind 3: adv sysconfig 0008 / 0008 (want a000 / f000): image without the interval [$ASV]"
as_case "real wsl.32 readout, no key -> the fixed old-image line" "$T/nokey.conf" "old" "$AS_OLD"$'\n'"DET rebind 3: adv sysconfig tries=1 unreadable=0"
as_case "a000 / f000 with the key -> PASS on the first try (edited)" "$T/key.conf" "good" "PASS rebind 3: adv sysconfig a000 / f000"$'\n'"DET rebind 3: adv sysconfig tries=1 unreadable=0"
as_case "key: 0008 twice, then a000 / f000 -> PASS, tries=3" "$T/key.conf" "old old good" "PASS rebind 3: adv sysconfig a000 / f000"$'\n'"DET rebind 3: adv sysconfig tries=3 unreadable=0"
as_case "key: a timed-out read, then good -> PASS, unreadable=1, the timeout line is not printed" "$T/key.conf" "timeout good" "PASS rebind 3: adv sysconfig a000 / f000"$'\n'"DET rebind 3: adv sysconfig tries=2 unreadable=1"
as_case "key: bluetoothctl died after both lines -> still a complete readout" "$T/key.conf" "died" "PASS rebind 3: adv sysconfig a000 / f000"$'\n'"DET rebind 3: adv sysconfig tries=1 unreadable=0"
as_case "key: cut short every time -> unreadable" "$T/key.conf" "cut cut cut cut cut" "FAIL rebind 3: adv sysconfig unreadable"$'\n'"DET rebind 3: adv sysconfig tries=5 unreadable=5"
as_case "no key: nothing readable in 5 tries -> unreadable" "$T/nokey.conf" "empty cut timeout empty" "FAIL rebind 3: adv sysconfig unreadable"$'\n'"DET rebind 3: adv sysconfig tries=5 unreadable=5"
as_case "no key: an empty read, then 0008 -> the fixed old-image line, tries=2" "$T/nokey.conf" "empty old" "$AS_OLD"$'\n'"DET rebind 3: adv sysconfig tries=2 unreadable=1"
as_case "no key but a000 / f000 -> its own FAIL line" "$T/nokey.conf" "good" "FAIL rebind 3: adv sysconfig a000 / f000 but main.conf has no key"$'\n'"DET rebind 3: adv sysconfig tries=1 unreadable=0"
as_case "key: only the minimum right, five times -> FAIL" "$T/key.conf" "minonly minonly minonly minonly minonly" "FAIL rebind 3: adv sysconfig a000 / 0008 after 5 tries (want a000 / f000)"$'\n'"DET rebind 3: adv sysconfig tries=5 unreadable=0"
as_case "key: only the maximum right, five times -> FAIL" "$T/key.conf" "maxonly maxonly maxonly maxonly maxonly" "FAIL rebind 3: adv sysconfig 0008 / f000 after 5 tries (want a000 / f000)"$'\n'"DET rebind 3: adv sysconfig tries=5 unreadable=0"
as_case "no key, only the minimum at 0008 -> not the old-image line" "$T/nokey.conf" "maxonly" "FAIL rebind 3: adv sysconfig 0008 / f000 but main.conf has no key"$'\n'"DET rebind 3: adv sysconfig tries=1 unreadable=0"
as_case "no key, only the maximum at 0008 -> not the old-image line" "$T/nokey.conf" "minonly" "FAIL rebind 3: adv sysconfig a000 / 0008 but main.conf has no key"$'\n'"DET rebind 3: adv sysconfig tries=1 unreadable=0"
as_case "key: 0008 five times -> FAIL after 5 tries" "$T/key.conf" "old old old old old" "FAIL rebind 3: adv sysconfig 0008 / 0008 after 5 tries (want a000 / f000)"$'\n'"DET rebind 3: adv sysconfig tries=5 unreadable=0"
as_case "key: unreadable, then 0008 to the end -> the value seen, not 'unreadable'" "$T/key.conf" "empty old old cut old" "FAIL rebind 3: adv sysconfig 0008 / 0008 after 5 tries (want a000 / f000)"$'\n'"DET rebind 3: adv sysconfig tries=5 unreadable=2"
o=$(lib 'pidof() { return 1; }; adv_sys_read() { echo CALLED; }; adv_sys_check "'"$T/key.conf"'" || no "rebind 3: $AS_MSG"; echo "tries=$AS_TRIES"')
[ "$o" = "FAIL rebind 3: adv sysconfig: bluetoothd not running"$'\n'"tries=0" ] && ok "adv sysconfig: no bluetoothd -> FAIL without calling bluetoothctl" || bad "adv sysconfig no bluetoothd: [$o]"
# the wiring: cmd_rebind judges it for a rebind that came up, and not in a --flip run
grep -A2 'if \[ "\$RB_UP" = 1 \] && \[ \$flip = 0 \]; then' "$REPO/scripts/node/bt-uart-305.sh" | grep -q 'adv_sys_check && pass "rebind \$i: \$AS_MSG" || no "rebind \$i: \$AS_MSG"' && ok "adv sysconfig: cmd_rebind calls the judge (RB_UP = 1, not --flip)" || bad "adv sysconfig: cmd_rebind does not call adv_sys_check"
# known-failures (#329): only the fixed old-image line is KNOWN
. "$REPO/scripts/dv/known-failures.sh"; KFL=$REPO/scripts/validation-known-failures.txt
kfc() { printf '%s\n' "$1" > "$T/kf.log"; KF_NO_GH=1 kf_classify bt-uart-rebind-305 "$T/kf.log" "$KFL" "${2:-2026-12-20}"; }
c=$(kfc "$(for i in 1 2 10; do echo "${AS_OLD/rebind 3/rebind $i}"; done)"); case "$c" in "known #329"*) ok "known-failures: the old-image line of every rebind -> known #329" ;; *) bad "known-failures rebind: [$c]" ;; esac
c=$(kfc "$AS_OLD" 2026-12-21); case "$c" in "new (the entry for #329 2026-12-20 has expired"*) ok "known-failures: the day after the expiry -> NEW" ;; *) bad "known-failures expiry: [$c]" ;; esac
for l in "adv sysconfig unreadable" "adv sysconfig 0008 / 0008 after 5 tries (want a000 / f000)" "adv sysconfig a000 / f000 but main.conf has no key" "adv sysconfig: bluetoothd not running"; do
	c=$(kfc "FAIL rebind 3: $l"); case "$c" in new*) ok "known-failures: [$l] -> NEW" ;; *) bad "known-failures should be NEW: [$l] -> [$c]" ;; esac; done
c=$(kfc "$AS_OLD"$'\n'"FAIL rebind 4: adv sysconfig unreadable"); case "$c" in "new (never-known"*) ok "known-failures: one unreadable rebind among old-image lines -> NEW" ;; *) bad "known-failures mixed: [$c]" ;; esac

echo "test-dv-bt-uart-305: $n checks, fails=$fails"
[ "$fails" = 0 ]
