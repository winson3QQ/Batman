package provd

import (
	"testing"

	"batman-prov/cbor"
)

// settings/set (254-p3-impl §3.3 / §3.1-8): forwarded to settings.set for the owner; the helper's reason becomes the
// protocol's detail (E_REJECTED{2: reason}, E_UNSUPPORTED{1: typ, 2: reason}); without a reason P2's mapping stays.
func TestSettingsSetForwardAndReasons(t *testing.T) {
	k, pub := ownerKey(t)
	f, psks := claimedHelper(t, pub)
	answer := func(code int, body cbor.Map) {
		f.set(func(f *fakeHelper) {
			f.handler = func(verb string, args cbor.Map) (int, cbor.Map, bool) {
				if verb != "settings.set" {
					return 0, nil, false
				}
				return code, body, true
			}
		})
	}
	s := startServer(t, f, TestEnv{})
	o := dial(t, s)
	o.handshake("", psks[0])
	o.do("auth/owner", cbor.M(1, kidOf(pub), 2, authSig(t, k, o.h, kidOf(pub))))
	body := cbor.M(2, "JP", 31, cbor.M(1, []byte{1}))

	answer(0, cbor.M(2, "JP"))
	if code, b := o.do("settings/set", body); code != 0 || func() bool { v, _ := b.Get(2); return v != "JP" }() {
		t.Fatalf("ok: code %d body %v", code, b)
	}
	answer(hEInput, cbor.M(1, uint64(13)))
	if code, d := o.do("settings/set", body); code != ERejected || func() bool { v, _ := d.Get(2); return v != uint64(13) }() {
		t.Fatalf("hEInput: code %d detail %v, want E_REJECTED{2: 13}", code, d)
	}
	answer(hEReject, cbor.M(1, uint64(14)))
	if code, d := o.do("settings/set", body); code != ERejected || func() bool { v, _ := d.Get(2); return v != uint64(14) }() {
		t.Fatalf("hEReject: code %d detail %v", code, d)
	}
	answer(hEUnsupported, cbor.M(1, uint64(20)))
	if code, d := o.do("settings/set", body); code != EUnsupported || func() bool { a, _ := d.Get(1); b, _ := d.Get(2); return a != "settings/set" || b != uint64(20) }() {
		t.Fatalf("hEUnsupported+reason: code %d detail %v", code, d)
	}
	answer(hEUnsupported, cbor.M())
	if code, d := o.do("settings/set", body); code != EUnsupported || func() bool { _, has := d.Get(2); return has }() {
		t.Fatalf("hEUnsupported without a reason: code %d detail %v (P2's form)", code, d)
	}
	answer(hEStorage, cbor.M())
	if code, _ := o.do("settings/set", body); code != EStorage {
		t.Fatalf("hEStorage: code %d", code)
	}
	m := dial(t, s)
	m.handshake("", psks[4])
	if code, _ := m.do("settings/set", body); code != EForbidden {
		t.Fatalf("member: code %d", code)
	}
}
