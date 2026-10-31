package provd

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/flynn/noise"

	"batman-prov/cbor"
)

// Timings (254-p2-impl §4.1–§4.4). Variables only so the unit tests can shorten them.
var (
	PollEvery     = 4 * time.Second   // ctl: health.get + info.state
	CtlWait       = 10 * time.Second  // one ctl request; no answer -> close ctl, reconnect
	HelperWait    = 330 * time.Second // one ops request (the verb may still finish later: outcome unknown)
	SignWait      = 30 * time.Second
	KeepaliveIdle = 20 * time.Second // the helper closes a connection idle for 30 s
	StaleAfter    = 60 * time.Second // no successful info.state / health.get for this long = not fresh
	ERateMax      = 120 * time.Second
	NonceLife     = 55 * time.Second // the helper's is 60 s
	HandshakeMax  = 10 * time.Second
	IdleAnon      = 30 * time.Second
	IdleAuthed    = 300 * time.Second
)

const (
	Slots         = 2 // BLE + sock together (219 §8)
	HandshakesMin = 20
	ClaimFails    = 3
)

// TestEnv: the prov_test switches (provd.env, h23 §4.8.3); zero in a release build.
type TestEnv struct {
	SockOnly        bool
	FastFakeDelayMS int
	NoBruteLimit    bool
	GattEncryptCtrl bool
	AdvLenTest      int
}

// Config wires a Server.
type Config struct {
	HelperPath string
	Log        func(string, ...any)
	Model      string // BATMAN_MODEL, "dev" when the stamp has none (the one fail-open, §8)
	Board      string // bcm2710 / bcm2711
	FW         string // BATMAN_VERSION
	Test       TestEnv
	Rand       func([]byte) // tests; crypto/rand otherwise
}

// node-state numbers (CDDL node-state)
var stateNum = map[string]uint64{"unclaimed": 0, "claimed": 1, "member": 2, "legacy": 3}

type pskSet struct {
	owners [][]byte
	member []byte
	replay []byte
}

type cache struct {
	state    string
	gen      uint64
	trial    bool
	stateOK  bool
	stateAt  time.Time
	health   map[string]string
	healthAt time.Time
	erateAt  time.Time // first ERate of the current run of ERate on ctl (zero = none)
	owners   [][]byte  // info.owners, nil until fetched
	psks     *pskSet
	// re-fetch marks (stale-while-revalidate: the old sets serve until the new ones arrive)
	needOwners, needPSK bool
	cert, sn, ecdhPub   []byte
	bootID              []byte
	deviceID            string
}

// Server is provd's state of one start.
type Server struct {
	cfg      Config
	ctl, ops *HelperConn
	ctlMu    sync.Mutex // ctl carries the poll and the sessions' read-only calls, one at a time
	static   noise.DHKey

	mu       sync.Mutex
	c        cache
	nodeCert []byte
	sessions []*Session
	hsTimes  []time.Time
	opsEpoch uint64
	ctlEpoch uint64
	changed  chan struct{} // closed + replaced when readiness / health may have changed (BLE side waits on it)
	stop     chan struct{}
	logLimit map[string][]time.Time
}

// NewServer makes the per-start Noise static key (219 §3.3) and the two helper connections.
func NewServer(cfg Config) (*Server, error) {
	if cfg.Log == nil {
		cfg.Log = func(string, ...any) {}
	}
	if cfg.Model == "" {
		cfg.Model = "dev"
	}
	st, err := GenerateStatic(rand.Reader)
	if err != nil {
		return nil, err
	}
	s := &Server{cfg: cfg, static: st, changed: make(chan struct{}), stop: make(chan struct{}), logLimit: map[string][]time.Time{}}
	s.ctl = &HelperConn{Path: cfg.HelperPath, Name: "ctl", MaxBackoff: 10 * time.Second, Log: cfg.Log}
	s.ops = &HelperConn{Path: cfg.HelperPath, Name: "ops", MaxBackoff: 60 * time.Second, Log: cfg.Log}
	return s, nil
}

func (s *Server) logf(f string, a ...any) { s.cfg.Log(f, a...) }

// logLimited: at most 10 lines a minute per key (a passer-by flood must not wash the log, §4.4)
func (s *Server) logLimited(key, f string, a ...any) {
	s.mu.Lock()
	now := time.Now()
	keep := s.logLimit[key][:0]
	for _, t := range s.logLimit[key] {
		if now.Sub(t) < time.Minute {
			keep = append(keep, t)
		}
	}
	ok := len(keep) < 10
	if ok {
		keep = append(keep, now)
	}
	s.logLimit[key] = keep
	s.mu.Unlock()
	if ok {
		s.logf(f, a...)
	}
}

func (s *Server) notify() {
	s.mu.Lock()
	close(s.changed)
	s.changed = make(chan struct{})
	s.mu.Unlock()
}

// Changed returns a channel closed at the next readiness / health / state change.
func (s *Server) Changed() <-chan struct{} {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.changed
}

// ctlCall: one read-only request on ctl (serialised); ERate is returned as a reply, a timeout closes ctl. A new ctl
// connection may mean a helper restart: the owner / PSK sets are re-fetched (and the boot_id check in the poll
// re-signs node_cert, L11).
func (s *Server) ctlCall(verb string, args cbor.Map) (Reply, error) {
	s.ctlMu.Lock()
	defer s.ctlMu.Unlock()
	r, err := s.ctl.Call(verb, args, CtlWait)
	if err == ErrTimeout {
		s.logf("helper ctl: %s unanswered for %s — reconnecting", verb, CtlWait)
		s.ctl.Close()
	}
	if e := s.ctl.Epoch(); e != 0 {
		s.mu.Lock()
		if e != s.ctlEpoch {
			s.ctlEpoch = e
			s.c.needOwners, s.c.needPSK = true, true
		}
		s.mu.Unlock()
	}
	return r, err
}

// opsCall: one request on ops. ErrBusy = another one is in flight. A new ops connection (helper restart) drops every
// session's nonce pair (the helper's nonces were in its memory, §4.3).
func (s *Server) opsCall(verb string, args cbor.Map, wait time.Duration) (Reply, error) {
	r, err := s.ops.Call(verb, args, wait)
	if e := s.ops.Epoch(); e != 0 {
		s.mu.Lock()
		if e != s.opsEpoch {
			old := s.opsEpoch
			s.opsEpoch = e
			if old != 0 {
				for _, ss := range s.sessions {
					ss.dropNonce()
				}
				s.c.needOwners, s.c.needPSK = true, true
			}
		}
		s.mu.Unlock()
	}
	return r, err
}

// idempotent ops verbs are re-sent once after a lost connection
func (s *Server) opsIdem(verb string, args cbor.Map, wait time.Duration) (Reply, error) {
	r, err := s.opsCall(verb, args, wait)
	if err == ErrGone {
		time.Sleep(200 * time.Millisecond)
		r, err = s.opsCall(verb, args, wait)
	}
	return r, err
}

// Run fetches the identity, builds node_cert, then polls until Stop. It never returns early on helper errors (backoff).
func (s *Server) Run() {
	go s.pollLoop()
	go s.opsLoop()
	<-s.stop
}

// Stop ends the loops and disconnects every session.
func (s *Server) Stop() {
	s.mu.Lock()
	ss := append([]*Session(nil), s.sessions...)
	s.mu.Unlock()
	for _, x := range ss {
		x.Kill("stop")
	}
	select {
	case <-s.stop:
	default:
		close(s.stop)
	}
}

func (s *Server) sleep(d time.Duration) bool {
	select {
	case <-s.stop:
		return false
	case <-time.After(d):
		return true
	}
}

// identity: info.cert / info.ecdh_pub / info.boot_id (ctl, read-only), then sign.static + sign.ecdh_proof (ops,
// back to back: the helper allows 2/s, F-P24; ERate -> 1 s later).
func (s *Server) buildNodeCert() error {
	r, err := s.ctlCall("info.cert", nil)
	if err != nil || r.Code != hOK {
		return fmt.Errorf("info.cert: %v code %d", err, r.Code)
	}
	cv, _ := r.Body.Get(1)
	snv, _ := r.Body.Get(2)
	cert, _ := cv.([]byte)
	sn, _ := snv.([]byte)
	r, err = s.ctlCall("info.ecdh_pub", nil)
	if err != nil || r.Code != hOK {
		return fmt.Errorf("info.ecdh_pub: %v code %d", err, r.Code)
	}
	ev, _ := r.Body.Get(1)
	ecdh, _ := ev.([]byte)
	sign := func(verb string, args cbor.Map) (cbor.Map, error) {
		for i := 0; i < 5; i++ {
			r, err := s.opsIdem(verb, args, SignWait)
			if err == nil && r.Code == hERate || err == ErrBusy {
				if !s.sleep(time.Second) {
					return nil, ErrGone
				}
				continue
			}
			if err != nil || r.Code != hOK {
				return nil, fmt.Errorf("%s: %v code %d", verb, err, r.Code)
			}
			return r.Body, nil
		}
		return nil, fmt.Errorf("%s: rate", verb)
	}
	b, err := sign("sign.static", cbor.M(1, s.static.Public))
	if err != nil {
		return err
	}
	sigS, _ := b.Get(1)
	bid, _ := b.Get(2)
	b, err = sign("sign.ecdh_proof", nil)
	if err != nil {
		return err
	}
	sigE, _ := b.Get(1)
	if len(cert) == 0 || len(sn) != 9 || len(ecdh) != 65 {
		return fmt.Errorf("identity fields: cert %d sn %d ecdh %d", len(cert), len(sn), len(ecdh))
	}
	nc, err := cbor.Encode(cbor.M(1, []any{cert}, 2, s.static.Public, 3, bid, 4, ecdh, 5, sigS, 6, sigE, 7, sn))
	if err != nil {
		return err
	}
	s.mu.Lock()
	s.nodeCert = nc
	s.c.cert, s.c.sn, s.c.ecdhPub, s.c.deviceID = cert, sn, ecdh, hex.EncodeToString(sn)
	s.c.bootID, _ = bid.([]byte)
	s.mu.Unlock()
	s.logf("node_cert ready (%d B)", len(nc))
	s.notify()
	return nil
}

func parseHealth(line string) map[string]string {
	kv := map[string]string{}
	for _, f := range strings.Fields(line) {
		k, v, _ := strings.Cut(f, "=")
		kv[k] = v
	}
	return kv
}

// pollLoop: every 4 s health.get first (撤廣播 timing, §4.4), then info.state; a (state, gen) change marks the owner
// and PSK sets for re-fetch. node_cert is (re)built whenever missing or the helper's boot_id changed.
func (s *Server) pollLoop() {
	back := time.Second
	for {
		s.mu.Lock()
		have := s.nodeCert != nil
		s.mu.Unlock()
		if !have {
			if err := s.buildNodeCert(); err != nil {
				s.logf("provd: backoff %ds reason=identity (%v)", int(back/time.Second), err)
				if !s.sleep(back) {
					return
				}
				if back *= 2; back > 60*time.Second {
					back = 60 * time.Second
				}
				continue
			}
			back = time.Second
		}
		start := time.Now()
		s.pollOnce()
		if !s.sleep(time.Until(start.Add(PollEvery))) {
			return
		}
	}
}

func (s *Server) pollOnce() {
	r, err := s.ctlCall("health.get", nil)
	now := time.Now()
	switch {
	case err == nil && r.Code == hOK:
		lv, _ := r.Body.Get(1)
		line, _ := lv.(string)
		s.mu.Lock()
		s.c.health, s.c.healthAt, s.c.erateAt = parseHealth(line), now, time.Time{}
		s.mu.Unlock()
	case err == nil && r.Code == hERate: // not a success, not a failure (§4.1); > 120 s in a row = stale
		s.mu.Lock()
		if s.c.erateAt.IsZero() {
			s.c.erateAt = now
		}
		s.mu.Unlock()
		s.sleep(time.Second)
	}
	r, err = s.ctlCall("info.state", nil)
	if err == nil && r.Code == hOK {
		sv, _ := r.Body.Get(1)
		gv, _ := r.Body.Get(2)
		tv, _ := r.Body.Get(5)
		st, _ := sv.(string)
		gen, _ := gv.(uint64)
		trial, _ := tv.(bool)
		s.mu.Lock()
		changed := !s.c.stateOK || st != s.c.state || gen != s.c.gen
		if changed {
			s.c.needOwners, s.c.needPSK = true, true
		}
		s.c.state, s.c.gen, s.c.trial, s.c.stateOK, s.c.stateAt = st, gen, trial, true, now
		s.mu.Unlock()
	}
	// a helper restart changes its boot_id: node_cert must be re-signed (L11)
	if r, err := s.ctlCall("info.boot_id", nil); err == nil && r.Code == hOK {
		bv, _ := r.Body.Get(1)
		b, _ := bv.([]byte)
		s.mu.Lock()
		if s.c.bootID != nil && !bytes.Equal(b, s.c.bootID) {
			s.logf("helper boot_id changed: re-signing node_cert")
			s.nodeCert = nil
			s.c.needOwners, s.c.needPSK = true, true
		}
		s.mu.Unlock()
	}
	s.mu.Lock()
	needO := s.c.needOwners
	s.mu.Unlock()
	if needO {
		if r, err := s.ctlCall("info.owners", nil); err == nil && (r.Code == hOK || r.Code == hEUnsupported) {
			var pubs [][]byte
			if r.Code == hOK {
				lv, _ := r.Body.Get(1)
				l, _ := lv.([]any)
				for _, p := range l {
					if b, ok := p.([]byte); ok {
						pubs = append(pubs, b)
					}
				}
			}
			if pubs == nil {
				pubs = [][]byte{}
			}
			s.mu.Lock()
			s.c.owners, s.c.needOwners = pubs, false
			s.mu.Unlock()
			s.reconcile()
		}
	}
	s.notify()
}

// opsLoop: the PSK re-fetch (only when ops is free: never queued behind a long verb) and the keepalive.
func (s *Server) opsLoop() {
	for s.sleep(500 * time.Millisecond) {
		s.mu.Lock()
		needP := s.c.needPSK && s.c.stateOK
		s.mu.Unlock()
		if needP && !s.ops.Busy() {
			r, err := s.opsCall("psks.get", nil, SignWait)
			if err == nil && r.Code == hOK {
				p := &pskSet{}
				ov, _ := r.Body.Get(1)
				l, _ := ov.([]any)
				for _, x := range l {
					if b, ok := x.([]byte); ok && len(b) == 32 {
						p.owners = append(p.owners, b)
					}
				}
				if m, _ := r.Body.Get(2); m != nil {
					p.member, _ = m.([]byte)
				}
				if m, _ := r.Body.Get(3); m != nil {
					p.replay, _ = m.([]byte)
				}
				s.mu.Lock()
				s.c.psks, s.c.needPSK = p, false
				s.mu.Unlock()
				s.reconcile()
				s.notify()
			} else if err == nil && r.Code == hEUnsupported { // no record: nothing to try (NX node or broken)
				s.mu.Lock()
				s.c.psks, s.c.needPSK = &pskSet{}, false
				s.mu.Unlock()
				s.notify()
			}
			continue // ERate / busy / error: retried on the next tick, the old set keeps serving
		}
		if !s.ops.Busy() && s.ops.Idle() >= KeepaliveIdle && s.ops.Epoch() > 0 {
			s.opsCall("info.boot_id", nil, CtlWait) // ERate ignored
		}
	}
}

// Ready: node_cert built, the state known, and in a PSK state the PSK set fetched once.
func (s *Server) Ready() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.readyLocked()
}

func (s *Server) readyLocked() bool {
	if s.nodeCert == nil || !s.c.stateOK {
		return false
	}
	switch s.c.state {
	case "unclaimed", "legacy":
		return true
	case "claimed", "member":
		return s.c.psks != nil
	}
	return false
}

// HealthOK: the advertising preconditions from the last health.get (254-p2-impl §4.4) and their freshness; reason
// for the log when false.
func (s *Server) HealthOK() (bool, string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := time.Now()
	if s.c.healthAt.IsZero() || now.Sub(s.c.healthAt) > StaleAfter || (!s.c.erateAt.IsZero() && now.Sub(s.c.erateAt) > ERateMax) {
		return false, "helper"
	}
	h := s.c.health
	for k, want := range map[string]string{"bluetoothd": "1", "hci0_powered": "1", "privacy": "1", "sc": "1", "sc_file": "1", "bondable": "0"} {
		if h[k] != want {
			return false, "health"
		}
	}
	if !s.readyLocked() {
		return false, "helper"
	}
	return true, ""
}

// KernelInstances: num_instances from the last health.get (-1 = unknown)
func (s *Server) KernelInstances() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	v, ok := s.c.health["num_instances"]
	if !ok {
		return -1
	}
	n := 0
	fmt.Sscanf(v, "%d", &n)
	return n
}

// statusFresh: info.state succeeded within 60 s (STATUS / sock 0xC1 answer only then, §4.1).
func (s *Server) statusFresh() bool {
	return s.c.stateOK && time.Since(s.c.stateAt) <= StaleAfter
}

// statusRecent: the last info.state answered within two poll periods (the claim/finish reason-10 inference, F-P38)
func (s *Server) statusRecent() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.c.stateOK && time.Since(s.c.stateAt) <= 2*PollEvery+2*time.Second
}

// info builds info-resp (CDDL) for a session of this role: 9 / 10 / 11 only for owner / member, from info.net on
// ctl; an ERate there drops those three keys (logged), never the whole answer.
func (s *Server) info(role Role) cbor.Map {
	s.mu.Lock()
	n := stateNum[s.c.state]
	m := cbor.M(1, s.c.deviceID, 2, s.cfg.Model, 3, s.cfg.Board, 4, s.cfg.FW, 5, []any{uint64(1), uint64(0)},
		6, []any{"halow"}, 7, n, 8, (n == 0 || n == 3) && !s.c.trial)
	s.mu.Unlock()
	if role != RoleOwner && role != RoleMember {
		return m
	}
	r, err := s.ctlCall("info.net", nil)
	if err != nil || r.Code != hOK {
		s.logLimited("info", "provd: info.net unavailable (%v code %d): info without net fields", err, r.Code)
		return m
	}
	nid, _ := r.Body.Get(1)
	ver, _ := r.Body.Get(2)
	unf, _ := r.Body.Get(4)
	if b, ok := nid.([]byte); ok && len(b) == 16 {
		m = append(m, cbor.Entry{K: uint64(9), V: ver}, cbor.Entry{K: uint64(10), V: b})
	}
	if u, ok := unf.(bool); ok {
		m = append(m, cbor.Entry{K: uint64(11), V: u})
	}
	return m
}

// Ctrl is the CTRL characteristic value (constant).
func Ctrl() []byte {
	b, _ := cbor.Encode(cbor.M(1, uint64(1), 2, uint64(0), 3, uint64(OutFrame), 4, uint64(MaxMsg)))
	return b
}

// Status is the STATUS characteristic value; ok = false when the cache is not fresh (-> ATT 0x0E, not a guess).
func (s *Server) Status() ([]byte, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.statusFresh() {
		return nil, false
	}
	n, ok := stateNum[s.c.state]
	if !ok {
		return nil, false
	}
	m := cbor.M(1, []any{uint64(1), uint64(0)}, 2, []any{"halow"}, 3, n, 4, s.c.trial)
	if (n == 0 || n == 3) && len(s.c.deviceID) >= 4 {
		m = append(m, cbor.Entry{K: uint64(5), V: s.c.deviceID[len(s.c.deviceID)-4:]})
	}
	b, _ := cbor.Encode(m)
	return b, true
}

// invalidate after provd's own state-changing verb answered (any code)
func (s *Server) invalidate() {
	s.mu.Lock()
	s.c.needOwners, s.c.needPSK = true, true
	s.mu.Unlock()
}

func ownerKID(pub []byte) []byte { h := sha256.Sum256(pub); return h[:] }

func inSet(set [][]byte, v []byte) bool {
	for _, x := range set {
		if bytes.Equal(x, v) {
			return true
		}
	}
	return false
}

// reconcile: the one revocation rule (254-p2-impl §1.3): with the NEW sets in hand, every session whose credential is
// no longer in them is disconnected — owner by owner_key_id against info.owners, candidate by its psk_owner value,
// re-acquire by psk_replay, member by psk_member. Anonymous sessions are left alone. Not "who changed it".
func (s *Server) reconcile() {
	s.mu.Lock()
	owners, psks := s.c.owners, s.c.psks
	var kill []*Session
	var why []string
	for _, ss := range s.sessions {
		ss.mu.Lock()
		role, kid, psk := ss.role, ss.ownerKID, ss.psk
		ss.mu.Unlock()
		switch role {
		case RoleOwner:
			if owners != nil {
				hit := false
				for _, o := range owners {
					if bytes.Equal(ownerKID(o), kid) {
						hit = true
					}
				}
				if !hit {
					kill, why = append(kill, ss), append(why, "owner-removed")
				}
			}
		case RoleCandidate:
			if psks != nil && !inSet(psks.owners, psk) {
				kill, why = append(kill, ss), append(why, "owner-removed")
			}
		case RoleReacquire:
			if psks != nil && !bytes.Equal(psks.replay, psk) {
				kill, why = append(kill, ss), append(why, "owner-removed")
			}
		case RoleMember:
			if psks != nil && !bytes.Equal(psks.member, psk) {
				kill, why = append(kill, ss), append(why, "psk-rotated")
			}
		}
	}
	s.mu.Unlock()
	for i, ss := range kill {
		s.logf("provd: session revoked reason=%s", why[i])
		ss.Kill(why[i])
	}
}

// handshakeAllowed: the global 20 / minute window (21st -> disconnect)
func (s *Server) handshakeAllowed() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := time.Now()
	keep := s.hsTimes[:0]
	for _, t := range s.hsTimes {
		if now.Sub(t) < time.Minute {
			keep = append(keep, t)
		}
	}
	s.hsTimes = keep
	if len(keep) >= HandshakesMin {
		return false
	}
	s.hsTimes = append(s.hsTimes, now)
	return true
}

func (s *Server) rand(b []byte) {
	if s.cfg.Rand != nil {
		s.cfg.Rand(b)
		return
	}
	rand.Read(b)
}

// handshakeParams: prologue + candidate PSKs for the current state (nil = NX); the PSK values ride along so the
// session can remember which credential opened it.
func (s *Server) handshakeParams() (prologue []byte, psks [][]byte, cert []byte, ok bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.readyLocked() {
		return nil, nil, nil, false
	}
	cert = s.nodeCert
	switch s.c.state {
	case "unclaimed", "legacy":
		return Prologue(s.c.deviceID), nil, cert, true
	}
	p := s.c.psks
	psks = make([][]byte, 0, NumPSK)
	for _, k := range p.owners {
		if len(psks) < 4 {
			psks = append(psks, k)
		}
	}
	for len(psks) < 4 {
		psks = append(psks, nil)
	}
	psks = append(psks, p.member, p.replay)
	for i := range psks {
		if len(psks[i]) != 32 {
			b := make([]byte, 32)
			s.rand(b)
			psks[i] = b
		}
	}
	return Prologue(""), psks, cert, true
}

// roleOfPSK maps the candidate index Respond reported to a role.
func roleOfPSK(i int) Role {
	switch {
	case i >= 0 && i < 4:
		return RoleCandidate
	case i == 4:
		return RoleMember
	case i == 5:
		return RoleReacquire
	}
	return RoleNone
}

// realPSK: the candidate at i was a stored one (not random padding)
func (s *Server) realPSK(i int, v []byte) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	p := s.c.psks
	if p == nil {
		return false
	}
	switch {
	case i < 4:
		return inSet(p.owners, v)
	case i == 4:
		return bytes.Equal(p.member, v)
	case i == 5:
		return bytes.Equal(p.replay, v)
	}
	return false
}

// Accept takes a new connection: 2 slots for BLE + sock together; a third evicts the oldest unauthenticated /
// candidate session that is not mid-handshake, or is refused (§4.1).
func (s *Server) Accept(t Transport) *Session {
	s.mu.Lock()
	if !s.readyLocked() {
		s.mu.Unlock()
		s.logLimited("conn", "provd: connection refused (not ready) %s", t.Kind())
		t.Close()
		return nil
	}
	var evict *Session
	if len(s.sessions) >= Slots {
		for _, ss := range s.sessions {
			if ss.evictable() && (evict == nil || ss.started.Before(evict.started)) {
				evict = ss
			}
		}
		if evict == nil {
			s.mu.Unlock()
			s.logLimited("conn", "provd: connection refused (%d slots in use) %s", Slots, t.Kind())
			t.Close()
			return nil
		}
	}
	ss := newSession(s, t)
	s.sessions = append(s.sessions, ss)
	s.mu.Unlock()
	if evict != nil {
		s.logLimited("conn", "provd: evicted the oldest unauthenticated session for a new connection")
		evict.Kill("evicted")
	}
	s.logLimited("conn", "provd: connection %s", t.Kind())
	go ss.run()
	return ss
}

func (s *Server) remove(ss *Session) {
	s.mu.Lock()
	for i, x := range s.sessions {
		if x == ss {
			s.sessions = append(s.sessions[:i], s.sessions[i+1:]...)
			break
		}
	}
	s.mu.Unlock()
	s.notify()
}

// Sessions is the number of open connections (the BLE side withdraws the advertisement while > 0).
func (s *Server) Sessions() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.sessions)
}

// killOthers: after a successful claim / replay every other session goes (incl. ones on the fake path)
func (s *Server) killOthers(keep *Session) {
	s.mu.Lock()
	var k []*Session
	for _, ss := range s.sessions {
		if ss != keep {
			k = append(k, ss)
		}
	}
	s.mu.Unlock()
	for _, ss := range k {
		ss.Kill("claimed")
	}
}
