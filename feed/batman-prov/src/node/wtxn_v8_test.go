package node

import (
	"crypto/ecdsa"
	"errors"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"batman-prov/cbor"
	"batman-prov/provstore"
)

// docs/design/254-wireless-txn.md §15 (code review round 1): one test per surviving mutant of reviews A and B, and
// per v8 change. Each names the mutant / finding it kills.

// A MAJOR-3(a): admin handover at v2, crash right after (the stored v2 is signed by v1's admin, not in rec.Admins)
func TestHandoverThenCrashAfterV2(t *testing.T) {
	r, v1 := memberRig(t)
	b := newKey()
	v2 := r.mkNet(&netv{nid: v1.nid, ver: 2, meshID: "m2", ch: 36, sae: "sae-v2-pass", admins: []*ecdsa.PrivateKey{b}, signer: v1.admins[0], prev: v1.cfg})
	if c := r.applyUpdate([]any{v2.cfg}, v2.secrets); c != OK {
		t.Fatalf("update v2: %d", c)
	}
	r.crashTxn2("sae-v3-pass", "m3", "28")
	if err := r.fin(); err != nil {
		t.Fatalf("Finish after the handover at v2: %v", err)
	}
	r.finishedCleanly("sae-v2-pass/m2/36")
}

// A MAJOR-3(b) / B m7 finish-save-ignored, finish-remove-before-save: a failed save keeps .txn; the next Finish saves
func TestFinishSaveFailureKeepsTxn(t *testing.T) {
	r, _ := memberRig(t)
	r.crashTxn2("sae-v2-pass", "m2", "36")
	r.sys.saveTxnOut = []saveRC{{1, "p5 busy"}}
	if err := r.fin(); err == nil {
		t.Fatal("Finish reported success although its save failed")
	}
	if !provstore.TxnPresent(r.n.P) {
		t.Fatal(".txn removed although the save failed")
	}
	if err := r.fin(); err != nil {
		t.Fatal(err)
	}
	r.finishedCleanly("sae-v1-pass/m1/28")
}

// A MAJOR-3(c): leave whose save fails keeps .txn (the next Finish saves)
func TestLeaveSaveFailureKeepsTxn(t *testing.T) {
	r, _ := memberRig(t)
	r.sys.saveTxnOut = []saveRC{{1, "p5 busy"}}
	if c := r.leave(); c != OK {
		t.Fatalf("leave: %d", c)
	}
	if !provstore.TxnPresent(r.n.P) {
		t.Fatal(".txn removed although leave's save failed")
	}
}

// A MAJOR-3(d): a join whose commit fails after the live change goes back to the previous state at once
func TestJoinCommitFailureFinishes(t *testing.T) {
	r := claimedRig(t)
	r.sys.wl = [3]string{"operator-key", "opmesh", "36"}
	v1 := r.v1Net()
	r.sys.persistRC = 1
	if c := r.applyJoin(v1); c == OK {
		t.Fatal("join succeeded without a commit")
	}
	r.sys.persistRC = 0
	if provstore.TxnPresent(r.n.P) || r.wl() != "operator-key/opmesh/36" || r.rec().State != provstore.Claimed {
		t.Fatalf("txn=%v wl=%s state=%s", provstore.TxnPresent(r.n.P), r.wl(), r.rec().State)
	}
}

// A MAJOR-3(e) / B m7 finish-no-meshmarkers, leave-no-meshmarkers
func TestMeshMarkersRemovedOnForget(t *testing.T) {
	r, _ := memberRig(t)
	if c := r.leave(); c != OK || r.sys.markersRemoved != 1 {
		t.Fatalf("leave: code %d, markers removed %d", c, r.sys.markersRemoved)
	}
	// a crash after the commit: Finish forgets and removes the markers too
	r2, _ := memberRig(t)
	r2.sys.forgetErr = &SetkeyError{RC: 2, Msg: "busy"}
	if c := r2.leave(); c != EApply {
		t.Fatalf("leave with a busy setkey: %d", c)
	}
	r2.sys.forgetErr = nil
	m := r2.sys.markersRemoved
	r2.restart()
	if err := r2.fin(); err != nil || r2.sys.markersRemoved != m+1 {
		t.Fatalf("Finish: %v, markers removed %d -> %d", err, m, r2.sys.markersRemoved)
	}
}

// A MAJOR-1 / B satisfied-noblock, satisfied-forget-nomark: a forget is never "already" — --forget-mesh is the only
// verification that the radio is down; a leave whose forget ended rc 3 (uci committed, not verified) is retried
func TestForgetAlwaysVerified(t *testing.T) {
	r, _ := memberRig(t)
	r.sys.forgetErr = &SetkeyError{RC: 3, Msg: "radio not down within 30 s"}
	if c := r.leave(); c != EApply {
		t.Fatalf("leave: %d", c)
	}
	if !strings.HasPrefix(r.wl(), placeholderKey+"/") || !r.sys.radioOff {
		t.Fatal("precondition: the fake's rc 3 committed uci like the script")
	}
	r.sys.forgetErr = nil
	if c := r.leave(); c != EForbidden { // the retry: Finish first, then "not a member"
		t.Fatalf("retried leave: %d", c)
	}
	if r.sys.forgets != 2 || provstore.TxnPresent(r.n.P) {
		t.Fatalf("forgets=%d txn=%v: the unverified forget was taken as done", r.sys.forgets, provstore.TxnPresent(r.n.P))
	}
}

// §15.4: a network is "already" only when the radio is live on it and nothing of this lifetime ended unverified
func TestSatisfiedNeedsLiveAndVerified(t *testing.T) {
	r, _ := memberRig(t)
	r.crashTxn2("sae-v1-pass", "m1", "28") // uci already the record's
	r.sys.liveDown = true                  // but the radio is not up on it
	sk := len(r.sys.setkeys)
	if err := r.fin(); err != nil || len(r.sys.setkeys) != sk+1 {
		t.Fatalf("live down: %v, setkeys +%d (want a re-apply)", err, len(r.sys.setkeys)-sk)
	}
	// an unverified apply (rc 3) in this lifetime: the next Finish re-applies even though uci and live match
	r2, _ := memberRig(t)
	r2.crashTxn2("sae-v2-pass", "m2", "36")
	r2.sys.setkeyErrs = []error{&SetkeyError{RC: 3, Msg: "unverified"}}
	if err := r2.fin(); err == nil {
		t.Fatal("Finish succeeded on an unverified setkey")
	}
	sk = len(r2.sys.setkeys)
	if err := r2.fin(); err != nil || len(r2.sys.setkeys) != sk+1 {
		t.Fatalf("after an unverified apply: %v, setkeys +%d (want a re-apply)", err, len(r2.sys.setkeys)-sk)
	}
}

// B BLOCKER-1 / m10 / desired-empty-key-net: a join whose previous state (the operator's) halow-setkey could not put
// back is refused before anything changes
func TestJoinRefusedWhenSnapshotUnrestorable(t *testing.T) {
	for _, c := range []struct {
		wl  [3]string
		enc string
	}{
		{[3]string{"op&erator1", "opmesh", "36"}, ""},
		{[3]string{"short7x", "opmesh", "36"}, ""},
		{[3]string{"operator-key", "opmesh", "auto"}, ""},
		{[3]string{"operator-key", "opmesh", "36"}, "psk2"},
	} {
		r := claimedRig(t)
		r.sys.wl, r.sys.encryption = c.wl, c.enc
		if code := r.applyJoin(r.v1Net()); code != EApply {
			t.Fatalf("%v/%s: join %d (want EApply)", c.wl, c.enc, code)
		}
		if len(r.sys.setkeys) != 0 || provstore.TxnPresent(r.n.P) || r.rec().State != provstore.Claimed {
			t.Fatalf("%v/%s: something changed", c.wl, c.enc)
		}
	}
	// an empty key (open mesh) too — CurrentWireless reports "" only when uci holds no key
	r := claimedRig(t)
	r.sys.restorableErr = errors.New("no mesh key (open mesh)")
	r.sys.wl = [3]string{"x", "opmesh", "36"} // any non-placeholder value; the real check sees ""
	if code := r.applyJoin(r.v1Net()); code != EApply {
		t.Fatalf("open mesh: join %d", code)
	}
}

// B BLOCKER-1: a .txn already holding an unrestorable snapshot (an older helper wrote it) is finished by forgetting —
// in-band exit, saving verbs work again
func TestExistingUnrestorableSnapshotForgets(t *testing.T) {
	r := claimedRig(t)
	r.sys.wl = [3]string{"op&erator1", "opmesh", "36"}
	r.crashTxn2("sae-v1-pass", "m1", "28")
	if err := r.fin(); err != nil {
		t.Fatalf("Finish: %v", err)
	}
	if r.sys.forgets != 1 || !strings.HasPrefix(r.wl(), placeholderKey+"/") || provstore.TxnPresent(r.n.P) {
		t.Fatalf("forgets=%d wl=%s txn=%v", r.sys.forgets, r.wl(), provstore.TxnPresent(r.n.P))
	}
	if c := r.sshSet(); c != OK {
		t.Fatalf("ssh_keys.set after: %d", c)
	}
}

// B m7 resolve-p5-fail-open: p5 rc 8 / 10 / 14 is unreadable too
func TestFinishP5OtherRCsKeepTxn(t *testing.T) {
	for _, rc := range []int{8, 10, 14, provstore.RCTimeout} {
		r, _ := memberRig(t)
		r.crashTxn2("sae-v2-pass", "m2", "36")
		r.sys.p5rc = rc
		if err := r.fin(); err == nil || !provstore.TxnPresent(r.n.P) || r.sys.txnMarker {
			t.Fatalf("p5 rc %d: err=%v txn=%v marker=%v", rc, err, provstore.TxnPresent(r.n.P), r.sys.txnMarker)
		}
	}
}

// A m3: p5 rc 0 with a record that does not decode is unreadable, not "use the overlay"
func TestFinishP5UndecodableKeepsTxn(t *testing.T) {
	r, _ := memberRig(t)
	r.crashTxn2("sae-v2-pass", "m2", "36")
	writeFile(t, r.sys.p5+"/prov.cbor", []byte{0xff, 0x00})
	if err := r.fin(); err == nil || !provstore.TxnPresent(r.n.P) {
		t.Fatalf("err=%v txn=%v", err, provstore.TxnPresent(r.n.P))
	}
}

// §15.2: the boot Finish holds the mutex from the moment BootFinish returns — a verb that arrives meanwhile waits
// for it and then sees the finished state
func TestBootFinishHoldsTheMutex(t *testing.T) {
	r, _ := memberRig(t)
	r.crashTxn2("sae-v2-pass", "m2", "36")
	release := make(chan struct{})
	r.n.BootFinish(func() { <-release })
	got := make(chan string, 1)
	go func() {
		code, _ := r.call("info.net", cbor.M())
		state := "done"
		if provstore.TxnPresent(r.n.P) {
			state = "txn"
		}
		got <- fmt.Sprintf("%s %s %d", r.wl(), state, code)
	}()
	select {
	case s := <-got:
		t.Fatalf("a verb ran during the boot Finish: %s", s)
	case <-time.After(300 * time.Millisecond):
	}
	close(release)
	select {
	case s := <-got:
		if s != fmt.Sprintf("sae-v1-pass/m1/28 done %d", OK) {
			t.Fatalf("after the boot Finish: %s", s)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the verb never ran")
	}
}

func writeFile(t *testing.T, p string, b []byte) {
	t.Helper()
	if err := os.WriteFile(p, b, 0o600); err != nil {
		t.Fatal(err)
	}
}

// A m4 / B m12: a successful join refreshes prov-state mesh_expect
func TestJoinRefreshesMeshExpect(t *testing.T) {
	r, _ := memberRig(t)
	if r.sys.meshExpect != "radio" {
		t.Fatalf("mesh_expect after the join: %q", r.sys.meshExpect)
	}
}

// A MAJOR-3(f): the stored secrets must be addressed to THIS node (the DAC target)
func TestStoredSecretsOtherTargetRefused(t *testing.T) {
	r, _ := memberRig(t)
	rec := r.rec()
	other := claimedRig(t) // a different node: its keystore decrypts nothing of r's
	if pt := other.n.openStoredSecrets(rec.Net.Secrets); pt != nil {
		t.Fatal("another node opened these stored secrets")
	}
	if pt := r.n.openStoredSecrets(rec.Net.Secrets); pt == nil {
		t.Fatal("this node cannot open its own stored secrets")
	}
}
