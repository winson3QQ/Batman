package node

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/sha256"
	"testing"

	"batman-prov/cbor"
	"batman-prov/proto"
	"batman-prov/provstore"
	"batman-prov/seam"
)

// docs/design/254-wireless-txn.md §17.1 / §18.1 (code review rounds 3–4): an owner-op checked against a stale
// overlay (p5 committed an owner removal, the overlay write failed) runs on the record p5 confirms, and its signer must
// be an owner of THAT record.

// staleRemoval: owner A adds B, then removes B; the removal is in p5 but the overlay still holds the record with B.
func staleRemoval(t *testing.T) (r *rig, b *ecdsa.PrivateKey, removedGen uint64) {
	r, _ = memberRig(t)
	b, be := newKey(), newKey()
	se, _ := proto.SignES256(b, append([]byte(proto.LabelOwnerEnc), pub(be)...))
	if c, _ := r.call("owner.add", cbor.M(1, r.h, 2, r.envelope("owner/add", cbor.M(1, pub(b), 2, pub(be), 3, se), r.owner))); c != OK {
		t.Fatalf("owner adds B: %d", c)
	}
	withB := *r.rec()
	kid := sha256.Sum256(pub(b))
	if c, _ := r.call("owner.remove", cbor.M(1, r.h, 2, r.envelope("owner/remove", cbor.M(1, kid[:]), r.owner))); c != OK {
		t.Fatalf("owner removes B: %d", c)
	}
	removedGen = r.rec().Generation
	if _, _, err := provstore.WriteOverlay(r.n.P, &withB); err != nil { // the overlay write of the removal "failed"
		t.Fatal(err)
	}
	return r, b, removedGen
}

func (r *rig) p5Rec() *provstore.Record {
	b, err := readFile(r.sys.p5 + "/prov.cbor")
	if err != nil {
		r.t.Fatal(err)
	}
	rec, err := provstore.Decode(b)
	if err != nil {
		r.t.Fatal(err)
	}
	return rec
}

// review 3 B MAJOR-1 + review 4 A/B MAJOR-1: the removed co-owner gets EForbidden for every owner-op verb on the stale
// overlay — owner.add (itself back), ssh_keys.set, root_password.reset, network.leave — and p5 keeps the removal
func TestRemovedOwnerCannotUseStaleOverlay(t *testing.T) {
	type op struct {
		verb, typ string
		body      cbor.Map
	}
	b2, be2 := newKey(), newKey()
	ops := []op{
		{"owner.add", "owner/add", nil}, // filled below with B's own key
		{"ssh_keys.set", "ssh_keys/set", cbor.M(1, []any{"ssh-ed25519 AAAAattacker b"})},
		{"root_password.reset", "root_password/reset", cbor.M()},
		{"network.leave", "network/leave", cbor.M()},
	}
	_ = b2
	_ = be2
	for _, o := range ops {
		r, b, removed := staleRemoval(t)
		body := o.body
		if o.verb == "owner.add" {
			be := newKey()
			se, _ := proto.SignES256(b, append([]byte(proto.LabelOwnerEnc), pub(be)...))
			body = cbor.M(1, pub(b), 2, pub(be), 3, se)
		}
		keys, root := append([]string(nil), r.sys.keys...), r.sys.root
		c, _ := r.call(o.verb, cbor.M(1, r.h, 2, r.envelope(o.typ, body, b)))
		if c != EForbidden {
			t.Fatalf("%s by the removed co-owner on the stale overlay: code %d (want EForbidden)", o.verb, c)
		}
		p5 := r.p5Rec()
		if p5.Generation != removed || hasOwner(p5, pub(b)) || p5.State != provstore.Member {
			t.Fatalf("%s: p5 gen %d (want %d), B owner=%v, state %s", o.verb, p5.Generation, removed, hasOwner(p5, pub(b)), p5.State)
		}
		if len(r.sys.keys) != len(keys) || r.sys.root != root {
			t.Fatalf("%s: keys %v / root %q changed", o.verb, r.sys.keys, r.sys.root)
		}
	}
}

// review 4 B m1: the legitimate owner on the stale overlay is not sent into "retry": the verb runs on p5's record at
// once (the removal of B stays), including owner.add / owner.remove
func TestOwnerOnStaleOverlayRunsOnP5Record(t *testing.T) {
	r, b, removed := staleRemoval(t)
	if c := r.sshSet(); c != OK {
		t.Fatalf("ssh_keys.set by the owner on the stale overlay: %d", c)
	}
	if c := r.ownerAdd(); c != OK {
		t.Fatalf("owner.add by the owner on the stale overlay: %d", c)
	}
	p5 := r.p5Rec()
	if p5.Generation <= removed || hasOwner(p5, pub(b)) {
		t.Fatalf("p5 gen %d (want > %d), B owner=%v: the removal was undone", p5.Generation, removed, hasOwner(p5, pub(b)))
	}
}

// §18.1: commitTxn never writes over a newer record (the generation check), whatever the caller built it on
func TestCommitRefusesAnOlderBase(t *testing.T) {
	r, _, removed := staleRemoval(t)
	stale := *r.rec() // the overlay: generation removed-1
	next := stale
	next.Generation = stale.Generation + 1 // == removed: would overwrite the removal
	if e := r.n.commitTxn(&next, "", seam.None); e == nil || e.Code != EState {
		t.Fatalf("commit on an older base: %v (want EState)", e)
	}
	if p5 := r.p5Rec(); p5.Generation != removed {
		t.Fatalf("p5 generation %d (want %d unchanged)", p5.Generation, removed)
	}
	if ov := r.rec(); ov.Generation != removed {
		t.Fatalf("overlay generation %d: not rebuilt from p5 (want %d)", ov.Generation, removed)
	}
}

func hasOwner(rec *provstore.Record, p []byte) bool {
	for _, o := range rec.Owners {
		if bytes.Equal(o.Pub, p) {
			return true
		}
	}
	return false
}
