package node

import (
	"os"
	"testing"
	"time"

	"batman-prov/cbor"
	"batman-prov/provstore"
)

func callConn(t *testing.T, h func(cbor.Map) cbor.Map, verb string, id uint64) int {
	raw, _ := cbor.Encode(cbor.M(1, verb, 2, id, 3, cbor.M()))
	dec, err := cbor.Decode(raw)
	if err != nil {
		t.Fatal(err)
	}
	c, _ := h(dec.(cbor.Map)).Get(2)
	return int(c.(uint64))
}

// 254-p2-impl L71: while a state change holds n.mu (net.apply can for minutes), the read-only verbs answer; a mutex
// verb waits. Negative control: the pre-P2 Handle locks first -> info.state waits -> FAIL.
func TestReadOnlyWhileMutexHeld(t *testing.T) {
	r := claimedRig(t)
	r.n.mu.Lock()
	defer r.n.mu.Unlock()
	for _, v := range []string{"info.state", "info.net", "info.owners", "info.cert", "info.ecdh_pub", "info.boot_id"} {
		done := make(chan int, 1)
		go func() { c, _ := r.call(v, cbor.M()); done <- c }()
		select {
		case c := <-done:
			if c != OK {
				t.Fatalf("%s: code %d", v, c)
			}
		case <-time.After(time.Second):
			t.Fatalf("%s waited for the mutex", v)
		}
	}
	done := make(chan int, 1)
	go func() { c, _ := r.call("info.counter", cbor.M()); done <- c }()
	select {
	case <-done:
		t.Fatal("info.counter ran without the mutex")
	case <-time.After(200 * time.Millisecond):
	}
}

// the read-only list is closed: nonce / sign.* / psks.get / claim.* stay under the mutex
func TestReadOnlyListClosed(t *testing.T) {
	want := map[string]bool{"health.get": true, "info.boot_id": true, "info.cert": true, "info.ecdh_pub": true,
		"info.state": true, "info.net": true, "info.owners": true}
	if len(readOnlyVerbs) != len(want) {
		t.Fatalf("read-only verbs %v", readOnlyVerbs)
	}
	for v := range want {
		if !readOnlyVerbs[v] {
			t.Fatalf("%s missing", v)
		}
	}
}

func TestInfoStateTrialAndInfoNetUnfinished(t *testing.T) {
	r := newRig(t, "unclaimed")
	r.sys.trial = true
	c, res := r.call("info.state", cbor.M())
	if v, _ := res.Get(5); c != OK || v != true {
		t.Fatalf("trial: %d %v", c, res)
	}
	calls := 0
	r.n.TrialCached = func() bool { calls++; return false } // the daemon's cache wins over Sys.IsTrial
	if _, res = r.call("info.state", cbor.M()); func() bool { v, _ := res.Get(5); return v != false }() || calls != 1 {
		t.Fatalf("cached trial not used: %v calls=%d", res, calls)
	}
	_, res = r.call("info.net", cbor.M())
	if v, _ := res.Get(4); v != false {
		t.Fatalf("unfinished without .txn: %v", res)
	}
	provstore.WriteTxn(r.n.P, "00", 1, 2, "network/join", "k", "id", "1", false)
	_, res = r.call("info.net", cbor.M())
	if v, _ := res.Get(4); v != true {
		t.Fatalf("unfinished with .txn: %v", res)
	}
}

func TestInfoOwnersAndHealthGet(t *testing.T) {
	r := claimedRig(t)
	c, res := r.call("info.owners", cbor.M())
	l, _ := res.Get(1)
	pubs, _ := l.([]any)
	if c != OK || len(pubs) != 1 || string(pubs[0].([]byte)) != string(pub(r.owner)) {
		t.Fatalf("info.owners %d %v", c, res)
	}
	if c, _ := r.call("health.get", cbor.M()); c != EUnsupported {
		t.Fatalf("health.get without a source: %d", c)
	}
	r.n.Health = func() string { return "boot_id=x num_instances=0\n" }
	c, res = r.call("health.get", cbor.M())
	if v, _ := res.Get(1); c != OK || v != "boot_id=x num_instances=0\n" {
		t.Fatalf("health.get %d %v", c, res)
	}
	// no record: health.get still answers (dispatch's no-record list), info.owners does not
	os.Remove(r.n.P.Meta())
	if c, _ := r.call("health.get", cbor.M()); c != OK {
		t.Fatalf("health.get without a record: %d", c)
	}
	if c, _ := r.call("info.owners", cbor.M()); c != EUnsupported {
		t.Fatalf("info.owners without a record: %d", c)
	}
}

// helper-wide 10/s burst 40 + per connection 5/s burst 20 (254-p2-impl §4.3). Churn: 50 connections x 20 requests in
// well under a second -> the helper-wide bucket refuses. Mutant: drop the helper-wide bucket -> all 1000 OK -> FAIL.
func TestReadOnlyQuotaChurn(t *testing.T) {
	r := newRig(t, "unclaimed")
	now := time.Unix(5000, 0)
	r.n.clock = func() time.Time { return now }
	ok, rate := 0, 0
	for c := 0; c < 50; c++ {
		h := r.n.NewConn()
		for i := 0; i < 20; i++ {
			switch callConn(t, h, "info.boot_id", uint64(i+1)) {
			case OK:
				ok++
			case ERate:
				rate++
			}
		}
	}
	if ok != roGlobalBurst || rate != 1000-roGlobalBurst {
		t.Fatalf("churn: %d OK, %d ERate (want %d / %d)", ok, rate, roGlobalBurst, 1000-roGlobalBurst)
	}
	// refill: one second later the global bucket has 10 more
	now = now.Add(time.Second)
	h := r.n.NewConn()
	ok = 0
	for i := 0; i < 20; i++ {
		if callConn(t, h, "info.boot_id", uint64(i+1)) == OK {
			ok++
		}
	}
	if ok != roGlobalRate {
		t.Fatalf("after 1 s: %d OK (want %d)", ok, roGlobalRate)
	}
}

// one connection: 20 burst then 5/s; ERate does not close anything (the handler keeps answering)
func TestReadOnlyQuotaPerConnection(t *testing.T) {
	r := newRig(t, "unclaimed")
	now := time.Unix(5000, 0)
	r.n.clock = func() time.Time { return now }
	h := r.n.NewConn()
	ok := 0
	for i := 0; i < 30; i++ {
		if callConn(t, h, "info.state", uint64(i+1)) == OK {
			ok++
		}
	}
	if ok != roConnBurst {
		t.Fatalf("burst %d (want %d)", ok, roConnBurst)
	}
	now = now.Add(time.Second)
	ok = 0
	for i := 0; i < 10; i++ {
		if callConn(t, h, "info.state", uint64(i+100)) == OK {
			ok++
		}
	}
	if ok != roConnRate {
		t.Fatalf("after 1 s %d (want %d)", ok, roConnRate)
	}
}

// psks.get: no keys 4/5 (adv_owner / adv_member stay in the helper, §8) and 1/s
func TestPsksGetNoAdvKeysAndRate(t *testing.T) {
	r := claimedRig(t)
	now := time.Unix(5000, 0)
	r.n.clock = func() time.Time { return now }
	c, res := r.call("psks.get", cbor.M())
	if c != OK {
		t.Fatalf("psks.get %d", c)
	}
	for _, k := range []int{4, 5} {
		if _, ok := res.Get(k); ok {
			t.Fatalf("psks.get returned key %d", k)
		}
	}
	if l, _ := res.Get(1); len(l.([]any)) != 1 {
		t.Fatalf("psk_owner list %v", res)
	}
	if c, _ := r.call("psks.get", cbor.M()); c != ERate {
		t.Fatalf("second psks.get within 1 s: %d", c)
	}
	now = now.Add(time.Second)
	if c, _ := r.call("psks.get", cbor.M()); c != OK {
		t.Fatalf("psks.get after 1 s: %d", c)
	}
}

// F-P25: a reader between WriteOverlay's two renames sees a new record with the old meta -> re-read. A meta that stays
// inconsistent -> EUnsupported (provd keeps its cache). Mutant: no re-read -> the first call fails -> FAIL.
func TestReadOnlyTornOverlayReread(t *testing.T) {
	r := newRig(t, "unclaimed")
	rec, _, _ := provstore.LoadOverlay(r.n.P)
	oldMeta, _ := os.ReadFile(r.n.P.Meta())
	next := *rec
	next.Generation = 2
	provstore.WriteOverlay(r.n.P, &next)
	newMeta, _ := os.ReadFile(r.n.P.Meta())
	os.WriteFile(r.n.P.Meta(), oldMeta, 0o600) // torn: new record, old meta
	go func() { time.Sleep(7 * time.Millisecond); os.WriteFile(r.n.P.Meta(), newMeta, 0o600) }()
	c, res := r.call("info.state", cbor.M())
	if g, _ := res.Get(2); c != OK || g != uint64(2) {
		t.Fatalf("torn read not re-read: %d %v", c, res)
	}
	os.WriteFile(r.n.P.Meta(), oldMeta, 0o600) // stays torn
	if c, _ := r.call("info.state", cbor.M()); c != EUnsupported {
		t.Fatalf("persistently torn overlay: %d", c)
	}
}
