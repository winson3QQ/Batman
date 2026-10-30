package node

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"batman-prov/boot"
	"batman-prov/cbor"
	"batman-prov/cose"
	"batman-prov/proto"
	"batman-prov/provstore"
)

// Wireless transactions (docs/design/254-wireless-txn.md). Owner rule: a change of the mesh wireless that did not
// succeed returns the node to the previous state. `.txn` (provstore) is the "unfinished" flag plus the pre-change
// snapshot; Finish makes the live mesh wireless match the previous state and only then saves and removes `.txn`.

const placeholderKey = "CHANGE-ME-NOW"

// SetkeyError carries halow-setkey's exit code: 2 = nothing changed (bad argument, busy, no radio), 3 = applied but not
// verified / not persisted. The real Sys returns it; anything else is treated as "changed, outcome unknown".
type SetkeyError struct {
	RC  int
	Msg string
}

func (e *SetkeyError) Error() string { return fmt.Sprintf("halow-setkey rc=%d: %s", e.RC, e.Msg) }

func setkeyRC(err error) int {
	var se *SetkeyError
	if errors.As(err, &se) {
		return se.RC
	}
	if err != nil {
		return 1
	}
	return 0
}

type wantKind int

const (
	wantNet    wantKind = iota // key / mesh id / channel
	wantForget                 // placeholder key, radio blocked by the keyguard, mesh markers removed
)

type wantWireless struct {
	kind         wantKind
	key, id, ch  string
	source       string // for the log: "the committed network" | "left" | "the pre-change snapshot"
	fromSnapshot bool
}

// storedNet decodes the committed record's network WITHOUT re-verifying signatures (§2): it was verified when it was
// accepted and lives in the root-only record; after an admin handover it is signed by admins no longer in rec.Admins.
func (n *Node) storedNet(rec *provstore.Record) (meshID, channel, sae string, err error) {
	if rec.Net == nil {
		return "", "", "", errors.New("no network in the record")
	}
	x, err := cbor.Decode(rec.Net.Config)
	if err != nil {
		return "", "", "", errors.New("stored net_config undecodable")
	}
	s, err := cose.Sign1Payload(x, cose.CTNetcfg, proto.LabelNetcfg)
	if err != nil {
		return "", "", "", errors.New("stored net_config malformed")
	}
	hl, _ := s.Payload.Get(6)
	halow, ok := hl.(cbor.Map)
	if !ok {
		return "", "", "", errors.New("stored net_config: no halow")
	}
	ssid, _ := halow.Get(1)
	ch, _ := halow.Get(2)
	id, ok1 := ssid.(string)
	chU, ok2 := ch.(uint64)
	if !ok1 || id == "" || !ok2 {
		return "", "", "", errors.New("stored net_config: halow fields")
	}
	pt := n.openStoredSecrets(rec.Net.Secrets)
	if pt == nil {
		return "", "", "", errors.New("stored net_secrets do not open")
	}
	key := saeOf(pt)
	if len(key) < 8 {
		return "", "", "", errors.New("stored net_secrets: sae_password")
	}
	return id, fmt.Sprint(chU), key, nil
}

// saeOf reads net_secrets' sae_password the way parseNet does (a byte field, or a text string).
func saeOf(pt cbor.Map) string {
	if b := secretField(pt, 1); b != nil {
		return string(b)
	}
	if v, ok := pt.Get(1); ok {
		if s, ok := v.(string); ok {
			return s
		}
	}
	return ""
}

// openStoredSecrets opens the STORED net_secrets: the signature is not re-checked (§2, §9), the DAC-target check and
// the net_id / version binding of the decryption stay exactly as in openSecrets.
func (n *Node) openStoredSecrets(raw []byte) cbor.Map {
	x, err := cbor.Decode(raw)
	if err != nil {
		return nil
	}
	s, err := cose.Sign1Payload(x, cose.CTSecrets, proto.LabelSecrets)
	if err != nil {
		return nil
	}
	return n.decryptSecrets(s)
}

// decryptSecrets is openSecrets' part after the signature: the DAC target, the net_id / version binding, the decryption.
func (n *Node) decryptSecrets(s *cose.Sign1) cbor.Map {
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

// desired = the previous state for this record (§2). A snapshot that halow-setkey cannot carry, or an unreadable one,
// is finished by forgetting (§15.1: the previous state cannot be reached; forgotten is fail-secure and the owner can
// join again).
func (n *Node) desired(rec *provstore.Record, tx provstore.Txn, txOK bool) (wantWireless, error) {
	switch {
	case rec.State == provstore.Member && rec.Net != nil:
		id, ch, key, err := n.storedNet(rec)
		if err != nil {
			return wantWireless{}, err
		}
		return wantWireless{kind: wantNet, key: key, id: id, ch: ch, source: "the committed network"}, nil
	case rec.Left:
		return wantWireless{kind: wantForget, source: "left (forgotten)"}, nil
	}
	if !txOK {
		n.Log("CRIT finish: the pre-change snapshot in .txn is unreadable — forgetting the mesh (the owner can join again)")
		return wantWireless{kind: wantForget, source: "forgotten (the snapshot is unreadable)", fromSnapshot: true}, nil
	}
	if tx.PrevKey == placeholderKey {
		return wantWireless{kind: wantForget, source: "the pre-change snapshot (placeholder)", fromSnapshot: true}, nil
	}
	if err := n.Sys.CheckRestorable(tx.PrevKey, tx.PrevID, tx.PrevChannel); err != nil {
		n.Log("CRIT finish: the pre-change settings cannot be restored by halow-setkey (%v) — forgetting the mesh (the owner can join again)", err)
		return wantWireless{kind: wantForget, source: "forgotten (the snapshot cannot be restored)", fromSnapshot: true}, nil
	}
	return wantWireless{kind: wantNet, key: tx.PrevKey, id: tx.PrevID, ch: tx.PrevChannel,
		source: "the pre-change snapshot", fromSnapshot: true}, nil
}

// satisfied: the LIVE wireless already is the wanted one (§15.4) — no re-apply, no wifi reload (review A r4 m1). A
// forget is never "satisfied": --forget-mesh is idempotent and is the only thing that verifies the radio is down.
// A network is satisfied only when uci matches, the radio is up on that mesh id, and no apply of this helper's lifetime
// ended unverified (an update may change only the key, which a live mesh id cannot show).
func (n *Node) satisfied(w wantWireless) bool {
	if w.kind == wantForget || n.unverified {
		return false
	}
	key, id, ch, err := n.Sys.CurrentWireless()
	if err != nil {
		return false
	}
	dis, _, err := n.Sys.RadioState()
	if err != nil || dis {
		return false
	}
	return key == w.key && (w.id == "" || id == w.id) && (w.ch == "" || ch == w.ch) && n.Sys.LiveMeshUp()
}

// noteApply records whether an apply was verified: rc 0 clears, rc 2 (nothing changed) keeps, anything else sets.
func (n *Node) noteApply(err error) {
	switch setkeyRC(err) {
	case 0:
		n.unverified = false
	case 2:
	default:
		n.unverified = true
	}
}

// resolve decides the committed record the way --boot does (p5 vs the overlay), with no side effect beyond
// rewriting a stale overlay from p5. p5 unreadable — including rc 0 with a record that does not decode (§15.6, like
// --boot's unknown(prov-corrupt)) — is an error: nothing may be finished against a record p5 did not confirm (review B
// r4 MAJOR-1).
func (n *Node) resolve() (*provstore.Record, *Error) {
	d, err := os.MkdirTemp(n.P.RunDir, "provget.")
	if err != nil {
		return nil, fail(EApply, "run dir: %v", err)
	}
	os.Remove(d) // --prov-get creates it itself
	defer os.RemoveAll(d)
	rc, out := n.Sys.GetP5(d)
	switch rc {
	case 0, 7, 9, 13:
	default:
		return nil, fail(EStorage, "p5 unreadable (--prov-get rc=%d %s)", rc, strings.TrimSpace(out))
	}
	ov, _, _ := provstore.LoadOverlay(n.P)
	var p5 *provstore.Record
	if b, err := os.ReadFile(filepath.Join(d, "prov.cbor")); err == nil {
		r, err := provstore.Decode(b)
		if err != nil {
			return nil, fail(EStorage, "p5 record does not decode (%v)", err)
		}
		p5 = r
	} else if rc == 0 {
		return nil, fail(EStorage, "p5 --prov-get rc 0 without a record")
	}
	switch {
	case p5 != nil && (ov == nil || p5.Generation > ov.Generation):
		if _, _, err := provstore.WriteOverlay(n.P, p5); err != nil {
			n.Log("resolve: overlay rebuild from p5 failed: %v", err)
		} else {
			n.Log("resolve: overlay rebuilt from p5 (gen %d)", p5.Generation)
		}
		return p5, nil
	case ov != nil:
		return ov, nil
	}
	return nil, fail(EState, "no usable provisioning record")
}

// Finish (§3): make the live mesh wireless the previous state, then save, then drop .txn. The caller holds n.mu.
// The run-dir marker is (re)written with .txn's token — after a reboot it is gone, and `config-save --save --txn`
// needs it — and cleared on EVERY exit (review B r6 MAJOR-1). On failure .txn stays: saves stay blocked.
func (n *Node) finish(why string) *Error {
	if !provstore.TxnPresent(n.P) {
		return nil
	}
	rec, e := n.resolve()
	if e != nil {
		n.Log("finish (%s): %s — the unfinished change is finished later", why, e.Reason)
		return e
	}
	tx, txOK := provstore.ReadTxn(n.P)
	tok := provstore.TxnToken(n.P)
	if tok == "" {
		// §15.1: an unreadable token. A fresh one carries the same obligation; the snapshot (if the record needs it)
		// is unreadable too and desired() forgets.
		tok = hex.EncodeToString(rnd(16))
		if err := provstore.WriteTxn(n.P, tok, rec.Generation, rec.Generation, "unreadable", "", "", "", false); err != nil {
			return fail(EApply, "txn rewrite: %v", err)
		}
		n.Log("CRIT finish (%s): .txn had no readable token — rewritten with a fresh one", why)
		tx, txOK = provstore.Txn{}, false
	}
	if err := n.Sys.WriteTxnMarker(tok); err != nil {
		return fail(EApply, "txn marker: %v", err)
	}
	defer n.Sys.ClearTxnMarker()
	w, err := n.desired(rec, tx, txOK)
	if err != nil {
		n.Log("CRIT finish (%s): %v — .txn kept, saves stay blocked", why, err)
		return fail(EState, "%v", err)
	}
	how := "already"
	if !n.satisfied(w) {
		if w.kind == wantForget {
			err = n.Sys.ForgetMesh()
		} else {
			err = n.Sys.SetKeyNoPersist(w.key, w.id, w.ch)
		}
		n.noteApply(err)
		if err != nil {
			n.Log("CRIT finish (%s): back to %s failed (%v) — .txn kept, saves stay blocked", why, w.source, err)
			return fail(EApply, "%v", err)
		}
		how = "applied"
	}
	if w.kind == wantForget {
		if err := n.Sys.RemoveMeshMarkers(); err != nil {
			n.Log("finish: mesh markers: %v", err)
		}
	}
	if w.fromSnapshot && txOK && tx.HasRadio {
		// a restore never writes `disabled` (§2); an operator switching the radio meanwhile is logged, not undone
		if dis, _, err := n.Sys.RadioState(); err == nil && dis != tx.PrevDisabled && w.kind == wantNet {
			n.Log("CRIT finish: the radio's disabled flag changed by hand during the change (%v -> %v) — kept", tx.PrevDisabled, dis)
		}
	}
	rc, out := n.Sys.SaveTxn(tok)
	if rc != 0 && rc != 6 {
		n.Log("finish (%s): save rc=%d (%s) — .txn kept, finished again later", why, rc, strings.TrimSpace(out))
		return fail(EStorage, "save rc=%d", rc)
	}
	provstore.RemoveTxn(n.P)
	n.refreshMeshExpect(rec)
	verb := tx.Verb
	if !txOK {
		verb = "?"
	}
	n.Log("txn %s finished (%s): wireless = %s, %s, save rc=%d", verb, why, w.source, how, rc)
	return nil
}

// finishGated is the verb-triggered Finish (§15.5): after a failure it is not retried for finishBackoff — the verb
// gets EState at once, so an unauthenticated peer can cause at most one setkey + one p5 save per backoff.
const finishBackoff = 60 * time.Second

func (n *Node) finishGated(why string) *Error {
	if !n.lastFinishFail.IsZero() && n.Sys.Now().Sub(n.lastFinishFail) < finishBackoff {
		return fail(EState, "retried within %s of a failure", finishBackoff)
	}
	if e := n.finish(why); e != nil {
		n.lastFinishFail = n.Sys.Now()
		return e
	}
	n.lastFinishFail = time.Time{}
	return nil
}

// refreshMeshExpect: prov-state's mesh_expect follows the finished state (review A r4 m3).
func (n *Node) refreshMeshExpect(rec *provstore.Record) {
	me := boot.MeshExpect(rec.State, func() string { k, _, _, _ := n.Sys.CurrentWireless(); return k })
	if err := n.Sys.SetMeshExpect(me); err != nil {
		n.Log("prov-state mesh_expect: %v", err)
	}
}

// BootFinish (§3, §15.2): the boot's Finish runs in the background holding the helper mutex, which is taken HERE,
// before the caller starts listening — no verb runs before it ends, and the helper always listens. waitRadio is called
// (under the mutex) first when the previous state is a network on a radio that is not blocked.
func (n *Node) BootFinish(waitRadio func()) {
	n.mu.Lock()
	go func() {
		defer n.mu.Unlock()
		if n.finishWantsRadio() {
			waitRadio()
		}
		if e := n.finish("boot"); e != nil {
			n.Log("boot finish: %s", e.Reason)
		}
	}()
}

// finishWantsRadio: Finish will set a network key on a radio that is neither blocked nor switched off by hand (a radio
// that will not come up is not waited for, review B m5).
func (n *Node) finishWantsRadio() bool {
	rec, e := n.resolve()
	if e != nil {
		return false
	}
	tx, ok := provstore.ReadTxn(n.P)
	if rec.State != provstore.Member && !rec.Left && (!ok || tx.PrevKey == placeholderKey) {
		return false
	}
	w, err := n.desired(rec, tx, ok)
	if err != nil || w.kind == wantForget {
		return false
	}
	dis, _, err := n.Sys.RadioState()
	return err == nil && !dis
}
