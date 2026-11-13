package main

import (
	"os"
	"path/filepath"
	"reflect"
	"sync/atomic"
	"testing"
	"time"
)

// design D-12: the staged packages are the non-empty regular files in uci's save dir, sorted
func TestUciStagedIn(t *testing.T) {
	old := uciOwner
	uciOwner = uint32(os.Getuid()) // the test's own dir stands in for root's
	t.Cleanup(func() { uciOwner = old })
	d := t.TempDir()
	os.Chmod(d, 0o700)
	os.WriteFile(filepath.Join(d, "wireless"), []byte("x"), 0o600)
	os.WriteFile(filepath.Join(d, "network"), []byte("y"), 0o600)
	os.WriteFile(filepath.Join(d, "system"), nil, 0o600) // empty: nothing staged
	os.Mkdir(filepath.Join(d, "sub"), 0o700)
	if got := uciStagedIn(d); !reflect.DeepEqual(got, []string{"network", "wireless"}) {
		t.Fatalf("staged %v", got)
	}
	if got := uciStagedIn(filepath.Join(d, "none")); got != nil {
		t.Fatalf("no dir: %v", got)
	}
	// #280: a save dir that is not the owner's 0700 directory is not trusted: counted as staged, never read
	untrusted := []string{"uci-savedir-untrusted"}
	os.Chmod(d, 0o755)
	if got := uciStagedIn(d); !reflect.DeepEqual(got, untrusted) {
		t.Fatalf("0755 save dir: %v", got)
	}
	os.Chmod(d, 0o700)
	ln := filepath.Join(t.TempDir(), "link")
	os.Symlink(d, ln)
	if got := uciStagedIn(ln); !reflect.DeepEqual(got, untrusted) {
		t.Fatalf("a symlinked save dir: %v", got)
	}
	f := filepath.Join(t.TempDir(), "file")
	os.WriteFile(f, nil, 0o700)
	if got := uciStagedIn(f); !reflect.DeepEqual(got, untrusted) {
		t.Fatalf("a file as the save dir: %v", got)
	}
	uciOwner = uint32(os.Getuid()) + 1
	if got := uciStagedIn(d); !reflect.DeepEqual(got, untrusted) {
		t.Fatalf("another owner's save dir: %v", got)
	}
}

// design D-9: on a trial boot the one-off save waits for the commit; stop ends the wait without saving
func TestSaveAfterCommit(t *testing.T) {
	var trial atomic.Bool
	trial.Store(true)
	var saved atomic.Int32
	done := make(chan struct{})
	go func() { saveAfterCommit(trial.Load, nil, 5*time.Millisecond, func() { saved.Add(1) }); close(done) }()
	time.Sleep(30 * time.Millisecond)
	if saved.Load() != 0 {
		t.Fatal("saved during the trial")
	}
	trial.Store(false)
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("no save after the commit")
	}
	if saved.Load() != 1 {
		t.Fatalf("saved %d times", saved.Load())
	}
	stop := make(chan struct{})
	close(stop)
	saveAfterCommit(func() bool { return true }, stop, time.Hour, func() { t.Fatal("saved after stop") })
}

// A r2 m6 / r3 m5: the D-9 save waits while the boot is a trial OR a wireless change is unfinished (.txn)
func TestTrialOrTxn(t *testing.T) {
	f := func(tr, tx bool) bool {
		return trialOrTxn(func() bool { return tr }, func() bool { return tx })()
	}
	if !f(true, false) || !f(false, true) || !f(true, true) || f(false, false) {
		t.Fatalf("trialOrTxn: %v %v %v %v", f(true, false), f(false, true), f(true, true), f(false, false))
	}
}
