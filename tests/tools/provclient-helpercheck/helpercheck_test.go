// Package helpercheck — the out-of-tree check of provclient's P3 request vectors against the REAL helper decoder
// (254-v16-ud §3.1 / §9 item 2; a separate module so nothing under feed/ changes: `replace batman-prov =>
// ../../../feed/batman-prov/src`). It reads ../provclient/testdata/p3-requests.json (written by provclient's
// golden_test.go), decodes each request with batman-prov/cbor and runs it through node.New(...).Handle with a fake
// UpdateSys (node.SetUpdateSource):
//   - the pre-UD update.check body {1: manifest map}      -> code 20 (ESchema); the helper logs "arg 1: want 0 bytes"
//     (bytesArg on key 1 refuses the map before key 2 is looked at);
//   - provclient's update.check body {1: manifest, 2: kid} -> past the schema check: code 0 (the fake trusts no root,
//     so the answer is ok=false reason 24 — a refusal of the manifest, not of the shape);
//   - the bulk.open bodies: the new one has key 2 = 32 bytes (what bulk.go:42-51 requires), the old one has no key 2
//     (bulk.open itself is an owner-op on a claimed record, not reachable here);
//   - the sample error reply decodes with the helper's cbor to {1: id, 2: 24, 3: {1: 15}}, errBody's shape
//     (node.go:75-81). errBody is unexported and every reason-carrying failR path needs a claimed record and an owner-op,
//     so the reply is compared with the helper's own encoding of that shape, not produced by errBody itself.
//
// Offline: GOFLAGS=-mod=mod GOPROXY=off (the module cache holds the feed's x/crypto / x/sys / noise / dbus).
package helpercheck

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"batman-prov/cbor"
	"batman-prov/node"
	"batman-prov/provstore"
	"batman-prov/release"
)

type fakeUpd struct{ checks int }

func (f *fakeUpd) Trust() release.Trust                        { return release.Trust{} }
func (f *fakeUpd) Build() (string, string)                     { return "1.5.14-wsl.36", "ekh-bcm2711" }
func (f *fakeUpd) MemAvailable() (uint64, bool)                { return 1 << 30, true }
func (f *fakeUpd) Uptime() int                                 { return 100 }
func (f *fakeUpd) BootID() string                              { return "11111111-2222-3333-4444-555555555555" }
func (f *fakeUpd) ActiveSlot() string                          { return "A" }
func (f *fakeUpd) PreSave()                                    {}
func (f *fakeUpd) RootBytes(string) (int64, bool)              { return 1 << 30, true }
func (f *fakeUpd) Slot(time.Duration, ...string) (int, string) { f.checks++; return 0, "" }

func vectors(t *testing.T) map[string]string {
	t.Helper()
	b, err := os.ReadFile("../provclient/testdata/p3-requests.json")
	if err != nil {
		t.Fatal(err)
	}
	v := map[string]string{}
	if err := json.Unmarshal(b, &v); err != nil {
		t.Fatal(err)
	}
	for _, k := range []string{"update_check_new", "update_check_old", "bulk_open_body_new", "bulk_open_body_old", "error_reply_24_15"} {
		if v[k] == "" {
			t.Fatalf("vector %s missing", k)
		}
	}
	return v
}

func decode(t *testing.T, h string) cbor.Map {
	t.Helper()
	b, err := hex.DecodeString(h)
	if err != nil {
		t.Fatal(err)
	}
	x, err := cbor.Decode(b)
	if err != nil {
		t.Fatalf("the helper's cbor refuses %s…: %v", h[:16], err)
	}
	m, ok := x.(cbor.Map)
	if !ok {
		t.Fatalf("not a map: %T", x)
	}
	return m
}

func get(m cbor.Map, k uint64) any { v, _ := m.Get(int(k)); return v }

// handle: one request through a fresh node (the helper-wide check rate is per node), returns code + result + log
func handle(t *testing.T, req cbor.Map) (uint64, cbor.Map, string) {
	t.Helper()
	var log strings.Builder
	n := node.New(provstore.Paths{}, nil, nil, func(f string, a ...any) { fmt.Fprintf(&log, f+"\n", a...) })
	n.SetUpdateSource(&fakeUpd{}, nil)
	resp := n.Handle(req)
	code, _ := get(resp, 2).(uint64)
	res, _ := get(resp, 3).(cbor.Map)
	return code, res, log.String()
}

func TestUpdateCheckOldShapeIsESchema(t *testing.T) {
	code, _, log := handle(t, decode(t, vectors(t)["update_check_old"]))
	if code != 20 || !strings.Contains(log, "verb update.check refused: code 20 (arg 1: want 0 bytes)") {
		t.Fatalf("pre-UD update.check: code %d, log %q (want 20, arg 1: want 0 bytes)", code, log)
	}
}

func TestUpdateCheckNewShapePassesSchema(t *testing.T) {
	code, res, log := handle(t, decode(t, vectors(t)["update_check_new"]))
	if code != 0 {
		t.Fatalf("provclient's update.check: code %d, log %q (want 0: past the schema check)", code, log)
	}
	ok, _ := get(res, 1).(bool)
	reason, _ := get(res, 2).(uint64)
	if ok || reason != 24 {
		t.Fatalf("want ok=false reason=24 (no root key in the fake), got ok=%v reason=%d", ok, reason)
	}
}

func TestBulkOpenBodies(t *testing.T) {
	v := vectors(t)
	nb := decode(t, v["bulk_open_body_new"])
	sha, _ := get(nb, 2).([]byte)
	purpose, _ := get(nb, 1).(uint64)
	if len(nb) != 2 || purpose != 0 || len(sha) != 32 {
		t.Fatalf("new bulk.open body %v: want {1: 0, 2: 32 bytes}", nb)
	}
	ob := decode(t, v["bulk_open_body_old"])
	if _, has := ob.Get(2); has {
		t.Fatal("the old body was expected to lack key 2 (bulk.go: 'body key 2: a sha256')")
	}
}

func TestErrorReplyIsErrBodyShape(t *testing.T) {
	h := vectors(t)["error_reply_24_15"]
	got, _ := hex.DecodeString(h)
	want, err := cbor.Encode(cbor.M(1, uint64(1), 2, uint64(24), 3, cbor.M(1, uint64(15))))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("error reply %x != the helper's encoding of errBody's shape %x", got, want)
	}
}
