package node

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math/big"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"batman-prov/cbor"
	"batman-prov/keystore"
	"batman-prov/provstore"
)

// The protocol vector (tests/vectors/219-protocol: Python, the reference) applied by the node (docs/design/
// 254-net-update-members.md §6 "跨語言"): join v1 with cose.net_config + cose.net_secrets, then network_update.body_v2
// -> 0 with v2's SAE; network_update.stale_body_v2 (v2 config + v1 secrets) -> E_BAD_OBJECT.

func vecKey(name string) *ecdsa.PrivateKey { // the vectors' private-key rule (gen.py p256 / keystore_test testKey)
	h := sha256.Sum256([]byte("batman-test-vector/" + name))
	n := elliptic.P256().Params().N
	d := new(big.Int).Mod(new(big.Int).SetBytes(h[:]), new(big.Int).Sub(n, big.NewInt(1)))
	d.Add(d, big.NewInt(1))
	b := make([]byte, 32)
	d.FillBytes(b)
	k, err := ecdsa.ParseRawPrivateKey(elliptic.P256(), b)
	if err != nil {
		panic(err)
	}
	return k
}

// vecIdentity writes an identity dir (keystore.Generate's layout) with the vectors' DAC and node-ecdh keys
func vecIdentity(t *testing.T, dir string) {
	dac, ek := vecKey("dac"), vecKey("node-ecdh")
	dacDER, _ := x509.MarshalPKCS8PrivateKey(dac)
	ekDER, _ := x509.MarshalPKCS8PrivateKey(ek)
	cert, err := keystore.DevCert(dac)
	if err != nil {
		t.Fatal(err)
	}
	pubB, _ := dac.PublicKey.Bytes()
	s := sha256.Sum256(pubB)
	secret := make([]byte, 32)
	rand.Read(secret)
	content := map[string][]byte{"node.key": dacDER, "ecdh.key": ekDER, "node.cert": cert, "claim.secret": secret,
		"backend": []byte("file\n"), "sn": []byte(hex.EncodeToString(s[:9]) + "\n")}
	os.MkdirAll(dir, 0o700)
	var sums strings.Builder
	for _, f := range keystore.Files {
		if err := os.WriteFile(filepath.Join(dir, f), content[f], 0o600); err != nil {
			t.Fatal(err)
		}
		h := sha256.Sum256(content[f])
		fmt.Fprintf(&sums, "%x  %s\n", h, f)
	}
	os.WriteFile(filepath.Join(dir, "sha256"), []byte(sums.String()), 0o600)
}

func vecItem(t *testing.T, v map[string]map[string]any, sec, key string) any {
	return vecItemOf(t, v[sec][key].(string))
}

func vecItemOf(t *testing.T, h string) any {
	b, err := hex.DecodeString(h)
	if err != nil {
		t.Fatal(err)
	}
	x, err := cbor.Decode(b)
	if err != nil {
		t.Fatal(err)
	}
	return x
}

func TestUpdateProtocolVector(t *testing.T) {
	raw, err := os.ReadFile("../../../../tests/vectors/219-protocol/vectors.json")
	if err != nil {
		t.Fatal(err)
	}
	var v map[string]map[string]any
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatal(err)
	}
	cose := v["cose"]
	r := newRig(t, provstore.Unclaimed)
	dir := filepath.Join(t.TempDir(), "identity")
	vecIdentity(t, dir)
	ks, err := keystore.Load(dir)
	if err != nil {
		t.Fatal(err)
	}
	if hex.EncodeToString(ks.DACPub()) != v["keys"]["dac_pub"].(string) {
		t.Fatal("the vector identity is not the vectors' DAC")
	}
	r.ks, r.ksDir = ks, dir
	r.n = New(r.n.P, ks, r.sys, func(string, ...any) {})
	r.n.Verdict = provstore.Unclaimed
	if c, _ := r.claim(); c != OK {
		t.Fatalf("claim %d", c)
	}
	cfg1 := vecItemOf(t, cose["net_config"].(map[string]any)["sign1"].(string))
	sec1 := vecItemOf(t, cose["net_secrets"].(map[string]any)["sign1"].(string))
	if c, _ := r.call("net.apply", cbor.M(1, r.h, 2, r.envelope("network/join", cbor.M(1, cfg1, 3, sec1), r.owner))); c != OK {
		t.Fatalf("join v1 (vector objects): %d", c)
	}
	if r.wl() != "correct-horse-battery/batman-test/40" {
		t.Fatalf("after join: %s", r.wl())
	}
	nu := v["network_update"]
	stale, _ := vecItem(t, v, "network_update", "stale_body_v2").(cbor.Map)
	b := r.nuSnap()
	r.refused(t, "vector stale_body_v2", r.applyUpdateBody(stale), EBadObject, b, "correct-horse-battery/batman-test/40")
	body, ok := vecItem(t, v, "network_update", "body_v2").(cbor.Map)
	if !ok {
		t.Fatal("body_v2 is not a map")
	}
	if c := r.applyUpdateBody(body); c != OK {
		t.Fatalf("vector body_v2: %d", c)
	}
	if want := nu["sae_v2"].(string) + "/batman-test/40"; r.wl() != want || r.rec().Net.Version != 2 {
		t.Fatalf("after body_v2: %s version %d, want %s / 2", r.wl(), r.rec().Net.Version, want)
	}
	root := r.n.netRoot(r.rec())
	if hex.EncodeToString(root) != nu["net_root_v2"].(string) {
		t.Fatal("net_root after the update is not the vector's v2 root")
	}
}
