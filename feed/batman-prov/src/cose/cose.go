// Package cose verifies the signed objects the helper accepts (219-protocol §7): COSE_Sign1 (tag 18, ES256,
// low-s, EMPTY unprotected header, protected = {1: -7, 3: content type}, external_aad = the object's label) and
// decrypts the COSE_Encrypt (tag 96) inside net_secrets: ChaCha20/Poly1305 (alg 24) with one ECDH-ES + HKDF-256
// recipient (alg -25), ephemeral key in recipient header -1, KDF context per §7.3. Unknown fields in a signed
// payload are rejected by the callers (§5.6); every input is decoded strictly (cbor package).
package cose

import (
	"bytes"
	"crypto/sha256"
	"errors"

	"golang.org/x/crypto/chacha20poly1305"

	"batman-prov/cbor"
	"batman-prov/proto"
)

// Content types (§5.6).
const (
	CTNetcfg  = "batman/netcfg"
	CTMembers = "batman/members"
	CTSecrets = "batman/secrets"
)

var errBad = errors.New("cose: bad object") // never says which check failed (§5.2 E_BAD_OBJECT)

// Sign1 is a verified COSE_Sign1: its decoded payload and its OBJECT_HASH (§7.1).
type Sign1 struct {
	Payload    cbor.Map
	ObjectHash []byte
	SignerPub  []byte
}

// VerifySign1 checks a COSE_Sign1 given as a decoded item (tag 18) against up to 4 signer keys.
func VerifySign1(item any, contentType, label string, pubs [][]byte) (*Sign1, error) {
	t, ok := item.(cbor.Tag)
	if !ok || t.Num != 18 {
		return nil, errBad
	}
	a, ok := t.V.([]any)
	if !ok || len(a) != 4 {
		return nil, errBad
	}
	prot, ok1 := a[0].([]byte)
	unprot, ok2 := a[1].(cbor.Map)
	payload, ok3 := a[2].([]byte)
	sig, ok4 := a[3].([]byte)
	if !ok1 || !ok2 || !ok3 || !ok4 || len(unprot) != 0 || len(sig) != 64 {
		return nil, errBad
	}
	ph, err := cbor.Decode(prot)
	if err != nil {
		return nil, errBad
	}
	want, _ := cbor.Encode(cbor.M(1, int64(-7), 3, contentType))
	if got, _ := cbor.Encode(ph); !bytes.Equal(got, want) {
		return nil, errBad
	}
	ss, err := cbor.Encode([]any{"Signature1", prot, []byte(label), payload})
	if err != nil {
		return nil, errBad
	}
	var signer []byte
	for i, p := range pubs {
		if i >= 4 {
			break
		}
		if proto.VerifyES256(p, ss, sig) {
			signer = p
			break
		}
	}
	if signer == nil {
		return nil, errBad
	}
	pl, err := cbor.Decode(payload)
	if err != nil {
		return nil, errBad
	}
	pm, ok := pl.(cbor.Map)
	if !ok {
		return nil, errBad
	}
	h := sha256.Sum256(ss)
	return &Sign1{Payload: pm, ObjectHash: h[:], SignerPub: signer}, nil
}

// Sign1Payload parses a COSE_Sign1 exactly as VerifySign1 does — the same structure, protected header and content type
// checks, the same OBJECT_HASH — but does NOT check the signature. Use it ONLY on objects the helper itself verified when
// it accepted them and stored in its root-only record (docs/design/254-wireless-txn.md §2): after an admin handover the
// stored object is signed by admins that are no longer in the record's admin set (219 §7.1), so re-verifying it against
// rec.Admins fails although nothing is wrong. Anything received from outside goes through VerifySign1. SignerPub is nil.
func Sign1Payload(item any, contentType, label string) (*Sign1, error) {
	t, ok := item.(cbor.Tag)
	if !ok || t.Num != 18 {
		return nil, errBad
	}
	a, ok := t.V.([]any)
	if !ok || len(a) != 4 {
		return nil, errBad
	}
	prot, ok1 := a[0].([]byte)
	unprot, ok2 := a[1].(cbor.Map)
	payload, ok3 := a[2].([]byte)
	sig, ok4 := a[3].([]byte)
	if !ok1 || !ok2 || !ok3 || !ok4 || len(unprot) != 0 || len(sig) != 64 {
		return nil, errBad
	}
	ph, err := cbor.Decode(prot)
	if err != nil {
		return nil, errBad
	}
	want, _ := cbor.Encode(cbor.M(1, int64(-7), 3, contentType))
	if got, _ := cbor.Encode(ph); !bytes.Equal(got, want) {
		return nil, errBad
	}
	ss, err := cbor.Encode([]any{"Signature1", prot, []byte(label), payload})
	if err != nil {
		return nil, errBad
	}
	pl, err := cbor.Decode(payload)
	if err != nil {
		return nil, errBad
	}
	pm, ok := pl.(cbor.Map)
	if !ok {
		return nil, errBad
	}
	h := sha256.Sum256(ss)
	return &Sign1{Payload: pm, ObjectHash: h[:]}, nil
}

// ECDHFunc returns the x-coordinate shared secret of the node's ECDH key with a peer public key (the keystore's).
type ECDHFunc func(peerPub65 []byte) ([]byte, error)

// Decrypt opens the COSE_Encrypt of net_secrets / member_secrets for target identity partyV with the KDF
// context [24, [nil,nil,nil], [partyV,nil,nil], [256, recipient_protected, other]], other = net_id ‖ u32BE(version).
func Decrypt(item any, label string, partyV, other []byte, ecdhf ECDHFunc) ([]byte, error) {
	t, ok := item.(cbor.Tag)
	if !ok || t.Num != 96 {
		return nil, errBad
	}
	a, ok := t.V.([]any)
	if !ok || len(a) != 4 {
		return nil, errBad
	}
	prot, ok1 := a[0].([]byte)
	unprot, ok2 := a[1].(cbor.Map)
	ct, ok3 := a[2].([]byte)
	recips, ok4 := a[3].([]any)
	if !ok1 || !ok2 || !ok3 || !ok4 || len(recips) != 1 || len(unprot) != 1 {
		return nil, errBad
	}
	if want, _ := cbor.Encode(cbor.M(1, uint64(24))); !bytes.Equal(prot, want) {
		return nil, errBad
	}
	ivAny, _ := unprot.Get(5)
	iv, ok := ivAny.([]byte)
	if !ok || len(iv) != chacha20poly1305.NonceSize {
		return nil, errBad
	}
	r, ok := recips[0].([]any)
	if !ok || len(r) != 3 {
		return nil, errBad
	}
	rprot, ok1 := r[0].([]byte)
	runprot, ok2 := r[1].(cbor.Map)
	if !ok1 || !ok2 || len(runprot) != 1 {
		return nil, errBad
	}
	if want, _ := cbor.Encode(cbor.M(1, int64(-25))); !bytes.Equal(rprot, want) {
		return nil, errBad
	}
	epkAny, _ := runprot.Get(int64(-1))
	epk, ok := epkAny.(cbor.Map)
	if !ok {
		return nil, errBad
	}
	kty, _ := epk.Get(1)
	crv, _ := epk.Get(int64(-1))
	xa, _ := epk.Get(int64(-2))
	ya, _ := epk.Get(int64(-3))
	x, okx := xa.([]byte)
	y, oky := ya.([]byte)
	if kty != uint64(2) || crv != uint64(1) || !okx || !oky || len(x) != 32 || len(y) != 32 || len(epk) != 4 {
		return nil, errBad
	}
	z, err := ecdhf(append(append([]byte{0x04}, x...), y...))
	if err != nil {
		return nil, errBad
	}
	ctx, err := cbor.Encode([]any{uint64(24), []any{nil, nil, nil}, []any{partyV, nil, nil}, []any{uint64(256), rprot, other}})
	if err != nil {
		return nil, errBad
	}
	cek := proto.HKDF32(z, ctx)
	aead, err := chacha20poly1305.New(cek)
	if err != nil {
		return nil, errBad
	}
	aad, err := cbor.Encode([]any{"Encrypt", prot, []byte(label)})
	if err != nil {
		return nil, errBad
	}
	pt, err := aead.Open(nil, iv, ct, aad)
	if err != nil {
		return nil, errBad
	}
	return pt, nil
}

// KDFContext is exported for the vector test only.
func KDFContext(partyV, rprot, other []byte) []byte {
	b, _ := cbor.Encode([]any{uint64(24), []any{nil, nil, nil}, []any{partyV, nil, nil}, []any{uint64(256), rprot, other}})
	return b
}
