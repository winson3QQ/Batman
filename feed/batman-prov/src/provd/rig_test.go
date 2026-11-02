package provd

// Test rig: a fake batman-provhelper on a real SEQPACKET socket (the wire contract of sock.go / node.go), a Go
// "phone" (flynn/noise initiator + GATT framing + envelopes) on a socketpair, and the Server between them.
// peer.py against the real helper is the independent judge (CI peer-vs-provd); this rig drives provd's own logic.

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"net"
	"os"
	"path/filepath"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/flynn/noise"

	"batman-prov/cbor"
	"batman-prov/proto"
)

type call struct {
	verb string
	args cbor.Map
}

type fakeHelper struct {
	t     *testing.T
	path  string
	ln    *net.UnixListener
	mu    sync.Mutex
	calls []call
	// state the read-only verbs report
	state   string
	gen     uint64
	trial   bool
	owners  [][]byte
	psks    cbor.Map
	health  string
	bootID  []byte
	unfin   bool
	netID   []byte
	netVer  uint64
	handler func(verb string, args cbor.Map) (int, cbor.Map, bool) // overrides; false = default
}

func newFakeHelper(t *testing.T) *fakeHelper {
	dir := t.TempDir()
	f := &fakeHelper{t: t, path: filepath.Join(dir, "helper.sock"), state: "unclaimed", gen: 1,
		health: "boot_id=b ts=1 bluetoothd=1 hci0_powered=1 adv_registered_once=0 privacy=1 sc=1 sc_file=1 bondable=0 num_instances=0\n",
		bootID: make([]byte, 16)}
	ln, err := net.ListenUnix("unixpacket", &net.UnixAddr{Name: f.path, Net: "unixpacket"})
	if err != nil {
		t.Fatal(err)
	}
	f.ln = ln
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			c, err := ln.AcceptUnix()
			if err != nil {
				return
			}
			go f.serve(c)
		}
	}()
	return f
}

func (f *fakeHelper) serve(c *net.UnixConn) {
	defer c.Close()
	buf := make([]byte, 70000)
	for {
		n, err := c.Read(buf)
		if err != nil {
			return
		}
		x, err := cbor.Decode(buf[:n])
		if err != nil {
			f.t.Errorf("provd sent non-deterministic CBOR to the helper: %v", err)
			return
		}
		m := x.(cbor.Map)
		if len(m) != 3 {
			f.t.Errorf("request with %d keys", len(m))
		}
		vv, _ := m.Get(1)
		idv, _ := m.Get(2)
		av, _ := m.Get(3)
		verb, _ := vv.(string)
		args, _ := av.(cbor.Map)
		f.mu.Lock()
		f.calls = append(f.calls, call{verb, args})
		h := f.handler
		f.mu.Unlock()
		code, body, done := 0, cbor.M(), false
		if h != nil {
			code, body, done = h(verb, args)
		}
		if !done {
			code, body = f.def(verb, args)
		}
		out, _ := cbor.Encode(cbor.M(1, idv, 2, uint64(code), 3, body))
		if _, err := c.Write(out); err != nil {
			return
		}
	}
}

func (f *fakeHelper) def(verb string, args cbor.Map) (int, cbor.Map) {
	f.mu.Lock()
	defer f.mu.Unlock()
	switch verb {
	case "info.cert":
		return 0, cbor.M(1, make([]byte, 300), 2, []byte{1, 2, 3, 4, 5, 6, 7, 8, 9})
	case "info.ecdh_pub":
		p := make([]byte, 65)
		p[0] = 4
		return 0, cbor.M(1, p)
	case "info.boot_id":
		return 0, cbor.M(1, f.bootID)
	case "sign.static":
		return 0, cbor.M(1, make([]byte, 64), 2, f.bootID)
	case "sign.ecdh_proof":
		return 0, cbor.M(1, make([]byte, 64))
	case "health.get":
		return 0, cbor.M(1, f.health)
	case "info.state":
		return 0, cbor.M(1, f.state, 2, f.gen, 3, uint64(len(f.owners)), 4, true, 5, f.trial)
	case "info.owners":
		l := []any{}
		for _, o := range f.owners {
			l = append(l, o)
		}
		return 0, cbor.M(1, l)
	case "info.net":
		var nid any
		if f.netID != nil {
			nid = f.netID
		}
		return 0, cbor.M(1, nid, 2, f.netVer, 3, false, 4, f.unfin)
	case "psks.get":
		if f.psks == nil {
			return 0, cbor.M(1, []any{}, 2, nil, 3, nil)
		}
		return 0, f.psks
	case "nonce":
		return 0, cbor.M(1, randB(32), 2, randB(32))
	}
	return 6, cbor.M()
}

func (f *fakeHelper) count(verb string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	n := 0
	for _, c := range f.calls {
		if c.verb == verb {
			n++
		}
	}
	return n
}

func (f *fakeHelper) last(verb string) cbor.Map {
	f.mu.Lock()
	defer f.mu.Unlock()
	for i := len(f.calls) - 1; i >= 0; i-- {
		if f.calls[i].verb == verb {
			return f.calls[i].args
		}
	}
	return nil
}

func (f *fakeHelper) set(fn func(f *fakeHelper)) { f.mu.Lock(); fn(f); f.mu.Unlock() }

func randB(n int) []byte { b := make([]byte, n); rand.Read(b); return b }

// TestMain shortens the timings once, before any Server runs (changing them later races the loops)
func TestMain(m *testing.M) {
	PollEvery, HandshakeMax, IdleAnon, HelperWait = 100*time.Millisecond, 2*time.Second, 3*time.Second, 2*time.Second
	os.Exit(m.Run())
}

func startServer(t *testing.T, f *fakeHelper, te TestEnv) *Server {
	s, err := NewServer(Config{HelperPath: f.path, Log: t.Logf, Board: "bcm2711", FW: "1.5.14-test", Test: te})
	if err != nil {
		t.Fatal(err)
	}
	go s.Run()
	t.Cleanup(s.Stop)
	waitFor(t, "server ready", s.Ready)
	return s
}

func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	end := time.Now().Add(5 * time.Second)
	for time.Now().Before(end) {
		if cond() {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
}

// ---- transport + phone ----

type pairT struct{ c *net.UnixConn }

func (p *pairT) ReadFrame() ([]byte, error) {
	b := make([]byte, MaxFrame+1)
	n, err := p.c.Read(b)
	if err != nil {
		return nil, err
	}
	return b[:n], nil
}
func (p *pairT) WriteFrame(f []byte) error { _, err := p.c.Write(f); return err }
func (p *pairT) FrameLimit() int           { return OutFrame }
func (p *pairT) Close()                    { p.c.Close() }
func (p *pairT) Kind() string              { return "sock" }

func socketpair(t *testing.T) (*net.UnixConn, *net.UnixConn) {
	fds, err := syscall.Socketpair(syscall.AF_UNIX, syscall.SOCK_SEQPACKET, 0)
	if err != nil {
		t.Fatal(err)
	}
	mk := func(fd int) *net.UnixConn {
		f := os.NewFile(uintptr(fd), "pair")
		c, err := net.FileConn(f)
		f.Close()
		if err != nil {
			t.Fatal(err)
		}
		return c.(*net.UnixConn)
	}
	return mk(fds[0]), mk(fds[1])
}

type phone struct {
	t          *testing.T
	c          *net.UnixConn
	s          *Session
	send, recv *noise.CipherState
	h          []byte
	cert       cbor.Map
	id         uint64
	r          Reassembler
}

func dial(t *testing.T, s *Server) *phone {
	a, b := socketpair(t)
	ss := s.Accept(&pairT{a})
	t.Cleanup(func() { b.Close() })
	return &phone{t: t, c: b, s: ss}
}

func (p *phone) readMsg(wait time.Duration) ([]byte, error) {
	buf := make([]byte, 600)
	p.c.SetReadDeadline(time.Now().Add(wait))
	for {
		n, err := p.c.Read(buf)
		if err != nil {
			return nil, err
		}
		m, done, err := p.r.Push(buf[:n])
		if err != nil {
			return nil, err
		}
		if done {
			return m, nil
		}
	}
}

func (p *phone) writeMsg(m []byte) {
	for _, f := range Split(m, 20) {
		if _, err := p.c.Write(f); err != nil {
			p.t.Fatalf("phone write: %v", err)
		}
	}
}

// handshake: NX when psk == nil; returns false when msg2 did not open (the fake path)
func (p *phone) handshake(hint string, psk []byte) bool {
	cfg := noise.Config{CipherSuite: suite, Pattern: noise.HandshakeNX, Initiator: true, Prologue: Prologue(hint)}
	if psk != nil {
		cfg.PresharedKey, cfg.PresharedKeyPlacement = psk, 0
	}
	hs, err := noise.NewHandshakeState(cfg)
	if err != nil {
		p.t.Fatal(err)
	}
	m1, _, _, _ := hs.WriteMessage(nil, nil)
	p.writeMsg(m1)
	m2, err := p.readMsg(3 * time.Second)
	if err != nil {
		p.t.Fatalf("no msg2: %v", err)
	}
	pl, cs1, cs2, err := hs.ReadMessage(nil, m2)
	if err != nil {
		return false
	}
	x, err := cbor.Decode(pl)
	if err != nil {
		p.t.Fatalf("node_cert: %v", err)
	}
	p.cert, p.send, p.recv, p.h = x.(cbor.Map), cs1, cs2, hs.ChannelBinding()
	return true
}

func (p *phone) env(typ string, body cbor.Map, extra ...any) []byte {
	p.id++
	m := cbor.M(0, []any{uint64(1), uint64(0)}, 1, p.id, 2, typ, 3, body)
	m = append(m, cbor.M(extra...)...)
	b, err := cbor.Encode(m)
	if err != nil {
		p.t.Fatal(err)
	}
	return b
}

func (p *phone) sendEnv(b []byte) {
	ct, err := p.send.Encrypt(nil, nil, b)
	if err != nil {
		p.t.Fatal(err)
	}
	p.writeMsg(ct)
}

// resp waits for one response envelope; nil = the connection ended
func (p *phone) resp(wait time.Duration) cbor.Map {
	m, err := p.readMsg(wait)
	if err != nil {
		return nil
	}
	pt, err := p.recv.Decrypt(nil, nil, m)
	if err != nil {
		p.t.Fatalf("response AEAD: %v", err)
	}
	x, err := cbor.Decode(pt)
	if err != nil {
		p.t.Fatalf("response CBOR: %v", err)
	}
	return x.(cbor.Map)
}

// do sends a request and returns (status, body-or-error map)
func (p *phone) do(typ string, body cbor.Map, extra ...any) (int, cbor.Map) {
	p.t.Helper()
	p.sendEnv(p.env(typ, body, extra...))
	r := p.resp(5 * time.Second)
	if r == nil {
		p.t.Fatalf("%s: connection ended", typ)
	}
	st, _ := r.Get(4)
	if b, ok := r.Get(3); ok {
		return int(st.(uint64)), b.(cbor.Map)
	}
	e, _ := r.Get(5)
	return int(st.(uint64)), e.(cbor.Map)
}

func (p *phone) closedWithin(d time.Duration) bool {
	p.c.SetReadDeadline(time.Now().Add(d))
	_, err := p.c.Read(make([]byte, 600))
	if ne, ok := err.(net.Error); ok && ne.Timeout() {
		return false
	}
	return err != nil
}

// owner keys for auth/owner
func ownerKey(t *testing.T) (*ecdsa.PrivateKey, []byte) {
	k, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	pub, _ := k.PublicKey.Bytes()
	return k, pub
}

func authSig(t *testing.T, k *ecdsa.PrivateKey, h, kid []byte) []byte {
	sig, err := proto.SignES256(k, append(append([]byte(proto.LabelOwnerAuth), h...), kid...))
	if err != nil {
		t.Fatal(err)
	}
	return sig
}

func kidOf(pub []byte) []byte { s := sha256.Sum256(pub); return s[:] }
