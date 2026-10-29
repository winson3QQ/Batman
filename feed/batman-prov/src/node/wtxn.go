package node

import (
	"crypto/sha256"
	"crypto/subtle"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

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

// desired = the previous state for this record (§2).
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
		return wantWireless{}, errors.New("the pre-change snapshot in .txn is unreadable")
	}
	if tx.PrevKey == "" || tx.PrevKey == placeholderKey {
		return wantWireless{kind: wantForget, source: "the pre-change snapshot (placeholder)", fromSnapshot: true}, nil
	}
	return wantWireless{kind: wantNet, key: tx.PrevKey, id: tx.PrevID, ch: tx.PrevChannel,
		source: "the pre-change snapshot", fromSnapshot: true}, nil
}

// satisfied: the live wireless already is the wanted one (no re-apply, no wifi reload — review A r4 m1).
func (n *Node) satisfied(w wantWireless) bool {
	key, id, ch, err := n.Sys.CurrentWireless()
	if err != nil {
		return false
	}
	dis, inMark, err := n.Sys.RadioState()
	if err != nil {
		return false
	}
	if w.kind == wantForget {
		return key == placeholderKey && dis && inMark
	}
	return key == w.key && (w.id == "" || id == w.id) && (w.ch == "" || ch == w.ch) && !(dis && inMark)
}

// resolve decides the committed record the way --boot does (p5 vs the overlay), with no side effect beyond
// rewriting a stale overlay from p5. p5 unreadable -> an error: nothing may be finished against a record p5 did not
// confirm (review B r4 MAJOR-1).
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
		if r, err := provstore.Decode(b); err == nil {
			p5 = r
		}
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
	tx, txOK := provstore.ReadTxn(n.P)
	tok := provstore.TxnToken(n.P)
	if tok == "" {
		n.Log("CRIT finish (%s): .txn has no readable token — left for the owner's next network change", why)
		return fail(EState, ".txn unreadable")
	}
	if err := n.Sys.WriteTxnMarker(tok); err != nil {
		return fail(EApply, "txn marker: %v", err)
	}
	defer n.Sys.ClearTxnMarker()
	rec, e := n.resolve()
	if e != nil {
		n.Log("finish (%s): %s — the unfinished change is finished at the next boot", why, e.Reason)
		return e
	}
	w, err := n.desired(rec, tx, txOK)
	if err != nil {
		n.Log("CRIT finish (%s): %v — .txn kept, saves stay blocked", why, err)
		return fail(EState, "%v", err)
	}
	src := 0
	if !n.satisfied(w) {
		if w.kind == wantForget {
			err = n.Sys.ForgetMesh()
		} else {
			err = n.Sys.SetKeyNoPersist(w.key, w.id, w.ch)
		}
		src = setkeyRC(err)
		if err != nil {
			n.Log("CRIT finish (%s): back to %s failed (%v) — .txn kept, saves stay blocked", why, w.source, err)
			return fail(EApply, "%v", err)
		}
	}
	if w.kind == wantForget {
		if err := n.Sys.RemoveMeshMarkers(); err != nil {
			n.Log("finish: mesh markers: %v", err)
		}
	}
	if w.fromSnapshot && txOK && tx.HasRadio {
		// a restore never writes `disabled` (§2); an operator switching the radio meanwhile is logged, not undone
		if dis, _, err := n.Sys.RadioState(); err == nil && dis != tx.PrevDisabled {
			n.Log("CRIT finish: the radio's disabled flag changed by hand during the change (%v -> %v) — kept", tx.PrevDisabled, dis)
		}
	}
	rc, out := n.Sys.SaveTxn(tok)
	if rc != 0 && rc != 6 {
		n.Log("finish (%s): save rc=%d (%s) — .txn kept, finished again at the next boot", why, rc, strings.TrimSpace(out))
		return fail(EStorage, "save rc=%d", rc)
	}
	provstore.RemoveTxn(n.P)
	n.refreshMeshExpect(rec)
	verb := tx.Verb
	if !txOK {
		verb = "?"
	}
	n.Log("txn %s finished (%s): wireless = %s, setkey rc=%d save rc=%d", verb, why, w.source, src, rc)
	return nil
}

// refreshMeshExpect: prov-state's mesh_expect follows the finished state (review A r4 m3).
func (n *Node) refreshMeshExpect(rec *provstore.Record) {
	me := boot.MeshExpect(rec.State, func() string { k, _, _, _ := n.Sys.CurrentWireless(); return k })
	if err := n.Sys.SetMeshExpect(me); err != nil {
		n.Log("prov-state mesh_expect: %v", err)
	}
}

// Finish is finish under the node's mutex, for the daemon before it serves (§3).
func (n *Node) Finish(why string) error {
	n.mu.Lock()
	defer n.mu.Unlock()
	if e := n.finish(why); e != nil {
		return errors.New(e.Reason)
	}
	return nil
}

// FinishWantsRadio: Finish will set a network key on a radio that is not blocked (wait for it to come up first).
func (n *Node) FinishWantsRadio() bool {
	n.mu.Lock()
	defer n.mu.Unlock()
	rec, e := n.resolve()
	if e != nil {
		return false
	}
	tx, ok := provstore.ReadTxn(n.P)
	w, err := n.desired(rec, tx, ok)
	if err != nil || w.kind == wantForget {
		return false
	}
	dis, inMark, err := n.Sys.RadioState()
	return err == nil && !(dis && inMark)
}
