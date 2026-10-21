package main

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"fmt"
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
	fmt.Printf("selftest: pass=%d fail=%d\n", pass, fail)
	if fail != 0 || pass != 5 {
		os.Exit(1)
	}
}
