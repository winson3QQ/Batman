package node

// 329-sshkeys-cut §8: ssh_keys.set keeps invariant I — every app-added key line in a durable copy of authorized_keys
// (the overlay file as a power loss keeps it, the p5 copy) is in the durable (p5) record's SSHKeysAdded — at every cut
// point and on every --save outcome. Negative control: today's order (commit, then write, then one --save whose rc is
// ignored) fails TestSSHKeysCut "save#1", TestSSHKeysSaveFailResend and TestSSHKeysP5Differs.

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"batman-prov/cbor"
	"batman-prov/provstore"
)

const (
	kA = "ssh-ed25519 AAAAkeyA app-a"
	kB = "ssh-ed25519 AAAAkeyB app-b"
	kC = "ssh-ed25519 AAAAkeyC app-c"
)

var appKeys = []string{kA, kB, kC}

type cutHere struct{ point string }

// claimed rig with the lab key everywhere and the durable copies equal to the live file
func sshRig(t *testing.T) *rig {
	r := newRig(t, provstore.Unclaimed)
	if c, _ := r.claim(); c != OK {
		t.Fatal("claim")
	}
	r.sys.keysSynced = append([]string(nil), r.sys.keys...)
	r.sys.p5keys = append([]string(nil), r.sys.keys...)
	return r
}

func (r *rig) setKeys(keys ...string) (int, cbor.Map) {
	l := []any{}
	for _, k := range keys {
		l = append(l, k)
	}
	return r.call("ssh_keys.set", cbor.M(1, r.h, 2, r.envelope("ssh_keys/set", cbor.M(1, l), r.owner)))
}

// setKeysCut: one ssh_keys.set that stops (power loss) at the n-th call of point; true = it stopped there
func (r *rig) setKeysCut(point string, nth int, keys ...string) (cut bool) {
	seen := 0
	r.sys.cut = func(p string) {
		if p == point {
			if seen++; seen == nth {
				panic(cutHere{p})
			}
		}
	}
	defer func() {
		r.sys.cut = nil
		if x := recover(); x != nil {
			if _, ok := x.(cutHere); !ok {
				panic(x)
			}
			cut = true
		}
	}()
	r.setKeys(keys...)
	return false
}

// reboot: a new Node on the same overlay + p5 (the helper restarts; n.mu of the dead one is gone with it). keep =
// whether the overlay file's last rename survived (no directory fsync: either outcome is possible).
func (r *rig) reboot(keep bool) {
	if !keep {
		r.sys.keys = append([]string(nil), r.sys.keysSynced...)
	}
	r.sys.keysSynced = append([]string(nil), r.sys.keys...)
	n := New(r.n.P, r.ks, r.sys, func(string, ...any) {})
	n.Verdict = provstore.Claimed
	r.n = n
}

// durable record: the p5 one (the boot rebuilds the overlay from it when it is newer)
func (r *rig) p5Record(t *testing.T) *provstore.Record {
	b, err := os.ReadFile(filepath.Join(r.sys.p5, "prov.cbor"))
	if err != nil {
		t.Fatalf("p5 record: %v", err)
	}
	rec, err := provstore.Decode(b)
	if err != nil {
		t.Fatalf("p5 record: %v", err)
	}
	return rec
}

// checkI: I on every durable copy; also the live file when liveDurable (it is what a reboot keeps when the rename
// survived)
func (r *rig) checkI(t *testing.T, ctx string) {
	t.Helper()
	tracked := map[string]bool{}
	for _, k := range r.p5Record(t).SSHKeysAdded {
		tracked[strings.TrimSpace(k)] = true
	}
	for name, copy := range map[string][]string{"overlay (synced)": r.sys.keysSynced, "overlay (rename kept)": r.sys.keys, "p5": r.sys.p5keys} {
		for _, l := range copy {
			for _, a := range appKeys {
				if l == a && !tracked[l] {
					t.Errorf("%s: I broken: %s holds app key %q, the record lists %v", ctx, name, l, r.p5Record(t).SSHKeysAdded)
				}
			}
		}
	}
}

func (r *rig) noAppKey(t *testing.T, ctx string) {
	t.Helper()
	for name, copy := range map[string][]string{"overlay": r.sys.keys, "p5": r.sys.p5keys} {
		for _, l := range copy {
			for _, a := range appKeys {
				if l == a {
					t.Errorf("%s: %s still holds app key %q after ssh_keys.set []", ctx, name, l)
				}
			}
		}
	}
	if len(r.sys.keys) == 0 || r.sys.keys[0] != "ssh-ed25519 AAAAlab lab" {
		t.Errorf("%s: the lab key must stay: %v", ctx, r.sys.keys)
	}
}

func reason(b cbor.Map) uint64 { v, _ := b.Get(1); u, _ := v.(uint64); return u }

// every cut point of a replace [A,B] -> [B,C], both outcomes of the last rename; then the app's "remove all"
func TestSSHKeysCut(t *testing.T) {
	for _, cp := range []struct {
		point string
		nth   int
	}{{"set", 1}, {"save", 1}, {"set", 2}, {"save", 2}} {
		for _, keep := range []bool{true, false} {
			name := fmt.Sprintf("%s#%d/keep=%v", cp.point, cp.nth, keep)
			t.Run(name, func(t *testing.T) {
				r := sshRig(t)
				if c, _ := r.setKeys(kA, kB); c != OK {
					t.Fatalf("set [A B]: %d", c)
				}
				r.checkI(t, "after [A B]")
				if !r.setKeysCut(cp.point, cp.nth, kB, kC) {
					t.Fatalf("the op never reached %s #%d", cp.point, cp.nth)
				}
				r.reboot(keep)
				r.checkI(t, "after the cut")
				if c, b := r.setKeys(); c != OK {
					t.Fatalf("set []: %d %v", c, b)
				}
				r.noAppKey(t, "after the cut")
			})
		}
	}
}

// review A-1: the removal's --save fails (not persisted) -> reason 25; the resend's step-3 save fails too: p5 must
// not keep A untracked (today: the op answers OK and p5 keeps A under a record without it)
func TestSSHKeysSaveFailResend(t *testing.T) {
	r := sshRig(t)
	if c, _ := r.setKeys(kA); c != OK {
		t.Fatal("set [A]")
	}
	r.sys.saveOut, r.sys.saveLost = []saveRC{{rc: 1, out: "mount failed"}}, []bool{true}
	c, b := r.setKeys(kB)
	if c != EApply || reason(b) != ReasonSSHUnpersisted {
		t.Fatalf("first try: want EApply/25, got %d %v", c, b)
	}
	r.checkI(t, "after the failed removal")
	r.sys.saveOut, r.sys.saveLost = []saveRC{{}, {rc: 1, out: "mount failed"}}, []bool{false, true} // resend: step 1 saves, step 3 fails
	c, b = r.setKeys(kB)
	if c != EApply || reason(b) != ReasonSSHUnpersisted {
		t.Fatalf("resend: want EApply/25, got %d %v", c, b)
	}
	r.checkI(t, "after the resend")
	if c, _ := r.setKeys(); c != OK {
		t.Fatal("set []")
	}
	r.noAppKey(t, "after the failures")
}

// review B-M1: the p5 copy differs from the overlay (A removed by hand, no --save); the step-3 save does not persist
func TestSSHKeysP5Differs(t *testing.T) {
	r := sshRig(t)
	if c, _ := r.setKeys(kA); c != OK {
		t.Fatal("set [A]")
	}
	r.sys.keys = []string{"ssh-ed25519 AAAAlab lab"} // by hand, no --save: p5 still has A
	// the --save after the commit is lost (rc 1, not persisted) — keyed on the generation, so today's single save
	// (after its commit) is hit as well as the fix's step-3 save
	r.sys.loseAfterGen = r.p5Record(t).Generation
	r.sys.saveOut = []saveRC{{}, {rc: 1, out: "mount failed"}}
	r.setKeys()
	r.sys.loseAfterGen = 0
	r.checkI(t, "after [] with p5 != overlay")
}

// rc 6 = persisted (a uci value was not persistable): OK; the busy lock is retried once
func TestSSHKeysSaveRC(t *testing.T) {
	r := sshRig(t)
	r.sys.saveOut = []saveRC{{rc: 6, out: "saved (rejected:x)"}}
	if c, b := r.setKeys(kA); c != OK {
		t.Fatalf("rc 6: want OK, got %d %v", c, b)
	}
	busy := "another batman-config-save is writing p5"
	before := r.sys.saves
	r.sys.saveOut, r.sys.saveLost = []saveRC{{rc: 1, out: busy}, {}, {rc: 1, out: busy}, {}}, []bool{true, false, true, false}
	if c, b := r.setKeys(kB); c != OK {
		t.Fatalf("busy then ok: want OK, got %d %v", c, b)
	}
	if d := r.sys.saves - before; d != 4 {
		t.Fatalf("want 4 saves (step 1: busy + retry, step 3: busy + retry), got %d", d)
	}
	r.checkI(t, "after the retries")
}

// failure codes (§3.4): reason 25 once the file may have changed; the plain code before
func TestSSHKeysFailureCodes(t *testing.T) {
	r := sshRig(t)
	if c, _ := r.setKeys(kA); c != OK {
		t.Fatal("set [A]")
	}
	// step-1 write fails: atomic rename, file unchanged -> plain EApply
	r.sys.setKeysErr = errors.New("disk")
	if c, b := r.setKeys(kB); c != EApply || reason(b) != 0 {
		t.Fatalf("step-1 write: want EApply/no reason, got %d %v", c, b)
	}
	r.sys.setKeysErr = nil
	// step 1 ran, commit fails -> 25
	r.sys.persistRC = 1
	if c, b := r.setKeys(kB); c != EApply || reason(b) != ReasonSSHUnpersisted {
		t.Fatalf("commit after step 1: want EApply/25, got %d %v", c, b)
	}
	r.checkI(t, "commit failed after step 1")
	// step 1 skipped (add only), commit fails -> the commit's code, as today
	r.sys.persistRC = 1
	if c, b := r.setKeys(kA, kB); c == EApply || reason(b) != 0 {
		t.Fatalf("commit, step 1 skipped: want the commit's own code, got %d %v", c, b)
	}
	r.sys.persistRC = 0
	// step 1 skipped, step-3 write fails -> 25
	r.sys.setKeysErr = errors.New("disk")
	if c, b := r.setKeys(kA, kB); c != EApply || reason(b) != ReasonSSHUnpersisted {
		t.Fatalf("step-3 write: want EApply/25, got %d %v", c, b)
	}
	r.sys.setKeysErr = nil
	r.checkI(t, "after the failures")
}

// review A-3: surrounding spaces are trimmed and stay revocable; an untrimmed line in an old record still matches; any
// \n is still refused
func TestSSHKeysCanonical(t *testing.T) {
	r := sshRig(t)
	if c, _ := r.setKeys(kA + "  "); c != OK {
		t.Fatal("set [A+spaces]")
	}
	rec := r.p5Record(t)
	if len(rec.SSHKeysAdded) != 1 || rec.SSHKeysAdded[0] != kA {
		t.Fatalf("stored %q, want the trimmed line", rec.SSHKeysAdded)
	}
	if c, _ := r.setKeys(kA + "\n"); c != ESchema {
		t.Fatalf("a trailing \\n must stay refused, got %d", c)
	}
	// an old record holding the raw line (written before the trim) with the file holding the trimmed one
	old := r.p5Record(t)
	old.SSHKeysAdded = []string{kA + " "}
	old.Generation++
	provstore.WriteOverlay(r.n.P, old)
	enc, _ := old.Encode()
	os.WriteFile(filepath.Join(r.sys.p5, "prov.cbor"), enc, 0o600)
	os.WriteFile(filepath.Join(r.sys.p5, "prov.meta"), []byte(provstore.MetaLine(old, enc)), 0o600)
	if c, b := r.setKeys(); c != OK {
		t.Fatalf("set []: %d %v", c, b)
	}
	r.noAppKey(t, "old untrimmed record")
}
