package provd

import (
	"crypto/ecdh"
	"crypto/rand"
	"crypto/sha256"
	"path/filepath"
	"slices"
	"sync"
	"testing"
	"time"

	"batman-prov/cbor"
	"batman-prov/node"
	"batman-prov/proto"
)

func startOn(t *testing.T, path string) *Server {
	s, err := NewServer(Config{HelperPath: path, Log: newLogCap(t).logf, Board: "bcm2711", FW: "test"})
	if err != nil {
		t.Fatal(err)
	}
	go s.Run()
	t.Cleanup(s.Stop)
	waitFor(t, "server ready", s.Ready)
	return s
}

func checkResp(k, nonce, h []byte, cert cbor.Map, ownerPub []byte) []byte {
	dac := cert[0].V.([]any)[0].([]byte)
	sn, _ := cert.Get(7)
	in, _ := proto.CheckMacInput(k, proto.ClientChal(nonce, h, dac, ownerPub), sn.([]byte))
	s := sha256.Sum256(in)
	return s[:]
}

// stateIs: provd has reached st and fetched what a session in it needs: the PSKs and the owner list (round 2 review
// B-2: between pollOnce setting "claimed" and info.owners returning, auth/owner can be refused with 3)
func (s *Server) stateIs(st string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.c.state == st && !s.c.needPSK && s.c.psks != nil && !s.c.needOwners && s.c.owners != nil
}

// 254-p2-impl §4.3 against node.go: claim with the real CheckMac (a wrong response first -> E_CLAIM_FAILED), the
// psk_owner session + auth/owner, then the re-acquire session (begin -> op/nonce -> claim/replay, one nonce pair).
// Negative control: provd sending claim.verify's fields in another order / the replay through a second nonce call
// makes the helper refuse (code 3 -> 9 / E_FORBIDDEN) and this test FAILs.
func TestRealHelperClaimAuthReplay(t *testing.T) {
	path, K := realHelper(t)
	s := startOn(t, path)
	s.mu.Lock()
	did := s.c.deviceID
	s.mu.Unlock()
	sk, pub := ownerKey(t)
	enc, _ := ecdh.P256().GenerateKey(rand.Reader)
	encPub := enc.PublicKey().Bytes()
	sigEnc, _ := proto.SignES256(sk, append([]byte(proto.LabelOwnerEnc), encPub...))

	p := dial(t, s)
	if !p.handshake(did, nil) {
		t.Fatal("NX handshake")
	}
	_, b := p.do("claim/begin", cbor.M(1, pub))
	if code, _ := p.do("claim/finish", cbor.M(1, randB(32), 2, encPub, 3, sigEnc)); code != EClaimFailed {
		t.Fatalf("a wrong response: %d (want E_CLAIM_FAILED)", code)
	}
	code, b := p.do("claim/begin", cbor.M(1, pub))
	nv, _ := b.Get(1)
	if code != 0 {
		t.Fatalf("claim/begin %d", code)
	}
	code, b = p.do("claim/finish", cbor.M(1, checkResp(K, nv.([]byte), p.h, p.cert, pub), 2, encPub, 3, sigEnc))
	if code != 0 {
		t.Fatalf("claim/finish %d %v", code, b)
	}
	tv, _ := b.Get(1)
	tag := tv.([]byte)
	if p.s.Role() != RoleOwner {
		t.Fatal("not owner after the claim")
	}
	p.c.Close()
	waitFor(t, "claimed state + PSKs", func() bool { return s.stateIs("claimed") && s.Sessions() == 0 })

	// psk_owner -> candidate -> auth/owner -> owner; info says claimed (1)
	q := dial(t, s)
	if !q.handshake("", proto.PskOwner(tag, did)) {
		t.Fatal("psk_owner handshake")
	}
	if code, _ := q.do("auth/owner", cbor.M(1, kidOf(pub), 2, authSig(t, sk, q.h, kidOf(pub)))); code != 0 || q.s.Role() != RoleOwner {
		t.Fatalf("auth/owner %d", code)
	}
	if _, info := q.do("info", cbor.M()); func() bool { v, _ := info.Get(7); return v != uint64(1) }() {
		t.Fatalf("info after the claim: %v", info)
	}
	q.c.Close()
	waitFor(t, "slot freed", func() bool { return s.Sessions() == 0 })

	// psk_replay = HKDF(ECDH(owner_enc, node ecdh_pub)) -> re-acquire; one nonce pair for CheckMac and owner-op
	r := dial(t, s)
	ecv, _ := p.cert.Get(4)
	nodeEC, err := ecdh.P256().NewPublicKey(ecv.([]byte))
	if err != nil {
		t.Fatal(err)
	}
	z, _ := enc.ECDH(nodeEC)
	if !r.handshake("", proto.PskReplay(z, did)) || r.s.Role() != RoleReacquire {
		t.Fatal("psk_replay handshake")
	}
	_, b = r.do("claim/begin", cbor.M(1, pub))
	nn, _ := b.Get(1)
	_, b = r.do("op/nonce", cbor.M())
	nh, _ := b.Get(1)
	body := cbor.M(1, checkResp(K, nn.([]byte), r.h, r.cert, pub))
	ah, _ := proto.ArgsHash(body)
	in, _ := proto.OwnerOpInput(r.h, nh.([]byte), "claim/replay", ah)
	sig, _ := proto.SignES256(sk, in)
	body = append(body, cbor.Entry{K: uint64(31), V: cbor.M(1, "claim/replay", 2, sig)})
	code, b = r.do("claim/replay", body)
	if tv2, _ := b.Get(1); code != 0 || string(tv2.([]byte)) != string(tag) {
		t.Fatalf("claim/replay %d %v", code, b)
	}
	if r.s.Role() != RoleOwner {
		t.Fatal("not owner after the replay")
	}
	_ = time.Second
}

// keysSys: stubSys that keeps what ssh_keys.set wrote
type keysSys struct {
	*stubSys
	mu   sync.Mutex
	keys []string
}

func (s *keysSys) AuthorizedKeys() ([]string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string(nil), s.keys...), nil
}
func (s *keysSys) SetAuthorizedKeys(l []string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.keys = append([]string(nil), l...)
	return nil
}

// docs/design/254-app-s1.md §8 item 6 (man in the middle) through provd AND node.go: the owner is logged in on two
// sessions (two h). An owner-op made for session A — signed over A's h, with a nonce A asked for — is refused when it
// is relayed on session B; so is one signed over B's h with A's nonce, and one signed over A's h with B's nonce. The
// same op made for B is accepted on B. Negative controls (mutants of node.go): see node/mitm_test.go.
func TestRealHelperOwnerOpRelayedToAnotherSession(t *testing.T) {
	sys := &keysSys{}
	path, K, _ := realHelperSys(t, func(root string) node.Sys {
		sys.stubSys = &stubSys{p5: filepath.Join(root, "p5")}
		return sys
	})
	s := startOn(t, path)
	s.mu.Lock()
	did := s.c.deviceID
	s.mu.Unlock()
	sk, pub := ownerKey(t)
	enc, _ := ecdh.P256().GenerateKey(rand.Reader)
	encPub := enc.PublicKey().Bytes()
	sigEnc, _ := proto.SignES256(sk, append([]byte(proto.LabelOwnerEnc), encPub...))
	p := dial(t, s)
	if !p.handshake(did, nil) {
		t.Fatal("NX handshake")
	}
	_, b := p.do("claim/begin", cbor.M(1, pub))
	nv, _ := b.Get(1)
	code, b := p.do("claim/finish", cbor.M(1, checkResp(K, nv.([]byte), p.h, p.cert, pub), 2, encPub, 3, sigEnc))
	if code != 0 {
		t.Fatalf("claim/finish %d %v", code, b)
	}
	tv, _ := b.Get(1)
	p.c.Close()
	waitFor(t, "claimed state + PSKs", func() bool { return s.stateIs("claimed") && s.Sessions() == 0 })

	owner := func() *phone {
		q := dial(t, s)
		if !q.handshake("", proto.PskOwner(tv.([]byte), did)) {
			t.Fatal("psk_owner handshake")
		}
		if code, _ := q.do("auth/owner", cbor.M(1, kidOf(pub), 2, authSig(t, sk, q.h, kidOf(pub)))); code != 0 || q.s.Role() != RoleOwner {
			t.Fatalf("auth/owner %d", code)
		}
		return q
	}
	a, bb := owner(), owner()
	if string(a.h) == string(bb.h) {
		t.Fatal("two sessions must have two h")
	}
	nonce := func(q *phone) []byte {
		code, r := q.do("op/nonce", cbor.M())
		if code != 0 {
			t.Fatalf("op/nonce %d", code)
		}
		v, _ := r.Get(1)
		return v.([]byte)
	}
	line := "ssh-ed25519 AAAAC3Nz owner"
	op := func(hSig, nh []byte) cbor.Map {
		body := cbor.M(1, []any{line})
		ah, _ := proto.ArgsHash(body)
		in, _ := proto.OwnerOpInput(hSig, nh, "ssh_keys/set", ah)
		sig, _ := proto.SignES256(sk, in)
		return append(body, cbor.Entry{K: uint64(31), V: cbor.M(1, "ssh_keys/set", 2, sig)})
	}
	before, _ := sys.AuthorizedKeys()
	for _, c := range []struct {
		what       string
		hSig, from *phone
	}{
		{"made for session A (its h, its nonce)", a, a},
		{"signed over B's h with A's nonce", bb, a},
		{"signed over A's h with B's nonce", a, bb},
	} {
		// the nonce is asked for just before: a verification attempt uses up the nonces of its h
		if code, _ := bb.do("ssh_keys/set", op(c.hSig.h, nonce(c.from))); code != EForbidden {
			t.Errorf("%s, sent on session B: code %d, want E_FORBIDDEN", c.what, code)
		}
		if now, _ := sys.AuthorizedKeys(); !slices.Equal(now, before) {
			t.Fatalf("%s: a refused owner-op changed the keys: %v -> %v", c.what, before, now)
		}
	}
	if code, r := bb.do("ssh_keys/set", op(bb.h, nonce(bb))); code != 0 {
		t.Fatalf("the op made for session B, on B: code %d %v", code, r)
	}
	if now, _ := sys.AuthorizedKeys(); !slices.Equal(now, []string{line}) {
		t.Fatalf("the accepted owner-op did not set the keys: %v", now)
	}
}
