package provd

// The HTTP channel (254-p3-impl §3.8): Noise over POST /batman/v1/session + /batman/v1/msg (the same sessions and
// routing as BLE, a pool of its own), and the upload PUT /batman/v1/bulk/0. Listens only on the address the helper
// gives in the poll's http field (http.2: given only while the firewall check holds), on 8095, and only in the
// fallback mode (HealthOK false for 5 min) or while the helper says an upload window is open.

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"errors"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"batman-prov/cbor"
)

const (
	HTTPPort          = 8095
	HTTPSlots         = 2  // HTTP sessions, apart from BLE's (§3.8.1)
	HTTPHandshakesMin = 10 // per minute, HTTP only
	httpMaxBody       = 9 << 10
	httpMaxConns      = 8
	uploadMinRate     = 256 << 10        // bytes / s, as a 30 s average
	httpIdleAuthed    = 10 * time.Minute // an HTTP session outlives the window / fallback by its idle time
	bulkName          = "payload"
)

// HTTP timings: variables only so the unit tests can shorten them
var (
	FallbackAfter    = 5 * time.Minute // HealthOK false this long -> the fallback listens
	FallbackClear    = time.Minute     // HealthOK true this long -> no new connections
	HTTPFieldMax     = 8 * time.Second // the poll's http field is older than two polls -> as if missing
	httpReadWait     = 15 * time.Second
	uploadRateWindow = 30 * time.Second
)

// httpField: the helper's health.get key 2 (§3.8.2), as of the poll at `at`
type httpField struct {
	at      time.Time
	addr    string
	window  bool
	owner   []byte
	left    time.Duration // the window's remaining time at `at`
	size    uint64
	bearer  []byte
	working bool
}

func parseHTTPField(v any, now time.Time) httpField {
	f := httpField{at: now}
	m, ok := v.(cbor.Map)
	if !ok {
		return f
	}
	if a, ok := m.Get(2); ok {
		if s, ok := a.(string); ok && net.ParseIP(s).To4() != nil {
			f.addr = s
		}
	}
	ov, _ := m.Get(3)
	lv, _ := m.Get(4)
	sv, _ := m.Get(5)
	bv, _ := m.Get(6)
	f.owner, _ = ov.([]byte)
	left, okL := lv.(uint64)
	f.size, _ = sv.(uint64)
	f.bearer, _ = bv.([]byte)
	if len(f.owner) == 32 && okL && left > 0 && f.size > 0 && len(f.bearer) == 16 {
		f.window, f.left = true, time.Duration(left)*time.Second
	} else {
		f.owner, f.bearer, f.size = nil, nil, 0 // missing keys = no window (fail-closed)
	}
	if w, ok := m.Get(8); ok {
		f.working, _ = w.(bool)
	}
	return f
}

// httpSide is the Server's HTTP state
type httpSide struct {
	mu        sync.Mutex
	field     httpField
	sess      map[string]*httpT
	hsTimes   []time.Time
	srv       *http.Server
	ln        net.Listener
	addr      string
	putting   bool
	falseFrom time.Time // HealthOK has been false since (zero = it is true)
	trueFrom  time.Time // HealthOK has been true since (zero = it is false)
	fallback  bool
	window    bool
	uploaded  atomic.Uint64
	bindFail  atomic.Bool
}

func (s *Server) httpFieldNow() httpField {
	s.http.mu.Lock()
	defer s.http.mu.Unlock()
	if time.Since(s.http.field.at) > HTTPFieldMax {
		return httpField{}
	}
	return s.http.field
}

// httpWindowOpen: the helper's window, by the last poll (the owner-only rule)
func (s *Server) httpWindowOpen() bool {
	f := s.httpFieldNow()
	return f.window && time.Since(f.at) < f.left
}

func (s *Server) httpHandshakeAllowed() bool {
	s.http.mu.Lock()
	defer s.http.mu.Unlock()
	now := time.Now()
	keep := s.http.hsTimes[:0]
	for _, t := range s.http.hsTimes {
		if now.Sub(t) < time.Minute {
			keep = append(keep, t)
		}
	}
	s.http.hsTimes = keep
	if len(keep) >= HTTPHandshakesMin {
		return false
	}
	s.http.hsTimes = append(s.http.hsTimes, now)
	return true
}

// httpRoleOK (§3.1-2, §3.8.1): psk_owner (-> candidate) always, psk_member only in the plain fallback mode; never NX
// or psk_replay (claim and re-acquire need a person next to the node, on BLE)
func (s *Server) httpRoleOK(r Role) bool {
	switch r {
	case RoleCandidate:
		return true
	case RoleMember:
		return !s.httpWindowOpen()
	}
	return false
}

// ---- the transport ---------------------------------------------------------------------------------------------

var errHTTPClosed = errors.New("provd: http session closed")

// httpT: one HTTP session. Requests push the frames of one Noise message; the session's replies come back whole.
type httpT struct {
	id     string
	in     chan []byte
	out    chan []byte
	rej    chan struct{}
	closed chan struct{}
	once   sync.Once
	busy   atomic.Bool
}

func newHTTPT() *httpT {
	b := make([]byte, 16)
	rand.Read(b)
	return &httpT{id: hex.EncodeToString(b), in: make(chan []byte, 32), out: make(chan []byte, 16),
		rej: make(chan struct{}, 1), closed: make(chan struct{})}
}

func (t *httpT) ReadFrame() ([]byte, error) {
	select {
	case f := <-t.in:
		return f, nil
	case <-t.closed:
		return nil, errHTTPClosed
	}
}

// WriteFrame: FrameLimit makes every message one frame. A reply nobody fetches within IdleAnon ends the session
// (a lost response = the session is aborted, §3.8.1).
func (t *httpT) WriteFrame(f []byte) error {
	if len(f) < 3 || f[0] != FlagStart|FlagEnd {
		return ErrFrame
	}
	select {
	case t.out <- append([]byte(nil), f[3:]...):
		return nil
	case <-t.closed:
		return errHTTPClosed
	case <-time.After(IdleAnon):
		return errors.New("provd: http reply not fetched")
	}
}

func (t *httpT) FrameLimit() int { return MaxMsg + 3 }
func (t *httpT) Kind() string    { return "http" }
func (t *httpT) Close()          { t.once.Do(func() { close(t.closed) }) }

// reject: the request carried a message that failed AEAD: that request gets 400, the session goes on
func (t *httpT) reject() {
	select {
	case t.rej <- struct{}{}:
	default:
	}
}

func (t *httpT) push(msg []byte) bool {
	for _, f := range Split(msg, MaxFrame) {
		select {
		case t.in <- f:
		case <-t.closed:
			return false
		}
	}
	return true
}

// ---- the controller (every second) -----------------------------------------------------------------------------

func (s *Server) httpLoop() {
	tk := time.NewTicker(time.Second)
	defer tk.Stop()
	for {
		select {
		case <-s.stop:
			s.httpClose("stop")
			return
		case <-tk.C:
			s.httpTick()
		}
	}
}

func (s *Server) httpTick() {
	ok, _ := s.HealthOK()
	now := time.Now()
	f := s.httpFieldNow()
	h := &s.http
	h.mu.Lock()
	if ok {
		h.falseFrom = time.Time{}
		if h.trueFrom.IsZero() {
			h.trueFrom = now
		}
		if h.fallback && now.Sub(h.trueFrom) >= FallbackClear {
			h.fallback = false
		}
	} else {
		h.trueFrom = time.Time{}
		if h.falseFrom.IsZero() {
			h.falseFrom = now
		}
		if now.Sub(h.falseFrom) >= FallbackAfter {
			h.fallback = true
		}
	}
	win := f.window && now.Sub(f.at) < f.left
	opened := win && !h.window
	h.window = win
	want := f.addr != "" && (h.fallback || win)
	keep := f.addr != "" && (len(h.sess) > 0 || h.putting) // no new connections, the established ones go on
	bound, baddr := h.ln != nil, h.addr
	h.mu.Unlock()
	if opened {
		s.httpKillMembers() // §3.8.1: a window accepts only the owner
	}
	switch {
	case f.addr == "":
		if bound {
			s.httpClose("no http.2 (firewall check, or the poll is stale)")
		}
	case want && (!bound || baddr != f.addr):
		if bound {
			s.httpClose("address changed")
		}
		s.httpListen(f.addr)
	case !want && !keep && bound:
		s.httpClose("no fallback, no window")
	}
}

// httpAccepting: new HTTP sessions / PUTs are taken only in a listening mode
func (s *Server) httpAccepting() bool {
	s.http.mu.Lock()
	defer s.http.mu.Unlock()
	return s.http.fallback || s.http.window
}

func (s *Server) httpKillMembers() {
	for _, ss := range s.httpSessions() {
		if ss.Role() == RoleMember {
			ss.Kill("upload window: owner only")
		}
	}
}

func (s *Server) httpSessions() []*Session {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []*Session
	for _, ss := range s.sessions {
		if ss.t.Kind() == "http" {
			out = append(out, ss)
		}
	}
	return out
}

func (s *Server) httpListen(addr string) {
	port := s.cfg.HTTPPort
	if port == 0 {
		port = HTTPPort
	}
	ln, err := net.Listen("tcp4", net.JoinHostPort(addr, strconv.Itoa(port)))
	if err != nil {
		if !s.http.bindFail.Load() {
			s.logf("provd: http: bind %s: %v", addr, err)
		}
		s.http.bindFail.Store(true)
		return
	}
	s.http.bindFail.Store(false)
	mux := http.NewServeMux()
	mux.HandleFunc("POST /batman/v1/session", s.httpSession)
	mux.HandleFunc("POST /batman/v1/msg", s.httpMsg)
	mux.HandleFunc("PUT /batman/v1/bulk/0", s.httpPut)
	hs := &http.Server{Handler: mux, ReadHeaderTimeout: 5 * time.Second, IdleTimeout: 30 * time.Second,
		MaxHeaderBytes: 4 << 10, ErrorLog: nil}
	s.http.mu.Lock()
	s.http.srv, s.http.ln, s.http.addr = hs, ln, addr
	s.http.mu.Unlock()
	s.logf("provd: http: listening on %s", ln.Addr())
	go hs.Serve(&limitListener{Listener: ln, sem: make(chan struct{}, httpMaxConns)})
}

// httpClose: stop listening and end every HTTP session
func (s *Server) httpClose(why string) {
	s.http.mu.Lock()
	hs := s.http.srv
	s.http.srv, s.http.ln, s.http.addr = nil, nil, ""
	s.http.mu.Unlock()
	if hs != nil {
		hs.Close()
		s.logf("provd: http: closed (%s)", why)
	}
	for _, ss := range s.httpSessions() {
		ss.Kill("http closed")
	}
}

// limitListener: at most n connections at a time (F43; provd's soft nofile is 1024)
type limitListener struct {
	net.Listener
	sem chan struct{}
}

func (l *limitListener) Accept() (net.Conn, error) {
	l.sem <- struct{}{}
	c, err := l.Listener.Accept()
	if err != nil {
		<-l.sem
		return nil, err
	}
	return &limitConn{Conn: c, release: func() { <-l.sem }}, nil
}

type limitConn struct {
	net.Conn
	once    sync.Once
	release func()
}

func (c *limitConn) Close() error {
	err := c.Conn.Close()
	c.once.Do(c.release)
	return err
}

// ---- handlers ----------------------------------------------------------------------------------------------------

func readBody(w http.ResponseWriter, r *http.Request) ([]byte, bool) {
	http.NewResponseController(w).SetReadDeadline(time.Now().Add(httpReadWait))
	b, err := io.ReadAll(http.MaxBytesReader(w, r.Body, httpMaxBody))
	if err != nil {
		http.Error(w, "body", http.StatusRequestEntityTooLarge)
		return nil, false
	}
	return b, true
}

// wait: the session's next reply for this request (or its end)
func (s *Server) httpReply(w http.ResponseWriter, t *httpT, ss *Session, setID bool) {
	select {
	case m := <-t.out:
		w.Header().Set("Content-Type", "application/octet-stream")
		if setID {
			w.Header().Set("X-Batman-Session", t.id)
		}
		if _, err := w.Write(m); err != nil {
			ss.Kill("http response lost")
		}
	case <-t.rej:
		http.Error(w, "message", http.StatusBadRequest)
	case <-ss.Done():
		http.Error(w, "session ended", http.StatusGone)
	case <-time.After(HelperWait + 30*time.Second):
		ss.Kill("http: no reply")
		http.Error(w, "no reply", http.StatusGatewayTimeout)
	}
}

func (s *Server) httpSession(w http.ResponseWriter, r *http.Request) {
	if !s.httpAccepting() {
		http.Error(w, "not listening", http.StatusServiceUnavailable)
		return
	}
	msg1, ok := readBody(w, r)
	if !ok {
		return
	}
	t := newHTTPT()
	ss := s.Accept(t)
	if ss == nil {
		http.Error(w, "busy", http.StatusServiceUnavailable)
		return
	}
	s.http.mu.Lock()
	if s.http.sess == nil {
		s.http.sess = map[string]*httpT{}
	}
	s.http.sess[t.id] = t
	s.http.mu.Unlock()
	go func() {
		<-ss.Done()
		s.http.mu.Lock()
		delete(s.http.sess, t.id)
		s.http.mu.Unlock()
	}()
	t.busy.Store(true)
	defer t.busy.Store(false)
	if !t.push(msg1) {
		http.Error(w, "session ended", http.StatusGone)
		return
	}
	s.httpReply(w, t, ss, true)
}

func (s *Server) httpMsg(w http.ResponseWriter, r *http.Request) {
	id := r.Header.Get("X-Batman-Session")
	s.http.mu.Lock()
	t := s.http.sess[id]
	s.http.mu.Unlock()
	ss := s.sessionOf(t)
	if t == nil || ss == nil {
		http.Error(w, "no such session", http.StatusNotFound)
		return
	}
	if !t.busy.CompareAndSwap(false, true) {
		http.Error(w, "one request at a time", http.StatusConflict)
		return
	}
	defer t.busy.Store(false)
	m, ok := readBody(w, r)
	if !ok {
		return
	}
	if len(m) > 0 && !t.push(m) { // an empty body = fetch the next block of a chunked reply
		http.Error(w, "session ended", http.StatusGone)
		return
	}
	s.httpReply(w, t, ss, false)
}

func (s *Server) sessionOf(t *httpT) *Session {
	if t == nil {
		return nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, ss := range s.sessions {
		if ss.t == Transport(t) {
			return ss
		}
	}
	return nil
}

// httpPut: PUT /batman/v1/bulk/0 (§3.8.2) — the upload bearer is its only credential; from the start every time
func (s *Server) httpPut(w http.ResponseWriter, r *http.Request) {
	f := s.httpFieldNow()
	left := f.left - time.Since(f.at)
	switch {
	case !f.window || left <= 0 || len(f.bearer) != 16:
		http.Error(w, "no upload window", http.StatusConflict)
		return
	case f.working:
		http.Error(w, "the update is being written", http.StatusConflict)
		return
	}
	got := r.Header.Get("X-Batman-Upload")
	b, err := hex.DecodeString(got)
	if len(got) != 32 || err != nil || hex.EncodeToString(b) != got || subtle.ConstantTimeCompare(b, f.bearer) != 1 {
		http.Error(w, "upload credential", http.StatusForbidden)
		return
	}
	if r.ContentLength < 0 || uint64(r.ContentLength) != f.size {
		http.Error(w, "Content-Length must be the payload size", http.StatusBadRequest)
		return
	}
	if left < time.Duration(r.ContentLength/uploadMinRate)*time.Second+60*time.Second {
		http.Error(w, "the window ends too soon: bulk/open again first", http.StatusConflict)
		return
	}
	s.http.mu.Lock()
	if s.http.putting {
		s.http.mu.Unlock()
		http.Error(w, "an upload is in progress", http.StatusConflict)
		return
	}
	s.http.putting = true
	s.http.mu.Unlock()
	defer func() { s.http.mu.Lock(); s.http.putting = false; s.http.mu.Unlock() }()
	dir := s.cfg.BulkDir
	if dir == "" {
		dir = "/tmp/run/batman-provd-bulk"
	}
	fd, err := syscall.Open(filepath.Join(dir, bulkName), syscall.O_WRONLY|syscall.O_CREAT|syscall.O_TRUNC|syscall.O_NOFOLLOW|syscall.O_CLOEXEC, 0o600)
	if err != nil {
		s.logf("provd: http: upload file: %v", err)
		http.Error(w, "storage", http.StatusInternalServerError)
		return
	}
	out := os.NewFile(uintptr(fd), bulkName)
	s.http.uploaded.Store(0)
	n, err := s.copyUpload(w, out, r.Body, r.ContentLength)
	if cerr := out.Close(); err == nil && cerr != nil {
		err = cerr
	}
	if err != nil || n != r.ContentLength {
		s.logLimited("put", "provd: http: upload cut at %d of %d bytes: %v", n, r.ContentLength, err)
		http.Error(w, "upload incomplete", http.StatusBadRequest)
		return
	}
	w.WriteHeader(http.StatusOK) // only after the file is closed (§3.8.2)
}

// copyUpload: exactly n bytes, at least 256 KiB/s over every 30 s (a slow client is cut)
func (s *Server) copyUpload(w http.ResponseWriter, dst io.Writer, src io.Reader, n int64) (int64, error) {
	rc := http.NewResponseController(w)
	buf := make([]byte, 64<<10)
	var done int64
	mark, markAt := int64(0), time.Now()
	for done < n {
		rc.SetReadDeadline(time.Now().Add(uploadRateWindow))
		k, err := src.Read(buf[:min(int64(len(buf)), n-done)])
		if k > 0 {
			if _, werr := dst.Write(buf[:k]); werr != nil {
				return done, werr
			}
			done += int64(k)
			s.http.uploaded.Store(uint64(done))
		}
		if now := time.Now(); now.Sub(markAt) >= uploadRateWindow {
			if done-mark < int64(uploadMinRate*uploadRateWindow/time.Second) {
				return done, errors.New("slower than 256 KiB/s")
			}
			mark, markAt = done, now
		}
		if err == io.EOF && done < n {
			return done, io.ErrUnexpectedEOF
		}
		if err != nil && err != io.EOF {
			return done, err
		}
	}
	return done, nil
}
