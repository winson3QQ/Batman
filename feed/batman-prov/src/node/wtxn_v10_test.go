package node

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/sha256"
	"testing"

	"batman-prov/cbor"
	"batman-prov/proto"
	"batman-prov/provstore"
)

// docs/design/254-wireless-txn.md §17 (code review round 3).

// review 3 B MAJOR-1: a removed co-owner cannot use a stale overlay (p5 committed, overlay write failed) to re-add
// themselves: the owner-op was checked against the stale overlay, resolve then finds a newer record -> EState, nothing
// committed; the retry is checked against the rebuilt overlay -> refused
func TestRemovedOwnerCannotUseStaleOverlay(t *testing.T) {
	r, _ := memberRig(t)
	b, be := newKey(), newKey()
	se, _ := proto.SignES256(b, append([]byte(proto.LabelOwnerEnc), pub(be)...))
	add := func(signer *ecdsa.PrivateKey) int {
		c, _ := r.call("owner.add", cbor.M(1, r.h, 2, r.envelope("owner/add", cbor.M(1, pub(b), 2, pub(be), 3, se), signer)))
		return c
	}
	if c := add(r.owner); c != OK {
		t.Fatalf("owner adds B: %d", c)
	}
	withB := *r.rec()
	kid := sha256.Sum256(pub(b))
	if c, _ := r.call("owner.remove", cbor.M(1, r.h, 2, r.envelope("owner/remove", cbor.M(1, kid[:]), r.owner))); c != OK {
		t.Fatalf("owner removes B: %d", c)
	}
	removed := r.rec().Generation
	if _, _, err := provstore.WriteOverlay(r.n.P, &withB); err != nil { // the overlay write of the removal "failed"
		t.Fatal(err)
	}
	if c := add(b); c != EState {
		t.Fatalf("B re-adds itself on the stale overlay: %d (want EState)", c)
	}
	rec := r.rec()
	if rec.Generation != removed || hasOwner(rec, pub(b)) {
		t.Fatalf("after the refused re-add: gen %d (want %d), B owner=%v", rec.Generation, removed, hasOwner(rec, pub(b)))
	}
	if c := add(b); c != EForbidden {
		t.Fatalf("B retries on the rebuilt overlay: %d (want EForbidden)", c)
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
