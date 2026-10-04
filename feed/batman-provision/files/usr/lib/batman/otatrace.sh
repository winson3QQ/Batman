# shellcheck shell=ash
# otatrace.sh — the OTA flight recorder's only writer (#209 S5; docs/design/ota-trace.md).
# Sourced (functions only, no top-level side effects) by /lib/upgrade/platform.sh — in sysupgrade
# stage 1, in validate_firmware_image AND in the stage-2 ramfs (RAMFS_COPY_DATA) — and by
# batman-slot, batman-autocommit and batdata-mount.
#
# One line per event in $OTATRACE_FILE (default /opt/batdata/log/ota-trace.log, only while p6 is
# really mounted):   <YYYYmmdd-HHMMSS> boot=<boot_id8> up=<uptime s> <STAGE> <EVENT> k=v ...
# Every line carries boot_id + uptime, so ordering never depends on the (RTC-less) wall clock.
#
# An instrument must NEVER change a decision. Callers follow four rules:
#   1. save $? BEFORE calling otalog (never between a command and the test of its status);
#   2. never as the LAST line of a function whose return status is used;
#   3. never inside a function whose stdout is captured with $(...);
#   4. never inside the Pi 3 p7 single-sector write window (between power_ok and the read-back).
# The functions themselves run in a subshell with all I/O redirected and `|| :`, so a failure,
# an unset variable under `set -u`, stray output or a missing tool cannot leak into the caller.
#
# otalog_k additionally writes the line to /dev/kmsg (ramoops carries it across a reboot on the
# boards whose ramoops survives — not manet02, #173). printk_devkmsg=ratelimit drops bursts, so
# only SUMMARY lines use otalog_k (a handful per OTA); the detail goes to the file only.

otalog()   { ( _ota_line "$@" ) </dev/null >/dev/null 2>&1 || :; }
otalog_k() { ( OTATRACE_KMSG=1 _ota_line "$@" ) </dev/null >/dev/null 2>&1 || :; }

_ota_line() {
	_f=${OTATRACE_FILE:-/opt/batdata/log/ota-trace.log}
	_l="$(date +%Y%m%d-%H%M%S) boot=$(cut -c1-8 /proc/sys/kernel/random/boot_id) up=$(cut -d. -f1 /proc/uptime) $*"
	[ "${OTATRACE_KMSG:-}" = 1 ] && echo "batman-ota: $_l" > /dev/kmsg
	_d=${_f%/*}
	[ -d "$_d" ] || return 0
	# the default location only on a MOUNTED data partition — never into the rootfs mountpoint dir
	case "$_d" in /opt/batdata/*) grep -q " /opt/batdata " /proc/mounts || return 0 ;; esac
	echo "$_l" >> "$_f"
	sync
}

# Raw facts, safe in the stage-2 ramfs (vcmailbox is staged there; vcgencmd is not). Meant for
# $(...) inside otalog arguments: they print exactly one token and never fail the caller.
ota_get()  { vcmailbox 0x00030064 4 4 0 2>/dev/null | awk '{printf "%s", $6}'; return 0; }   # tryboot flag
ota_thr()  { vcmailbox 0x00030046 4 4 0 2>/dev/null | awk '{printf "%s", $6}'; return 0; }   # throttled
