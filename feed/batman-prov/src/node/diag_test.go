package node

import (
	"testing"
	"time"

	"batman-prov/cbor"
)

// 254-p3-impl §3.5: diag.summary from the 04 capture: health.checks -> diag-item {1 id, 2 severity, 4 msg}
func TestDiagSummaryFrom04(t *testing.T) {
	r, _ := statusRig(t, &fakeStatus{js: hs04(t), inline: true})
	c, m := r.call("diag.summary", cbor.M())
	if c != OK {
		t.Fatalf("diag.summary %d", c)
	}
	v, _ := m.Get(1)
	items := v.([]any)
	if len(items) < 2 {
		t.Fatalf("items %v", items)
	}
	first := items[0].(cbor.Map)
	if id, _ := first.Get(1); id != "mesh" {
		t.Fatalf("first id %v", id)
	}
	if sev, _ := first.Get(2); sev != uint64(2) {
		t.Fatalf("CRIT -> severity %v, want 2", sev)
	}
	if msg, _ := first.Get(4); msg == nil {
		t.Fatal("no msg")
	}
	second := items[1].(cbor.Map)
	if sev, _ := second.Get(2); sev != uint64(0) {
		t.Fatalf("OK -> severity %v, want 0", sev)
	}
}

// no current read -> E_BUSY (not an empty "all fine" list); arguments are refused
func TestDiagSummaryNoReadAndArgs(t *testing.T) {
	f := &fakeStatus{js: hs04(t), inline: true}
	r, now := statusRig(t, f)
	if c, _ := r.call("diag.summary", cbor.M(1, uint64(1))); c != ESchema {
		t.Fatalf("an argument: %d", c)
	}
	f.gate = make(chan struct{})
	r.n.status.runAsync = func(fn func()) { go fn() }
	*now = now.Add(time.Second)
	c, _ := r.call("diag.summary", cbor.M())
	close(f.gate)
	if c != EBusy {
		t.Fatalf("no read yet: %d, want E_BUSY", c)
	}
}

// a level halow-status may add later (not OK / WARN / CRIT) is a warning (1), never dropped or "fine"
func TestDiagSummaryUnknownLevel(t *testing.T) {
	js := []byte(`{"health":{"level":"WARN","checks":[{"id":"x","level":"NOTICE","msg":"m"},{"id":"y","level":"WARN"}]},"join":{"state":"JOINED"}}`)
	r, _ := statusRig(t, &fakeStatus{js: js, inline: true})
	c, m := r.call("diag.summary", cbor.M())
	v, _ := m.Get(1)
	items, _ := v.([]any)
	if c != OK || len(items) != 2 {
		t.Fatalf("diag.summary %d %v", c, m)
	}
	if sev, _ := items[0].(cbor.Map).Get(2); sev != uint64(1) {
		t.Fatalf("unknown level -> %v, want 1", sev)
	}
	if _, ok := items[1].(cbor.Map).Get(4); ok {
		t.Fatal("an empty msg was sent")
	}
}
