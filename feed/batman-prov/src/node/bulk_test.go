package node

import (
	"bytes"
	"errors"
	"testing"

	"batman-prov/cbor"
)

type fakeBulk struct {
	addr   string
	httpOK bool
	apUp   bool
	tmpErr error
}

func (b *fakeBulk) HTTPAddr() (string, bool)   { return b.addr, b.httpOK }
func (b *fakeBulk) AP() (bool, string, string) { return b.apUp, "batman-ap", "ap-pass-1" }
func (b *fakeBulk) BulkTmpfs() error           { return b.tmpErr }

func okBulk() *fakeBulk            { return &fakeBulk{addr: "10.41.80.13", httpOK: true, apUp: true} }
func bulkBody(sha []byte) cbor.Map { return cbor.M(1, uint64(0), 2, sha) }

func (w *workRig) open(t *testing.T) (cbor.Map, *Error) {
	return w.n.bulkOpen(w.owner, wire(t, bulkBody(w.sumSha)))
}

// bulkRig: a pending of owner-1 (checked), no window yet
func bulkRig(t *testing.T) (*workRig, *fakeBulk) {
	t.Helper()
	w := newWorkRig(t, defaultPayload())
	b := okBulk()
	w.n.SetBulkSource(b)
	if ok, r, _, e := check(t, w.n, w.clk, w.mf, string(ownerID(w.owner))); e != nil || !ok {
		t.Fatalf("check: %v %d %v", ok, r, e)
	}
	return w, b
}

func TestBulkOpen(t *testing.T) {
	w, _ := bulkRig(t)
	m, e := w.open(t)
	if e != nil {
		t.Fatal(e)
	}
	for k, want := range map[int]any{1: "batman-ap", 2: "ap-pass-1", 3: "10.41.80.13", 4: uint64(8095), 5: uint64(900)} {
		if v, _ := m.Get(k); v != want {
			t.Fatalf("key %d = %v, want %v", k, v, want)
		}
	}
	bv, _ := m.Get(6)
	bearer, _ := bv.([]byte)
	if len(bearer) != 16 || bytes.Equal(bearer, make([]byte, 16)) {
		t.Fatalf("bearer %x", bearer)
	}
	u := w.n.upd
	if u.window == nil || u.window.Expiry != w.f.up+900 || !bytes.Equal(u.window.Owner, ownerID(w.owner)) {
		t.Fatalf("window %+v", u.window)
	}
	if p := u.validPending(); p == nil || p.Expiry < w.f.up+900+300 {
		t.Fatal("the pending does not outlive the window by 5 min")
	}
	// the same owner again = extend the same window, the same bearer (and the pending past its own 30 min)
	w.f.up += 800
	m2, e := w.open(t)
	if e != nil {
		t.Fatal(e)
	}
	b2, _ := m2.Get(6)
	if !bytes.Equal(b2.([]byte), bearer) || u.window.Expiry != w.f.up+900 {
		t.Fatalf("re-open: bearer changed or not extended (%d)", u.window.Expiry)
	}
	if p := u.validPending(); p == nil || p.Expiry < w.f.up+900+300 {
		t.Fatal("re-open did not extend the pending")
	}
}

func TestBulkOpenRefusals(t *testing.T) {
	other := ownerID(vPub(vKey("owner-2")))
	for name, tc := range map[string]struct {
		set  func(w *workRig, b *fakeBulk) cbor.Map
		code int
		why  uint64
	}{
		"no pending":     {func(w *workRig, b *fakeBulk) cbor.Map { w.n.upd.pend = nil; return nil }, EReject, 15},
		"other sha":      {func(w *workRig, b *fakeBulk) cbor.Map { return bulkBody(bytes.Repeat([]byte{7}, 32)) }, EReject, 15},
		"other owner":    {func(w *workRig, b *fakeBulk) cbor.Map { w.owner = vPub(vKey("owner-2")); return nil }, EReject, 15},
		"worker running": {func(w *workRig, b *fakeBulk) cbor.Map { w.n.upd.working = true; return nil }, EBusy, 0},
		"other's window": {func(w *workRig, b *fakeBulk) cbor.Map {
			w.n.upd.window = &window{Owner: other, Expiry: w.f.up + 100}
			return nil
		}, EBusy, 0},
		"AP off":      {func(w *workRig, b *fakeBulk) cbor.Map { b.apUp = false; return nil }, EReject, 16},
		"no tmpfs":    {func(w *workRig, b *fakeBulk) cbor.Map { b.tmpErr = errors.New("not tmpfs"); return nil }, EReject, 21},
		"no firewall": {func(w *workRig, b *fakeBulk) cbor.Map { b.httpOK = false; return nil }, EReject, 21},
		"purpose 1":   {func(w *workRig, b *fakeBulk) cbor.Map { return cbor.M(1, uint64(1), 2, w.sumSha) }, ESchema, 0},
		"extra key": {func(w *workRig, b *fakeBulk) cbor.Map {
			return cbor.M(1, uint64(0), 2, w.sumSha, 3, uint64(1))
		}, ESchema, 0},
	} {
		t.Run(name, func(t *testing.T) {
			w, b := bulkRig(t)
			body := tc.set(w, b)
			if body == nil {
				body = bulkBody(w.sumSha)
			}
			before := w.n.upd.window
			_, e := w.n.bulkOpen(w.owner, wire(t, body))
			if e == nil || e.Code != tc.code || e.Why != tc.why {
				t.Fatalf("got %v, want code %d reason %d", e, tc.code, tc.why)
			}
			if w.n.upd.window != before {
				t.Fatal("a refused bulk.open changed the window")
			}
		})
	}
}

func TestBulkClose(t *testing.T) {
	w, _ := bulkRig(t)
	if _, e := w.n.bulkClose(w.owner, wire(t, cbor.M())); e != nil {
		t.Fatalf("close without a window: %v", e)
	}
	w.open(t)
	if _, e := w.n.bulkClose(vPub(vKey("owner-2")), wire(t, cbor.M())); e == nil || e.Why != 15 || w.n.upd.window == nil {
		t.Fatalf("another owner closed the window: %v", e)
	}
	if _, e := w.n.bulkClose(w.owner, wire(t, cbor.M())); e != nil || w.n.upd.window != nil {
		t.Fatalf("own close: %v %v", e, w.n.upd.window)
	}
}

// otaBusy counts an open window (§3.1-7): a network reload would cut the upload
func TestBulkWindowMakesOtaBusy(t *testing.T) {
	w, _ := bulkRig(t)
	if w.n.otaBusy() {
		t.Fatal("busy before the window")
	}
	w.open(t)
	if !w.n.otaBusy() {
		t.Fatal("an open window is not busy")
	}
	w.f.up += 901
	if w.n.otaBusy() {
		t.Fatal("an expired window is still busy")
	}
}

// an expired window the tick has not cleared yet does not block another owner
func TestBulkExpiredWindowOtherOwner(t *testing.T) {
	w, _ := bulkRig(t)
	w.open(t)
	w.f.up += 901
	o2 := vPub(vKey("owner-2"))
	w.n.upd.pend.Owner = ownerID(o2)
	if _, e := w.n.bulkOpen(o2, wire(t, bulkBody(w.sumSha))); e != nil {
		t.Fatalf("an expired window of owner-1 blocked owner-2: %v", e)
	}
}

// health.get's http field (§3.8.2): the address only with the firewall check; the window keys only while it is open
func TestBulkHTTPField(t *testing.T) {
	w, b := bulkRig(t)
	hf := func(up uint64, have bool) cbor.Map { return w.n.httpField(up, have, false) }
	if v, ok := hf(0, false).Get(2); !ok || v != "10.41.80.13" {
		t.Fatalf("no address with the firewall in place: %v", v)
	}
	if _, ok := hf(0, false).Get(6); ok {
		t.Fatal("a bearer without a window")
	}
	m, _ := w.open(t)
	bearer, _ := m.Get(6)
	h := hf(100, true)
	for k, want := range map[int]any{3: string(ownerID(w.owner)), 4: uint64(900), 6: string(bearer.([]byte)), 7: uint64(w.f.up + 900)} {
		v, ok := h.Get(k)
		if bb, isB := v.([]byte); isB {
			v = string(bb)
		}
		if !ok || v != want {
			t.Fatalf("http.%d = %v, want %v", k, v, want)
		}
	}
	if v, _ := h.Get(5); v != w.n.upd.pend.R.Size {
		t.Fatalf("http.5 = %v", v)
	}
	if w.n.upd.uploaded != 100 {
		t.Fatalf("uploaded %d", w.n.upd.uploaded)
	}
	hf(1<<40, true)
	if w.n.upd.uploaded != w.n.upd.pend.R.Size {
		t.Fatal("uploaded not clamped to the payload size")
	}
	if _, ok := hf(0, false).Get(8); ok {
		t.Fatal("worker key without a worker")
	}
	b.httpOK = false
	if h := hf(0, false); len(h) != 0 {
		t.Fatalf("firewall check failed, yet the field has %v", h)
	}
	b.httpOK = true
	w.n.upd.working = true
	if v, _ := hf(0, false).Get(8); v != true {
		t.Fatal("no worker key")
	}
	w.n.httpField(0, false, true)
	if !w.n.httpBindFailed.Load() {
		t.Fatal("bind failure not recorded")
	}
}

// the poll's health.get takes {1: uploaded, 2: bind failed} and answers {1: health, 2: http}
func TestBulkHealthGet(t *testing.T) {
	r := claimedRig(t)
	w := newWorkRig(t, defaultPayload())
	r.n.SetUpdateSource(w.f, w.fs)
	r.n.SetBulkSource(okBulk())
	r.n.Health = func() string { return "ok" }
	c, m := r.call("health.get", cbor.M(1, uint64(10), 2, true))
	if c != OK {
		t.Fatalf("health.get with the poll's keys: %d", c)
	}
	hv, ok := m.Get(2)
	hm, isM := hv.(cbor.Map)
	if !ok || !isM {
		t.Fatalf("no http field: %v", m)
	}
	if v, _ := hm.Get(2); v != "10.41.80.13" {
		t.Fatalf("http.2 = %v", v)
	}
	if !r.n.httpBindFailed.Load() {
		t.Fatal("bind failure not recorded")
	}
	if c, _ := r.call("health.get", cbor.M(3, uint64(1))); c == OK {
		t.Fatal("unknown key accepted")
	}
}

// status key 15 says http_bind_failed (§3.8.1)
func TestBulkStatusBindFailed(t *testing.T) {
	f := &fakeStatus{js: hs04(t), p5: true, inline: true}
	r, _ := statusRig(t, f)
	f15 := func() cbor.Map { v, _ := statusCall(t, r, true).Get(15); return v.(cbor.Map) }
	if _, ok := f15().Get("http_bind_failed"); ok {
		t.Fatal("http_bind_failed before any failure")
	}
	r.n.httpBindFailed.Store(true)
	if v, _ := f15().Get("http_bind_failed"); v != true {
		t.Fatal("no http_bind_failed")
	}
}

// the real owner-op path: bulk/open and bulk/close envelopes reach bulkOpen / bulkClose
func TestBulkOwnerOpVerbs(t *testing.T) {
	r := claimedRig(t)
	w := newWorkRig(t, defaultPayload())
	if ok, _, _, e := check(t, w.n, w.clk, w.mf, string(ownerID(w.owner))); e != nil || !ok {
		t.Fatal("check")
	}
	rel := w.n.upd.pend.R
	r.n.SetUpdateSource(w.f, w.fs)
	r.n.SetBulkSource(okBulk())
	u := r.n.upd
	u.pend = &pending{R: rel, Owner: ownerID(pub(r.owner)), BootID: w.f.boot, Expiry: w.f.up + 600}
	c, m := r.call("bulk.open", cbor.M(1, r.h, 2, r.envelope("bulk/open", bulkBody(rel.SumsSha), r.owner)))
	if c != OK || u.window == nil {
		t.Fatalf("bulk.open: %d %v", c, m)
	}
	if c, _ := r.call("bulk.close", cbor.M(1, r.h, 2, r.envelope("bulk/close", cbor.M(), r.owner))); c != OK || u.window != nil {
		t.Fatalf("bulk.close: %d", c)
	}
	if c, _ := r.call("bulk.open", cbor.M(1, r.h, 2, r.envelope("bulk/close", bulkBody(rel.SumsSha), r.owner))); c == OK {
		t.Fatal("a bulk/close envelope opened a window")
	}
}
