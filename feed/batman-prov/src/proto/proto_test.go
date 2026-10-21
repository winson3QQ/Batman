package proto

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
)

// The protocol vectors are the judge (219-protocol §10–11). VECTORS overrides the in-repo path.
func vectors(t *testing.T) map[string]map[string]any {
	p := os.Getenv("VECTORS")
	if p == "" {
		p = "../../../../tests/vectors/219-protocol/vectors.json"
	}
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatalf("vectors: %v (a test that finds nothing must FAIL)", err)
	}
	var v map[string]map[string]any
	if err := json.Unmarshal(b, &v); err != nil {
		t.Fatal(err)
	}
	return v
}

func hx(t *testing.T, v map[string]map[string]any, sec, key string) []byte {
	s, ok := v[sec][key].(string)
	if !ok {
		t.Fatalf("vector %s.%s missing", sec, key)
	}
	b, err := hex.DecodeString(s)
	if err != nil {
		t.Fatalf("vector %s.%s: %v", sec, key, err)
	}
	return b
}

// test private scalars: d = (int(SHA-256('batman-test-vector/'+name)) mod (n-1)) + 1 (vectors.keys note)
func testScalar(name string) []byte {
	h := sha256.Sum256([]byte("batman-test-vector/" + name))
	n := elliptic.P256().Params().N
	d := new(big.Int).Mod(new(big.Int).SetBytes(h[:]), new(big.Int).Sub(n, big.NewInt(1)))
	d.Add(d, big.NewInt(1))
	out := make([]byte, 32)
	d.FillBytes(out)
	return out
}

func TestClaimCheckMac(t *testing.T) {
	v := vectors(t)
	h := hx(t, v, "noise_nx", "handshake_hash")
	cc := ClientChal(hx(t, v, "claim_checkmac", "nonce"), h, hx(t, v, "keys", "dac_cert_der"), hx(t, v, "keys", "owner_sign_pub"))
	if !bytes.Equal(cc, hx(t, v, "claim_checkmac", "client_chal")) {
		t.Fatalf("ClientChal mismatch")
	}
	in, _ := CheckMacInput(hx(t, v, "keys", "claim_secret"), cc, hx(t, v, "keys", "sn"))
	if !bytes.Equal(in, hx(t, v, "claim_checkmac", "checkmac_input_88B")) {
		t.Fatalf("CheckMac input mismatch")
	}
	resp := hx(t, v, "claim_checkmac", "response")
	if !CheckMacOK(hx(t, v, "keys", "claim_secret"), cc, hx(t, v, "keys", "sn"), resp) {
		t.Fatalf("CheckMac response rejected")
	}
	// negative: the attacker's owner_pub with the buyer's response must fail (§4.1 negative test)
	cc2 := ClientChal(hx(t, v, "claim_checkmac", "nonce"), h, hx(t, v, "keys", "dac_cert_der"), hx(t, v, "keys", "admin_pub"))
	if CheckMacOK(hx(t, v, "keys", "claim_secret"), cc2, hx(t, v, "keys", "sn"), resp) {
		t.Fatalf("CheckMac accepted a response bound to another owner_pub")
	}
}

func TestOwnerOp(t *testing.T) {
	v := vectors(t)
	h := hx(t, v, "noise_nxpsk0_owner", "handshake_hash")
	env, err := cbor.Decode(hx(t, v, "owner_op", "request_network_join"))
	if err != nil {
		t.Fatalf("request is not strict deterministic CBOR: %v", err)
	}
	em := env.(cbor.Map)
	typ, _ := em.Get(2)
	bodyAny, _ := em.Get(3)
	body := bodyAny.(cbor.Map)
	ah, _ := ArgsHash(body)
	if !bytes.Equal(ah, hx(t, v, "owner_op", "args_hash")) {
		t.Fatalf("args_hash mismatch")
	}
	in, _ := OwnerOpInput(h, hx(t, v, "owner_op", "nonce_helper"), typ.(string), ah)
	if !bytes.Equal(in, hx(t, v, "owner_op", "input")) {
		t.Fatalf("owner-op input mismatch")
	}
	if !VerifyES256(hx(t, v, "keys", "owner_sign_pub"), in, hx(t, v, "owner_op", "sig")) {
		t.Fatalf("owner-op signature rejected")
	}
	// negative: same body under another envelope type (verb from the envelope, §5.7)
	env2, _ := cbor.Decode(hx(t, v, "owner_op", "request_type_mismatch"))
	typ2, _ := env2.(cbor.Map).Get(2)
	in2, _ := OwnerOpInput(h, hx(t, v, "owner_op", "nonce_helper"), typ2.(string), ah)
	if VerifyES256(hx(t, v, "keys", "owner_sign_pub"), in2, hx(t, v, "owner_op", "sig")) {
		t.Fatalf("owner-op accepted under another envelope type")
	}
	// negative: a high-s twin of a valid signature is rejected
	sig := hx(t, v, "owner_op", "sig")
	n := elliptic.P256().Params().N
	s := new(big.Int).SetBytes(sig[32:])
	hi := make([]byte, 64)
	copy(hi, sig[:32])
	new(big.Int).Sub(n, s).FillBytes(hi[32:])
	if VerifyES256(hx(t, v, "keys", "owner_sign_pub"), in, hi) {
		t.Fatalf("high-s signature accepted")
	}
}

func TestHKDF(t *testing.T) {
	v := vectors(t)
	dev := v["keys"]["device_id"].(string)
	netID := hx(t, v, "keys", "net_id")
	if !bytes.Equal(PskOwner(hx(t, v, "keys", "owner_tag_key"), dev), hx(t, v, "hkdf", "psk_owner")) {
		t.Fatalf("psk_owner")
	}
	if !bytes.Equal(AdvOwner(hx(t, v, "keys", "adv_owner_key"), dev), hx(t, v, "hkdf", "adv_owner")) {
		t.Fatalf("adv_owner")
	}
	// net_version of the hkdf vectors: try the documented first version
	ok := false
	for ver := uint32(0); ver < 8; ver++ {
		if bytes.Equal(PskMember(hx(t, v, "keys", "net_root"), netID, ver), hx(t, v, "hkdf", "psk_member")) &&
			bytes.Equal(AdvMember(hx(t, v, "keys", "net_root"), netID, ver), hx(t, v, "hkdf", "adv_member")) {
			ok = true
		}
	}
	if !ok {
		t.Fatalf("psk_member / adv_member")
	}
}

func TestPskReplay(t *testing.T) {
	v := vectors(t)
	priv, err := ecdh.P256().NewPrivateKey(testScalar("node-ecdh"))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(priv.PublicKey().Bytes(), hx(t, v, "keys", "node_ecdh_pub")) {
		t.Fatalf("test scalar rule does not reproduce node_ecdh_pub")
	}
	z, err := ECDHX(priv, hx(t, v, "keys", "owner_enc_pub"))
	if err != nil || !bytes.Equal(z, hx(t, v, "psk_replay", "ecdh_z")) {
		t.Fatalf("ECDH z mismatch")
	}
	if !bytes.Equal(PskReplay(z, v["keys"]["device_id"].(string)), hx(t, v, "psk_replay", "psk_replay")) {
		t.Fatalf("psk_replay")
	}
}

func TestClaimReplayOwnerOp(t *testing.T) {
	v := vectors(t)
	h := hx(t, v, "noise_nxpsk0_replay", "handshake_hash")
	cc := ClientChal(hx(t, v, "claim_replay", "nonce"), h, hx(t, v, "keys", "dac_cert_der"), hx(t, v, "keys", "owner_sign_pub"))
	if !bytes.Equal(cc, hx(t, v, "claim_replay", "client_chal")) {
		t.Fatalf("replay ClientChal")
	}
	if !CheckMacOK(hx(t, v, "keys", "claim_secret"), cc, hx(t, v, "keys", "sn"), hx(t, v, "claim_replay", "response")) {
		t.Fatalf("replay CheckMac")
	}
	env, err := cbor.Decode(hx(t, v, "claim_replay", "request"))
	if err != nil {
		t.Fatal(err)
	}
	body, _ := env.(cbor.Map).Get(3)
	ah, _ := ArgsHash(body.(cbor.Map))
	in, _ := OwnerOpInput(h, hx(t, v, "claim_replay", "nonce_helper"), "claim/replay", ah)
	if !bytes.Equal(in, hx(t, v, "claim_replay", "owner_op_input")) {
		t.Fatalf("replay owner-op input")
	}
	if !VerifyES256(hx(t, v, "keys", "owner_sign_pub"), in, hx(t, v, "claim_replay", "owner_op_sig")) {
		t.Fatalf("replay owner-op sig")
	}
}
