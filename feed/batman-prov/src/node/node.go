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
	"batman-prov/seam"
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
	EState        = 22 // this boot's verdict is unknown(*) (e.g. identity-mismatch: frozen, P-U6)
	// ELockIncomplete: the request was COMMITTED to p5 but the lock / password step did not complete; no password was
	// handed out. Only returned after a commit (EApply also covers pre-commit stage failures). provd maps it to
	// protocol 13 E_LOCK_INCOMPLETE -> the app retries with claim/replay (219-protocol §5.2; claim-lock fix §7).
	ELockIncomplete = 23
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
	IsTrial() bool                                                 // batman-slot is-trial rc 0
	Persist(record, meta, identity, txn string) (int, string)      // batman-config-save --prov-only
	GetP5(dir string) (int, string)                                // batman-config-save --prov-get
	Save() (int, string)                                           // batman-config-save --save (after a lock/shadow change)
	SetKeyNoPersist(meshKey, meshID string, channel string) error  // halow-setkey --no-persist; a *SetkeyError on failure
	CurrentWireless() (meshKey, meshID, channel string, err error) // the live values (the pre-change snapshot in .txn)
	// docs/design/254-wireless-txn.md
	SaveTxn(token string) (int, string)                     // batman-config-save --save --txn <token> (while .txn + marker hold it)
	ForgetMesh() error                                      // halow-setkey --forget-mesh --no-persist; a *SetkeyError on failure
	RadioState() (disabled, inKeyguardMark bool, err error) // the morse radio's uci disabled; listed in the keyguard mark
	SetMeshExpect(me string) error                          // p6 prov-state field 6 only
	CheckRestorable(key, id, ch string) error               // halow-setkey --check-only + sae encryption (§15.1)
	LiveMeshUp() bool                                       // the radio is up on the uci mesh id (meshjoin_radio_up, §15.4)
	ApplyLock(rootHash string) error                        // prov_apply_lock --hash-stdin: doors first, the hash last (§5.3)
	RestoreRoot(prev string) error                          // prov_apply_lock --restore-stdin: root's previous field back ("" -> "!")
	RootField() (string, error)                             // root's current shadow field
	MarkLockIncomplete()                                    // p6 lock-status LOCK-INCOMPLETE
	SetLastKnown(state string) error                        // p6 prov-state field 3 only (claim / replay commit)
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
	// Verdict is this boot's --boot verdict; unknown(*) freezes every state-changing verb (round-6 B-M2)
	Verdict string
	// 254-wireless-txn §15: an apply of this lifetime ended "changed, not verified"; the last verb-triggered Finish
	// failure; the last commit-only resolve
	lastFinishFail time.Time
	finishFails    int // consecutive Finish failures (the backoff doubles, §16.1)
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

// commitOnly: state-changing verbs that only commit the record (no save, no wireless) — 254-wireless-txn §4.1
var commitOnly = map[string]bool{"owner.add": true, "owner.remove": true}

func (n *Node) dispatch(verb string, a cbor.Map) (cbor.Map, *Error) {
	if stateChanging[verb] && n.Sys.IsTrial() {
		return nil, fail(EBusy, "trial slot (updating)")
	}
	if stateChanging[verb] && (n.Verdict == "" || strings.HasPrefix(n.Verdict, "unknown")) {
		return nil, fail(EState, "this boot's verdict is %q — state changes refused", n.Verdict)
	}
	// docs/design/254-wireless-txn.md §4.1: an unfinished wireless change is finished before a verb that saves or changes
	// the wireless; commit-only verbs never Finish (an owner can always remove a co-owner, even with a dead radio) but
	// never commit on an overlay older than p5 either
	if !commitOnly[verb] && stateChanging[verb] && provstore.TxnPresent(n.P) {
		if e := n.finishGated("before " + verb); e != nil {
			return nil, fail(EState, "an earlier network change could not be finished (%s)", e.Reason)
		}
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
	case "info.net":
		// net_id / version / left for the app's "already done" decision (254-wireless-txn §4.1). provd routes this
		// verb only for the owner role: a stable net_id to any BLE peer would link a fleet (§14).
		if e := onlyKeys(a); e != nil {
			return nil, e
		}
		var nid any
		var ver uint64
		if rec.Net != nil {
			nid, ver = rec.Net.NetID, rec.Net.Version
		}
		return cbor.M(1, nid, 2, ver, 3, rec.Left), nil
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

const pwAlpha = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789"

// genPassword: 24 characters from a 56-character set by rejection sampling (bytes >= 224 = 256 - 256%56 are redrawn,
// so every character is equally likely; ~139 bits).
func genPassword() string {
	out := make([]byte, 0, 24)
	for len(out) < 24 {
		for _, v := range rnd(32) {
			if int(v) < 256-256%len(pwAlpha) && len(out) < 24 {
				out = append(out, pwAlpha[int(v)%len(pwAlpha)])
			}
		}
	}
	return string(out)
}

// cfgSaveBusy: batman-config-save --save found another instance writing p5 (it waits 10 s, then exits 1 with this
// line; batman-config-save:190-224). Retried once (claim-lock fix §5.3).
func cfgSaveBusy(rc int, out string) bool {
	return rc == 1 && strings.Contains(out, "another batman-config-save is writing p5")
}

func (n *Node) saveRetry() (int, string) {
	rc, out := n.Sys.Save()
	if cfgSaveBusy(rc, out) {
		n.Log("--save: p5 busy, retrying once")
		rc, out = n.Sys.Save()
	}
	return rc, out
}

func lastOf(s string) string {
	l := strings.Split(strings.TrimSpace(s), "\n")
	return l[len(l)-1]
}

// setPassword is the password step shared by claim / claim.replay / root_password.reset (docs/design/
// 254-claim-lock-fix.md §5.3). The password is handed out only once p5 holds it:
//   - hash or lock failure (doors first, hash last): shadow keeps its previous value (an empty root became "!");
//     --save still runs (p5 is already claimed and must be seeded to allow OTAs) -> ELockIncomplete;
//   - --save failure (busy retried once): root's previous field is written back BEFORE the error — joinwatch's
//     --on-join would otherwise carry the never-delivered hash into p5 — then one best-effort --save so p5 follows the
//     restored value; a failed restore -> CRIT + lock-status LOCK-INCOMPLETE -> saveFailCode.
func (n *Node) setPassword(pw string, saveFailCode int) *Error {
	prev, perr := n.Sys.RootField()
	hash, err := n.Sys.CryptPassword(pw)
	if err == nil {
		err = n.Sys.ApplyLock(hash)
	} else {
		n.Sys.ApplyLock("") // no hash could be made: still lock the doors, an empty root becomes "!" (review A-m1)
	}
	if err != nil {
		n.Log("lock step failed: %v — no password handed out", err)
		// a late failure (after the shadow mv: sync / read-back) can leave the new hash live: put the previous field
		// back before anything is saved (review B-m2)
		if cur, cerr := n.Sys.RootField(); cerr == nil && hash != "" && cur == hash {
			if perr != nil || n.Sys.RestoreRoot(prev) != nil {
				n.Log("CRIT: the undelivered hash is live and could not be restored — recover with claim/replay or root_password/reset")
				n.Sys.MarkLockIncomplete()
			}
		}
		if rc, out := n.saveRetry(); rc != 0 {
			n.Log("--save after the failed lock step: rc=%d (%s)", rc, lastOf(out))
		}
		return fail(ELockIncomplete, "lock-incomplete: %v", err)
	}
	rc, out := n.saveRetry()
	if rc == 0 {
		return nil
	}
	n.Log("--save rc=%d (%s) — restoring root's previous shadow field, no password handed out", rc, lastOf(out))
	if perr != nil {
		n.Log("CRIT: root's previous shadow field unknown (%v): the live hash was never handed out — recover with claim/replay or root_password/reset", perr)
		n.Sys.MarkLockIncomplete()
	} else if rerr := n.Sys.RestoreRoot(prev); rerr != nil {
		n.Log("CRIT: restoring root's shadow field failed (%v): the live hash was never handed out — recover with claim/replay or root_password/reset", rerr)
		n.Sys.MarkLockIncomplete()
	} else if rc2, out2 := n.Sys.Save(); rc2 != 0 {
		n.Log("best-effort --save after the restore: rc=%d (%s)", rc2, lastOf(out2))
	}
	return fail(saveFailCode, "--save rc=%d", rc)
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
	if err := n.commitTxn(&next, "", seam.ClaimAfterPersist); err != nil { // = commit + its killpoint
		return nil, err
	}
	// committed: p6 last_known_state follows at once, so batman-prov-lock locks on any slot even if p5 is unreadable
	if err := n.Sys.SetLastKnown(string(provstore.Claimed)); err != nil {
		n.Log("claim: p6 last_known_state not updated: %v", err)
	}
	seam.At(seam.ClaimBeforeShadow, n.Log) // claimed in p5 + overlay + p6, not locked, no shadow-root
	// §6.1 step 4 (claim-lock fix §5.3): lock, hash last, --save; the password only once p5 holds it
	if e := n.setPassword(pw, ELockIncomplete); e != nil {
		n.Log("claim committed, lock / save incomplete (%s): the owner recovers with claim/replay", e.Reason)
		return nil, e
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
	// the node nonce is taken BEFORE the owner-op is verified: verifyOwnerOp consumes every nonce entry it tries
	// (node half included, takeHelperNonce deletes the entry), so taking it afterwards found nothing or an older one
	// and claim.replay failed unless map iteration happened to spare it (found by the claim-lock fix tests,
	// TestReplayOK). One `nonce` call now serves both: node half -> CheckMac, helper half -> owner-op.
	nn := n.takeNodeNonce(h)
	if e := n.verifyOwnerOp(h, typ, body, [][]byte{owner.Pub}); e != nil {
		return failOnce(e.Code, e.Reason)
	}
	if nn == nil || !n.KS.CheckMac(proto.ClientChal(nn, h, n.KS.Cert(), owner.Pub), resp) {
		return failOnce(EForbidden, "CheckMac")
	}
	if err := n.Sys.SetLastKnown(string(rec.State)); err != nil {
		n.Log("claim.replay: p6 last_known_state not updated: %v", err)
	}
	pw := genPassword()
	if e := n.setPassword(pw, ELockIncomplete); e != nil {
		return nil, e
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
	// commit-only verbs never Finish (an owner can always remove a co-owner, even with a dead radio) but never commit
	// on an overlay older than p5 either — resolved AFTER the owner-op check (§16.4: no p5 mount for anonymous peers)
	if commitOnly[verb] {
		if r, e := n.resolve(); e != nil {
			n.Log("%s: %s (committing on the overlay)", verb, e.Reason)
		} else if r.Generation != rec.Generation {
			// §17.1 (review 3 B MAJOR-1): the owner-op was verified against a stale overlay — its owners may not be the
			// record's any more (a removed co-owner re-adding themselves). The overlay is now rebuilt: retry.
			return nil, fail(EState, "the provisioning record changed (generation %d -> %d) — retry", rec.Generation, r.Generation)
		}
	}
	switch verb {
	case "net.apply":
		return n.netJoin(rec, body)
	case "network.leave":
		return n.leave(rec)
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
		// lock failure -> ELockIncomplete (password unchanged); --save failure -> EStorage with root restored
		if e := n.setPassword(pw, EStorage); e != nil {
			return nil, e
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
	pt := n.openStoredSecrets(rec.Net.Secrets) // stored: not re-verified (handover, 254-wireless-txn §2)
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
	return n.decryptSecrets(s)
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
	// the STORED config is not re-verified (254-wireless-txn §2): after an admin handover it is signed by admins that
	// are no longer in rec.Admins, which made every later update fail (review r5 B MAJOR-3); its OBJECT_HASH is the same
	prevS, err := cose.Sign1Payload(prevX, cose.CTNetcfg, proto.LabelNetcfg)
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

// applyNet runs the wireless transaction of a join / update (docs/design/254-wireless-txn.md §3, §4.2): pre-check,
// .txn (the pre-change snapshot) + marker, setkey --no-persist, commit (p5 = the commit point), then save under the
// transaction's token and only then drop .txn. Any failure after the live change -> Finish: the node goes back to the
// previous state (or forward, if the commit landed — decided by p5, not by generations).
func (n *Node) applyNet(rec *provstore.Record, p *parsedNet, verb string) (cbor.Map, *Error) {
	// a radio an operator switched off by hand can neither take the change nor its undo (review r6 A M1)
	if dis, inMark, err := n.Sys.RadioState(); err == nil && dis && !inMark {
		return nil, fail(EApply, "the HaLow radio is switched off on this node")
	}
	// §15.1: when the previous state is the snapshot (not a member), it must be restorable — or the change is refused
	// before anything changes
	if rec.State != provstore.Member {
		k, id, ch, err := n.Sys.CurrentWireless()
		if err != nil {
			return nil, fail(EApply, "current wireless: %v", err)
		}
		if k != placeholderKey {
			if err := n.Sys.CheckRestorable(k, id, ch); err != nil {
				return nil, fail(EApply, "this node's mesh settings were set outside halow-setkey and could not be put back if the change failed — set them with halow-setkey first (%v)", err)
			}
		}
	}
	token := hex.EncodeToString(rnd(16))
	next := *rec
	next.Generation = rec.Generation + 1
	next.State = provstore.Member
	next.RadioManaged = true
	next.Left = false
	next.Admins = p.admins
	next.Net = &provstore.Net{Config: p.cfgRaw, Secrets: p.secRaw, Version: p.version, NetID: p.netID}
	// step 1: marker, .txn with the snapshot of the live wireless (the previous state of a non-member, §2)
	if err := n.Sys.WriteTxnMarker(token); err != nil {
		return nil, fail(EApply, "txn marker: %v", err)
	}
	defer n.Sys.ClearTxnMarker()
	pk, pid, pch, err := n.Sys.CurrentWireless()
	if err != nil {
		return nil, fail(EApply, "current wireless: %v", err)
	}
	dis, _, _ := n.Sys.RadioState()
	if err := provstore.WriteTxn(n.P, token, rec.Generation, next.Generation, verb, pk, pid, pch, dis); err != nil {
		return nil, fail(EApply, "txn: %v", err)
	}
	seam.At(seam.Txn1, n.Log) // marker + .txn written, wireless untouched
	// step 2: the live change
	err = n.Sys.SetKeyNoPersist(p.sae, p.meshID, p.channel)
	n.noteApply(err)
	if err != nil {
		if setkeyRC(err) == 2 { // nothing changed: nothing to undo (review r4 B-M2)
			provstore.RemoveTxn(n.P)
			return nil, fail(EApply, "setkey: %v", err)
		}
		n.finish("after a failed setkey of " + verb)
		return nil, fail(EApply, "setkey: %v", err)
	}
	seam.At(seam.Txn2, n.Log) // wireless changed (not persisted), p5 not yet
	// step 3: commit (p5 prov.meta is the commit point)
	if err := n.commitTxn(&next, token, seam.Txn3); err != nil {
		n.finish("after a failed commit of " + verb)
		return nil, err
	}
	seam.At(seam.Txn4, n.Log) // committed; .txn and the marker still there, the save not done
	// step 4: save under this transaction's token BEFORE .txn goes (a power loss in between = Finish again)
	if rc, out := n.Sys.SaveTxn(token); rc != 0 && rc != 6 {
		n.Log("%s: save rc=%d (%s) — .txn kept, the next boot finishes it", verb, rc, strings.TrimSpace(out))
	} else {
		provstore.RemoveTxn(n.P)
	}
	n.refreshMeshExpect(&next) // §15.6 (A m4)
	seam.At(seam.Txn5, n.Log)  // everything written, the reply not sent
	return cbor.M(1, p.version), nil
}

// leave (L22, 254-wireless-txn §5): network/leave = forget the network. A wireless transaction: .txn, commit
// (claimed, Left), forget (placeholder, radio blocked), markers, save, drop .txn. A power loss before the commit puts the
// network back (Finish against the member record); after it, Finish forgets.
func (n *Node) leave(rec *provstore.Record) (cbor.Map, *Error) {
	if rec.State != provstore.Member {
		return nil, fail(EForbidden, "not a member")
	}
	token := hex.EncodeToString(rnd(16))
	next := *rec
	next.Generation = rec.Generation + 1
	next.State = provstore.Claimed
	next.Net, next.Members, next.Admins = nil, nil, nil
	next.Left = true
	if err := n.Sys.WriteTxnMarker(token); err != nil {
		return nil, fail(EApply, "txn marker: %v", err)
	}
	defer n.Sys.ClearTxnMarker()
	pk, pid, pch, err := n.Sys.CurrentWireless()
	if err != nil {
		return nil, fail(EApply, "current wireless: %v", err)
	}
	dis, _, _ := n.Sys.RadioState()
	if err := provstore.WriteTxn(n.P, token, rec.Generation, next.Generation, "network/leave", pk, pid, pch, dis); err != nil {
		return nil, fail(EApply, "txn: %v", err)
	}
	if err := n.commitTxn(&next, token, seam.None); err != nil {
		n.finish("after a failed commit of network/leave")
		return nil, err
	}
	err = n.Sys.ForgetMesh()
	n.noteApply(err)
	if err != nil {
		// committed but not forgotten: .txn stays, the next Finish forgets; the app must not show "left" as complete
		n.Log("network.leave: committed, forgetting the mesh failed: %v", err)
		return nil, fail(EApply, "left the network; the radio still has the old settings — retry")
	}
	if err := n.Sys.RemoveMeshMarkers(); err != nil {
		n.Log("network.leave: mesh markers: %v", err)
	}
	if rc, out := n.Sys.SaveTxn(token); rc != 0 && rc != 6 {
		n.Log("network.leave: save rc=%d (%s) — .txn kept, the next boot finishes it", rc, strings.TrimSpace(out))
	} else {
		provstore.RemoveTxn(n.P)
	}
	n.refreshMeshExpect(&next)
	return cbor.M(), nil
}
