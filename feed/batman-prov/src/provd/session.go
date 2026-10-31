package provd

import (
	"bytes"
	"errors"
	"sync"
	"time"

	"github.com/flynn/noise"

	"batman-prov/cbor"
	"batman-prov/proto"
)

// Transport is one connection: a BLE link (RX AcquireWrite fd / TX AcquireNotify fd) or a prov_test frame socket.
// ReadFrame returns one inbound frame (or a sock control packet); WriteFrame sends one outbound frame.
type Transport interface {
	ReadFrame() ([]byte, error)
	WriteFrame([]byte) error
	FrameLimit() int
	Close()
	Kind() string // "ble" | "sock"
}

// Role of a session (219 §3.5).
type Role int

const (
	RoleNone      Role = iota // handshake not complete
	RoleAnon                  // NX on an unclaimed / legacy node
	RoleCandidate             // psk_owner: info, auth/owner
	RoleOwner
	RoleMember    // psk_member
	RoleReacquire // psk_replay: info, claim/begin, op/nonce, claim/replay
)

// protocol error codes (219 §5.2)
const (
	EVersion        = 1
	EUnknownType    = 2
	EForbidden      = 3
	EBadObject      = 4
	EStaleVersion   = 5
	EUnsupported    = 6
	EBusy           = 7
	EClaimFailed    = 9
	EStorage        = 10
	ERejected       = 11
	ERate           = 12
	ELockIncomplete = 13
)

// sock control packets (h23 §4.8.2): only before the handshake completes
const (
	CtlReadCtrl   = 0xC0
	CtlReadStatus = 0xC1
	CtlError      = 0xC2 // reply: 0xC2 ‖ ATT error code (0x0E: not fresh)
)

var knownTypes = map[string]bool{"info": true, "claim/begin": true, "claim/finish": true, "auth/owner": true,
	"owner/add": true, "owner/remove": true, "settings/get": true, "settings/set": true, "network/join": true,
	"network/update": true, "network/leave": true, "status": true, "peers/challenge": true, "diag/summary": true,
	"diag/bundle": true, "update/check": true, "update/prepare": true, "update/apply": true, "update/status": true,
	"bulk/open": true, "bulk/close": true, "reset": true, "claim/replay": true, "op/nonce": true, "ssh_keys/set": true,
	"root_password/reset": true}

// P3 types: E_UNSUPPORTED{capability: <type>} (254-p2-impl §4.3)
var p3Types = map[string]bool{"owner/add": true, "owner/remove": true, "settings/get": true, "settings/set": true,
	"status": true, "peers/challenge": true, "diag/summary": true, "diag/bundle": true, "update/check": true,
	"update/prepare": true, "update/apply": true, "update/status": true, "bulk/open": true, "bulk/close": true}

// types whose response carries a secret: an idempotency key is E_FORBIDDEN (219 §4.2)
var secretTypes = map[string]bool{"claim/finish": true, "claim/replay": true, "root_password/reset": true,
	"owner/add": true, "bulk/open": true}

var allowed = map[Role]map[string]bool{
	RoleAnon:      {"info": true, "claim/begin": true, "claim/finish": true},
	RoleCandidate: {"info": true, "auth/owner": true},
	RoleOwner: {"info": true, "op/nonce": true, "network/join": true, "network/update": true, "network/leave": true,
		"ssh_keys/set": true, "root_password/reset": true},
	RoleMember:    {"info": true, "network/update": true},
	RoleReacquire: {"info": true, "claim/begin": true, "op/nonce": true, "claim/replay": true},
}

// owner-op verbs forwarded as the whole envelope: type -> helper verb
var forward = map[string]string{"network/join": "net.apply", "network/update": "net.apply",
	"network/leave": "network.leave", "ssh_keys/set": "ssh_keys.set", "root_password/reset": "root_password.reset",
	"claim/replay": "claim.replay"}

// MaxChunks / MaxReassembled: stage 1 limits of a chunked request (helper MaxRequest 65536 minus its wrapping).
const (
	MaxChunks      = 8
	MaxReassembled = 65400
	maxPlain       = MaxMsg - 16
)

var errKill = errors.New("provd: session killed")

// Session is one connection.
type Session struct {
	srv     *Server
	t       Transport
	started time.Time

	mu         sync.Mutex
	role       Role
	psk        []byte // the credential that opened the handshake (revocation compares by value)
	ownerKID   []byte
	h          []byte
	recv, send *noise.CipherState
	handshake  bool // msg1 seen, not complete (real or fake path)
	fake       bool
	lastID     uint64
	haveID     bool
	nonceNode  []byte
	nonceHelp  []byte
	nonceAt    time.Time
	beginPub   []byte
	fails      int
	msgs       uint64
	inflight   bool // a request is at the helper: no idle timeout
	lastActive time.Time
	killed     bool
	why        string
	closeAfter string // disconnect once the current response is sent (3rd claim / auth failure)
	done       chan struct{}
	// chunk reassembly
	chID    uint64
	chN     uint64
	chTotal uint64
	chType  string
	chIdem  []byte
	chBuf   []byte
	chOn    bool
}

func newSession(s *Server, t Transport) *Session {
	now := time.Now()
	return &Session{srv: s, t: t, started: now, lastActive: now, done: make(chan struct{})}
}

// Role reports the session's role.
func (ss *Session) Role() Role { ss.mu.Lock(); defer ss.mu.Unlock(); return ss.role }

// Done is closed when the session ended.
func (ss *Session) Done() <-chan struct{} { return ss.done }

// evictable: an unauthenticated / candidate session past its handshake (called with srv.mu held; locks ss.mu)
func (ss *Session) evictable() bool {
	ss.mu.Lock()
	defer ss.mu.Unlock()
	if ss.killed {
		return false
	}
	if ss.handshake || ss.fake { // mid-handshake (incl. the fake path's 10 s) is never evicted
		return false
	}
	if ss.role == RoleNone {
		return time.Since(ss.started) >= HandshakeMax
	}
	return ss.role == RoleAnon || ss.role == RoleCandidate || ss.role == RoleReacquire
}

// Kill disconnects (any goroutine).
func (ss *Session) Kill(why string) {
	ss.mu.Lock()
	if ss.killed {
		ss.mu.Unlock()
		return
	}
	ss.killed, ss.why = true, why
	ss.mu.Unlock()
	ss.t.Close()
}

func (ss *Session) dropNonce() {
	ss.mu.Lock()
	ss.nonceNode, ss.nonceHelp, ss.beginPub = nil, nil, nil
	ss.mu.Unlock()
}

func (ss *Session) logf(f string, a ...any) { ss.srv.logf(f, a...) }

type inbound struct {
	msg []byte
	ctl byte
	err error
}

// run: one reader goroutine (frames -> messages) and this worker (handshake, envelopes, timeouts).
func (ss *Session) run() {
	defer close(ss.done)
	defer ss.srv.remove(ss)
	defer ss.t.Close()
	in := make(chan inbound, 4)
	go func() {
		var r Reassembler
		for {
			f, err := ss.t.ReadFrame()
			if err != nil {
				in <- inbound{err: err}
				return
			}
			if ss.t.Kind() == "sock" && len(f) == 1 && (f[0] == CtlReadCtrl || f[0] == CtlReadStatus) {
				in <- inbound{ctl: f[0]}
				continue
			}
			m, done, err := r.Push(f)
			if err != nil {
				in <- inbound{err: err}
				return
			}
			if done {
				in <- inbound{msg: m}
			}
		}
	}()
	tick := time.NewTicker(500 * time.Millisecond)
	defer tick.Stop()
	for {
		select {
		case x := <-in:
			if x.err != nil {
				return
			}
			if x.ctl != 0 {
				if !ss.control(x.ctl) {
					return
				}
				continue
			}
			if err := ss.onMessage(x.msg); err != nil {
				if err != errKill {
					ss.logLimited("provd: session ended: %v", err)
				}
				return
			}
		case <-tick.C:
			if ss.expired() {
				return
			}
		}
		ss.mu.Lock()
		k := ss.killed
		ss.mu.Unlock()
		if k {
			return
		}
	}
}

func (ss *Session) logLimited(f string, a ...any) { ss.srv.logLimited("session", f, a...) }

// control answers a sock control packet (CTRL / STATUS before the handshake; afterwards it aborts).
func (ss *Session) control(c byte) bool {
	ss.mu.Lock()
	post := ss.recv != nil || ss.handshake || ss.fake
	ss.mu.Unlock()
	if post {
		return false
	}
	switch c {
	case CtlReadCtrl:
		return ss.t.WriteFrame(append([]byte{CtlReadCtrl}, Ctrl()...)) == nil
	default:
		b, ok := ss.srv.Status()
		if !ok {
			return ss.t.WriteFrame([]byte{CtlError, 0x0E}) == nil
		}
		return ss.t.WriteFrame(append([]byte{CtlReadStatus}, b...)) == nil
	}
}

func (ss *Session) expired() bool {
	ss.mu.Lock()
	defer ss.mu.Unlock()
	now := time.Now()
	if ss.recv == nil { // handshake (or the fake path) not done: 10 s from the connection
		return now.Sub(ss.started) >= HandshakeMax
	}
	if ss.inflight {
		return false
	}
	idle := IdleAnon
	if ss.role == RoleOwner || ss.role == RoleMember {
		idle = IdleAuthed
	}
	return now.Sub(ss.lastActive) >= idle
}

func (ss *Session) sendMsg(b []byte) error {
	for _, f := range Split(b, ss.t.FrameLimit()) {
		if err := ss.t.WriteFrame(f); err != nil {
			return err
		}
	}
	return nil
}

func (ss *Session) onMessage(m []byte) error {
	ss.mu.Lock()
	transport := ss.recv != nil
	fake := ss.fake
	ss.mu.Unlock()
	if fake {
		return errors.New("message on the fake path")
	}
	if !transport {
		return ss.onMsg1(m)
	}
	ss.mu.Lock()
	pt, err := ss.recv.Decrypt(nil, nil, m)
	ss.msgs++
	n := ss.msgs
	ss.lastActive = time.Now()
	ss.mu.Unlock()
	if err != nil {
		return errors.New("AEAD failure")
	}
	if n >= 1<<20 {
		return errors.New("2^20 messages: re-handshake")
	}
	resp, err := ss.onEnvelope(pt)
	if err != nil {
		return err
	}
	if resp == nil { // a chunk that did not complete the request
		return nil
	}
	if err := ss.reply(resp); err != nil {
		return err
	}
	ss.mu.Lock()
	why := ss.closeAfter
	ss.mu.Unlock()
	if why != "" {
		ss.logLimited("provd: disconnect after the response: %s", why)
		return errKill
	}
	return nil
}

func (ss *Session) markClose(why string) {
	ss.mu.Lock()
	ss.closeAfter = why
	ss.mu.Unlock()
}

// reply encrypts a response envelope, chunking a body larger than max_msg − 16 (§5.1).
func (ss *Session) reply(env cbor.Map) error {
	b, err := cbor.Encode(env)
	if err != nil {
		return err
	}
	if len(b) <= maxPlain {
		return ss.sendEnc(b)
	}
	idv, _ := env.Get(1)
	bodyv, _ := env.Get(3)
	body, err := cbor.Encode(bodyv)
	if err != nil {
		return err
	}
	per := maxPlain - 64
	total := (len(body) + per - 1) / per
	for i := 0; i < total; i++ {
		end := min((i+1)*per, len(body))
		c, _ := cbor.Encode(cbor.M(1, idv, 4, uint64(0), 3, body[i*per:end], 6, cbor.M(1, uint64(i+1), 2, uint64(total))))
		if err := ss.sendEnc(c); err != nil {
			return err
		}
	}
	return nil
}

func (ss *Session) sendEnc(pt []byte) error {
	ss.mu.Lock()
	ct, err := ss.send.Encrypt(nil, nil, pt)
	ss.msgs++
	ss.lastActive = time.Now()
	ss.mu.Unlock()
	if err != nil {
		return err
	}
	return ss.sendMsg(ct)
}

func (ss *Session) onMsg1(m []byte) error {
	if !ss.srv.handshakeAllowed() {
		return errors.New("global handshake rate (20/min)")
	}
	prologue, psks, cert, ok := ss.srv.handshakeParams()
	if !ok {
		return errors.New("not ready")
	}
	hs, err := Respond(m, ss.srv.static, prologue, psks, cert, nil)
	if err != nil {
		return err
	}
	if hs.Fake {
		ss.mu.Lock()
		ss.fake = true
		ss.mu.Unlock()
		if d := ss.srv.cfg.Test.FastFakeDelayMS; d > 0 {
			time.Sleep(time.Duration(d) * time.Millisecond)
		}
		// same length as a real msg2, then wait for the handshake timeout (the worker's ticker ends it)
		return ss.sendMsg(hs.Msg2)
	}
	role := RoleAnon
	var cred []byte
	if psks != nil {
		role, cred = roleOfPSK(hs.PSK), psks[hs.PSK]
		if !ss.srv.realPSK(hs.PSK, cred) { // a random pad cannot be hit, but never trust it
			return errors.New("padding PSK")
		}
	}
	ss.mu.Lock()
	ss.role, ss.psk, ss.h, ss.recv, ss.send, ss.lastActive = role, cred, hs.H, hs.Recv, hs.Send, time.Now()
	ss.mu.Unlock()
	return ss.sendMsg(hs.Msg2)
}

func errEnv(id uint64, code int, detail cbor.Map) cbor.Map {
	if detail == nil {
		detail = cbor.M()
	}
	return cbor.M(1, id, 4, uint64(code), 5, detail)
}

func okEnv(id uint64, body cbor.Map) cbor.Map {
	if body == nil {
		body = cbor.M()
	}
	return cbor.M(1, id, 4, uint64(0), 3, body)
}

// onEnvelope decodes one request envelope (strict deterministic CBOR), reassembles chunks, checks the id, and routes.
// A malformed envelope / id replay / chunk violation ends the session.
func (ss *Session) onEnvelope(pt []byte) (cbor.Map, error) {
	x, err := cbor.Decode(pt)
	env, ok := x.(cbor.Map)
	if err != nil || !ok {
		return nil, errors.New("envelope not deterministic CBOR")
	}
	for _, e := range env {
		k, ok := e.K.(uint64)
		if !ok || !(k <= 3 || k == 6 || k == 7) {
			return nil, errors.New("envelope key")
		}
	}
	idv, _ := env.Get(1)
	id, ok := idv.(uint64)
	if !ok {
		return nil, errors.New("envelope id")
	}
	tv, _ := env.Get(2)
	typ, _ := tv.(string)
	pv, _ := env.Get(0)
	ver, _ := pv.([]any)
	if len(ver) != 2 || typ == "" {
		return nil, errors.New("envelope version / type")
	}
	var idem []byte
	if iv, ok := env.Get(7); ok {
		if idem, ok = iv.([]byte); !ok || len(idem) != 16 {
			return nil, errors.New("idem key")
		}
	}
	bodyv, _ := env.Get(3)
	partv, isChunk := env.Get(6)
	var body cbor.Map
	if isChunk {
		complete, b, err := ss.chunk(id, typ, idem, bodyv, partv)
		if err != nil {
			return nil, err
		}
		if !complete {
			return nil, nil
		}
		y, err := cbor.Decode(b)
		if body, ok = y.(cbor.Map); err != nil || !ok {
			return nil, errors.New("reassembled body")
		}
	} else {
		ss.mu.Lock()
		on := ss.chOn
		ss.mu.Unlock()
		if on {
			return nil, errors.New("whole message inside a chunked one")
		}
		if body, ok = bodyv.(cbor.Map); !ok {
			return nil, errors.New("body")
		}
	}
	ss.mu.Lock()
	if ss.haveID && id <= ss.lastID {
		ss.mu.Unlock()
		return nil, errors.New("id repeated / backwards")
	}
	ss.haveID, ss.lastID = true, id
	ss.mu.Unlock()
	// the envelope the helper decodes itself: deterministic {0, 1, 2, 3, (7)} (a chunked one is rebuilt whole)
	whole := cbor.M(0, pv, 1, id, 2, typ, 3, body)
	if idem != nil {
		whole = append(whole, cbor.Entry{K: uint64(7), V: idem})
	}
	raw, err := cbor.Encode(whole)
	if err != nil {
		return nil, err
	}
	if mj, _ := ver[0].(uint64); mj != 1 {
		return errEnv(id, EVersion, nil), nil
	}
	return ss.route(id, typ, body, idem, raw), nil
}

func (ss *Session) chunk(id uint64, typ string, idem []byte, bodyv, partv any) (bool, []byte, error) {
	part, ok := partv.(cbor.Map)
	slice, ok2 := bodyv.([]byte)
	if !ok || !ok2 {
		return false, nil, errors.New("chunk shape")
	}
	nv, _ := part.Get(1)
	tv, _ := part.Get(2)
	n, _ := nv.(uint64)
	total, _ := tv.(uint64)
	if n == 0 || total == 0 || total > MaxChunks || n > total {
		return false, nil, errors.New("chunk part")
	}
	ss.mu.Lock()
	defer ss.mu.Unlock()
	if !ss.chOn {
		if n != 1 {
			return false, nil, errors.New("chunk does not start at 1")
		}
		ss.chOn, ss.chID, ss.chN, ss.chTotal, ss.chType, ss.chIdem, ss.chBuf = true, id, 0, total, typ, idem, nil
	}
	if id != ss.chID || typ != ss.chType || total != ss.chTotal || n != ss.chN+1 || !bytes.Equal(idem, ss.chIdem) {
		return false, nil, errors.New("chunk out of order / mixed")
	}
	ss.chN = n
	ss.chBuf = append(ss.chBuf, slice...)
	if len(ss.chBuf) > MaxReassembled {
		return false, nil, errors.New("chunked request too large")
	}
	if n < total {
		return false, nil, nil
	}
	b := ss.chBuf
	ss.chOn, ss.chBuf = false, nil
	return true, b, nil
}

// failOnce counts a claim / auth failure; 3 per connection -> disconnect (NO_BRUTE_LIMIT off in prov_test).
func (ss *Session) failOnce() bool {
	ss.mu.Lock()
	ss.fails++
	f := ss.fails
	ss.mu.Unlock()
	return f >= ClaimFails && !ss.srv.cfg.Test.NoBruteLimit
}

// mapHelper is THE error-code table (254-p2-impl §4.3): helper code -> protocol code + detail.
func (ss *Session) mapHelper(id uint64, typ string, code int) cbor.Map {
	switch code {
	case hEForbidden, hEBadObject, hEStaleVersion, hEBusy, hEStorage, hERate:
		return errEnv(id, code, nil)
	case hEUnsupported:
		return errEnv(id, EUnsupported, cbor.M(1, typ))
	case hEApply, hEState:
		return errEnv(id, ERejected, nil)
	case hELockIncomplete:
		return errEnv(id, ELockIncomplete, nil)
	case hESchema:
		ss.logf("CRIT provd: the helper rejected a request schema (%s) — a provd bug", typ)
		return errEnv(id, ERejected, nil)
	}
	return errEnv(id, ERejected, nil)
}

func busyUnknown(id uint64) cbor.Map {
	return errEnv(id, EBusy, cbor.M(3, "outcome unknown — re-read info"))
}

// ops runs one state-changing / nonce request for this session: ErrBusy -> E_BUSY; a timeout -> E_BUSY "outcome
// unknown"; a lost connection -> E_BUSY (non-idempotent: not re-sent).
func (ss *Session) ops(id uint64, verb string, args cbor.Map) (Reply, cbor.Map) {
	ss.mu.Lock()
	ss.inflight = true
	ss.mu.Unlock()
	r, err := ss.srv.opsCall(verb, args, HelperWait)
	ss.mu.Lock()
	ss.inflight, ss.lastActive = false, time.Now()
	ss.mu.Unlock()
	switch err {
	case nil:
		return r, nil
	case ErrTimeout:
		ss.logf("provd: %s unanswered after %s — outcome unknown", verb, HelperWait)
		return r, busyUnknown(id)
	default:
		if err == ErrGone {
			ss.logf("provd: helper connection lost during %s", verb)
		}
		return r, errEnv(id, EBusy, nil)
	}
}

func (ss *Session) route(id uint64, typ string, body cbor.Map, idem, raw []byte) cbor.Map {
	if !knownTypes[typ] {
		return errEnv(id, EUnknownType, nil)
	}
	if idem != nil {
		if secretTypes[typ] {
			return errEnv(id, EForbidden, nil)
		}
		return errEnv(id, EUnsupported, cbor.M(1, "idem"))
	}
	if typ == "reset" {
		return errEnv(id, EUnsupported, cbor.M(1, "reset", 2, uint64(9)))
	}
	if p3Types[typ] {
		return errEnv(id, EUnsupported, cbor.M(1, typ))
	}
	ss.mu.Lock()
	role, h := ss.role, ss.h
	ss.mu.Unlock()
	if !allowed[role][typ] {
		return errEnv(id, EForbidden, nil)
	}
	switch typ {
	case "info":
		return okEnv(id, ss.srv.info(role))
	case "claim/begin":
		return ss.claimBegin(id, h, body)
	case "op/nonce":
		return ss.opNonce(id, h, role)
	case "claim/finish":
		return ss.claimFinish(id, h, body)
	case "auth/owner":
		return ss.authOwner(id, h, body)
	}
	verb := forward[typ]
	r, e := ss.ops(id, verb, cbor.M(1, h, 2, raw))
	if typ == "claim/replay" {
		ss.dropNonce() // the helper consumed the pair, whatever the answer (F-P33)
	}
	ss.srv.invalidate()
	if e != nil {
		return e
	}
	if r.Code != hOK && !(typ == "claim/replay" && r.Code == hELockIncomplete) {
		if typ == "claim/replay" && r.Code == hEForbidden && ss.failOnce() {
			ss.markClose("claim failures")
		}
		return ss.mapHelper(id, typ, r.Code)
	}
	switch typ {
	case "claim/replay":
		ss.becomeOwner(nil)
		if r.Code == hELockIncomplete {
			return errEnv(id, ELockIncomplete, nil)
		}
		return okEnv(id, r.Body)
	case "network/join":
		return okEnv(id, cbor.M(1, uint64(0))) // joined
	case "network/update":
		v, _ := r.Body.Get(1)
		return okEnv(id, cbor.M(1, v))
	case "root_password/reset":
		return okEnv(id, r.Body)
	}
	return okEnv(id, nil)
}

// becomeOwner after claim/finish (pub = the begin owner_pub) or claim/replay (pub nil = the single stored owner).
func (ss *Session) becomeOwner(pub []byte) {
	if pub == nil {
		ss.srv.mu.Lock()
		if len(ss.srv.c.owners) == 1 {
			pub = ss.srv.c.owners[0]
		}
		ss.srv.mu.Unlock()
	}
	ss.mu.Lock()
	ss.role = RoleOwner
	if pub != nil {
		ss.ownerKID = ownerKID(pub)
	}
	ss.mu.Unlock()
	ss.srv.killOthers(ss)
}

func (ss *Session) claimBegin(id uint64, h []byte, body cbor.Map) cbor.Map {
	pv, _ := body.Get(1)
	pub, ok := pv.([]byte)
	if !ok || len(pub) != 65 {
		return errEnv(id, EBadObject, nil)
	}
	r, e := ss.ops(id, "nonce", cbor.M(1, h))
	if e != nil {
		return e
	}
	if r.Code != hOK {
		return ss.mapHelper(id, "claim/begin", r.Code)
	}
	nv, _ := r.Body.Get(1)
	hv, _ := r.Body.Get(2)
	nn, _ := nv.([]byte)
	nh, _ := hv.([]byte)
	ss.mu.Lock()
	ss.nonceNode, ss.nonceHelp, ss.nonceAt, ss.beginPub = nn, nh, time.Now(), pub
	ss.mu.Unlock()
	return okEnv(id, cbor.M(1, nn))
}

// op/nonce: the owner gets a fresh nonce(h); the re-acquire role gets the nonce_helper of the pair its claim/begin
// fetched (one pair serves claim/replay's CheckMac and owner-op, F-P9) — no pair / older than 55 s -> E_FORBIDDEN,
// not counted as a failure; the app starts again with claim/begin.
func (ss *Session) opNonce(id uint64, h []byte, role Role) cbor.Map {
	if role == RoleReacquire {
		ss.mu.Lock()
		nh, at := ss.nonceHelp, ss.nonceAt
		ss.mu.Unlock()
		if nh == nil || time.Since(at) > NonceLife {
			return errEnv(id, EForbidden, nil)
		}
		return okEnv(id, cbor.M(1, nh))
	}
	r, e := ss.ops(id, "nonce", cbor.M(1, h))
	if e != nil {
		return e
	}
	if r.Code != hOK {
		return ss.mapHelper(id, "op/nonce", r.Code)
	}
	hv, _ := r.Body.Get(2)
	return okEnv(id, cbor.M(1, hv))
}

func (ss *Session) claimFinish(id uint64, h []byte, body cbor.Map) cbor.Map {
	ss.mu.Lock()
	pub, nn, at := ss.beginPub, ss.nonceNode, ss.nonceAt
	ss.mu.Unlock()
	if pub == nil || nn == nil || time.Since(at) > NonceLife {
		return errEnv(id, EForbidden, nil)
	}
	rv, _ := body.Get(1)
	ev, _ := body.Get(2)
	sv, _ := body.Get(3)
	resp, ok1 := rv.([]byte)
	enc, ok2 := ev.([]byte)
	sig, ok3 := sv.([]byte)
	if !ok1 || !ok2 || !ok3 || len(resp) != 32 || len(enc) != 65 || len(sig) != 64 {
		return errEnv(id, EBadObject, nil)
	}
	// one claim at a time across sessions (L24) = ops' single request in flight: a second claim.verify gets E_BUSY
	r, e := ss.ops(id, "claim.verify", cbor.M(1, h, 2, resp, 3, pub, 4, enc, 5, sig))
	ss.dropNonce()
	ss.srv.invalidate()
	if e != nil {
		return e
	}
	switch r.Code {
	case hOK:
		ss.becomeOwner(pub)
		return okEnv(id, r.Body)
	case hELockIncomplete:
		ss.becomeOwner(pub)
		return errEnv(id, ELockIncomplete, nil)
	case hEForbidden:
		if ss.failOnce() {
			ss.markClose("claim failures")
		}
		return errEnv(id, EClaimFailed, nil)
	case hEUnsupported:
		// F-P38: under the mutex claim.verify answers 6 only for no-ssh-key — unless the record itself was unreadable,
		// which the ctl poll would also be seeing (then no reason is claimed)
		if ss.srv.statusRecent() {
			return errEnv(id, EUnsupported, cbor.M(1, "claim", 2, uint64(10)))
		}
		return errEnv(id, EUnsupported, cbor.M(1, "claim"))
	}
	return ss.mapHelper(id, "claim/finish", r.Code)
}

// auth/owner: ES256_owner("batman-owner-auth-v1" ‖ h ‖ owner_key_id) against the info.owners keys (provd's own
// check: a role upgrade only; every change is still an owner-op the helper verifies). Stage 1 answers {} (B16 #255).
func (ss *Session) authOwner(id uint64, h []byte, body cbor.Map) cbor.Map {
	kv, _ := body.Get(1)
	sv, _ := body.Get(2)
	kid, ok1 := kv.([]byte)
	sig, ok2 := sv.([]byte)
	if !ok1 || !ok2 || len(kid) != 32 || len(sig) != 64 {
		return errEnv(id, EBadObject, nil)
	}
	ss.srv.mu.Lock()
	owners := ss.srv.c.owners
	ss.srv.mu.Unlock()
	in := append(append([]byte(proto.LabelOwnerAuth), h...), kid...)
	for _, o := range owners {
		if bytes.Equal(ownerKID(o), kid) && proto.VerifyES256(o, in, sig) {
			ss.mu.Lock()
			ss.role, ss.ownerKID = RoleOwner, kid
			ss.mu.Unlock()
			return okEnv(id, nil)
		}
	}
	if ss.failOnce() {
		ss.markClose("auth failures")
	}
	return errEnv(id, EForbidden, nil)
}
