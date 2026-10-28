//go:build prov_test

// Package seam holds the test-only seams of batman-provhelper (docs/design/254-h23-harness.md §4.1, §15, §16).
// This file is compiled ONLY with -tags prov_test; the release build gets seam_release.go, which has no strings.
//
// Killpoint file: /tmp/run/batman-prov-test/killpoint, one line = one point name. The daemon reads it once at start
// (Arm), deletes it, and from then on the matching At(point) call reboots the node at once with sysrq "b" — no sync,
// no unmount: the closest the harness gets to pulling the power at that point of a transaction.
//
// The syslog "sysrq reboot" line is NOT expected to reach the host: the node dies microseconds later with it still in
// RAM. The same line goes to /dev/kmsg first, so a console capture (ramoops) carries it over the reboot, and the
// kernel's own "sysrq: " line makes the next boot-reasons record say "hints: sysrq". The harness judges a killpoint by
// §16.1 (armed line, no reply, boot_id, the state of that point, boot-reasons); a "fallback" line = sysrq did not work.
package seam

import (
	"fmt"
	"io"
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

// maxFile bounds the killpoint file: a point name, a newline, nothing else.
const maxFile = 64

// Dir is the killpoint directory (root 0700). A var only so the unit tests can point it at a temp dir.
var Dir = "/tmp/run/batman-prov-test"

// wantUID is the required owner of the dir and the file. Tests set it to their own euid.
var wantUID = 0

// names is the closed list of points (§4.1.1) by the name the killpoint file uses.
var names = map[string]Point{
	"txn-1": Txn1, "txn-2": Txn2, "txn-3": Txn3, "txn-4": Txn4, "txn-5": Txn5,
	"claim-after-persist": ClaimAfterPersist, "claim-before-shadow": ClaimBeforeShadow,
}

func nameOf(p Point) string {
	for n, q := range names {
		if q == p {
			return n
		}
	}
	return fmt.Sprintf("point-%d", p)
}

var armed Point

// kmsg writes one line to the kernel log: it is in the console (and so in a ramoops console capture) at once.
func kmsg(s string) {
	if f, err := os.OpenFile(kmsgPath, os.O_WRONLY|os.O_APPEND, 0); err == nil {
		f.Write([]byte("<4>batman-provhelper: " + s + "\n"))
		f.Close()
	}
}

// The paths, the wait and the fallback are vars only so the unit tests can run fire() without rebooting the host.
var (
	kmsgPath  = "/dev/kmsg"
	sysrqPath = "/proc/sysrq-trigger"
	settle    = 2 * time.Second
	fallback  = func() error { syscall.Sync(); return exec.Command("reboot", "-f").Run() }
)

// reboot is the action at an armed point; ArmForTest replaces it.
var reboot = fire

// fire: log + kmsg, sysrq "b"; still alive after settle → log + kmsg the fallback, reboot -f; never returns.
func fire(name string, logf func(string, ...any)) {
	m := fmt.Sprintf("killpoint %s: sysrq reboot", name)
	logf("%s", m)
	kmsg(m)
	f, err := os.OpenFile(sysrqPath, os.O_WRONLY, 0)
	if err == nil {
		_, err = f.Write([]byte("b"))
		f.Close()
	}
	if err != nil {
		m = fmt.Sprintf("killpoint %s: sysrq write failed: %v", name, err)
		logf("%s", m)
		kmsg(m)
	}
	// still alive: sysrq unavailable (/proc read-only, no sysrq support) — fall back, and say so
	time.Sleep(settle)
	m = fmt.Sprintf("killpoint %s: fallback reboot -f", name)
	logf("%s", m)
	kmsg(m)
	err = fallback()
	time.Sleep(5 * time.Second)
	logf("killpoint %s: reboot did not happen (%v); stopping here", name, err)
	select {}
}

func refuse(logf func(string, ...any), why string) { logf("killpoint: refused (%s)", why) }

// modeBits = permission bits plus setuid/setgid/sticky: an exact match refuses any special bit.
const modeBits = os.ModePerm | os.ModeSetuid | os.ModeSetgid | os.ModeSticky

// check: exact type, owner wantUID, exact mode bits (special bits included), link count 1 for a file.
func check(p string, fi os.FileInfo, dir bool, perm os.FileMode) (string, bool) {
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
	if fi.Mode()&modeBits != perm {
		return p + " has mode " + (fi.Mode() & modeBits).String(), false
	}
	if !dir && st.Nlink != 1 {
		return p + " has more than one link", false
	}
	return "", true
}

// Arm reads and deletes the killpoint file. Absent file = nothing armed, no log line.
// The dir is checked first (Lstat); an untrusted dir is not even unlinked in. The file is opened once with O_NOFOLLOW
// and checked on that descriptor (fstat), so what is checked is what is read.
func Arm(logf func(string, ...any)) {
	armed = None
	f := filepath.Join(Dir, "killpoint")
	if _, err := os.Lstat(f); err != nil {
		return
	}
	if fi, err := os.Lstat(Dir); err != nil {
		refuse(logf, err.Error())
		return
	} else if why, ok := check(Dir, fi, true, 0o700); !ok {
		refuse(logf, why) // an untrusted dir: do not even unlink in it
		return
	}
	defer os.Remove(f) // trusted dir: the file is read once, whatever its outcome (unlink does not follow a symlink)
	fd, err := os.OpenFile(f, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		refuse(logf, err.Error())
		return
	}
	defer fd.Close()
	fi, err := fd.Stat()
	if err != nil {
		refuse(logf, err.Error())
		return
	}
	if why, ok := check(f, fi, false, 0o600); !ok {
		refuse(logf, why)
		return
	}
	b, err := io.ReadAll(io.LimitReader(fd, maxFile+1))
	if err != nil {
		refuse(logf, err.Error())
		return
	}
	if len(b) > maxFile {
		refuse(logf, "killpoint file longer than 64 bytes")
		return
	}
	name := strings.TrimSpace(string(b))
	p, ok := names[name]
	if !ok {
		refuse(logf, "unknown point "+name)
		return
	}
	armed = p
	logf(armedFmt, name)
}

// At fires the armed point. Called on every transaction path; a no-op unless this exact point is armed.
func At(p Point, logf func(string, ...any)) {
	if armed != None && armed == p {
		reboot(nameOf(p), logf)
	}
}
