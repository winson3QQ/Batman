package provd

import (
	"testing"

	"batman-prov/cbor"
)

// settings/get (254-p3-impl §3.3): owner only, empty body, the helper's answer passed on (integer keys only)
func TestSettingsGet(t *testing.T) {
	k, pub := ownerKey(t)
	f, psks := claimedHelper(t, pub)
	f.set(func(f *fakeHelper) {
		f.handler = func(verb string, args cbor.Map) (int, cbor.Map, bool) {
			if verb != "settings.get" {
				return 0, nil, false
			}
			return 0, cbor.M(1, "BCM2711-6c89", 2, "US", 10, cbor.M(1, uint64(42), 2, uint64(2)), 20, cbor.M(1, "BCM2711-6c89"), "x", "y"), true
		}
	})
	s := startServer(t, f, TestEnv{})
	o := dial(t, s)
	o.handshake("", psks[0])
	o.do("auth/owner", cbor.M(1, kidOf(pub), 2, authSig(t, k, o.h, kidOf(pub))))
	code, body := o.do("settings/get", cbor.M())
	if code != 0 {
		t.Fatalf("owner settings/get code %d", code)
	}
	if v, _ := body.Get(2); v != "US" {
		t.Fatalf("2 = %v", v)
	}
	if _, ok := body.Get("x"); ok {
		t.Fatal("a text key was passed on")
	}
	if code, _ := o.do("settings/get", cbor.M(1, uint64(1))); code != EBadObject {
		t.Fatalf("a body: code %d, want E_BAD_OBJECT", code)
	}

	m := dial(t, s)
	m.handshake("", psks[4]) // psk_member: not the member's verb
	if code, _ := m.do("settings/get", cbor.M()); code != EForbidden {
		t.Fatalf("member settings/get code %d, want E_FORBIDDEN", code)
	}
}
