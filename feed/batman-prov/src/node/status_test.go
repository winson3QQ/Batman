package node

import (
	"errors"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"batman-prov/cbor"
)

// testdata/halow-status-04-wsl22.json is `halow-status json` captured read-only on 04 (1.5.14-wsl.22, 2026-11-09):
// joined (plinks 1, batman_neighbours 1), health CRIT (the phone AP key is the placeholder, keyguard blocks it).
func hs04(t *testing.T) []byte {
	b, err := os.ReadFile("testdata/halow-status-04-wsl22.json")
	if err != nil {
		t.Fatal(err)
	}
	return b
}

type fakeStatus struct {
	mu     sync.Mutex
	js     []byte
	jsErr  error
	delay  time.Duration
	p5     bool
	p5Err  error
	nJS    atomic.Int32
	nP5    atomic.Int32
	gate   chan struct{} // when set, HalowStatus blocks until it is closed
	inline bool
}

func (f *fakeStatus) src() StatusSource {
	return StatusSource{
		HalowStatus: func() ([]byte, error) {
			f.nJS.Add(1)
			if f.gate != nil {
				<-f.gate
			}
			time.Sleep(f.delay)
			f.mu.Lock()
			defer f.mu.Unlock()
			return f.js, f.jsErr
		},
		P5Fresh: func() (bool, error) { f.nP5.Add(1); f.mu.Lock(); defer f.mu.Unlock(); return f.p5, f.p5Err },
	}
}

// statusRig: a claimed node with a fake clock and status source; every refresh runs inline unless async is wanted
func statusRig(t *testing.T, f *fakeStatus) (*rig, *time.Time) {
	r := claimedRig(t)
	now := time.Unix(1000, 0)
	r.n.clock = func() time.Time { return now }
	r.n.SetStatusSource(f.src())
	if f.inline {
		r.n.status.runAsync = func(fn func()) { fn() }
	}
	return r, &now
}

func statusCall(t *testing.T, r *rig, full bool) cbor.Map {
	t.Helper()
	c, m := r.call("status.get", cbor.M(1, full))
	if c != OK {
		t.Fatalf("status.get code %d", c)
	}
	return m
}

func key(m cbor.Map, k any) (any, bool) { return m.Get(k) }

// the owner's answer from the 04 capture: state, verdict CRIT=2, neighbours 1, no join-failure (JOINED), key 15
func TestStatusOwnerFrom04Capture(t *testing.T) {
	f := &fakeStatus{js: hs04(t), p5: true, inline: true}
	r, now := statusRig(t, f)
	if _, ok := key(statusCall(t, r, true), 4); ok {
		t.Fatal("key 4 before --check ever ran (never computed -> omitted)")
	}
	*now = now.Add(time.Second)
	m := statusCall(t, r, true)
	if v, _ := key(m, 1); v != "claimed" {
		t.Fatalf("key 1 = %v", v)
	}
	if v, _ := key(m, 2); v != uint64(2) {
		t.Fatalf("key 2 (verdict) = %v, want 2 (CRIT)", v)
	}
	if v, _ := key(m, 3); v != uint64(1) {
		t.Fatalf("key 3 (neighbours) = %v", v)
	}
	if v, ok := key(m, 4); !ok || v != true {
		t.Fatalf("key 4 (p5_saved) = %v %v", v, ok)
	}
	if _, ok := key(m, 5); ok {
		t.Fatal("key 5 (join-failure) on a JOINED node")
	}
	v15, ok := key(m, 15)
	if !ok {
		t.Fatal("owner: no key 15")
	}
	f15 := v15.(cbor.Map)
	for k, want := range map[string]any{"node": "BCM2711-6c89", "temp_c": "56", "throttled": "0x0", "uptime_s": uint64(402)} {
		if got, _ := f15.Get(k); got != want {
			t.Fatalf("15.%s = %v, want %v", k, got, want)
		}
	}
	tn, _ := f15.Get("tenants")
	if !strings.Contains(tn.(string), "opentakserver") {
		t.Fatalf("15.tenants = %v", tn)
	}
	j, _ := f15.Get("join")
	if p, _ := j.(cbor.Map).Get("plinks"); p != uint64(1) {
		t.Fatalf("15.join.plinks = %v", p)
	}
	if _, err := cbor.Encode(m); err != nil {
		t.Fatalf("status reply does not encode: %v", err)
	}
}

// a member gets keys 1-5 only (§3.4); negative control: full=true for the member would leak node / tenants
func TestStatusMemberSummary(t *testing.T) {
	r, _ := statusRig(t, &fakeStatus{js: hs04(t), inline: true})
	m := statusCall(t, r, false)
	for _, e := range m {
		k, ok := e.K.(uint64)
		if i, isInt := e.K.(int); isInt {
			k, ok = uint64(i), i >= 0
		}
		if !ok || k > 5 {
			t.Fatalf("member reply carries key %v", e.K)
		}
	}
}

// not joined: key 5 = {1: reason_code, 2: state + detail}; reason_code missing (joinwatch before verdict_code) -> 0
func TestStatusJoinFailure(t *testing.T) {
	notJoined := strings.Replace(string(hs04(t)), `"state":"JOINED"`, `"state":"SEARCHING","reason_code":3`, 1)
	r, _ := statusRig(t, &fakeStatus{js: []byte(notJoined), inline: true})
	m := statusCall(t, r, false)
	v, ok := key(m, 5)
	if !ok {
		t.Fatal("no key 5 on a node that is not joined")
	}
	if c, _ := v.(cbor.Map).Get(1); c != uint64(3) {
		t.Fatalf("5.1 = %v, want 3", c)
	}
	if d, _ := v.(cbor.Map).Get(2); !strings.HasPrefix(d.(string), "SEARCHING ") {
		t.Fatalf("5.2 = %v", d)
	}
	noCode := strings.Replace(string(hs04(t)), `"state":"JOINED"`, `"state":"SEARCHING"`, 1)
	r2, _ := statusRig(t, &fakeStatus{js: []byte(noCode), inline: true})
	v2, _ := key(statusCall(t, r2, false), 5)
	if c, _ := v2.(cbor.Map).Get(1); c != uint64(0) {
		t.Fatalf("missing reason_code -> 5.1 = %v, want 0", c)
	}
}

// the first request waits at most 2 s for halow-status; slower -> key 1 + 15: {stale: true}, never a guess
func TestStatusFirstRequestStale(t *testing.T) {
	f := &fakeStatus{js: hs04(t), delay: 3 * time.Second}
	r, _ := statusRig(t, f)
	t0 := time.Now()
	m := statusCall(t, r, true)
	if d := time.Since(t0); d > 2500*time.Millisecond {
		t.Fatalf("waited %v", d)
	}
	if len(m) != 2 {
		t.Fatalf("stale reply %v", m)
	}
	v, _ := key(m, 15)
	if s, _ := v.(cbor.Map).Get("stale"); s != true {
		t.Fatalf("stale reply %v", m)
	}
}

// invalid JSON or an error from halow-status is never cached; p5 unknown -> key 4 omitted, then it is computed
func TestStatusBadSourceAndP5(t *testing.T) {
	f := &fakeStatus{js: []byte("{not json"), p5Err: errors.New("cfgsave lock busy"), inline: true}
	r, now := statusRig(t, f)
	if m := statusCall(t, r, false); len(m) != 2 {
		t.Fatalf("invalid json cached: %v", m)
	}
	*now = now.Add(time.Second)
	f.js, f.jsErr = hs04(t), errors.New("halow-status exit 1")
	if m := statusCall(t, r, false); len(m) != 2 {
		t.Fatalf("an error result was cached: %v", m)
	}
	*now = now.Add(time.Second)
	f.jsErr, f.p5Err = nil, errors.New("cfgsave lock busy")
	m := statusCall(t, r, false)
	if _, ok := key(m, 4); ok {
		t.Fatal("key 4 from a failed --check")
	}
	f.p5Err, f.p5 = nil, false
	*now = now.Add(statusP5Every)
	r.n.StatusTick()
	m = statusCall(t, r, false)
	if v, ok := key(m, 4); !ok || v != false {
		t.Fatalf("key 4 = %v %v, want false", v, ok)
	}
	// older than 300 s -> omitted again (and a refresh is asked for)
	f.p5Err = errors.New("busy")
	*now = now.Add(statusP5MaxAge + time.Second)
	if _, ok := key(statusCall(t, r, false), 4); ok {
		t.Fatal("key 4 older than 300 s")
	}
}

// refreshes only while someone asked in the last 10 min; halow-status every 15 s, --check every 120 s
func TestStatusTickSchedule(t *testing.T) {
	f := &fakeStatus{js: hs04(t), p5: true, inline: true}
	r, now := statusRig(t, f)
	for i := 0; i < 5; i++ {
		*now = now.Add(time.Minute)
		r.n.StatusTick()
	}
	if f.nJS.Load() != 0 || f.nP5.Load() != 0 {
		t.Fatalf("refreshed with nobody asking: js %d p5 %d", f.nJS.Load(), f.nP5.Load())
	}
	statusCall(t, r, false)
	js0, p50 := f.nJS.Load(), f.nP5.Load()
	*now = now.Add(10 * time.Second)
	r.n.StatusTick()
	if f.nJS.Load() != js0 {
		t.Fatal("halow-status refreshed before 15 s")
	}
	*now = now.Add(5 * time.Second)
	r.n.StatusTick()
	if f.nJS.Load() != js0+1 {
		t.Fatal("halow-status not refreshed at 15 s")
	}
	if f.nP5.Load() != p50 {
		t.Fatal("--check ran again before 120 s")
	}
	*now = now.Add(statusP5Every)
	r.n.StatusTick()
	if f.nP5.Load() != p50+1 {
		t.Fatal("--check not run at 120 s")
	}
	*now = now.Add(statusAskWindow)
	js1, p51 := f.nJS.Load(), f.nP5.Load()
	r.n.StatusTick()
	if f.nJS.Load() != js1 || f.nP5.Load() != p51 {
		t.Fatal("refreshed 10 min after the last ask")
	}
}

// single-flight: concurrent first requests run halow-status once
func TestStatusSingleFlight(t *testing.T) {
	f := &fakeStatus{js: hs04(t), gate: make(chan struct{})}
	r, _ := statusRig(t, f)
	r.n.status.global = bucket{rate: 100, burst: 100}
	var wg sync.WaitGroup
	for i := 0; i < 4; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); r.call("status.get", cbor.M(1, false)) }()
	}
	time.Sleep(200 * time.Millisecond)
	close(f.gate)
	wg.Wait()
	if n := f.nJS.Load(); n != 1 {
		t.Fatalf("halow-status ran %d times", n)
	}
}

// quotas: per connection 1/s, helper-wide 2/s (§3.1-9); arguments: key 1 must be a bool, nothing else
func TestStatusQuotaAndArgs(t *testing.T) {
	r, now := statusRig(t, &fakeStatus{js: hs04(t), inline: true})
	h := r.n.NewConn()
	call := func(args cbor.Map) int {
		raw, _ := cbor.Encode(cbor.M(1, "status.get", 2, uint64(1), 3, args))
		dec, _ := cbor.Decode(raw)
		c, _ := h(dec.(cbor.Map)).Get(2)
		return int(c.(uint64))
	}
	if c := call(cbor.M(1, false)); c != OK {
		t.Fatalf("first %d", c)
	}
	if c := call(cbor.M(1, false)); c != ERate {
		t.Fatalf("second within 1 s on one connection: %d, want ERate", c)
	}
	*now = now.Add(time.Second)
	if c := call(cbor.M(1, false)); c != OK {
		t.Fatalf("after 1 s: %d", c)
	}
	h2, h3 := r.n.NewConn(), r.n.NewConn()
	*now = now.Add(time.Second)
	codes := []int{}
	for _, hh := range []func(cbor.Map) cbor.Map{h, h2, h3} {
		raw, _ := cbor.Encode(cbor.M(1, "status.get", 2, uint64(1), 3, cbor.M(1, false)))
		dec, _ := cbor.Decode(raw)
		c, _ := hh(dec.(cbor.Map)).Get(2)
		codes = append(codes, int(c.(uint64)))
	}
	if codes[2] != ERate {
		t.Fatalf("three connections in one second: %v, want the third ERate (helper-wide 2/s)", codes)
	}
	*now = now.Add(time.Second)
	if c := call(cbor.M(1, "yes")); c != ESchema {
		t.Fatalf("key 1 not a bool: %d", c)
	}
	*now = now.Add(time.Second)
	if c := call(cbor.M(1, false, 2, uint64(1))); c != ESchema {
		t.Fatalf("extra key: %d", c)
	}
}

// no source wired (an older daemon) -> E_UNSUPPORTED, not a crash
func TestStatusNoSource(t *testing.T) {
	r := claimedRig(t)
	if c, _ := r.call("status.get", cbor.M(1, false)); c != EUnsupported {
		t.Fatalf("code %d", c)
	}
}
