#!/bin/sh
# halow-fi-263.sh — #263 fault-injection run of the mm6108 command path on a Pi bench node (DESTRUCTIVE).
#
# Swaps the HaLow driver for /tmp/mm6108_sdio-dvfi.ko — a DEBUG build of the shipped driver plus the
# fault-injection knobs (firmware: debug/990-DEBUG-fi-263.patch, built by scripts/build-debug-mm6108-fi.sh for
# EXACTLY the build this node runs) — and drives `morse_cli stats` (MAC_STATS_LOG, 0x200C) through the race
# that panicked the fleet: the command is held 800 ms after its page write (its 600 ms wait times out while
# the TX path owns the skb), then 700 ms after tx_complete (the sent skb and the retry sit on two queues).
#   patched driver: every case completes, no WARN/Oops, 20/20 normal commands afterwards
#   stock driver + the same knobs: Oops on the first command (write to 0x8 in __morse_skbq_unlink) — the
#                 negative control, panics the node (panic_on_oops -> reboot)
#
# The node leaves the mesh while the driver is swapped, so this runs UNATTENDED and ALWAYS ends with a
# reboot, which brings back the shipped driver (the debug module is only insmod'ed, never installed).
#   setsid sh /tmp/halow-fi-263.sh </dev/null >/dev/null 2>&1 &
# Result: /opt/batdata/halow-fi-263-<stamp>.log (+ -dmesg.txt). The harness judges it after the reboot.
KO=/tmp/mm6108_sdio-dvfi.ko; TS=$(date +%Y%m%d%H%M%S)
L=/opt/batdata/halow-fi-263-$TS.log; D=/opt/batdata/halow-fi-263-$TS-dmesg.txt
P=/sys/module/mm6108_sdio/parameters
log(){ echo "[$(cut -d. -f1 /proc/uptime)] $*" >> "$L"; sync; }
snap(){ dmesg -c > /tmp/hfi.dm; cat /tmp/hfi.dm >> "$D"
	grep -E "FI263 inject|QLEN|WARNING|Late response|timed out|Oops|Unable to handle|not on this queue" /tmp/hfi.dm | tail -40 >> "$L"; sync; }
stats(){ t0=$(cut -d" " -f1 /proc/uptime); morse_cli -i wlh0 stats > /tmp/hfi-stats.out 2>&1; rc=$?
	log "$1: morse_cli stats rc=$rc ($(awk -v a="$t0" '{printf "%.1f", $1-a}' /proc/uptime)s)"; }
trap 'log "aborted -> reboot"; reboot' INT TERM
[ -f "$KO" ] || { echo "no $KO" > "$L"; exit 1; }
log "START boot=$(cat /proc/sys/kernel/random/boot_id) ko-md5=$(md5sum < "$KO" | cut -c1-12) kernel=$(uname -r) panic_on_oops=$(cat /proc/sys/kernel/panic_on_oops)"
# no p5 writes and no other morse_cli traffic during the run (the field Oopses coincided with p5 mounts)
/etc/init.d/joinwatch stop 2>/dev/null; /etc/init.d/meshled stop 2>/dev/null
PARAMS=$(sed -n 's/^mm6108_sdio //p' /etc/modules.d/mm6108)
dmesg -c > "$D"
rmmod mm6108_sdio || { log "rmmod failed -> reboot"; reboot; exit 1; }
insmod "$KO" $PARAMS enable_watchdog=0 || { log "insmod failed -> reboot"; reboot; exit 1; }
[ -f $P/fi263_put_delay_ms ] || { log "loaded module has no fi263 knobs -> reboot"; reboot; exit 1; }
log "debug module loaded (patched=$([ -f $P/cmd_timeout_in_flight ] && echo yes || echo no))"
wifi up >/dev/null 2>&1; sleep 5; wifi >/dev/null 2>&1
for _ in $(seq 1 60); do [ "$(batctl n 2>/dev/null | grep -c wlh0)" -gt 0 ] && break; sleep 3; done
log "mesh neighbours: $(batctl n 2>/dev/null | grep -c wlh0)"
snap
stats baseline; snap
echo 8204 > $P/fi263_msg_id                      # 0x200C MAC_STATS_LOG = morse_cli stats
# case 1: timeout while the TX path holds the command, then sent skb on pending + retry on skbq
echo 800 > $P/fi263_put_delay_ms; echo 700 > $P/fi263_post_complete_delay_ms
stats case1; sleep 3; snap
stats after-case1; sleep 2; snap
# case 2: written to the chip, then dropped by the host -> the chip still answers
echo 1 > $P/fi263_drop_after_write; stats case2; sleep 3; snap
# case 3: a 300 ms stall must not turn the live command's response into a late one
echo 300 > $P/fi263_put_delay_ms; stats case3; sleep 2; snap
# case 4: case 1 five more times
for k in 1 2 3 4 5; do echo 800 > $P/fi263_put_delay_ms; echo 700 > $P/fi263_post_complete_delay_ms; stats "case4-$k"; sleep 2; done; snap
ok=0; for k in $(seq 1 20); do morse_cli -i wlh0 stats >/dev/null 2>&1 && ok=$((ok+1)); done
log "normal stats after injection: $ok/20 ok"
log "cmd_timeout_in_flight=$(cat $P/cmd_timeout_in_flight 2>/dev/null || echo n/a)"
log "mesh neighbours at end: $(batctl n 2>/dev/null | grep -c wlh0)"
snap
log "END -> reboot"; sync
reboot
