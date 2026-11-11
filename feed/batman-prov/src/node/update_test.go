package node

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"strings"
	"testing"
	"time"

	"batman-prov/cbor"
	"batman-prov/provstore"
	"batman-prov/release"
)

// fakeUpd: a scripted UpdateSys (254-p3-impl §3.7.4).
type fakeUpd struct {
	trust   release.Trust
	ver     string
	board   string
	mem     uint64
	up      int
	boot    string
	active  string
	rc      map[string]int    // batman-slot verb -> rc
	out     map[string]string // batman-slot verb -> stdout
	calls   []string
	presave int
	onSlot  func(verb string)
}

func (f *fakeUpd) Trust() release.Trust         { return f.trust }
func (f *fakeUpd) Build() (string, string)      { return f.ver, f.board }
func (f *fakeUpd) MemAvailable() (uint64, bool) { return f.mem, f.mem != 0 }
func (f *fakeUpd) Uptime() int                  { return f.up }
func (f *fakeUpd) BootID() string               { return f.boot }
func (f *fakeUpd) ActiveSlot() string           { return f.active }
func (f *fakeUpd) PreSave()                     { f.presave++ }
func (f *fakeUpd) Slot(_ time.Duration, args ...string) (int, string) {
	f.calls = append(f.calls, strings.Join(args, " "))
	if f.onSlot != nil {
		f.onSlot(args[0])
	}
	return f.rc[args[0]], f.out[args[0]]
}

func relManifest(t *testing.T, name string) []byte {
	t.Helper()
	b, err := os.ReadFile("../release/testdata/" + name + ".manifest")
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func relTrust(t *testing.T) release.Trust {
	t.Helper()
	b, _ := os.ReadFile("../release/testdata/T.pub")
	p, _ := hex.DecodeString(strings.TrimSpace(string(b)))
	return release.Trust{Root: p, MinSerial: 1, State: "test"}
}

func bootinfoOut(bootcfg string) string {
	return "verified=-\nbad=0\nbootcfg=" + bootcfg + "\n--\n[pi4]\n"
}

func updRig(t *testing.T) (*Node, *fakeUpd, *time.Time) {
	t.Helper()
	n := New(provstore.Paths{}, nil, nil, func(string, ...any) {})
	clk := time.Unix(1_000_000, 0)
	n.clock = func() time.Time { return clk }
	f := &fakeUpd{trust: relTrust(t), ver: "1.5.14-wsl.25+fbc01ae.fw02f0913", board: "ekh-bcm2711", mem: 1 << 30, up: 100,
		boot: "11111111-2222-3333-4444-555555555555", active: "A", rc: map[string]int{}, out: map[string]string{}}
	n.SetUpdateSource(f, nil)
	return n, f, &clk
}

// wire: a map as the socket delivers it (encoded, then decoded: integer keys become uint64)
func wire(t *testing.T, m cbor.Map) cbor.Map {
	t.Helper()
	b, err := cbor.Encode(m)
	if err != nil {
		t.Fatal(err)
	}
	x, err := cbor.Decode(b)
	if err != nil {
		t.Fatal(err)
	}
	return x.(cbor.Map)
}

func check(t *testing.T, n *Node, clk *time.Time, m []byte, owner string) (bool, uint64, uint64, *Error) {
	t.Helper()
	*clk = clk.Add(11 * time.Second) // past the helper-wide 1 / 10 s
	res, e := n.updateCheck(wire(t, cbor.M(1, m, 2, []byte(owner))))
	if e != nil {
		return false, 0, 0, e
	}
	okv, _ := res.Get(1)
	rv, _ := res.Get(2)
	ram, _ := res.Get(3)
	r, _ := rv.(uint64)
	ru, _ := ram.(uint64)
	return okv == true, r, ru, nil
}

func TestUpdateCheckAccepts(t *testing.T) {
	n, f, clk := updRig(t)
	ok, reason, ram, e := check(t, n, clk, relManifest(t, "plain"), "o1")
	if e != nil || !ok || reason != 0 {
		t.Fatalf("plain: ok=%v reason=%d err=%v", ok, reason, e)
	}
	if ram != 446+150 {
		t.Fatalf("ram %d, want payload + boot total", ram)
	}
	if f.presave != 1 || len(f.calls) != 1 || f.calls[0] != "precheck-node" {
		t.Fatalf("calls %v presave %d", f.calls, f.presave)
	}
	if p := n.upd.validPending(); p == nil || p.R.Version != "1.5.14-wsl.30+abcdef1.fw0123456" || p.Expiry != 100+pendingTTL {
		t.Fatalf("pending %+v", p)
	}
}

func TestUpdateCheckRefusals(t *testing.T) {
	cases := []struct {
		name   string
		mod    func(*fakeUpd)
		man    string
		reason uint64
	}{
		{"board", func(f *fakeUpd) { f.board = "ekh-bcm2710" }, "plain", release.ReasonBoard},
		{"downgrade", func(f *fakeUpd) { f.ver = "1.5.14-wsl.31" }, "plain", release.ReasonDowngrade},
		{"no key", func(f *fakeUpd) { f.trust = release.Trust{State: "none"} }, "plain", release.ReasonNoKey},
		{"bad sig", func(*fakeUpd) {}, "bad_sig", release.ReasonBad},
		{"trial", func(f *fakeUpd) { f.rc["precheck-node"] = 10 }, "plain", 1},
		{".txn", func(f *fakeUpd) { f.rc["precheck-node"] = 11 }, "plain", 12},
		{"p5 stale", func(f *fakeUpd) { f.rc["precheck-node"] = 12 }, "plain", 17},
		{"p5 unseeded", func(f *fakeUpd) { f.rc["precheck-node"] = 16 }, "plain", 2},
		{"fw override", func(f *fakeUpd) { f.rc["precheck-node"] = 17 }, "plain", 21},
		{"card", func(f *fakeUpd) { f.rc["precheck-node"] = 18 }, "plain", 21},
		{"timeout", func(f *fakeUpd) { f.rc["precheck-node"] = 124 }, "plain", 21},
		{"internal", func(f *fakeUpd) { f.rc["precheck-node"] = 1 }, "plain", 21},
		{"ram", func(f *fakeUpd) { f.mem = 64<<20 + 100 }, "plain", 8},
		{"bootcfg differs", func(f *fakeUpd) { f.out["bootinfo"] = bootinfoOut(strings.Repeat("ab", 32)) }, "ok", release.ReasonBootCfg},
		{"bootinfo broken", func(f *fakeUpd) { f.out["bootinfo"] = "verified=-\nbad=0\n--\n" }, "ok", 21},
		{"bootinfo rc 18", func(f *fakeUpd) { f.rc["bootinfo"] = 18 }, "ok", 21},
	}
	for _, c := range cases {
		n, f, clk := updRig(t)
		c.mod(f)
		ok, reason, _, e := check(t, n, clk, relManifest(t, c.man), "o1")
		if e != nil || ok || reason != c.reason {
			t.Fatalf("%s: ok=%v reason=%d err=%v (want reason %d)", c.name, ok, reason, e, c.reason)
		}
		if n.upd.validPending() != nil {
			t.Fatalf("%s: a refused check wrote a pending", c.name)
		}
	}
	// precheck-node rc 14 -> E_BUSY (retryable), no pending
	n, f, clk := updRig(t)
	f.rc["precheck-node"] = 14
	if _, _, _, e := check(t, n, clk, relManifest(t, "plain"), "o1"); e == nil || e.Code != EBusy {
		t.Fatalf("rc 14: %v (want EBusy)", e)
	}
}

func TestUpdateCheckBootCfgMatches(t *testing.T) {
	n, f, clk := updRig(t)
	h := sha256.Sum256([]byte("cfg")) // signrel's ok manifest lists sha256("cfg")
	f.out["bootinfo"] = bootinfoOut(hex.EncodeToString(h[:]))
	ok, reason, _, e := check(t, n, clk, relManifest(t, "ok"), "o1")
	if e != nil || !ok {
		t.Fatalf("bootcfg in the list: ok=%v reason=%d %v", ok, reason, e)
	}
	if got := strings.Join(f.calls, ","); got != "precheck-node,bootinfo B" {
		t.Fatalf("calls %s (want the TARGET slot B's bootinfo)", got)
	}
}

func TestUpdateCheckRateAndOwners(t *testing.T) {
	n, f, clk := updRig(t)
	if ok, _, _, e := check(t, n, clk, relManifest(t, "plain"), "o1"); !ok || e != nil {
		t.Fatal(e)
	}
	// 1 / 10 s helper-wide
	if _, e := n.updateCheck(wire(t, cbor.M(1, relManifest(t, "plain"), 2, []byte("o1")))); e == nil || e.Code != ERate {
		t.Fatalf("second check at once: %v (want ERate)", e)
	}
	// another owner while o1's pending is valid -> busy; the same owner -> overwrites
	if _, _, _, e := check(t, n, clk, relManifest(t, "plain"), "o2"); e == nil || e.Code != EBusy {
		t.Fatalf("other owner: %v (want EBusy)", e)
	}
	if ok, _, _, e := check(t, n, clk, relManifest(t, "plain"), "o1"); !ok || e != nil {
		t.Fatalf("same owner again: %v", e)
	}
	// o1's pending expires -> o2 may check
	f.up += pendingTTL
	if ok, _, _, e := check(t, n, clk, relManifest(t, "plain"), "o2"); !ok || e != nil {
		t.Fatalf("other owner after expiry: %v", e)
	}
	// a pending of another boot does not count
	f.boot = "99999999-2222-3333-4444-555555555555"
	if n.upd.validPending() != nil {
		t.Fatal("a pending of another boot is valid")
	}
	// the node checks run on every check (the signature result is the only cache): a .txn that appears is seen
	f.rc["precheck-node"] = 11
	if ok, reason, _, _ := check(t, n, clk, relManifest(t, "plain"), "o2"); ok || reason != 12 {
		t.Fatalf("cached node state: ok=%v reason=%d (want 12)", ok, reason)
	}
	f.rc["precheck-node"] = 0
	if ok, _, _, e := check(t, n, clk, relManifest(t, "plain"), "o2"); !ok || e != nil {
		t.Fatalf("after the .txn is gone: %v (a temporary refusal must not stick, A9-MAJOR-2)", e)
	}
}

func TestUpdateCheckOutsideMu(t *testing.T) {
	n, _, clk := updRig(t)
	*clk = clk.Add(11 * time.Second)
	n.mu.Lock() // a long state-changing verb holds n.mu
	done := make(chan cbor.Map, 1)
	go func() {
		done <- n.Handle(wire(t, cbor.M(1, "update.check", 2, uint64(7), 3, cbor.M(1, relManifest(t, "plain"), 2, []byte("o1")))))
	}()
	select {
	case r := <-done:
		n.mu.Unlock()
		if c, _ := r.Get(2); c != uint64(OK) {
			t.Fatalf("update.check: code %v", c)
		}
	case <-time.After(3 * time.Second):
		n.mu.Unlock()
		t.Fatal("update.check waited for n.mu (design D-12)")
	}
}

func TestUpdateUnwired(t *testing.T) {
	n := New(provstore.Paths{}, nil, nil, func(string, ...any) {})
	if _, e := n.updateCheck(wire(t, cbor.M(1, []byte{1}, 2, []byte("o")))); e == nil || e.Code != EUnsupported {
		t.Fatalf("unwired: %v", e)
	}
}

func TestParseBootinfo(t *testing.T) {
	v := strings.Repeat("a", 64) + " 11111111-2222-3333-4444-555555555555"
	good := "verified=" + v + "\nbad=1\nbootcfg=" + strings.Repeat("c", 64) + "\n--\n[pi4]\ndtoverlay=miniuart-bt\n"
	si, ok := parseBootinfo(good)
	if !ok || si.Verified != v || !si.Bad || si.Distroconfig != "[pi4]\ndtoverlay=miniuart-bt\n" {
		t.Fatalf("good: %v %+v", ok, si)
	}
	for name, s := range map[string]string{
		"no separator":      "verified=-\nbad=0\nbootcfg=" + strings.Repeat("c", 64) + "\n",
		"duplicate":         "verified=-\nverified=-\nbad=0\nbootcfg=" + strings.Repeat("c", 64) + "\n--\n",
		"missing bad":       "verified=-\nbootcfg=" + strings.Repeat("c", 64) + "\n--\n",
		"upper hex":         "verified=-\nbad=0\nbootcfg=" + strings.Repeat("C", 64) + "\n--\n",
		"short verified":    "verified=abc 1\nbad=0\nbootcfg=" + strings.Repeat("c", 64) + "\n--\n",
		"unknown key":       "verified=-\nbad=0\nbootcfg=" + strings.Repeat("c", 64) + "\nx=1\n--\n",
		"stderr noise line": "batman-slot: WARN: x\nverified=-\nbad=0\nbootcfg=" + strings.Repeat("c", 64) + "\n--\n",
	} {
		if _, ok := parseBootinfo(s); ok {
			t.Fatalf("%s: accepted", name)
		}
	}
}
