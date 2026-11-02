package node

// Read-only verbs (docs/design/254-p2-impl.md §1.3, §4.3): answered WITHOUT n.mu, so provd's ctl connection, a second
// phone and provclient are not queued behind a state change (net.apply can hold the mutex for minutes) or BootFinish.
// They touch only n.P, n.KS (read-only after Load; Cert / SN return copies), n.BootID, n.Log and the overlay files
// (read with a retry: WriteOverlay renames the record before the meta, F-P25) — never nonces / signLog / replayF /
// Verdict / finishFails. Quotas (uid 471 is one principal; a quota per connection alone is reset by reconnecting):
// helper-wide 10/s burst 40 and per connection 5/s burst 20; over -> ERate, the connection stays.

import (
	"sync"
	"time"

	"batman-prov/cbor"
	"batman-prov/provstore"
)

// readOnlyVerbs is the closed list; every other verb takes the mutex.
var readOnlyVerbs = map[string]bool{"health.get": true, "info.boot_id": true, "info.cert": true, "info.ecdh_pub": true,
	"info.state": true, "info.net": true, "info.owners": true}

const (
	roGlobalRate, roGlobalBurst = 10, 40
	roConnRate, roConnBurst     = 5, 20
)

// bucket is a token bucket; the zero value with rate / burst set starts full.
type bucket struct {
	mu          sync.Mutex
	rate, burst float64
	tokens      float64
	last        time.Time
}

func (b *bucket) take(now time.Time) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.last.IsZero() {
		b.tokens = b.burst
	} else {
		b.tokens += now.Sub(b.last).Seconds() * b.rate
		if b.tokens > b.burst {
			b.tokens = b.burst
		}
	}
	b.last = now
	if b.tokens < 1 {
		return false
	}
	b.tokens--
	return true
}

// NewConn returns the handler of one helper-socket connection, with its own read-only quota (sock.ServeConns).
func (n *Node) NewConn() func(cbor.Map) cbor.Map {
	b := &bucket{rate: roConnRate, burst: roConnBurst}
	return func(req cbor.Map) cbor.Map { return n.handle(req, b) }
}

func (n *Node) now() time.Time {
	if n.clock != nil {
		return n.clock()
	}
	return time.Now()
}

// trial is info.state key 5: the cached batman-slot is-trial (TrialCached, <= 5 s old) when the daemon wired one.
func (n *Node) trial() bool {
	if n.TrialCached != nil {
		return n.TrialCached()
	}
	return n.Sys.IsTrial()
}

// loadOverlayRO reads the overlay without the mutex: a meta / record mismatch may be a write in progress -> re-read up
// to 3 times; still inconsistent -> the error (provd keeps its cache, §4.3).
func (n *Node) loadOverlayRO() (*provstore.Record, error) {
	var rec *provstore.Record
	var err error
	for i := 0; i < 4; i++ {
		if i > 0 {
			time.Sleep(5 * time.Millisecond)
		}
		rec, _, err = provstore.LoadOverlay(n.P)
		if err == nil {
			return rec, nil
		}
	}
	return nil, err
}

func (n *Node) readOnly(verb string, a cbor.Map, conn *bucket) (cbor.Map, *Error) {
	now := n.now()
	if conn != nil && !conn.take(now) {
		return nil, fail(ERate, "read-only verbs: per-connection quota")
	}
	if !n.roGlobal.take(now) {
		return nil, fail(ERate, "read-only verbs: helper-wide quota")
	}
	if e := onlyKeys(a); e != nil {
		return nil, e
	}
	switch verb {
	case "health.get":
		if n.Health == nil {
			return nil, fail(EUnsupported, "no health source")
		}
		return cbor.M(1, n.Health()), nil
	case "info.cert":
		return cbor.M(1, n.KS.Cert(), 2, n.KS.SN()), nil
	case "info.ecdh_pub":
		return cbor.M(1, n.KS.ECDHPub()), nil
	case "info.boot_id":
		return cbor.M(1, n.BootID), nil
	}
	rec, err := n.loadOverlayRO()
	if err != nil || rec == nil {
		return nil, fail(EUnsupported, "no usable provisioning record (%v)", err)
	}
	switch verb {
	case "info.state":
		return cbor.M(1, rec.State, 2, rec.Generation, 3, uint64(len(rec.Owners)), 4, rec.RadioManaged, 5, n.trial()), nil
	case "info.net":
		// net_id / version / left / unfinished for the app's "already done" decision (254-wireless-txn §4.1); unfinished
		// is also 1 while this node's own join is still in steps 1-4 (F-P39). provd routes it only for the owner and
		// member roles: a stable net_id to any BLE peer would link a fleet (§14).
		var nid any
		var ver uint64
		if rec.Net != nil {
			nid, ver = rec.Net.NetID, rec.Net.Version
		}
		return cbor.M(1, nid, 2, ver, 3, rec.Left, 4, provstore.TxnPresent(n.P)), nil
	case "info.owners": // provd verifies auth/owner with these (§1.3)
		pubs := []any{}
		for _, o := range rec.Owners {
			pubs = append(pubs, o.Pub)
		}
		return cbor.M(1, pubs), nil
	}
	return nil, fail(ESchema, "unreachable")
}
