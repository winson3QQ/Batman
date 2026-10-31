package provd

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"os"
	"strings"
	"testing"

	"github.com/flynn/noise"
)

// the protocol vectors (tests/vectors/219-protocol/vectors.json): the first judge of this implementation (219 §11)
var vecs map[string]any

func vec(t *testing.T, path string) string {
	t.Helper()
	if vecs == nil {
		b, err := os.ReadFile("../../../../tests/vectors/219-protocol/vectors.json")
		if err != nil {
			t.Fatal(err)
		}
		if err := json.Unmarshal(b, &vecs); err != nil {
			t.Fatal(err)
		}
	}
	var cur any = vecs
	for _, p := range strings.Split(path, ".") {
		m, ok := cur.(map[string]any)
		if !ok {
			t.Fatalf("vector %s: not an object at %s", path, p)
		}
		cur = m[p]
	}
	s, ok := cur.(string)
	if !ok {
		t.Fatalf("vector %s missing", path)
	}
	return s
}

func vhex(t *testing.T, path string) []byte {
	t.Helper()
	b, err := hex.DecodeString(vec(t, path))
	if err != nil {
		t.Fatalf("%s: %v", path, err)
	}
	return b
}

// fixedRand yields the given bytes, then zeros (the vectors' node ephemeral comes from it).
type fixedRand struct{ b []byte }

func (f *fixedRand) Read(p []byte) (int, error) {
	n := copy(p, f.b)
	f.b = f.b[n:]
	for i := n; i < len(p); i++ {
		p[i] = 0
	}
	return len(p), nil
}

func staticKey(t *testing.T) noise.DHKey {
	return noise.DHKey{Private: vhex(t, "keys.s_node_priv"), Public: vhex(t, "keys.s_node_pub")}
}

func randKey() []byte { b := make([]byte, 32); rand.Read(b); return b }

func TestPrologueVector(t *testing.T) {
	if !bytes.Equal(Prologue(vec(t, "keys.device_id")), vhex(t, "noise_nx.prologue")) {
		t.Fatal("NX prologue")
	}
	if !bytes.Equal(Prologue(""), vhex(t, "noise_nxpsk0_owner.prologue")) {
		t.Fatal("NXpsk0 prologue")
	}
}

// msg2 byte for byte with flynn/noise against the noiseprotocol-generated vectors (Q8 cross-check), h, and the first
// transport message decrypted with Recv
func TestRespondNXVector(t *testing.T) {
	hs, err := Respond(vhex(t, "noise_nx.msg1"), staticKey(t), vhex(t, "noise_nx.prologue"), nil,
		vhex(t, "node_cert.cbor"), &fixedRand{vhex(t, "keys.node_ephemeral_priv")})
	if err != nil {
		t.Fatal(err)
	}
	if hs.Fake || !bytes.Equal(hs.Msg2, vhex(t, "noise_nx.msg2")) {
		t.Fatalf("msg2 differs (fake=%v)", hs.Fake)
	}
	if !bytes.Equal(hs.H, vhex(t, "noise_nx.handshake_hash")) {
		t.Fatal("handshake hash")
	}
	pt, err := hs.Recv.Decrypt(nil, nil, vhex(t, "noise_nx.first_transport_message"))
	if err != nil || !bytes.Equal(pt, vhex(t, "noise_nx.first_transport_plaintext")) {
		t.Fatalf("first transport message: %v", err)
	}
}

// the right PSK at any of the 6 positions opens msg1; all 6 are always tried. Mutant: break after the first success
// -> ReadAttempts < 6 for position 0 -> FAIL.
func TestRespondPSKVectors(t *testing.T) {
	for _, c := range []struct{ name, psk string }{{"noise_nxpsk0_owner", "hkdf.psk_owner"}, {"noise_nxpsk0_replay", "psk_replay.psk_replay"}} {
		for pos := 0; pos < NumPSK; pos++ {
			psks := make([][]byte, NumPSK)
			for i := range psks {
				psks[i] = randKey()
			}
			psks[pos] = vhex(t, c.psk)
			hs, err := Respond(vhex(t, c.name+".msg1"), staticKey(t), vhex(t, c.name+".prologue"), psks,
				vhex(t, "node_cert.cbor"), &fixedRand{vhex(t, "keys.node_ephemeral_priv")})
			if err != nil {
				t.Fatal(err)
			}
			if hs.Fake || hs.PSK != pos || hs.ReadAttempts != NumPSK || !bytes.Equal(hs.Msg2, vhex(t, c.name+".msg2")) {
				t.Fatalf("%s pos %d: fake=%v psk=%d attempts=%d", c.name, pos, hs.Fake, hs.PSK, hs.ReadAttempts)
			}
			if !bytes.Equal(hs.H, vhex(t, c.name+".handshake_hash")) {
				t.Fatalf("%s: h", c.name)
			}
		}
	}
}

// no PSK opens msg1, a 32 B (NX) msg1 on a PSK node, a 48 B (psk) msg1 on an NX node, a short msg1: the fake msg2 is
// as long as the real one (711 B with the vector cert, fake_msg2_rule), starts with a valid fresh public key, and the
// PSK node still tried 6 times. Mutant: fake without the 48 -> 663 B -> FAIL.
func TestRespondFake(t *testing.T) {
	cert := vhex(t, "node_cert.cbor")
	want := int(vecs["fake_msg2_rule"].(map[string]any)["length_equals_real_msg2"].(float64))
	wrong := [][]byte{randKey(), randKey(), randKey(), randKey(), randKey(), randKey()}
	cases := []struct {
		name     string
		msg1     []byte
		psks     [][]byte
		attempts int
	}{
		{"wrong psk", vhex(t, "noise_nxpsk0_owner.msg1"), wrong, 6},
		{"NX msg1 on a PSK node", vhex(t, "noise_nx.msg1"), wrong, 6},
		{"psk msg1 on an NX node", vhex(t, "noise_nxpsk0_owner.msg1"), nil, 0},
		{"short msg1", []byte{1, 2, 3}, nil, 0},
		{"long msg1 on a PSK node", append(vhex(t, "noise_nxpsk0_owner.msg1"), 0), wrong, 6},
	}
	for _, c := range cases {
		hs, err := Respond(c.msg1, staticKey(t), Prologue(""), c.psks, cert, nil)
		if err != nil {
			t.Fatal(err)
		}
		if !hs.Fake || len(hs.Msg2) != want || hs.ReadAttempts != c.attempts || hs.H != nil {
			t.Fatalf("%s: fake=%v len=%d (want %d) attempts=%d", c.name, hs.Fake, len(hs.Msg2), want, hs.ReadAttempts)
		}
	}
	// the real msg2 has the same length
	hs, _ := Respond(vhex(t, "noise_nx.msg1"), staticKey(t), vhex(t, "noise_nx.prologue"), nil, cert, nil)
	if len(hs.Msg2) != want {
		t.Fatalf("real msg2 %d", len(hs.Msg2))
	}
	// the long msg1 that the right PSK would open (F-P31: ReadMessage does not reject it) is still fake
	psks := append([][]byte{vhex(t, "hkdf.psk_owner")}, wrong[:5]...)
	if hs, _ := Respond(append(vhex(t, "noise_nxpsk0_owner.msg1"), 0), staticKey(t), Prologue(""), psks, cert, nil); !hs.Fake {
		t.Fatal("a 49 B msg1 was answered for real")
	}
}

func TestRespondNeedsSixCandidates(t *testing.T) {
	if _, err := Respond(make([]byte, 48), staticKey(t), Prologue(""), [][]byte{randKey()}, nil, nil); err == nil {
		t.Fatal("1 candidate accepted")
	}
}
