package release

import (
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"batman-prov/cbor"
)

// testdata/ comes from the harness signer tests/tools/peer/signrel.py (the format contract, 254-p3-impl §3.7.1 /
// §12.5: "signrel's positive objects Go accepts; every negative flag Go refuses").

func readPub(t *testing.T, name string) []byte {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", name))
	if err != nil {
		t.Fatal(err)
	}
	p, err := hex.DecodeString(strings.TrimSpace(string(b)))
	if err != nil {
		t.Fatal(err)
	}
	return p
}

func manifest(t *testing.T, name string) []byte {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", name+".manifest"))
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func trustT(t *testing.T, min uint64) Trust {
	return Trust{Root: readPub(t, "T.pub"), MinSerial: min, State: "test"}
}

func TestVerifySignrelPositive(t *testing.T) {
	var cases struct {
		OK struct {
			Version       string   `json:"version"`
			Board         string   `json:"board"`
			SumsSha       string   `json:"sums_sha"`
			MinFrom       string   `json:"min_from"`
			Size          uint64   `json:"size"`
			BootTotal     uint64   `json:"boot_total"`
			Serial        uint64   `json:"serial"`
			DowngradeFrom []string `json:"downgrade_from"`
			BootCfg       []string `json:"bootcfg"`
		} `json:"ok"`
	}
	b, _ := os.ReadFile("testdata/cases.json")
	if err := json.Unmarshal(b, &cases); err != nil {
		t.Fatal(err)
	}
	r, e := Verify(manifest(t, "ok"), trustT(t, 1))
	if e != nil {
		t.Fatalf("signrel ok manifest refused: %v", e)
	}
	c := cases.OK
	if r.Version != c.Version || r.Board != c.Board || r.Size != c.Size || hex.EncodeToString(r.SumsSha) != c.SumsSha ||
		r.BootTotal != c.BootTotal || r.Serial != c.Serial || r.MinFrom != c.MinFrom ||
		len(r.DowngradeFrom) != 1 || r.DowngradeFrom[0] != c.DowngradeFrom[0] ||
		len(r.BootCfg) != 1 || hex.EncodeToString(r.BootCfg[0]) != c.BootCfg[0] {
		t.Fatalf("fields differ from signrel's: %+v vs %+v", r, c)
	}
	if len(r.ManifestSha) != 32 {
		t.Fatal("no manifest sha")
	}
	if _, e := Verify(manifest(t, "plain"), trustT(t, 1)); e != nil {
		t.Fatalf("plain: %v", e)
	}
	// board is the caller's check: a wrong board still verifies, and says so
	r, e = Verify(manifest(t, "wrong_board"), trustT(t, 1))
	if e != nil || r.Board != "ekh-bcm2711-wrong" {
		t.Fatalf("wrong_board: %v %v", e, r)
	}
}

func TestVerifySignrelNegative(t *testing.T) {
	for _, n := range []string{"key_other", "bad_sig", "mismatch_size", "unparsable_version"} {
		if _, e := Verify(manifest(t, n), trustT(t, 1)); e == nil || e.Reason != ReasonBad {
			t.Fatalf("%s: %v (want reason 11)", n, e)
		}
	}
	// another root
	if _, e := Verify(manifest(t, "ok"), Trust{Root: readPub(t, "other.pub"), MinSerial: 1, State: "x"}); e == nil || e.Reason != ReasonBad {
		t.Fatalf("other root: %v", e)
	}
	// revocation: E serial 1 against min-serial 2
	if _, e := Verify(manifest(t, "serial1"), trustT(t, 1)); e != nil {
		t.Fatalf("serial 1 vs min 1: %v", e)
	}
	if _, e := Verify(manifest(t, "serial1"), trustT(t, 2)); e == nil || e.Reason != ReasonBad {
		t.Fatalf("serial 1 vs min 2: %v (want revoked)", e)
	}
	// no key in the image -> 24, whatever the manifest
	if _, e := Verify(manifest(t, "ok"), Trust{State: "none"}); e == nil || e.Reason != ReasonNoKey {
		t.Fatalf("no trust: %v (want 24)", e)
	}
	// the manifest's own copy of key 1 tampered (S still verifies) -> 11
	it, _ := cbor.Decode(manifest(t, "ok"))
	m := it.(cbor.Map)
	for i := range m {
		if m[i].K == uint64(1) {
			m[i].V = "1.5.99-wsl.1"
		}
	}
	tb, _ := cbor.Encode(m)
	if _, e := Verify(tb, trustT(t, 1)); e == nil || e.Reason != ReasonBad {
		t.Fatalf("tampered manifest key 1: %v", e)
	}
	// not CBOR / truncated
	ok := manifest(t, "ok")
	for _, bad := range [][]byte{nil, []byte("x"), ok[:len(ok)-1]} {
		if _, e := Verify(bad, trustT(t, 1)); e == nil || e.Reason != ReasonBad {
			t.Fatalf("garbage %x: %v", bad, e)
		}
	}
}

func TestLoadTrust(t *testing.T) {
	real := fsCheck
	defer func() { fsCheck = real }()
	fsCheck = func(int) bool { return true }
	tp, _ := os.ReadFile("testdata/T.pub") // one line + "\n", 131 B like tests/keys/T.pub
	write := func(dir, name, s string) { _ = os.WriteFile(filepath.Join(dir, name), []byte(s), 0o644) }
	d := t.TempDir()
	if s := LoadTrust(d).State; s != "none" {
		t.Fatalf("empty dir: %s", s)
	}
	if s := LoadTrust(filepath.Join(d, "nope")).State; s != "none" {
		t.Fatalf("missing dir: %s", s)
	}
	write(d, "release-root.pub", string(tp))
	if s := LoadTrust(d).State; s != "bad" {
		t.Fatalf("only the pub: %s (want bad)", s)
	}
	write(d, "release-min-serial", "1\n")
	tr := LoadTrust(d)
	if tr.Root == nil || tr.MinSerial != 1 || len(tr.State) != 16 {
		t.Fatalf("good pair: %+v", tr)
	}
	for name, cnt := range map[string][2]string{
		"serial 0":         {string(tp), "0\n"},
		"serial two lines": {string(tp), "1\n2\n"},
		"pub not hex":      {strings.Replace(string(tp), "0", "g", 1), "1\n"},
		"pub off curve":    {"04" + strings.Repeat("11", 64) + "\n", "1\n"},
		"pub too long":     {strings.Repeat("0", 300), "1\n"},
		"pub CRLF":         {strings.TrimSpace(string(tp)) + "\r\n", "1\n"},
	} {
		dd := t.TempDir()
		write(dd, "release-root.pub", cnt[0])
		write(dd, "release-min-serial", cnt[1])
		if s := LoadTrust(dd).State; s != "bad" {
			t.Fatalf("%s: %s (want bad)", name, s)
		}
	}
	// a symlink and a FIFO are refused, the FIFO without hanging (O_NONBLOCK)
	ds := t.TempDir()
	write(ds, "target", string(tp))
	_ = os.Symlink(filepath.Join(ds, "target"), filepath.Join(ds, "release-root.pub"))
	write(ds, "release-min-serial", "1\n")
	if s := LoadTrust(ds).State; s != "bad" {
		t.Fatalf("symlink: %s", s)
	}
	df := t.TempDir()
	if err := syscall.Mkfifo(filepath.Join(df, "release-root.pub"), 0o644); err != nil {
		t.Fatal(err)
	}
	write(df, "release-min-serial", "1\n")
	done := make(chan string, 1)
	go func() { done <- LoadTrust(df).State }()
	select {
	case s := <-done:
		if s != "bad" {
			t.Fatalf("fifo: %s", s)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("LoadTrust hung on a FIFO")
	}
	// production check: a tmpdir is not the squashfs -> bad (the overlay can never supply a key)
	fsCheck = real
	if s := LoadTrust(d).State; s != "bad" {
		t.Fatalf("not squashfs: %s (want bad)", s)
	}
}

func TestVersionRule(t *testing.T) {
	for _, s := range []string{"1.5.14-wsl.25+fbc01ae.fw02f0913", "1.5.14", "1.6.0-rel.3", "1.5.14-ci.7+x.dirty.wbox-ud-x",
		"1.5.14-wsl.2+F7.fwW7.bench.dirty"} {
		if _, ok := ParseVersion(s); !ok {
			t.Fatalf("%s unparsable", s)
		}
	}
	for _, s := range []string{"1.5.14-wsl", "1.5.14-foo.1", "1.5", "v1.5.14", "1.5.14-wsl.1+", "1.5.14-wsl.1+a b"} {
		if _, ok := ParseVersion(s); ok {
			t.Fatalf("%s parsed", s)
		}
	}
	rel := func(v string, down ...string) *Release { return &Release{Version: v, DowngradeFrom: down} }
	cases := []struct {
		cur  string
		r    *Release
		want uint64
	}{
		{"1.5.14-wsl.25+a", rel("1.5.14-wsl.26+b"), 0},                // newer N
		{"1.5.14-wsl.25+a", rel("1.5.14-wsl.25+zzz"), 0},              // equal (meta ignored) = reinstall
		{"1.5.14-wsl.25+a", rel("1.5.14-wsl.24"), ReasonDowngrade},    // older N
		{"1.5.14-wsl.25+a", rel("1.5.14-wsl.24", "1.5.14-wsl.25"), 0}, // older, listed in key 6
		{"1.5.14-wsl.25", rel("1.5.15-wsl.1"), 0},                     // newer REL
		{"1.5.15-wsl.1", rel("1.5.14-wsl.99"), ReasonDowngrade},       // older REL
		{"1.5.14-wsl.25", rel("1.5.14"), 0},                           // shipped > -CH.N (D12)
		{"1.5.14", rel("1.5.14-wsl.30"), ReasonDowngrade},             // shipped -> dev needs key 6
		{"1.5.14-wsl.25", rel("1.5.14-ci.3"), ReasonDowngrade},        // cross-channel: no order
		{"1.5.14-wsl.25+x", rel("1.5.14-ci.3", "1.5.14-wsl.25"), 0},   // cross-channel, listed
		{"1.5.14-wsl.25", rel("1.5.14-rel.1"), ReasonDowngrade},       // transition release is cross-channel: key 6 needed
	}
	for _, c := range cases {
		if got, why := Decide(c.cur, c.r); got != c.want {
			t.Fatalf("%s -> %s: %d (%s), want %d", c.cur, c.r.Version, got, why, c.want)
		}
	}
	// key 7: min_from
	r := &Release{Version: "1.6.0-wsl.1", MinFrom: "1.5.14-wsl.20"}
	if got, _ := Decide("1.5.14-wsl.19", r); got != ReasonIntermediate {
		t.Fatalf("below min_from: %d", got)
	}
	if got, _ := Decide("1.5.14-wsl.20", r); got != 0 {
		t.Fatalf("at min_from: %d", got)
	}
	if got, _ := Decide("1.5.14-ci.50", r); got != ReasonIntermediate {
		t.Fatalf("min_from on another channel (no order): %d (want 4, fail-closed)", got)
	}
}
