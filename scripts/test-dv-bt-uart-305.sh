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

# ---- settings -----------------------------------------------------------------------------------------------------
o=$(lib 'PR="readinfo_powered=1 settings=powered,le,secure-conn,privacy hci_version=status0 ms=1"; settings_ok && echo good'); [ "$o" = good ] && ok "settings_ok: privacy + secure-conn, no bondable" || bad "settings good: [$o]"
o=$(lib 'PR="readinfo_powered=1 settings=powered,bondable,le,secure-conn,privacy hci_version=status0 ms=1"; settings_ok; echo rc=$?'); case "$o" in *bondable*rc=1) ok "settings_ok: bondable -> FAIL";; *) bad "settings bondable: [$o]";; esac
o=$(lib 'PR="readinfo_powered=1 settings=powered,le,secure-conn hci_version=status0 ms=1"; settings_ok; echo rc=$?'); case "$o" in *privacy*rc=1) ok "settings_ok: no privacy -> FAIL";; *) bad "settings privacy: [$o]";; esac

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

echo "test-dv-bt-uart-305: $n checks, fails=$fails"
[ "$fails" = 0 ]
