package node

import (
	"errors"
	"sync/atomic"
	"testing"
	"time"

	"batman-prov/cbor"
)

// the two US rows of /usr/share/morse-regdb/channels.csv as read on 04 (wsl.22), with the header
const regdb04 = `country_code,channelizations,default_channelization,bw,s1g_chan,s1g_op_class,global_op_class,centre_freq_mhz,duty_cycle_ap,duty_cycle_sta,country,tx_power_max,duty_cycle_omit_ctrl_resp,pkt_spacing_ms,airtime_min_ms,airtime_max_ms,map_5g_chan
US,,True,2,42,2,69,923.0,100.0,100.0,USA,36.0,False,0.0,0.0,0.0,159
US,,True,4,40,3,70,922.0,100.0,100.0,USA,36.0,False,0.0,0.0,0.0,155
`

func settingsRig(t *testing.T, s Settings, err error, delay time.Duration) (*rig, *time.Time, *atomic.Int32) {
	r := claimedRig(t)
	now := time.Unix(1000, 0)
	r.n.clock = func() time.Time { return now }
	var n atomic.Int32
	r.n.SetSettingsSource(func() (Settings, error) { n.Add(1); time.Sleep(delay); return s, err })
	if delay == 0 {
		r.n.settings.runAsync = func(f func()) { f() }
	}
	return r, &now, &n
}

// 04 fresh B (2026-11-09): hostname BCM2711-6c89, radio1 US ch 42, AP ssid BCM2711-6c89 -> 10 = {42, 2 MHz}
func TestSettingsFrom04(t *testing.T) {
	s := Settings{Hostname: "BCM2711-6c89", Country: "US", Channel: "42", SSID: "BCM2711-6c89", RegdbBW: RegdbLookup(regdb04)}
	r, _, _ := settingsRig(t, s, nil, 0)
	c, m := r.call("settings.get", cbor.M())
	if c != OK {
		t.Fatalf("code %d", c)
	}
	if v, _ := m.Get(1); v != "BCM2711-6c89" {
		t.Fatalf("1 = %v", v)
	}
	if v, _ := m.Get(2); v != "US" {
		t.Fatalf("2 = %v", v)
	}
	h, _ := m.Get(10)
	if ch, _ := h.(cbor.Map).Get(1); ch != uint64(42) {
		t.Fatalf("10.1 = %v", ch)
	}
	if bw, _ := h.(cbor.Map).Get(2); bw != uint64(2) {
		t.Fatalf("10.2 = %v, want 2 (US ch 42)", bw)
	}
	a, _ := m.Get(20)
	if ss, _ := a.(cbor.Map).Get(1); ss != "BCM2711-6c89" {
		t.Fatalf("20.1 = %v", ss)
	}
	for _, e := range m {
		if k, _ := e.K.(uint64); k != 1 && k != 2 && k != 10 && k != 20 {
			t.Fatalf("unexpected key %v", e.K)
		}
	}
}

// not well-formed values are omitted (never guessed); a channel the regdb does not know has no bandwidth
func TestSettingsOmitBad(t *testing.T) {
	s := Settings{Hostname: "", Country: "us", Channel: "4x", SSID: "", RegdbBW: RegdbLookup(regdb04)}
	r, _, _ := settingsRig(t, s, nil, 0)
	_, m := r.call("settings.get", cbor.M())
	if len(m) != 0 {
		t.Fatalf("bad values not omitted: %v", m)
	}
	s = Settings{Country: "US", Channel: "44", RegdbBW: RegdbLookup(regdb04)}
	r, _, _ = settingsRig(t, s, nil, 0)
	_, m = r.call("settings.get", cbor.M())
	h, _ := m.Get(10)
	if _, ok := h.(cbor.Map).Get(2); ok {
		t.Fatal("a bandwidth for a channel the regdb does not list")
	}
}

// the source failing -> E_BUSY (re-read), never an empty "settings"; a slow first read -> E_BUSY within ~2 s
func TestSettingsNotReadYet(t *testing.T) {
	r, _, _ := settingsRig(t, Settings{}, errors.New("uci failed"), 0)
	if c, _ := r.call("settings.get", cbor.M()); c != EBusy {
		t.Fatalf("source error: code %d, want E_BUSY", c)
	}
	r, _, _ = settingsRig(t, Settings{Hostname: "x"}, nil, 3*time.Second)
	t0 := time.Now()
	if c, _ := r.call("settings.get", cbor.M()); c != EBusy {
		t.Fatalf("slow first read: code %d", c)
	}
	if time.Since(t0) > 2500*time.Millisecond {
		t.Fatal("waited more than 2 s")
	}
	if c, _ := r.call("settings.get", cbor.M(1, uint64(1))); c != ESchema {
		t.Fatalf("an argument: code %d, want ESchema", c)
	}
}

// refreshed every 15 s only while someone asked in the last 10 min
func TestSettingsTick(t *testing.T) {
	r, now, n := settingsRig(t, Settings{Hostname: "x"}, nil, 0)
	r.n.StatusTick()
	if n.Load() != 0 {
		t.Fatal("read with nobody asking")
	}
	r.call("settings.get", cbor.M())
	n0 := n.Load()
	*now = now.Add(14 * time.Second)
	r.n.StatusTick()
	if n.Load() != n0 {
		t.Fatal("refreshed before 15 s")
	}
	*now = now.Add(time.Second)
	r.n.StatusTick()
	if n.Load() != n0+1 {
		t.Fatal("not refreshed at 15 s")
	}
	*now = now.Add(statusAskWindow)
	n1 := n.Load()
	r.n.StatusTick()
	if n.Load() != n1 {
		t.Fatal("refreshed 10 min after the last ask")
	}
}

func TestRegdbLookup(t *testing.T) {
	f := RegdbLookup(regdb04)
	if bw, ok := f("US", "40"); !ok || bw != 4 {
		t.Fatalf("US 40 = %d %v", bw, ok)
	}
	if _, ok := f("TW", "40"); ok {
		t.Fatal("a country that is not in the table")
	}
	if _, ok := f("US", "4"); ok {
		t.Fatal("channel 4 matched 40/42 by prefix")
	}
}
