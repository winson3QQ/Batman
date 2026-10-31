package node

import (
	"os"
	"testing"
	"time"

	"batman-prov/provstore"
)

// review 3 A m5: the backoff stops at its cap
func TestBackoffCap(t *testing.T) {
	r, _ := memberRig(t)
	r.n.finishFails = 40
	if d := r.n.backoff(); d != finishBackoffMax {
		t.Fatalf("backoff after 40 failures: %s (want %s)", d, finishBackoffMax)
	}
	r.n.finishFails = 2
	if d := r.n.backoff(); d != 2*finishBackoff {
		t.Fatalf("backoff after 2 failures: %s", d)
	}
}

// review 3 A m5 (the uciIs condition): a radio switched off by hand and a setkey that ended rc 3 with uci NOT at the
// previous state is a failure (.txn kept), not "applied"
func TestHandOffRC3WrongUciFails(t *testing.T) {
	r, _ := memberRig(t)
	r.crashTxn2("sae-v2-pass", "m2", "36")
	r.sys.radioOff, r.sys.inMark = true, false
	r.sys.setkeyErrs = []error{&SetkeyError{RC: 3}}
	r.sys.setkeyLands = &[3]string{"something-else", "mx", "40"}
	if err := r.fin(); err == nil {
		t.Fatal("Finish took a wrong uci as applied")
	}
	if !provstore.TxnPresent(r.n.P) {
		t.Fatal(".txn removed")
	}
}

// review 3 B m3: after a leave the operator set their own mesh — the boot waits for the radio (it rejoins the
// operator's mesh), unless the radio is off
func TestFinishWantsRadioOperatorAfterLeave(t *testing.T) {
	r, _ := memberRig(t)
	if c := r.leave(); c != OK {
		t.Fatalf("leave: %d", c)
	}
	r.sys.wl = [3]string{"operator-key", "opmesh", "36"}
	r.sys.radioOff, r.sys.inMark = false, false
	r.crashTxn2("sae-n1-pass", "n1", "28")
	if !r.n.finishWantsRadio() {
		t.Fatal("the operator's mesh after a leave: must wait for the radio")
	}
	_ = time.Second
}

// review 4 A m6 / B m9: no join / update / leave while batman-slot writes the other slot (its .txn gate already ran)
func TestNoWirelessChangeDuringOTA(t *testing.T) {
	r := claimedRig(t)
	busy := r.n.P.RunDir + "/batman-slot.busy"
	writeFile(t, busy, nil)
	if c := r.applyJoin(r.v1Net()); c != EBusy {
		t.Fatalf("join during an OTA: %d (want EBusy)", c)
	}
	if len(r.sys.setkeys) != 0 || provstore.TxnPresent(r.n.P) {
		t.Fatal("something changed")
	}
	if c := r.sshSet(); c != OK { // other verbs are not affected
		t.Fatalf("ssh_keys.set during an OTA: %d", c)
	}
	removeFile(busy)
	if c := r.applyJoin(r.v1Net()); c != OK {
		t.Fatalf("join after the OTA: %d", c)
	}
	if c := r.leave(); c != OK {
		t.Fatalf("leave: %d", c)
	}
}

func removeFile(p string) { _ = os.Remove(p) }
