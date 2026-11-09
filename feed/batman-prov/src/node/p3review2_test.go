package node

import (
	"testing"
	"time"

	"batman-prov/cbor"
)

// design D-12: an ssid with a config-save UNSAFE character is not kept in p5
func TestConfigUnsafe(t *testing.T) {
	for _, v := range []string{"Tom's AP", "a;b", "$x", "a|b", "a&b", "<x>", "(x)", "`x`"} {
		if !ConfigUnsafe(v) {
			t.Fatalf("%q not unsafe", v)
		}
	}
	for _, v := range []string{"Team 1", "BCM2711-6c89", "a.b_c~d+e=f,g:h@i%j^k*l-m"} {
		if ConfigUnsafe(v) {
			t.Fatalf("%q unsafe", v)
		}
	}
}

// A r2 MAJOR-1: ssid_unsaved comes from the settings cache — status never calls a source for it on the request path
func TestStatusSSIDUnsavedFromSettingsCache(t *testing.T) {
	f := &fakeStatus{js: hs04(t), p5: true, inline: true}
	r, _ := statusRig(t, f)
	r.n.SetSettingsSource(func() (Settings, error) {
		return Settings{Hostname: "h", Country: "US", Channel: "42", SSID: "Tom's AP"}, nil
	})
	r.n.settings.runAsync = func(fn func()) { fn() }
	v, _ := key(statusCall(t, r, true), 15)
	if s, _ := v.(cbor.Map).Get("ssid_unsaved"); s != nil {
		t.Fatalf("ssid_unsaved before any settings read: %v", s)
	}
	if c, _ := r.call("settings.get", cbor.M()); c != OK {
		t.Fatalf("settings.get %d", c)
	}
	v, _ = key(statusCall(t, r, true), 15)
	if s, _ := v.(cbor.Map).Get("ssid_unsaved"); s != true {
		t.Fatalf("ssid_unsaved after reading \"Tom's AP\": %v", s)
	}
}

// A r2 m3: a country set returning 0 does not clear the D-6 flag of a failed AP restore; an AP set does
func TestRestoreFlagClearedOnlyByAP(t *testing.T) {
	f := &fakeStatus{js: hs04(t), p5: true, inline: true}
	r, now := statusRig(t, f)
	flag := func() bool {
		v, _ := key(statusCall(t, r, true), 15)
		s, _ := v.(cbor.Map).Get("settings_restore")
		return s == "not verified"
	}
	r.sys.setRC = 6
	r.settingsSet(cbor.M(20, cbor.M(1, "Team 1", 2, "Abcdefgh1234")))
	r.sys.setRC = 0
	*now = now.Add(2 * time.Second)
	if c, _ := r.settingsSet(cbor.M(2, "JP")); c != OK || !flag() {
		t.Fatalf("country set %d cleared the AP restore flag (flag %v)", c, flag())
	}
	*now = now.Add(2 * time.Second)
	if c, _ := r.settingsSet(cbor.M(20, cbor.M(1, "Team 1", 2, "Abcdefgh1234"))); c != OK || flag() {
		t.Fatalf("AP set %d did not clear the flag", c)
	}
}
