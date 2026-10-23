package cose

import (
	"bytes"
	"crypto/ecdh"
	"crypto/elliptic"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"math/big"
	"os"
	"testing"

	"batman-prov/cbor"
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

func h(t *testing.T, s any) []byte {
	b, err := hex.DecodeString(s.(string))
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func scalar(name string) []byte {
	d := sha256.Sum256([]byte("batman-test-vector/" + name))
	n := elliptic.P256().Params().N
	x := new(big.Int).Mod(new(big.Int).SetBytes(d[:]), new(big.Int).Sub(n, big.NewInt(1)))
	x.Add(x, big.NewInt(1))
	b := make([]byte, 32)
	x.FillBytes(b)
	return b
}

func dec(t *testing.T, b []byte) any {
	x, err := cbor.Decode(b)
	if err != nil {
		t.Fatalf("strict decode: %v", err)
	}
	return x
}

func TestNetConfigAndChain(t *testing.T) {
	v := vec(t)
	cose := v["cose"]["net_config"].(map[string]any)
	admin := h(t, v["keys"]["admin_pub"])
	s1, err := VerifySign1(dec(t, h(t, cose["sign1"])), CTNetcfg, proto.LabelNetcfg, [][]byte{admin})
	if err != nil {
		t.Fatal("net_config v1 rejected")
	}
	vc := v["version_chain"]
	if !bytes.Equal(s1.ObjectHash, h(t, vc["v1_object_hash"])) {
		t.Fatal("OBJECT_HASH(v1)")
	}
	// wrong label / content type / key -> rejected
	if _, err := VerifySign1(dec(t, h(t, cose["sign1"])), CTNetcfg, proto.LabelSecrets, [][]byte{admin}); err == nil {
		t.Fatal("accepted under another label")
	}
	if _, err := VerifySign1(dec(t, h(t, cose["sign1"])), CTMembers, proto.LabelNetcfg, [][]byte{admin}); err == nil {
		t.Fatal("accepted under another content type")
	}
	if _, err := VerifySign1(dec(t, h(t, cose["sign1"])), CTNetcfg, proto.LabelNetcfg, [][]byte{h(t, v["keys"]["owner_sign_pub"])}); err == nil {
		t.Fatal("accepted with a non-admin key")
	}
	// chain: v2 verified with v1's admins; v3 valid only against v2's admins (admin2 added in v2)
	admins := func(s *Sign1) [][]byte {
		var out [][]byte
		for _, e := range s.Payload {
			if e.K == uint64(8) { // net_config key 8 = admins (219-protocol.cddl)
				for _, a := range e.V.([]any) {
					out = append(out, a.([]byte))
				}
			}
		}
		return out
	}
	s2, err := VerifySign1(dec(t, h(t, vc["v2"])), CTNetcfg, proto.LabelNetcfg, admins(s1))
	if err != nil || !bytes.Equal(s2.ObjectHash, h(t, vc["v2_object_hash"])) {
		t.Fatal("v2 against v1 admins")
	}
	if _, err := VerifySign1(dec(t, h(t, vc["v3"])), CTNetcfg, proto.LabelNetcfg, admins(s2)); err != nil {
		t.Fatal("v3 against v2 admins")
	}
	if _, err := VerifySign1(dec(t, h(t, vc["v3"])), CTNetcfg, proto.LabelNetcfg, admins(s1)); err == nil {
		t.Fatal("v3 accepted against v1 admins (version-chain rule broken)")
	}
	// unprotected header must be empty: a Sign1 with {4: kid} in it is rejected
	raw := dec(t, h(t, cose["sign1"])).(cbor.Tag)
	arr := append([]any(nil), raw.V.([]any)...)
	arr[1] = cbor.M(4, []byte("k"))
	if _, err := VerifySign1(cbor.Tag{Num: 18, V: arr}, CTNetcfg, proto.LabelNetcfg, [][]byte{admin}); err == nil {
		t.Fatal("non-empty unprotected header accepted")
	}
}

func TestNetSecrets(t *testing.T) {
	v := vec(t)
	ns := v["cose"]["net_secrets"].(map[string]any)
	admin := h(t, v["keys"]["admin_pub"])
	s, err := VerifySign1(dec(t, h(t, ns["sign1"])), CTSecrets, proto.LabelSecrets, [][]byte{admin})
	if err != nil {
		t.Fatal("net_secrets Sign1 rejected")
	}
	target, _ := s.Payload.Get(3)
	if !bytes.Equal(target.([]byte), h(t, v["keys"]["dac_pub_hash"])) {
		t.Fatal("target_dac_hash")
	}
	netID, _ := s.Payload.Get(1)
	ver, _ := s.Payload.Get(2)
	other := append(append([]byte(nil), netID.([]byte)...), 0, 0, 0, byte(ver.(uint64)))
	priv, err := ecdh.P256().NewPrivateKey(scalar("node-ecdh"))
	if err != nil {
		t.Fatal(err)
	}
	ecdhf := func(p []byte) ([]byte, error) { return proto.ECDHX(priv, p) }
	enc, _ := s.Payload.Get(4)
	pt, err := Decrypt(enc, proto.LabelSecrets, target.([]byte), other, ecdhf)
	if err != nil {
		t.Fatalf("decrypt: %v", err)
	}
	if !bytes.Equal(pt, h(t, ns["plaintext"])) {
		t.Fatal("plaintext")
	}
	if !bytes.Equal(KDFContext(target.([]byte), mustEnc(cbor.M(1, int64(-25))), other), h(t, ns["kdf_context"])) {
		t.Fatal("KDF context")
	}
	// wrong label (member_secrets label on net_secrets) -> AEAD fails
	if _, err := Decrypt(enc, "batman-msecrets-v1", target.([]byte), other, ecdhf); err == nil {
		t.Fatal("decrypted under another label")
	}
	// wrong recipient key -> fails
	other2, _ := ecdh.P256().NewPrivateKey(scalar("owner-enc"))
	if _, err := Decrypt(enc, proto.LabelSecrets, target.([]byte), other, func(p []byte) ([]byte, error) { return proto.ECDHX(other2, p) }); err == nil {
		t.Fatal("decrypted with another node's key")
	}
}

func mustEnc(x any) []byte { b, _ := cbor.Encode(x); return b }
