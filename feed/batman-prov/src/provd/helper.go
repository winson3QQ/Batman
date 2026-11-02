package provd

import (
	"errors"
	"net"
	"sync"
	"time"

	"batman-prov/cbor"
)

// Helper error codes provd reads (node.go): only the ones it maps differently.
const (
	hOK              = 0
	hEForbidden      = 3
	hEBadObject      = 4
	hEStaleVersion   = 5
	hEUnsupported    = 6
	hEBusy           = 7
	hEStorage        = 10
	hERate           = 12
	hESchema         = 20
	hEApply          = 21
	hEState          = 22
	hELockIncomplete = 23
)

var (
	// ErrBusy: this connection already has a request in flight (ops: one at a time, 254-p2-impl §4.3)
	ErrBusy = errors.New("provd: helper connection busy")
	// ErrTimeout: no answer in time; on ops the request may still complete (the connection stays, the late answer is
	// dropped by its id)
	ErrTimeout = errors.New("provd: helper did not answer in time")
	// ErrGone: no connection (helper not reachable / connection lost before the answer)
	ErrGone = errors.New("provd: helper connection lost")
)

// Reply is one helper answer.
type Reply struct {
	Code int
	Body cbor.Map
}

type waiter struct {
	id uint64
	ch chan result
}

type result struct {
	r   Reply
	err error
}

// HelperConn is one SEQPACKET connection to batman-provhelper with at most one request in flight. Connected lazily;
// after a failed dial the next attempt waits (1, 2, 4 … MaxBackoff s).
type HelperConn struct {
	Path       string
	Name       string // ctl / ops (logs)
	MaxBackoff time.Duration
	Log        func(string, ...any)
	Dial       func(path string) (*net.UnixConn, error) // tests

	mu       sync.Mutex
	c        *net.UnixConn
	id       uint64
	inflight bool
	flightID uint64
	w        *waiter
	lastSend time.Time
	epoch    uint64 // +1 per new connection (the helper's nonces / claim state are per connection lifetime)
	backoff  time.Duration
	nextDial time.Time
}

func (h *HelperConn) dial() error {
	if time.Now().Before(h.nextDial) {
		return ErrGone
	}
	d := h.Dial
	if d == nil {
		d = func(p string) (*net.UnixConn, error) {
			return net.DialUnix("unixpacket", nil, &net.UnixAddr{Name: p, Net: "unixpacket"})
		}
	}
	c, err := d(h.Path)
	if err != nil {
		if h.backoff == 0 {
			h.backoff = time.Second
		} else if h.backoff *= 2; h.backoff > h.MaxBackoff && h.MaxBackoff > 0 {
			h.backoff = h.MaxBackoff
		}
		h.nextDial = time.Now().Add(h.backoff)
		h.logf("helper %s: connect failed (%v); backoff %s", h.Name, err, h.backoff)
		return ErrGone
	}
	h.c, h.backoff, h.nextDial = c, 0, time.Time{}
	h.epoch++
	go h.reader(c)
	return nil
}

func (h *HelperConn) logf(f string, a ...any) {
	if h.Log != nil {
		h.Log(f, a...)
	}
}

// Epoch is the number of connections made so far (changes = the helper may have restarted).
func (h *HelperConn) Epoch() uint64 {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.epoch
}

// Busy reports a request in flight (incl. one past its wait whose answer has not come back).
func (h *HelperConn) Busy() bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.inflight
}

// Idle is the time since the last request was sent.
func (h *HelperConn) Idle() time.Duration {
	h.mu.Lock()
	defer h.mu.Unlock()
	return time.Since(h.lastSend)
}

func (h *HelperConn) reader(c *net.UnixConn) {
	buf := make([]byte, 65536+1)
	for {
		n, err := c.Read(buf)
		if err != nil || n > 65536 {
			h.mu.Lock()
			if h.c == c {
				h.c, h.inflight = nil, false
				if h.w != nil {
					h.w.ch <- result{err: ErrGone}
					h.w = nil
				}
			}
			h.mu.Unlock()
			c.Close()
			return
		}
		x, err := cbor.Decode(buf[:n])
		m, ok := x.(cbor.Map)
		if err != nil || !ok {
			continue
		}
		idv, _ := m.Get(1)
		id, _ := idv.(uint64)
		cv, _ := m.Get(2)
		code, _ := cv.(uint64)
		bv, _ := m.Get(3)
		body, _ := bv.(cbor.Map)
		h.mu.Lock()
		if h.c == c && h.inflight && id == h.flightID {
			h.inflight = false
		}
		if h.w != nil && h.w.id == id {
			h.w.ch <- result{r: Reply{Code: int(code), Body: body}}
			h.w = nil
		}
		h.mu.Unlock()
		// sock.go answers a malformed request with id 0 and closes: the reader sees EOF next
	}
}

// Close drops the connection (the next Call reconnects).
func (h *HelperConn) Close() {
	h.mu.Lock()
	c := h.c
	h.c, h.inflight = nil, false
	if h.w != nil {
		h.w.ch <- result{err: ErrGone}
		h.w = nil
	}
	h.mu.Unlock()
	if c != nil {
		c.Close()
	}
}

// Call sends one request and waits up to wait. ErrBusy at once when a request is in flight on this connection;
// ErrTimeout leaves the request in flight (Busy) until its answer or EOF.
func (h *HelperConn) Call(verb string, args cbor.Map, wait time.Duration) (Reply, error) {
	if args == nil {
		args = cbor.M()
	}
	h.mu.Lock()
	if h.inflight {
		h.mu.Unlock()
		return Reply{}, ErrBusy
	}
	if h.c == nil {
		if err := h.dial(); err != nil {
			h.mu.Unlock()
			return Reply{}, err
		}
	}
	h.id++
	id := h.id
	raw, err := cbor.Encode(cbor.M(1, verb, 2, id, 3, args))
	if err != nil {
		h.mu.Unlock()
		return Reply{}, err
	}
	w := &waiter{id: id, ch: make(chan result, 1)}
	h.w, h.inflight, h.flightID, h.lastSend = w, true, id, time.Now()
	c := h.c
	h.mu.Unlock()
	if _, err := c.Write(raw); err != nil {
		h.mu.Lock()
		if h.c == c {
			h.c, h.inflight, h.w = nil, false, nil
		}
		h.mu.Unlock()
		c.Close()
		return Reply{}, ErrGone
	}
	t := time.NewTimer(wait)
	defer t.Stop()
	select {
	case r := <-w.ch:
		return r.r, r.err
	case <-t.C:
		h.mu.Lock()
		if h.w == w {
			h.w = nil
		}
		h.mu.Unlock()
		return Reply{}, ErrTimeout
	}
}
