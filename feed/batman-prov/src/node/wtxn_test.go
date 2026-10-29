package node

import (
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"strings"
	"testing"

	"golang.org/x/crypto/chacha20poly1305"

	"batman-prov/cbor"
	"batman-prov/cose"
	"batman-prov/proto"
	"batman-prov/provstore"
)

// docs/design/254-wireless-txn.md §8 / §11: a wireless change that did not succeed returns the node to the previous
// state; .txn never deadlocks the saves. The crash states are built the way a power loss leaves them (the record on
// p5 / overlay, .txn with its snapshot, the live wireless) and the helper is "restarted" (a new Node on the same files).

// ---- real signed / encrypted network objects (219 §7) ----------------------------------------------------------------

func sign1(t *testing.T, key *ecdsa.PrivateKey, ct, label string, payload cbor.Map) any {
	t.Helper()
	prot, _ := cbor.Encode(cbor.M(1, int64(-7), 3, ct))
	pl, _ := cbor.Encode(payload)
	ss, _ := cbor.Encode([]any{"Signature1", prot, []byte(label), pl})
	sig, err := proto.SignES256(key, ss)
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := cbor.Encode(cbor.Tag{Num: 18, V: []any{prot, cbor.Map{}, pl, sig}})
	x, err := cbor.Decode(raw)
	if err != nil {
		t.Fatal(err)
	}
	return x
}

func objHash(t *testing.T, item any) []byte {
	s, err := cose.Sign1Payload(item, cose.CTNetcfg, proto.LabelNetcfg)
	if err != nil {
		t.Fatal(err)
	}
	return s.ObjectHash
}

type netv struct {
	nid     []byte
	ver     uint64
	meshID  string
	ch      uint64
	sae     string
	admins  []*ecdsa.PrivateKey // this version's admin set (key 8)
	signer  *ecdsa.PrivateKey   // signs the config and the secrets (the previous version's admin; v1: self)
	prev    any                 // the previous config (for key 3)
	cfg     any
	secrets any
}

func (r *rig) mkNet(v *netv) *netv {
	t := r.t
	var ad []any
	for _, k := range v.admins {
		ad = append(ad, pub(k))
	}
	pl := cbor.M(1, v.nid, 2, v.ver, 6, cbor.M(1, v.meshID, 2, v.ch), 8, ad)
	if v.prev != nil {
		pl = cbor.M(1, v.nid, 2, v.ver, 3, objHash(t, v.prev), 6, cbor.M(1, v.meshID, 2, v.ch), 8, ad)
	}
	v.cfg = sign1(t, v.signer, cose.CTNetcfg, proto.LabelNetcfg, pl)
	// net_secrets: COSE_Encrypt to this node (ECDH-ES + HKDF-256, ChaCha20/Poly1305), as cose.Decrypt opens it
	dacHash := sha256.Sum256(r.ks.DACPub())
	other := append(append([]byte(nil), v.nid...), byte(v.ver>>24), byte(v.ver>>16), byte(v.ver>>8), byte(v.ver))
	eph, _ := ecdh.P256().GenerateKey(rand.Reader)
	z, err := proto.ECDHX(eph, r.ks.ECDHPub())
	if err != nil {
		t.Fatal(err)
	}
	rprot, _ := cbor.Encode(cbor.M(1, int64(-25)))
	cek := proto.HKDF32(z, cose.KDFContext(dacHash[:], rprot, other))
	prot, _ := cbor.Encode(cbor.M(1, uint64(24)))
	aad, _ := cbor.Encode([]any{"Encrypt", prot, []byte(proto.LabelSecrets)})
	aead, _ := chacha20poly1305.New(cek)
	iv := rnd(chacha20poly1305.NonceSize)
	pt, _ := cbor.Encode(cbor.M(1, []byte(v.sae), 2, make32(9)))
	ep := eph.PublicKey().Bytes()
	enc := cbor.Tag{Num: 96, V: []any{prot, cbor.M(5, iv), aead.Seal(nil, iv, pt, aad),
		[]any{[]any{rprot, cbor.M(int64(-1), cbor.M(1, uint64(2), int64(-1), uint64(1), int64(-2), ep[1:33], int64(-3), ep[33:])), []byte{}}}}}
	v.secrets = sign1(t, v.signer, cose.CTSecrets, proto.LabelSecrets, cbor.M(1, v.nid, 2, v.ver, 3, dacHash[:], 4, enc))
	return v
}

func newKey() *ecdsa.PrivateKey { k, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader); return k }

func (r *rig) v1Net() *netv {
	a := newKey()
	return r.mkNet(&netv{nid: make32(4)[:16], ver: 1, meshID: "m1", ch: 28, sae: "sae-v1-pass", admins: []*ecdsa.PrivateKey{a}, signer: a})
}

func (r *rig) applyJoin(v *netv) int {
	c, _ := r.call("net.apply", cbor.M(1, r.h, 2, r.envelope("network/join", cbor.M(1, v.cfg, 3, v.secrets), r.owner)))
	return c
}

func (r *rig) applyUpdate(chain []any, sec any) int {
	raw, _ := cbor.Encode(cbor.M(0, []any{uint64(1), uint64(0)}, 1, uint64(9), 2, "network/update", 3, cbor.M(1, chain, 2, sec)))
	c, _ := r.call("net.apply", cbor.M(1, r.h, 2, raw))
	return c
}

func (r *rig) leave() int {
	c, _ := r.call("network.leave", cbor.M(1, r.h, 2, r.envelope("network/leave", cbor.M(), r.owner)))
	return c
}

func (r *rig) sshSet() int {
	c, _ := r.call("ssh_keys.set", cbor.M(1, r.h, 2, r.envelope("ssh_keys/set", cbor.M(1, []any{"ssh-ed25519 AAAAx o"}), r.owner)))
	return c
}

func (r *rig) ownerAdd() int {
	o, e := newKey(), newKey()
	se, _ := proto.SignES256(o, append([]byte(proto.LabelOwnerEnc), pub(e)...))
	c, _ := r.call("owner.add", cbor.M(1, r.h, 2, r.envelope("owner/add", cbor.M(1, pub(o), 2, pub(e), 3, se), r.owner)))
	return c
}

func (r *rig) rec() *provstore.Record {
	rec, _, err := provstore.LoadOverlay(r.n.P)
	if err != nil || rec == nil {
		r.t.Fatalf("overlay: %v", err)
	}
	return rec
}

// restart = the helper starts again on the same files (a power loss: the run-dir marker is gone)
func (r *rig) restart() {
	r.sys.txnMarker = false
	n := New(r.n.P, r.ks, r.sys, r.n.Log)
	n.Verdict = r.n.Verdict
	r.n = n
}

func (r *rig) wl() string { k, id, ch, _ := r.sys.CurrentWireless(); return k + "/" + id + "/" + ch }

// memberRig: claimed, joined v1 (mesh m1, channel 28) with real objects through the dispatcher
func memberRig(t *testing.T) (*rig, *netv) {
	r := claimedRig(t)
	v1 := r.v1Net()
	if c := r.applyJoin(v1); c != OK {
		t.Fatalf("join v1: %d", c)
	}
	if rec := r.rec(); rec.State != provstore.Member || provstore.TxnPresent(r.n.P) || r.wl() != "sae-v1-pass/m1/28" {
		t.Fatalf("after join: %s txn=%v wl=%s", rec.State, provstore.TxnPresent(r.n.P), r.wl())
	}
	return r, v1
}

const crashTok = "abababababababababababababababab"

// crashTxn2 builds the state a power loss at txn-2 leaves: .txn (snapshot = the live wireless before), the live
// wireless changed to the new values, the record unchanged; then the helper restarts.
func (r *rig) crashTxn2(newKey, newID, newCh string) {
	k, id, ch, _ := r.sys.CurrentWireless()
	rec := r.rec()
	if err := provstore.WriteTxn(r.n.P, crashTok, rec.Generation, rec.Generation+1, "network/join", k, id, ch, r.sys.radioOff); err != nil {
		r.t.Fatal(err)
	}
	r.sys.wl = [3]string{newKey, newID, newCh}
	r.restart()
}

func (r *rig) finishedCleanly(want string) {
	r.t.Helper()
	if provstore.TxnPresent(r.n.P) {
		r.t.Fatal(".txn left after Finish")
	}
	if r.wl() != want {
		r.t.Fatalf("wireless %s, want %s", r.wl(), want)
	}
	if len(r.sys.saveTxns) == 0 || r.sys.saveTxns[len(r.sys.saveTxns)-1] != crashTok {
		r.t.Fatalf("no save under the transaction's token: %v", r.sys.saveTxns)
	}
	if r.sys.saveTxnNoMark != 0 {
		r.t.Fatalf("SaveTxn ran %d time(s) without the run-dir marker (config-save refuses it)", r.sys.saveTxnNoMark)
	}
	if r.sys.txnMarker {
		r.t.Fatal("run-dir marker left set")
	}
}

// ---- §8 rows ------------------------------------------------------------------------------------------------------

// power loss mid update (member): Finish -> the record's network
func TestFinishMemberBackToRecord(t *testing.T) {
	r, _ := memberRig(t)
	r.crashTxn2("sae-v2-pass", "m2", "36")
	if !r.n.FinishWantsRadio() {
		t.Fatal("a network to rejoin must wait for the radio")
	}
	if err := r.n.Finish("boot"); err != nil {
		t.Fatal(err)
	}
	r.finishedCleanly("sae-v1-pass/m1/28")
	if r.sys.meshExpect != "radio" {
		t.Fatalf("mesh_expect %q", r.sys.meshExpect)
	}
}

// power loss mid join, legacy / operator key (04's S0): Finish -> the snapshot (the operator's settings). The mutant
// "always forget" fails here (review B r5 m5).
func TestFinishJoinBackToOperatorSnapshot(t *testing.T) {
	r := claimedRig(t)
	r.sys.wl = [3]string{"operator-key", "opmesh", "36"}
	r.crashTxn2("sae-v1-pass", "m1", "28")
	if err := r.n.Finish("boot"); err != nil {
		t.Fatal(err)
	}
	r.finishedCleanly("operator-key/opmesh/36")
	if r.sys.forgets != 0 {
		t.Fatal("forgot the operator's network")
	}
}

// power loss mid join, fresh / left node (placeholder snapshot): Finish -> forgotten
func TestFinishJoinFromPlaceholderForgets(t *testing.T) {
	r := claimedRig(t)
	r.sys.wl = [3]string{placeholderKey, "", ""}
	r.sys.radioOff, r.sys.inMark = true, true
	r.crashTxn2("sae-v1-pass", "m1", "28")
	r.sys.radioOff, r.sys.inMark = false, false // setkey unblocked the radio
	if r.n.FinishWantsRadio() {
		t.Fatal("a forget waits for the radio")
	}
	if err := r.n.Finish("boot"); err != nil {
		t.Fatal(err)
	}
	if r.sys.forgets != 1 || !r.sys.radioOff || !r.sys.inMark {
		t.Fatalf("not forgotten: forgets=%d off=%v mark=%v", r.sys.forgets, r.sys.radioOff, r.sys.inMark)
	}
	r.finishedCleanly(placeholderKey + "//")
	if r.sys.meshExpect != "0" {
		t.Fatalf("mesh_expect %q", r.sys.meshExpect)
	}
}

// commit landed (p5 = new record), the save did not (txn-4): Finish keeps the new network, no re-apply, saves
func TestFinishAfterCommitKeepsNew(t *testing.T) {
	r := claimedRig(t)
	v1 := r.v1Net()
	r.sys.saveTxnOut = []saveRC{{1, "power loss"}}
	if c := r.applyJoin(v1); c != OK {
		t.Fatalf("join: %d", c)
	}
	if !provstore.TxnPresent(r.n.P) {
		t.Fatal(".txn removed although the save failed")
	}
	tok := r.sys.saveTxns[0]
	r.restart()
	sk := len(r.sys.setkeys)
	if err := r.n.Finish("boot"); err != nil {
		t.Fatal(err)
	}
	if len(r.sys.setkeys) != sk {
		t.Fatal("re-applied a wireless that already is the record's")
	}
	if provstore.TxnPresent(r.n.P) || r.wl() != "sae-v1-pass/m1/28" || r.sys.saveTxns[len(r.sys.saveTxns)-1] != tok || r.sys.saveTxnNoMark != 0 {
		t.Fatalf("txn=%v wl=%s saves=%v nomark=%d", provstore.TxnPresent(r.n.P), r.wl(), r.sys.saveTxns, r.sys.saveTxnNoMark)
	}
}

// power loss between the save and RemoveTxn: Finish again is idempotent (no setkey), saves, removes .txn
func TestFinishIdempotentAfterSave(t *testing.T) {
	r, _ := memberRig(t)
	r.crashTxn2("sae-v1-pass", "m1", "28") // the live wireless already is the record's
	sk := len(r.sys.setkeys)
	if err := r.n.Finish("boot"); err != nil {
		t.Fatal(err)
	}
	if len(r.sys.setkeys) != sk {
		t.Fatal("setkey on a satisfied wireless")
	}
	r.finishedCleanly("sae-v1-pass/m1/28")
}

// the shipped deadlock: Finish fails (dead radio) -> .txn kept, marker cleared; owner.add (commit-only) still works,
// a saving verb is refused with EState; once the radio works the next saving verb finishes first
func TestDeadRadioCommitOnlyWorksSavingRefused(t *testing.T) {
	r, _ := memberRig(t)
	r.crashTxn2("sae-v2-pass", "m2", "36")
	r.sys.setkeyErrs = []error{&SetkeyError{RC: 3, Msg: "unverified"}, &SetkeyError{RC: 3, Msg: "unverified"}}
	if err := r.n.Finish("boot"); err == nil {
		t.Fatal("Finish succeeded with a dead radio")
	}
	if !provstore.TxnPresent(r.n.P) || r.sys.txnMarker {
		t.Fatalf("txn=%v marker=%v: want .txn kept, the marker cleared", provstore.TxnPresent(r.n.P), r.sys.txnMarker)
	}
	if c := r.ownerAdd(); c != OK {
		t.Fatalf("owner.add with an unfinished change: %d", c)
	}
	if c := r.sshSet(); c != EState {
		t.Fatalf("ssh_keys.set with a dead radio: %d (want EState)", c)
	}
	if c := r.sshSet(); c != OK { // the radio works again: Finish first, then the verb
		t.Fatalf("ssh_keys.set after the radio came back: %d", c)
	}
	r.finishedCleanly("sae-v1-pass/m1/28")
}

// another verb while .txn exists: a saving verb finishes first (the operator snapshot comes back before the save)
func TestSavingVerbFinishesFirst(t *testing.T) {
	r := claimedRig(t)
	r.sys.wl = [3]string{"operator-key", "opmesh", "36"}
	r.crashTxn2("sae-v1-pass", "m1", "28")
	saves := r.sys.saves
	if c := r.sshSet(); c != OK {
		t.Fatalf("ssh_keys.set: %d", c)
	}
	r.finishedCleanly("operator-key/opmesh/36")
	if r.sys.saves == saves {
		t.Fatal("ssh_keys.set did not save")
	}
}

// commit-only verbs never Finish (the wireless stays as it is, .txn kept)
func TestCommitOnlyDoesNotFinish(t *testing.T) {
	r, _ := memberRig(t)
	r.crashTxn2("sae-v2-pass", "m2", "36")
	sk := len(r.sys.setkeys)
	if c := r.ownerAdd(); c != OK {
		t.Fatalf("owner.add: %d", c)
	}
	if len(r.sys.setkeys) != sk || !provstore.TxnPresent(r.n.P) {
		t.Fatal("owner.add finished the wireless change")
	}
}

// commit landed in p5, the overlay write failed (overlay older than p5): owner.add commits on p5's record
func TestCommitOnlyResolvesStaleOverlay(t *testing.T) {
	r, _ := memberRig(t)
	p5 := r.rec()
	stale := *p5
	stale.Generation--
	stale.State, stale.Net, stale.Admins, stale.Members = provstore.Claimed, nil, nil, nil
	if _, _, err := provstore.WriteOverlay(r.n.P, &stale); err != nil {
		t.Fatal(err)
	}
	if c := r.ownerAdd(); c != OK {
		t.Fatalf("owner.add: %d", c)
	}
	if rec := r.rec(); rec.State != provstore.Member || rec.Generation != p5.Generation+1 || rec.Net == nil {
		t.Fatalf("owner.add committed on the stale overlay: %s gen %d", rec.State, rec.Generation)
	}
}

// p5 unreadable: nothing is finished against an unconfirmed record; .txn kept, retried later
func TestFinishP5UnreadableKeepsTxn(t *testing.T) {
	r, _ := memberRig(t)
	r.crashTxn2("sae-v2-pass", "m2", "36")
	r.sys.p5rc = 1
	sk := len(r.sys.setkeys)
	if err := r.n.Finish("boot"); err == nil {
		t.Fatal("Finish with p5 unreadable")
	}
	if !provstore.TxnPresent(r.n.P) || len(r.sys.setkeys) != sk || r.sys.txnMarker {
		t.Fatalf("txn=%v setkeys=%d marker=%v", provstore.TxnPresent(r.n.P), len(r.sys.setkeys)-sk, r.sys.txnMarker)
	}
	r.sys.p5rc = 0
	if err := r.n.Finish("boot"); err != nil {
		t.Fatal(err)
	}
	r.finishedCleanly("sae-v1-pass/m1/28")
}

// setkey rc 2 (nothing changed): .txn removed, nothing else
func TestJoinSetkeyRC2(t *testing.T) {
	r := claimedRig(t)
	v1 := r.v1Net()
	r.sys.setkeyErrs = []error{&SetkeyError{RC: 2, Msg: "busy"}}
	if c := r.applyJoin(v1); c != EApply {
		t.Fatalf("join: %d", c)
	}
	if provstore.TxnPresent(r.n.P) || len(r.sys.saveTxns) != 0 || r.rec().State != provstore.Claimed || r.sys.txnMarker {
		t.Fatal("setkey rc 2 left state behind")
	}
}

// setkey failed after changing something (rc 3): Finish puts the previous state back at once
func TestJoinSetkeyRC3Finishes(t *testing.T) {
	r := claimedRig(t)
	r.sys.wl = [3]string{"operator-key", "opmesh", "36"}
	v1 := r.v1Net()
	r.sys.setkeyErrs = []error{&SetkeyError{RC: 3, Msg: "unverified"}}
	r.sys.setkeyHalf = true
	if c := r.applyJoin(v1); c != EApply {
		t.Fatalf("join: %d", c)
	}
	if provstore.TxnPresent(r.n.P) || r.wl() != "operator-key/opmesh/36" || r.rec().State != provstore.Claimed {
		t.Fatalf("txn=%v wl=%s", provstore.TxnPresent(r.n.P), r.wl())
	}
}

// join on a radio switched off by hand: refused up front, nothing changed
func TestJoinRadioOffByHand(t *testing.T) {
	r := claimedRig(t)
	r.sys.radioOff = true
	v1 := r.v1Net()
	if c := r.applyJoin(v1); c != EApply {
		t.Fatalf("join: %d", c)
	}
	if len(r.sys.setkeys) != 0 || provstore.TxnPresent(r.n.P) || r.rec().State != provstore.Claimed {
		t.Fatal("something changed")
	}
}

// admin handover: v2 hands the network to new admins; updates and psks keep working, and so does a Finish with .txn
func TestHandoverStoredObjectsNotReverified(t *testing.T) {
	r, v1 := memberRig(t)
	b := newKey()
	v2 := r.mkNet(&netv{nid: v1.nid, ver: 2, meshID: "m2", ch: 36, sae: "sae-v2-pass", admins: []*ecdsa.PrivateKey{b}, signer: v1.admins[0], prev: v1.cfg})
	if c := r.applyUpdate([]any{v2.cfg}, v2.secrets); c != OK {
		t.Fatalf("update v2: %d", c)
	}
	if r.n.netRoot(r.rec()) == nil {
		t.Fatal("net_root unreadable after the handover (psks.get would fail)")
	}
	v3 := r.mkNet(&netv{nid: v1.nid, ver: 3, meshID: "m3", ch: 28, sae: "sae-v3-pass", admins: []*ecdsa.PrivateKey{b}, signer: b, prev: v2.cfg})
	if c := r.applyUpdate([]any{v3.cfg}, v3.secrets); c != OK {
		t.Fatalf("update v3 after the handover: %d", c)
	}
	if r.wl() != "sae-v3-pass/m3/28" {
		t.Fatalf("wl %s", r.wl())
	}
	r.crashTxn2("sae-v4-pass", "m4", "36")
	if err := r.n.Finish("boot"); err != nil {
		t.Fatalf("Finish after the handover: %v", err)
	}
	r.finishedCleanly("sae-v3-pass/m3/28")
}

// network/leave (L22) forgets the network; Left is recorded; a join clears it
func TestLeaveForgets(t *testing.T) {
	r, _ := memberRig(t)
	if c := r.leave(); c != OK {
		t.Fatalf("leave: %d", c)
	}
	rec := r.rec()
	if rec.State != provstore.Claimed || !rec.Left || rec.Net != nil || r.sys.forgets != 1 || provstore.TxnPresent(r.n.P) {
		t.Fatalf("leave: %s left=%v forgets=%d txn=%v", rec.State, rec.Left, r.sys.forgets, provstore.TxnPresent(r.n.P))
	}
	if r.wl() != placeholderKey+"//" || r.sys.meshExpect != "0" || r.sys.saveTxnNoMark != 0 || len(r.sys.saveTxns) < 2 {
		t.Fatalf("wl %s mesh_expect %q saves %v", r.wl(), r.sys.meshExpect, r.sys.saveTxns)
	}
	c, res := r.call("info.net", cbor.M())
	if l, _ := res.Get(3); c != OK || l != true {
		t.Fatalf("info.net after leave: %d %v", c, res)
	}
	a := newKey()
	v := r.mkNet(&netv{nid: make32(5)[:16], ver: 1, meshID: "n1", ch: 36, sae: "sae-n1-pass", admins: []*ecdsa.PrivateKey{a}, signer: a})
	if c := r.applyJoin(v); c != OK {
		t.Fatalf("rejoin: %d", c)
	}
	if rec := r.rec(); rec.Left || rec.State != provstore.Member || r.wl() != "sae-n1-pass/n1/36" {
		t.Fatalf("rejoin: left=%v %s wl=%s", rec.Left, rec.State, r.wl())
	}
}

// leave committed, forgetting failed: the app is told; the next Finish forgets (the record says Left)
func TestLeaveForgetFailsThenFinishForgets(t *testing.T) {
	r, _ := memberRig(t)
	r.sys.forgetErr = &SetkeyError{RC: 3, Msg: "radio still up"}
	if c := r.leave(); c != EApply {
		t.Fatalf("leave: %d", c)
	}
	if !provstore.TxnPresent(r.n.P) || !r.rec().Left {
		t.Fatal("want committed Left + .txn kept")
	}
	r.sys.forgetErr = nil
	r.restart()
	if err := r.n.Finish("boot"); err != nil {
		t.Fatal(err)
	}
	if provstore.TxnPresent(r.n.P) || r.wl() != placeholderKey+"//" || r.sys.forgets != 2 {
		t.Fatalf("txn=%v wl=%s forgets=%d", provstore.TxnPresent(r.n.P), r.wl(), r.sys.forgets)
	}
}

// leave whose commit fails (power loss before the commit): the record is still member, the network stays
func TestLeaveBeforeCommitBackToNetwork(t *testing.T) {
	r, _ := memberRig(t)
	r.sys.persistRC = 1
	if c := r.leave(); c == OK {
		t.Fatal("leave succeeded without a commit")
	}
	r.sys.persistRC = 0
	if r.rec().State != provstore.Member || provstore.TxnPresent(r.n.P) || r.wl() != "sae-v1-pass/m1/28" || r.sys.forgets != 0 {
		t.Fatalf("state %s txn=%v wl=%s", r.rec().State, provstore.TxnPresent(r.n.P), r.wl())
	}
}

// commit landed, reply lost, the app retries: the retry is answered "already" and info.net shows the version
func TestRetryAfterLostReply(t *testing.T) {
	r, v1 := memberRig(t)
	if c := r.applyJoin(v1); c != EStaleVersion {
		t.Fatalf("retried join: %d", c)
	}
	c, res := r.call("info.net", cbor.M())
	nid, _ := res.Get(1)
	ver, _ := res.Get(2)
	nb, _ := nid.([]byte)
	if c != OK || ver != uint64(1) || string(nb) != string(v1.nid) {
		t.Fatalf("info.net: %d %v", c, res)
	}
}

// a .txn without a readable token: Finish refuses (fail-closed), saves stay blocked, commit-only verbs still work
func TestMalformedTxnFailsClosed(t *testing.T) {
	r, _ := memberRig(t)
	if err := provstore.WriteTxn(r.n.P, "short", 1, 2, "x", "", "", "", false); err != nil {
		t.Fatal(err)
	}
	r.restart()
	if err := r.n.Finish("boot"); err == nil {
		t.Fatal("Finish accepted a .txn without a valid token")
	}
	if c := r.sshSet(); c != EState {
		t.Fatalf("ssh_keys.set: %d", c)
	}
	if c := r.ownerAdd(); c != OK {
		t.Fatalf("owner.add: %d", c)
	}
	_ = strings.TrimSpace
}
