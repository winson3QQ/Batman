package node

// The app's update fixtures (Batman-app docs/design/254-app-update.md v0.4 §8): the helper's own replies along the
// app's update path, from the rigs of updwork_test.go / bulk_test.go (check -> bulk.open -> the upload -> prepare ->
// the status rows -> apply, and the refusals the app tells apart). Every reply is asserted here, so the test is a
// regular one; with BATMAN_CAPTURE_DIR set it also writes them to $BATMAN_CAPTURE_DIR/node-helper.json, which provd's
// TestCaptureAppWire turns into the wire envelopes the app receives:
//
//	d=$(mktemp -d); BATMAN_CAPTURE_DIR=$d go test ./node -run TestCaptureApp && BATMAN_CAPTURE_DIR=$d go test ./provd -run TestCaptureApp

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"batman-prov/cbor"
)

// capCase: one helper reply — Code = the helper's code (0 = ok), Body = its body (hex of the encoded CBOR map)
type capCase struct {
	Name string `json:"name"`
	Verb string `json:"verb"` // the app's wire type (update/check, bulk/open, ...)
	Code int    `json:"code"`
	Body string `json:"body"`
}

type capture struct {
	t     *testing.T
	cases []capCase
}

func (c *capture) add(name, verb string, m cbor.Map, e *Error) {
	c.t.Helper()
	code, body := 0, m
	if e != nil {
		code, body = e.Code, errBody(e)
	}
	if body == nil {
		body = cbor.M()
	}
	b, err := cbor.Encode(body)
	if err != nil {
		c.t.Fatalf("%s: %v", name, err)
	}
	c.cases = append(c.cases, capCase{name, verb, code, hex.EncodeToString(b)})
}

// ok: the reply must be a success whose key `k` is `want` (want nil: any success)
func (c *capture) ok(name, verb string, m cbor.Map, e *Error, k int, want any) {
	c.t.Helper()
	if e != nil {
		c.t.Fatalf("%s: %v", name, e)
	}
	if want != nil {
		if v, _ := m.Get(k); v != want {
			c.t.Fatalf("%s: key %d = %v, want %v", name, k, v, want)
		}
	}
	c.add(name, verb, m, e)
}

// refused: the reply must be the helper error `code` with reason `why`
func (c *capture) refused(name, verb string, m cbor.Map, e *Error, code int, why uint64) {
	c.t.Helper()
	if e == nil || e.Code != code || e.Why != why {
		c.t.Fatalf("%s: %v (want code %d reason %d)", name, e, code, why)
	}
	c.add(name, verb, m, e)
}

// status: update.status must be phase `ph` with reason `r`
func (c *capture) status(name string, n *Node, ph, r uint64) {
	c.t.Helper()
	m, e := n.updateStatus()
	if e != nil {
		c.t.Fatalf("%s: %v", name, e)
	}
	gp, _ := getUint(m, 1)
	gr, _ := getUint(m, 3)
	if gp != ph || gr != r {
		c.t.Fatalf("%s: status %d + %d, want %d + %d", name, gp, gr, ph, r)
	}
	c.add(name, "update/status", m, e)
}

func TestCaptureAppUpdateReplies(t *testing.T) {
	rebootDelay = 10 * time.Millisecond
	c := &capture{t: t}
	checkReq := func(w *workRig, owner []byte) (cbor.Map, *Error) {
		*w.clk = w.clk.Add(11 * time.Second) // past the helper-wide 1 / 10 s
		return w.n.updateCheck(wire(t, cbor.M(1, w.mf, 2, ownerID(owner))))
	}

	// the whole path: idle -> check -> bulk.open -> (the upload) -> prepare -> written -> apply
	w := newWorkRig(t, defaultPayload())
	w.n.SetBulkSource(okBulk())
	c.status("status-idle", w.n, 0, 0)
	m, e := checkReq(w, w.owner)
	c.ok("check-ok", "update/check", m, e, 1, true)
	m, e = w.open(t)
	c.ok("bulk-open-ok", "bulk/open", m, e, 2, "ap-pass-1")
	c.status("status-receiving", w.n, 1, 0)
	if err := os.WriteFile(filepath.Join(w.fs.bulk, "payload"), w.tgz, 0o600); err != nil {
		t.Fatal(err)
	}
	m, e = w.prepare(t)
	c.ok("prepare-ok", "update/prepare", m, e, 1, uint64(2))
	w.waitWorker(t)
	c.status("status-written", w.n, 3, 0)
	m, e = w.n.updateApply(w.owner, wire(t, cbor.M(1, w.sumSha)))
	c.ok("apply-ok", "update/apply", m, e, 1, uint64(3))
	time.Sleep(100 * time.Millisecond) // the (fake) reboot after the reply

	// update.check refusals: an ok answer with a reason; E_BUSY (precheck rc 14 / another owner's pending); E_RATE
	for _, x := range []struct {
		name string
		mod  func(*fakeUpd)
		why  uint64
	}{
		{"check-refused-board", func(f *fakeUpd) { f.board = "ekh-bcm2710" }, 3},
		{"check-refused-nokey", func(f *fakeUpd) { f.trust.State, f.trust.Root = "none", nil }, 24},
		{"check-refused-downgrade", func(f *fakeUpd) { f.ver = "1.5.14-wsl.31" }, 6},
	} {
		wx := newWorkRig(t, defaultPayload())
		x.mod(wx.f)
		m, e := checkReq(wx, wx.owner)
		c.ok(x.name, "update/check", m, e, 2, x.why)
	}
	wb := newWorkRig(t, defaultPayload())
	wb.f.rc["precheck-node"] = 14
	m, e = checkReq(wb, wb.owner)
	c.refused("check-busy", "update/check", m, e, EBusy, 0)
	wr := newWorkRig(t, defaultPayload())
	if _, e := checkReq(wr, wr.owner); e != nil {
		t.Fatal(e)
	}
	m, e = wr.n.updateCheck(wire(t, cbor.M(1, wr.mf, 2, ownerID(wr.owner)))) // at once: the helper-wide 1 / 10 s
	c.refused("check-rate", "update/check", m, e, ERate, 0)
	m, e = checkReq(wr, vPub(vKey("owner-2")))
	c.refused("check-busy-other-owner", "update/check", m, e, EBusy, 0)

	// bulk.open / bulk.close refusals
	open := func(set func(w *workRig, b *fakeBulk)) (cbor.Map, *Error) {
		w, b := bulkRig(t)
		set(w, b)
		return w.n.bulkOpen(w.owner, wire(t, bulkBody(w.sumSha)))
	}
	m, e = open(func(w *workRig, b *fakeBulk) { w.n.upd.pend = nil })
	c.refused("bulk-open-15", "bulk/open", m, e, EReject, 15)
	m, e = open(func(w *workRig, b *fakeBulk) { b.apUp = false })
	c.refused("bulk-open-16", "bulk/open", m, e, EReject, 16)
	m, e = open(func(w *workRig, b *fakeBulk) { b.httpOK = false })
	c.refused("bulk-open-21", "bulk/open", m, e, EReject, 21)
	m, e = open(func(w *workRig, b *fakeBulk) { w.n.upd.working = true })
	c.refused("bulk-open-busy", "bulk/open", m, e, EBusy, 0)
	wc, _ := bulkRig(t)
	if _, e := wc.open(t); e != nil {
		t.Fatal(e)
	}
	m, e = wc.n.bulkClose(vPub(vKey("owner-2")), wire(t, cbor.M()))
	c.refused("bulk-close-15", "bulk/close", m, e, EReject, 15)
	m, e = wc.n.bulkClose(wc.owner, wire(t, cbor.M()))
	c.ok("bulk-close-ok", "bulk/close", m, e, 0, nil)

	// update.prepare refusals: not the window's holder / an incomplete upload (15), an orphan write (E_BUSY), p6 (E_STORAGE)
	wp := newWorkRig(t, defaultPayload())
	wp.checkAndUpload(t)
	m, e = wp.n.updatePrepare(vPub(vKey("owner-2")), wire(t, cbor.M(1, wp.sumSha)))
	c.refused("prepare-15-not-holder", "update/prepare", m, e, EReject, 15)
	os.WriteFile(filepath.Join(wp.fs.bulk, "payload"), wp.tgz[:10], 0o600)
	m, e = wp.prepare(t)
	c.refused("prepare-15-incomplete", "update/prepare", m, e, EReject, 15)
	os.WriteFile(filepath.Join(wp.fs.bulk, "payload"), wp.tgz, 0o600)
	os.MkdirAll(filepath.Join(wp.fs.wd, "boot"), 0o700)
	wp.fs.busy = true
	m, e = wp.prepare(t)
	c.refused("prepare-busy", "update/prepare", m, e, EBusy, 0)
	wp.fs.busy = false
	wp.fs.p6ok = false
	m, e = wp.prepare(t)
	c.refused("prepare-storage", "update/prepare", m, e, EStorage, 0)

	// update.apply refusals: another owner (15), the target slot busy (E_BUSY)
	wa := newWorkRig(t, defaultPayload())
	wa.checkAndUpload(t)
	wa.prepare(t)
	wa.waitWorker(t)
	m, e = wa.n.updateApply(vPub(vKey("owner-2")), wire(t, cbor.M(1, wa.sumSha)))
	c.refused("apply-15", "update/apply", m, e, EReject, 15)
	wa.f.rc["bootinfo"] = 14
	m, e = wa.n.updateApply(wa.owner, wire(t, cbor.M(1, wa.sumSha)))
	c.refused("apply-busy", "update/apply", m, e, EBusy, 0)

	// status rows while working / after a worker that did not finish
	ww := newWorkRig(t, defaultPayload())
	ww.fs.cutWrite = make(chan struct{})
	ww.checkAndUpload(t)
	if _, e := ww.prepare(t); e != nil {
		t.Fatal(e)
	}
	<-ww.fs.cutWrite
	c.status("status-working", ww.n, 2, 0)
	ww.n.updOwnerRemoved(ownerID(ww.owner))
	ww.waitWorker(t)
	c.status("status-0-22", ww.n, 0, 22)
	wt := newWorkRig(t, defaultPayload())
	wt.checkAndUpload(t)
	os.Link(filepath.Join(wt.fs.bulk, "payload"), filepath.Join(wt.fs.bulk, "second"))
	wt.prepare(t)
	wt.waitWorker(t)
	c.status("status-0-15", wt.n, 0, 15)
	p := defaultPayload()
	s := sumsOf(p.members)
	p.members[2].data = append([]byte("hsqs"), bytes.Repeat([]byte{9}, 5000)...)
	p.sums = s
	wg := newWorkRig(t, p)
	wg.checkAndUpload(t)
	wg.prepare(t)
	wg.waitWorker(t)
	c.status("status-0-11", wg.n, 0, 11)
	w21 := newWorkRig(t, defaultPayload())
	w21.fs.writeRC = []int{14, 14, 14, 14}
	w21.checkAndUpload(t)
	w21.prepare(t)
	w21.waitWorker(t)
	c.status("status-0-21", w21.n, 0, 21)

	// status rows after an apply (TestUpdateStatusTable's update-last / slot states)
	wl := newWorkRig(t, defaultPayload())
	u := wl.n.upd
	put := func(ul *updateLast) { u.updMu.Lock(); u.writeUL(ul); u.updMu.Unlock() }
	cur := wl.f.ver
	base := func() *updateLast {
		return &updateLast{Sha: wl.sumSha, FromSlot: "A", FromVersion: cur, ToSlot: "B", ToVersion: testRel}
	}
	put(base())
	wl.f.active, wl.f.ver = "B", testRel
	wl.fs.trial = true
	c.status("status-trial", wl.n, 4, 0)
	wl.fs.trial = false
	c.status("status-committed", wl.n, 5, 0)
	wl.f.active, wl.f.ver = "A", cur
	ul := base()
	ul.ApplyBootID, ul.Rebooting = "00000000-2222-3333-4444-555555555555", true
	put(ul)
	os.WriteFile(wl.fs.aclog, []byte("20261111-1 TRIAL-REVERTED boot=1 slot=B version="+testRel+" waited=300s\n"), 0o644)
	c.status("status-reverted", wl.n, 6, 0)
	os.Remove(wl.fs.aclog)
	c.status("status-reverted-18", wl.n, 6, 18)
	put(base())
	u.siMu.Lock()
	u.slots["B"], u.slotsBad["B"] = slotInfo{Verified: hex.EncodeToString(wl.sumSha) + " 00000000-2222-3333-4444-555555555555"}, 0
	u.siMu.Unlock()
	c.status("status-0-23", wl.n, 0, 23)

	if d := os.Getenv("BATMAN_CAPTURE_DIR"); d != "" {
		out, _ := json.MarshalIndent(map[string]any{
			"manifest": hex.EncodeToString(w.mf),
			"sha":      hex.EncodeToString(w.sumSha),
			"size":     len(w.tgz),
			"version":  testRel,
			"cases":    c.cases,
		}, "", " ")
		if err := os.WriteFile(filepath.Join(d, "node-helper.json"), append(out, '\n'), 0o644); err != nil {
			t.Fatal(err)
		}
		t.Logf("wrote %d replies to %s", len(c.cases), d)
	}
}
