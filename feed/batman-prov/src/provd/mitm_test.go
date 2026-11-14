package provd

import (
	"testing"

	"batman-prov/cbor"
	"batman-prov/proto"
)

// docs/design/254-app-s1.md §8 item 6 (man in the middle: "h swapped -> the node refuses"). A relay between the phone
// and the node ends up with two Noise sessions and two different h; the owner's auth/owner signature is over the h of
// the session the PHONE is in. provd checks it against the h of the session it arrived on: the signature made for
// session A (accepted there) is refused when replayed on session B, and so is one that leaves h out.
func TestAuthOwnerSignedOverAnotherSessionsH(t *testing.T) {
	k, pub := ownerKey(t)
	f, psks := claimedHelper(t, pub)
	s := startServer(t, f, TestEnv{})
	a, b := dial(t, s), dial(t, s)
	if !a.handshake("", psks[0]) || !b.handshake("", psks[0]) {
		t.Fatal("psk_owner handshake")
	}
	if string(a.h) == string(b.h) || len(a.h) != 32 {
		t.Fatal("two handshakes must give two h")
	}
	kid := kidOf(pub)
	// session A logs in; the very signature it sent is then replayed on session B
	forA := authSig(t, k, a.h, kid)
	if code, _ := a.do("auth/owner", cbor.M(1, kid, 2, forA)); code != 0 || a.s.Role() != RoleOwner {
		t.Fatalf("auth/owner on session A: code %d", code)
	}
	if code, _ := b.do("auth/owner", cbor.M(1, kid, 2, forA)); code != EForbidden {
		t.Fatalf("a signature over another session's h: code %d", code)
	}
	noH, err := proto.SignES256(k, append([]byte(proto.LabelOwnerAuth), kid...))
	if err != nil {
		t.Fatal(err)
	}
	if code, _ := b.do("auth/owner", cbor.M(1, kid, 2, noH)); code != EForbidden {
		t.Fatalf("a signature that leaves h out: code %d", code)
	}
	if b.s.Role() != RoleCandidate {
		t.Fatalf("role %d after refused auth/owner", b.s.Role())
	}
	// the same key over this session's own h is accepted (the refusals above are about h, not the key)
	if code, _ := b.do("auth/owner", cbor.M(1, kid, 2, authSig(t, k, b.h, kid))); code != 0 || b.s.Role() != RoleOwner {
		t.Fatalf("auth/owner over this session's h: code %d role %d", code, b.s.Role())
	}
}
