package provd

// network/update end to end against the REAL helper (docs/design/254-net-update-members.md §6 U13 / U15 / U16):
// claim -> join v1 -> update v2 through provd; a wrong shape is E_BAD_OBJECT without a provd CRIT line; after the
// update the node serves psk_member of v2 (and not v1's); a chain that fits 8 chunks applies, one that needs 9 ends
// the session with the record unchanged.

import (
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"fmt"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"golang.org/x/crypto/chacha20poly1305"

	"batman-prov/cbor"
	"batman-prov/cose"
	"batman-prov/keystore"
	"batman-prov/node"
	"batman-prov/proto"
)

// wlSys: stubSys with a live wireless the helper can change (the update path needs setkey / current wireless)
type wlSys struct {
	stubSys
	mu sync.Mutex
	wl [3]string
}

func (s *wlSys) SetKeyNoPersist(k, id, ch string) error {
	s.mu.Lock()
	s.wl = [3]string{k, id, ch}
	s.mu.Unlock()
	return nil
}
func (s *wlSys) CurrentWireless() (string, string, string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.wl[0], s.wl[1], s.wl[2], nil
}
func (s *wlSys) RadioState() (bool, bool, error) { return false, false, nil }
func (s *wlSys) ForgetMesh() error               { return nil }

type logCap struct {
	mu    sync.Mutex
	lines []string
	t     *testing.T
}

func (l *logCap) logf(f string, a ...any) {
	l.mu.Lock()
	l.lines = append(l.lines, fmt.Sprintf(f, a...))
	l.mu.Unlock()
	l.t.Logf(f, a...)
}

func (l *logCap) has(sub string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	for _, x := range l.lines {
		if strings.Contains(x, sub) {
			return true
		}
	}
	return false
}

// ---- signed network objects (219 §7), as the app builds them --------------------------------------------------------

func tSign1(t *testing.T, k *ecdsa.PrivateKey, ct, label string, pl cbor.Map) any {
	prot, _ := cbor.Encode(cbor.M(1, int64(-7), 3, ct))
	b, _ := cbor.Encode(pl)
	ss, _ := cbor.Encode([]any{"Signature1", prot, []byte(label), b})
	sig, err := proto.SignES256(k, ss)
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := cbor.Encode(cbor.Tag{Num: 18, V: []any{prot, cbor.Map{}, b, sig}})
	x, _ := cbor.Decode(raw)
	return x
}

type tNet struct {
	nid       []byte
	ver       uint64
	root      []byte
	cfg, mem  any
	sec       any
	admin     *ecdsa.PrivateKey
	nMembers  int
	prevCfg   any
	meshID    string
	sae       string
	ksTarget  *keystore.Keystore
	adminPubs []any
}

func (n *tNet) build(t *testing.T) *tNet {
	var prev any
	if n.prevCfg != nil {
		s, err := cose.Sign1Payload(n.prevCfg, cose.CTNetcfg, proto.LabelNetcfg)
		if err != nil {
			t.Fatal(err)
		}
		prev = s.ObjectHash
	}
	n.cfg = tSign1(t, n.admin, cose.CTNetcfg, proto.LabelNetcfg, cbor.M(1, n.nid, 2, n.ver, 3, prev, 4, "team", 5, "US",
		6, cbor.M(1, n.meshID, 2, uint64(28), 3, uint64(2)), 8, n.adminPubs))
	var ms []any
	for i := 0; i < n.nMembers; i++ {
		ms = append(ms, cbor.M(1, randB(32), 2, randB(65), 3, fmt.Sprintf("member-%02d", i), 4, randB(65), 5, randB(65)))
	}
	n.mem = tSign1(t, n.admin, cose.CTMembers, proto.LabelMembers, cbor.M(1, n.nid, 2, n.ver, 3, nil, 4, ms, 5, []any{}, 6, []any{}, 7, []any{}))
	dacHash := sha256.Sum256(n.ksTarget.DACPub())
	other := append(append([]byte(nil), n.nid...), byte(n.ver>>24), byte(n.ver>>16), byte(n.ver>>8), byte(n.ver))
	eph, _ := ecdh.P256().GenerateKey(rand.Reader)
	z, err := proto.ECDHX(eph, n.ksTarget.ECDHPub())
	if err != nil {
		t.Fatal(err)
	}
	rprot, _ := cbor.Encode(cbor.M(1, int64(-25)))
	cek := proto.HKDF32(z, cose.KDFContext(dacHash[:], rprot, other))
	prot, _ := cbor.Encode(cbor.M(1, uint64(24)))
	aad, _ := cbor.Encode([]any{"Encrypt", prot, []byte(proto.LabelSecrets)})
	aead, _ := chacha20poly1305.New(cek)
	iv := randB(chacha20poly1305.NonceSize)
	pt, _ := cbor.Encode(cbor.M(1, []byte(n.sae), 2, n.root))
	ep := eph.PublicKey().Bytes()
	enc := cbor.Tag{Num: 96, V: []any{prot, cbor.M(5, iv), aead.Seal(nil, iv, pt, aad),
		[]any{[]any{rprot, cbor.M(int64(-1), cbor.M(1, uint64(2), int64(-1), uint64(1), int64(-2), ep[1:33], int64(-3), ep[33:])), []byte{}}}}}
	n.sec = tSign1(t, n.admin, cose.CTSecrets, proto.LabelSecrets, cbor.M(1, n.nid, 2, n.ver, 3, dacHash[:], 4, enc))
	return n
}

func (n *tNet) next(t *testing.T, members int) *tNet {
	v := n.ver + 1
	return (&tNet{nid: n.nid, ver: v, root: randB(32), admin: n.admin, adminPubs: n.adminPubs, nMembers: members, prevCfg: n.cfg,
		meshID: fmt.Sprintf("m%d", v), sae: fmt.Sprintf("sae-v%d-pass", v), ksTarget: n.ksTarget}).build(t)
}

func updateBody(vs ...*tNet) cbor.Map {
	var chain []any
	for i, v := range vs {
		if i == len(vs)-1 {
			chain = append(chain, cbor.M(1, v.cfg, 2, v.mem, 3, v.sec))
		} else {
			chain = append(chain, cbor.M(1, v.cfg, 2, v.mem))
		}
	}
	return cbor.M(1, chain)
}

// ownerOp appends key 31 for typ over body (op/nonce first)
func ownerOp(t *testing.T, p *phone, sk *ecdsa.PrivateKey, typ string, body cbor.Map) cbor.Map {
	code, b := p.do("op/nonce", cbor.M())
	if code != 0 {
		t.Fatalf("op/nonce %d", code)
	}
	nh, _ := b.Get(1)
	ah, _ := proto.ArgsHash(body)
	in, _ := proto.OwnerOpInput(p.h, nh.([]byte), typ, ah)
	sig, _ := proto.SignES256(sk, in)
	return append(body, cbor.Entry{K: uint64(31), V: cbor.M(1, typ, 2, sig)})
}

// infoVersion: info key 9; info.net is rate-limited in the helper (F16: keys 9-11 absent when refused) -> paced retries
func infoVersion(t *testing.T, p *phone) uint64 {
	for i := 0; i < 15; i++ {
		_, info := p.do("info", cbor.M())
		if v, ok := info.Get(9); ok {
			u, _ := v.(uint64)
			return u
		}
		time.Sleep(300 * time.Millisecond)
	}
	t.Fatal("info without key 9 for 4.5 s")
	return 0
}

func TestRealHelperNetworkUpdate(t *testing.T) {
	path, K, ks := realHelperSys(t, func(root string) node.Sys {
		return &wlSys{stubSys: stubSys{p5: filepath.Join(root, "p5")}, wl: [3]string{"op-key-12345", "m0", "28"}}
	})
	lc := &logCap{t: t}
	s, err := NewServer(Config{HelperPath: path, Log: lc.logf, Board: "bcm2711", FW: "test"})
	if err != nil {
		t.Fatal(err)
	}
	go s.Run()
	t.Cleanup(s.Stop)
	waitFor(t, "server ready", s.Ready)
	s.mu.Lock()
	did := s.c.deviceID
	s.mu.Unlock()

	// claim (as TestRealHelperClaimAuthReplay)
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
	tag := tv.([]byte)
	p.c.Close()
	waitFor(t, "claimed + PSKs", func() bool { return s.stateIs("claimed") && s.Sessions() == 0 })

	owner := func() *phone {
		q := dial(t, s)
		if !q.handshake("", proto.PskOwner(tag, did)) {
			t.Fatal("psk_owner handshake")
		}
		if code, _ := q.do("auth/owner", cbor.M(1, kidOf(pub), 2, authSig(t, sk, q.h, kidOf(pub)))); code != 0 {
			t.Fatalf("auth/owner %d", code)
		}
		return q
	}
	adm, admPubB := ownerKey(t)
	admPub := []any{admPubB}
	v1 := (&tNet{nid: randB(16), ver: 1, root: randB(32), admin: adm, adminPubs: admPub, nMembers: 1, meshID: "m1",
		sae: "sae-v1-pass", ksTarget: ks}).build(t)

	q := owner()
	if code, b := q.do("network/join", ownerOp(t, q, sk, "network/join", cbor.M(1, v1.cfg, 2, v1.mem, 3, v1.sec))); code != 0 {
		t.Fatalf("join %d %v", code, b)
	}

	// U15: a wrong shape -> E_BAD_OBJECT, no provd CRIT line
	for name, body := range map[string]cbor.Map{"not an array": cbor.M(1, "x"), "old shape": cbor.M(1, []any{v1.cfg}, 2, v1.sec)} {
		if code, _ := q.do("network/update", body); code != EBadObject {
			t.Fatalf("%s: %d, want E_BAD_OBJECT", name, code)
		}
	}
	if lc.has("CRIT") {
		t.Fatal("a malformed update logged a provd CRIT line")
	}

	// update v2 (new net_root)
	v2 := v1.next(t, 1)
	if code, b := q.do("network/update", updateBody(v2)); code != 0 {
		t.Fatalf("update v2 %d %v", code, b)
	}
	if v := infoVersion(t, q); v != 2 {
		t.Fatalf("info key 9 = %d after v2", v)
	}
	q.c.Close()
	waitFor(t, "member + PSKs of v2", func() bool { return s.stateIs("member") && s.Sessions() == 0 })

	// U16: psk_member of v2 opens a member session; v1's does not (fake msg2)
	m := dial(t, s)
	if !m.handshake("", proto.PskMember(v2.root, v2.nid, 2)) || m.s.Role() != RoleMember {
		t.Fatal("psk_member(v2) did not open a member session after the update")
	}
	m.c.Close()
	waitFor(t, "slot freed", func() bool { return s.Sessions() == 0 })
	o := dial(t, s)
	if o.handshake("", proto.PskMember(v1.root, v1.nid, 1)) {
		t.Fatal("psk_member(v1) still opens a session after the update to v2")
	}
	o.c.Close()
	waitFor(t, "slot freed", func() bool { return s.Sessions() == 0 })

	// U13: 16 members per step; as many steps as fit 8 chunks -> applies; one more step (9 chunks) -> the session ends,
	// the version unchanged
	const slice = 8000
	chain := []*tNet{v2.next(t, 16)}
	for {
		nxt := chain[len(chain)-1].next(t, 16)
		raw, _ := cbor.Encode(updateBody(append(chain, nxt)...))
		if len(raw) > 8*slice {
			break
		}
		chain = append(chain, nxt)
	}
	fits, _ := cbor.Encode(updateBody(chain...))
	step1, _ := cbor.Encode(cbor.M(1, chain[0].cfg, 2, chain[0].mem))
	t.Logf("U13 sizes: one step with 16 members = %d B; %d steps = %d B (%d chunks of %d B)", len(step1), len(chain), len(fits), (len(fits)+slice-1)/slice, slice)
	sendChunked := func(p *phone, body []byte, upTo int) { // upTo: chunks to send (0 = all)
		p.id++
		total := (len(body) + slice - 1) / slice
		for i := 0; i < total && (upTo == 0 || i < upTo); i++ {
			end := (i + 1) * slice
			if end > len(body) {
				end = len(body)
			}
			e, _ := cbor.Encode(cbor.M(0, []any{uint64(1), uint64(0)}, 1, p.id, 2, "network/update", 3, body[i*slice:end],
				6, cbor.M(1, uint64(i+1), 2, uint64(total))))
			if len(e)+16 > MaxMsg {
				t.Fatalf("chunk envelope %d B > MaxMsg", len(e)+16)
			}
			p.sendEnv(e)
		}
	}
	q = owner()
	sendChunked(q, fits, 0)
	r := q.resp(10 * time.Second)
	if r == nil {
		t.Fatal("8-chunk update: the session ended")
	}
	if st, _ := r.Get(4); st != uint64(0) {
		t.Fatalf("8-chunk update: %v", r)
	}
	want := chain[len(chain)-1].ver
	if v := infoVersion(t, q); v != want {
		t.Fatalf("after the 8-chunk update: version %d, want %d", v, want)
	}
	nine := chain[len(chain)-1].next(t, 16)
	more := []*tNet{nine}
	for {
		raw, _ := cbor.Encode(updateBody(more...))
		if len(raw) > 8*slice {
			break
		}
		more = append(more, more[len(more)-1].next(t, 16))
	}
	big, _ := cbor.Encode(updateBody(more...))
	sendChunked(q, big, 1) // the first chunk already declares 9 parts: provd ends the session at once (F9)
	if !q.closedWithin(3 * time.Second) {
		t.Fatalf("a %d-chunk update did not end the session", (len(big)+slice-1)/slice)
	}
	waitFor(t, "slot freed", func() bool { return s.Sessions() == 0 })
	q = owner()
	if v := infoVersion(t, q); v != want {
		t.Fatalf("after the 9-chunk attempt: version %d, want %d (unchanged)", v, want)
	}
}
