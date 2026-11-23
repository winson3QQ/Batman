package helpercheck

// ownerop_test.go — provclient's owner-op requests against the REAL helper verification (node.Handle on a claimed
// record: verifyOwnerOp, proto.ArgsHash / OwnerOpInput / VerifyES256). Device run on 04 (2026-11-23 13:30, 641b1fa):
// bulk.open and bulk.close answered code 3 "owner-op signature / nonce". For bulk-open, bulk-close, update-prepare and
// update-apply the request is built by the provclient binary itself (`provclient oprequest`, the same p3Op code path as
// node mode, only the transport differs) with a nonce the real node issued, then handed to node.Handle:
//   - signed by the record's owner            -> past the owner-op check (the verb itself then refuses for lack of
//                                                 bulk / update wiring: never code 3);
//   - one signature byte flipped               -> code 3 (the check discriminates);
//   - signed by a key that is not an owner     -> code 3 (a signature that verifies, by the wrong key: what 04 answers
//                                                 when the harness's H0 is not one of the node's owners);
//   - the nonce of another connection (h)      -> code 3.
// PROVCLIENT_BIN = a prebuilt provclient (the negative control builds the 641b1fa one); default: built from ../provclient.

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/hex"
	"encoding/pem"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"batman-prov/cbor"
	"batman-prov/keystore"
	"batman-prov/node"
	"batman-prov/provstore"
)

type nodeSys struct{ node.Sys } // only the methods the owner-op path calls are implemented; anything else panics

func (nodeSys) GetP5(string) (int, string) { return 1, "no p5 in this test" } // resolve: the overlay is used
func (nodeSys) Now() time.Time             { return time.Now() }
func (nodeSys) IsTrial() bool              { return false }

func provclientBin(t *testing.T) string {
	t.Helper()
	if b := os.Getenv("PROVCLIENT_BIN"); b != "" {
		return b
	}
	out := filepath.Join(t.TempDir(), "provclient")
	cmd := exec.Command(filepath.Join(runtime.GOROOT(), "bin", "go"), "build", "-buildvcs=false", "-o", out, ".")
	cmd.Dir = "../provclient"
	cmd.Env = append(os.Environ(), "GOFLAGS=-mod=vendor", "CGO_ENABLED=0")
	if b, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("build provclient: %v\n%s", err, b)
	}
	return out
}

func keyFile(t *testing.T) (string, []byte) {
	t.Helper()
	k, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	der, _ := x509.MarshalECPrivateKey(k)
	p := filepath.Join(t.TempDir(), "k.pem")
	if err := os.WriteFile(p, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: der}), 0o600); err != nil {
		t.Fatal(err)
	}
	pub, _ := k.PublicKey.Bytes()
	return p, pub
}

// claimed: a node on a claimed record whose only owner is ownerPub
func claimed(t *testing.T, ownerPub []byte) *node.Node {
	t.Helper()
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
	if _, _, err := provstore.WriteOverlay(p, &provstore.Record{Generation: 1, State: provstore.Claimed,
		Owners: []provstore.Owner{{Pub: ownerPub, EncPub: ownerPub, TagKey: make([]byte, 32)}}, AdvOwnerKey: make([]byte, 32),
		Admins: [][]byte{}, SSHKeysAdded: []string{}}); err != nil {
		t.Fatal(err)
	}
	n := node.New(p, ks, nodeSys{}, func(f string, a ...any) { t.Logf("helper: "+f, a...) })
	n.Verdict = provstore.Claimed
	n.SetUpdateSource(&fakeUpd{}, nil)
	return n
}

func call(t *testing.T, n *node.Node, verb string, args cbor.Map) (uint64, cbor.Map) {
	t.Helper()
	raw, err := cbor.Encode(cbor.M(1, verb, 2, uint64(1), 3, args))
	if err != nil {
		t.Fatal(err)
	}
	dec, err := cbor.Decode(raw)
	if err != nil {
		t.Fatal(err)
	}
	resp := n.Handle(dec.(cbor.Map))
	c, _ := get(resp, 2).(uint64)
	r, _ := get(resp, 3).(cbor.Map)
	return c, r
}

// opRequest: the request provclient builds for <op> with the node's nonce for h, signed with keyfile
func opRequest(t *testing.T, bin, keyfile string, h, nh []byte, op string, args ...string) (string, cbor.Map) {
	t.Helper()
	a := append([]string{"oprequest", keyfile, hex.EncodeToString(h), hex.EncodeToString(nh), "--", op}, args...)
	out, err := exec.Command(bin, a...).CombinedOutput()
	if err != nil {
		t.Fatalf("provclient oprequest %s: %v\n%s", op, err, out)
	}
	for _, l := range strings.Split(string(out), "\n") {
		f := strings.Fields(l)
		if len(f) == 3 && f[0] == "REQ" {
			b, err := hex.DecodeString(f[2])
			if err != nil {
				t.Fatal(err)
			}
			x, err := cbor.Decode(b)
			if err != nil {
				t.Fatalf("%s: the request does not decode with the helper's cbor: %v", op, err)
			}
			return f[1], x.(cbor.Map)
		}
	}
	t.Fatalf("provclient oprequest %s printed no REQ line:\n%s", op, out)
	return "", nil
}

func nonceFor(t *testing.T, n *node.Node, h []byte) []byte {
	t.Helper()
	c, r := call(t, n, "nonce", cbor.M(1, h))
	nh, _ := get(r, 2).([]byte)
	if c != 0 || len(nh) != 32 {
		t.Fatalf("nonce: code %d", c)
	}
	return nh
}

// flipSig: the request with one byte of the owner-op signature (envelope body key 31, key 2) flipped
func flipSig(t *testing.T, args cbor.Map) cbor.Map {
	t.Helper()
	envRaw, _ := get(args, 2).([]byte)
	ex, _ := cbor.Decode(envRaw)
	env := ex.(cbor.Map)
	body := get(env, 3).(cbor.Map)
	op := get(body, 31).(cbor.Map)
	sig := append([]byte(nil), get(op, 2).([]byte)...)
	sig[5] ^= 1
	nb := cbor.M()
	for _, e := range body {
		if e.K == uint64(31) {
			nb = append(nb, cbor.Entry{K: e.K, V: cbor.M(1, get(op, 1), 2, sig)})
		} else {
			nb = append(nb, e)
		}
	}
	ne := cbor.M()
	for _, e := range env {
		if e.K == uint64(3) {
			ne = append(ne, cbor.Entry{K: e.K, V: nb})
		} else {
			ne = append(ne, e)
		}
	}
	b, err := cbor.Encode(ne)
	if err != nil {
		t.Fatal(err)
	}
	return cbor.M(1, get(args, 1), 2, b)
}

var ownerOps = []struct {
	op   string
	verb string
	args func(pubHex string) []string
}{
	{"bulk-open", "bulk.open", func(p string) []string { return []string{p, strings.Repeat("ab", 32)} }},
	{"bulk-close", "bulk.close", func(p string) []string { return []string{p} }},
	{"update-prepare", "update.prepare", func(p string) []string { return []string{p, strings.Repeat("ab", 32)} }},
	{"update-apply", "update.apply", func(p string) []string { return []string{p, strings.Repeat("ab", 32)} }},
}

func TestOwnerOpsPassTheRealVerifier(t *testing.T) {
	bin := provclientBin(t)
	kf, pub := keyFile(t)
	other, _ := keyFile(t)
	pubHex := hex.EncodeToString(pub)
	for _, o := range ownerOps {
		t.Run(o.op, func(t *testing.T) {
			n := claimed(t, pub)
			h := make([]byte, 32)
			rand.Read(h)
			// signed by the owner: past the owner-op check
			verb, args := opRequest(t, bin, kf, h, nonceFor(t, n, h), o.op, o.args(pubHex)...)
			if verb != o.verb {
				t.Fatalf("provclient sent %q for %s", verb, o.op)
			}
			if c, _ := call(t, n, verb, args); c == 3 {
				t.Fatalf("%s signed by the owner: code 3 (owner-op signature / nonce) — provclient signs what the helper does not verify", o.op)
			}
			// one signature byte flipped: refused
			_, args = opRequest(t, bin, kf, h, nonceFor(t, n, h), o.op, o.args(pubHex)...)
			if c, _ := call(t, n, verb, flipSig(t, args)); c != 3 {
				t.Fatalf("%s with a flipped signature byte: code %d, want 3", o.op, c)
			}
			// a key that is not an owner: refused
			_, args = opRequest(t, bin, other, h, nonceFor(t, n, h), o.op, o.args(pubHex)...)
			if c, _ := call(t, n, verb, args); c != 3 {
				t.Fatalf("%s signed by a non-owner: code %d, want 3", o.op, c)
			}
			// the nonce of another h: refused
			h2 := make([]byte, 32)
			rand.Read(h2)
			_, args = opRequest(t, bin, kf, h, nonceFor(t, n, h2), o.op, o.args(pubHex)...)
			if c, _ := call(t, n, verb, args); c != 3 {
				t.Fatalf("%s with another connection's nonce: code %d, want 3", o.op, c)
			}
		})
	}
}

// UD20's negative arm (254-v16-ud §1.3): PROVCLIENT_SIGN_ARGS_SHA makes the owner-op sign args_hash({1: another sha})
// while the body carries the argv sha — the real verifier must refuse it (code 3), while the same request signed for
// the body's own sha passes the owner-op check. One variable, so a code 3 in UD20 neg is the swap and nothing else.
func TestUD20SignedForAnotherShaIsRefused(t *testing.T) {
	bin := provclientBin(t)
	kf, pub := keyFile(t)
	n := claimed(t, pub)
	h := make([]byte, 32)
	rand.Read(h)
	pubHex, sum := hex.EncodeToString(pub), strings.Repeat("ab", 32)
	a := []string{"oprequest", kf, hex.EncodeToString(h), hex.EncodeToString(nonceFor(t, n, h)), "--", "update-prepare", pubHex, sum}
	cmd := exec.Command(bin, a...)
	cmd.Env = append(os.Environ(), "PROVCLIENT_SIGN_ARGS_SHA="+strings.Repeat("cd", 32))
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("oprequest: %v\n%s", err, out)
	}
	var args cbor.Map
	for _, l := range strings.Split(string(out), "\n") {
		if f := strings.Fields(l); len(f) == 3 && f[0] == "REQ" {
			b, _ := hex.DecodeString(f[2])
			x, _ := cbor.Decode(b)
			args = x.(cbor.Map)
		}
	}
	if args == nil {
		t.Fatalf("no REQ line:\n%s", out)
	}
	if c, _ := call(t, n, "update.prepare", args); c != 3 {
		t.Fatalf("signed for another sha: code %d, want 3", c)
	}
	_, args = opRequest(t, bin, kf, h, nonceFor(t, n, h), "update-prepare", pubHex, sum)
	if c, _ := call(t, n, "update.prepare", args); c == 3 {
		t.Fatal("signed for the body's sha: code 3 (the control must pass the owner-op check)")
	}
}
