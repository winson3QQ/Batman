package node

// #324 review round 3 (code A / security B): each test fails without its fix

import (
	"sync/atomic"
	"testing"
	"time"

	"batman-prov/cbor"
)

// A r3 m2: after a set the cache is re-read by a read that starts after it — whatever halow-setkey answered; a
// background read that started before the set does not overwrite it
func TestSettingsRereadAfterEverySet(t *testing.T) {
	r := claimedRig(t)
	now := time.Unix(1000, 0)
	r.n.clock = func() time.Time { return now }
	var cc atomic.Value
	cc.Store("US")
	var reads atomic.Int32
	r.n.SetSettingsSource(func() (Settings, error) {
		reads.Add(1)
		return Settings{Hostname: "h", Country: cc.Load().(string), Channel: "42"}, nil
	})
	r.n.settings.runAsync = func(f func()) { f() }
	r.call("settings.get", cbor.M()) // cache: US
	// a failed set (rc 3) whose live value changed anyway: the cache follows the live value
	r.sys.setRC = 3
	cc.Store("JP")
	before := reads.Load()
	if c, _ := r.settingsSet(cbor.M(2, "JP")); c != EInput {
		t.Fatalf("rc 3 -> %d", c)
	}
	if reads.Load() == before {
		t.Fatal("no re-read after a failed set")
	}
	if _, m := r.call("settings.get", cbor.M()); func() bool { v, _ := m.Get(2); return v != "JP" }() {
		t.Fatalf("cache after the failed set: %v (want the live JP)", m)
	}
	// an older background read finishing after readNow does not overwrite it
	gate := make(chan struct{})
	r.n.settings.runAsync = func(f func()) { go func() { <-gate; f() }() }
	cc.Store("AU")
	r.n.settings.refresh() // starts (blocked) with gen before readNow
	cc.Store("DE")
	r.n.settings.readNow()
	cc.Store("AU") // what the stale background read would store
	close(gate)
	time.Sleep(100 * time.Millisecond)
	r.n.settings.mu.Lock()
	got := r.n.settings.val.Country
	r.n.settings.mu.Unlock()
	if got != "DE" {
		t.Fatalf("an older background read overwrote readNow: %s", got)
	}
}

// A r3 m7: an exit code outside 0..6 (helper timeout 124) leaves the radio state unknown: CRIT + status flag
func TestSettingsSetTimeoutSetsFlag(t *testing.T) {
	f := &fakeStatus{js: hs04(t), p5: true, inline: true}
	r, _ := statusRig(t, f)
	crit := 0
	r.n.Log = func(s string, a ...any) {
		if len(s) >= 4 && s[:4] == "CRIT" {
			crit++
		}
	}
	r.sys.setRC = 124
	if c, _ := r.settingsSet(cbor.M(20, cbor.M(1, "Team 1", 2, "Abcdefgh1234"))); c != EApply {
		t.Fatalf("rc 124 -> %d, want EApply", c)
	}
	v, _ := key(statusCall(t, r, true), 15)
	if s, _ := v.(cbor.Map).Get("settings_restore"); s != "not verified" || crit == 0 {
		t.Fatalf("rc 124: settings_restore %v, CRIT logs %d", s, crit)
	}
}

// B r3 m2: a stale answer to a member has no key 15 at all (not left to provd's filter alone)
func TestStatusStaleMemberNoKey15(t *testing.T) {
	f := &fakeStatus{js: hs04(t), inline: true}
	r, now := statusRig(t, f)
	statusCall(t, r, false)
	f.gate = make(chan struct{})
	r.n.status.runAsync = func(fn func()) { go fn() }
	*now = now.Add(11 * time.Minute)
	m := statusCall(t, r, false)
	close(f.gate)
	if _, ok := key(m, 15); ok {
		t.Fatalf("member got key 15 on a stale answer: %v", m)
	}
}

// A r3 m6: an owner's status keeps the settings cache asked, so the ticker reads it (ssid_unsaved needs it)
func TestOwnerStatusKeepsSettingsAsked(t *testing.T) {
	f := &fakeStatus{js: hs04(t), p5: true, inline: true}
	r, _ := statusRig(t, f)
	var reads atomic.Int32
	r.n.SetSettingsSource(func() (Settings, error) {
		reads.Add(1)
		return Settings{Hostname: "h", Country: "US", Channel: "42", SSID: "Tom's AP"}, nil
	})
	r.n.settings.runAsync = func(fn func()) { fn() }
	statusCall(t, r, true)
	r.n.StatusTick()
	if reads.Load() == 0 {
		t.Fatal("an owner's status did not get the settings cache read")
	}
	v, _ := key(statusCall(t, r, true), 15)
	if s, _ := v.(cbor.Map).Get("ssid_unsaved"); s != true {
		t.Fatalf("ssid_unsaved after a status + tick: %v", s)
	}
}
