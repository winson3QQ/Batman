package node

// Whole-team status (docs/design/254-app-team-status.md v2.1 §10.1, T-N1..T-N11). testdata/*.capture are the real
// outputs of 04 and 02 meshed on N0 (2026-11-13, wsl.25, design §9.2 C1 / C2 / C5), unchanged. testdata/*.derived keep the
// real format line for line (header, spacing, fields) but add rows two nodes cannot produce: a third node, a multi-hop
// best route, a second route without `*`, a station gone quiet (design §9.2 C5').

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"batman-prov/cbor"
	"batman-prov/provstore"
)

const phy04 = "a8:dd:9f:4d:c6:10"

func readFix(t *testing.T, name string) []byte {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", name))
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// peerFS: a fake /sys/class/net/bat0 (meshed = has lower_wlh0) and /sys/class/ieee80211 with the given phys
// (name -> driver, mac).
func peerFS(t *testing.T, isMeshed bool, phys map[string][2]string) (string, string) {
	t.Helper()
	root := t.TempDir()
	bat := filepath.Join(root, "bat0")
	os.MkdirAll(bat, 0o755)
	if isMeshed {
		os.WriteFile(filepath.Join(bat, "lower_wlh0"), nil, 0o644)
	}
	phyDir := filepath.Join(root, "ieee80211")
	for name, dm := range phys {
		d := filepath.Join(phyDir, name, "device")
		os.MkdirAll(d, 0o755)
		if err := os.Symlink("../../../bus/spi/drivers/"+dm[0], filepath.Join(d, "driver")); err != nil {
			t.Fatal(err)
		}
		os.WriteFile(filepath.Join(phyDir, name, "macaddress"), []byte(dm[1]+"\n"), 0o444)
	}
	return bat, phyDir
}

type fakeRun struct {
	mu    sync.Mutex
	bat   []byte
	batE  error
	iw    []byte
	iwE   error
	argvs [][]string
}

func (f *fakeRun) run(argv []string) ([]byte, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.argvs = append(f.argvs, append([]string(nil), argv...))
	if strings.HasSuffix(argv[0], "batctl") {
		return f.bat, f.batE
	}
	return f.iw, f.iwE
}

type peerRig struct {
	*rig
	now  *time.Time
	run  *fakeRun
	logs *bytes.Buffer
	bat  string
}

func newPeerRig(t *testing.T, isMeshed bool, phys map[string][2]string) *peerRig {
	return newPeerRigWith(t, isMeshed, phys, "batctl-originators-multihop.derived", "iw-station-dump-multihop.derived")
}

func newPeerRigWith(t *testing.T, isMeshed bool, phys map[string][2]string, batFix, iwFix string) *peerRig {
	f := &fakeStatus{js: hs04(t), p5: true, inline: true}
	r, now := statusRig(t, f)
	logs := &bytes.Buffer{}
	var lmu sync.Mutex
	r.n.Log = func(format string, a ...any) { lmu.Lock(); fmt.Fprintf(logs, format+"\n", a...); lmu.Unlock() }
	bat, phyDir := peerFS(t, isMeshed, phys)
	fr := &fakeRun{bat: readFix(t, batFix), iw: readFix(t, iwFix)}
	src := DefaultPeerSource()
	src.BatDir, src.PhyDir, src.Run = bat, phyDir, fr.run
	r.n.SetPeerSource(src)
	r.n.peers.runAsync = func(fn func()) { fn() }
	setNet(t, r, provstore.Member, 1) // key 9 is sent only for a node in a network (design §4.1)
	return &peerRig{rig: r, now: now, run: fr, logs: logs, bat: bat}
}

func morse04() map[string][2]string { return map[string][2]string{"phy0": {"morse_spi", phy04}} }

// tick advances the clock and runs one due sample
func (p *peerRig) tick(d time.Duration) {
	*p.now = p.now.Add(d)
	p.n.StatusTick()
}

type peerOut struct {
	addr   string
	ago    uint64
	kbps   *uint64
	signal *int64
}

func macStr(b []byte) string {
	s := make([]string, len(b))
	for i, x := range b {
		s[i] = fmt.Sprintf("%02x", x)
	}
	return strings.Join(s, ":")
}

func peersOf(t *testing.T, m cbor.Map) (k8 string, has8 bool, list []peerOut, has9 bool) {
	t.Helper()
	if v, ok := m.Get(uint64(8)); ok {
		k8, has8 = macStr(v.([]byte)), true
	}
	v, ok := m.Get(uint64(9))
	if !ok {
		return
	}
	has9 = true
	for _, e := range v.([]any) {
		em := e.(cbor.Map)
		a, _ := em.Get(uint64(1))
		ago, _ := em.Get(uint64(2))
		po := peerOut{addr: macStr(a.([]byte)), ago: ago.(uint64)}
		if k, ok := em.Get(uint64(3)); ok {
			x := k.(uint64)
			po.kbps = &x
		}
		if s, ok := em.Get(uint64(4)); ok {
			x := s.(int64)
			po.signal = &x
		}
		list = append(list, po)
	}
	return
}

// T-N1 (+ T-N3): the multi-hop table -> keys 8 / 9 for the owner AND a member; an unreadable header later ->
// key 9 gone once the last good sample is older than 60 s.
func TestPeersFromMultihopTable(t *testing.T) {
	p := newPeerRig(t, true, morse04())
	p.tick(0)
	for i, full := range []bool{true, false} {
		lag := uint64(i) // one second passes between the two reads
		k8, has8, list, has9 := peersOf(t, statusCall(t, p.rig, full))
		if !has8 || k8 != phy04 {
			t.Fatalf("full=%v: key 8 = %q (%v), want the morse phy's MAC", full, k8, has8)
		}
		if !has9 || len(list) != 2 {
			t.Fatalf("full=%v: key 9 = %+v (%v), want 2 peers (ourselves excluded)", full, list, has9)
		}
		d, m := list[0], list[1]
		if d.addr != "a8:dd:9f:4d:c6:d3" || d.ago != lag || d.kbps == nil || *d.kbps != 14900 || d.signal == nil || *d.signal != -62 {
			t.Fatalf("direct peer = %+v", d)
		}
		if m.addr != "a8:dd:9f:4d:c7:60" || m.ago != 2+lag || m.kbps == nil || *m.kbps != 3200 || m.signal != nil {
			t.Fatalf("multi-hop peer (best route via c6:d3; its own station inactive) = %+v", m)
		}
		*p.now = p.now.Add(time.Second) // status: 1/s per connection
	}
	// the header becomes unreadable: samples fail; key 9 stays while the last good one is <= 60 s old, then goes
	p.run.bat = []byte("garbage\nmore garbage\n")
	p.tick(15 * time.Second)
	if _, _, _, has9 := peersOf(t, statusCall(t, p.rig, true)); !has9 {
		t.Fatal("key 9 gone 15 s after the last good sample")
	}
	for i := 0; i < 3; i++ {
		p.tick(15 * time.Second)
	}
	*p.now = p.now.Add(time.Second) // 61 s after the last good sample
	if _, _, _, has9 := peersOf(t, statusCall(t, p.rig, true)); has9 {
		t.Fatal("key 9 still sent 62 s after the last good sample (stale data shown as current)")
	}
	// seen-ago keeps growing for a peer no longer in the table's samples once sampling recovers without it
	p.run.bat = readFix(t, "batctl-originators-multihop.derived")
	p.run.bat = bytes.Join(bytes.Split(p.run.bat, []byte("\n"))[:3], []byte("\n")) // only c6:d3 left
	p.tick(15 * time.Second)
	_, _, list, _ := peersOf(t, statusCall(t, p.rig, true))
	if len(list) != 2 || list[1].addr != "a8:dd:9f:4d:c7:60" || list[1].ago < 76 || list[1].signal != nil {
		t.Fatalf("a peer that left keeps its last-seen: %+v", list)
	}
}

// rows: n originators with last-seen i ms (equal = all 1.000 s)
func origFix(n int, equal bool) []byte {
	var b strings.Builder
	b.WriteString("[B.A.T.M.A.N. adv 2024.3, MainIF/MAC: wlh0/" + phy04 + " (bat0/be:5e:79:bb:31:38 BATMAN_V)]\n")
	b.WriteString("   Originator        last-seen ( throughput)  Nexthop           [outgoingIF]\n")
	for i := 0; i < n; i++ {
		a := fmt.Sprintf("02:00:00:00:00:%02x", i)
		ls := fmt.Sprintf("%d.%03d", i, 0)
		if equal {
			ls = "1.000"
		}
		fmt.Fprintf(&b, " * %s %8ss (%11s)  %s [%10s]\n", a, ls, "1.0", a, "wlh0")
	}
	return []byte(b.String())
}

// T-N2: at most 32; the oldest go first; on equal times the larger addresses go first (deterministic).
func TestPeersEviction(t *testing.T) {
	for _, equal := range []bool{false, true} {
		p := newPeerRig(t, true, morse04())
		p.run.bat = origFix(40, equal)
		p.tick(0)
		_, _, list, _ := peersOf(t, statusCall(t, p.rig, true))
		if len(list) != peerMax || peerMax != 32 {
			t.Fatalf("equal=%v: %d entries kept (peerMax %d), want 32", equal, len(list), peerMax)
		}
		kept := map[string]bool{}
		for _, e := range list {
			kept[e.addr] = true
		}
		for i := 0; i < 40; i++ {
			a := fmt.Sprintf("02:00:00:00:00:%02x", i)
			// unequal: last-seen i s -> the 8 largest i are the oldest; equal: the 8 largest addresses go
			if want := i < 32; kept[a] != want {
				t.Fatalf("equal=%v: %s kept=%v, want %v", equal, a, kept[a], want)
			}
		}
	}
}

// T-N4: 32 longest entries + a large key 15 stay under the 8192 B message limit (provd/frame.go MaxMsg).
func TestPeersAnswerSize(t *testing.T) {
	f := &fakeStatus{js: hs04(t), p5: true, inline: true}
	r, now := statusRig(t, f)
	pk := make([]string, 20)
	for i := range pk {
		pk[i] = strings.Repeat("p", 32)
	}
	r.n.status.src.UciStaged = func() []string { return pk }
	bat, phyDir := peerFS(t, true, morse04())
	var rows strings.Builder
	rows.WriteString("[B.A.T.M.A.N. adv 2024.3, MainIF/MAC: wlh0/" + phy04 + " (bat0/be:5e:79:bb:31:38 BATMAN_V)]\n")
	rows.WriteString("   Originator        last-seen ( throughput)  Nexthop           [outgoingIF]\n")
	var sta strings.Builder
	for i := 0; i < 64; i++ {
		a := fmt.Sprintf("02:00:00:00:%02x:%02x", i/256, i%256)
		fmt.Fprintf(&rows, " * %s 999999999.999s (999999999.9)  %s [%10s]\n", a, a, "wlh0")
		fmt.Fprintf(&sta, "Station %s (on wlh0)\n\tinactive time:\t1 ms\n\tsignal avg:\t-128 dBm\n", a)
	}
	fr := &fakeRun{bat: []byte(rows.String()), iw: []byte(sta.String())}
	src := DefaultPeerSource()
	src.BatDir, src.PhyDir, src.Run = bat, phyDir, fr.run
	setNet(t, r, provstore.Member, 1)
	r.n.SetPeerSource(src)
	r.n.peers.runAsync = func(fn func()) { fn() }
	*now = now.Add(time.Hour * 24 * 365 * 40) // seen-ago as large as it gets
	r.n.StatusTick()
	m := statusCall(t, r, true)
	_, _, list, _ := peersOf(t, m)
	if len(list) != 32 {
		t.Fatalf("%d entries", len(list))
	}
	b, err := cbor.Encode(m)
	if err != nil {
		t.Fatal(err)
	}
	if len(b) > 8192 {
		t.Fatalf("status answer %d B > 8192 B", len(b))
	}
	t.Logf("status answer with 32 maximal peers: %d B", len(b))
}

// T-N6: a rebuilt helper (new table) starts empty: no key 9 until it has sampled.
func TestPeersResetOnHelperRestart(t *testing.T) {
	p := newPeerRig(t, true, morse04())
	p.tick(0)
	if _, _, l, _ := peersOf(t, statusCall(t, p.rig, true)); len(l) != 2 {
		t.Fatal("setup: no peers")
	}
	src := p.n.peers.src
	p.n.SetPeerSource(src) // what a helper restart amounts to: a new process, a new table
	*p.now = p.now.Add(time.Second)
	if _, _, l, has9 := peersOf(t, statusCall(t, p.rig, true)); has9 || len(l) != 0 {
		t.Fatalf("after the restart the table still has %+v", l)
	}
}

// T-N7: (a) the exact argv (untranslated -n, fixed bat0, absolute paths, no shell); (b) a translated table would
// yield a MAC-looking bat-hosts name as an address — which is why -n is mandatory; (c) a bad row is dropped alone.
func TestPeersUntranslatedInput(t *testing.T) {
	src := DefaultPeerSource()
	want := []string{"/usr/sbin/batctl", "meshif", "bat0", "originators", "-n"}
	if strings.Join(src.Batctl, " ") != strings.Join(want, " ") || src.IW != "/usr/sbin/iw" {
		t.Fatalf("argv %q / iw %q", src.Batctl, src.IW)
	}
	p := newPeerRig(t, true, morse04())
	p.tick(0)
	if got := p.run.argvs; len(got) != 2 || strings.Join(got[1], " ") != "/usr/sbin/iw dev wlh0 station dump" {
		t.Fatalf("runs %q", got)
	}
	// (b) the translated capture parses, and its fake address is exactly the danger -n avoids
	tr, err := parseOriginators(readFix(t, "batctl-originators-translated.derived"))
	if err != nil || len(tr.rows) != 1 || macStr(tr.rows[0].addr[:]) != "a8:dd:9f:00:00:01" || tr.dropped != 1 {
		t.Fatalf("translated capture: %+v %v", tr, err)
	}
	un, _ := parseOriginators(readFix(t, "batctl-originators-multihop.derived"))
	for _, r := range un.rows {
		if macStr(r.addr[:]) == "a8:dd:9f:00:00:01" {
			t.Fatal("the untranslated capture yields the bat-hosts name")
		}
	}
	// (c) one bad row among good ones
	b := readFix(t, "batctl-originators-multihop.derived")
	b = append(b, []byte(" * A8:DD:9F:4D:C6:FF    0.100s (        1.0)  A8:DD:9F:4D:C6:FF [      wlh0]\n * not a row\n")...)
	p.run.bat = b
	p.tick(15 * time.Second)
	if _, _, l, has9 := peersOf(t, statusCall(t, p.rig, true)); !has9 || len(l) != 2 {
		t.Fatalf("one bad row cost the sample: %v %+v", has9, l)
	}
}

func stubScript(t *testing.T, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "stub")
	if err := os.WriteFile(p, []byte("#!/bin/sh\n"+body), 0o755); err != nil {
		t.Fatal(err)
	}
	return p
}

func gone(pid int) bool {
	if err := syscall.Kill(pid, 0); err != nil {
		return true
	}
	b, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid))
	if err != nil {
		return true
	}
	f := strings.Fields(string(b))
	return len(f) > 2 && f[2] == "Z"
}

// T-N8: past the deadline the whole process group ends, the child the stub forked included.
func TestPeersExecTimeoutKillsGroup(t *testing.T) {
	if peerExecTimeout != 5*time.Second {
		t.Fatalf("peerExecTimeout %v, design says 5 s", peerExecTimeout)
	}
	pidf := filepath.Join(t.TempDir(), "pids")
	s := stubScript(t, "sleep 30 &\necho $! > "+pidf+"\necho $$ >> "+pidf+"\nsleep 30\n")
	start := time.Now()
	_, err := runCapped(time.Second, peerOutputMax, []string{s})
	if !errors.Is(err, errPeerTimeout) || time.Since(start) > 5*time.Second {
		t.Fatalf("err %v after %v", err, time.Since(start))
	}
	b, _ := os.ReadFile(pidf)
	pids := strings.Fields(string(b))
	if len(pids) != 2 {
		t.Fatalf("stub pids %q", pids)
	}
	deadline := time.Now().Add(3 * time.Second)
	for _, ps := range pids {
		pid, _ := strconv.Atoi(ps)
		for !gone(pid) && time.Now().Before(deadline) {
			time.Sleep(50 * time.Millisecond)
		}
		if !gone(pid) {
			syscall.Kill(pid, syscall.SIGKILL)
			t.Fatalf("pid %s of the group still runs after the timeout", ps)
		}
	}
	if _, err := runCapped(time.Second, 10, []string{"sh", "-c", "true"}); !errors.Is(err, errPeerArgv) {
		t.Fatalf("a relative argv[0] ran: %v", err)
	}
}

// T-N9: more than 64 KiB of output fails the run (and is not kept).
func TestPeersExecOutputCap(t *testing.T) {
	s := stubScript(t, "head -c 1048576 /dev/zero\n")
	b, err := runCapped(5*time.Second, peerOutputMax, []string{s})
	if !errors.Is(err, errPeerTooBig) || b != nil {
		t.Fatalf("1 MiB: %d B, err %v", len(b), err)
	}
	s2 := stubScript(t, "printf ok\n")
	if b, err := runCapped(5*time.Second, peerOutputMax, []string{s2}); err != nil || string(b) != "ok" {
		t.Fatalf("small output: %q %v", b, err)
	}
}

// T-N10: no mesh address reaches the log, whatever the path (good rows, a bad row, a failing header, a timeout).
func TestPeersNoAddressInLog(t *testing.T) {
	const sentinel = "de:ad:be:ef:00:01"
	p := newPeerRig(t, true, morse04())
	good := readFix(t, "batctl-originators-multihop.derived")
	good = append(good, []byte(" * "+sentinel+"    0.100s (        1.0)  "+sentinel+" [      wlh0]\n * "+sentinel+" bad row\n")...)
	p.run.bat = good
	p.tick(0)
	statusCall(t, p.rig, true)
	p.run.bat = []byte("[B.A.T.M.A.N. adv 2024.3, MainIF/MAC: wlh0/" + sentinel + " (bat0/" + sentinel + " BATMAN_V)]\nbroken " + sentinel + "\n")
	p.tick(15 * time.Second)
	// the primary hard-if differs from the phy -> the withheld log line
	p.run.bat = []byte(mustReplace(t, string(good), "MainIF/MAC: wlh0/"+phy04, "MainIF/MAC: wlh0/"+sentinel))
	p.tick(15 * time.Second)
	p.run.batE = errPeerTimeout
	p.tick(15 * time.Second)
	*p.now = p.now.Add(time.Second)
	statusCall(t, p.rig, false)
	log := p.logs.String()
	if log == "" {
		t.Fatal("nothing logged: the scan would prove nothing")
	}
	for _, form := range []string{sentinel, strings.ToUpper(sentinel), "deadbeef0001", "DEADBEEF0001", phy04, "a8:dd:9f:4d:c6:d3"} {
		if strings.Contains(log, form) {
			t.Fatalf("log carries an address (%s):\n%s", form, log)
		}
	}
	t.Logf("log lines scanned:\n%s", log)
}

// T-N11: the self-check — key 8 only when the mesh's primary hard-if is the morse phy (or not meshed); the phy is
// chosen by driver, and two morse phys or none give no key 8.
func TestPeersOwnAddressSelfCheck(t *testing.T) {
	p := newPeerRig(t, true, morse04())
	p.tick(0)
	if k8, has8, _, _ := peersOf(t, statusCall(t, p.rig, true)); !has8 || k8 != phy04 {
		t.Fatalf("same MAC: key 8 %q %v", k8, has8)
	}
	p.run.bat = []byte(mustReplace(t, string(readFix(t, "batctl-originators-multihop.derived")), "wlh0/"+phy04, "wlh0/02:11:22:33:44:55"))
	p.tick(15 * time.Second)
	if _, has8, _, has9 := peersOf(t, statusCall(t, p.rig, true)); has8 || !has9 {
		t.Fatalf("primary hard-if != phy: key 8 sent=%v (want withheld), key 9 %v", has8, has9)
	}
	if n := strings.Count(p.logs.String(), "key 8 withheld"); n != 1 {
		t.Fatalf("withheld logged %d times, want once", n)
	}
	p.tick(15 * time.Second)
	if n := strings.Count(p.logs.String(), "key 8 withheld"); n != 1 || p.n.peers.withheldN != 2 {
		t.Fatalf("second withhold: logged %d, counted %d", n, p.n.peers.withheldN)
	}
	for name, phys := range map[string]map[string][2]string{
		"not morse": {"phy0": {"brcmfmac", phy04}},
		"two morse": {"phy0": {"morse_spi", phy04}, "phy2": {"morse_sdio", "a8:dd:9f:4d:c6:11"}},
		"bad mac":   {"phy0": {"morse_spi", "A8-DD-9F-4D-C6-10"}},
	} {
		q := newPeerRig(t, false, phys)
		q.tick(0)
		if _, has8, _, _ := peersOf(t, statusCall(t, q.rig, true)); has8 {
			t.Fatalf("%s: key 8 sent", name)
		}
	}
	q := newPeerRig(t, false, map[string][2]string{"phy0": {"brcmfmac", "88:a2:9e:b5:6c:89"}, "phy1": {"morse_spi", phy04}})
	q.tick(0)
	if k8, has8, _, _ := peersOf(t, statusCall(t, q.rig, true)); !has8 || k8 != phy04 {
		t.Fatalf("not meshed, morse phy1 chosen by driver: key 8 %q %v", k8, has8)
	}
}

// setNet: the node's record as status.get reads it (key 9 depends on it, design §4.1): state, and for a member the
// network id (16 x id).
func setNet(t *testing.T, r *rig, state string, id byte) {
	t.Helper()
	rec, err := r.n.loadOverlayRO()
	if err != nil || rec == nil {
		t.Fatalf("record: %v", err)
	}
	rec.Generation++
	rec.State, rec.Net = state, nil
	if state == provstore.Member {
		rec.Net = &provstore.Net{Config: []byte{0xa0}, Secrets: []byte{0xa0}, Version: 1, NetID: bytes.Repeat([]byte{id}, 16)}
	}
	if _, _, err := provstore.WriteOverlay(r.n.P, rec); err != nil {
		t.Fatal(err)
	}
}

// T-N5: not in a network -> batctl is not needed and key 9 = []; in a network with batctl failing -> no key 9.
func TestPeersNotMeshedVsFailing(t *testing.T) {
	p := newPeerRig(t, false, morse04())
	setNet(t, p.rig, provstore.Claimed, 0)
	p.tick(0)
	_, has8, list, has9 := peersOf(t, statusCall(t, p.rig, true))
	if !has8 || !has9 || len(list) != 0 || len(p.run.argvs) != 0 {
		t.Fatalf("not in a network: key 8 %v, key 9 %v %+v, runs %v", has8, has9, list, p.run.argvs)
	}
	q := newPeerRig(t, true, morse04())
	q.run.batE = errors.New("exit status 1")
	q.tick(0)
	if _, has8, _, has9 := peersOf(t, statusCall(t, q.rig, true)); has9 || !has8 {
		t.Fatalf("meshed, batctl failing: key 9 %v (want absent), key 8 %v", has9, has8)
	}
}

// T-N5 (code review A-m4), from a table that was NOT empty: another network drops the old network's peers; a wireless
// reload (still in the network, bat0 without a hard interface) sends no key 9 and keeps the table; leaving the network
// gives key 9 = [] and empties it. Negative controls: no clearing on leave / on a network change, or a hard-if-less
// bat0 counted as a good sample -> FAIL.
func TestPeersLeaveReloadAndNetworkChange(t *testing.T) {
	full := readFix(t, "batctl-originators-multihop.derived")
	onlyD3 := bytes.Join(bytes.Split(full, []byte("\n"))[:3], []byte("\n"))
	read := func(p *peerRig) ([]peerOut, bool) {
		*p.now = p.now.Add(time.Second)
		_, _, l, has9 := peersOf(t, statusCall(t, p.rig, true))
		return l, has9
	}
	p := newPeerRig(t, true, morse04())
	p.tick(0)
	if l, _ := read(p); len(l) != 2 {
		t.Fatalf("setup: %+v", l)
	}
	// joined another network (no leave in between): the old network's peers are gone at once
	setNet(t, p.rig, provstore.Member, 2)
	if l, has9 := read(p); !has9 || len(l) != 0 {
		t.Fatalf("another network still shows the old peers: %v %+v", has9, l)
	}
	p.tick(15 * time.Second) // refilled from this network
	// a wireless reload: no key 9 while bat0 has no hard interface; the table is kept
	os.Remove(filepath.Join(p.bat, "lower_wlh0"))
	p.tick(15 * time.Second)
	if l, has9 := read(p); has9 {
		t.Fatalf("key 9 sent during a wireless reload: %+v", l)
	}
	os.WriteFile(filepath.Join(p.bat, "lower_wlh0"), nil, 0o644)
	p.run.bat = onlyD3
	p.tick(15 * time.Second)
	if l, has9 := read(p); !has9 || len(l) != 2 {
		t.Fatalf("after the reload the table was not kept (c7:60 must still be listed): %v %+v", has9, l)
	}
	// left the network: key 9 = [] and the table emptied (a later join starts from nothing)
	setNet(t, p.rig, provstore.Claimed, 0)
	os.Remove(filepath.Join(p.bat, "lower_wlh0"))
	p.tick(15 * time.Second)
	if l, has9 := read(p); !has9 || len(l) != 0 {
		t.Fatalf("not in a network: key 9 %v %+v, want []", has9, l)
	}
	if len(p.n.peers.m) != 0 {
		t.Fatalf("the table still holds %d peers after leaving", len(p.n.peers.m))
	}
}

// Code review B-m1: key 4 is reset every sample — a peer that was a direct station and is now relayed loses its
// signal. Negative control: the per-sample reset removed -> FAIL.
func TestPeersSignalOnlyFromThisSample(t *testing.T) {
	p := newPeerRig(t, true, morse04())
	p.tick(0)
	if _, _, l, _ := peersOf(t, statusCall(t, p.rig, true)); l[0].signal == nil {
		t.Fatal("setup: the direct peer has no signal")
	}
	// c6:d3 now reached through c7:60 (not direct): its station entry is still in the dump
	p.run.bat = []byte(mustReplace(t, string(readFix(t, "batctl-originators-multihop.derived")),
		" * a8:dd:9f:4d:c6:d3    0.420s (       14.9) a8:dd:9f:4d:c6:d3", " * a8:dd:9f:4d:c6:d3    0.420s (       14.9) a8:dd:9f:4d:c7:60"))
	p.tick(15 * time.Second)
	_, _, l, _ := peersOf(t, statusCall(t, p.rig, true))
	for _, e := range l {
		if e.addr == "a8:dd:9f:4d:c6:d3" && e.signal != nil {
			t.Fatalf("a relayed peer kept the last sample's signal: %+v", e)
		}
	}
}

// Code review B-m2: our own originator (the MainIF MAC, and the phy MAC) never appears in key 9. Negative control:
// the self skip removed -> FAIL.
func TestPeersNeverListsItself(t *testing.T) {
	p := newPeerRig(t, true, morse04())
	b := readFix(t, "batctl-originators-multihop.derived")
	b = append(b, []byte(" * "+phy04+"    0.010s (       99.9)  "+phy04+" [      wlh0]\n")...)
	p.run.bat = b
	p.tick(0)
	_, _, l, _ := peersOf(t, statusCall(t, p.rig, true))
	for _, e := range l {
		if e.addr == phy04 {
			t.Fatalf("key 9 lists this node itself: %+v", l)
		}
	}
	if len(l) != 2 {
		t.Fatalf("%+v", l)
	}
}

// Code review B-m3: the child gets only PATH and LANG — nothing of the helper's environment. Negative control: the
// clean environment removed -> FAIL.
func TestPeersExecCleanEnvironment(t *testing.T) {
	t.Setenv("BATMAN_SENTINEL_ENV", "leaked")
	s := stubScript(t, "env\n")
	b, err := runCapped(5*time.Second, peerOutputMax, []string{s})
	if err != nil {
		t.Fatal(err)
	}
	env := string(b)
	if strings.Contains(env, "BATMAN_SENTINEL_ENV") || !strings.Contains(env, "PATH=/usr/sbin:/usr/bin:/sbin:/bin") || !strings.Contains(env, "LANG=C") {
		t.Fatalf("child environment:\n%s", env)
	}
}

// Code review B-m5: an interface name starting with '-' (it would become an iw option) fails the header. Negative
// control: the loose interface pattern back -> FAIL.
func TestPeersInterfaceNameIsNoOption(t *testing.T) {
	b := []byte(mustReplace(t, string(readFix(t, "batctl-originators-multihop.derived")), "MainIF/MAC: wlh0/", "MainIF/MAC: -h/"))
	if _, err := parseOriginators(b); err == nil {
		t.Fatal("a MainIF of '-h' was accepted (it would reach iw's argv)")
	}
}

// T-N1 on the real captures (design §9.2 C1 / C2 / C5, 2026-11-13, 04 and 02 meshed on N0, wsl.25): each node's key 8
// is its own morse phy's MAC (02's is phy2, its brcmfmac is phy1: chosen by driver, not by name) and key 9 holds exactly
// the other node, at the address the other node reports as its own (C2), with BATMAN_V's 14.9 Mbit/s as 14900 kbit/s
// and the station's signal avg.
func TestPeersFromRealCaptures(t *testing.T) {
	for _, c := range []struct {
		node, self, peer string
		phys             map[string][2]string
		ago              uint64
	}{
		{"04", phy04, "a8:dd:9f:4d:c7:60", map[string][2]string{"phy0": {"morse_spi", phy04}, "phy1": {"brcmfmac", "88:a2:9e:b5:6c:8a"}}, 0},
		{"02", "a8:dd:9f:4d:c7:60", phy04, map[string][2]string{"phy1": {"brcmfmac", "d8:3a:dd:f8:45:d8"}, "phy2": {"morse_spi", "a8:dd:9f:4d:c7:60"}}, 2},
	} {
		p := newPeerRigWith(t, true, c.phys, "batctl-originators-"+c.node+".capture", "iw-station-dump-"+c.node+".capture")
		p.tick(0)
		k8, has8, list, has9 := peersOf(t, statusCall(t, p.rig, true))
		if !has8 || k8 != c.self {
			t.Fatalf("%s: key 8 = %q (%v), want its morse phy %s", c.node, k8, has8, c.self)
		}
		if !has9 || len(list) != 1 {
			t.Fatalf("%s: key 9 = %+v (%v), want exactly the other node", c.node, list, has9)
		}
		e := list[0]
		if e.addr != c.peer || e.ago != c.ago || e.kbps == nil || *e.kbps != 14900 || e.signal == nil || *e.signal != -29 {
			t.Fatalf("%s: peer = %+v (kbps %v signal %v), want %s ago %d 14900 kbit/s -29 dBm", c.node, e, e.kbps, e.signal, c.peer, c.ago)
		}
	}
	// the real translated capture (bat-hosts names) gives no peer: the name row is dropped, nothing invented
	tr, err := parseOriginators(readFix(t, "batctl-originators-04-translated.capture"))
	if err != nil || len(tr.rows) != 0 || tr.dropped != 1 {
		t.Fatalf("translated capture: %+v %v", tr, err)
	}
}

// mustReplace: strings.Replace once, and FAIL when the text is not there — a fixture format change (2026-11-13: the real
// capture has one space before Nexthop, the provisional file had two) must not turn an edit into a silent no-op.
func mustReplace(t *testing.T, s, old, new string) string {
	t.Helper()
	if !strings.Contains(s, old) {
		t.Fatalf("fixture edit: %q is not in the fixture", old)
	}
	return strings.Replace(s, old, new, 1)
}

// design §9.2 C5' (code review A-m5 / A-m6): rows two nodes cannot produce, written in the real capture's format.
// (a) best route only: the route without `*` listed first must not win. Negative control: the `continue` on a
// non-best row removed -> 0.8 Mbit/s is taken -> FAIL.
func TestPeersBestRouteOnlyEvenWhenListedSecond(t *testing.T) {
	p := newPeerRig(t, true, morse04())
	p.run.bat = []byte(mustReplace(t, string(readFix(t, "batctl-originators-multihop.derived")),
		" * a8:dd:9f:4d:c7:60    2.130s (        3.2) a8:dd:9f:4d:c6:d3 [      wlh0]\n   a8:dd:9f:4d:c7:60    2.130s (        0.8) a8:dd:9f:4d:c7:60 [      wlh0]\n",
		"   a8:dd:9f:4d:c7:60    2.130s (        0.8) a8:dd:9f:4d:c7:60 [      wlh0]\n * a8:dd:9f:4d:c7:60    2.130s (        3.2) a8:dd:9f:4d:c6:d3 [      wlh0]\n"))
	p.tick(0)
	_, _, l, _ := peersOf(t, statusCall(t, p.rig, true))
	for _, e := range l {
		if e.addr == "a8:dd:9f:4d:c7:60" && (e.kbps == nil || *e.kbps != 3200 || e.signal != nil) {
			t.Fatalf("c7:60 = %+v: want the best route (3200 kbit/s, relayed, no signal)", e)
		}
	}
}

// (b) our own originator in the table (MainIF MAC = our morse phy) is never a peer. Negative control: the self check
// removed -> our own MAC in key 9 -> FAIL.
func TestPeersOwnRowExcluded(t *testing.T) {
	p := newPeerRig(t, true, morse04())
	p.run.bat = append(readFix(t, "batctl-originators-multihop.derived"),
		[]byte(" * "+phy04+"    0.010s (       14.9) "+phy04+" [      wlh0]\n")...)
	p.tick(0)
	_, _, l, has9 := peersOf(t, statusCall(t, p.rig, true))
	if !has9 || len(l) != 2 {
		t.Fatalf("key 9 = %+v (%v), want the 2 other nodes only", l, has9)
	}
	for _, e := range l {
		if e.addr == phy04 {
			t.Fatalf("ourselves in key 9: %+v", l)
		}
	}
}

// (c) key 4 only for a direct station heard within one sampling period: inactive 15000 ms keeps the signal, 15001 ms
// does not. Negative control: the inactive threshold removed -> 15001 ms keeps it -> FAIL.
func TestPeersSignalInactiveThreshold(t *testing.T) {
	for _, c := range []struct {
		ms   string
		want bool
	}{{"15000", true}, {"15001", false}} {
		p := newPeerRig(t, true, morse04())
		p.run.iw = []byte(mustReplace(t, string(readFix(t, "iw-station-dump-multihop.derived")), "inactive time:\t120 ms", "inactive time:\t"+c.ms+" ms"))
		p.tick(0)
		_, _, l, _ := peersOf(t, statusCall(t, p.rig, true))
		for _, e := range l {
			if e.addr == "a8:dd:9f:4d:c6:d3" && (e.signal != nil) != c.want {
				t.Fatalf("inactive %s ms: signal present=%v, want %v", c.ms, e.signal != nil, c.want)
			}
		}
	}
}
