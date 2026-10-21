package cbor

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"os"
	"testing"
)

func mustHex(s string) []byte {
	b, err := hex.DecodeString(s)
	if err != nil {
		panic(err)
	}
	return b
}

// Strict input: everything core deterministic encoding would not produce is rejected (219-protocol §5.1).
func TestRejects(t *testing.T) {
	cases := map[string]string{
		"non-shortest uint (24 in 1+1)":   "1817",
		"non-shortest uint16":             "190017",
		"non-shortest length bstr":        "5801ff",
		"indefinite array":                "9f01ff",
		"indefinite bstr":                 "5f4101ff",
		"duplicate key":                   "a2010101 02",
		"unsorted keys":                   "a202010101",
		"float16":                         "f93c00",
		"float64":                         "fb3ff0000000000000",
		"undefined":                       "f7",
		"trailing bytes":                  "0101",
		"truncated":                       "5820aa",
		"map key bstr":                    "a1410101",
		"too deep":                        "818181818181818181818181818181818101",
	}
	for name, h := range cases {
		b := mustHex(stripSpaces(h))
		if _, err := Decode(b); err == nil {
			t.Errorf("%s: accepted %s", name, h)
		}
	}
}

func stripSpaces(s string) string { return string(bytes.ReplaceAll([]byte(s), []byte(" "), nil)) }

// Round trip: every protocol object in the vectors decodes strictly and re-encodes byte-identically.
func TestVectorRoundTrip(t *testing.T) {
	p := os.Getenv("VECTORS")
	if p == "" {
		p = "../../../../tests/vectors/219-protocol/vectors.json"
	}
	raw, err := os.ReadFile(p)
	if err != nil {
		t.Fatalf("vectors: %v", err)
	}
	var v map[string]map[string]any
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatal(err)
	}
	checked := 0
	for _, k := range [][2]string{{"owner_op", "request_network_join"}, {"owner_op", "request_type_mismatch"},
		{"op_nonce", "request"}, {"op_nonce", "response"}, {"claim_replay", "request"}, {"claim_replay", "response_envelope"}} {
		s, _ := v[k[0]][k[1]].(string)
		b := mustHex(s)
		x, err := Decode(b)
		if err != nil {
			t.Fatalf("%s.%s: %v", k[0], k[1], err)
		}
		e, err := Encode(x)
		if err != nil || !bytes.Equal(e, b) {
			t.Fatalf("%s.%s: re-encoding differs", k[0], k[1])
		}
		checked++
	}
	if checked == 0 {
		t.Fatal("nothing checked")
	}
}

func TestEncodeSortsAndRejectsDup(t *testing.T) {
	b, err := Encode(Map{{"b", uint64(1)}, {uint64(10), uint64(2)}, {int64(-1), uint64(3)}, {uint64(1), uint64(4)}})
	if err != nil {
		t.Fatal(err)
	}
	// canonical order by encoded key bytes: 01, 0a, 20 (-1), 61 62 ("b")
	if hex.EncodeToString(b) != "a401040a0220036162"+"01" {
		t.Fatalf("got %x", b)
	}
	if _, err := Encode(Map{{uint64(1), true}, {1, false}}); err == nil {
		t.Fatal("duplicate key encoded")
	}
}
