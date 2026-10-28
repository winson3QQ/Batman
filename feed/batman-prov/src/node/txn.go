package node

import (
	"os"
	"path/filepath"
	"strings"

	"batman-prov/provstore"
	"batman-prov/seam"
)

// commit persists a new record to p5 and then the overlay (no wireless side effect: claim, owners, ssh keys, leave).
func (n *Node) commit(next *provstore.Record, what string) *Error {
	return n.commitTxn(next, "", seam.None) // no killpoint: only claimVerify and applyNet name one (254-h23 §4.1.1)
}

// commitTxn = §4.4 steps 3–4: stage, --prov-only, on rc != 0 read the generation back to decide, then the overlay.
func (n *Node) commitTxn(next *provstore.Record, token string, afterPersist seam.Point) *Error {
	stage := n.P.Stage()
	os.RemoveAll(stage)
	if err := os.MkdirAll(stage, 0o700); err != nil {
		return fail(EApply, "stage: %v", err)
	}
	defer os.RemoveAll(stage)
	sp := provstore.Paths{Dir: stage}
	if _, _, err := provstore.WriteOverlay(sp, next); err != nil {
		return fail(EApply, "stage: %v", err)
	}
	rc, out := n.Sys.Persist(sp.Record(), sp.Meta(), "", token)
	if rc != 0 {
		g, ok := n.p5Generation()
		if !ok || g != next.Generation {
			return fail(EStorage, "--prov-only rc=%d (%s); p5 generation %d", rc, strings.TrimSpace(out), g)
		}
		n.Log("--prov-only rc=%d but p5 holds generation %d: committed", rc, g)
	}
	seam.At(afterPersist, n.Log) // txn-3 / claim-after-persist: p5 holds the new generation (also after rc != 0 + read-back), the overlay does not
	if _, _, err := provstore.WriteOverlay(n.P, next); err != nil {
		// p5 is ahead now; the next --boot rebuilds the overlay from it (§4.4 step 7)
		n.Log("overlay write after a committed p5 write failed: %v", err)
	}
	return nil
}

func (n *Node) p5Generation() (uint64, bool) {
	d, err := os.MkdirTemp(n.P.RunDir, "provget.")
	if err != nil {
		return 0, false
	}
	os.Remove(d)
	defer os.RemoveAll(d)
	if rc, _ := n.Sys.GetP5(d); rc != 0 && rc != 13 {
		return 0, false
	}
	b, err := os.ReadFile(filepath.Join(d, "prov.meta"))
	if err != nil {
		return 0, false
	}
	m, err := provstore.ParseMeta(b)
	if err != nil {
		return 0, false
	}
	return m.Gen, true
}
