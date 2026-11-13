package node

// status.get (docs/design/254-p3-impl.md §3.4): the node's own status for the app, answered from two caches the helper
// keeps in the background — the request path never runs a child process (readonly.go's contract):
//   - `halow-status json`: refreshed every 15 s while someone asked in the last 10 min (single-flight). The first
//     request triggers a refresh and waits up to 2 s; still nothing -> key 1 only + 15: {stale: true}.
//   - p5_saved: `batman-config-save --check` at most once per 120 s while someone asked in the last 10 min (cfgsave.lock
//     is taken at most once per 2 min, so --on-join is never starved, F28); older than 300 s or never -> key 4 omitted.
// Ages are measured on Go's monotonic clock (no RTC on the node: wall time is meaningless there).
//
// args: {1: full (bool)} — provd sends full = true for the owner role, false for a member (members get keys 1-5, and
// 8 / 9 of the whole-team sampling, peers.go; never key 15).

import (
	"encoding/json"
	"strings"
	"sync"
	"time"

	"batman-prov/cbor"
	"batman-prov/provstore"
)

const (
	statusFresh     = 15 * time.Second
	statusP5Every   = 120 * time.Second
	statusP5MaxAge  = 300 * time.Second
	statusAskWindow = 10 * time.Minute
	statusFirstWait = 2 * time.Second
	// statusStaleAfter: a cache older than this is refreshed (and waited for) before it is answered: inside the ask
	// window the ticker keeps it <= statusFresh + 1 s; after a quiet spell it may be hours old (code review M2)
	statusStaleAfter = 2 * statusFresh
	statusGlobalRate = 2 // helper-wide 2/s; the 1/s per app connection is provd's (§3.1-9)
)

// StatusSource is what the caches are filled from; the daemon wires the real commands, tests inject.
type StatusSource struct {
	HalowStatus func() ([]byte, error) // `halow-status json`
	P5Fresh     func() (bool, error)   // `batman-config-save --check` says "p5 fresh"
	// design D-12 / §5.1 (optional; nil = not reported): packages with staged uci changes (uci's save dir), the reason a
	// settings.set answers E_BUSY (a directory listing, no child process); the phone AP ssid is not saved to p5 (it has
	// a config-save UNSAFE character) — SetStatusSource wires it from the settings cache (A r2 MAJOR-1: the request
	// path never runs a child process)
	UciStaged   func() []string
	SSIDUnsaved func() bool
	// D-6: the last settings.set's restore did not verify (wired by SetStatusSource from the node)
	RestoreBad func() bool
	// §3.8.1: provd could not bind 8095 (wired by SetStatusSource from the node)
	HTTPBindFailed func() bool
	// §3.7.4: the image's root key: "none" / "bad" / the first 8 bytes of its fingerprint, hex (wired from the node)
	Trust func() string
}

type statusCache struct {
	mu       sync.Mutex
	src      StatusSource
	js       []byte
	jsAt     time.Time
	jsBusy   bool
	jsDone   chan struct{} // closed when the running refresh ends
	p5       bool
	p5At     time.Time
	p5Busy   bool
	asked    time.Time
	global   bucket
	now      func() time.Time
	runAsync func(func()) // go f() in the daemon; tests may run inline
}

func newStatusCache(src StatusSource, now func() time.Time) *statusCache {
	return &statusCache{src: src, now: now, global: bucket{rate: statusGlobalRate, burst: statusGlobalRate},
		runAsync: func(f func()) { go f() }}
}

// refreshJS starts a halow-status refresh unless one runs; returns the channel closed when the current one ends.
func (c *statusCache) refreshJS() chan struct{} {
	c.mu.Lock()
	if c.jsBusy {
		done := c.jsDone
		c.mu.Unlock()
		return done
	}
	c.jsBusy, c.jsDone = true, make(chan struct{})
	done := c.jsDone
	c.mu.Unlock() // the refresh takes c.mu itself: never start it while holding it
	c.runAsync(func() {
		b, err := c.src.HalowStatus()
		c.mu.Lock()
		if err == nil && json.Valid(b) {
			c.js, c.jsAt = b, c.now()
		}
		c.jsBusy = false
		c.mu.Unlock()
		close(done)
	})
	return done
}

func (c *statusCache) refreshP5() {
	c.mu.Lock()
	if c.p5Busy {
		c.mu.Unlock()
		return
	}
	c.p5Busy = true
	c.mu.Unlock()
	c.runAsync(func() {
		ok, err := c.src.P5Fresh()
		c.mu.Lock()
		if err == nil {
			c.p5, c.p5At = ok, c.now()
		}
		c.p5Busy = false
		c.mu.Unlock()
	})
}

// Tick is called every second by the daemon: refreshes what is due while someone asked in the last 10 min.
func (c *statusCache) Tick() {
	c.mu.Lock()
	now := c.now()
	active := !c.asked.IsZero() && now.Sub(c.asked) < statusAskWindow
	jsDue := active && (c.jsAt.IsZero() || now.Sub(c.jsAt) >= statusFresh)
	p5Due := active && (c.p5At.IsZero() || now.Sub(c.p5At) >= statusP5Every)
	c.mu.Unlock()
	if jsDue {
		c.refreshJS()
	}
	if p5Due {
		c.refreshP5()
	}
}

// halow-status json, the part status reads (field names as `halow-status json` prints them on 04, wsl.22)
type halowStatus struct {
	Node           string `json:"node"`
	Image          string `json:"image"`
	UptimeS        uint64 `json:"uptime_s"`
	LastBootReason string `json:"last_boot_reason"`
	LastOTA        string `json:"last_ota"`
	TempC          string `json:"temp_c"`
	Throttled      string `json:"throttled"`
	Tenants        string `json:"tenants"`
	Health         struct {
		Level string `json:"level"`
	} `json:"health"`
	Join struct {
		State      string  `json:"state"`
		Detail     string  `json:"detail"`
		Channel    string  `json:"channel"`
		Country    string  `json:"country"`
		Plinks     *uint64 `json:"plinks"`
		Neighbours *uint64 `json:"batman_neighbours"`
		SNR        string  `json:"snr_db"`
		ReasonCode *uint64 `json:"reason_code"` // joinwatch verdict_code() (§3.4); missing -> 0
	} `json:"join"`
}

var verdictOf = map[string]uint64{"OK": 0, "WARN": 1, "CRIT": 2}

// get answers status.get; state is info.state's node state (needs no cache).
func (c *statusCache) get(state string, full bool) cbor.Map {
	c.mu.Lock()
	c.asked = c.now()
	have := c.js != nil && c.asked.Sub(c.jsAt) <= statusStaleAfter
	c.mu.Unlock()
	if !have {
		done := c.refreshJS()
		select {
		case <-done:
		case <-time.After(statusFirstWait):
		}
	}
	c.mu.Lock()
	js, jsAt := c.js, c.jsAt
	p5, p5At := c.p5, c.p5At
	now := c.now()
	c.mu.Unlock()
	if !p5At.IsZero() && now.Sub(p5At) > statusP5MaxAge {
		p5At = time.Time{}
	}
	if p5At.IsZero() {
		c.refreshP5()
	}
	var h halowStatus
	if js == nil || now.Sub(jsAt) > statusStaleAfter || json.Unmarshal(js, &h) != nil {
		if !full {
			return cbor.M(1, state) // a member gets key 1 only (B r3 m2: not left to provd's filter alone)
		}
		return cbor.M(1, state, 15, cbor.M("stale", true)) // old data is not shown as current
	}
	m := cbor.M(1, state)
	if v, ok := verdictOf[h.Health.Level]; ok {
		m = append(m, cbor.Entry{K: uint64(2), V: v})
	}
	if h.Join.Neighbours != nil {
		m = append(m, cbor.Entry{K: uint64(3), V: *h.Join.Neighbours})
	}
	if !p5At.IsZero() {
		m = append(m, cbor.Entry{K: uint64(4), V: p5})
	}
	if h.Join.State != "JOINED" {
		var rc uint64
		if h.Join.ReasonCode != nil {
			rc = *h.Join.ReasonCode
		}
		m = append(m, cbor.Entry{K: uint64(5), V: cbor.M(1, rc, 2, strings.TrimSpace(h.Join.State+" "+h.Join.Detail))})
	}
	if full {
		j := cbor.M("state", h.Join.State, "channel", h.Join.Channel, "country", h.Join.Country, "snr_db", h.Join.SNR)
		if h.Join.Plinks != nil {
			j = append(j, cbor.Entry{K: "plinks", V: *h.Join.Plinks})
		}
		f := cbor.M("node", h.Node, "image", h.Image, "uptime_s", h.UptimeS, "last_boot_reason", h.LastBootReason,
			"last_ota", h.LastOTA, "temp_c", h.TempC, "throttled", h.Throttled, "tenants", h.Tenants,
			"age_s", uint64(now.Sub(jsAt)/time.Second), "join", j)
		if c.src.UciStaged != nil {
			if pk := c.src.UciStaged(); len(pk) > 0 {
				a := make([]any, len(pk))
				for i, p := range pk {
					a[i] = p
				}
				f = append(f, cbor.Entry{K: "uci_staged", V: a})
			}
		}
		if c.src.SSIDUnsaved != nil && c.src.SSIDUnsaved() {
			f = append(f, cbor.Entry{K: "ssid_unsaved", V: true})
		}
		if c.src.RestoreBad != nil && c.src.RestoreBad() {
			f = append(f, cbor.Entry{K: "settings_restore", V: "not verified"})
		}
		if c.src.HTTPBindFailed != nil && c.src.HTTPBindFailed() {
			f = append(f, cbor.Entry{K: "http_bind_failed", V: true})
		}
		if c.src.Trust != nil {
			f = append(f, cbor.Entry{K: "trust", V: c.src.Trust()})
		}
		m = append(m, cbor.Entry{K: uint64(15), V: f})
	}
	return m
}

// SetStatusSource wires status.get's caches; the daemon calls StatusTick every second.
func (n *Node) SetStatusSource(src StatusSource) {
	if src.RestoreBad == nil {
		src.RestoreBad = n.settingsRestoreBad.Load
	}
	if src.SSIDUnsaved == nil {
		src.SSIDUnsaved = n.ssidUnsavedCached
	}
	if src.HTTPBindFailed == nil {
		src.HTTPBindFailed = n.httpBindFailed.Load
	}
	if src.Trust == nil {
		src.Trust = n.trustState
	}
	n.status = newStatusCache(src, n.now)
}

// trustState: the image's root key as status key 15 shows it; a node without the update verbs (not an A/B card) =
// "none" — it cannot be updated through the app either
func (n *Node) trustState() string {
	if u := n.upd; u != nil && u.sys != nil {
		return u.sys.Trust().State
	}
	return "none"
}

// StatusTick refreshes the status caches that are due (no-op without a source).
func (n *Node) StatusTick() {
	if n.status != nil {
		n.status.Tick()
	}
	if n.settings != nil {
		n.settings.Tick()
	}
	if n.peers != nil {
		n.peers.Tick()
	}
}

func (n *Node) statusGet(a cbor.Map, now time.Time, conn *bucket) (cbor.Map, *Error) {
	if n.status == nil {
		return nil, fail(EUnsupported, "no status source")
	}
	if conn != nil && !conn.take(now) {
		return nil, fail(ERate, "status.get: per-connection quota")
	}
	if !n.status.global.take(now) {
		return nil, fail(ERate, "status.get: helper-wide quota")
	}
	if e := onlyKeys(a, 1); e != nil {
		return nil, e
	}
	fv, _ := a.Get(1)
	full, ok := fv.(bool)
	if !ok {
		return nil, fail(ESchema, "status.get: key 1 (full) must be a bool")
	}
	rec, err := n.loadOverlayRO()
	if err != nil || rec == nil {
		return nil, fail(EUnsupported, "no usable provisioning record (%v)", err)
	}
	if full && n.settings != nil {
		n.settings.touch()
	}
	m := n.status.get(rec.State, full)
	if n.peers != nil { // 254-app-team-status §4.1: keys 8 / 9 for the owner and a member alike
		inNet := rec.State == provstore.Member || rec.State == provstore.Legacy
		var netID []byte
		if rec.Net != nil {
			netID = rec.Net.NetID
		}
		m = append(m, n.peers.keys(n.now(), inNet, netID)...)
	}
	return m, nil
}
