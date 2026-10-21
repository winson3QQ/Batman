// Package node implements the helper's verbs (docs/design/254-stage1-impl.md §4.1, §4.4, §6.1–§6.2; protocol
// 219-protocol.md v0.7). The caller (the socket server) has already checked SO_PEERCRED and serialises requests.
//
// Helper socket messages (internal to provd <-> helper, 254-p1-impl.md §2.1): one SEQPACKET = one CBOR map.
//
//	request  = { 1: verb (tstr), 2: req_id (uint), 3: args (map) }
//	response = { 1: req_id, 2: code (0 = ok), 3: result (map) }
//
// Owner-op verbs take the ORIGINAL request envelope bytes (args {1: h, 2: envelope}); the helper decodes them
// strictly and acts only on what it decoded itself (§4.1). Codes follow 219-protocol §5.2 where one exists.
package node

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"fmt"
	"regexp"
	"strings"
	"sync"
	"time"

	"batman-prov/cbor"
	"batman-prov/cose"
	"batman-prov/keystore"
	"batman-prov/proto"
	"batman-prov/provstore"
)

// Codes (219-protocol §5.2 numbering; 20+ are helper-internal).
const (
	OK            = 0
	EForbidden    = 3
	EBadObject    = 4
	EStaleVersion = 5
	EUnsupported  = 6
	EBusy         = 7
	EStorage      = 10 // E_PERSIST: p5 not written
	ERate         = 12
	ESchema       = 20
	EApply        = 21
)

// Error is a coded failure; Reason is for the log only.
type Error struct {
	Code   int
	Reason string
}

func (e *Error) Error() string { return fmt.Sprintf("code %d: %s", e.Code, e.Reason) }
func fail(code int, why string, a ...any) *Error {
	return &Error{Code: code, Reason: fmt.Sprintf(why, a...)}
}

// Sys is every side effect outside the helper's own files; the real one lives in cmd/, tests fake it.
type Sys interface {
	IsTrial() bool                                            // batman-slot is-trial rc 0
	Persist(record, meta, identity, txn string) (int, string) // batman-config-save --prov-only
	GetP5(dir string) (int, string)                           // batman-config-save --prov-get
	Save() (int, string)                                      // batman-config-save --save (after a lock/shadow change)
	SetKeyNoPersist(meshKey, meshID string, channel string) error
	CurrentWireless() (meshKey, meshID, channel string, err error) // the values a .txn must be able to restore
	ApplyLock(rootHash string) error                               // PasswordAuth=off, RootPasswordAuth=off, ttylogin=1, shadow root hash, lock-status
	CryptPassword(pw string) (string, error)
	AuthorizedKeys() ([]string, error)
	SetAuthorizedKeys(lines []string) error
	DevOpen() bool
	WriteTxnMarker(token string) error // $RUNDIR/prov-txn
	ClearTxnMarker()
	DiagBundle() ([]byte, error)
	RemoveMeshMarkers() error // p6 mesh-expected / mesh-joined (network/leave)
	Now() time.Time
}

// Node is the helper state of one boot.
type Node struct {
	mu      sync.Mutex
	P       provstore.Paths
	KS      *keystore.Keystore
	Sys     Sys
	BootID  []byte // 16 B, this helper's per-boot id (sig_static input)
	nonces  map[string]*nonce
	signLog []time.Time
	replayF []time.Time
	Log     func(string, ...any)
}

type nonce struct {
	h            []byte
	node, helper []byte
	exp          time.Time
	nodeUsed     bool
	helperUsed   bool
}

// New wires a node.
func New(p provstore.Paths, ks *keystore.Keystore, sys Sys, log func(string, ...any)) *Node {
	b := make([]byte, 16)
	rand.Read(b)
	return &Node{P: p, KS: ks, Sys: sys, BootID: b, nonces: map[string]*nonce{}, Log: log}
}

func rnd(n int) []byte { b := make([]byte, n); rand.Read(b); return b }

func bytesArg(m cbor.Map, k int, n int) ([]byte, *Error) {
	v, ok := m.Get(k)
	if !ok {
		return nil, fail(ESchema, "missing arg %d", k)
	}
	b, ok := v.([]byte)
	if !ok || (n > 0 && len(b) != n) {
		return nil, fail(ESchema, "arg %d: want %d bytes", k, n)
	}
	return b, nil
}

// onlyKeys rejects extra fields in helper args (the helper's own schema is closed).
func onlyKeys(m cbor.Map, keys ...uint64) *Error {
	allowed := map[uint64]bool{}
	for _, k := range keys {
		allowed[k] = true
	}
	for _, e := range m {
		k, ok := e.K.(uint64)
		if !ok || !allowed[k] {
			return fail(ESchema, "unexpected arg %v", e.K)
		}
	}
	return nil
}

// Handle dispatches one decoded request map and returns the response map.
func (n *Node) Handle(req cbor.Map) cbor.Map {
	n.mu.Lock()
	defer n.mu.Unlock()
	idAny, _ := req.Get(2)
	id, _ := idAny.(uint64)
	verbAny, _ := req.Get(1)
	verb, _ := verbAny.(string)
	argsAny, _ := req.Get(3)
	args, ok := argsAny.(cbor.Map)
	if len(req) != 3 || !ok || verb == "" {
		return cbor.M(1, id, 2, uint64(ESchema), 3, cbor.M())
	}
	res, err := n.dispatch(verb, args)
	if err != nil {
		n.Log("verb %s refused: code %d (%s)", verb, err.Code, err.Reason)
		return cbor.M(1, id, 2, uint64(err.Code), 3, cbor.M())
	}
	return cbor.M(1, id, 2, uint64(OK), 3, res)
}

var stateChanging = map[string]bool{"claim.verify": true, "claim.replay": true, "net.apply": true, "network.leave": true,
	"owner.add": true, "owner.remove": true, "settings.set": true, "root_password.reset": true, "ssh_keys.set": true}

func (n *Node) dispatch(verb string, a cbor.Map) (cbor.Map, *Error) {
	if stateChanging[verb] && n.Sys.IsTrial() {
		return nil, fail(EBusy, "trial slot (updating)")
	}
	rec, _, err := provstore.LoadOverlay(n.P)
	if err != nil || rec == nil {
		if verb != "info.cert" && verb != "info.ecdh_pub" && verb != "info.boot_id" && verb != "nonce" {
			return nil, fail(EUnsupported, "no usable provisioning record (%v)", err)
		}
	}
	switch verb {
	case "info.cert":
		if e := onlyKeys(a); e != nil {
			return nil, e
		}
		return cbor.M(1, n.KS.Cert(), 2, n.KS.SN()), nil
	case "info.ecdh_pub":
		if e := onlyKeys(a); e != nil {
			return nil, e
		}
		return cbor.M(1, n.KS.ECDHPub()), nil
	case "info.boot_id":
		if e := onlyKeys(a); e != nil {
			return nil, e
		}
		return cbor.M(1, n.BootID), nil
	case "info.counter":
		if e := onlyKeys(a); e != nil {
			return nil, e
		}
		return cbor.M(1, rec.ClaimedCounter), nil
	case "info.state":
		if e := onlyKeys(a); e != nil {
			return nil, e
		}
		return cbor.M(1, rec.State, 2, rec.Generation, 3, uint64(len(rec.Owners)), 4, rec.RadioManaged), nil
	case "nonce":
		return n.newNonce(a)
	case "sign.static", "sign.ecdh_proof", "sign.peer":
		return n.sign(verb, a)
	case "psks.get":
		if e := onlyKeys(a); e != nil {
			return nil, e
		}
		return n.psks(rec), nil
	case "claim.verify":
		return n.claimVerify(rec, a)
	case "claim.replay":
		return n.claimReplay(rec, a)
	case "net.apply", "network.leave", "owner.add", "owner.remove", "settings.set", "root_password.reset",
		"diag.bundle", "ssh_keys.set":
		return n.ownerOpVerb(verb, rec, a)
	}
	return nil, fail(ESchema, "unknown verb %q", verb) // incl. keystore.ecdh, persist, keystore.sign, any reset: none exist (§4.1)
}

// ---- nonces (one-time, 60 s, bound to h; <= 4 open per h, oldest dropped — 219 §8) ------------------------------

func (n *Node) newNonce(a cbor.Map) (cbor.Map, *Error) {
	if e := onlyKeys(a, 1); e != nil {
		return nil, e
	}
	h, e := bytesArg(a, 1, 32)
	if e != nil {
		return nil, e
	}
	now := n.Sys.Now()
	var same []*nonce
	for k, v := range n.nonces {
		if now.After(v.exp) {
			delete(n.nonces, k)
		} else if subtle.ConstantTimeCompare(v.h, h) == 1 {
			same = append(same, v)
		}
	}
	for len(same) >= 4 {
		oldest := same[0]
		for _, s := range same {
			if s.exp.Before(oldest.exp) {
				oldest = s
			}
		}
		delete(n.nonces, hex.EncodeToString(oldest.helper))
		same = same[:len(same)-1]
	}
	nn := &nonce{h: h, node: rnd(32), helper: rnd(32), exp: now.Add(60 * time.Second)}
	n.nonces[hex.EncodeToString(nn.helper)] = nn
	return cbor.M(1, nn.node, 2, nn.helper), nil
}

// takeNodeNonce returns the newest unused nonce_node issued for h (consumed: one claim attempt per nonce).
func (n *Node) takeNodeNonce(h []byte) []byte {
	now := n.Sys.Now()
	var best *nonce
	for _, v := range n.nonces {
		if !v.nodeUsed && now.Before(v.exp) && subtle.ConstantTimeCompare(v.h, h) == 1 && (best == nil || v.exp.After(best.exp)) {
			best = v
		}
	}
	if best == nil {
		return nil
	}
	best.nodeUsed = true
	return best.node
}

// takeHelperNonce consumes nonce_helper (ANY verification attempt consumes it, 219 §5.7); nil if not valid for h.
func (n *Node) takeHelperNonce(h, nonceHelper []byte) bool {
	k := hex.EncodeToString(nonceHelper)
	v, ok := n.nonces[k]
	if !ok {
		return false
	}
	valid := !v.helperUsed && n.Sys.Now().Before(v.exp) && subtle.ConstantTimeCompare(v.h, h) == 1
	v.helperUsed = true
	delete(n.nonces, k)
	return valid
}

// ---- signing (purpose fixed, content assembled here; 0.5/s per connection is the server's, 2/s global here) -------

func (n *Node) sign(verb string, a cbor.Map) (cbor.Map, *Error) {
	now := n.Sys.Now()
	var keep []time.Time
	for _, t := range n.signLog {
		if now.Sub(t) < time.Second {
			keep = append(keep, t)
		}
	}
	if len(keep) >= 2 {
		n.signLog = keep
		return nil, fail(ERate, "signing rate (2/s global)")
	}
	n.signLog = append(keep, now)
	switch verb {
	case "sign.static":
		if e := onlyKeys(a, 1); e != nil {
			return nil, e
		}
		sp, e := bytesArg(a, 1, 32)
		if e != nil {
			return nil, e
		}
		sig, err := n.KS.SignPurpose(keystore.PurposeStatic, sp, n.BootID)
		if err != nil {
			return nil, fail(ESchema, "%v", err)
		}
		return cbor.M(1, sig, 2, n.BootID), nil
	case "sign.ecdh_proof":
		if e := onlyKeys(a); e != nil {
			return nil, e
		}
		sig, err := n.KS.SignPurpose(keystore.PurposeECDH)
		if err != nil {
			return nil, fail(ESchema, "%v", err)
		}
		return cbor.M(1, sig), nil
	default: // sign.peer: nonce_app (peer), h; nonce_node is ours
		if e := onlyKeys(a, 1, 2); e != nil {
			return nil, e
		}
		na, e := bytesArg(a, 1, 32)
		if e != nil {
			return nil, e
		}
		h, e := bytesArg(a, 2, 32)
		if e != nil {
			return nil, e
		}
		nn := rnd(32)
		sig, err := n.KS.SignPurpose(keystore.PurposePeer, na, nn, h)
		if err != nil {
			return nil, fail(ESchema, "%v", err)
		}
		return cbor.M(1, nn, 2, sig), nil
	}
}

// ---- PSKs (HKDF outputs only; never owner_tag_key / net_root) ----------------------------------------------------

func (n *Node) psks(rec *provstore.Record) cbor.Map {
	dev := n.KS.DeviceID()
	owners := []any{}
	for _, o := range rec.Owners {
		owners = append(owners, proto.PskOwner(o.TagKey, dev))
	}
	var replay, advOwner, member, advMember any
	if len(rec.Owners) == 1 {
		if z, err := n.KS.ECDH(rec.Owners[0].EncPub); err == nil {
			replay = proto.PskReplay(z, dev)
		}
	}
	if rec.AdvOwnerKey != nil {
		advOwner = proto.AdvOwner(rec.AdvOwnerKey, dev)
	}
	if rec.Net != nil {
		if root := n.netRoot(rec); root != nil {
			member = proto.PskMember(root, rec.Net.NetID, uint32(rec.Net.Version))
			advMember = proto.AdvMember(root, rec.Net.NetID, uint32(rec.Net.Version))
		}
	}
	return cbor.M(1, owners, 2, member, 3, replay, 4, advOwner, 5, advMember)
}

// ---- claim (§6.1) --------------------------------------------------------------------------------------------------

func genPassword() string {
	const alpha = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789"
	b := rnd(24)
	out := make([]byte, 24)
	for i := range b {
		out[i] = alpha[int(b[i])%len(alpha)]
	}
	return string(out)
}

func (n *Node) claimVerify(rec *provstore.Record, a cbor.Map) (cbor.Map, *Error) {
	if e := onlyKeys(a, 1, 2, 3, 4, 5); e != nil {
		return nil, e
	}
	h, e := bytesArg(a, 1, 32)
	if e != nil {
		return nil, e
	}
	resp, e := bytesArg(a, 2, 32)
	if e != nil {
		return nil, e
	}
	ownerPub, e := bytesArg(a, 3, 65)
	if e != nil {
		return nil, e
	}
	encPub, e := bytesArg(a, 4, 65)
	if e != nil {
		return nil, e
	}
	sigEnc, e := bytesArg(a, 5, 64)
	if e != nil {
		return nil, e
	}
	if rec.State != provstore.Legacy && rec.State != provstore.Unclaimed {
		return nil, fail(EForbidden, "state %s cannot be claimed", rec.State)
	}
	nn := n.takeNodeNonce(h)
	if nn == nil {
		return nil, fail(EForbidden, "no nonce for this session")
	}
	// the node recomputes ClientChal from ITS nonce, ITS DAC and the owner_pub about to be stored (219 §5.4)
	if !n.KS.CheckMac(proto.ClientChal(nn, h, n.KS.Cert(), ownerPub), resp) {
		return nil, fail(EForbidden, "CheckMac")
	}
	if !proto.VerifyES256(ownerPub, append([]byte(proto.LabelOwnerEnc), encPub...), sigEnc) {
		return nil, fail(EForbidden, "sig_enc")
	}
	// legacy safety gate — only after CheckMac passed (219 §5.3)
	if rec.State == provstore.Legacy && !n.Sys.DevOpen() {
		keys, _ := n.Sys.AuthorizedKeys()
		if len(keys) == 0 {
			return nil, fail(EUnsupported, "no-ssh-key")
		}
	}
	tag, adv, pw := rnd(32), rnd(32), genPassword()
	next := *rec
	next.Generation = rec.Generation + 1
	next.State = provstore.Claimed
	next.RadioManaged = rec.State == provstore.Unclaimed // legacy claim keeps the operator's radio (§1.4)
	next.ClaimedCounter = rec.ClaimedCounter + 1
	next.Owners = []provstore.Owner{{Pub: ownerPub, EncPub: encPub, TagKey: tag}}
	next.AdvOwnerKey = adv
	if err := n.commit(&next, "claim"); err != nil {
		return nil, err
	}
	// §6.1 step 4: lock (shadow hash + dropbear + ttylogin) then --save
	hash, err := n.Sys.CryptPassword(pw)
	if err == nil {
		err = n.Sys.ApplyLock(hash)
	}
	if err != nil {
		n.Log("claim committed but the lock step failed: %v (the next boot completes it)", err)
	} else if rc, out := n.Sys.Save(); rc != 0 {
		n.Log("claim: --save rc=%d (%s) — p5 shadow-root not updated; the next boot's --check reports it", rc, strings.TrimSpace(out))
	}
	return cbor.M(1, tag, 2, adv, 3, pw), nil
}

func (n *Node) claimReplay(rec *provstore.Record, a cbor.Map) (cbor.Map, *Error) {
	if e := onlyKeys(a, 1, 2); e != nil {
		return nil, e
	}
	h, e := bytesArg(a, 1, 32)
	if e != nil {
		return nil, e
	}
	envRaw, e := bytesArg(a, 2, 0)
	if e != nil {
		return nil, e
	}
	now := n.Sys.Now()
	var recent []time.Time
	for _, t := range n.replayF {
		if now.Sub(t) < time.Hour {
			recent = append(recent, t)
		}
	}
	n.replayF = recent
	if len(recent) >= 10 {
		return nil, fail(ERate, "claim.replay failures (10/h)")
	}
	failOnce := func(code int, why string) (cbor.Map, *Error) {
		n.replayF = append(n.replayF, now)
		return nil, fail(code, "%s", why)
	}
	if (rec.State != provstore.Claimed && rec.State != provstore.Member) || len(rec.Owners) != 1 {
		return failOnce(EForbidden, "replay needs exactly one owner")
	}
	typ, body, e := decodeEnvelope(envRaw)
	if e != nil {
		return failOnce(e.Code, e.Reason)
	}
	if typ != "claim/replay" {
		return failOnce(EForbidden, "envelope type")
	}
	resp, e := bytesArg(body, 1, 32)
	if e != nil {
		return failOnce(e.Code, e.Reason)
	}
	owner := rec.Owners[0]
	if e := n.verifyOwnerOp(h, typ, body, [][]byte{owner.Pub}); e != nil {
		return failOnce(e.Code, e.Reason)
	}
	nn := n.takeNodeNonce(h)
	if nn == nil || !n.KS.CheckMac(proto.ClientChal(nn, h, n.KS.Cert(), owner.Pub), resp) {
		return failOnce(EForbidden, "CheckMac")
	}
	pw := genPassword()
	if hash, err := n.Sys.CryptPassword(pw); err != nil || n.Sys.ApplyLock(hash) != nil {
		return nil, fail(EApply, "root password")
	}
	if rc, _ := n.Sys.Save(); rc != 0 {
		n.Log("claim.replay: --save rc=%d", rc)
	}
	return cbor.M(1, owner.TagKey, 2, rec.AdvOwnerKey, 3, pw), nil
}

// ---- owner-op (219 §5.7) ---------------------------------------------------------------------------------------------

// decodeEnvelope strictly decodes a request envelope and returns its type and body.
func decodeEnvelope(raw []byte) (string, cbor.Map, *Error) {
	if len(raw) > 65536 {
		return "", nil, fail(ESchema, "envelope > 64 KiB")
	}
	x, err := cbor.Decode(raw)
	if err != nil {
		return "", nil, fail(ESchema, "envelope not strict deterministic CBOR: %v", err)
	}
	m, ok := x.(cbor.Map)
	if !ok {
		return "", nil, fail(ESchema, "envelope not a map")
	}
	t, _ := m.Get(2)
	typ, ok := t.(string)
	if !ok {
		return "", nil, fail(ESchema, "envelope type")
	}
	b, _ := m.Get(3)
	body, ok := b.(cbor.Map)
	if !ok {
		return "", nil, fail(ESchema, "envelope body")
	}
	return typ, body, nil
}

// verifyOwnerOp: owner-op at body key 31, verb == envelope type, signature by one of owners over the input the
// helper assembles from h, its nonce_helper and the args_hash it computes from the decoded body.
func (n *Node) verifyOwnerOp(h []byte, typ string, body cbor.Map, owners [][]byte) *Error {
	opAny, ok := body.Get(31)
	if !ok {
		return fail(EForbidden, "no owner-op")
	}
	op, ok := opAny.(cbor.Map)
	if !ok || len(op) != 2 {
		return fail(EForbidden, "owner-op shape")
	}
	va, _ := op.Get(1)
	sa, _ := op.Get(2)
	verb, ok1 := va.(string)
	sig, ok2 := sa.([]byte)
	if !ok1 || !ok2 || verb != typ {
		return fail(EForbidden, "owner-op verb != envelope type")
	}
	ah, err := proto.ArgsHash(body)
	if err != nil {
		return fail(EForbidden, "args_hash")
	}
	// the owner-op does not carry nonce_helper: try every unexpired one issued for this h (each attempt consumes)
	for k, v := range n.nonces {
		if subtle.ConstantTimeCompare(v.h, h) != 1 || v.helperUsed {
			continue
		}
		nonceHelper, _ := hex.DecodeString(k)
		in, err := proto.OwnerOpInput(h, nonceHelper, typ, ah)
		if err != nil {
			continue
		}
		hit := false
		for _, o := range owners {
			if proto.VerifyES256(o, in, sig) {
				hit = true
			}
		}
		if n.takeHelperNonce(h, nonceHelper) && hit {
			return nil
		}
	}
	return fail(EForbidden, "owner-op signature / nonce")
}

func ownerPubs(rec *provstore.Record) [][]byte {
	var out [][]byte
	for _, o := range rec.Owners {
		out = append(out, o.Pub)
	}
	return out
}

var sshLine = regexp.MustCompile(`^ssh-ed25519 [A-Za-z0-9+/=]{1,200}( [ -~]{0,40})?$`)

func (n *Node) ownerOpVerb(verb string, rec *provstore.Record, a cbor.Map) (cbor.Map, *Error) {
	if e := onlyKeys(a, 1, 2); e != nil {
		return nil, e
	}
	h, e := bytesArg(a, 1, 32)
	if e != nil {
		return nil, e
	}
	raw, e := bytesArg(a, 2, 0)
	if e != nil {
		return nil, e
	}
	typ, body, e := decodeEnvelope(raw)
	if e != nil {
		return nil, e
	}
	want := map[string]string{"net.apply": "network/join", "network.leave": "network/leave", "owner.add": "owner/add",
		"owner.remove": "owner/remove", "settings.set": "settings/set", "root_password.reset": "root_password/reset",
		"diag.bundle": "diag/bundle", "ssh_keys.set": "ssh_keys/set"}[verb]
	if verb == "net.apply" && typ == "network/update" {
		return n.netUpdate(rec, body) // version chain, no owner-op (219 §5.3)
	}
	if typ != want {
		return nil, fail(EForbidden, "envelope type %q for %s", typ, verb)
	}
	if rec.State != provstore.Claimed && rec.State != provstore.Member {
		return nil, fail(EForbidden, "no owner")
	}
	if e := n.verifyOwnerOp(h, typ, body, ownerPubs(rec)); e != nil {
		return nil, e
	}
	switch verb {
	case "net.apply":
		return n.netJoin(rec, body)
	case "network.leave":
		if rec.State != provstore.Member {
			return nil, fail(EForbidden, "not a member")
		}
		next := *rec
		next.Generation++
		next.State = provstore.Claimed
		next.Net, next.Members, next.Admins = nil, nil, nil
		if err := n.commit(&next, "leave"); err != nil {
			return nil, err
		}
		if err := n.Sys.RemoveMeshMarkers(); err != nil {
			n.Log("network.leave: mesh markers: %v", err)
		}
		return cbor.M(), nil
	case "owner.add":
		return n.ownerAdd(rec, body)
	case "owner.remove":
		return n.ownerRemove(rec, body)
	case "settings.set":
		for _, en := range body {
			if en.K == uint64(31) {
				continue
			}
			if s, ok := en.K.(string); ok && s == "hostname" || en.K == uint64(1) {
				return nil, fail(EUnsupported, "rename-pending") // P-U7: no rename in P1
			}
			return nil, fail(ESchema, "unknown setting %v", en.K)
		}
		return cbor.M(), nil
	case "root_password.reset":
		pw := genPassword()
		hash, err := n.Sys.CryptPassword(pw)
		if err == nil {
			err = n.Sys.ApplyLock(hash)
		}
		if err != nil {
			return nil, fail(EApply, "%v", err)
		}
		if rc, out := n.Sys.Save(); rc != 0 {
			return nil, fail(EStorage, "--save rc=%d %s", rc, strings.TrimSpace(out))
		}
		return cbor.M(1, pw), nil
	case "diag.bundle":
		b, err := n.Sys.DiagBundle()
		if err != nil {
			return nil, fail(EApply, "%v", err)
		}
		return cbor.M(1, b), nil
	case "ssh_keys.set":
		return n.sshKeys(rec, body)
	}
	return nil, fail(ESchema, "unreachable")
}

func (n *Node) sshKeys(rec *provstore.Record, body cbor.Map) (cbor.Map, *Error) {
	la, _ := body.Get(1)
	list, ok := la.([]any)
	if !ok || len(list) > 8 {
		return nil, fail(ESchema, "keys: 0..8 lines")
	}
	var lines []string
	for _, l := range list {
		s, ok := l.(string)
		if !ok || len(s) > 256 || strings.ContainsAny(s, "\r\n") || !sshLine.MatchString(s) {
			return nil, fail(ESchema, "key line rejected")
		}
		lines = append(lines, s)
	}
	cur, err := n.Sys.AuthorizedKeys()
	if err != nil {
		return nil, fail(EApply, "%v", err)
	}
	added := map[string]bool{}
	for _, k := range rec.SSHKeysAdded {
		added[k] = true
	}
	var out []string
	for _, k := range cur { // keep every line we did not add ourselves (operator / lab keys)
		if !added[k] {
			out = append(out, k)
		}
	}
	out = append(out, lines...)
	next := *rec
	next.Generation++
	next.SSHKeysAdded = lines
	if err := n.commit(&next, "ssh_keys"); err != nil {
		return nil, err
	}
	if err := n.Sys.SetAuthorizedKeys(out); err != nil {
		return nil, fail(EApply, "%v", err)
	}
	if rc, _ := n.Sys.Save(); rc != 0 {
		n.Log("ssh_keys.set: --save rc=%d", rc)
	}
	return cbor.M(), nil
}

func (n *Node) ownerAdd(rec *provstore.Record, body cbor.Map) (cbor.Map, *Error) {
	pub, e := bytesArg(body, 1, 65)
	if e != nil {
		return nil, e
	}
	enc, e := bytesArg(body, 2, 65)
	if e != nil {
		return nil, e
	}
	se, e := bytesArg(body, 3, 64)
	if e != nil {
		return nil, e
	}
	if !proto.VerifyES256(pub, append([]byte(proto.LabelOwnerEnc), enc...), se) {
		return nil, fail(EForbidden, "sig_enc")
	}
	next := *rec
	next.Owners = append([]provstore.Owner(nil), rec.Owners...)
	tag := rnd(32)
	found := false
	for i, o := range next.Owners {
		if subtle.ConstantTimeCompare(o.Pub, pub) == 1 { // re-add = rotate that owner's tag key (219 §5.3)
			next.Owners[i] = provstore.Owner{Pub: pub, EncPub: enc, TagKey: tag}
			found = true
		}
	}
	if !found {
		if len(next.Owners) >= 4 {
			return nil, fail(EUnsupported, "4 owners")
		}
		next.Owners = append(next.Owners, provstore.Owner{Pub: pub, EncPub: enc, TagKey: tag})
	}
	next.Generation++
	if err := n.commit(&next, "owner.add"); err != nil {
		return nil, err
	}
	return cbor.M(1, tag), nil
}

func (n *Node) ownerRemove(rec *provstore.Record, body cbor.Map) (cbor.Map, *Error) {
	kid, e := bytesArg(body, 1, 32)
	if e != nil {
		return nil, e
	}
	next := *rec
	next.Owners = nil
	for _, o := range rec.Owners {
		s := sha256.Sum256(o.Pub)
		if subtle.ConstantTimeCompare(s[:], kid) != 1 {
			next.Owners = append(next.Owners, o)
		}
	}
	if len(next.Owners) == len(rec.Owners) {
		return nil, fail(EForbidden, "no such owner")
	}
	if len(next.Owners) == 0 {
		return nil, fail(EForbidden, "cannot remove the last owner (reflash to transfer)")
	}
	next.AdvOwnerKey = rnd(32) // rotated on removal (219 §5.3)
	next.Generation++
	if err := n.commit(&next, "owner.remove"); err != nil {
		return nil, err
	}
	return cbor.M(), nil
}

// ---- net.apply (§4.4) --------------------------------------------------------------------------------------------------

// netRoot decrypts the stored net_secrets to read net_root (kept inside the helper).
func (n *Node) netRoot(rec *provstore.Record) []byte {
	pt := n.openSecrets(rec.Net.Secrets, rec.Admins)
	if pt == nil {
		return nil
	}
	return secretField(pt, 2)
}

func (n *Node) openSecrets(raw []byte, admins [][]byte) cbor.Map {
	x, err := cbor.Decode(raw)
	if err != nil {
		return nil
	}
	s, err := cose.VerifySign1(x, cose.CTSecrets, proto.LabelSecrets, admins)
	if err != nil {
		return nil
	}
	target, _ := s.Payload.Get(3)
	dacHash := sha256.Sum256(n.KS.DACPub())
	tb, ok := target.([]byte)
	if !ok || subtle.ConstantTimeCompare(tb, dacHash[:]) != 1 {
		return nil
	}
	nid, _ := s.Payload.Get(1)
	ver, _ := s.Payload.Get(2)
	nidB, ok1 := nid.([]byte)
	verU, ok2 := ver.(uint64)
	if !ok1 || !ok2 || verU > 0xffffffff {
		return nil
	}
	other := append(append([]byte(nil), nidB...), byte(verU>>24), byte(verU>>16), byte(verU>>8), byte(verU))
	enc, _ := s.Payload.Get(4)
	pt, err := cose.Decrypt(enc, proto.LabelSecrets, dacHash[:], other, n.KS.ECDH)
	if err != nil {
		return nil
	}
	m, err := cbor.Decode(pt)
	if err != nil {
		return nil
	}
	mm, _ := m.(cbor.Map)
	return mm
}

func secretField(m cbor.Map, k int) []byte {
	v, _ := m.Get(k)
	b, _ := v.([]byte)
	return b
}

type parsedNet struct {
	cfgRaw, secRaw []byte
	netID          []byte
	version        uint64
	admins         [][]byte
	meshID         string
	channel        string
	sae            string
}

// parseNet verifies net_config (signed by signers) and this node's net_secrets (signed by the same admins set).
func (n *Node) parseNet(cfgItem, secItem any, signers [][]byte) (*parsedNet, *Error) {
	c, err := cose.VerifySign1(cfgItem, cose.CTNetcfg, proto.LabelNetcfg, signers)
	if err != nil {
		return nil, fail(EBadObject, "net_config")
	}
	p := &parsedNet{}
	nid, _ := c.Payload.Get(1)
	ver, _ := c.Payload.Get(2)
	var ok bool
	if p.netID, ok = nid.([]byte); !ok || len(p.netID) != 16 {
		return nil, fail(EBadObject, "net_id")
	}
	if p.version, ok = ver.(uint64); !ok || p.version == 0 || p.version > 0xffffffff {
		return nil, fail(EBadObject, "net_version")
	}
	ad, _ := c.Payload.Get(8)
	al, ok := ad.([]any)
	if !ok || len(al) == 0 || len(al) > 4 {
		return nil, fail(EBadObject, "admins")
	}
	for _, a := range al {
		b, ok := a.([]byte)
		if !ok || len(b) != 65 {
			return nil, fail(EBadObject, "admin")
		}
		p.admins = append(p.admins, b)
	}
	hl, _ := c.Payload.Get(6)
	halow, ok := hl.(cbor.Map)
	if !ok {
		return nil, fail(EBadObject, "halow")
	}
	ssid, _ := halow.Get(1)
	ch, _ := halow.Get(2)
	if p.meshID, ok = ssid.(string); !ok || p.meshID == "" {
		return nil, fail(EBadObject, "ssid")
	}
	chU, ok := ch.(uint64)
	if !ok {
		return nil, fail(EBadObject, "channel")
	}
	p.channel = fmt.Sprint(chU)
	p.cfgRaw, _ = cbor.Encode(cfgItem)
	p.secRaw, _ = cbor.Encode(secItem)
	pt := n.openSecrets(p.secRaw, signers)
	if pt == nil {
		return nil, fail(EBadObject, "net_secrets")
	}
	sae := secretField(pt, 1)
	if sae == nil {
		if s, ok := func() (string, bool) { v, _ := pt.Get(1); s, ok := v.(string); return s, ok }(); ok {
			sae = []byte(s)
		}
	}
	if len(sae) < 8 {
		return nil, fail(EBadObject, "sae_password")
	}
	p.sae = string(sae)
	return p, nil
}

func (n *Node) netJoin(rec *provstore.Record, body cbor.Map) (cbor.Map, *Error) {
	if rec.Net != nil {
		return nil, fail(EStaleVersion, "already in a network: use network/update")
	}
	cfg, _ := body.Get(1)
	sec, _ := body.Get(3)
	// first version: self-signed by its creator; the owner-op (already verified) is the trust anchor (219 §7.1)
	c, err := cose.VerifySign1(cfg, cose.CTNetcfg, proto.LabelNetcfg, n.adminsOf(cfg))
	if err != nil {
		return nil, fail(EBadObject, "net_config v1")
	}
	_ = c
	p, e := n.parseNet(cfg, sec, n.adminsOf(cfg))
	if e != nil {
		return nil, e
	}
	return n.applyNet(rec, p, "network/join")
}

func (n *Node) adminsOf(cfg any) [][]byte {
	t, ok := cfg.(cbor.Tag)
	if !ok {
		return nil
	}
	a, ok := t.V.([]any)
	if !ok || len(a) != 4 {
		return nil
	}
	pl, ok := a[2].([]byte)
	if !ok {
		return nil
	}
	x, err := cbor.Decode(pl)
	if err != nil {
		return nil
	}
	m, _ := x.(cbor.Map)
	ad, _ := m.Get(8)
	al, _ := ad.([]any)
	var out [][]byte
	for _, v := range al {
		if b, ok := v.([]byte); ok {
			out = append(out, b)
		}
	}
	return out
}

func (n *Node) netUpdate(rec *provstore.Record, body cbor.Map) (cbor.Map, *Error) {
	if rec.Net == nil {
		return nil, fail(EStaleVersion, "no network yet: first version only via network/join")
	}
	chainAny, _ := body.Get(1)
	chain, ok := chainAny.([]any)
	if !ok || len(chain) == 0 {
		return nil, fail(ESchema, "version chain")
	}
	sec, _ := body.Get(2)
	admins := rec.Admins
	prevX, _ := cbor.Decode(rec.Net.Config)
	prevS, err := cose.VerifySign1(prevX, cose.CTNetcfg, proto.LabelNetcfg, rec.Admins)
	if err != nil {
		return nil, fail(EBadObject, "stored net_config")
	}
	prevHash, prevVer := prevS.ObjectHash, rec.Net.Version
	var last any
	for _, item := range chain {
		s, err := cose.VerifySign1(item, cose.CTNetcfg, proto.LabelNetcfg, admins) // version v+1 by version v's admins
		if err != nil {
			return nil, fail(EBadObject, "chain link")
		}
		ver, _ := s.Payload.Get(2)
		ph, _ := s.Payload.Get(3)
		vU, _ := ver.(uint64)
		phB, _ := ph.([]byte)
		if vU != prevVer+1 || subtle.ConstantTimeCompare(phB, prevHash) != 1 {
			return nil, fail(EStaleVersion, "chain not contiguous")
		}
		admins = n.adminsOf(item)
		prevHash, prevVer, last = s.ObjectHash, vU, item
	}
	// the last version's secrets are signed by the admins valid for it (= the previous version's set, §7.1)
	p, e := n.parseNet(last, sec, n.adminsOfPrev(chain, rec))
	if e != nil {
		return nil, e
	}
	return n.applyNet(rec, p, "network/update")
}

func (n *Node) adminsOfPrev(chain []any, rec *provstore.Record) [][]byte {
	if len(chain) >= 2 {
		return n.adminsOf(chain[len(chain)-2])
	}
	return rec.Admins
}

// applyNet runs the §4.4 transaction: txn markers, setkey --no-persist, --prov-only, overlay rename, --save, prov-state.
func (n *Node) applyNet(rec *provstore.Record, p *parsedNet, verb string) (cbor.Map, *Error) {
	token := hex.EncodeToString(rnd(16))
	next := *rec
	next.Generation = rec.Generation + 1
	next.State = provstore.Member
	next.RadioManaged = true
	next.Admins = p.admins
	next.Net = &provstore.Net{Config: p.cfgRaw, Secrets: p.secRaw, Version: p.version, NetID: p.netID}
	// step 1: markers, staged record
	if err := n.Sys.WriteTxnMarker(token); err != nil {
		return nil, fail(EApply, "txn marker: %v", err)
	}
	defer n.Sys.ClearTxnMarker()
	pk, pid, pch, err := n.Sys.CurrentWireless()
	if err != nil {
		return nil, fail(EApply, "current wireless: %v", err)
	}
	if err := writeTxn(n.P, token, rec.Generation, next.Generation, verb, pk, pid, pch); err != nil {
		return nil, fail(EApply, "txn: %v", err)
	}
	// step 2: the fallible side effect
	if err := n.Sys.SetKeyNoPersist(p.sae, p.meshID, p.channel); err != nil {
		removeTxn(n.P)
		return nil, fail(EApply, "setkey: %v", err)
	}
	// step 3-4: persist then rename the overlay record (commit point = p5 prov.meta)
	if err := n.commitTxn(&next, token); err != nil {
		return nil, err
	}
	removeTxn(n.P)
	// step 5
	if rc, out := n.Sys.Save(); rc != 0 && rc != 6 {
		n.Log("%s: --save rc=%d (%s) — the next boot's --check reports it", verb, rc, strings.TrimSpace(out))
	}
	return cbor.M(1, p.version), nil
}
