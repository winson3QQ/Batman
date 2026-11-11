package provd

import (
	"bytes"
	"encoding/hex"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/flynn/noise"

	"batman-prov/cbor"
)

// hfield: what the fake helper's health.get answers in key 2 (the test changes it under mu)
type hfield struct {
	mu      sync.Mutex
	addr    bool
	window  bool
	left    uint64
	size    uint64
	bearer  []byte
	working bool
	healthy bool
	fail    bool // health.get answers an error (the poll gets no http field)
}

func (h *hfield) set(fn func(h *hfield)) { h.mu.Lock(); fn(h); h.mu.Unlock() }

const goodHealth = "boot_id=b ts=1 bluetoothd=1 hci0_powered=1 adv_registered_once=0 privacy=1 sc=1 sc_file=1 bondable=0 num_instances=0\n"
const badHealth = "boot_id=b ts=1 bluetoothd=0 hci0_powered=1 adv_registered_once=0 privacy=1 sc=1 sc_file=1 bondable=0 num_instances=0\n"

type httpRig struct {
	t     *testing.T
	f     *fakeHelper
	s     *Server
	h     *hfield
	base  string
	port  int
	bulk  string
	psks  [][]byte
	k     []byte // owner pub
	sign  func(h, kid []byte) []byte
	extra func(verb string, args cbor.Map) (int, cbor.Map, bool)
}

func freePort(t *testing.T) int {
	l, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	p := l.Addr().(*net.TCPAddr).Port
	l.Close()
	return p
}

func newHTTPRig(t *testing.T, h *hfield) *httpRig {
	t.Helper()
	return newHTTPRigPort(t, h, freePort(t))
}

func newHTTPRigPort(t *testing.T, h *hfield, port int) *httpRig {
	t.Helper()
	k, pub := ownerKey(t)
	f, psks := claimedHelper(t, pub)
	r := &httpRig{t: t, f: f, h: h, psks: psks, k: pub, port: port, bulk: t.TempDir()}
	r.sign = func(hh, kid []byte) []byte { return authSig(t, k, hh, kid) }
	f.set(func(f *fakeHelper) {
		f.handler = func(verb string, args cbor.Map) (int, cbor.Map, bool) {
			if verb == "health.get" {
				h.mu.Lock()
				defer h.mu.Unlock()
				if h.fail {
					return hEUnsupported, cbor.M(), true
				}
				line := badHealth
				if h.healthy {
					line = goodHealth
				}
				m := cbor.M()
				if h.addr {
					m = append(m, cbor.Entry{K: uint64(2), V: "127.0.0.1"})
				}
				if h.window {
					m = append(m, cbor.Entry{K: uint64(3), V: kidOf(pub)}, cbor.Entry{K: uint64(4), V: h.left},
						cbor.Entry{K: uint64(5), V: h.size}, cbor.Entry{K: uint64(6), V: h.bearer}, cbor.Entry{K: uint64(7), V: uint64(9999)})
				}
				if h.working {
					m = append(m, cbor.Entry{K: uint64(8), V: true})
				}
				return 0, cbor.M(1, line, 2, m), true
			}
			h.mu.Lock()
			ex := r.extra
			h.mu.Unlock()
			if ex != nil {
				return ex(verb, args)
			}
			return 0, nil, false
		}
	})
	s, err := NewServer(Config{HelperPath: f.path, Log: t.Logf, Board: "bcm2711", FW: "1.5.14-test", HTTPPort: r.port, BulkDir: r.bulk})
	if err != nil {
		t.Fatal(err)
	}
	go s.Run()
	t.Cleanup(s.Stop)
	r.s = s
	r.base = "http://127.0.0.1:" + strconv.Itoa(r.port)
	waitFor(t, "server ready", s.Ready)
	return r
}

func (r *httpRig) listening() bool {
	c, err := net.DialTimeout("tcp4", "127.0.0.1:"+strconv.Itoa(r.port), 200*time.Millisecond)
	if err != nil {
		return false
	}
	c.Close()
	return true
}

func (r *httpRig) waitListening(want bool, what string) {
	r.t.Helper()
	waitFor(r.t, what, func() bool { return r.listening() == want })
}

// hphone: the app over HTTP (Noise initiator, one message per POST)
type hphone struct {
	r          *httpRig
	id         string
	send, recv *noise.CipherState
	h          []byte
	n          uint64
}

func (r *httpRig) post(path, sid string, body []byte) (int, []byte, http.Header) {
	r.t.Helper()
	req, _ := http.NewRequest("POST", r.base+path, bytes.NewReader(body))
	if sid != "" {
		req.Header.Set("X-Batman-Session", sid)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return 0, nil, nil
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, b, resp.Header
}

// handshake: psk_* over /session; (HTTP status, opened)
func (r *httpRig) handshake(psk []byte) (*hphone, int, bool) {
	r.t.Helper()
	cfg := noise.Config{CipherSuite: suite, Pattern: noise.HandshakeNX, Initiator: true, Prologue: Prologue("")}
	if psk != nil {
		cfg.PresharedKey, cfg.PresharedKeyPlacement = psk, 0
	}
	hs, _ := noise.NewHandshakeState(cfg)
	m1, _, _, _ := hs.WriteMessage(nil, nil)
	st, m2, hdr := r.post("/batman/v1/session", "", m1)
	if st != 200 {
		return nil, st, false
	}
	_, cs1, cs2, err := hs.ReadMessage(nil, m2)
	if err != nil {
		return nil, st, false
	}
	return &hphone{r: r, id: hdr.Get("X-Batman-Session"), send: cs1, recv: cs2, h: hs.ChannelBinding()}, st, true
}

func (p *hphone) msg(pt []byte) (int, cbor.Map) {
	p.r.t.Helper()
	var ct []byte
	if pt != nil {
		ct, _ = p.send.Encrypt(nil, nil, pt)
	}
	st, b, _ := p.r.post("/batman/v1/msg", p.id, ct)
	if st != 200 {
		return st, nil
	}
	dec, err := p.recv.Decrypt(nil, nil, b)
	if err != nil {
		p.r.t.Fatalf("reply AEAD: %v", err)
	}
	x, err := cbor.Decode(dec)
	if err != nil {
		p.r.t.Fatalf("reply CBOR: %v", err)
	}
	return st, x.(cbor.Map)
}

func (p *hphone) do(typ string, body cbor.Map, extra ...any) (int, cbor.Map) {
	p.r.t.Helper()
	p.n++
	m := cbor.M(0, []any{uint64(1), uint64(0)}, 1, p.n, 2, typ, 3, body)
	m = append(m, cbor.M(extra...)...)
	b, _ := cbor.Encode(m)
	st, resp := p.msg(b)
	if st != 200 {
		p.r.t.Fatalf("%s: HTTP %d", typ, st)
	}
	code, _ := resp.Get(4)
	if b, ok := resp.Get(3); ok {
		return int(code.(uint64)), b.(cbor.Map)
	}
	e, _ := resp.Get(5)
	return int(code.(uint64)), e.(cbor.Map)
}

func (r *httpRig) owner() *hphone {
	r.t.Helper()
	p, st, ok := r.handshake(r.psks[0])
	if !ok {
		r.t.Fatalf("psk_owner handshake over HTTP: %d", st)
	}
	if code, _ := p.do("auth/owner", cbor.M(1, kidOf(r.k), 2, r.sign(p.h, kidOf(r.k)))); code != 0 {
		r.t.Fatalf("auth/owner over HTTP: %d", code)
	}
	return p
}

func windowField(h *hfield) {
	h.addr, h.window, h.left, h.size, h.bearer = true, true, 900, 3<<20, bytes.Repeat([]byte{0xab}, 16)
}

// listening needs http.2 AND (the fallback or a window); http.2 gone = closed and every HTTP session ended
func TestHTTPListenGate(t *testing.T) {
	h := &hfield{healthy: true}
	r := newHTTPRig(t, h)
	time.Sleep(500 * time.Millisecond)
	if r.listening() {
		t.Fatal("listening without http.2")
	}
	h.set(func(h *hfield) { h.addr = true })
	time.Sleep(time.Second)
	if r.listening() {
		t.Fatal("listening with http.2 but neither fallback nor window")
	}
	h.set(windowField)
	r.waitListening(true, "window -> listening")
	p := r.owner()
	h.set(func(h *hfield) { h.addr = false })
	r.waitListening(false, "http.2 gone -> closed")
	waitFor(t, "HTTP sessions ended", func() bool { return len(r.s.httpSessions()) == 0 })
	_ = p
}

// the fallback: HealthOK false for FallbackAfter -> listens; true for FallbackClear -> no new sessions, the
// established one goes on; once it is gone the listener closes
func TestHTTPFallback(t *testing.T) {
	h := &hfield{healthy: false, addr: true}
	r := newHTTPRig(t, h)
	time.Sleep(FallbackAfter / 3)
	if r.listening() {
		t.Fatal("the fallback listens before HealthOK has been false for FallbackAfter")
	}
	r.waitListening(true, "fallback after HealthOK false")
	p, _, ok := r.handshake(r.psks[4])
	if !ok {
		t.Fatal("psk_member in the fallback")
	}
	h.set(func(h *hfield) { h.healthy = true })
	waitFor(t, "fallback cleared", func() bool { return !r.s.httpAccepting() })
	if _, st, _ := r.handshake(r.psks[0]); st != http.StatusServiceUnavailable {
		t.Fatalf("a new session after the fallback cleared: HTTP %d", st)
	}
	if code, _ := p.do("info", cbor.M()); code != 0 {
		t.Fatalf("the established session stopped working: %d", code)
	}
	if !r.listening() {
		t.Fatal("closed while a session is established")
	}
}

// psk_owner -> candidate -> auth/owner over HTTP; an AEAD failure is a 400 and the session goes on; key 20 is BLE only
func TestHTTPOwnerSession(t *testing.T) {
	h := &hfield{healthy: true}
	windowField(h)
	r := newHTTPRig(t, h)
	h.set(func(*hfield) {
		r.extra = func(verb string, args cbor.Map) (int, cbor.Map, bool) {
			if verb == "update.status" {
				return 0, cbor.M(1, uint64(1), 2, uint64(40), 99, bytes.Repeat([]byte{7}, 20000)), true
			}
			return 0, nil, false
		}
	})
	r.waitListening(true, "window")
	p := r.owner()
	if p.id == "" || len(p.id) != 32 {
		t.Fatalf("X-Batman-Session %q", p.id)
	}
	st, _, _ := r.post("/batman/v1/msg", p.id, bytes.Repeat([]byte{1}, 64))
	if st != http.StatusBadRequest {
		t.Fatalf("forged /msg: HTTP %d, want 400", st)
	}
	if code, _ := p.do("info", cbor.M()); code != 0 {
		t.Fatalf("the session did not survive a forged /msg: %d", code)
	}
	if code, d := p.do("settings/set", cbor.M(20, cbor.M(1, "x"))); code != EUnsupported {
		t.Fatalf("settings/set key 20 over HTTP: %d %v", code, d)
	} else if v, _ := d.Get(2); v != uint64(7) {
		t.Fatalf("key 20 reason %v", d)
	}
	if st, _, _ := r.post("/batman/v1/msg", "00000000000000000000000000000000", nil); st != http.StatusNotFound {
		t.Fatalf("unknown session id: HTTP %d", st)
	}
	// a chunked reply: the first block answers the request, an empty POST fetches the next
	p.n++
	b, _ := cbor.Encode(cbor.M(0, []any{uint64(1), uint64(0)}, 1, p.n, 2, "update/status", 3, cbor.M()))
	st1, first := p.msg(b)
	if st1 != 200 {
		t.Fatalf("chunk 1: %d", st1)
	}
	pv, ok := first.Get(6)
	if !ok {
		t.Fatalf("not chunked: %v", first)
	}
	total, _ := pv.(cbor.Map).Get(2)
	for i := uint64(2); i <= total.(uint64); i++ {
		st, c := p.msg(nil)
		if st != 200 {
			t.Fatalf("chunk %d: HTTP %d", i, st)
		}
		if v, _ := c.Get(6); v == nil {
			t.Fatalf("chunk %d: %v", i, c)
		}
	}
}

// HTTP takes psk_owner and psk_member only (never psk_replay); a window takes the owner only and drops members
func TestHTTPRoles(t *testing.T) {
	h := &hfield{healthy: false, addr: true}
	r := newHTTPRig(t, h)
	r.waitListening(true, "fallback")
	if _, st, ok := r.handshake(r.psks[5]); ok {
		t.Fatalf("psk_replay opened over HTTP: %d", st)
	}
	m, _, ok := r.handshake(r.psks[4])
	if !ok {
		t.Fatal("psk_member in the plain fallback")
	}
	h.set(windowField)
	time.Sleep(1500 * time.Millisecond) // a poll + a controller tick
	if st, _ := m.msg(nil); st != http.StatusNotFound && st != http.StatusGone {
		t.Fatalf("the member session survived the window opening: HTTP %d", st)
	}
	if _, st, ok := r.handshake(r.psks[4]); ok {
		t.Fatalf("psk_member while a window is open: %d", st)
	}
	time.Sleep(HandshakeMax + 500*time.Millisecond) // the refused handshakes leave their slots
	r.owner()
}

// two pools: HTTP sessions do not take BLE's slots, do not count for the advertising, and have their own 2
func TestHTTPPools(t *testing.T) {
	h := &hfield{healthy: true}
	windowField(h)
	r := newHTTPRig(t, h)
	r.waitListening(true, "window")
	r.owner()
	r.owner()
	if _, st, _ := r.handshake(r.psks[0]); st != http.StatusServiceUnavailable {
		t.Fatalf("a third HTTP session: HTTP %d", st)
	}
	if n := r.s.Sessions(); n != 0 {
		t.Fatalf("Sessions() counts HTTP: %d", n)
	}
	b := dial(t, r.s)
	if b == nil || b.s == nil {
		t.Fatal("BLE refused while HTTP is full")
	}
	if !b.handshake("", r.psks[0]) {
		t.Fatal("BLE handshake")
	}
	if n := r.s.Sessions(); n != 1 {
		t.Fatalf("Sessions() = %d, want 1 (BLE)", n)
	}
}

// 10 HTTP handshakes a minute, apart from BLE's 20
func TestHTTPHandshakeRate(t *testing.T) {
	h := &hfield{healthy: true}
	r := newHTTPRig(t, h)
	for i := 0; i < HTTPHandshakesMin; i++ {
		if !r.s.httpHandshakeAllowed() {
			t.Fatalf("handshake %d refused", i+1)
		}
	}
	if r.s.httpHandshakeAllowed() {
		t.Fatal("handshake 11 allowed")
	}
	if !r.s.handshakeAllowed() {
		t.Fatal("HTTP handshakes used BLE's quota")
	}
}

func put(r *httpRig, bearer string, body io.Reader, n int64) int {
	req, _ := http.NewRequest("PUT", r.base+"/batman/v1/bulk/0", body)
	req.ContentLength = n
	if bearer != "" {
		req.Header.Set("X-Batman-Upload", bearer)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return 0
	}
	resp.Body.Close()
	return resp.StatusCode
}

func TestHTTPPut(t *testing.T) {
	h := &hfield{healthy: true}
	windowField(h)
	h.size = 300 << 10
	r := newHTTPRig(t, h)
	r.waitListening(true, "window")
	data := bytes.Repeat([]byte("batman"), int(h.size)/6)
	data = append(data, make([]byte, int(h.size)-len(data))...)
	good := hex.EncodeToString(h.bearer)
	pf := filepath.Join(r.bulk, "payload")
	for name, tc := range map[string]struct {
		bearer string
		n      int64
		want   int
	}{
		"no bearer":    {"", int64(h.size), 403},
		"wrong bearer": {hex.EncodeToString(bytes.Repeat([]byte{1}, 16)), int64(h.size), 403},
		"upper hex":    {hex.EncodeToString(bytes.Repeat([]byte{0xAB}, 16))[:30] + "AB", int64(h.size), 403},
		"short":        {good[:30], int64(h.size), 403},
		"wrong size":   {good, int64(h.size) - 1, 400},
	} {
		if st := put(r, tc.bearer, bytes.NewReader(data[:tc.n]), tc.n); st != tc.want {
			t.Fatalf("%s: HTTP %d, want %d", name, st, tc.want)
		}
	}
	if _, err := os.Stat(pf); err == nil {
		t.Fatal("a refused PUT created the file")
	}
	if st := put(r, good, bytes.NewReader(data), int64(len(data))); st != 200 {
		t.Fatalf("good PUT: HTTP %d", st)
	}
	if b, _ := os.ReadFile(pf); !bytes.Equal(b, data) {
		t.Fatal("the file is not the upload")
	}
	waitFor(t, "uploaded reported to the helper", func() bool {
		a := r.f.last("health.get")
		v, _ := a.Get(1)
		return v == h.size
	})
	h.set(func(h *hfield) { h.working = true })
	time.Sleep(300 * time.Millisecond)
	if st := put(r, good, bytes.NewReader(data), int64(len(data))); st != 409 {
		t.Fatalf("PUT while the worker runs: %d", st)
	}
	h.set(func(h *hfield) { h.working, h.left = false, 30 })
	time.Sleep(300 * time.Millisecond)
	if st := put(r, good, bytes.NewReader(data), int64(len(data))); st != 409 {
		t.Fatalf("PUT with the window ending in 30 s (< size/256 KiB/s + 60 s): %d", st)
	}
	h.set(func(h *hfield) { h.window = false })
	time.Sleep(300 * time.Millisecond)
	if st := put(r, good, bytes.NewReader(data), int64(len(data))); st != 0 && st != 409 {
		t.Fatalf("PUT without a window: %d", st)
	}
}

// the upload file is opened with O_NOFOLLOW: a symlink planted there is never written through
func TestHTTPPutNoFollow(t *testing.T) {
	h := &hfield{healthy: true}
	windowField(h)
	h.size = 1024
	r := newHTTPRig(t, h)
	r.waitListening(true, "window")
	target := filepath.Join(t.TempDir(), "victim")
	os.WriteFile(target, []byte("keep"), 0o600)
	os.Symlink(target, filepath.Join(r.bulk, "payload"))
	if st := put(r, hex.EncodeToString(h.bearer), bytes.NewReader(make([]byte, 1024)), 1024); st == 200 {
		t.Fatal("PUT through a symlink")
	}
	if b, _ := os.ReadFile(target); string(b) != "keep" {
		t.Fatal("the symlink's target was written")
	}
}

// one PUT at a time; a client slower than 256 KiB/s (30 s average) is cut
type slowReader struct {
	n    int64
	step time.Duration
	read atomic.Int64
}

func (s *slowReader) Read(b []byte) (int, error) {
	if s.read.Load() >= s.n {
		return 0, io.EOF
	}
	time.Sleep(s.step)
	k := min(int64(len(b)), 1024, s.n-s.read.Load())
	s.read.Add(k)
	return int(k), nil
}

func TestHTTPPutSlowAndSingle(t *testing.T) {
	h := &hfield{healthy: true}
	windowField(h)
	h.size = 1 << 20
	r := newHTTPRig(t, h)
	r.waitListening(true, "window")
	sr := &slowReader{n: int64(h.size), step: 20 * time.Millisecond} // ~50 KiB/s
	done := make(chan int, 1)
	go func() { done <- put(r, hex.EncodeToString(h.bearer), sr, int64(h.size)) }()
	waitFor(t, "the slow PUT started", func() bool { return sr.read.Load() > 0 })
	if st := put(r, hex.EncodeToString(h.bearer), bytes.NewReader(make([]byte, h.size)), int64(h.size)); st != 409 {
		t.Fatalf("a second PUT while one runs: %d", st)
	}
	select {
	case st := <-done:
		if st == 200 {
			t.Fatal("a 50 KiB/s upload completed")
		}
	case <-time.After(3 * time.Second):
		t.Fatal("the slow PUT was not cut")
	}
}

// a failed bind (8095 taken) is reported in the poll
func TestHTTPBindFailed(t *testing.T) {
	h := &hfield{healthy: true}
	windowField(h)
	l, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	rr := newHTTPRigPort(t, h, l.Addr().(*net.TCPAddr).Port)
	waitFor(t, "bind failure reported", func() bool {
		v, _ := rr.f.last("health.get").Get(2)
		return v == true
	})
}

// a poll that stops bringing the http field (helper gone, health.get failing) = as if missing: closed within
// HTTPFieldMax, sessions ended (§3.8.1 "poll 失敗 / 過期 -> 不 bind")
func TestHTTPStalePollCloses(t *testing.T) {
	h := &hfield{healthy: true}
	windowField(h)
	r := newHTTPRig(t, h)
	r.waitListening(true, "window")
	r.owner()
	h.set(func(h *hfield) { h.fail = true })
	r.waitListening(false, "stale field -> closed")
	waitFor(t, "HTTP sessions ended", func() bool { return len(r.s.httpSessions()) == 0 })
}

// the http field: missing or malformed window keys = no window; an address must be IPv4
func TestHTTPFieldParse(t *testing.T) {
	now := time.Now()
	kid, b := bytes.Repeat([]byte{1}, 32), bytes.Repeat([]byte{2}, 16)
	full := cbor.M(2, "10.41.80.13", 3, kid, 4, uint64(900), 5, uint64(100), 6, b, 7, uint64(1000), 8, true)
	f := parseHTTPField(full, now)
	if f.addr != "10.41.80.13" || !f.window || f.left != 900*time.Second || f.size != 100 || !bytes.Equal(f.bearer, b) || !f.working {
		t.Fatalf("full: %+v", f)
	}
	for name, m := range map[string]cbor.Map{
		"no bearer":    cbor.M(2, "10.41.80.13", 3, kid, 4, uint64(900), 5, uint64(100)),
		"short bearer": cbor.M(2, "10.41.80.13", 3, kid, 4, uint64(900), 5, uint64(100), 6, b[:15]),
		"no owner":     cbor.M(2, "10.41.80.13", 4, uint64(900), 5, uint64(100), 6, b),
		"no time left": cbor.M(2, "10.41.80.13", 3, kid, 4, uint64(0), 5, uint64(100), 6, b),
		"no size":      cbor.M(2, "10.41.80.13", 3, kid, 4, uint64(900), 6, b),
	} {
		if f := parseHTTPField(m, now); f.window || f.bearer != nil {
			t.Fatalf("%s: a window %+v", name, f)
		}
	}
	for _, a := range []any{"::1", "not-an-ip", uint64(5), ""} {
		if f := parseHTTPField(cbor.M(2, a), now); f.addr != "" {
			t.Fatalf("address %v accepted", a)
		}
	}
	if f := parseHTTPField("not a map", now); f.addr != "" || f.window {
		t.Fatal("a non-map field")
	}
}

// the HTTP handshake takes HTTP's quota, not BLE's: BLE's 20 used up, an HTTP handshake still opens
func TestHTTPHandshakeOwnQuota(t *testing.T) {
	h := &hfield{healthy: true}
	windowField(h)
	r := newHTTPRig(t, h)
	r.waitListening(true, "window")
	for r.s.handshakeAllowed() {
	}
	if _, st, ok := r.handshake(r.psks[0]); !ok {
		t.Fatalf("an HTTP handshake after BLE's quota was used up: HTTP %d", st)
	}
	for r.s.httpHandshakeAllowed() {
	}
	time.Sleep(HandshakeMax + 500*time.Millisecond) // the first session's slot (a candidate is evictable anyway)
	if _, _, ok := r.handshake(r.psks[0]); ok {
		t.Fatal("an HTTP handshake over HTTP's quota")
	}
}

// review r1 B-m7: an empty /msg with nothing queued answers 204 within httpFetchWait and the session goes on (it is
// not held for the request timeout and then killed)
func TestHTTPEmptyFetchDoesNotHold(t *testing.T) {
	h := &hfield{healthy: true}
	windowField(h)
	r := newHTTPRig(t, h)
	r.waitListening(true, "window")
	p := r.owner()
	start := time.Now()
	st, _, _ := r.post("/batman/v1/msg", p.id, nil)
	if st != http.StatusNoContent || time.Since(start) > httpFetchWait+time.Second {
		t.Fatalf("empty fetch with nothing queued: HTTP %d after %s (want 204 within %s)", st, time.Since(start), httpFetchWait)
	}
	if code, _ := p.do("info", cbor.M()); code != 0 {
		t.Fatalf("the session did not survive an empty fetch: %d", code)
	}
}

// Stop returns only after the HTTP side closed its listener and sessions (K10's 500 ms; review r1 race: the loop
// logged after the test ended)
func TestHTTPStopWaits(t *testing.T) {
	h := &hfield{healthy: true}
	windowField(h)
	r := newHTTPRig(t, h)
	r.waitListening(true, "window")
	r.s.Stop()
	select {
	case <-r.s.httpDone:
	default:
		t.Fatal("Stop returned before the HTTP loop ended")
	}
	if r.listening() {
		t.Fatal("still listening after Stop")
	}
}
