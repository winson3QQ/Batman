package provd

import (
	"crypto/ecdh"
	"crypto/rand"
	"crypto/sha256"
	"testing"
	"time"

	"batman-prov/cbor"
	"batman-prov/proto"
)

func startOn(t *testing.T, path string) *Server {
	s, err := NewServer(Config{HelperPath: path, Log: t.Logf, Board: "bcm2711", FW: "test"})
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

func (s *Server) stateIs(st string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.c.state == st && !s.c.needPSK && s.c.psks != nil
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
