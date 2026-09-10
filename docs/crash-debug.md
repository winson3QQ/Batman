# Crash-debug capability (#61)

How a node's death is captured so it's diagnosable — the field requirement is "**a node must
not fall over**, and when it does we must know why" (#67). This spec defines the capture
layers, what each one catches, and the current gaps.

Background (this session): manet02 rebooted under load with an **empty pstore** and the
kernel lacks hung-task/softlockup detectors → a pure hang produced **no backtrace**. The
capture chain below closes that.

## Failure modes → what catches them

| Failure | Symptom | Caught by |
|---|---|---|
| Clean reboot (watchdog, power cycle) | node restarts | persistent syslog (last lines on disk) |
| **Kernel panic / oops** | kernel dies with a trace | **pstore/ramoops** (last kernel output to reserved RAM, survives reboot) + serial console |
| **Pure hang** (no panic) | node frozen, no trace | **hung-task / softlockup detectors** (convert a hang into a captured panic) + serial console |
| Hard power-off (battery) | abrupt loss | nothing after the last fsync — mitigated by graceful shutdown (#91); unflushed tail is lost |

## Capture layers

### 1. Persistent syslog (have — but mislocated)
OpenWrt logd is a RAM ring buffer by default (lost on reboot). manet02 is configured with
`log_file=/root/persist-syslog.log` (survives clean reboot). **Gap:** `/root` is on the
**rootfs overlay** → an A/B image swap (#74) wipes it. **Fix:** relocate the persistent log
to **p5** (storage-architecture.md / #88). Buffered writes still lose the tail on hard
power-off.

### 2. pstore / ramoops (missing — enable)
A reserved RAM region the kernel writes its **last output** to on panic; the pstore filesystem
exposes it after reboot. **Gap:** `/proc/cmdline` has **no ramoops** → panics aren't captured;
`/sys/fs/pstore` is empty. **Fix:** reserve a `ramoops` region (kernel cmdline / DT
`reserved-memory`), size it (a few 100 KB), and reserve the region in the #88 p5/RAM layout.
After a panic, the trace lands in pstore and can be flushed to the persistent log on next boot.

### 3. Kernel hung-task / softlockup detectors (missing — build)
The stock kernel lacks `CONFIG_DETECT_HUNG_TASK` / `CONFIG_SOFTLOCKUP_DETECTOR`, so a pure
hang never becomes a panic → nothing to capture. **Fix:** enable them in the kernel config so
a hang **converts to a captured panic** (which then lands in ramoops #2). This needs a kernel
rebuild (ties to the driver/image build, docs/building-the-driver.md).

### 4. Serial console (needs hardware — USB-UART)
A USB-UART on the Pi's UART pins captures the **last kernel output of a hard hang** live, even
when nothing reaches disk or the network — the determinative method. **Hardware-gated:** needs
a USB-UART adapter + a collector on the desktop. Document the wiring + the capture setup;
implement when the adapter is on hand.

## Live-capture chain (already validated this session)

For a node under watch, a reconnecting **syslog stream** to the desktop + **btime-versioned
snapshots** of the node's CSV/logs captured the pre-reboot trajectory without data loss across
reboots. Keep this for active debugging; it complements (doesn't replace) the on-node layers.

## Priority

1. **Now (no hardware):** relocate persistent syslog to p5 (#88); reserve + enable **ramoops**
   (cmdline/DT) — cheapest capture win.
2. **Kernel rebuild:** hung-task / softlockup detectors (with the next driver/image build).
3. **Hardware:** USB-UART serial console when the adapter is available.

Standards / prior art: kernel pstore/ramoops, `hung_task`/`softlockup` watchdogs; the EMS
epic (#67) consumes these as fault signals (#66 alarms, #65 collector).
