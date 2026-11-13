//go:build prov_test

package node

import (
	"testing"

	"batman-prov/provstore"
)

// U9: a power loss inside network/update (the existing seam tests only go through join): stopped before the commit
// (txn-2) -> Finish goes back to v1; at or after it (txn-3: p5 is the commit point, txn-4) -> forward to v2
func TestUpdatePowerLoss(t *testing.T) {
	for _, tc := range []struct {
		point, wl string
		ver       uint64
	}{{"txn-2", "sae-v1-pass/m1/28", 1}, {"txn-3", "sae-v2-pass/m2/36", 2}, {"txn-4", "sae-v2-pass/m2/36", 2}} {
		r, v1 := memberRig(t)
		v2 := r.next(v1, 2, nil)
		stopAt(t, r, tc.point, func() { r.applyUpdate(v2) })
		r.restart()
		if err := r.fin(); err != nil {
			t.Fatalf("%s: Finish: %v", tc.point, err)
		}
		rec, _, err := provstore.LoadOverlay(r.n.P)
		if err != nil {
			t.Fatal(err)
		}
		if provstore.TxnPresent(r.n.P) || r.wl() != tc.wl || rec.Net.Version != tc.ver {
			t.Fatalf("%s: txn=%v wl=%s version=%d, want %s / %d", tc.point, provstore.TxnPresent(r.n.P), r.wl(), rec.Net.Version, tc.wl, tc.ver)
		}
	}
}
