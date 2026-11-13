package provd

import (
	"bytes"
	"testing"
	"time"

	"batman-prov/cbor"
)

// ownerPhone: a session that passed auth/owner on a claimed node whose fake helper runs h for the update verbs
func ownerPhone(t *testing.T, h func(verb string, args cbor.Map) (int, cbor.Map, bool)) (*phone, *fakeHelper, []byte, [][]byte, *Server) {
	t.Helper()
	k, pub := ownerKey(t)
	f, psks := claimedHelper(t, pub)
	f.set(func(f *fakeHelper) { f.handler = h })
	s := startServer(t, f, TestEnv{})
	p := dial(t, s)
	p.handshake("", psks[0])
	if code, _ := p.do("auth/owner", cbor.M(1, kidOf(pub), 2, authSig(t, k, p.h, kidOf(pub)))); code != 0 {
		t.Fatalf("auth/owner %d", code)
	}
	return p, f, pub, psks, s
}

func testManifest() cbor.Map {
	return cbor.M(1, "1.5.14-wsl.26", 2, "ekh-bcm2711", 3, uint64(126309765), 4, bytes.Repeat([]byte{4}, 32), 5, []byte{0x82, 0x40, 0x40})
}

// update/check (254-p3-impl §3.1-3): the manifest map re-encoded to the helper with the session's owner key id; a
// refusal is an ok answer passed on; 1 / 10 s per connection; a body without a map is E_BAD_OBJECT
func TestUpdateCheckRoute(t *testing.T) {
	p, f, pub, psks, s := ownerPhone(t, func(verb string, args cbor.Map) (int, cbor.Map, bool) {
		if verb == "update.check" {
			return 0, cbor.M(1, false, 2, uint64(24), 3, uint64(0)), true
		}
		return 0, nil, false
	})
	if code, _ := p.do("update/check", cbor.M(1, "not a map")); code != EBadObject {
		t.Fatalf("no manifest map: %d", code)
	}
	if f.count("update.check") != 0 {
		t.Fatal("a bad request reached the helper")
	}
	mf := testManifest()
	code, body := p.do("update/check", cbor.M(1, mf))
	if code != 0 {
		t.Fatalf("update/check %d %v", code, body)
	}
	if v, _ := body.Get(2); v != uint64(24) {
		t.Fatalf("refusal not passed on: %v", body)
	}
	a := f.last("update.check")
	want, _ := cbor.Encode(mf)
	if v, _ := a.Get(1); !bytes.Equal(v.([]byte), want) {
		t.Fatal("the helper did not get the manifest's encoding")
	}
	if v, _ := a.Get(2); !bytes.Equal(v.([]byte), kidOf(pub)) {
		t.Fatal("the helper did not get the session's owner key id")
	}
	if code, _ := p.do("update/check", cbor.M(1, mf)); code != ERate {
		t.Fatalf("second check within 10 s: %d, want E_RATE", code)
	}
	if f.count("update.check") != 1 {
		t.Fatal("the rate-limited check reached the helper")
	}
	m := dial(t, s)
	m.handshake("", psks[4])
	if code, _ := m.do("update/check", cbor.M(1, mf)); code != EForbidden {
		t.Fatalf("member update/check: %d", code)
	}
}

// update/status on the ro connection; the owner-ops forwarded as the whole envelope; helper reasons mapped
func TestUpdateOwnerOpRoutes(t *testing.T) {
	prog := cbor.M(1, uint64(2), 2, uint64(0))
	open := cbor.M(1, "batman-ap", 2, "pass", 3, "10.41.80.13", 4, uint64(8095), 5, uint64(900), 6, bytes.Repeat([]byte{6}, 16))
	p, f, _, _, _ := ownerPhone(t, func(verb string, args cbor.Map) (int, cbor.Map, bool) {
		switch verb {
		case "update.status", "update.prepare", "update.apply":
			return 0, prog, true
		case "bulk.open":
			return 0, open, true
		case "bulk.close":
			return hEReject, cbor.M(1, uint64(15)), true
		}
		return 0, nil, false
	})
	if code, body := p.do("update/status", cbor.M()); code != 0 || !mapEq(body, prog) {
		t.Fatalf("update/status %d %v", code, body)
	}
	if code, _ := p.do("update/status", cbor.M(1, uint64(1))); code != EBadObject {
		t.Fatalf("update/status with a body: %d", code)
	}
	for typ, want := range map[string]cbor.Map{"update/prepare": prog, "update/apply": prog, "bulk/open": open} {
		env := p.env(typ, cbor.M(1, bytes.Repeat([]byte{9}, 32)))
		p.sendEnv(env)
		r := p.resp(5 * time.Second)
		st, _ := r.Get(4)
		b, _ := r.Get(3)
		if st != uint64(0) || !mapEq(b.(cbor.Map), want) {
			t.Fatalf("%s: %v %v", typ, st, b)
		}
		verb := forward[typ]
		if v, _ := f.last(verb).Get(2); !bytes.Equal(v.([]byte), env) {
			t.Fatalf("%s: %s did not get the original envelope", typ, verb)
		}
	}
	code, detail := p.do("bulk/close", cbor.M())
	if v, _ := detail.Get(2); code != ERejected || v != uint64(15) {
		t.Fatalf("bulk/close refusal: %d %v", code, detail)
	}
	if code, _ := p.do("bulk/open", cbor.M(1, uint64(0)), 7, randB(16)); code != EForbidden {
		t.Fatalf("bulk/open with an idempotency key (its answer is secret): %d", code)
	}
}

func mapEq(a, b cbor.Map) bool {
	x, _ := cbor.Encode(a)
	y, _ := cbor.Encode(b)
	return bytes.Equal(x, y)
}
