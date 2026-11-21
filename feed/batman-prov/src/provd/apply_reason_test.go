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

// 329-sshkeys-cut §3.4: ssh_keys.set's "not known to be persisted" (helper EApply{1: 25}) reaches the app as
// E_REJECTED{2: 25}; the helper error code EInput (also 25) never shows up as a reason (different namespaces)
func TestSSHUnpersistedReasonOnTheWire(t *testing.T) {
	for _, c := range []struct {
		code   int
		body   cbor.Map
		reason any
	}{{hEApply, cbor.M(1, uint64(25)), uint64(25)}, {hEInput, cbor.M(), nil}, {hEApply, cbor.M(), nil}} {
		k, pub := ownerKey(t)
		f, psks := claimedHelper(t, pub)
		f.set(func(f *fakeHelper) {
			f.handler = func(v string, a cbor.Map) (int, cbor.Map, bool) {
				if v == "ssh_keys.set" {
					return c.code, c.body, true
				}
				return 0, nil, false
			}
		})
		s := startServer(t, f, TestEnv{})
		a := dial(t, s)
		a.handshake("", psks[0])
		a.do("auth/owner", cbor.M(1, kidOf(pub), 2, authSig(t, k, a.h, kidOf(pub))))
		code, det := a.do("ssh_keys/set", cbor.M(1, []any{"ssh-ed25519 AAAAx x"}, 31, cbor.M(1, "ssh_keys/set", 2, randB(64))))
		r, _ := det.Get(2)
		if code != ERejected || r != c.reason {
			t.Fatalf("helper %d %v -> %d %v, want E_REJECTED reason %v", c.code, c.body, code, det, c.reason)
		}
	}
}
