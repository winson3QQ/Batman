package provd

import (
	"testing"

	"batman-prov/cbor"
)

// A r2 m1: the helper's EApply with a reason (settings.set rc 6) reaches the app as E_REJECTED{2: reason}
func TestApplyReasonOnTheWire(t *testing.T) {
	k, pub := ownerKey(t)
	f, psks := claimedHelper(t, pub)
	f.set(func(f *fakeHelper) {
		f.handler = func(v string, a cbor.Map) (int, cbor.Map, bool) {
			if v == "settings.set" {
				return hEApply, cbor.M(1, uint64(13)), true
			}
			return 0, nil, false
		}
	})
	s := startServer(t, f, TestEnv{})
	a := dial(t, s)
	a.handshake("", psks[0])
	a.do("auth/owner", cbor.M(1, kidOf(pub), 2, authSig(t, k, a.h, kidOf(pub))))
	code, det := a.do("settings/set", cbor.M(2, "JP", 31, cbor.M(1, "settings/set", 2, randB(64))))
	if r, _ := det.Get(2); code != ERejected || r != uint64(13) {
		t.Fatalf("rc 6 on the wire: %d %v, want E_REJECTED{2: 13}", code, det)
	}
}
