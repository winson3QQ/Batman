package main

// The real node.UpdateSys / node.UpdateFS (254-p3-impl §3.7, §3.8): batman-slot, /rom keys, p6, provd's bulk tmpfs.

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"time"

	"batman-prov/node"
	"batman-prov/provstore"
	"batman-prov/release"
)

const (
	romKeys    = "/rom/usr/share/batman" // the image's root key: read from the squashfs only (§3.7.1)
	bulkDir    = "/tmp/run/batman-provd-bulk"
	workDir    = "/tmp/run/batman/update"
	p6Mount    = "/opt/batdata"
	slotWriteT = 600 * time.Second
)

// nsVerbs run in a private mount namespace: a KILL leaves no boot-FAT / p5 mount behind (§3.7.3). reboot committed
// and is-trial stay in the init namespace (the 240 s safety net must not hold a namespace into the shutdown).
var nsVerbs = map[string]bool{"write": true, "arm": true, "disarm": true, "bootinfo": true, "precheck-node": true}

type realUpdate struct {
	p      provstore.Paths
	trust  release.Trust
	ver    string
	board  string
	active string
	trial  func() bool
}

// newRealUpdate: nil when this is not an A/B card (no batman_slot= on the kernel command line) — the update verbs
// then answer E_UNSUPPORTED instead of guessing a target slot.
func newRealUpdate(p provstore.Paths, trial func() bool) *realUpdate {
	act := cmdlineSlot("/proc/cmdline")
	if act == "" {
		return nil
	}
	st := stampKV("/etc/batman-build")
	return &realUpdate{p: p, trust: release.LoadTrust(romKeys), ver: st["BATMAN_VERSION"], board: st["BATMAN_BOARD"],
		active: act, trial: trial}
}

// cmdlineSlot: batman_slot=A|B (batman-slot active_slot's rule)
func cmdlineSlot(path string) string {
	b, _ := os.ReadFile(path)
	for _, f := range strings.Fields(string(b)) {
		if v, ok := strings.CutPrefix(f, "batman_slot="); ok && (v == "A" || v == "B") {
			return v
		}
	}
	return ""
}

// stampKV reads /etc/batman-build (parsed, never sourced; F-P59)
func stampKV(path string) map[string]string {
	kv := map[string]string{}
	b, err := os.ReadFile(path)
	if err != nil {
		return kv
	}
	for l := range strings.Lines(string(b)) {
		if k, v, ok := strings.Cut(strings.TrimSpace(l), "="); ok {
			kv[k] = v
		}
	}
	return kv
}

func (u *realUpdate) Trust() release.Trust         { return u.trust }
func (u *realUpdate) Build() (string, string)      { return u.ver, u.board }
func (u *realUpdate) MemAvailable() (uint64, bool) { return memAvailable("/proc/meminfo") }
func (u *realUpdate) Uptime() int                  { return uptime() }
func (u *realUpdate) BootID() string               { return bootID() }
func (u *realUpdate) ActiveSlot() string           { return u.active }
func (u *realUpdate) PreSave()                     { upgradeSave(u.p, u.trial()) }
func (u *realUpdate) BulkDir() string              { return bulkDir }
func (u *realUpdate) WorkDir() string              { return workDir }
func (u *realUpdate) ProvdUID() int                { return provdUID }
func (u *realUpdate) AutocommitLog() string        { return p6Mount + "/log/autocommit.log" }
func (u *realUpdate) SlotBusy() bool               { return node.SlotLockHeld(u.p.RunDir) }
func (u *realUpdate) IsTrial() bool                { return u.trial() }
func (u *realUpdate) P6State() (string, bool) {
	return p6Mount + "/state", isMountPoint("/proc/mounts", p6Mount)
}

// Slot: batman-slot <verb>; stdout for bootinfo (only stdout is parsed), the messages (stderr) for the rest.
func (u *realUpdate) Slot(timeout time.Duration, args ...string) (int, string) {
	rc, so, se := provstore.ExecSplit(provstore.Opts{Timeout: timeout, Env: cleanEnv, NewNS: len(args) > 0 && nsVerbs[args[0]]},
		"batman-slot", args...)
	if len(args) > 0 && args[0] == "bootinfo" && rc == 0 {
		return rc, so
	}
	if strings.TrimSpace(se) == "" {
		return rc, so
	}
	return rc, se
}

func (u *realUpdate) SlotWrite(cancel <-chan struct{}, dir string, rootfs io.Reader) (int, string) {
	rc, so, se := provstore.ExecSplit(provstore.Opts{Timeout: slotWriteT, Env: cleanEnv, Stdin: rootfs, Cancel: cancel, NewNS: true},
		"batman-slot", "write", dir)
	if strings.TrimSpace(se) == "" {
		return rc, so
	}
	return rc, se
}

// Reboot: batman-slot reboot committed, in the init namespace (it returns once procd has the shutdown)
func (u *realUpdate) Reboot() error {
	rc, out := run(nil, "batman-slot", "reboot", "committed", "app update")
	if rc != 0 {
		return fmt.Errorf("batman-slot reboot committed rc %d: %s", rc, lastLine(out))
	}
	return nil
}

// memAvailable: MemAvailable in bytes
func memAvailable(path string) (uint64, bool) {
	f, err := os.Open(path)
	if err != nil {
		return 0, false
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		fl := strings.Fields(sc.Text())
		if len(fl) == 3 && fl[0] == "MemAvailable:" && fl[2] == "kB" {
			v, err := strconv.ParseUint(fl[1], 10, 64)
			if err != nil || v > 1<<44 {
				return 0, false
			}
			return v << 10, true
		}
	}
	return 0, false
}

// isMountPoint: /proc/mounts has this mount point (otatrace.sh / batman-slot's rule; the source is not compared —
// a LUKS node mounts /dev/mapper/batdata_crypt)
func isMountPoint(mounts, dir string) bool {
	b, err := os.ReadFile(mounts)
	if err != nil {
		return false
	}
	for l := range strings.Lines(string(b)) {
		if fl := strings.Fields(l); len(fl) >= 2 && fl[1] == dir {
			return true
		}
	}
	return false
}

// coreFreqMinOK: the running firmware reports core_freq_min >= 500 (§6.4 ble-ok, unchanged)
func coreFreqMinOK() bool {
	rc, out := run(nil, "vcgencmd", "get_config", "core_freq_min")
	if rc != 0 {
		return false
	}
	v, err := strconv.Atoi(strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(out), "core_freq_min=")))
	return err == nil && v >= 500
}
