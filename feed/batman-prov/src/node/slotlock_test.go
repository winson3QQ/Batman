package node

import (
	"os"
	"path/filepath"
	"syscall"
	"testing"
)

// holdSlotLock takes batman-slot's exclusive slot lock the way batman-slot does (a kernel flock on
// $RUNDIR/batman-slot.flock, 254-p3-impl §3.7.3) and returns its release.
func holdSlotLock(t *testing.T, rundir string) func() {
	t.Helper()
	f, err := os.OpenFile(filepath.Join(rundir, "batman-slot.flock"), os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		t.Fatal(err)
	}
	return func() { _ = f.Close() }
}

// #254 S5: otaBusy reads batman-slot's flock — no lock file = not busy, held = busy, released = not busy, cannot
// open = busy; and the probe itself must never keep a lock (a kept shared lock makes batman-slot's own exclusive
// lock fail: review B15-MAJOR-1 in shell form).
func TestOtaBusyFlock(t *testing.T) {
	r := claimedRig(t)
	lockf := filepath.Join(r.n.P.RunDir, "batman-slot.flock")
	if r.n.otaBusy() {
		t.Fatal("no lock file: must not be busy")
	}
	release := holdSlotLock(t, r.n.P.RunDir)
	if !r.n.otaBusy() {
		t.Fatal("lock held: must be busy")
	}
	release()
	if r.n.otaBusy() {
		t.Fatal("lock released (file still there): must not be busy")
	}
	// the probe left nothing behind: an exclusive non-blocking lock still succeeds right after it
	f, err := os.OpenFile(lockf, os.O_WRONLY|os.O_APPEND, 0)
	if err != nil {
		t.Fatal(err)
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		t.Fatalf("otaBusy kept a lock: %v", err)
	}
	_ = f.Close()
	// cannot tell -> busy (fail-closed): a symlink is refused by O_NOFOLLOW
	if err := os.Remove(lockf); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("/dev/null", lockf); err != nil {
		t.Fatal(err)
	}
	if !r.n.otaBusy() {
		t.Fatal("lock file is a symlink: must be busy (cannot tell)")
	}
}
