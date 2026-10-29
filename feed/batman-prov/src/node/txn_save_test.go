package node

import (
	"testing"

	"batman-prov/provstore"
)

// TestJoinSavesUnderItsToken: batman-config-save --save refuses while a transaction is live (the run-dir marker or
// .txn) — 04, 2026-10-28: every join left p5 stale; 2026-10-29 (M6): an unfinished .txn deadlocked every later save.
// A join now saves with `--save --txn <token>` while the marker and .txn still hold it, and only then drops .txn
// (docs/design/254-wireless-txn.md §3, §7).
func TestJoinSavesUnderItsToken(t *testing.T) {
	r := claimedRig(t)
	rec, _, err := provstore.LoadOverlay(r.n.P)
	if err != nil {
		t.Fatal(err)
	}
	saves := r.sys.saves
	net := &parsedNet{cfgRaw: []byte{0xa0}, secRaw: []byte{0xa0}, netID: make([]byte, 16), version: 1,
		admins: [][]byte{make([]byte, 65)}, meshID: "m1", channel: "28", sae: "saepassword"}
	if _, e := r.n.applyNet(rec, net, "network/join"); e != nil {
		t.Fatalf("join: %v", e)
	}
	if len(r.sys.saveTxns) != 1 || len(r.sys.saveTxns[0]) != 32 {
		t.Fatalf("join saves %v: want one --save --txn <token>", r.sys.saveTxns)
	}
	if r.sys.saveTxnNoMark != 0 || r.sys.saves != saves {
		t.Fatalf("save without the marker (%d) or a plain --save (%d): config-save refuses it", r.sys.saveTxnNoMark, r.sys.saves-saves)
	}
	if r.sys.txnMarker || provstore.TxnPresent(r.n.P) {
		t.Fatal("txn marker or .txn left after the join")
	}
}
