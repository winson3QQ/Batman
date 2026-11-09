package node

// settings.get (docs/design/254-p3-impl.md §3.3): the node's settings for its owner, from a cache the helper refreshes
// in the background (every 15 s while someone asked in the last 10 min, single-flight; the first request waits <= 2 s).
// No child process on the request path (readonly.go). Keys: 1 hostname, 2 country (radio1), 10 {1: channel, 2:
// bandwidth MHz from the morse regdb for that country + channel}, 20 {1: the phone AP's ssid} — never a password.
// A value that is missing or not well-formed is omitted, never guessed. Nothing read yet -> E_BUSY (re-read).

import (
	"strconv"
	"strings"
	"sync"
	"time"

	"batman-prov/cbor"
)

// Settings is one read of the live values (uci) — strings as uci prints them.
type Settings struct {
	Hostname, Country, Channel, SSID string
	// RegdbBW: country + S1G channel -> bandwidth in MHz (the morse regdb netifd and halow-setkey use)
	RegdbBW func(country, channel string) (uint64, bool)
}

type settingsCache struct {
	mu       sync.Mutex
	src      func() (Settings, error)
	val      *Settings
	at       time.Time
	busy     bool
	done     chan struct{}
	asked    time.Time
	now      func() time.Time
	runAsync func(func())
}

func newSettingsCache(src func() (Settings, error), now func() time.Time) *settingsCache {
	return &settingsCache{src: src, now: now, runAsync: func(f func()) { go f() }}
}

func (c *settingsCache) refresh() chan struct{} {
	c.mu.Lock()
	if c.busy {
		d := c.done
		c.mu.Unlock()
		return d
	}
	c.busy, c.done = true, make(chan struct{})
	done := c.done
	c.mu.Unlock() // the refresh takes c.mu itself
	c.runAsync(func() {
		s, err := c.src()
		c.mu.Lock()
		if err == nil {
			c.val, c.at = &s, c.now()
		}
		c.busy = false
		c.mu.Unlock()
		close(done)
	})
	return done
}

// Tick: refresh when due while someone asked in the last 10 min (same window and period as status).
func (c *settingsCache) Tick() {
	c.mu.Lock()
	now := c.now()
	due := !c.asked.IsZero() && now.Sub(c.asked) < statusAskWindow && (c.at.IsZero() || now.Sub(c.at) >= statusFresh)
	c.mu.Unlock()
	if due {
		c.refresh()
	}
}

func isCountry(s string) bool {
	return len(s) == 2 && s[0] >= 'A' && s[0] <= 'Z' && s[1] >= 'A' && s[1] <= 'Z'
}

func (c *settingsCache) get() (cbor.Map, *Error) {
	c.mu.Lock()
	c.asked = c.now()
	have := c.val != nil && c.asked.Sub(c.at) <= statusStaleAfter
	c.mu.Unlock()
	if !have {
		select {
		case <-c.refresh():
		case <-time.After(statusFirstWait):
		}
	}
	c.mu.Lock()
	v, at, now := c.val, c.at, c.now()
	c.mu.Unlock()
	if v == nil || now.Sub(at) > statusStaleAfter {
		return nil, fail(EBusy, "settings not read yet (or only an old read)")
	}
	m := cbor.M()
	if v.Hostname != "" {
		m = append(m, cbor.Entry{K: uint64(1), V: v.Hostname})
	}
	if isCountry(v.Country) {
		m = append(m, cbor.Entry{K: uint64(2), V: v.Country})
	}
	if ch, err := strconv.ParseUint(strings.TrimSpace(v.Channel), 10, 32); err == nil {
		h := cbor.M(1, ch)
		if v.RegdbBW != nil && isCountry(v.Country) {
			if bw, ok := v.RegdbBW(v.Country, v.Channel); ok {
				h = append(h, cbor.Entry{K: uint64(2), V: bw})
			}
		}
		m = append(m, cbor.Entry{K: uint64(10), V: h})
	}
	if v.SSID != "" {
		m = append(m, cbor.Entry{K: uint64(20), V: cbor.M(1, v.SSID)})
	}
	return m, nil
}

// SetSettingsSource wires settings.get's cache; the daemon's 1 s ticker calls StatusTick, which ticks this one too.
func (n *Node) SetSettingsSource(src func() (Settings, error)) {
	n.settings = newSettingsCache(src, n.now)
}

func (n *Node) settingsGet(a cbor.Map) (cbor.Map, *Error) {
	if n.settings == nil {
		return nil, fail(EUnsupported, "no settings source")
	}
	if e := onlyKeys(a); e != nil {
		return nil, e
	}
	return n.settings.get()
}

// RegdbLookup parses the morse regdb (channels.csv: country_code,channelizations,default_channelization,bw,s1g_chan,…;
// captured on 04, wsl.22) and returns the bandwidth of country + channel.
func RegdbLookup(csv string) func(country, channel string) (uint64, bool) {
	return func(country, channel string) (uint64, bool) {
		for _, line := range strings.Split(csv, "\n") {
			f := strings.Split(strings.TrimSpace(line), ",")
			if len(f) < 5 || f[0] != country || f[4] != strings.TrimSpace(channel) {
				continue
			}
			bw, err := strconv.ParseUint(f[3], 10, 32)
			return bw, err == nil
		}
		return 0, false
	}
}
