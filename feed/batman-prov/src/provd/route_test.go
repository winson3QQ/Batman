package provd

import (
	"bytes"
	"testing"
	"time"

	"batman-prov/cbor"
)

const devID = "010203040506070809"

func TestNXInfoCtrlStatus(t *testing.T) {
	f := newFakeHelper(t)
	s := startServer(t, f, TestEnv{})
	p := dial(t, s)
	// control packets before the handshake (sock): CTRL constant, STATUS from the cache with the last 4 of device_id
	p.c.Write([]byte{CtlReadCtrl})
	b := make([]byte, 200)
	n, _ := p.c.Read(b)
	if b[0] != CtlReadCtrl || !bytes.Equal(b[1:n], Ctrl()) {
		t.Fatalf("CTRL %x", b[:n])
	}
	p.c.Write([]byte{CtlReadStatus})
	n, _ = p.c.Read(b)
	x, err := cbor.Decode(b[1:n])
	st := x.(cbor.Map)
	if v, _ := st.Get(5); err != nil || b[0] != CtlReadStatus || v != "0809" {
		t.Fatalf("STATUS %v", st)
	}
	if !p.handshake(devID, nil) {
		t.Fatal("NX handshake failed")
	}
	if p.s.Role() != RoleAnon {
		t.Fatalf("role %d", p.s.Role())
	}
	code, body := p.do("info", cbor.M())
	if code != 0 {
		t.Fatalf("info %d", code)
	}
	for k, want := range map[int]any{1: devID, 2: "dev", 3: "bcm2711", 4: "1.5.14-test", 7: uint64(0), 8: true} {
		if v, _ := body.Get(k); v != want {
			t.Fatalf("info key %d = %v (want %v)", k, v, want)
		}
	}
	for _, k := range []int{9, 10, 11} {
		if _, ok := body.Get(k); ok {
			t.Fatalf("anonymous info carried key %d", k)
		}
	}
	// a control packet after the handshake aborts
	p.c.Write([]byte{CtlReadStatus})
	if !p.closedWithin(time.Second) {
		t.Fatal("control packet after the handshake accepted")
	}
}

func TestTypeAndIdemRules(t *testing.T) {
	f := newFakeHelper(t)
	s := startServer(t, f, TestEnv{})
	p := dial(t, s)
	p.handshake(devID, nil)
	idem := bytes.Repeat([]byte{1}, 16)
	cases := []struct {
		typ   string
		extra []any
		code  int
		det   cbor.Map
	}{
		{"no/such", nil, EUnknownType, nil},
		{"reset", nil, EUnsupported, cbor.M(1, "reset", 2, uint64(9))},
		{"owner/add", nil, EUnsupported, cbor.M(1, "owner/add")},
		{"status", nil, EUnsupported, cbor.M(1, "status")},
		{"network/join", nil, EForbidden, nil}, // anonymous
		{"info", []any{7, idem}, EUnsupported, cbor.M(1, "idem")},
		{"claim/finish", []any{7, idem}, EForbidden, nil},
	}
	for _, c := range cases {
		code, det := p.do(c.typ, cbor.M(), c.extra...)
		if code != c.code {
			t.Fatalf("%s: code %d (want %d)", c.typ, code, c.code)
		}
		if c.det != nil {
			a, _ := cbor.Encode(det)
			b, _ := cbor.Encode(c.det)
			if !bytes.Equal(a, b) {
				t.Fatalf("%s: detail %v", c.typ, det)
			}
		}
	}
	// major != 1 -> E_VERSION
	p.id++
	b, _ := cbor.Encode(cbor.M(0, []any{uint64(2), uint64(0)}, 1, p.id, 2, "info", 3, cbor.M()))
	p.sendEnv(b)
	r := p.resp(2 * time.Second)
	if st, _ := r.Get(4); st != uint64(EVersion) {
		t.Fatalf("major 2: %v", r)
	}
	// id repeated -> disconnect
	b, _ = cbor.Encode(cbor.M(0, []any{uint64(1), uint64(0)}, 1, p.id, 2, "info", 3, cbor.M()))
	p.sendEnv(b)
	if p.resp(time.Second) != nil || !p.closedWithin(time.Second) {
		t.Fatal("a repeated id was answered")
	}
}

// claim/begin -> claim/finish: claim.verify gets the 5 split fields (F-P8) with begin's owner_pub; success -> owner,
// the other session is disconnected.
func TestClaimFlow(t *testing.T) {
	f := newFakeHelper(t)
	s := startServer(t, f, TestEnv{})
	other := dial(t, s)
	other.handshake(devID, nil)
	p := dial(t, s)
	p.handshake(devID, nil)
	_, pub := ownerKey(t)
	f.set(func(f *fakeHelper) {
		f.handler = func(v string, a cbor.Map) (int, cbor.Map, bool) {
			if v == "claim.verify" {
				return 0, cbor.M(1, randB(32), 2, randB(32), 3, "pw"), true
			}
			return 0, nil, false
		}
	})
	code, body := p.do("claim/begin", cbor.M(1, pub))
	nn, _ := body.Get(1)
	if code != 0 || len(nn.([]byte)) != 32 {
		t.Fatalf("claim/begin %d %v", code, body)
	}
	code, body = p.do("claim/finish", cbor.M(1, randB(32), 2, append([]byte{4}, randB(64)...), 3, randB(64)))
	if code != 0 {
		t.Fatalf("claim/finish %d", code)
	}
	a := f.last("claim.verify")
	if len(a) != 5 {
		t.Fatalf("claim.verify args %v", a)
	}
	if v, _ := a.Get(3); !bytes.Equal(v.([]byte), pub) {
		t.Fatal("claim.verify owner_pub is not claim/begin's")
	}
	if v, _ := a.Get(1); !bytes.Equal(v.([]byte), p.h) {
		t.Fatal("claim.verify h")
	}
	if p.s.Role() != RoleOwner {
		t.Fatal("not owner after the claim")
	}
	if !other.closedWithin(time.Second) {
		t.Fatal("the other session survived the claim")
	}
}

// helper 3 -> E_CLAIM_FAILED (9); the 3rd failure is answered, then the connection goes. 6 -> reason 10.
// NO_BRUTE_LIMIT keeps it (the prov-sec-claim-brute negative control).
func TestClaimFailures(t *testing.T) {
	for _, nb := range []bool{false, true} {
		f := newFakeHelper(t)
		s := startServer(t, f, TestEnv{NoBruteLimit: nb})
		p := dial(t, s)
		p.handshake(devID, nil)
		_, pub := ownerKey(t)
		f.set(func(f *fakeHelper) {
			f.handler = func(v string, a cbor.Map) (int, cbor.Map, bool) {
				if v == "claim.verify" {
					return 3, cbor.M(), true
				}
				return 0, nil, false
			}
		})
		for i := 0; i < 3; i++ {
			p.do("claim/begin", cbor.M(1, pub))
			if code, _ := p.do("claim/finish", cbor.M(1, randB(32), 2, randB(65), 3, randB(64))); code != EClaimFailed {
				t.Fatalf("attempt %d: %d", i, code)
			}
		}
		if closed := p.closedWithin(time.Second); closed == nb {
			t.Fatalf("NO_BRUTE_LIMIT=%v: closed after 3 failures = %v", nb, closed)
		}
	}
	f := newFakeHelper(t)
	s := startServer(t, f, TestEnv{})
	p := dial(t, s)
	p.handshake(devID, nil)
	f.set(func(f *fakeHelper) {
		f.handler = func(v string, a cbor.Map) (int, cbor.Map, bool) {
			if v == "claim.verify" {
				return 6, cbor.M(), true
			}
			return 0, nil, false
		}
	})
	_, pub := ownerKey(t)
	p.do("claim/begin", cbor.M(1, pub))
	code, det := p.do("claim/finish", cbor.M(1, randB(32), 2, randB(65), 3, randB(64)))
	if r, _ := det.Get(2); code != EUnsupported || r != uint64(10) {
		t.Fatalf("no-ssh-key: %d %v", code, det)
	}
	// claim/finish without claim/begin -> E_FORBIDDEN, the helper never asked
	n := f.count("claim.verify")
	if code, _ := p.do("claim/finish", cbor.M(1, randB(32), 2, randB(65), 3, randB(64))); code != EForbidden || f.count("claim.verify") != n {
		t.Fatalf("finish without begin: %d", code)
	}
}

// two phones claim at once: one 0, one E_BUSY (L24)
func TestTwoPhonesClaim(t *testing.T) {
	f := newFakeHelper(t)
	s := startServer(t, f, TestEnv{})
	release := make(chan struct{})
	f.set(func(f *fakeHelper) {
		f.handler = func(v string, a cbor.Map) (int, cbor.Map, bool) {
			if v == "claim.verify" {
				<-release
				return 0, cbor.M(1, randB(32), 2, randB(32), 3, "pw"), true
			}
			return 0, nil, false
		}
	})
	a, b := dial(t, s), dial(t, s)
	a.handshake(devID, nil)
	b.handshake(devID, nil)
	_, pub := ownerKey(t)
	a.do("claim/begin", cbor.M(1, pub))
	b.do("claim/begin", cbor.M(1, pub))
	a.sendEnv(a.env("claim/finish", cbor.M(1, randB(32), 2, randB(65), 3, randB(64))))
	time.Sleep(200 * time.Millisecond)
	if code, _ := b.do("claim/finish", cbor.M(1, randB(32), 2, randB(65), 3, randB(64))); code != EBusy {
		t.Fatalf("second claim: %d (want E_BUSY)", code)
	}
	close(release)
	r := a.resp(3 * time.Second)
	if st, _ := r.Get(4); st != uint64(0) {
		t.Fatalf("first claim: %v", r)
	}
}

// claimedHelper: a member node; the returned keys are in the 6-slot layout [owner0..owner3, member, replay]
func claimedHelper(t *testing.T, owners ...[]byte) (*fakeHelper, [][]byte) {
	f := newFakeHelper(t)
	ps := []any{}
	raw := make([][]byte, NumPSK)
	for i := range owners {
		raw[i] = randB(32)
		ps = append(ps, raw[i])
	}
	raw[4], raw[5] = randB(32), randB(32)
	f.state, f.owners, f.psks = "member", owners, cbor.M(1, ps, 2, raw[4], 3, raw[5])
	f.netID, f.netVer = randB(16), 3
	return f, raw
}

// psk_owner -> candidate (info, auth/owner only); auth/owner verified against info.owners -> owner, info has 9/10/11.
// A wrong signature counts as a failure.
func TestCandidateAuthOwner(t *testing.T) {
	k, pub := ownerKey(t)
	f, psks := claimedHelper(t, pub)
	s := startServer(t, f, TestEnv{})
	p := dial(t, s)
	if !p.handshake("", psks[0]) {
		t.Fatal("psk_owner handshake")
	}
	if p.s.Role() != RoleCandidate {
		t.Fatalf("role %d", p.s.Role())
	}
	if code, _ := p.do("network/leave", cbor.M()); code != EForbidden {
		t.Fatal("candidate allowed network/leave")
	}
	if code, _ := p.do("auth/owner", cbor.M(1, kidOf(pub), 2, randB(64))); code != EForbidden {
		t.Fatal("bad auth/owner signature accepted")
	}
	if code, body := p.do("auth/owner", cbor.M(1, kidOf(pub), 2, authSig(t, k, p.h, kidOf(pub)))); code != 0 || len(body) != 0 {
		t.Fatalf("auth/owner %d %v", code, body)
	}
	if p.s.Role() != RoleOwner {
		t.Fatal("not owner")
	}
	_, body := p.do("info", cbor.M())
	if v, _ := body.Get(9); v != uint64(3) {
		t.Fatalf("owner info %v", body)
	}
	if v, _ := body.Get(11); v != false {
		t.Fatalf("owner info unfinished %v", body)
	}
	// member handshake, then a wrong PSK -> the fake msg2 (same length), connection held
	m := dial(t, s)
	if !m.handshake("", psks[4]) || m.s.Role() != RoleMember {
		t.Fatal("member handshake")
	}
	m.c.Close() // owner + member hold both slots: nothing is evictable (TestSlots)
	waitFor(t, "member slot freed", func() bool { return s.Sessions() == 1 })
	x := dial(t, s)
	if x.handshake("", randB(32)) {
		t.Fatal("a wrong PSK opened the handshake")
	}
	if x.closedWithin(500 * time.Millisecond) {
		t.Fatal("fake path disconnected at once (must wait for the handshake timeout)")
	}
}

// the re-acquire role: begin -> op/nonce answers the SAME pair's nonce_helper without a helper call (F-P9), replay
// forwards {h, envelope}; afterwards the pair is gone -> op/nonce E_FORBIDDEN (L79). Mutant: op/nonce calls nonce ->
// the helper count goes to 2 -> FAIL.
func TestReacquire(t *testing.T) {
	_, pub := ownerKey(t)
	f, psks := claimedHelper(t, pub)
	f.state = "claimed"
	var pairHelper []byte
	f.set(func(f *fakeHelper) {
		f.handler = func(v string, a cbor.Map) (int, cbor.Map, bool) {
			switch v {
			case "nonce":
				pairHelper = randB(32)
				return 0, cbor.M(1, randB(32), 2, pairHelper), true
			case "claim.replay":
				return 0, cbor.M(1, randB(32), 2, randB(32), 3, "pw2"), true
			}
			return 0, nil, false
		}
	})
	s := startServer(t, f, TestEnv{})
	p := dial(t, s)
	if !p.handshake("", psks[5]) || p.s.Role() != RoleReacquire {
		t.Fatal("psk_replay handshake")
	}
	p.do("claim/begin", cbor.M(1, pub))
	code, body := p.do("op/nonce", cbor.M())
	if nh, _ := body.Get(1); code != 0 || !bytes.Equal(nh.([]byte), pairHelper) || f.count("nonce") != 1 {
		t.Fatalf("op/nonce: %d, nonce calls %d", code, f.count("nonce"))
	}
	envBytes := p.env("claim/replay", cbor.M(1, randB(32), 31, cbor.M(1, "claim/replay", 2, randB(64))))
	p.sendEnv(envBytes)
	r := p.resp(3 * time.Second)
	if st, _ := r.Get(4); st != uint64(0) {
		t.Fatalf("replay %v", r)
	}
	a := f.last("claim.replay")
	if v, _ := a.Get(2); !bytes.Equal(v.([]byte), envBytes) {
		t.Fatal("claim.replay did not get the original envelope")
	}
	if p.s.Role() != RoleOwner {
		t.Fatal("not owner after the replay")
	}
	// a second re-acquire session: no pair -> E_FORBIDDEN without a helper call
	q := dial(t, s)
	q.handshake("", psks[5])
	n := f.count("nonce")
	if code, _ := q.do("op/nonce", cbor.M()); code != EForbidden || f.count("nonce") != n {
		t.Fatalf("op/nonce without a pair: %d", code)
	}
}

// owner-op verbs: the whole envelope goes to the helper; join answers {1: 0}; while ops is busy a second session gets
// E_BUSY at once (single in flight, no queue).
func TestOwnerOpsForwardAndBusy(t *testing.T) {
	k, pub := ownerKey(t)
	f, psks := claimedHelper(t, pub)
	release := make(chan struct{})
	f.set(func(f *fakeHelper) {
		f.handler = func(v string, a cbor.Map) (int, cbor.Map, bool) {
			if v == "net.apply" {
				<-release
				return 0, cbor.M(1, uint64(4)), true
			}
			return 0, nil, false
		}
	})
	s := startServer(t, f, TestEnv{})
	p := dial(t, s)
	p.handshake("", psks[0])
	p.do("auth/owner", cbor.M(1, kidOf(pub), 2, authSig(t, k, p.h, kidOf(pub))))
	m := dial(t, s)
	m.handshake("", psks[4])
	env := p.env("network/update", cbor.M(1, []any{}))
	p.sendEnv(env)
	time.Sleep(200 * time.Millisecond)
	if code, _ := m.do("network/update", cbor.M(1, []any{})); code != EBusy {
		t.Fatalf("second request while ops busy: %d", code)
	}
	close(release)
	r := p.resp(3 * time.Second)
	if b, _ := r.Get(3); b == nil {
		t.Fatalf("update %v", r)
	} else if v, _ := b.(cbor.Map).Get(1); v != uint64(4) {
		t.Fatalf("update body %v", b)
	}
	if v, _ := f.last("net.apply").Get(2); !bytes.Equal(v.([]byte), env) {
		t.Fatal("net.apply did not get the original envelope")
	}
}

// HELPER_WAIT: past it the session gets E_BUSY "outcome unknown" and stays; ops refuses others until the late answer.
func TestHelperWait(t *testing.T) {
	k, pub := ownerKey(t)
	f, psks := claimedHelper(t, pub)
	release := make(chan struct{})
	f.set(func(f *fakeHelper) {
		f.handler = func(v string, a cbor.Map) (int, cbor.Map, bool) {
			if v == "network.leave" {
				<-release
				return 0, cbor.M(), true
			}
			return 0, nil, false
		}
	})
	s := startServer(t, f, TestEnv{})
	p := dial(t, s)
	p.handshake("", psks[0])
	p.do("auth/owner", cbor.M(1, kidOf(pub), 2, authSig(t, k, p.h, kidOf(pub))))
	code, det := p.do("network/leave", cbor.M(31, cbor.M(1, "network/leave", 2, randB(64))))
	if txt, _ := det.Get(3); code != EBusy || txt == nil {
		t.Fatalf("after HELPER_WAIT: %d %v", code, det)
	}
	if code, _ := p.do("op/nonce", cbor.M()); code != EBusy {
		t.Fatal("ops accepted a request while the timed-out one is still at the helper")
	}
	close(release)
	waitFor(t, "late answer", func() bool { return !s.ops.Busy() })
	if code, _ := p.do("op/nonce", cbor.M()); code != 0 {
		t.Fatalf("op/nonce after the late answer: %d", code)
	}
}

// revocation (§1.3): a removed owner's session goes when the new owners arrive; a member's when psk_member changes;
// anonymous sessions stay. Mutant: no reconcile -> the owner session survives -> FAIL.
func TestRevocation(t *testing.T) {
	k, pub := ownerKey(t)
	_, pub2 := ownerKey(t)
	f, psks := claimedHelper(t, pub, pub2)
	s := startServer(t, f, TestEnv{})
	o := dial(t, s)
	o.handshake("", psks[0])
	o.do("auth/owner", cbor.M(1, kidOf(pub), 2, authSig(t, k, o.h, kidOf(pub))))
	c := dial(t, s)
	c.handshake("", psks[1]) // candidate of pub2: stays (pub2 kept)
	member2 := randB(32)
	f.set(func(f *fakeHelper) {
		f.owners = [][]byte{pub2}
		f.psks = cbor.M(1, []any{psks[1]}, 2, member2, 3, nil)
		f.gen++
	})
	if !o.closedWithin(2 * time.Second) {
		t.Fatal("the removed owner's session survived")
	}
	if c.closedWithin(300 * time.Millisecond) {
		t.Fatal("the remaining owner's candidate session was cut")
	}
	waitFor(t, "new PSK set", func() bool {
		s.mu.Lock()
		defer s.mu.Unlock()
		return s.c.psks != nil && bytes.Equal(s.c.psks.member, member2)
	})
	m := dial(t, s)
	m.handshake("", member2)
	if m.s.Role() != RoleMember {
		t.Fatalf("member role %d", m.s.Role())
	}
	f.set(func(f *fakeHelper) { f.psks = cbor.M(1, []any{psks[1]}, 2, randB(32), 3, nil); f.gen++ })
	if !m.closedWithin(2 * time.Second) {
		t.Fatal("the member session survived a psk_member change")
	}
}

// slots: 2; a third evicts the oldest unauthenticated session past its handshake, or is refused (§4.1)
func TestSlots(t *testing.T) {
	f := newFakeHelper(t)
	s := startServer(t, f, TestEnv{})
	a := dial(t, s)
	a.handshake(devID, nil)
	b := dial(t, s)
	b.handshake(devID, nil)
	c := dial(t, s)
	if c.s == nil || !a.closedWithin(time.Second) {
		t.Fatal("third connection did not evict the oldest anonymous session")
	}
	if !c.handshake(devID, nil) {
		t.Fatal("the new connection could not handshake")
	}
	// two owners -> nothing evictable -> refused
	f2 := newFakeHelper(t)
	s2 := startServer(t, f2, TestEnv{})
	f2.set(func(f *fakeHelper) {
		f.handler = func(v string, a cbor.Map) (int, cbor.Map, bool) {
			if v == "claim.verify" {
				return 0, cbor.M(1, randB(32), 2, randB(32), 3, "pw"), true
			}
			return 0, nil, false
		}
	})
	x := dial(t, s2)
	x.handshake(devID, nil)
	_, pub := ownerKey(t)
	x.do("claim/begin", cbor.M(1, pub))
	x.do("claim/finish", cbor.M(1, randB(32), 2, randB(65), 3, randB(64)))
	y := dial(t, s2)
	z := dial(t, s2)
	if y.s == nil || z.s != nil {
		t.Fatalf("slots with one owner: y=%v z=%v", y.s != nil, z.s != nil)
	}
}

// a chunked request (vector chunking) is reassembled and forwarded as ONE deterministic envelope
func TestChunkedRequest(t *testing.T) {
	k, pub := ownerKey(t)
	f, psks := claimedHelper(t, pub)
	f.set(func(f *fakeHelper) {
		f.handler = func(v string, a cbor.Map) (int, cbor.Map, bool) {
			if v == "net.apply" {
				return 0, cbor.M(1, uint64(4)), true
			}
			return 0, nil, false
		}
	})
	s := startServer(t, f, TestEnv{})
	p := dial(t, s)
	p.handshake("", psks[0])
	p.do("auth/owner", cbor.M(1, kidOf(pub), 2, authSig(t, k, p.h, kidOf(pub))))
	body := vhex(t, "chunking.body")
	x, _ := cbor.Decode(body)
	p.id++
	id := p.id
	half := len(body) / 2
	for i, sl := range [][]byte{body[:half], body[half:]} {
		b, _ := cbor.Encode(cbor.M(0, []any{uint64(1), uint64(0)}, 1, id, 2, "network/update", 3, sl, 6, cbor.M(1, uint64(i+1), 2, uint64(2))))
		p.sendEnv(b)
	}
	r := p.resp(3 * time.Second)
	if st, _ := r.Get(4); st != uint64(0) {
		t.Fatalf("chunked: %v", r)
	}
	want, _ := cbor.Encode(cbor.M(0, []any{uint64(1), uint64(0)}, 1, id, 2, "network/update", 3, x))
	if v, _ := f.last("net.apply").Get(2); !bytes.Equal(v.([]byte), want) {
		t.Fatal("reassembled envelope differs from the whole one")
	}
	// a repeated (id, n) -> disconnect
	p.id++
	for i := 0; i < 2; i++ {
		b, _ := cbor.Encode(cbor.M(0, []any{uint64(1), uint64(0)}, 1, p.id, 2, "network/update", 3, body[:10], 6, cbor.M(1, uint64(1), 2, uint64(3))))
		p.sendEnv(b)
	}
	if !p.closedWithin(time.Second) {
		t.Fatal("a repeated chunk (id, n) was accepted")
	}
	p = dial(t, s)
	p.handshake("", psks[0])
	// out-of-order chunk -> disconnect
	p.id++
	b, _ := cbor.Encode(cbor.M(0, []any{uint64(1), uint64(0)}, 1, p.id, 2, "network/update", 3, body[:10], 6, cbor.M(1, uint64(2), 2, uint64(2))))
	p.sendEnv(b)
	if !p.closedWithin(time.Second) {
		t.Fatal("a chunk starting at 2 was accepted")
	}
}

// STATUS is not answered from a stale cache (§4.1: an error, never a guess)
func TestStatusStale(t *testing.T) {
	f := newFakeHelper(t)
	s := startServer(t, f, TestEnv{})
	if _, ok := s.Status(); !ok {
		t.Fatal("fresh status refused")
	}
	s.mu.Lock()
	s.c.stateAt = time.Now().Add(-StaleAfter - time.Second)
	s.mu.Unlock()
	if _, ok := s.Status(); ok {
		t.Fatal("stale status answered")
	}
}

// the global handshake window: the 21st in a minute is disconnected
func TestGlobalHandshakeRate(t *testing.T) {
	f := newFakeHelper(t)
	s := startServer(t, f, TestEnv{})
	for i := 0; i < HandshakesMin; i++ {
		p := dial(t, s)
		if !p.handshake(devID, nil) {
			t.Fatalf("handshake %d", i)
		}
		p.c.Close()
		waitFor(t, "slot freed", func() bool { return s.Sessions() == 0 })
	}
	p := dial(t, s)
	a, _ := noiseInit(t)
	p.writeMsg(a)
	if !p.closedWithin(2 * time.Second) {
		t.Fatal("21st handshake in a minute answered")
	}
}

func noiseInit(t *testing.T) ([]byte, error) {
	p := &phone{t: t}
	_ = p
	m := make([]byte, Msg1NX)
	copy(m, randB(32))
	return m, nil
}
