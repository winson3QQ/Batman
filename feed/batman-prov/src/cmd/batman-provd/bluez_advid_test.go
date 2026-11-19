package main

import (
	"bytes"
	"errors"
	"fmt"
	"reflect"
	"strings"
	"testing"

	"github.com/godbus/dbus/v5"

	"batman-prov/proto"
	"batman-prov/provd"
)

// #329 rotating identifier (docs/design/329-rotating-id-plan.md §9, G2 / G3): register() through its two seams.
// No bus, no helper: fakeAdv stands in for the advertisement, advID is a function of the test.

type fakeAdv struct {
	b       *bleSide
	refuse  func(mfr map[uint16]dbus.Variant) error // nil = accept
	cur     map[uint16]dbus.Variant
	sets    []map[uint16]dbus.Variant
	regs    []map[uint16]dbus.Variant // the property's value at each Register call
	unregs  int
	setOnAd bool // a SetMfr arrived while the advertisement was registered
}

func (f *fakeAdv) SetMfr(m map[uint16]dbus.Variant) {
	f.b.mu.Lock()
	if f.b.advOn {
		f.setOnAd = true
	}
	f.b.mu.Unlock()
	f.cur = m
	f.sets = append(f.sets, m)
}
func (f *fakeAdv) Register() error {
	f.regs = append(f.regs, f.cur)
	if f.refuse != nil {
		return f.refuse(f.cur)
	}
	return nil
}
func (f *fakeAdv) Unregister() { f.unregs++ }

type advRig struct {
	b     *bleSide
	a     *fakeAdv
	lines []string
	asks  int // advID calls
}

func newAdvRig(te provd.TestEnv) *advRig {
	r := &advRig{}
	r.b = newBLE(nil, te, func(f string, a ...any) { r.lines = append(r.lines, fmt.Sprintf(f, a...)) })
	r.a = &fakeAdv{b: r.b}
	r.b.adv = r.a
	r.b.advID = func() ([]byte, error) { r.asks++; return []byte{byte(r.asks), 2, 3, 4, 5, 6}, nil }
	return r
}

func (r *advRig) on() bool { r.b.mu.Lock(); defer r.b.mu.Unlock(); return r.b.advOn }

func idOf(t *testing.T, m map[uint16]dbus.Variant) []byte {
	t.Helper()
	v, ok := m[proto.AdvCID]
	id, isB := v.Value().([]byte)
	if len(m) != 1 || !ok || !isB || len(id) != 6 || v.Signature().String() != "ay" {
		t.Fatalf("ManufacturerData %v: want {0x%04x: 6 bytes (ay)}", m, proto.AdvCID)
	}
	return id
}

func wantLines(t *testing.T, got []string, want ...string) {
	t.Helper()
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("log lines:\n got  %q\n want %q", got, want)
	}
}

// G2 (a): every registration carries a new value; the field line comes immediately before the unchanged
// `adv registered` line; (d) the property is never written while the advertisement is registered
func TestAdvIDTwoRegistrationsTwoValues(t *testing.T) {
	r := newAdvRig(provd.TestEnv{})
	r.b.register("start")
	if !r.on() || len(r.a.regs) != 1 {
		t.Fatalf("not registered: on=%v regs=%d", r.on(), len(r.a.regs))
	}
	first := idOf(t, r.a.regs[0])
	r.b.register("again") // already on: nothing asked, nothing written
	if r.asks != 1 || len(r.a.sets) != 1 || len(r.a.regs) != 1 {
		t.Fatalf("register while on: asks=%d sets=%d regs=%d", r.asks, len(r.a.sets), len(r.a.regs))
	}
	r.b.withdraw("link")
	r.b.register("link closed")
	second := idOf(t, r.a.regs[1])
	if bytes.Equal(first, second) || r.asks != 2 {
		t.Fatalf("second registration: %x then %x, asks=%d", first, second, r.asks)
	}
	if r.a.setOnAd {
		t.Fatal("ManufacturerData was written while the advertisement was registered")
	}
	wantLines(t, r.lines, "provd: adv field id=1", "provd: adv registered reason=start",
		"provd: adv withdrawn reason=link", "provd: adv field id=1", "provd: adv registered reason=link closed")
}

// G2 (b): the helper gives no identifier -> the advert goes out without the field
func TestAdvIDHelperError(t *testing.T) {
	r := newAdvRig(provd.TestEnv{})
	r.b.advID = func() ([]byte, error) { r.asks++; return nil, provd.ErrBusy }
	r.b.register("start")
	if !r.on() || len(r.a.regs) != 1 || len(r.a.regs[0]) != 0 {
		t.Fatalf("on=%v regs=%v", r.on(), r.a.regs)
	}
	wantLines(t, r.lines, "provd: adv field id=0 why=helper", "provd: adv registered reason=start")
}

// G2 (c): BlueZ refuses the advertisement with the field -> once more without it; the failure line appears once
func TestAdvIDRegisterRefusedWithField(t *testing.T) {
	r := newAdvRig(provd.TestEnv{})
	r.a.refuse = func(m map[uint16]dbus.Variant) error {
		if len(m) != 0 {
			return errors.New("org.bluez.Error.InvalidLength")
		}
		return nil
	}
	r.b.register("start")
	if !r.on() || len(r.a.regs) != 2 || len(r.a.regs[0]) != 1 || len(r.a.regs[1]) != 0 {
		t.Fatalf("on=%v regs=%v", r.on(), r.a.regs)
	}
	wantLines(t, r.lines, "provd: adv register failed: org.bluez.Error.InvalidLength",
		"provd: adv field id=0 why=register", "provd: adv registered reason=start")
}

// G2 (c2): BlueZ refuses everything -> not registered, no field line, the failure line once; the next pass asks
// the helper again
func TestAdvIDRegisterRefusedAlways(t *testing.T) {
	r := newAdvRig(provd.TestEnv{})
	r.a.refuse = func(map[uint16]dbus.Variant) error { return errors.New("org.bluez.Error.NotPermitted") }
	r.b.register("start")
	if r.on() || len(r.a.regs) != 2 || r.asks != 1 {
		t.Fatalf("on=%v regs=%d asks=%d", r.on(), len(r.a.regs), r.asks)
	}
	wantLines(t, r.lines, "provd: adv register failed: org.bluez.Error.NotPermitted")
	r.b.register("retry")
	if r.on() || r.asks != 2 || len(r.a.regs) != 4 {
		t.Fatalf("second pass: on=%v asks=%d regs=%d", r.on(), r.asks, len(r.a.regs))
	}
	if strings.Contains(strings.Join(r.lines, "\n"), "adv field") || len(r.lines) != 1 {
		t.Fatalf("lines after two failed passes: %q", r.lines)
	}
}

// G2 (f): ADV_ID_OFF (prov_test images only) — the helper is never asked
func TestAdvIDOff(t *testing.T) {
	r := newAdvRig(provd.TestEnv{AdvIDOff: true})
	r.b.register("start")
	if !r.on() || r.asks != 0 || len(r.a.regs) != 1 || len(r.a.regs[0]) != 0 {
		t.Fatalf("on=%v asks=%d regs=%v", r.on(), r.asks, r.a.regs)
	}
	wantLines(t, r.lines, "provd: adv field id=0 why=off", "provd: adv registered reason=start")
}

// an open link: no registration, and the helper is not asked for an identifier nobody will advertise
func TestAdvIDNotAskedWithLiveLink(t *testing.T) {
	r := newAdvRig(provd.TestEnv{})
	addLink(r.b, devA)
	r.b.register("start")
	if r.on() || r.asks != 0 || len(r.a.sets) != 0 {
		t.Fatalf("on=%v asks=%d sets=%d", r.on(), r.asks, len(r.a.sets))
	}
}

// G3: UUID list 18 + Manufacturer Data 10 + Flags 3 = 31 B, the limit; ADV_LEN_TEST replaces the whole length
func TestAdvPreflight(t *testing.T) {
	if advUUIDAD+advMfrAD+advFlags != advMax {
		t.Fatalf("advert %d B, max %d", advUUIDAD+advMfrAD+advFlags, advMax)
	}
	for n, want := range map[int]int{0: 0, 28: 0, 29: 3} {
		r := newAdvRig(provd.TestEnv{AdvLenTest: n})
		if got := r.b.preflight(); got != want {
			t.Fatalf("ADV_LEN_TEST=%d: preflight %d, want %d", n, got, want)
		}
	}
}
