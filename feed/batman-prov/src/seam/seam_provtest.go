//go:build prov_test

// Package seam holds the test-only seams of batman-provhelper (docs/design/254-h23-harness.md §4.1, §15).
// This file is compiled ONLY with -tags prov_test; the release build gets seam_release.go, which has no strings.
//
// Killpoint file: /tmp/run/batman-prov-test/killpoint, one line = one point name. The daemon reads it once at start
// (Arm), deletes it, and from then on the matching At(name) call reboots the node at once with sysrq "b" — no sync,
// no unmount: the closest the harness gets to pulling the power at that point of a transaction.
package seam

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

// Marker is printed by `batman-provhelper --version` (line 2) and logged first by --boot / the daemon. The build gate
// and preflight grep for it: it must exist only in prov_test builds.
const Marker = "BATMAN_PROV_TEST_BUILD_7f3a"

// Enabled reports whether this binary carries the test seams.
const Enabled = true

// The one log format for an armed point. The build gate greps the binary for `killpoint .*: armed`, so this must stay
// ONE literal (a concatenated string is not in .rodata as such — §15.1).
const armedFmt = "killpoint %s: armed"

// Dir is the killpoint directory (root 0700). A var only so the unit tests can point it at a temp dir.
var Dir = "/tmp/run/batman-prov-test"

// wantUID is the required owner of the dir and the file. Tests set it to their own euid.
var wantUID = 0

// names is the closed list of points (§4.1.1). Anything else in the file is ignored.
var names = map[string]bool{
	"txn-1": true, "txn-2": true, "txn-3": true, "txn-4": true, "txn-5": true,
	"claim-after-persist": true, "claim-before-shadow": true,
}

var armed string

// reboot is the action at an armed point; tests replace it.
var reboot = func(name string, logf func(string, ...any)) {
	logf("killpoint %s: sysrq reboot", name)
	if f, err := os.OpenFile("/proc/sysrq-trigger", os.O_WRONLY, 0); err == nil {
		f.Write([]byte("b"))
		f.Close()
	}
	// still alive: sysrq unavailable (/proc read-only, no sysrq support) — fall back, and say so
	time.Sleep(2 * time.Second)
	logf("killpoint %s: fallback reboot -f", name)
	syscall.Sync()
	exec.Command("reboot", "-f").Run()
	select {}
}

func refuse(logf func(string, ...any), why string) { logf("killpoint: refused (%s)", why) }

// owned checks a path without following a final symlink: exact type, owner wantUID, exact permission bits, link count.
func owned(p string, dir bool, perm os.FileMode) (string, bool) {
	fi, err := os.Lstat(p)
	if err != nil {
		return err.Error(), false
	}
	if fi.Mode()&os.ModeSymlink != 0 {
		return p + " is a symlink", false
	}
	if dir != fi.IsDir() || (!dir && !fi.Mode().IsRegular()) {
		return p + " has the wrong type", false
	}
	st, ok := fi.Sys().(*syscall.Stat_t)
	if !ok || int(st.Uid) != wantUID {
		return p + " is not owned by root", false
	}
	if fi.Mode().Perm() != perm {
		return p + " has mode " + fi.Mode().Perm().String(), false
	}
	if !dir && st.Nlink != 1 {
		return p + " has more than one link", false
	}
	return "", true
}

// Arm reads and deletes the killpoint file. Absent file = nothing armed, no log line.
func Arm(logf func(string, ...any)) {
	armed = ""
	f := filepath.Join(Dir, "killpoint")
	if _, err := os.Lstat(f); err != nil {
		return
	}
	if why, ok := owned(Dir, true, 0o700); !ok {
		refuse(logf, why)
		return
	}
	if why, ok := owned(f, false, 0o600); !ok {
		refuse(logf, why)
		return
	}
	b, err := os.ReadFile(f)
	os.Remove(f)
	if err != nil {
		refuse(logf, err.Error())
		return
	}
	name := strings.TrimSpace(string(b))
	if !names[name] {
		refuse(logf, "unknown point "+name)
		return
	}
	armed = name
	logf(armedFmt, name)
}

// At fires the armed point. Called on every transaction path; a no-op unless this exact point is armed.
func At(name string, logf func(string, ...any)) {
	if armed != "" && armed == name {
		reboot(name, logf)
	}
}
