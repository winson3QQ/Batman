package node

import (
	"testing"

	"batman-prov/provstore"
)

// TestSaveRunsWithoutTheTxnMarker: batman-config-save --save waits for the txn marker ($RUNDIR/prov-txn) and gives up
// after 10 s (batman-config-save:162-167). applyNet must clear its marker BEFORE its own --save, or every join /
// update leaves the p5 overrides stale — 04, 2026-10-28 (#254 prov-netjoin-254, reproduced twice): "network/join:
// --save rc=1 (batman-config-save: provisioning transaction still in progress after 10 s — not saving)".
func TestSaveRunsWithoutTheTxnMarker(t *testing.T) {
	r := claimedRig(t)
	rec, _, err := provstore.LoadOverlay(r.n.P)
	if err != nil {
		t.Fatal(err)
	}
	net := &parsedNet{cfgRaw: []byte{0xa0}, secRaw: []byte{0xa0}, netID: make([]byte, 16), version: 1,
		admins: [][]byte{make([]byte, 65)}, meshID: "m1", channel: "28", sae: "saepassword"}
	if _, e := r.n.applyNet(rec, net, "network/join"); e != nil {
		t.Fatalf("join: %v", e)
	}
	if r.sys.saves == 0 {
		t.Fatal("join ran no --save")
	}
	if r.sys.saveUnderMarker != 0 {
		t.Fatalf("--save ran %d time(s) while applyNet's txn marker was still set (config-save refuses it)", r.sys.saveUnderMarker)
	}
	if r.sys.txnMarker {
		t.Fatal("txn marker left set after the join")
	}
}
