package node

import (
	"bytes"
	"crypto/ecdsa"
	"slices"
	"testing"

	"batman-prov/cbor"
	"batman-prov/proto"
	"batman-prov/provstore"
)

// envelopeOver: as rig.envelope, with the h the owner signed over (hSig) and the nonce_helper given by the caller.
func envelopeOver(hSig, nh []byte, typ string, body cbor.Map, signer *ecdsa.PrivateKey) []byte {
	ah, _ := proto.ArgsHash(body)
	in, _ := proto.OwnerOpInput(hSig, nh, typ, ah)
	sig, _ := proto.SignES256(signer, in)
	b := append(append(cbor.Map(nil), body...), cbor.Entry{K: uint64(31), V: cbor.M(1, typ, 2, sig)})
	raw, _ := cbor.Encode(cbor.M(0, []any{uint64(1), uint64(0)}, 1, uint64(9), 2, typ, 3, b))
	return raw
}

// docs/design/254-app-s1.md §8 item 6 (man in the middle: "h swapped -> the node refuses the owner-op"). With a relay
// in the middle the phone's session has hPhone and the node's has r.h. The helper builds the owner-op input from the h
// of ITS session and only tries nonce_helpers issued for that h, so each of these is refused:
//  1. signed over hPhone, with a nonce of the node's session (the relay fetched it) — the h in the signature;
//  2. signed over r.h, with a nonce issued for hPhone — nothing but the nonce's binding to h stands in the way;
//  3. signature and nonce both of the phone's session, presented on the node's session.
//
// Negative controls (mutants of node.go, never committed): without the two `v.h == h` checks (verifyOwnerOp's filter
// and takeHelperNonce) case 2 is accepted; either check alone still REFUSES it, but the filter has a second job that
// this test does not see (another session's failed owner-op must not burn this session's nonce):
// TestFailedOwnerOpOfAnotherSessionKeepsThisNonce. With the input built from the nonce's h as well, case 3 is
// accepted too. Case 1 has no mutant of its own here: it is refused by the signature check itself.
func TestOwnerOpSignedOverAnotherSessionsH(t *testing.T) {
	r := newRig(t, provstore.Unclaimed)
	if c, _ := r.claim(); c != OK {
		t.Fatal("claim")
	}
	hPhone := bytes.Repeat([]byte{0xa5}, len(r.h))
	if bytes.Equal(hPhone, r.h) {
		t.Fatal("the two h must differ")
	}
	keys := []any{"ssh-ed25519 AAAAC3Nz owner"}
	before := append([]string(nil), r.sys.keys...)
	nonceFor := func(h []byte) []byte {
		c, res := r.call("nonce", cbor.M(1, h))
		if c != OK {
			t.Fatal("nonce")
		}
		x, _ := res.Get(2)
		return x.([]byte)
	}
	for _, c := range []struct {
		what         string
		hSig, hNonce []byte
	}{
		{"signed over another h, this session's nonce", hPhone, r.h},
		{"signed over this h, a nonce issued for another h", r.h, hPhone},
		{"signature and nonce of another h", hPhone, hPhone},
	} {
		env := envelopeOver(c.hSig, nonceFor(c.hNonce), "ssh_keys/set", cbor.M(1, keys), r.owner)
		if code, _ := r.call("ssh_keys.set", cbor.M(1, r.h, 2, env)); code != EForbidden {
			t.Errorf("%s: code %d, want E_FORBIDDEN", c.what, code)
		}
		if !slices.Equal(r.sys.keys, before) {
			t.Fatalf("%s: a refused owner-op changed the keys: %v -> %v", c.what, before, r.sys.keys)
		}
	}
	// the same owner, the same body, over this session's h with its nonce: accepted (the refusals are about h), and
	// the keys are now the ones in the body
	if c, _ := r.call("ssh_keys.set", cbor.M(1, r.h, 2, envelopeOver(r.h, nonceFor(r.h), "ssh_keys/set", cbor.M(1, keys), r.owner))); c != OK {
		t.Fatalf("owner-op over this session's h: code %d", c)
	}
	if slices.Equal(r.sys.keys, before) || !slices.Contains(r.sys.keys, keys[0].(string)) {
		t.Fatalf("the accepted owner-op did not set the keys: %v -> %v", before, r.sys.keys)
	}
}

// A failed owner-op of another session (same owner, other h) must not burn this session's nonce_helper. verifyOwnerOp
// only tries — and so only consumes — the nonces issued for the h of the session the owner-op arrived on; without its
// `v.h == h` filter every unexpired nonce is tried, and takeHelperNonce consumes whatever it is handed (219 §5.7: any
// attempt consumes), so session B's failure would delete session A's nonce and A's legitimate op would be refused.
//
// Negative control (mutant of node.go, never committed): the filter removed (M1) -> A's op is refused. Removing only
// takeHelperNonce's own h check (M2) is an equivalent mutant here: its only caller already filters on h; the white-box
// TestTakeHelperNonceOtherH below pins that check on its own.
func TestFailedOwnerOpOfAnotherSessionKeepsThisNonce(t *testing.T) {
	r := newRig(t, provstore.Unclaimed)
	if c, _ := r.claim(); c != OK {
		t.Fatal("claim")
	}
	hB := bytes.Repeat([]byte{0xa5}, len(r.h))
	nonceFor := func(h []byte) []byte {
		c, res := r.call("nonce", cbor.M(1, h))
		if c != OK {
			t.Fatal("nonce")
		}
		x, _ := res.Get(2)
		return x.([]byte)
	}
	keys := []any{"ssh-ed25519 AAAAC3Nz owner"}
	before := append([]string(nil), r.sys.keys...)
	nA := nonceFor(r.h) // session A asks for its nonce first ...
	nB := nonceFor(hB)  // ... then session B asks for its own
	// B's op fails: signed over B's h, but over a nonce that was never issued (a stale one)
	stale := bytes.Repeat([]byte{0x5a}, len(nB))
	if bytes.Equal(stale, nA) || bytes.Equal(stale, nB) {
		t.Fatal("the stale nonce must differ")
	}
	if code, _ := r.call("ssh_keys.set", cbor.M(1, hB, 2, envelopeOver(hB, stale, "ssh_keys/set", cbor.M(1, keys), r.owner))); code != EForbidden {
		t.Fatalf("session B's op over a stale nonce: code %d, want E_FORBIDDEN", code)
	}
	if !slices.Equal(r.sys.keys, before) {
		t.Fatalf("a refused owner-op changed the keys: %v -> %v", before, r.sys.keys)
	}
	// A's op with its own nonce, over its own h: accepted
	if code, _ := r.call("ssh_keys.set", cbor.M(1, r.h, 2, envelopeOver(r.h, nA, "ssh_keys/set", cbor.M(1, keys), r.owner))); code != OK {
		t.Fatalf("session A's op with its own nonce after session B's failure: code %d, want OK (B burnt A's nonce)", code)
	}
	if !slices.Contains(r.sys.keys, keys[0].(string)) {
		t.Fatalf("the accepted owner-op did not set the keys: %v -> %v", before, r.sys.keys)
	}
}

// White-box: takeHelperNonce refuses a nonce issued for another h (and, 219 §5.7, still consumes it).
func TestTakeHelperNonceOtherH(t *testing.T) {
	r := newRig(t, provstore.Unclaimed)
	_, n := r.nonce()
	other := bytes.Repeat([]byte{0xa5}, len(r.h))
	if r.n.takeHelperNonce(other, n) {
		t.Fatal("takeHelperNonce accepted a nonce issued for another h")
	}
	if r.n.takeHelperNonce(r.h, n) {
		t.Fatal("the nonce was not consumed by the refused attempt")
	}
	_, n2 := r.nonce()
	if !r.n.takeHelperNonce(r.h, n2) {
		t.Fatal("takeHelperNonce refused a fresh nonce of its own h")
	}
}
