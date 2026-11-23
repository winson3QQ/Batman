package node

import (
	"bytes"
	"testing"

	"batman-prov/cbor"
	"batman-prov/keystore"
	"batman-prov/provstore"
)

// stubIdentity is a keystore.Identity that is not the file backend: it answers with fixed values and records which
// methods the node called. #255 phase 1 PR 1: the node must reach the identity only through the interface, so a
// second backend (the 608B) can be plugged in later without touching the node.
type stubIdentity struct {
	keystore.Identity // the real file backend, for the methods this test does not override
	cert              []byte
	sn                []byte
	ecdhPub           []byte
	calls             map[string]int
}

func (s *stubIdentity) Cert() []byte { s.calls["Cert"]++; return append([]byte(nil), s.cert...) }
func (s *stubIdentity) SN() []byte   { s.calls["SN"]++; return append([]byte(nil), s.sn...) }
func (s *stubIdentity) ECDHPub() []byte {
	s.calls["ECDHPub"]++
	return append([]byte(nil), s.ecdhPub...)
}
func (s *stubIdentity) Backend() string { return "stub" }

// The read-only identity verbs answer from whatever Identity the node was given, on each request: the node neither
// reads the file backend directly nor caches identity values. Negative controls: with Node.KS / New typed
// *keystore.Keystore this file does not compile; with info.cert answered from keystore.Load(n.P.Identity())
// instead of n.KS, this test fails while the existing TestReadOnly* tests still pass.
func TestNodeUsesIdentityInterface(t *testing.T) {
	r := newRig(t, provstore.Unclaimed)
	stub := &stubIdentity{
		Identity: r.ks,
		cert:     []byte("stub-cert-der"),
		sn:       []byte{9, 8, 7, 6, 5, 4, 3, 2, 1},
		ecdhPub:  append([]byte{4}, bytes.Repeat([]byte{0xAB}, 64)...),
		calls:    map[string]int{},
	}
	r.n = New(r.n.P, stub, r.sys, func(string, ...any) {})
	r.n.Verdict = provstore.Unclaimed

	c, res := r.call("info.cert", cbor.M())
	if c != OK {
		t.Fatalf("info.cert: code %d", c)
	}
	gotCert, _ := res.Get(1)
	gotSN, _ := res.Get(2)
	if !bytes.Equal(gotCert.([]byte), stub.cert) || !bytes.Equal(gotSN.([]byte), stub.sn) {
		t.Fatalf("info.cert answered %x / %x, not the stub's values", gotCert, gotSN)
	}
	c, res = r.call("info.ecdh_pub", cbor.M())
	if c != OK {
		t.Fatalf("info.ecdh_pub: code %d", c)
	}
	gotPub, _ := res.Get(1)
	if !bytes.Equal(gotPub.([]byte), stub.ecdhPub) {
		t.Fatalf("info.ecdh_pub answered %x, not the stub's value", gotPub)
	}
	if stub.calls["Cert"] != 1 || stub.calls["SN"] != 1 || stub.calls["ECDHPub"] != 1 {
		t.Fatalf("calls %v", stub.calls)
	}
}
