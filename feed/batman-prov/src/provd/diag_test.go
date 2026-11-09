package provd

import (
	"testing"

	"batman-prov/cbor"
)

// 254-p3-impl §3.5 / D10: diag/summary for the owner and a member, not for anonymous; 1/s per session
func TestDiagSummaryRoles(t *testing.T) {
	k, pub := ownerKey(t)
	f, psks := claimedHelper(t, pub)
	f.set(func(f *fakeHelper) {
		f.handler = func(v string, a cbor.Map) (int, cbor.Map, bool) {
			if v == "diag.summary" {
				return 0, cbor.M(1, []any{cbor.M(1, "mesh", 2, uint64(2))}, "x", "dropped"), true
			}
			return 0, nil, false
		}
	})
	s := startServer(t, f, TestEnv{})
	o := dial(t, s)
	o.handshake("", psks[0])
	o.do("auth/owner", cbor.M(1, kidOf(pub), 2, authSig(t, k, o.h, kidOf(pub))))
	code, body := o.do("diag/summary", cbor.M())
	if v, _ := body.Get(1); code != 0 || len(v.([]any)) != 1 {
		t.Fatalf("owner diag/summary: %d %v", code, body)
	}
	if _, ok := body.Get("x"); ok {
		t.Fatal("a text key passed on")
	}
	if code, _ := o.do("diag/summary", cbor.M()); code != ERate {
		t.Fatalf("second within 1 s: %d, want E_RATE", code)
	}
	if code, _ := o.do("diag/summary", cbor.M(1, uint64(1))); code != EBadObject && code != ERate {
		t.Fatalf("a body: %d", code)
	}
	m := dial(t, s)
	m.handshake("", psks[4])
	if code, _ := m.do("diag/summary", cbor.M()); code != 0 {
		t.Fatalf("member diag/summary: %d (D10: members may read it)", code)
	}
	s2 := startServer(t, newFakeHelper(t), TestEnv{})
	a := dial(t, s2)
	a.handshake(devID, nil)
	if code, _ := a.do("diag/summary", cbor.M()); code != EForbidden {
		t.Fatalf("anonymous diag/summary: %d", code)
	}
}
