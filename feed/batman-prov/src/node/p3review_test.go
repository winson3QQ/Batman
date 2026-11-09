package node

// #324 code / security review of the P3 implementation (2026-11-09): each test fails without its fix.

import (
	"bytes"
	"testing"
	"time"

	"batman-prov/cbor"
)

// review A M2: after a quiet spell (> statusStaleAfter) the first status is a fresh read, not the hours-old cache
func TestStatusOldCacheIsReread(t *testing.T) {
	f := &fakeStatus{js: hs04(t), p5: true, inline: true}
	r, now := statusRig(t, f)
	if v, _ := key(statusCall(t, r, true), 3); v != uint64(1) {
		t.Fatalf("first read: neighbours %v", v)
	}
	f.mu.Lock()
	f.js = bytes.Replace(hs04(t), []byte(`"batman_neighbours":1`), []byte(`"batman_neighbours":3`), 1)
	f.mu.Unlock()
	*now = now.Add(11 * time.Minute)
	if v, _ := key(statusCall(t, r, true), 3); v != uint64(3) {
		t.Fatalf("after 11 min idle: neighbours %v, want the fresh 3 (not the old cache)", v)
	}
}

// review A M2: an old cache that cannot be refreshed in time is answered as stale, not as current
func TestStatusOldCacheNotShownAsCurrent(t *testing.T) {
	f := &fakeStatus{js: hs04(t), p5: true, inline: true}
	r, now := statusRig(t, f)
	statusCall(t, r, true)
	f.gate = make(chan struct{}) // the next refresh never returns in time
	r.n.status.runAsync = func(fn func()) { go fn() }
	*now = now.Add(11 * time.Minute)
	m := statusCall(t, r, true)
	close(f.gate)
	if _, ok := key(m, 3); ok {
		t.Fatalf("an 11-minute-old cache answered as current: %v", m)
	}
	v, _ := key(m, 15)
	fm, _ := v.(cbor.Map)
	if s, _ := fm.Get("stale"); s != true {
		t.Fatalf("no stale mark: %v", m)
	}
}

// review A M2: settings.get re-reads an old cache too
func TestSettingsOldCacheIsReread(t *testing.T) {
	r, now, n := settingsRig(t, Settings{Hostname: "h", Country: "US", Channel: "42"}, nil, 0)
	if c, _ := r.call("settings.get", cbor.M()); c != OK {
		t.Fatalf("settings.get %d", c)
	}
	before := n.Load()
	*now = now.Add(11 * time.Minute)
	if c, _ := r.call("settings.get", cbor.M()); c != OK {
		t.Fatalf("settings.get after idle %d", c)
	}
	if n.Load() == before {
		t.Fatal("after 11 min idle settings.get answered from the old cache without reading")
	}
}

// D-6: setkey rc 6 -> EApply reason 13, CRIT, status key 15 settings_restore until a later set succeeds
func TestSettingsSetRestoreNotVerified(t *testing.T) {
	f := &fakeStatus{js: hs04(t), p5: true, inline: true}
	r, _ := statusRig(t, f)
	var logs []string
	r.n.Log = func(s string, a ...any) { logs = append(logs, s) }
	r.sys.setRC = 6
	c, b := r.settingsSet(cbor.M(2, "JP"))
	if c != EApply || reasonOf(b) != ReasonBadValue {
		t.Fatalf("rc 6: code %d reason %d, want EApply 13", c, reasonOf(b))
	}
	crit := false
	for _, l := range logs {
		if len(l) >= 4 && l[:4] == "CRIT" {
			crit = true
		}
	}
	if !crit {
		t.Fatal("rc 6 without a CRIT log")
	}
	v, _ := key(statusCall(t, r, true), 15)
	fm, _ := v.(cbor.Map)
	if s, _ := fm.Get("settings_restore"); s != "not verified" {
		t.Fatalf("status key 15 settings_restore = %v", s)
	}
	r.sys.setRC = 0
	if c, _ := r.settingsSet(cbor.M(2, "JP")); c != OK {
		t.Fatalf("set after: %d", c)
	}
	v, _ = key(statusCall(t, r, true), 15)
	fm, _ = v.(cbor.Map)
	if _, ok := fm.Get("settings_restore"); ok {
		t.Fatal("settings_restore still reported after a successful set")
	}
}

// D-12: key 15 carries uci_staged and ssid_unsaved when the source reports them
func TestStatusStagedAndUnsavedSSID(t *testing.T) {
	f := &fakeStatus{js: hs04(t), p5: true, inline: true}
	r := claimedRig(t)
	now := time.Unix(1000, 0)
	r.n.clock = func() time.Time { return now }
	src := f.src()
	src.UciStaged = func() []string { return []string{"wireless"} }
	src.SSIDUnsaved = func() bool { return true }
	r.n.SetStatusSource(src)
	r.n.status.runAsync = func(fn func()) { fn() }
	v, _ := key(statusCall(t, r, true), 15)
	fm, _ := v.(cbor.Map)
	if s, _ := fm.Get("uci_staged"); len(s.([]any)) != 1 || s.([]any)[0] != "wireless" {
		t.Fatalf("uci_staged = %v", s)
	}
	if s, _ := fm.Get("ssid_unsaved"); s != true {
		t.Fatalf("ssid_unsaved = %v", s)
	}
	if v, ok := key(statusCall(t, r, false), 15); ok {
		t.Fatalf("a member got key 15: %v", v)
	}
}

// security review m1 (defence in depth): the helper refuses AP values halow-setkey would refuse, before calling it
func TestSettingsSetAPValuesCheckedFirst(t *testing.T) {
	r := claimedRig(t)
	for _, ap := range []cbor.Map{
		cbor.M(1, "Team 1", 2, "Abcdefgh1234\nxyz"), // a second line
		cbor.M(1, "Team 1", 2, "short"),
		cbor.M(1, "Team'1", 2, "Abcdefgh1234"),
		cbor.M(1, " lead", 2, "Abcdefgh1234"),
		cbor.M(1, "Team 1", 2, "has space 12345"),
	} {
		if c, b := r.settingsSet(cbor.M(20, ap)); c != EInput || reasonOf(b) != ReasonBadValue {
			t.Fatalf("AP %v: code %d reason %d, want EInput 13", ap, c, reasonOf(b))
		}
	}
	if len(r.sys.setAP) != 0 {
		t.Fatalf("halow-setkey called with a refused value: %v", r.sys.setAP)
	}
}

// review A m5: no settings.set while batman-slot writes the other slot
func TestSettingsSetDuringOTA(t *testing.T) {
	r := claimedRig(t)
	writeFile(t, r.n.P.RunDir+"/batman-slot.busy", nil)
	if c, _ := r.settingsSet(cbor.M(2, "JP")); c != EBusy {
		t.Fatalf("settings.set during an OTA: %d (want EBusy)", c)
	}
	if len(r.sys.setCountry) != 0 {
		t.Fatal("halow-setkey called during an OTA")
	}
}
