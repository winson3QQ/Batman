package provd

import (
	"testing"
	"time"

	"batman-prov/cbor"
)

// 254-p3-impl §3.2: owner/add answers only the 32-byte owner_tag_key; owner/remove cuts the removed owner's session
// (invalidate -> reconcile), and the remaining owner's session stays
func TestOwnerAddRemoveRouted(t *testing.T) {
	k, pub := ownerKey(t)
	k2, pub2 := ownerKey(t)
	f, psks := claimedHelper(t, pub, pub2)
	tag := randB(32)
	f.set(func(f *fakeHelper) {
		f.handler = func(v string, a cbor.Map) (int, cbor.Map, bool) {
			switch v {
			case "owner.add":
				return 0, cbor.M(1, tag, 9, "not for the app"), true
			case "owner.remove":
				f.owners = [][]byte{pub}
				f.gen++
				return 0, cbor.M(), true
			}
			return 0, nil, false
		}
	})
	s := startServer(t, f, TestEnv{})
	a := dial(t, s)
	a.handshake("", psks[0])
	a.do("auth/owner", cbor.M(1, kidOf(pub), 2, authSig(t, k, a.h, kidOf(pub))))
	b := dial(t, s)
	b.handshake("", psks[1])
	b.do("auth/owner", cbor.M(1, kidOf(pub2), 2, authSig(t, k2, b.h, kidOf(pub2))))
	op := func(typ string) cbor.Map { return cbor.M(31, cbor.M(1, typ, 2, randB(64))) }
	code, body := a.do("owner/add", append(cbor.M(1, randB(65), 2, randB(65), 3, randB(64)), op("owner/add")...))
	if v, _ := body.Get(1); code != 0 || len(v.([]byte)) != 32 {
		t.Fatalf("owner/add: %d %v", code, body)
	}
	if _, extra := body.Get(9); extra || len(body) != 1 {
		t.Fatalf("owner/add passed more than the tag key: %v", body)
	}
	if f.last("owner.add") == nil {
		t.Fatal("owner/add not forwarded to the helper")
	}
	if code, _ := a.do("owner/remove", append(cbor.M(1, kidOf(pub2)), op("owner/remove")...)); code != 0 {
		t.Fatalf("owner/remove: %d", code)
	}
	if !b.closedWithin(2 * time.Second) {
		t.Fatal("the removed owner's session survived owner/remove")
	}
	if a.closedWithin(300 * time.Millisecond) {
		t.Fatal("the remaining owner's session was cut")
	}
}

// an OK owner.add without a 32-byte tag is not passed on as success
func TestOwnerAddBadHelperAnswer(t *testing.T) {
	k, pub := ownerKey(t)
	f, psks := claimedHelper(t, pub)
	f.set(func(f *fakeHelper) {
		f.handler = func(v string, a cbor.Map) (int, cbor.Map, bool) {
			if v == "owner.add" {
				return 0, cbor.M(1, randB(16)), true
			}
			return 0, nil, false
		}
	})
	s := startServer(t, f, TestEnv{})
	a := dial(t, s)
	a.handshake("", psks[0])
	a.do("auth/owner", cbor.M(1, kidOf(pub), 2, authSig(t, k, a.h, kidOf(pub))))
	if code, _ := a.do("owner/add", cbor.M(1, randB(65), 31, cbor.M(1, "owner/add", 2, randB(64)))); code != ERejected {
		t.Fatalf("a 16-byte tag from the helper: %d, want E_REJECTED", code)
	}
}
