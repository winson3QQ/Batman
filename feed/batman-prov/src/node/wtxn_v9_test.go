package node

import (
	"errors"
	"strings"
	"testing"
	"time"

	"batman-prov/provstore"
)

// docs/design/254-wireless-txn.md §16 (code review round 2): one test per finding / surviving mutant.

// review 2 A MAJOR-2: after a leave the operator set their own mesh with halow-setkey; a join that then fails goes back
// to THOSE settings (the pre-change snapshot), not to "forgotten"
func TestLeftThenOperatorSettingsThenFailedJoin(t *testing.T) {
	r, _ := memberRig(t)
	if c := r.leave(); c != OK {
		t.Fatalf("leave: %d", c)
	}
	r.sys.wl = [3]string{"operator-key", "opmesh", "36"} // the operator's own halow-setkey after the leave
	r.sys.radioOff, r.sys.inMark = false, false
	r.crashTxn2("sae-n1-pass", "n1", "28")
	f := r.sys.forgets
	if err := r.fin(); err != nil {
		t.Fatalf("Finish: %v", err)
	}
	if r.sys.forgets != f || r.wl() != "operator-key/opmesh/36" || provstore.TxnPresent(r.n.P) {
		t.Fatalf("forgets +%d wl=%s txn=%v (want the operator's settings back)", r.sys.forgets-f, r.wl(), provstore.TxnPresent(r.n.P))
	}
}

// review 2 B m1 / A: a transient failure of the restorability check keeps .txn (no forget, nothing saved)
func TestTransientRestoreCheckKeepsTxn(t *testing.T) {
	r := claimedRig(t)
	r.sys.wl = [3]string{"operator-key", "opmesh", "36"}
	r.crashTxn2("sae-v1-pass", "m1", "28")
	r.sys.restorableErr = errors.New("halow-setkey --check-only rc=124: timed out")
	if err := r.fin(); err == nil {
		t.Fatal("Finish succeeded on a transient check failure")
	}
	if r.sys.forgets != 0 || !provstore.TxnPresent(r.n.P) || len(r.sys.saveTxns) != 0 {
		t.Fatalf("forgets=%d txn=%v saves=%v", r.sys.forgets, provstore.TxnPresent(r.n.P), r.sys.saveTxns)
	}
	r.sys.restorableErr = nil
	if err := r.fin(); err != nil {
		t.Fatal(err)
	}
	r.finishedCleanly("operator-key/opmesh/36")
}

// review 2 A MAJOR-1: the backoff doubles per consecutive failure; the boot Finish's failure counts
func TestBackoffDoublesAndCountsTheBootFinish(t *testing.T) {
	r, _ := memberRig(t)
	r.crashTxn2("sae-v2-pass", "m2", "36")
	dead := func() { r.sys.setkeyErrs = []error{&SetkeyError{RC: 3}, &SetkeyError{RC: 3}, &SetkeyError{RC: 3}} }
	dead()
	r.n.BootFinish(func() {})
	r.n.mu.Lock() // wait for the boot Finish
	r.n.mu.Unlock()
	sk := len(r.sys.setkeys)
	r.sys.now = r.sys.now.Add(30 * time.Second)
	if c := r.sshSet(); c != EState || len(r.sys.setkeys) != sk {
		t.Fatalf("30 s after a failed boot Finish: code %d setkeys +%d (want EState, none)", c, len(r.sys.setkeys)-sk)
	}
	r.sys.now = r.sys.now.Add(31 * time.Second) // 61 s: retried, fails again
	dead()
	if c := r.sshSet(); c != EState || len(r.sys.setkeys) == sk {
		t.Fatalf("61 s: code %d setkeys +%d (want a retry that fails)", c, len(r.sys.setkeys)-sk)
	}
	sk = len(r.sys.setkeys)
	r.sys.now = r.sys.now.Add(61 * time.Second) // second failure: 120 s backoff
	if c := r.sshSet(); c != EState || len(r.sys.setkeys) != sk {
		t.Fatalf("61 s after the 2nd failure: setkeys +%d (want none: the backoff doubled)", len(r.sys.setkeys)-sk)
	}
	r.sys.setkeyErrs = nil
	r.sys.now = r.sys.now.Add(60 * time.Second)
	if c := r.sshSet(); c != OK {
		t.Fatalf("after the doubled backoff: %d", c)
	}
	if r.n.finishFails != 0 {
		t.Fatal("a successful Finish did not reset the backoff")
	}
}

// review 2 B m2: "unverified" survives a helper restart (run dir), so the next Finish re-applies
func TestUnverifiedSurvivesHelperRestart(t *testing.T) {
	r, _ := memberRig(t)
	r.crashTxn2("sae-v2-pass", "m2", "36")
	r.sys.setkeyErrs = []error{&SetkeyError{RC: 3, Msg: "unverified"}}
	if err := r.fin(); err == nil {
		t.Fatal("Finish succeeded on rc 3")
	}
	r.restart() // the helper restarts (not the node): uci already holds the record's values
	sk := len(r.sys.setkeys)
	if err := r.fin(); err != nil || len(r.sys.setkeys) != sk+1 {
		t.Fatalf("after a restart: %v, setkeys +%d (want a re-apply)", err, len(r.sys.setkeys)-sk)
	}
}

// review 2 A minor: the radio switched off by hand while .txn is pending — the previous state goes into uci and Finish
// completes (nothing is on the air to verify); with uci already right it is "already"
func TestHandOffRadioDuringPendingFinish(t *testing.T) {
	r, _ := memberRig(t)
	r.crashTxn2("sae-v2-pass", "m2", "36")
	r.sys.radioOff, r.sys.inMark = true, false
	r.sys.setkeyErrs = []error{&SetkeyError{RC: 3, Msg: "radio off: not verified"}}
	if err := r.fin(); err != nil {
		t.Fatalf("Finish with the radio off by hand: %v", err)
	}
	r.finishedCleanly("sae-v1-pass/m1/28")
	r2, _ := memberRig(t)
	r2.crashTxn2("sae-v1-pass", "m1", "28")
	r2.sys.radioOff, r2.sys.inMark = true, false
	sk := len(r2.sys.setkeys)
	if err := r2.fin(); err != nil || len(r2.sys.setkeys) != sk {
		t.Fatalf("uci already right, radio off: %v setkeys +%d", err, len(r2.sys.setkeys)-sk)
	}
}

// review 2 A/B m3: the mutex is held when BootFinish returns (deterministic: TryLock)
func TestBootFinishHoldsTheMutexOnReturn(t *testing.T) {
	r, _ := memberRig(t)
	r.crashTxn2("sae-v2-pass", "m2", "36")
	release := make(chan struct{})
	r.n.BootFinish(func() { <-release })
	if r.n.mu.TryLock() {
		r.n.mu.Unlock()
		t.Fatal("the mutex was free when BootFinish returned")
	}
	close(release)
	r.n.mu.Lock()
	r.n.mu.Unlock()
}

// review 2 B m5: rc 6 from the save (p5 cannot carry a value; the record and overlay still saved) finishes
func TestFinishSaveRC6Finishes(t *testing.T) {
	r, _ := memberRig(t)
	r.crashTxn2("sae-v2-pass", "m2", "36")
	r.sys.saveTxnOut = []saveRC{{6, "unpersistable"}}
	if err := r.fin(); err != nil {
		t.Fatal(err)
	}
	r.finishedCleanly("sae-v1-pass/m1/28")
}

// review 2 B / A (wants-radio mutants, B m5 round 1): what the boot waits for
func TestFinishWantsRadio(t *testing.T) {
	r, _ := memberRig(t)
	r.crashTxn2("sae-v2-pass", "m2", "36")
	if !r.n.finishWantsRadio() {
		t.Fatal("member, radio on: must wait for the radio")
	}
	r.sys.radioOff, r.sys.inMark = true, false
	if r.n.finishWantsRadio() {
		t.Fatal("radio off by hand: it will not come up — must not wait")
	}
	r.sys.radioOff, r.sys.inMark = true, true
	if r.n.finishWantsRadio() {
		t.Fatal("radio blocked by the keyguard: must not wait")
	}
	r2 := claimedRig(t)
	r2.sys.wl = [3]string{placeholderKey, "", ""}
	r2.crashTxn2("sae-v1-pass", "m1", "28")
	if r2.n.finishWantsRadio() {
		t.Fatal("a forget must not wait for the radio")
	}
}

// review 2 B minor: a commit-only verb with a bad owner-op mounts nothing (resolve runs after the check)
func TestCommitOnlyResolveAfterAuth(t *testing.T) {
	r, _ := memberRig(t)
	g := r.sys.getP5s
	other := newKey()
	saved := r.owner
	r.owner = other // signs with a key that is not an owner
	if c := r.ownerAdd(); c != EForbidden {
		t.Fatalf("owner.add by a non-owner: %d", c)
	}
	r.owner = saved
	if r.sys.getP5s != g {
		t.Fatalf("a refused owner-op mounted p5 %d time(s)", r.sys.getP5s-g)
	}
	_ = strings.TrimSpace
}
