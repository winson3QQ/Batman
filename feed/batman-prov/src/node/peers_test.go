package node

// Whole-team status (docs/design/254-app-team-status.md v2.1 §10.1, T-N1..T-N11). The batctl / iw outputs are
// testdata/*.provisional: written from batctl's printf formats and the older capture, to be REPLACED by the 04 + 02
// mesh capture (design §9) before the hardware test.

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
}

func newPeerRig(t *testing.T, isMeshed bool, phys map[string][2]string) *peerRig {
	f := &fakeStatus{js: hs04(t), p5: true, inline: true}
	r, now := statusRig(t, f)
	logs := &bytes.Buffer{}
	var lmu sync.Mutex
	r.n.Log = func(format string, a ...any) { lmu.Lock(); fmt.Fprintf(logs, format+"\n", a...); lmu.Unlock() }
	bat, phyDir := peerFS(t, isMeshed, phys)
	fr := &fakeRun{bat: readFix(t, "batctl-originators-meshed.provisional"), iw: readFix(t, "iw-station-dump-meshed.provisional")}
	src := DefaultPeerSource()
	src.BatDir, src.PhyDir, src.Run = bat, phyDir, fr.run
	r.n.SetPeerSource(src)
	r.n.peers.runAsync = func(fn func()) { fn() }
	return &peerRig{rig: r, now: now, run: fr, logs: logs}
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

// T-N1 (+ T-N3): the provisional capture -> keys 8 / 9 for the owner AND a member; an unreadable header later ->
// key 9 gone once the last good sample is older than 60 s.
func TestPeersFromProvisionalCapture(t *testing.T) {
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
	p.run.bat = readFix(t, "batctl-originators-meshed.provisional")
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

// T-N5: not in a mesh -> batctl is not run and key 9 = []; in a mesh with batctl failing -> no key 9.
func TestPeersNotMeshedVsFailing(t *testing.T) {
	p := newPeerRig(t, false, morse04())
	p.tick(0)
	_, has8, list, has9 := peersOf(t, statusCall(t, p.rig, true))
	if !has8 || !has9 || len(list) != 0 || len(p.run.argvs) != 0 {
		t.Fatalf("not meshed: key 8 %v, key 9 %v %+v, runs %v", has8, has9, list, p.run.argvs)
	}
	q := newPeerRig(t, true, morse04())
	q.run.batE = errors.New("exit status 1")
	q.tick(0)
	if _, has8, _, has9 := peersOf(t, statusCall(t, q.rig, true)); has9 || !has8 {
		t.Fatalf("meshed, batctl failing: key 9 %v (want absent), key 8 %v", has9, has8)
	}
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
	tr, err := parseOriginators(readFix(t, "batctl-originators-translated.provisional"))
	if err != nil || len(tr.rows) != 1 || macStr(tr.rows[0].addr[:]) != "a8:dd:9f:00:00:01" || tr.dropped != 1 {
		t.Fatalf("translated capture: %+v %v", tr, err)
	}
	un, _ := parseOriginators(readFix(t, "batctl-originators-meshed.provisional"))
	for _, r := range un.rows {
		if macStr(r.addr[:]) == "a8:dd:9f:00:00:01" {
			t.Fatal("the untranslated capture yields the bat-hosts name")
		}
	}
	// (c) one bad row among good ones
	b := readFix(t, "batctl-originators-meshed.provisional")
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
	good := readFix(t, "batctl-originators-meshed.provisional")
	good = append(good, []byte(" * "+sentinel+"    0.100s (        1.0)  "+sentinel+" [      wlh0]\n * "+sentinel+" bad row\n")...)
	p.run.bat = good
	p.tick(0)
	statusCall(t, p.rig, true)
	p.run.bat = []byte("[B.A.T.M.A.N. adv 2024.3, MainIF/MAC: wlh0/" + sentinel + " (bat0/" + sentinel + " BATMAN_V)]\nbroken " + sentinel + "\n")
	p.tick(15 * time.Second)
	// the primary hard-if differs from the phy -> the withheld log line
	p.run.bat = []byte(strings.Replace(string(good), "MainIF/MAC: wlh0/"+phy04, "MainIF/MAC: wlh0/"+sentinel, 1))
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
	p.run.bat = []byte(strings.Replace(string(readFix(t, "batctl-originators-meshed.provisional")), "wlh0/"+phy04, "wlh0/02:11:22:33:44:55", 1))
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
