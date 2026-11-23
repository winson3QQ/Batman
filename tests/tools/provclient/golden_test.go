package main

// golden_test.go — the P3 request bodies this client sends, as committed vectors (254-v16-ud §3.1 "golden vectors"):
// testdata/p3-requests.json holds each request exactly as it goes on the helper socket ({1: verb, 2: id, 3: args},
// hex), the PRE-UD shapes of update.check / bulk.open ("old", what 4eba26d sent) and a sample error reply in errBody's
// shape. The old update.check is {1: the manifest map} with no key 2. tests/tools/provclient-helpercheck decodes them with the helper's own cbor package and runs them through the
// real node.Handle. PROVCLIENT_UPDATE_GOLDEN=1 rewrites the file; otherwise a difference FAILs.

import (
	"encoding/hex"
	"encoding/json"
	"os"
	"testing"
)

const goldenPath = "testdata/p3-requests.json"

// goldenManifest: a small update-manifest-shaped map (the helper verifies it and refuses it: the vectors only have to
// get past the schema check)
func goldenManifest() []byte {
	return cEnc(cmap{{uint64(1), "1.5.14-wsl.36"}, {uint64(2), "ekh-bcm2711"}, {uint64(3), uint64(127292688)},
		{uint64(4), make([]byte, 32)}, {uint64(5), cEnc([]any{[]byte{0xd2}, []byte{0xd2}})}})
}

func goldenVectors(t *testing.T) map[string]string {
	t.Helper()
	req := func(verb string, args cmap) string {
		return hex.EncodeToString(cEnc(cmap{{uint64(1), verb}, {uint64(2), uint64(1)}, {uint64(3), args}}))
	}
	mf := goldenManifest()
	uc, err := updateCheckBody(mf, testOwner)
	if err != nil {
		t.Fatal(err)
	}
	sum := make([]byte, 32)
	sum[31] = 0x5a
	bo, err := bulkOpenBody(sum)
	if err != nil {
		t.Fatal(err)
	}
	return map[string]string{
		"owner_pub":          hex.EncodeToString(testOwner),
		"update_check_new":   req("update.check", uc),
		"update_check_old":   req("update.check", cmap{{uint64(1), rawCBOR(mf)}}),
		"bulk_open_body_new": hex.EncodeToString(cEnc(bo)),
		"bulk_open_body_old": hex.EncodeToString(cEnc(cmap{{uint64(1), uint64(0)}})),
		// node.go errBody for failR(EReject 24, reason 15): {1: id, 2: 24, 3: {1: 15}}
		"error_reply_24_15": hex.EncodeToString(cEnc(cmap{{uint64(1), uint64(1)}, {uint64(2), uint64(24)}, {uint64(3), cmap{{uint64(1), uint64(15)}}}})),
	}
}

func TestGoldenVectors(t *testing.T) {
	got := goldenVectors(t)
	b, _ := json.MarshalIndent(got, "", "  ")
	b = append(b, '\n')
	if os.Getenv("PROVCLIENT_UPDATE_GOLDEN") == "1" {
		if err := os.WriteFile(goldenPath, b, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	old, err := os.ReadFile(goldenPath)
	if err != nil {
		t.Fatalf("%s: %v (PROVCLIENT_UPDATE_GOLDEN=1 writes it)", goldenPath, err)
	}
	if string(old) != string(b) {
		t.Fatalf("%s differs from what this client sends:\n%s", goldenPath, b)
	}
	// the error reply, read the way the CLI reads it
	x, _, err := cDec(mustDecodeHex(t, got["error_reply_24_15"]))
	if err != nil {
		t.Fatal(err)
	}
	m := x.(cmap)
	code, _ := m.get(2).(uint64)
	res, _ := m.get(3).(cmap)
	if l := resultLine("update.prepare", code, res, ""); l != "RESULT update.prepare code=24 reason=15" {
		t.Fatalf("errBody reply read as %q", l)
	}
}

func mustDecodeHex(t *testing.T, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(s)
	if err != nil {
		t.Fatal(err)
	}
	return b
}
