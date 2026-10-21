package boot

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"batman-prov/keystore"
	"batman-prov/provstore"
)

// fixture: a node with an overlay dir, a run dir, a p6 state dir, and a fake p5 that --prov-get copies out of.
type fx struct {
	t        *testing.T
	root     string
	e        Env
	p5       string // fake p5 contents: p5/prov.cbor, p5/prov.meta, p5/identity/
	p5rc     int
	persists []string
	gens     int
}

func newFx(t *testing.T, rc int) *fx {
	f := &fx{t: t, root: t.TempDir(), p5rc: rc}
	f.p5 = filepath.Join(f.root, "p5")
	os.MkdirAll(f.p5, 0o700)
	p := provstore.Paths{Dir: filepath.Join(f.root, "etc/batman-prov"), RunDir: filepath.Join(f.root, "run"), State: filepath.Join(f.root, "state")}
	os.MkdirAll(p.RunDir, 0o700)
	os.MkdirAll(p.State, 0o700)
	f.e = Env{
		P: p,
		GetP5: func(dir string) (int, string) {
			os.MkdirAll(dir, 0o700)
			for _, n := range []string{"prov.cbor", "prov.meta"} {
				if b, err := os.ReadFile(filepath.Join(f.p5, n)); err == nil {
					os.WriteFile(filepath.Join(dir, n), b, 0o600)
				}
			}
			if _, err := os.Stat(filepath.Join(f.p5, "identity")); err == nil {
				copyDir(filepath.Join(f.p5, "identity"), filepath.Join(dir, "identity"))
			}
			return f.p5rc, ""
		},
		Persist: func(r, m, id string) (int, string) { f.persists = append(f.persists, "id="+id); return 0, "" },
		Bypass:  func() bool { return false },
		BootID:  func() string { return "BOOT" },
		MeshKey: func() string { return "real-key" },
		Log:     func(string, ...any) {},
		Generate: func(d string) error {
			f.gens++
			return keystore.Generate(d)
		},
		Sleep: func(time.Duration) {},
	}
	return f
}

func (f *fx) overlayIdentity() { os.MkdirAll(f.e.P.Dir, 0o700); keystore.Generate(f.e.P.Identity()) }
func (f *fx) p5Identity()      { keystore.Generate(filepath.Join(f.p5, "identity")) }
func (f *fx) overlayRecord(st string, gen uint64) {
	provstore.WriteOverlay(f.e.P, &provstore.Record{State: st, Generation: gen, Owners: owners(st), Net: netFor(st)})
}
func (f *fx) p5Record(st string, gen uint64) {
	provstore.WriteOverlay(provstore.Paths{Dir: f.p5}, &provstore.Record{State: st, Generation: gen, Owners: owners(st), Net: netFor(st)})
}
func owners(st string) []provstore.Owner {
	if st == provstore.Claimed || st == provstore.Member {
		return []provstore.Owner{{Pub: bytes.Repeat([]byte{4}, 65), EncPub: bytes.Repeat([]byte{5}, 65), TagKey: bytes.Repeat([]byte{6}, 32)}}
	}
	return nil
}
func netFor(st string) *provstore.Net {
	if st == provstore.Member {
		return &provstore.Net{Config: []byte{1}, Secrets: []byte{2}, Version: 1, NetID: make([]byte, 16)}
	}
	return nil
}
func sum(dir string) []byte { b, _ := os.ReadFile(filepath.Join(dir, "sha256")); return b }

func TestNewCardGeneratesUnclaimed(t *testing.T) {
	f := newFx(t, 7)
	r := Run(f.e)
	if r.Verdict != provstore.Unclaimed || f.gens != 1 || len(f.persists) != 1 || f.persists[0] == "id=" {
		t.Fatalf("%+v gens=%d persists=%v", r, f.gens, f.persists)
	}
	ps, _ := os.ReadFile(filepath.Join(f.e.P.State, "prov-state"))
	if string(ps) != "BOOT helper unclaimed unclaimed - 0\n" {
		t.Fatalf("prov-state %q", ps)
	}
}

func TestLegacyUpgradeGeneratesLegacy(t *testing.T) {
	f := newFx(t, 9)
	if r := Run(f.e); r.Verdict != provstore.Legacy || f.gens != 1 {
		t.Fatalf("%+v gens=%d", r, f.gens)
	}
}

// rc 9 with a complete overlay record + identity: re-persist the whole record, NEVER generate (A11-m5)
func TestRc9KeepsOverlay(t *testing.T) {
	f := newFx(t, 9)
	f.overlayIdentity()
	f.overlayRecord(provstore.Claimed, 4)
	before := sum(f.e.P.Identity())
	r := Run(f.e)
	if r.Verdict != provstore.Claimed || f.gens != 0 || !bytes.Equal(before, sum(f.e.P.Identity())) || len(f.persists) != 1 {
		t.Fatalf("%+v gens=%d", r, f.gens)
	}
}

func TestRc0RestoresAndCompares(t *testing.T) {
	// overlay empty (fresh slot whose 96 did not copy): restore from p5
	f := newFx(t, 0)
	f.p5Identity()
	f.p5Record(provstore.Member, 5)
	r := Run(f.e)
	if r.Verdict != provstore.Member || !bytes.Equal(sum(f.e.P.Identity()), sum(filepath.Join(f.p5, "identity"))) || f.gens != 0 {
		t.Fatalf("restore: %+v", r)
	}
	// p5 newer -> overlay rebuilt
	f.p5Record(provstore.Member, 6)
	if r := Run(f.e); !strings.Contains(r.Action, "p5 newer") {
		t.Fatalf("p5 newer: %+v", r)
	}
	if rec, _, _ := provstore.LoadOverlay(f.e.P); rec.Generation != 6 {
		t.Fatal("overlay not rebuilt")
	}
	// overlay newer -> re-persist
	f.overlayRecord(provstore.Member, 9)
	n := len(f.persists)
	if r := Run(f.e); !strings.Contains(r.Action, "overlay newer") || len(f.persists) != n+1 {
		t.Fatalf("overlay newer: %+v", r)
	}
}

// P-U6 / B-N5: both identities complete and different -> frozen: no persist, no overlay change, verdict unknown
func TestIdentityMismatchFrozen(t *testing.T) {
	f := newFx(t, 0)
	f.overlayIdentity()
	f.overlayRecord(provstore.Claimed, 9) // overlay NEWER — a gen-first rule would have re-persisted it
	f.p5Identity()
	f.p5Record(provstore.Legacy, 1)
	before, _ := os.ReadFile(f.e.P.Meta())
	os.WriteFile(filepath.Join(f.e.P.State, "prov-state"), []byte("OLD helper claimed claimed - today\n"), 0o600)
	r := Run(f.e)
	after, _ := os.ReadFile(f.e.P.Meta())
	if r.Verdict != "unknown(identity-mismatch)" || len(f.persists) != 0 || !bytes.Equal(before, after) || f.gens != 0 {
		t.Fatalf("%+v persists=%v", r, f.persists)
	}
	ps, _ := os.ReadFile(filepath.Join(f.e.P.State, "prov-state"))
	if !strings.HasPrefix(string(ps), "BOOT helper claimed unknown(identity-mismatch)") {
		t.Fatalf("last_known_state not kept: %q", ps)
	}
}

func TestNoGenerationOnCorruptOrLost(t *testing.T) {
	for _, rc := range []int{10, 13, 1, 8, 11, 12, 14} {
		f := newFx(t, rc)
		r := Run(f.e)
		if f.gens != 0 || !strings.HasPrefix(r.Verdict, "unknown(") {
			t.Fatalf("rc %d: %+v gens=%d", rc, r, f.gens)
		}
	}
}

func TestBypassTouchesNothing(t *testing.T) {
	f := newFx(t, 7)
	called := false
	f.e.GetP5 = func(string) (int, string) { called = true; return 7, "" }
	f.e.Bypass = func() bool { return true }
	if r := Run(f.e); r.Verdict != "unknown(bypass)" || called || f.gens != 0 {
		t.Fatalf("%+v", r)
	}
}

func TestClaimedPlaceholderMeshExpect(t *testing.T) {
	f := newFx(t, 0)
	f.overlayIdentity()
	f.overlayRecord(provstore.Claimed, 2)
	copyDir(f.e.P.Identity(), filepath.Join(f.p5, "identity"))
	f.p5Record(provstore.Claimed, 2)
	f.e.MeshKey = func() string { return placeholder }
	Run(f.e)
	ps, _ := os.ReadFile(filepath.Join(f.e.P.State, "prov-state"))
	if string(ps) != "BOOT helper claimed claimed - 0\n" {
		t.Fatalf("prov-state %q", ps)
	}
}

// §4.4 step 6: an interrupted net.apply — decided by the generation p5 actually holds.
func TestTxnCommittedAndNot(t *testing.T) {
	// committed: p5 already at gen_to -> overlay completed from p5, .txn gone, nothing to restore
	f := newFx(t, 0)
	f.overlayIdentity()
	f.overlayRecord(provstore.Claimed, 4)
	copyDir(f.e.P.Identity(), filepath.Join(f.p5, "identity"))
	f.p5Record(provstore.Member, 5)
	provstore.WriteTxn(f.e.P, "tok", 4, 5, "network/join", "oldkey12", "oldmesh", "28")
	r := Run(f.e)
	if r.Verdict != provstore.Member || r.Restore != nil {
		t.Fatalf("committed: %+v", r)
	}
	if _, ok := provstore.ReadTxn(f.e.P); ok {
		t.Fatal(".txn left after a committed transaction")
	}
	// not committed: p5 still at gen_from -> restore requested with the recorded values, .txn kept until done
	g := newFx(t, 0)
	g.overlayIdentity()
	g.overlayRecord(provstore.Claimed, 4)
	copyDir(g.e.P.Identity(), filepath.Join(g.p5, "identity"))
	g.p5Record(provstore.Claimed, 4)
	provstore.WriteTxn(g.e.P, "tok", 4, 5, "network/join", "oldkey12", "oldmesh", "28")
	r = Run(g.e)
	if r.Restore == nil || r.Restore.PrevKey != "oldkey12" || r.Restore.PrevID != "oldmesh" || r.Restore.PrevChannel != "28" {
		t.Fatalf("not committed: %+v", r)
	}
	if _, ok := provstore.ReadTxn(g.e.P); !ok {
		t.Fatal(".txn removed before the wireless restore ran")
	}
}

// round-6 B-M3: rc 13 (p5 identity damaged) never lets an older / other slot's record or identity replace p5's
func TestRc13NeverDowngrades(t *testing.T) {
	f := newFx(t, 13)
	f.overlayIdentity()
	f.overlayRecord(provstore.Legacy, 1) // an old slot, legacy
	f.p5Record(provstore.Claimed, 5)     // p5: claimed, its identity damaged (rc 13)
	r := Run(f.e)
	if r.Verdict != "unknown(identity-lost)" || len(f.persists) != 0 {
		t.Fatalf("%+v persists=%v", r, f.persists)
	}
	// same node (same sn on p5) and the overlay not older -> the identity alone is re-persisted
	g := newFx(t, 13)
	g.overlayIdentity()
	g.overlayRecord(provstore.Claimed, 5)
	g.p5Record(provstore.Claimed, 5)
	os.MkdirAll(filepath.Join(g.p5, "identity"), 0o700)
	sn, _ := os.ReadFile(filepath.Join(g.e.P.Identity(), "sn"))
	os.WriteFile(filepath.Join(g.p5, "identity", "sn"), sn, 0o600)
	g.e.GetP5 = func(dir string) (int, string) { // rc 13 with only "sn" left of the identity
		os.MkdirAll(filepath.Join(dir, "identity"), 0o700)
		for _, n := range []string{"prov.cbor", "prov.meta"} {
			b, _ := os.ReadFile(filepath.Join(g.p5, n))
			os.WriteFile(filepath.Join(dir, n), b, 0o600)
		}
		os.WriteFile(filepath.Join(dir, "identity", "sn"), sn, 0o600)
		return 13, ""
	}
	if r := Run(g.e); r.Verdict != provstore.Claimed || len(g.persists) != 1 {
		t.Fatalf("same node: %+v persists=%v", r, g.persists)
	}
}

// round-6 B-m2: every prov-state writer uses one mesh_expect rule
func TestMeshExpect(t *testing.T) {
	k := func(v string) func() string { return func() string { return v } }
	for _, c := range []struct{ v, key, want string }{
		{provstore.Unclaimed, "real", "0"},
		{provstore.Member, placeholder, "radio"},
		{provstore.Claimed, placeholder, "0"},
		{provstore.Claimed, "", "today"}, // unreadable key: fail-closed (round-7 A-M7)
		{provstore.Claimed, "real", "today"},
		{provstore.Legacy, placeholder, "today"},
		{"unknown(no-record)", placeholder, "today"},
	} {
		if got := MeshExpect(c.v, k(c.key)); got != c.want {
			t.Errorf("MeshExpect(%s, %q) = %s, want %s", c.v, c.key, got, c.want)
		}
	}
}

// rc13Only makes GetP5 answer rc 13 with p5's record and only the given sn left of its identity.
func (f *fx) rc13Only(sn []byte) {
	f.e.GetP5 = func(dir string) (int, string) {
		os.MkdirAll(filepath.Join(dir, "identity"), 0o700)
		for _, n := range []string{"prov.cbor", "prov.meta"} {
			b, _ := os.ReadFile(filepath.Join(f.p5, n))
			os.WriteFile(filepath.Join(dir, n), b, 0o600)
		}
		os.WriteFile(filepath.Join(dir, "identity", "sn"), sn, 0o600)
		return 13, ""
	}
}

// round-7 B-m9: the gen condition of rc 13 on its own (same sn, overlay OLDER than p5) -> no write
func TestRc13SameSnOlderGen(t *testing.T) {
	f := newFx(t, 13)
	f.overlayIdentity()
	f.overlayRecord(provstore.Legacy, 1)
	f.p5Record(provstore.Claimed, 5)
	sn, _ := os.ReadFile(filepath.Join(f.e.P.Identity(), "sn"))
	f.rc13Only(sn)
	if r := Run(f.e); r.Verdict != "unknown(identity-lost)" || len(f.persists) != 0 {
		t.Fatalf("%+v persists=%v", r, f.persists)
	}
}

// round-7 B-M3: --persist-now never lowers a generation, never crosses identities, never runs over a .txn, and
// leaves the boot path's files alone
func TestPersistNow(t *testing.T) {
	same := func(f *fx) { copyDir(f.e.P.Identity(), filepath.Join(f.p5, "identity")) }
	// a legacy slot (gen 1) over a claimed p5 (gen 5), same identity: refused
	f := newFx(t, 0)
	f.overlayIdentity()
	f.overlayRecord(provstore.Legacy, 1)
	same(f)
	f.p5Record(provstore.Claimed, 5)
	if rc, why := PersistNow(f.e); rc == 0 || len(f.persists) != 0 {
		t.Fatalf("downgrade allowed: rc=%d %s", rc, why)
	}
	// overlay newer (gen 6 > 5), same identity: persisted, record only; .stage and prov-state untouched
	f = newFx(t, 0)
	f.overlayIdentity()
	f.overlayRecord(provstore.Claimed, 6)
	same(f)
	f.p5Record(provstore.Claimed, 5)
	os.MkdirAll(f.e.P.Stage(), 0o700)
	if rc, why := PersistNow(f.e); rc != 0 || len(f.persists) != 1 || f.persists[0] != "id=" {
		t.Fatalf("newer overlay: rc=%d %s %v", rc, why, f.persists)
	}
	if _, err := os.Stat(f.e.P.Stage()); err != nil {
		t.Fatalf("persist-now removed the boot path's .stage")
	}
	if _, err := os.Stat(filepath.Join(f.e.P.State, "prov-state")); err == nil {
		t.Fatalf("persist-now wrote prov-state")
	}
	// equal generation: in sync, nothing written
	f = newFx(t, 0)
	f.overlayIdentity()
	f.overlayRecord(provstore.Claimed, 5)
	same(f)
	f.p5Record(provstore.Claimed, 5)
	if rc, _ := PersistNow(f.e); rc != 0 || len(f.persists) != 0 {
		t.Fatalf("in sync wrote: %v", f.persists)
	}
	// identity mismatch: refused
	f = newFx(t, 0)
	f.overlayIdentity()
	f.overlayRecord(provstore.Claimed, 6)
	f.p5Identity()
	f.p5Record(provstore.Claimed, 5)
	if rc, _ := PersistNow(f.e); rc == 0 || len(f.persists) != 0 {
		t.Fatalf("mismatch allowed")
	}
	// an open net.apply transaction: refused with 7, .txn untouched
	f = newFx(t, 0)
	f.overlayIdentity()
	f.overlayRecord(provstore.Claimed, 6)
	same(f)
	f.p5Record(provstore.Claimed, 5)
	provstore.WriteTxn(f.e.P, "tok", 5, 6, "net.apply", "k", "id", "36")
	if rc, _ := PersistNow(f.e); rc != 7 || len(f.persists) != 0 {
		t.Fatalf("txn: rc=%d", rc)
	}
	if _, ok := provstore.ReadTxn(f.e.P); !ok {
		t.Fatalf("persist-now consumed the .txn")
	}
	os.WriteFile(f.e.P.Txn(), []byte("garbage"), 0o600) // malformed .txn: still refused
	if rc, _ := PersistNow(f.e); rc != 7 || len(f.persists) != 0 {
		t.Fatalf("malformed txn: rc=%d", rc)
	}
	// legacy upgrade (rc 9, no record on p5): persisted with the identity
	f = newFx(t, 9)
	f.overlayIdentity()
	f.overlayRecord(provstore.Legacy, 1)
	if rc, _ := PersistNow(f.e); rc != 0 || len(f.persists) != 1 || f.persists[0] == "id=" {
		t.Fatalf("rc 9: %v", f.persists)
	}
	// rc 13: another sn refused; the same sn with a newer overlay persisted with the identity
	f = newFx(t, 13)
	f.overlayIdentity()
	f.overlayRecord(provstore.Claimed, 6)
	f.p5Record(provstore.Claimed, 5)
	f.rc13Only([]byte("other"))
	if rc, _ := PersistNow(f.e); rc == 0 || len(f.persists) != 0 {
		t.Fatalf("rc 13 other sn allowed")
	}
	sn, _ := os.ReadFile(filepath.Join(f.e.P.Identity(), "sn"))
	f.rc13Only(sn)
	if rc, why := PersistNow(f.e); rc != 0 || len(f.persists) != 1 || f.persists[0] == "id=" {
		t.Fatalf("rc 13 same sn: rc=%d %s %v", rc, why, f.persists)
	}
	// an unreadable p5 and a bypass boot: refused
	f = newFx(t, 1)
	f.overlayIdentity()
	f.overlayRecord(provstore.Claimed, 6)
	if rc, _ := PersistNow(f.e); rc == 0 {
		t.Fatalf("unreadable p5 allowed")
	}
	f.e.Bypass = func() bool { return true }
	if rc, _ := PersistNow(f.e); rc == 0 {
		t.Fatalf("bypass allowed")
	}
}
