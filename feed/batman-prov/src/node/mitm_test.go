package node

import (
	"bytes"
	"crypto/ecdsa"
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
// in the middle the phone's session has hPhone and the node's has r.h. The owner signs over hPhone; the helper builds
// the input from the h of ITS session, so the owner-op is refused — whether the nonce_helper was issued for the node's
// session (the relay fetched it) or for the phone's h.
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
	before := len(r.sys.keys)

	// the nonce is the node session's, the signature is over the phone session's h
	_, nh := r.nonce()
	if c, _ := r.call("ssh_keys.set", cbor.M(1, r.h, 2, envelopeOver(hPhone, nh, "ssh_keys/set", cbor.M(1, keys), r.owner))); c != EForbidden {
		t.Fatalf("owner-op over another h, node-session nonce: code %d", c)
	}
	// nonce and signature both of the phone's session, presented on the node's session
	c, res := r.call("nonce", cbor.M(1, hPhone))
	if c != OK {
		t.Fatal("nonce")
	}
	x, _ := res.Get(2)
	if c, _ := r.call("ssh_keys.set", cbor.M(1, r.h, 2, envelopeOver(hPhone, x.([]byte), "ssh_keys/set", cbor.M(1, keys), r.owner))); c != EForbidden {
		t.Fatalf("owner-op and nonce of another h: code %d", c)
	}
	if len(r.sys.keys) != before {
		t.Fatalf("a refused owner-op changed the keys: %v", r.sys.keys)
	}
	// the same owner, the same body, over this session's h: accepted (the refusals are about h)
	if c, _ := r.call("ssh_keys.set", cbor.M(1, r.h, 2, r.envelope("ssh_keys/set", cbor.M(1, keys), r.owner))); c != OK {
		t.Fatalf("owner-op over this session's h: code %d", c)
	}
}
