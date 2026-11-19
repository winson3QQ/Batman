package node

import (
	"bytes"
	"crypto/sha256"
	"testing"
	"time"

	"batman-prov/cbor"
	"batman-prov/proto"
	"batman-prov/provstore"
)

// #329 rotating identifier (docs/design/329-rotating-id-plan.md §9, G1 / G4): the helper's read-only verb adv.id.

func advID(t *testing.T, r *rig) []byte {
	t.Helper()
	c, res := r.call("adv.id", cbor.M())
	v, _ := res.Get(1)
	id, ok := v.([]byte)
	if c != OK || !ok || len(id) != 6 || len(res) != 1 {
		t.Fatalf("adv.id: code %d, answer %v", c, res)
	}
	return id
}

func tagOK(r *rig, key, id []byte) bool {
	return bytes.Equal(proto.AdvIDTag(proto.AdvOwner(key, r.ks.DeviceID()), id[:3]), id[3:])
}

// G1: a claimed node answers 6 B = nonce ‖ tag; the tag verifies under this node's adv_owner and under no other key;
// the answer holds nothing else (never the key).
func TestAdvIDClaimed(t *testing.T) {
	r := claimedRig(t)
	key := r.rec().AdvOwnerKey
	id := advID(t, r)
	if !tagOK(r, key, id) {
		t.Fatal("the tag does not verify under adv_owner")
	}
	if tagOK(r, make32(9), id) {
		t.Fatal("the tag verifies under another key")
	}
	if c, _ := r.call("adv.id", cbor.M(1, uint64(1))); c != ESchema {
		t.Fatalf("adv.id with an argument: code %d", c)
	}
}

// G1: a fresh nonce at every call. 1000 draws of 3 random bytes may repeat a few times by chance (birthday bound:
// about 0.03 expected pairs), so the bar is 990 distinct, and every one of the 1000 verifies.
func TestAdvIDFreshNonce(t *testing.T) {
	r := claimedRig(t)
	key := r.rec().AdvOwnerKey
	now := r.n.now()
	r.n.clock = func() time.Time { now = now.Add(time.Second); return now } // one call a second: under the read quota
	seen := map[string]bool{}
	for i := 0; i < 1000; i++ {
		id := advID(t, r)
		if !tagOK(r, key, id) {
			t.Fatalf("call %d: the tag does not verify", i)
		}
		seen[string(id[:3])] = true
	}
	if len(seen) < 990 {
		t.Fatalf("%d distinct nonces in 1000 calls", len(seen))
	}
}

// the existing read-only quota covers adv.id like every read-only verb (helper-wide burst 40): over it -> ERate
func TestAdvIDQuota(t *testing.T) {
	r := claimedRig(t)
	now := r.n.now()
	r.n.clock = func() time.Time { return now }
	rate := 0
	for i := 0; i < 60; i++ {
		if c, res := r.call("adv.id", cbor.M()); c == ERate && len(res) == 0 {
			rate++
		} else if c != OK {
			t.Fatalf("call %d: code %d", i, c)
		}
	}
	if rate == 0 || rate == 60 {
		t.Fatalf("%d of 60 calls in one instant were refused with ERate", rate)
	}
}

// G1: no record with a 32-byte adv_owner_key (unclaimed, or a record written before the key existed) -> EUnsupported
func TestAdvIDNoKey(t *testing.T) {
	r := newRig(t, provstore.Unclaimed)
	if c, res := r.call("adv.id", cbor.M()); c != EUnsupported || len(res) != 0 {
		t.Fatalf("unclaimed: code %d, answer %v", c, res)
	}
	r = claimedRig(t)
	rec := *r.rec()
	rec.AdvOwnerKey = rec.AdvOwnerKey[:16]
	if _, _, err := provstore.WriteOverlay(r.n.P, &rec); err != nil {
		t.Fatal(err)
	}
	if c, res := r.call("adv.id", cbor.M()); c != EUnsupported || len(res) != 0 {
		t.Fatalf("16-byte key: code %d, answer %v", c, res)
	}
}

// G1: read-only — answered while a state change holds n.mu (net.apply can for minutes)
func TestAdvIDWhileMutexHeld(t *testing.T) {
	r := claimedRig(t)
	r.n.mu.Lock()
	defer r.n.mu.Unlock()
	done := make(chan int, 1)
	go func() { c, _ := r.call("adv.id", cbor.M()); done <- c }()
	select {
	case c := <-done:
		if c != OK {
			t.Fatalf("code %d", c)
		}
	case <-time.After(time.Second):
		t.Fatal("adv.id waited for the mutex")
	}
}

// G4: owner.remove rotates adv_owner_key (219 §5.3); the next identifier verifies under the new key, not the old one
func TestAdvIDAfterOwnerRemove(t *testing.T) {
	r, _ := memberRig(t)
	b, be := newKey(), newKey()
	se, _ := proto.SignES256(b, append([]byte(proto.LabelOwnerEnc), pub(be)...))
	if c, _ := r.call("owner.add", cbor.M(1, r.h, 2, r.envelope("owner/add", cbor.M(1, pub(b), 2, pub(be), 3, se), r.owner))); c != OK {
		t.Fatalf("owner adds B: %d", c)
	}
	old := r.rec().AdvOwnerKey
	if !tagOK(r, old, advID(t, r)) {
		t.Fatal("before the removal: the tag does not verify")
	}
	kid := sha256.Sum256(pub(b))
	if c, _ := r.call("owner.remove", cbor.M(1, r.h, 2, r.envelope("owner/remove", cbor.M(1, kid[:]), r.owner))); c != OK {
		t.Fatalf("owner removes B: %d", c)
	}
	now := r.rec().AdvOwnerKey
	if bytes.Equal(old, now) {
		t.Fatal("owner.remove kept adv_owner_key")
	}
	id := advID(t, r)
	if !tagOK(r, now, id) || tagOK(r, old, id) {
		t.Fatalf("after the removal: new key %v, old key %v", tagOK(r, now, id), tagOK(r, old, id))
	}
}
