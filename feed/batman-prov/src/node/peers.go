package node

// Whole-team status (docs/design/254-app-team-status.md v2.1 §4.1): the helper samples the batman originator table and
// the mesh iface's station dump every 15 s in the background — always, not only while an app asked — into a table kept
// in this process's memory (it resets with the helper / the node: owner decision U2, design T3). status.get adds
//   key 8: this node's own mesh address = the permanent MAC of the HaLow phy (selected by its driver, morse_*);
//   key 9: [{1 addr, 2 seen-ago s, ?3 throughput kbit/s, ?4 signal dBm}], at most 32, only while the last successful
//          sample is <= 60 s old.
// Rules (§4.1, §7): only untranslated output (batctl -n: never bat-hosts names), a fixed meshif, absolute paths, no
// shell, a 5 s deadline that ends the whole process group, 64 KiB of output at most; a bad row is dropped, an unreadable
// header fails the sample. No mesh address is ever written to the log (counts only).
//
// ⚠️ PROVISIONAL: the batctl / iw formats parsed here are taken from batctl's printf formats and an older capture
// (docs/data/soak-12h-final-state.txt:57-59, batman-adv 2025.4); testdata/*.provisional stand in until the 04 + 02 mesh
// capture (design §9) replaces them.

import (
	"bytes"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"batman-prov/cbor"
)

const (
	peerEvery     = 15 * time.Second
	peerFreshFor  = 60 * time.Second
	peerMax       = 32
	peerOutputMax = 64 << 10
	// a direct station counts as active (key 4) when it was heard within one sampling period (⚠️ C5)
	peerActiveMs = 15000
)

// peerExecTimeout: the deadline of one batctl / iw run (design §4.1: 5 s); a var only so a test can shorten it
var peerExecTimeout = 5 * time.Second

// PeerSource is where the samples come from; the daemon wires the real paths (DefaultPeerSource), tests inject.
type PeerSource struct {
	BatDir string   // /sys/class/net/bat0: absent or without lower_* = not in a mesh (no batctl run)
	PhyDir string   // /sys/class/ieee80211
	Batctl []string // the originators command, argv (absolute path first)
	IW     string   // absolute path of iw
	// Run executes argv without a shell (runCapped in the daemon)
	Run func(argv []string) ([]byte, error)
}

// DefaultPeerSource: the paths on the node (⚠️ C1a: /usr/sbin/batctl and /usr/sbin/iw to be confirmed on 04).
func DefaultPeerSource() PeerSource {
	return PeerSource{BatDir: "/sys/class/net/bat0", PhyDir: "/sys/class/ieee80211",
		Batctl: []string{"/usr/sbin/batctl", "meshif", "bat0", "originators", "-n"}, IW: "/usr/sbin/iw",
		Run: func(argv []string) ([]byte, error) { return runCapped(peerExecTimeout, peerOutputMax, argv) }}
}

var (
	errPeerTimeout = errors.New("timed out")
	errPeerTooBig  = errors.New("output over the limit")
	errPeerArgv    = errors.New("not an absolute path")
)

// runCapped runs argv (no shell) in its own process group with a clean environment; past the deadline or past max
// bytes of stdout the whole group is stopped (TERM, then KILL after 1 s) and the run fails. stderr is discarded. The
// error never carries the output.
func runCapped(timeout time.Duration, max int, argv []string) ([]byte, error) {
	if len(argv) == 0 || !filepath.IsAbs(argv[0]) {
		return nil, errPeerArgv
	}
	c := exec.Command(argv[0], argv[1:]...)
	c.Env = []string{"PATH=/usr/sbin:/usr/bin:/sbin:/bin", "LANG=C"}
	c.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	out, err := c.StdoutPipe()
	if err != nil {
		return nil, err
	}
	if err := c.Start(); err != nil {
		return nil, err
	}
	pgid := c.Process.Pid
	waited := make(chan error, 1)
	var once sync.Once
	reap := func() { once.Do(func() { go func() { waited <- c.Wait() }() }) } // one Wait, whoever needs it first
	stop := func() {
		syscall.Kill(-pgid, syscall.SIGTERM)
		reap()
		select {
		case <-waited:
		case <-time.After(time.Second):
			syscall.Kill(-pgid, syscall.SIGKILL)
			select {
			case <-waited:
			case <-time.After(2 * time.Second): // unkillable: abandoned (its Wait goroutine stays)
			}
		}
		syscall.Kill(-pgid, syscall.SIGKILL) // anything of the group the parent's exit left behind
	}
	type res struct {
		b   []byte
		err error
	}
	got := make(chan res, 1)
	go func() {
		b, err := io.ReadAll(io.LimitReader(out, int64(max)+1))
		got <- res{b, err}
	}()
	t := time.NewTimer(timeout)
	defer t.Stop()
	var r res
	select {
	case r = <-got:
	case <-t.C:
		stop()
		return nil, errPeerTimeout
	}
	if len(r.b) > max {
		stop()
		return nil, errPeerTooBig
	}
	reap()
	select {
	case err := <-waited:
		if err != nil {
			return nil, errors.New("exit status " + exitCode(err))
		}
		return r.b, nil
	case <-t.C:
		stop()
		return nil, errPeerTimeout
	}
}

func exitCode(err error) string {
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		return strconv.Itoa(ee.ExitCode())
	}
	return "unknown"
}

// ---- parsers (⚠️ provisional formats, design §9 C1 / C5)

const macRE = `[0-9a-f]{2}(?::[0-9a-f]{2}){5}`

var (
	// [B.A.T.M.A.N. adv 2024.3, MainIF/MAC: wlh0/a8:dd:9f:4d:c6:10 (bat0/be:5e:79:bb:31:38 BATMAN_V)]
	origHeaderRE = regexp.MustCompile(`^\[B\.A\.T\.M\.A\.N\. adv [^,\]]{1,32}, MainIF/MAC: ([A-Za-z0-9_.-]{1,15})/(` + macRE +
		`) \([A-Za-z0-9_.-]{1,15}/` + macRE + ` BATMAN_V\)\]$`)
	//    Originator        last-seen ( throughput)  Nexthop           [outgoingIF]
	origColsRE = regexp.MustCompile(`^\s*Originator\s+last-seen\s+\(\s*throughput\)\s+Nexthop\s+\[\s*outgoingIF\]\s*$`)
	//  * a8:dd:9f:4d:c6:d3    0.420s (       14.9)  a8:dd:9f:4d:c6:d3 [      wlh0]
	origRowRE = regexp.MustCompile(`^\s*(\*?)\s*(` + macRE + `)\s+(\d{1,9})\.(\d{3})s\s+\(\s*(\d{1,9})\.(\d)\)\s+(` +
		macRE + `)\s+\[\s*([A-Za-z0-9_.-]{1,15})\]\s*$`)
	staRE      = regexp.MustCompile(`^Station (` + macRE + `) \(on [A-Za-z0-9_.-]{1,15}\)$`)
	inactiveRE = regexp.MustCompile(`^\s+inactive time:\s+(\d{1,9}) ms$`)
	signalRE   = regexp.MustCompile(`^\s+signal avg:\s+(-?\d{1,3})(?: \[[-0-9, ]*\])? dBm$`)
)

type origRow struct {
	addr     [6]byte
	lastSeen time.Duration
	kbps     uint64
	direct   bool
}

type origTable struct {
	mainIf  string
	mainMAC [6]byte
	rows    []origRow // best routes only
	dropped int
}

func mac6(s string) [6]byte {
	var m [6]byte
	for i := 0; i < 6; i++ {
		v, _ := strconv.ParseUint(s[i*3:i*3+2], 16, 8)
		m[i] = byte(v)
	}
	return m
}

// parseOriginators: `batctl meshif bat0 originators -n` (BATMAN_V). The header and the column line must be read;
// a row that does not match is dropped (counted), the others stay; only the best route ("*") of each originator is
// kept.
func parseOriginators(b []byte) (origTable, error) {
	var t origTable
	lines := strings.Split(strings.TrimRight(string(b), "\n"), "\n")
	if len(lines) < 2 {
		return t, errors.New("no header")
	}
	h := origHeaderRE.FindStringSubmatch(strings.TrimSpace(lines[0]))
	if h == nil || !origColsRE.MatchString(lines[1]) {
		return t, errors.New("header not understood")
	}
	t.mainIf, t.mainMAC = h[1], mac6(h[2])
	seen := map[[6]byte]bool{}
	for _, l := range lines[2:] {
		if strings.TrimSpace(l) == "" {
			continue
		}
		m := origRowRE.FindStringSubmatch(l)
		if m == nil {
			t.dropped++
			continue
		}
		if m[1] != "*" {
			continue // not the best route
		}
		a := mac6(m[2])
		if seen[a] {
			t.dropped++ // two best routes for one originator: keep the first
			continue
		}
		seen[a] = true
		sec, _ := strconv.ParseUint(m[3], 10, 32)
		ms, _ := strconv.ParseUint(m[4], 10, 16)
		mb, _ := strconv.ParseUint(m[5], 10, 32)
		tenth, _ := strconv.ParseUint(m[6], 10, 8)
		t.rows = append(t.rows, origRow{addr: a, lastSeen: time.Duration(sec)*time.Second + time.Duration(ms)*time.Millisecond,
			kbps: mb*1000 + tenth*100, direct: m[7] == m[2]})
	}
	return t, nil
}

type station struct {
	inactiveMs uint64
	signal     int64
	hasSignal  bool
	hasInact   bool
}

// parseStations: `iw dev <if> station dump`; a block whose Station line does not match is skipped (counted).
func parseStations(b []byte) (map[[6]byte]station, int) {
	out := map[[6]byte]station{}
	dropped := 0
	var cur *station
	var curA [6]byte
	flush := func() {
		if cur != nil {
			out[curA] = *cur
		}
		cur = nil
	}
	for _, l := range strings.Split(string(b), "\n") {
		if strings.HasPrefix(l, "Station ") {
			flush()
			m := staRE.FindStringSubmatch(l)
			if m == nil {
				dropped++
				continue
			}
			curA, cur = mac6(m[1]), &station{}
			continue
		}
		if cur == nil {
			continue
		}
		if m := inactiveRE.FindStringSubmatch(l); m != nil {
			cur.inactiveMs, _ = strconv.ParseUint(m[1], 10, 32)
			cur.hasInact = true
		} else if m := signalRE.FindStringSubmatch(l); m != nil {
			cur.signal, _ = strconv.ParseInt(m[1], 10, 16)
			cur.hasSignal = true
		}
	}
	flush()
	return out, dropped
}

// morsePhyMAC: the permanent MAC of the one phy whose driver is morse_*; none or several -> false.
func morsePhyMAC(dir string) ([6]byte, bool) {
	ents, err := os.ReadDir(dir)
	if err != nil {
		return [6]byte{}, false
	}
	var found []string
	for _, e := range ents {
		d, err := os.Readlink(filepath.Join(dir, e.Name(), "device", "driver"))
		if err == nil && strings.HasPrefix(filepath.Base(d), "morse_") {
			found = append(found, e.Name())
		}
	}
	if len(found) != 1 {
		return [6]byte{}, false
	}
	b, err := os.ReadFile(filepath.Join(dir, found[0], "macaddress"))
	if err != nil {
		return [6]byte{}, false
	}
	s := strings.TrimSpace(string(b))
	if !regexp.MustCompile(`^` + macRE + `$`).MatchString(s) {
		return [6]byte{}, false
	}
	return mac6(s), true
}

// meshed: bat0 exists and has at least one lower (hard) interface (⚠️ C7).
func meshed(batDir string) bool {
	ents, err := os.ReadDir(batDir)
	if err != nil {
		return false
	}
	for _, e := range ents {
		if strings.HasPrefix(e.Name(), "lower_") {
			return true
		}
	}
	return false
}

// ---- the table

type peerEntry struct {
	seen      time.Time
	kbps      uint64
	hasKbps   bool
	signal    int64
	hasSignal bool
}

type peerTable struct {
	mu        sync.Mutex
	src       PeerSource
	m         map[[6]byte]*peerEntry
	okAt      time.Time
	lastStart time.Time
	busy      bool
	phy       [6]byte
	phyOK     bool
	withhold  bool // the primary hard-if's MAC is not the HaLow phy's (design A2-m1)
	withheldN int
	failN     int
	droppedN  int
	logf      func(string, ...any)
	now       func() time.Time
	runAsync  func(func())
}

func newPeerTable(src PeerSource, now func() time.Time, logf func(string, ...any)) *peerTable {
	if logf == nil {
		logf = func(string, ...any) {}
	}
	return &peerTable{src: src, m: map[[6]byte]*peerEntry{}, now: now, logf: logf, runAsync: func(f func()) { go f() }}
}

// Tick starts a sample when one is due (every 15 s, single-flight).
func (p *peerTable) Tick() {
	p.mu.Lock()
	now := p.now()
	due := !p.busy && (p.lastStart.IsZero() || now.Sub(p.lastStart) >= peerEvery)
	if due {
		p.busy, p.lastStart = true, now
	}
	p.mu.Unlock()
	if due {
		p.runAsync(p.sample)
	}
}

type peerSample struct {
	ok      bool
	meshed  bool
	tab     origTable
	sta     map[[6]byte]station
	dropped int
	why     string
}

func (p *peerTable) take() peerSample {
	s := peerSample{meshed: meshed(p.src.BatDir)}
	if !s.meshed {
		s.ok = true // not in a mesh: nobody seen, and that is known (design §4.1 key 9)
		return s
	}
	out, err := p.src.Run(p.src.Batctl)
	if err != nil {
		s.why = "batctl: " + err.Error()
		return s
	}
	t, err := parseOriginators(out)
	if err != nil {
		s.why = "batctl: " + err.Error()
		return s
	}
	s.ok, s.tab, s.dropped = true, t, t.dropped
	if b, err := p.src.Run([]string{p.src.IW, "dev", t.mainIf, "station", "dump"}); err == nil {
		var d int
		s.sta, d = parseStations(b)
		s.dropped += d
	} // iw failing costs only the signal (key 4)
	return s
}

func (p *peerTable) sample() {
	phy, phyOK := morsePhyMAC(p.src.PhyDir)
	s := p.take()
	p.mu.Lock()
	defer p.mu.Unlock()
	p.busy = false
	now := p.now()
	p.phy, p.phyOK = phy, phyOK
	if !s.ok {
		p.failN++
		if p.failN == 1 {
			p.logf("peers: sample failed (%s); key 9 is withheld once the last good sample is 60 s old", s.why)
		}
		return
	}
	if p.failN > 0 {
		p.logf("peers: sampling recovered after %d failed samples", p.failN)
		p.failN = 0
	}
	if s.dropped > 0 {
		p.droppedN += s.dropped
		if p.droppedN == s.dropped { // first time only; the count stays in droppedN
			p.logf("peers: dropped %d unreadable rows", s.dropped)
		}
	}
	p.okAt = now
	withhold := s.meshed && phyOK && s.tab.mainMAC != phy
	if withhold {
		p.withheldN++
		if !p.withhold {
			p.logf("peers: key 8 withheld: the mesh's primary interface is not the HaLow phy (%d times)", p.withheldN)
		}
	}
	p.withhold = withhold
	for _, e := range p.m {
		e.hasSignal = false // key 4 only for a station active in this sample
	}
	for _, r := range s.tab.rows {
		if r.addr == s.tab.mainMAC || (phyOK && r.addr == phy) {
			continue // ourselves
		}
		seen := now.Add(-r.lastSeen)
		e := p.m[r.addr]
		if e == nil {
			e = &peerEntry{seen: seen}
			p.m[r.addr] = e
		}
		if seen.After(e.seen) {
			e.seen = seen
		}
		e.kbps, e.hasKbps = r.kbps, true
		if st, ok := s.sta[r.addr]; ok && r.direct && st.hasSignal && st.hasInact && st.inactiveMs <= peerActiveMs {
			e.signal, e.hasSignal = st.signal, true
		}
	}
	p.evict()
}

// evict keeps the peerMax most recently seen; on equal times the larger address goes first (design B-m2).
func (p *peerTable) evict() {
	if len(p.m) <= peerMax {
		return
	}
	keys := make([][6]byte, 0, len(p.m))
	for k := range p.m {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool {
		a, b := p.m[keys[i]], p.m[keys[j]]
		if !a.seen.Equal(b.seen) {
			return a.seen.Before(b.seen)
		}
		return bytes.Compare(keys[i][:], keys[j][:]) > 0
	})
	for _, k := range keys[:len(keys)-peerMax] {
		delete(p.m, k)
	}
}

// keys returns status keys 8 and 9 (either may be absent).
func (p *peerTable) keys(now time.Time) cbor.Map {
	p.mu.Lock()
	defer p.mu.Unlock()
	var out cbor.Map
	if p.phyOK && !p.withhold {
		out = append(out, cbor.Entry{K: uint64(8), V: append([]byte(nil), p.phy[:]...)})
	}
	if p.okAt.IsZero() || now.Sub(p.okAt) > peerFreshFor {
		return out
	}
	type kv struct {
		a [6]byte
		e *peerEntry
	}
	all := make([]kv, 0, len(p.m))
	for a, e := range p.m {
		all = append(all, kv{a, e})
	}
	sort.Slice(all, func(i, j int) bool {
		if !all[i].e.seen.Equal(all[j].e.seen) {
			return all[i].e.seen.After(all[j].e.seen)
		}
		return bytes.Compare(all[i].a[:], all[j].a[:]) < 0
	})
	list := make([]any, 0, len(all))
	for _, x := range all {
		ago := now.Sub(x.e.seen)
		if ago < 0 {
			ago = 0
		}
		m := cbor.M(1, append([]byte(nil), x.a[:]...), 2, uint64(ago/time.Second))
		if x.e.hasKbps {
			m = append(m, cbor.Entry{K: uint64(3), V: x.e.kbps})
		}
		if x.e.hasSignal {
			m = append(m, cbor.Entry{K: uint64(4), V: x.e.signal})
		}
		list = append(list, m)
	}
	return append(out, cbor.Entry{K: uint64(9), V: list})
}

// SetPeerSource starts the whole-team sampling (ticked by StatusTick).
func (n *Node) SetPeerSource(src PeerSource) {
	n.peers = newPeerTable(src, n.now, n.Log)
}
