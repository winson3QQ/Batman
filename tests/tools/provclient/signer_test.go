package main

import "testing"

// the signer signs exactly the three COSE objects of a network change (netcfg, secrets, member_list — the last was
// missing until 2026-11-22: every network/update unit got "signer refused") and nothing else
func TestSignerCoseLabels(t *testing.T) {
	for _, c := range []struct {
		label string
		want  bool
	}{{labelNetcfg, true}, {labelSecrets, true}, {labelMembers, true}, {"batman-other-v1", false}, {"", false}} {
		msg := cEnc([]any{"Signature1", []byte{0xa0}, []byte(c.label), []byte("payload")})
		if got := isCoseSigStructure(msg); got != c.want {
			t.Errorf("label %q: %v, want %v", c.label, got, c.want)
		}
	}
	if isCoseSigStructure(cEnc([]any{"Signature2", []byte{0xa0}, []byte(labelMembers), []byte("p")})) {
		t.Error("a non-Signature1 structure was accepted")
	}
}
