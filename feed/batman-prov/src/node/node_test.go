package node

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"batman-prov/cbor"
	"batman-prov/keystore"
	"batman-prov/proto"
	"batman-prov/provstore"
)

type fakeSys struct {
	trial, devOpen bool
	keys           []string
	persisted      []uint64
	p5             string // fake p5 meta dir
	locked         string
	saves          int
	now            time.Time
	setkeys        []string
	persistRC      int
}

func (f *fakeSys) IsTrial() bool { return f.trial }
func (f *fakeSys) Persist(r, m, id, txn string) (int, string) {
	if f.persistRC != 0 {
		return f.persistRC, "fail"
	}
	b, _ := os.ReadFile(m)
	os.MkdirAll(f.p5, 0o700)
	os.WriteFile(filepath.Join(f.p5, "prov.meta"), b, 0o600)
	mm, _ := provstore.ParseMeta(b)
	f.persisted = append(f.persisted, mm.Gen)
	return 0, ""
}
func (f *fakeSys) GetP5(dir string) (int, string) {
	os.MkdirAll(dir, 0o700)
	b, err := os.ReadFile(filepath.Join(f.p5, "prov.meta"))
	if err != nil {
		return 9, ""
	}
	os.WriteFile(filepath.Join(dir, "prov.meta"), b, 0o600)
	return 0, ""
}
func (f *fakeSys) Save() (int, string) { f.saves++; return 0, "" }
func (f *fakeSys) SetKeyNoPersist(k, id, ch string) error {
	f.setkeys = append(f.setkeys, id+"/"+ch)
	return nil
}
func (f *fakeSys) CurrentWireless() (string, string, string, error) {
	return "oldkey123", "oldmesh", "28", nil
}
func (f *fakeSys) ApplyLock(h string) error                { f.locked = h; return nil }
func (f *fakeSys) CryptPassword(pw string) (string, error) { return "$6$x$" + pw, nil }
func (f *fakeSys) AuthorizedKeys() ([]string, error)       { return f.keys, nil }
func (f *fakeSys) SetAuthorizedKeys(l []string) error      { f.keys = l; return nil }
func (f *fakeSys) DevOpen() bool                           { return f.devOpen }
func (f *fakeSys) WriteTxnMarker(string) error             { return nil }
func (f *fakeSys) ClearTxnMarker()                         {}
func (f *fakeSys) DiagBundle() ([]byte, error)             { return []byte("diag"), nil }
func (f *fakeSys) RemoveMeshMarkers() error                { return nil }
func (f *fakeSys) Now() time.Time                          { return f.now }

type rig struct {
	t     *testing.T
	n     *Node
	sys   *fakeSys
	ks    *keystore.Keystore
	ksDir string
	owner *ecdsa.PrivateKey
	enc   *ecdsa.PrivateKey
	h     []byte
	id    uint64
}

func newRig(t *testing.T, state string) *rig {
	root := t.TempDir()
	p := provstore.Paths{Dir: filepath.Join(root, "prov"), RunDir: filepath.Join(root, "run")}
	os.MkdirAll(p.RunDir, 0o700)
	os.MkdirAll(p.Dir, 0o700)
	if err := keystore.Generate(p.Identity()); err != nil {
		t.Fatal(err)
	}
	ks, err := keystore.Load(p.Identity())
	if err != nil {
		t.Fatal(err)
	}
	provstore.WriteOverlay(p, &provstore.Record{Generation: 1, State: state})
	sys := &fakeSys{p5: filepath.Join(root, "p5"), now: time.Unix(1000, 0), keys: []string{"ssh-ed25519 AAAAlab lab"}}
	o, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	e, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	return &rig{t: t, n: New(p, ks, sys, func(string, ...any) {}), sys: sys, ks: ks, ksDir: p.Identity(), owner: o, enc: e, h: make32(7)}
}

func make32(c byte) []byte {
	b := make([]byte, 32)
	for i := range b {
		b[i] = c
	}
	return b
}
func pub(k *ecdsa.PrivateKey) []byte { b, _ := k.PublicKey.Bytes(); return b }

func (r *rig) call(verb string, args cbor.Map) (int, cbor.Map) {
	r.id++
	// through the wire format, as the socket server does: encode, then strict decode
	raw, err := cbor.Encode(cbor.M(1, verb, 2, r.id, 3, args))
	if err != nil {
		r.t.Fatal(err)
	}
	dec, err := cbor.Decode(raw)
	if err != nil {
		r.t.Fatal(err)
	}
	resp := r.n.Handle(dec.(cbor.Map))
	c, _ := resp.Get(2)
	res, _ := resp.Get(3)
	return int(c.(uint64)), res.(cbor.Map)
}

func (r *rig) nonce() (node, helper []byte) {
	c, res := r.call("nonce", cbor.M(1, r.h))
	if c != OK {
		r.t.Fatal("nonce")
	}
	a, _ := res.Get(1)
	b, _ := res.Get(2)
	return a.([]byte), b.([]byte)
}

func (r *rig) claimResp(nonceNode []byte, ownerPub []byte) []byte {
	k, _ := os.ReadFile(filepath.Join(r.ksDir, "claim.secret"))
	in, _ := proto.CheckMacInput(k, proto.ClientChal(nonceNode, r.h, r.ks.Cert(), ownerPub), r.ks.SN())
	s := sha256.Sum256(in)
	return s[:]
}

func (r *rig) claim() (int, cbor.Map) {
	nn, _ := r.nonce()
	se, _ := proto.SignES256(r.enc, append([]byte(proto.LabelOwnerEnc), pub(r.enc)...))
	se, _ = proto.SignES256(r.owner, append([]byte(proto.LabelOwnerEnc), pub(r.enc)...))
	return r.call("claim.verify", cbor.M(1, r.h, 2, r.claimResp(nn, pub(r.owner)), 3, pub(r.owner), 4, pub(r.enc), 5, se))
}

func (r *rig) envelope(typ string, body cbor.Map, signer *ecdsa.PrivateKey) []byte {
	_, nh := r.nonce()
	ah, _ := proto.ArgsHash(body)
	in, _ := proto.OwnerOpInput(r.h, nh, typ, ah)
	sig, _ := proto.SignES256(signer, in)
	b := append(cbor.Map(nil), body...)
	b = append(b, cbor.Entry{K: uint64(31), V: cbor.M(1, typ, 2, sig)})
	raw, _ := cbor.Encode(cbor.M(0, []any{uint64(1), uint64(0)}, 1, uint64(9), 2, typ, 3, b))
	return raw
}

func TestClaimUnclaimed(t *testing.T) {
	r := newRig(t, provstore.Unclaimed)
	c, res := r.claim()
	if c != OK {
		t.Fatalf("claim code %d", c)
	}
	pw, _ := res.Get(3)
	if len(pw.(string)) != 24 || !strings.HasSuffix(r.sys.locked, pw.(string)) || r.sys.saves != 1 {
		t.Fatal("lock / password")
	}
	rec, _, _ := provstore.LoadOverlay(r.n.P)
	if rec.State != provstore.Claimed || rec.Generation != 2 || !rec.RadioManaged || len(r.sys.persisted) != 1 {
		t.Fatalf("record %+v", rec)
	}
	// a second claim of a claimed node is refused
	if c, _ := r.claim(); c != EForbidden {
		t.Fatalf("re-claim code %d", c)
	}
}

func TestClaimRejectsAnotherOwnerPub(t *testing.T) {
	r := newRig(t, provstore.Unclaimed)
	nn, _ := r.nonce()
	attacker, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	se, _ := proto.SignES256(attacker, append([]byte(proto.LabelOwnerEnc), pub(r.enc)...))
	// the buyer's response (bound to the buyer's owner_pub) with the attacker's owner_pub
	c, _ := r.call("claim.verify", cbor.M(1, r.h, 2, r.claimResp(nn, pub(r.owner)), 3, pub(attacker), 4, pub(r.enc), 5, se))
	if c != EForbidden {
		t.Fatalf("code %d", c)
	}
}

func TestLegacyGateAfterCheckMac(t *testing.T) {
	r := newRig(t, provstore.Legacy)
	r.sys.keys = nil
	if c, _ := r.claim(); c != EUnsupported {
		t.Fatalf("no-ssh-key: code %d", c)
	}
	// without the claim secret (wrong response) the answer is E_FORBIDDEN, not the gate's (no probing, 219 §5.3)
	nn, _ := r.nonce()
	_ = nn
	se, _ := proto.SignES256(r.owner, append([]byte(proto.LabelOwnerEnc), pub(r.enc)...))
	if c, _ := r.call("claim.verify", cbor.M(1, r.h, 2, make32(1), 3, pub(r.owner), 4, pub(r.enc), 5, se)); c != EForbidden {
		t.Fatalf("wrong response: code %d", c)
	}
	r.sys.devOpen = true
	if c, res := r.claim(); c != OK {
		t.Fatalf("dev-open claim: %d", c)
	} else if rec, _, _ := provstore.LoadOverlay(r.n.P); rec.RadioManaged {
		t.Fatal("legacy claim must keep radio_managed=0")
	} else {
		_ = res
	}
}

func TestTrialBusy(t *testing.T) {
	r := newRig(t, provstore.Unclaimed)
	r.sys.trial = true
	if c, _ := r.claim(); c != EBusy {
		t.Fatalf("code %d", c)
	}
	if c, _ := r.call("info.state", cbor.M()); c != OK {
		t.Fatal("read-only verbs must still work on a trial")
	}
}

func TestOwnerOpRules(t *testing.T) {
	r := newRig(t, provstore.Unclaimed)
	if c, _ := r.claim(); c != OK {
		t.Fatal("claim")
	}
	keys := []any{"ssh-ed25519 AAAAC3Nz owner"}
	// valid owner-op
	if c, _ := r.call("ssh_keys.set", cbor.M(1, r.h, 2, r.envelope("ssh_keys/set", cbor.M(1, keys), r.owner))); c != OK {
		t.Fatalf("ssh_keys.set %d", c)
	}
	if len(r.sys.keys) != 2 || r.sys.keys[0] != "ssh-ed25519 AAAAlab lab" {
		t.Fatalf("lab key must stay: %v", r.sys.keys)
	}
	// signed by someone else
	other, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if c, _ := r.call("ssh_keys.set", cbor.M(1, r.h, 2, r.envelope("ssh_keys/set", cbor.M(1, keys), other))); c != EForbidden {
		t.Fatalf("foreign signer %d", c)
	}
	// envelope type of another verb
	if c, _ := r.call("ssh_keys.set", cbor.M(1, r.h, 2, r.envelope("network/leave", cbor.M(), r.owner))); c != EForbidden {
		t.Fatalf("type mismatch %d", c)
	}
	// a body field added after signing changes args_hash
	raw := r.envelope("ssh_keys/set", cbor.M(1, keys), r.owner)
	x, _ := cbor.Decode(raw)
	env := x.(cbor.Map)
	b, _ := env.Get(3)
	body := append(b.(cbor.Map), cbor.Entry{K: uint64(2), V: true})
	env = append(env.Without(3), cbor.Entry{K: uint64(3), V: body})
	tampered, _ := cbor.Encode(env)
	if c, _ := r.call("ssh_keys.set", cbor.M(1, r.h, 2, tampered)); c != EForbidden {
		t.Fatalf("tampered body %d", c)
	}
	// injection in a key line
	if c, _ := r.call("ssh_keys.set", cbor.M(1, r.h, 2, r.envelope("ssh_keys/set", cbor.M(1, []any{"command=\"x\" ssh-ed25519 AAAA"}), r.owner))); c != ESchema {
		t.Fatalf("injection %d", c)
	}
	// rename refused in P1 (P-U7)
	if c, _ := r.call("settings.set", cbor.M(1, r.h, 2, r.envelope("settings/set", cbor.M("hostname", "x"), r.owner))); c != EUnsupported {
		t.Fatalf("hostname %d", c)
	}
	// nonce_helper is one-time: replaying a consumed envelope fails
	raw = r.envelope("root_password/reset", cbor.M(), r.owner)
	if c, _ := r.call("root_password.reset", cbor.M(1, r.h, 2, raw)); c != OK {
		t.Fatal("reset")
	}
	if c, _ := r.call("root_password.reset", cbor.M(1, r.h, 2, raw)); c != EForbidden {
		t.Fatal("replayed owner-op accepted")
	}
}

func TestNoForbiddenVerbs(t *testing.T) {
	r := newRig(t, provstore.Unclaimed)
	for _, v := range []string{"keystore.ecdh", "persist", "keystore.sign", "reset", "factory_reset"} {
		if c, _ := r.call(v, cbor.M()); c != ESchema {
			t.Fatalf("%s: code %d", v, c)
		}
	}
	if c, _ := r.call("info.state", cbor.M(9, true)); c != ESchema {
		t.Fatal("extra arg accepted")
	}
}

func TestPersistFailureRollsBack(t *testing.T) {
	r := newRig(t, provstore.Unclaimed)
	r.sys.persistRC = 1
	if c, _ := r.claim(); c != EStorage {
		t.Fatalf("code %d", c)
	}
	rec, _, _ := provstore.LoadOverlay(r.n.P)
	if rec.State != provstore.Unclaimed || r.sys.locked != "" {
		t.Fatal("overlay changed / locked although p5 was not written")
	}
}
