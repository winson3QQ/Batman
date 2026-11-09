package provd

import (
	"testing"

	"batman-prov/cbor"
)

// status (254-p3-impl §3.4): the helper's status.get answer, with key 15 whatever "full" says (the member check
// must be provd's own, not only the helper's)
func statusHelper(f *fakeHelper, state string, code int) {
	f.set(func(f *fakeHelper) {
		f.handler = func(verb string, args cbor.Map) (int, cbor.Map, bool) {
			if verb != "status.get" {
				return 0, nil, false
			}
			return code, cbor.M(1, state, 2, uint64(2), 3, uint64(1), 4, true, 15, cbor.M("node", "BCM2711-6c89")), true
		}
	})
}

func lastStatusArgs(f *fakeHelper) (cbor.Map, bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	for i := len(f.calls) - 1; i >= 0; i-- {
		if f.calls[i].verb == "status.get" {
			return f.calls[i].args, true
		}
	}
	return nil, false
}

func TestStatusOwnerMemberAnon(t *testing.T) {
	k, pub := ownerKey(t)
	f, psks := claimedHelper(t, pub)
	statusHelper(f, "member", 0)
	s := startServer(t, f, TestEnv{})

	o := dial(t, s)
	o.handshake("", psks[0])
	o.do("auth/owner", cbor.M(1, kidOf(pub), 2, authSig(t, k, o.h, kidOf(pub))))
	code, body := o.do("status", cbor.M(1, uint64(0)))
	if code != 0 {
		t.Fatalf("owner status code %d", code)
	}
	if v, _ := body.Get(1); v != uint64(2) {
		t.Fatalf("owner: key 1 = %v, want 2 (member, the CDDL number)", v)
	}
	if _, ok := body.Get(15); !ok {
		t.Fatal("owner: no key 15")
	}
	if a, _ := lastStatusArgs(f); func() bool { v, _ := a.Get(1); return v != true }() {
		t.Fatalf("owner: helper asked with full=%v", a)
	}

	m := dial(t, s)
	m.handshake("", psks[4]) // psk_member
	code, body = m.do("status", cbor.M(1, uint64(0)))
	if code != 0 {
		t.Fatalf("member status code %d", code)
	}
	if _, ok := body.Get(15); ok {
		t.Fatal("member got key 15 (the helper sent it; provd must drop it)")
	}
	if v, _ := body.Get(2); v != uint64(2) {
		t.Fatalf("member: key 2 = %v", v)
	}
	if a, _ := lastStatusArgs(f); func() bool { v, _ := a.Get(1); return v != false }() {
		t.Fatalf("member: helper asked with full=%v", a)
	}

	// a fresh server: two slots, both taken by the owner and the member above
	s2 := startServer(t, newFakeHelper(t), TestEnv{})
	a := dial(t, s2)
	a.handshake(devID, nil)
	if code, _ := a.do("status", cbor.M(1, uint64(0))); code != EForbidden {
		t.Fatalf("anonymous status code %d, want E_FORBIDDEN", code)
	}
}

func TestStatusScopeAndErrors(t *testing.T) {
	k, pub := ownerKey(t)
	f, psks := claimedHelper(t, pub)
	statusHelper(f, "member", 0)
	s := startServer(t, f, TestEnv{})
	o := dial(t, s)
	o.handshake("", psks[0])
	o.do("auth/owner", cbor.M(1, kidOf(pub), 2, authSig(t, k, o.h, kidOf(pub))))

	code, det := o.do("status", cbor.M(1, uint64(1)))
	if code != EUnsupported {
		t.Fatalf("team scope code %d", code)
	}
	if v, _ := det.Get(2); v != uint64(7) {
		t.Fatalf("team scope detail %v, want {1: status, 2: 7}", det)
	}
	for _, b := range []cbor.Map{cbor.M(), cbor.M(1, "self"), cbor.M(1, uint64(2))} {
		if code, _ := o.do("status", b); code != EBadObject {
			t.Fatalf("status %v: code %d, want E_BAD_OBJECT", b, code)
		}
	}
	statusHelper(f, "weird", 0)
	if code, _ := o.do("status", cbor.M(1, uint64(0))); code != ERejected {
		t.Fatalf("unknown helper state: code %d, want E_REJECTED", code)
	}
	statusHelper(f, "member", hERate)
	if code, _ := o.do("status", cbor.M(1, uint64(0))); code != hERate {
		t.Fatalf("helper ERate: code %d", code)
	}
}
