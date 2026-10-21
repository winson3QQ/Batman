package keystore

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/sha256"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"math/big"
	"os"
	"path/filepath"
	"testing"

	"batman-prov/proto"
)

func vec(t *testing.T) map[string]map[string]any {
	p := os.Getenv("VECTORS")
	if p == "" {
		p = "../../../../tests/vectors/219-protocol/vectors.json"
	}
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatalf("vectors: %v", err)
	}
	var v map[string]map[string]any
	if err := json.Unmarshal(b, &v); err != nil {
		t.Fatal(err)
	}
	return v
}

func testKey(name string) *ecdsa.PrivateKey {
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

// The cert built here has the vector's TBSCertificate byte for byte (same key; signatures differ — random k).
func TestDevCertMatchesVector(t *testing.T) {
	v := vec(t)
	want, _ := hex.DecodeString(v["identity_file"]["dev_cert_der"].(string))
	wc, err := x509.ParseCertificate(want)
	if err != nil {
		t.Fatal(err)
	}
	k := testKey("dev-node")
	pub, _ := k.PublicKey.Bytes()
	if hex.EncodeToString(pub) != v["identity_file"]["dac_pub"].(string) {
		t.Fatal("test key rule does not reproduce identity_file.dac_pub")
	}
	der, err := DevCert(k)
	if err != nil {
		t.Fatal(err)
	}
	gc, _ := x509.ParseCertificate(der)
	if !bytes.Equal(gc.RawTBSCertificate, wc.RawTBSCertificate) {
		t.Fatalf("TBS differs from the vector\n got %x\nwant %x", gc.RawTBSCertificate, wc.RawTBSCertificate)
	}
	id, err := CheckDevCert(want)
	if err != nil || id != v["identity_file"]["device_id"].(string) {
		t.Fatalf("vector dev cert rejected: %v", err)
	}
	forged, _ := hex.DecodeString(v["identity_file"]["forged_dev_cert_der"].(string))
	if _, err := CheckDevCert(forged); err == nil {
		t.Fatal("forged dev cert (same CN / serialNumber, other key) accepted")
	}
}

func TestGenerateLoadTamper(t *testing.T) {
	d := filepath.Join(t.TempDir(), "identity")
	if err := Generate(d); err != nil {
		t.Fatal(err)
	}
	if err := Generate(d); err == nil {
		t.Fatal("Generate overwrote an existing identity")
	}
	k, err := Load(d)
	if err != nil {
		t.Fatal(err)
	}
	if len(k.DeviceID()) != 18 || len(k.ECDHPub()) != 65 {
		t.Fatal("bad identity shape")
	}
	fi, _ := os.Stat(d)
	if fi.Mode().Perm() != 0o700 {
		t.Fatalf("identity dir mode %o", fi.Mode().Perm())
	}
	for _, f := range []string{"node.key", "ecdh.key", "claim.secret"} {
		fi, _ := os.Stat(filepath.Join(d, f))
		if fi.Mode().Perm() != 0o600 {
			t.Fatalf("%s mode %o", f, fi.Mode().Perm())
		}
	}
	// signatures verify with the DAC key; unknown purpose refused
	sig, err := k.SignPurpose(PurposeStatic, make([]byte, 32), make([]byte, 16))
	if err != nil || !proto.VerifyES256(k.DACPub(), append([]byte(PurposeStatic), make([]byte, 48)...), sig) {
		t.Fatal("static signature")
	}
	if _, err := k.SignPurpose("anything-else", []byte("x")); err == nil {
		t.Fatal("signed an unknown purpose")
	}
	// tamper: any file changed -> Load fails
	os.Chmod(filepath.Join(d, "claim.secret"), 0o600)
	os.WriteFile(filepath.Join(d, "claim.secret"), make([]byte, 32), 0o600)
	if _, err := Load(d); err == nil {
		t.Fatal("tampered identity loaded")
	}
}
