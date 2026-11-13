package node

import (
	"testing"

	"batman-prov/cbor"
	"batman-prov/provstore"
)

// settings.set through the owner-op path (254-p3-impl §3.3): codes + the reason in the error body
func (r *rig) settingsSet(body cbor.Map) (int, cbor.Map) {
	return r.call("settings.set", cbor.M(1, r.h, 2, r.envelope("settings/set", body, r.owner)))
}

func reasonOf(m cbor.Map) uint64 {
	v, _ := m.Get(1)
	u, _ := v.(uint64)
	return u
}

func TestSettingsSetCountry(t *testing.T) {
	r := claimedRig(t)
	if c, _ := r.settingsSet(cbor.M(2, "JP")); c != OK {
		t.Fatalf("country JP: code %d", c)
	}
	if len(r.sys.setCountry) != 1 || r.sys.setCountry[0] != "JP" {
		t.Fatalf("SetCountry calls %v", r.sys.setCountry)
	}
	for _, bad := range []any{"jp", "JPN", "J", uint64(81)} {
		c, b := r.settingsSet(cbor.M(2, bad))
		if c != EInput || reasonOf(b) != ReasonBadValue {
			t.Fatalf("country %v: code %d reason %d, want EInput 13", bad, c, reasonOf(b))
		}
	}
	if len(r.sys.setCountry) != 1 {
		t.Fatal("a refused value reached halow-setkey")
	}
}

// setkey's exit codes -> the helper's (and so the app's) answer
func TestSettingsSetExitCodes(t *testing.T) {
	cases := []struct {
		rc, code int
		reason   uint64
	}{{2, EInput, ReasonBadValue}, {3, EInput, ReasonBadValue}, {4, EStorage, 0}, {5, EBusy, 0}, {9, EApply, 0}, {124, EApply, 0}}
	for _, k := range cases {
		r := claimedRig(t)
		r.sys.setRC = k.rc
		c, b := r.settingsSet(cbor.M(2, "JP"))
		if c != k.code || reasonOf(b) != k.reason {
			t.Fatalf("setkey rc %d: code %d reason %d, want %d %d", k.rc, c, reasonOf(b), k.code, k.reason)
		}
	}
}

func TestSettingsSetAP(t *testing.T) {
	r := claimedRig(t)
	if c, _ := r.settingsSet(cbor.M(20, cbor.M(1, "Team 1", 2, "Abcdefgh1234._~xy"))); c != OK {
		t.Fatalf("AP: code %d", c)
	}
	if len(r.sys.setAP) != 1 || r.sys.setAP[0] != "Team 1|Abcdefgh1234._~xy" {
		t.Fatalf("SetAP calls %v", r.sys.setAP)
	}
	for _, bad := range []any{"Team", cbor.M(1, "Team"), cbor.M(1, uint64(1), 2, "x")} {
		if c, b := r.settingsSet(cbor.M(20, bad)); c != EInput || reasonOf(b) != ReasonBadValue {
			t.Fatalf("AP %v: code %d reason %d", bad, c, reasonOf(b))
		}
	}
}

// one setting per call; 10-13 are not settings here (reason 7); 1 stays rename-pending (D8); unknown uint keys ignored
func TestSettingsSetShape(t *testing.T) {
	r := claimedRig(t)
	if c, b := r.settingsSet(cbor.M(2, "JP", 20, cbor.M(1, "T", 2, "Abcdefgh1234"))); c != EInput || reasonOf(b) != ReasonBadValue {
		t.Fatalf("two settings: code %d reason %d", c, reasonOf(b))
	}
	if c, b := r.settingsSet(cbor.M(10, cbor.M(1, uint64(40)))); c != EUnsupported || reasonOf(b) != ReasonNoCapability {
		t.Fatalf("key 10: code %d reason %d", c, reasonOf(b))
	}
	if c, _ := r.settingsSet(cbor.M(1, "newname")); c != EUnsupported {
		t.Fatalf("rename: code %d", c)
	}
	if c, b := r.settingsSet(cbor.M()); c != EInput || reasonOf(b) != ReasonBadValue {
		t.Fatalf("nothing: code %d reason %d", c, reasonOf(b))
	}
	if c, _ := r.settingsSet(cbor.M(2, "JP", 77, "ignored")); c != OK {
		t.Fatalf("an unknown uint key is ignored: code %d", c)
	}
	if len(r.sys.setCountry)+len(r.sys.setAP) != 1 {
		t.Fatalf("halow-setkey calls %v %v", r.sys.setCountry, r.sys.setAP)
	}
}

// D9: the country only while not in a network (reason 14); D20: a legacy node -> E_UNSUPPORTED reason 20
func TestSettingsSetJoinedAndLegacy(t *testing.T) {
	r, _ := memberRig(t)
	if c, b := r.settingsSet(cbor.M(2, "JP")); c != EReject || reasonOf(b) != ReasonCountryJoin {
		t.Fatalf("joined: code %d reason %d, want EReject 14", c, reasonOf(b))
	}
	if len(r.sys.setCountry) != 0 {
		t.Fatal("halow-setkey called on a joined node")
	}
	l := claimedRig(t)
	rec, _, err := provstore.LoadOverlay(l.n.P)
	if err != nil {
		t.Fatal(err)
	}
	rec.RadioManaged = false
	if _, _, err := provstore.WriteOverlay(l.n.P, rec); err != nil {
		t.Fatal(err)
	}
	for _, b := range []cbor.Map{cbor.M(2, "JP"), cbor.M(20, cbor.M(1, "T", 2, "Abcdefgh1234"))} {
		if c, body := l.settingsSet(b); c != EUnsupported || reasonOf(body) != ReasonLegacy {
			t.Fatalf("legacy %v: code %d reason %d", b, c, reasonOf(body))
		}
	}
	if len(l.sys.setCountry)+len(l.sys.setAP) != 0 {
		t.Fatal("halow-setkey called on a legacy node")
	}
}

// the applied settings come back (the cache re-read after the set)
func TestSettingsSetAnswersApplied(t *testing.T) {
	r := claimedRig(t)
	r.n.SetSettingsSource(func() (Settings, error) {
		cc := "US"
		if len(r.sys.setCountry) > 0 {
			cc = r.sys.setCountry[len(r.sys.setCountry)-1]
		}
		return Settings{Hostname: "h", Country: cc, Channel: "42"}, nil
	})
	r.n.settings.runAsync = func(f func()) { f() }
	r.call("settings.get", cbor.M()) // the cache holds US now
	c, b := r.settingsSet(cbor.M(2, "JP"))
	if v, _ := b.Get(2); c != OK || v != "JP" {
		t.Fatalf("answer after the set: code %d body %v, want country JP", c, b)
	}
}
