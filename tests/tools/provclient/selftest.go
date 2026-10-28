package main

import (
	"bytes"
	"crypto/ecdh"
	"crypto/elliptic"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math/big"
	"os"
)

// selftest: this client's own computations against the protocol vectors (the judge, 219-protocol §11).
// Exit 0 only if every check ran and passed; an unreadable vector file is a failure, never a pass.
func selftest(path string) {
	raw, err := os.ReadFile(path)
	if err != nil {
		die("selftest: %v", err)
	}
	var v map[string]map[string]any
	if err := json.Unmarshal(raw, &v); err != nil {
		die("selftest: %v", err)
	}
	for obj, f := range v["cose"] {
		if m, ok := f.(map[string]any); ok {
			for k, x := range m {
				v["cose"][k+"_"+obj] = x
			}
		}
	}
	h := func(sec, key string) []byte {
		s, ok := v[sec][key].(string)
		if !ok {
			die("selftest: vector %s.%s missing", sec, key)
		}
		b, err := hex.DecodeString(s)
		if err != nil {
			die("selftest: %s.%s: %v", sec, key, err)
		}
		return b
	}
	pass, fail := 0, 0
	check := func(name string, ok bool) {
		if ok {
			pass++
			fmt.Println("PASS " + name)
		} else {
			fail++
			fmt.Println("FAIL " + name)
		}
	}
	hs := h("noise_nx", "handshake_hash")
	cc := clientChal(h("claim_checkmac", "nonce"), hs, h("keys", "dac_cert_der"), h("keys", "owner_sign_pub"))
	check("ClientChal", bytes.Equal(cc, h("claim_checkmac", "client_chal")))
	check("CheckMac response", bytes.Equal(checkMac(h("keys", "claim_secret"), cc, h("keys", "sn")), h("claim_checkmac", "response")))
	// owner-op: args_hash from this client's re-encoding of the vector body without key 31
	env, _, err := cDec(h("owner_op", "request_network_join"))
	if err != nil {
		die("selftest: decode: %v", err)
	}
	em, _ := env.(cmap)
	body, _ := em.get(3).(cmap)
	var noOp cmap
	for _, e := range body {
		if e.k != uint64(31) {
			noOp = append(noOp, e)
		}
	}
	ah := sha(cEnc(noOp))
	check("args_hash (own CBOR re-encoding)", bytes.Equal(ah, h("owner_op", "args_hash")))
	in := opInput(h("noise_nxpsk0_owner", "handshake_hash"), h("owner_op", "nonce_helper"), "network/join", ah)
	check("owner-op input", bytes.Equal(in, h("owner_op", "input")))
	check("own CBOR re-encodes the whole request byte-identically", bytes.Equal(cEnc(env), h("owner_op", "request_network_join")))
	// net_config / net_secrets (net.go): the vectors' deterministic keys (219 F19 scalar rule) and IV reproduce the
	// KDF context, the CEK, the ciphertext and both Sig_structures byte for byte
	scalar := func(name string) *ecdh.PrivateKey {
		n := elliptic.P256().Params().N
		d := new(big.Int).SetBytes(sha([]byte("batman-test-vector/" + name)))
		d.Mod(d, new(big.Int).Sub(n, big.NewInt(1)))
		d.Add(d, big.NewInt(1))
		b := make([]byte, 32)
		d.FillBytes(b)
		k, err := ecdh.P256().NewPrivateKey(b)
		if err != nil {
			die("selftest: scalar %s: %v", name, err)
		}
		return k
	}
	netID, nodePub, dacHash := h("keys", "net_id"), h("keys", "node_ecdh_pub"), h("keys", "dac_pub_hash")
	check("dac_pub_hash = SHA-256(dac_pub)", bytes.Equal(sha(h("keys", "dac_pub")), dacHash))
	encObj, cek := encryptTo(h("cose", "plaintext_net_secrets"), labelSecrets, nodePub, dacHash, netID, 1,
		scalar("cose-ephemeral"), sha([]byte("batman-test-vector/iv-secrets"))[:12])
	check("net_secrets CEK (ECDH-ES + HKDF over the KDF context)", bytes.Equal(cek, h("cose", "cek_net_secrets")))
	secPayload := cEnc(cmap{{uint64(1), netID}, {uint64(2), uint64(1)}, {uint64(3), dacHash}, {uint64(4), encObj}})
	vs, _, err := cDec(h("cose", "sign1_net_secrets"))
	if err != nil {
		die("selftest: net_secrets: %v", err)
	}
	vpl, _ := vs.(ctag).v.([]any)[2].([]byte)
	check("net_secrets payload (COSE_Encrypt incl. ciphertext) byte-identical", bytes.Equal(secPayload, vpl))
	vprot, _ := vs.(ctag).v.([]any)[0].([]byte)
	check("net_secrets protected header", bytes.Equal(vprot, coseProt("batman/secrets")))
	check("net_config Sig_structure", bytes.Equal(sigStructure(coseProt("batman/netcfg"), labelNetcfg, h("cose", "payload_net_config")), h("cose", "sig_structure_net_config")))
	check("net_config OBJECT HASH (version chain prev_hash)", bytes.Equal(objectHash(h("cose", "sign1_net_config")), h("version_chain", "v1_object_hash")))
	fmt.Printf("selftest: pass=%d fail=%d\n", pass, fail)
	if fail != 0 || pass != 11 {
		os.Exit(1)
	}
}
