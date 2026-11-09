package node

// 254-p3-impl §3.2 / F4: owner.add / owner.remove boundaries (the helper logic is P2's; provd routes them from P3)

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"testing"

	"batman-prov/cbor"
	"batman-prov/proto"
	"batman-prov/provstore"
)

type coOwner struct{ k, e *ecdsa.PrivateKey }

func newCoOwner() coOwner {
	k, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	e, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	return coOwner{k, e}
}

// addBody: owner-add-req {1 owner_pub, 2 owner_enc_pub, 3 sig_enc}; sigBy signs the enc key (normally the new owner)
func addBody(o coOwner, sigBy *ecdsa.PrivateKey) cbor.Map {
	se, _ := proto.SignES256(sigBy, append([]byte(proto.LabelOwnerEnc), pub(o.e)...))
	return cbor.M(1, pub(o.k), 2, pub(o.e), 3, se)
}

func (r *rig) ownerOp(verb, typ string, body cbor.Map, signer *ecdsa.PrivateKey) (int, cbor.Map) {
	return r.call(verb, cbor.M(1, r.h, 2, r.envelope(typ, body, signer)))
}

func kidOf(k *ecdsa.PrivateKey) []byte { s := sha256.Sum256(pub(k)); return s[:] }

func (r *rig) record() *provstore.Record {
	rec, _, err := provstore.LoadOverlay(r.n.P)
	if err != nil {
		r.t.Fatal(err)
	}
	return rec
}

func TestOwnerAddBoundaries(t *testing.T) {
	r := claimedRig(t)
	a := newCoOwner()
	// sig_enc not by the new owner -> E_FORBIDDEN, nothing stored
	if c, _ := r.ownerOp("owner.add", "owner/add", addBody(a, r.owner), r.owner); c != EForbidden {
		t.Fatalf("sig_enc by another key: %d", c)
	}
	if n := len(r.record().Owners); n != 1 {
		t.Fatalf("owners after a refused add: %d", n)
	}
	c, b := r.ownerOp("owner.add", "owner/add", addBody(a, a.k), r.owner)
	tag1, _ := b.Get(1)
	if c != OK || len(tag1.([]byte)) != 32 || len(r.record().Owners) != 2 {
		t.Fatalf("add: %d %v owners %d", c, b, len(r.record().Owners))
	}
	// re-add the same owner = its tag key rotated, still 2 owners
	_, b = r.ownerOp("owner.add", "owner/add", addBody(a, a.k), r.owner)
	tag2, _ := b.Get(1)
	if bytes.Equal(tag1.([]byte), tag2.([]byte)) || len(r.record().Owners) != 2 {
		t.Fatal("re-add did not rotate the tag key (or added a duplicate)")
	}
	// up to 4 owners; the 5th -> E_UNSUPPORTED
	for i := 0; i < 2; i++ {
		o := newCoOwner()
		if c, _ := r.ownerOp("owner.add", "owner/add", addBody(o, o.k), r.owner); c != OK {
			t.Fatalf("owner %d: %d", i+3, c)
		}
	}
	o5 := newCoOwner()
	if c, _ := r.ownerOp("owner.add", "owner/add", addBody(o5, o5.k), r.owner); c != EUnsupported {
		t.Fatalf("5th owner: %d", c)
	}
	if n := len(r.record().Owners); n != 4 {
		t.Fatalf("owners %d", n)
	}
	// the added owner signs owner-ops now
	if c, _ := r.ownerOp("owner.add", "owner/add", addBody(a, a.k), a.k); c != OK {
		t.Fatalf("the added owner's own owner-op: %d", c)
	}
}

func TestOwnerRemoveBoundaries(t *testing.T) {
	r := claimedRig(t)
	a := newCoOwner()
	if c, _ := r.ownerOp("owner.add", "owner/add", addBody(a, a.k), r.owner); c != OK {
		t.Fatalf("add %d", c)
	}
	adv := r.record().AdvOwnerKey
	if c, _ := r.ownerOp("owner.remove", "owner/remove", cbor.M(1, make([]byte, 32)), r.owner); c != EForbidden {
		t.Fatalf("unknown kid: %d", c)
	}
	if c, _ := r.ownerOp("owner.remove", "owner/remove", cbor.M(1, kidOf(a.k)), r.owner); c != OK {
		t.Fatalf("remove: %d", c)
	}
	rec := r.record()
	if len(rec.Owners) != 1 || bytes.Equal(rec.AdvOwnerKey, adv) {
		t.Fatalf("after remove: owners %d, adv_owner_key rotated %v", len(rec.Owners), !bytes.Equal(rec.AdvOwnerKey, adv))
	}
	// the removed owner's owner-op is refused
	if c, _ := r.ownerOp("owner.add", "owner/add", addBody(a, a.k), a.k); c == OK {
		t.Fatal("a removed owner's owner-op accepted")
	}
	// the last owner cannot be removed
	if c, _ := r.ownerOp("owner.remove", "owner/remove", cbor.M(1, kidOf(r.owner)), r.owner); c != EForbidden {
		t.Fatalf("remove the last owner: %d", c)
	}
	if n := len(r.record().Owners); n != 1 {
		t.Fatalf("owners %d", n)
	}
}
