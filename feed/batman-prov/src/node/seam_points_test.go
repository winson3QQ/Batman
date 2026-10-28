//go:build prov_test

package node

import (
	"os"
	"sort"
	"testing"

	"batman-prov/cbor"
	"batman-prov/provstore"
	"batman-prov/seam"
)

// 254-h23 §4.1.1 / §6.2: each killpoint sits at one exact place of a transaction. These tests stop the transaction
// at the armed point (the reboot is replaced by a panic) and assert what is on "disk" at that instant, so moving a
// seam.At call, or dropping one, turns them red (code review A-M3).

type fired struct{ name string }

type snap struct {
	gen       uint64
	state     string
	txn       bool
	persisted int
	setkeys   int
	saves     int
	root      string
	lastKnown string
	lockCalls int
}

func (r *rig) snap() snap {
	rec, _, err := provstore.LoadOverlay(r.n.P)
	if err != nil {
		r.t.Fatalf("overlay: %v", err)
	}
	_, terr := os.Stat(r.n.P.Txn())
	return snap{rec.Generation, rec.State, terr == nil, len(r.sys.persisted), len(r.sys.setkeys), r.sys.saves,
		r.sys.root, r.sys.lastKnown, len(r.sys.lockCalls)}
}

// stopAt arms point, runs op, and returns the state seen at the point; it fails the test if the point never fires.
func stopAt(t *testing.T, r *rig, point string, op func()) snap {
	t.Helper()
	var at snap
	restore := seam.ArmForTest(point, func(n string) {
		if n != point {
			t.Fatalf("fired %s, armed %s", n, point)
		}
		at = r.snap()
		panic(fired{n})
	})
	defer restore()
	got := ""
	func() {
		defer func() {
			if x := recover(); x != nil {
				f, ok := x.(fired)
				if !ok {
					panic(x)
				}
				got = f.name
			}
		}()
		op()
	}()
	if got != point {
		t.Fatalf("killpoint %s never fired", point)
	}
	return at
}

// neverFires arms every point in turn and asserts op reaches none of them.
func neverFires(t *testing.T, mk func() *rig, op func(r *rig), what string) {
	t.Helper()
	names := seam.Names()
	sort.Strings(names)
	for _, p := range names {
		r := mk()
		restore := seam.ArmForTest(p, func(n string) { t.Fatalf("%s reached killpoint %s", what, n) })
		op(r)
		restore()
	}
}

func testNet() *parsedNet {
	return &parsedNet{cfgRaw: []byte{0xa0}, secRaw: []byte{0xa0}, netID: make32(3)[:16], version: 1,
		admins: [][]byte{make([]byte, 65)}, meshID: "m1", channel: "28", sae: "saepassword"}
}

func (r *rig) join() *Error {
	rec, _, err := provstore.LoadOverlay(r.n.P)
	if err != nil {
		r.t.Fatal(err)
	}
	_, e := r.n.applyNet(rec, testNet(), "network/join")
	return e
}

func TestKillpointTxnPositions(t *testing.T) {
	// before: claimed (generation 2), one persist, no setkey, no .txn
	base := func() (*rig, snap) {
		r := claimedRig(t)
		return r, r.snap()
	}
	r, b := base()
	s := stopAt(t, r, "txn-1", func() { r.join() })
	if !s.txn || s.setkeys != b.setkeys || s.persisted != b.persisted || s.gen != b.gen || s.state != provstore.Claimed {
		t.Fatalf("txn-1: %+v (before %+v): want .txn written, wireless/p5/overlay untouched", s, b)
	}
	r, b = base()
	s = stopAt(t, r, "txn-2", func() { r.join() })
	if !s.txn || s.setkeys != b.setkeys+1 || s.persisted != b.persisted || s.gen != b.gen {
		t.Fatalf("txn-2: %+v (before %+v): want setkey done, p5 and overlay not", s, b)
	}
	r, b = base()
	s = stopAt(t, r, "txn-3", func() { r.join() })
	if !s.txn || s.persisted != b.persisted+1 || r.sys.persisted[len(r.sys.persisted)-1] != b.gen+1 || s.gen != b.gen || s.state != provstore.Claimed {
		t.Fatalf("txn-3: %+v (before %+v): want p5 at gen %d, overlay still gen %d", s, b, b.gen+1, b.gen)
	}
	r, b = base()
	s = stopAt(t, r, "txn-4", func() { r.join() })
	if s.txn || s.gen != b.gen+1 || s.state != provstore.Member || s.saves != b.saves {
		t.Fatalf("txn-4: %+v (before %+v): want overlay member gen %d, .txn gone, no --save yet", s, b, b.gen+1)
	}
	r, b = base()
	s = stopAt(t, r, "txn-5", func() { r.join() })
	if s.txn || s.gen != b.gen+1 || s.state != provstore.Member || s.saves != b.saves+1 {
		t.Fatalf("txn-5: %+v (before %+v): want --save done", s, b)
	}
}

func TestKillpointClaimPositions(t *testing.T) {
	r := newRig(t, provstore.Unclaimed)
	s := stopAt(t, r, "claim-after-persist", func() { r.claim() })
	if s.persisted != 1 || r.sys.persisted[0] != 2 || s.gen != 1 || s.state != provstore.Unclaimed || s.lockCalls != 0 || s.lastKnown != "" {
		t.Fatalf("claim-after-persist: %+v: want p5 gen 2, overlay still unclaimed gen 1, nothing locked", s)
	}
	r = newRig(t, provstore.Unclaimed)
	s = stopAt(t, r, "claim-before-shadow", func() { r.claim() })
	if s.gen != 2 || s.state != provstore.Claimed || s.lastKnown != provstore.Claimed || s.lockCalls != 0 || s.root != "" {
		t.Fatalf("claim-before-shadow: %+v: want claimed in overlay + p6, no lock call, root untouched", s)
	}
}

// Paths that must reach no killpoint: claim.replay, ssh_keys.set, root_password.reset, and commit (leave, ssh_keys,
// owner.add, owner.remove share it with claim). A claim reaches no txn point, a join no claim point.
func TestKillpointsNotOnOtherPaths(t *testing.T) {
	neverFires(t, func() *rig { return claimedRig(t) }, func(r *rig) {
		if c, _ := r.replay(); c != OK {
			t.Fatalf("replay %d", c)
		}
	}, "claim.replay")
	neverFires(t, func() *rig { return claimedRig(t) }, func(r *rig) {
		keys := []any{"ssh-ed25519 AAAAC3Nz owner"}
		if c, _ := r.call("ssh_keys.set", cbor.M(1, r.h, 2, r.envelope("ssh_keys/set", cbor.M(1, keys), r.owner))); c != OK {
			t.Fatalf("ssh_keys.set %d", c)
		}
		if c, _ := r.call("root_password.reset", cbor.M(1, r.h, 2, r.envelope("root_password/reset", cbor.M(), r.owner))); c != OK {
			t.Fatalf("root_password.reset %d", c)
		}
	}, "ssh_keys.set / root_password.reset")
	neverFires(t, func() *rig { return claimedRig(t) }, func(r *rig) {
		rec, _, _ := provstore.LoadOverlay(r.n.P)
		for _, what := range []string{"leave", "ssh_keys", "owner.add", "owner.remove"} {
			next := *rec
			next.Generation++
			if e := r.n.commit(&next, what); e != nil {
				t.Fatalf("commit %s: %v", what, e)
			}
			rec = &next
		}
	}, "commit (leave / ssh_keys / owner.add / owner.remove)")
	for _, p := range []string{"txn-1", "txn-2", "txn-3", "txn-4", "txn-5"} {
		r := newRig(t, provstore.Unclaimed)
		restore := seam.ArmForTest(p, func(n string) { t.Fatalf("claim reached %s", n) })
		if c, _ := r.claim(); c != OK {
			t.Fatalf("claim %d", c)
		}
		restore()
	}
	for _, p := range []string{"claim-after-persist", "claim-before-shadow"} {
		r := claimedRig(t)
		restore := seam.ArmForTest(p, func(n string) { t.Fatalf("join reached %s", n) })
		if e := r.join(); e != nil {
			t.Fatalf("join: %v", e)
		}
		restore()
	}
}

// txn-3 fires also when --prov-only fails AFTER p5 was written: commitTxn reads the generation back, finds it
// committed, and goes on (§16.5) — r2 B-m1.
func TestKillpointTxn3AfterLateProvOnlyFailure(t *testing.T) {
	r := claimedRig(t)
	b := r.snap()
	r.sys.persistLateRC = 5
	s := stopAt(t, r, "txn-3", func() { r.join() })
	if s.persisted != b.persisted+1 || r.sys.persisted[len(r.sys.persisted)-1] != b.gen+1 || s.gen != b.gen || !s.txn {
		t.Fatalf("txn-3 after a late --prov-only failure: %+v (before %+v)", s, b)
	}
}
