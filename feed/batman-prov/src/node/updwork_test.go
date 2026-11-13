package node

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"math/big"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"batman-prov/cbor"
	"batman-prov/proto"
	"batman-prov/release"
)

// ---- a Go test signer (keys derived like the harness's netobj._vector_key) ----------------------------------

func vKey(name string) *ecdsa.PrivateKey {
	c := elliptic.P256()
	h := sha256.Sum256([]byte("batman-test-vector/" + name))
	n1 := new(big.Int).Sub(c.Params().N, big.NewInt(1))
	d := new(big.Int).Mod(new(big.Int).SetBytes(h[:]), n1)
	d.Add(d, big.NewInt(1))
	k := &ecdsa.PrivateKey{D: d}
	k.PublicKey.Curve = c
	k.PublicKey.X, k.PublicKey.Y = c.ScalarBaseMult(d.Bytes())
	return k
}

func vPub(k *ecdsa.PrivateKey) []byte {
	return elliptic.Marshal(elliptic.P256(), k.PublicKey.X, k.PublicKey.Y) //nolint:staticcheck // test only
}

func vSign1(t *testing.T, k *ecdsa.PrivateKey, payload cbor.Map, ct, label string) []byte {
	t.Helper()
	prot, _ := cbor.Encode(cbor.M(1, int64(-7), 3, ct))
	pl, _ := cbor.Encode(payload)
	ss, _ := cbor.Encode([]any{"Signature1", prot, []byte(label), pl})
	h := sha256.Sum256(ss)
	r, s, err := ecdsa.Sign(rand.Reader, k, h[:])
	if err != nil {
		t.Fatal(err)
	}
	if half := new(big.Int).Rsh(elliptic.P256().Params().N, 1); s.Cmp(half) > 0 {
		s.Sub(elliptic.P256().Params().N, s)
	}
	sig := make([]byte, 64)
	r.FillBytes(sig[:32])
	s.FillBytes(sig[32:])
	b, _ := cbor.Encode(cbor.Tag{Num: 18, V: []any{prot, cbor.M(), pl, sig}})
	return b
}

// ---- a payload builder ----------------------------------------------------------------------------------

type member struct {
	name string
	data []byte
	typ  byte
}

type payload struct {
	members  []member // in tar order (after SHA256SUMS and metadata)
	sums     []byte   // nil: computed from members
	meta     []byte   // nil: computed
	extra    []member // appended after root.squashfs
	trailing []byte   // bytes after the gzip stream
	inGzTail []byte   // bytes inside the gzip stream, after the tar's end (a decompression bomb when large)
	first    string   // "" normal; "metadata" swaps the first two members
}

func defaultPayload() *payload {
	return &payload{members: []member{
		{name: "boot/kernel8.img", data: bytes.Repeat([]byte("k"), 100)},
		{name: "boot/overlays/x.dtbo", data: []byte("ovl")},
		{name: "root.squashfs", data: append([]byte("hsqs"), bytes.Repeat([]byte{7}, 5000)...)},
	}}
}

const testRel = "1.5.14-wsl.30+abcdef1.fw0123456"

func (p *payload) build(t *testing.T) (tgz []byte, sums []byte, bootTotal uint64) {
	t.Helper()
	sums = p.sums
	if sums == nil {
		var lines []string
		for _, m := range p.members {
			if m.typ == 0 || m.typ == tar.TypeReg {
				h := sha256.Sum256(m.data)
				lines = append(lines, hex.EncodeToString(h[:])+"  "+m.name)
			}
		}
		sort.Strings(lines)
		sums = []byte(strings.Join(lines, "\n") + "\n")
	}
	var root []byte
	for _, m := range p.members {
		if m.name == "root.squashfs" {
			root = m.data
		} else if strings.HasPrefix(m.name, "boot/") {
			bootTotal += uint64(len(m.data))
		}
	}
	meta := p.meta
	if meta == nil {
		meta = []byte(fmt.Sprintf("board=ekh-bcm2711\nversion=20261111-000000\nsize=%d\nrelease=%s\n", len(root), testRel))
	}
	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gz)
	add := func(m member) {
		typ := m.typ
		if typ == 0 {
			typ = tar.TypeReg
		}
		h := &tar.Header{Name: m.name, Mode: 0o644, Size: int64(len(m.data)), Typeflag: typ, ModTime: time.Unix(0, 0)}
		if typ == tar.TypeSymlink {
			h.Size, h.Linkname = 0, "/etc/shadow"
		}
		if err := tw.WriteHeader(h); err != nil {
			t.Fatal(err)
		}
		if typ == tar.TypeReg {
			tw.Write(m.data)
		}
	}
	head := []member{{name: "SHA256SUMS", data: sums}, {name: "metadata", data: meta}}
	if p.first == "metadata" {
		head[0], head[1] = head[1], head[0]
	}
	for _, m := range append(append(head, p.members...), p.extra...) {
		add(m)
	}
	tw.Close()
	gz.Write(p.inGzTail)
	gz.Close()
	return append(buf.Bytes(), p.trailing...), sums, bootTotal
}

func signedManifest(t *testing.T, size uint64, sums []byte, bootTotal uint64) []byte {
	t.Helper()
	k := vKey("release-key-K_test")
	sh := sha256.Sum256(sums)
	s := cbor.M(1, testRel, 2, "ekh-bcm2711", 3, size, 4, sh[:], 9, bootTotal)
	e := vSign1(t, vKey("release-root-T"), cbor.M(1, vPub(k), 2, uint64(2)), release.CTRelKey, release.LabelRelKey)
	sb := vSign1(t, k, s, release.CTRelease, release.LabelRelease)
	pair, _ := cbor.Encode([]any{e, sb})
	m, _ := cbor.Encode(cbor.M(1, testRel, 2, "ekh-bcm2711", 3, size, 4, sh[:], 5, pair))
	return m
}

// ---- the fake files / slot writer ------------------------------------------------------------------------

type fakeFS struct {
	mu        sync.Mutex
	bulk, wd  string
	p6        string
	p6ok      bool
	aclog     string
	upd       *fakeUpd
	writeRC   []int
	writes    [][]byte
	wroteBoot []string
	busy      bool
	trial     bool
	reboots   int
	rebootErr error
	cutWrite  chan struct{} // non-nil: the write marks the target BAD, closes this, waits for the cancel, rc 125
	uid       int           // provd's uid the worker expects (0 = this test's own)
	earlyExit bool          // like the real batman-slot: a refusal (rc != 0) before it reads a byte of stdin
}

func (f *fakeFS) BulkDir() string { return f.bulk }
func (f *fakeFS) WorkDir() string { return f.wd }
func (f *fakeFS) ProvdUID() int {
	if f.uid != 0 {
		return f.uid
	}
	return os.Getuid()
}
func (f *fakeFS) P6State() (string, bool) { return f.p6, f.p6ok }
func (f *fakeFS) AutocommitLog() string   { return f.aclog }
func (f *fakeFS) SlotBusy() bool          { return f.busy }
func (f *fakeFS) IsTrial() bool           { return f.trial }
func (f *fakeFS) Reboot() error           { f.mu.Lock(); defer f.mu.Unlock(); f.reboots++; return f.rebootErr }
func (f *fakeFS) SlotWrite(cancel <-chan struct{}, dir string, r io.Reader) (int, string) {
	if f.cutWrite != nil {
		f.mu.Lock()
		f.upd.out["bootinfo"] = "verified=-\nbad=1\nbootcfg=" + strings.Repeat("c", 64) + "\n--\n[pi4]\n"
		f.mu.Unlock()
		close(f.cutWrite)
		<-cancel
		return 125, "batman-slot: canceled"
	}
	if f.earlyExit {
		f.mu.Lock()
		rc := 0
		if len(f.writeRC) > 0 {
			rc = f.writeRC[0]
		}
		f.mu.Unlock()
		if rc != 0 {
			f.mu.Lock()
			f.writeRC = f.writeRC[1:]
			f.writes = append(f.writes, nil)
			f.mu.Unlock()
			return rc, "batman-slot: refused before the write"
		}
	}
	data, _ := io.ReadAll(r)
	f.mu.Lock()
	defer f.mu.Unlock()
	f.writes = append(f.writes, data)
	filepath.Walk(filepath.Join(dir, "boot"), func(p string, fi os.FileInfo, _ error) error {
		if fi != nil && fi.Mode().IsRegular() {
			rel, _ := filepath.Rel(dir, p)
			f.wroteBoot = append(f.wroteBoot, rel)
		}
		return nil
	})
	rc := 0
	if len(f.writeRC) > 0 {
		rc, f.writeRC = f.writeRC[0], f.writeRC[1:]
	}
	if rc == 0 {
		s, _ := os.ReadFile(filepath.Join(dir, "SHA256SUMS"))
		h := sha256.Sum256(s)
		f.upd.out["bootinfo"] = "verified=" + hex.EncodeToString(h[:]) + " " + f.upd.boot + "\nbad=0\nbootcfg=" + strings.Repeat("c", 64) + "\n--\n[pi4]\n"
	}
	return rc, "write rc"
}

type workRig struct {
	n      *Node
	f      *fakeUpd
	fs     *fakeFS
	clk    *time.Time
	owner  []byte // the owner's public key (the owner-op signer)
	tgz    []byte
	mf     []byte
	sumSha []byte
}

func newWorkRig(t *testing.T, p *payload) *workRig {
	t.Helper()
	n, f, clk := updRig(t)
	d := t.TempDir()
	fs := &fakeFS{bulk: filepath.Join(d, "bulk"), wd: filepath.Join(d, "run", "update"), p6: filepath.Join(d, "p6"), p6ok: true,
		aclog: filepath.Join(d, "autocommit.log"), upd: f}
	os.MkdirAll(fs.bulk, 0o700)
	os.MkdirAll(filepath.Dir(fs.wd), 0o700)
	os.MkdirAll(fs.p6, 0o700)
	n.SetUpdateSource(f, fs)
	retryWait = 10 * time.Millisecond
	tgz, sums, bt := p.build(t)
	mf := signedManifest(t, uint64(len(tgz)), sums, bt)
	sh := sha256.Sum256(sums)
	return &workRig{n: n, f: f, fs: fs, clk: clk, owner: vPub(vKey("owner-1")), tgz: tgz, mf: mf, sumSha: sh[:]}
}

// checkAndUpload: update.check by the owner, the window opened by the owner, the upload written by "provd".
func (w *workRig) checkAndUpload(t *testing.T) {
	t.Helper()
	ok, reason, _, e := check(t, w.n, w.clk, w.mf, string(ownerID(w.owner)))
	if e != nil || !ok {
		t.Fatalf("check: ok=%v reason=%d %v", ok, reason, e)
	}
	w.n.upd.updMu.Lock()
	w.n.upd.window = &window{Owner: ownerID(w.owner), Expiry: w.f.up + 900}
	w.n.upd.updMu.Unlock()
	if err := os.WriteFile(filepath.Join(w.fs.bulk, "payload"), w.tgz, 0o600); err != nil {
		t.Fatal(err)
	}
}

func (w *workRig) prepare(t *testing.T) (cbor.Map, *Error) {
	return w.n.updatePrepare(w.owner, wire(t, cbor.M(1, w.sumSha)))
}

func (w *workRig) waitWorker(t *testing.T) {
	t.Helper()
	for i := 0; i < 500; i++ {
		if !w.n.upd.isWorking() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("worker did not end")
}

func phaseOf(t *testing.T, n *Node) (uint64, uint64) {
	t.Helper()
	m, e := n.updateStatus()
	if e != nil {
		t.Fatal(e)
	}
	ph, _ := getUint(m, 1)
	r, _ := getUint(m, 3)
	return ph, r
}

// ---- tests ----------------------------------------------------------------------------------------------

func TestUpdateFlowEndToEnd(t *testing.T) {
	rebootDelay = 10 * time.Millisecond
	w := newWorkRig(t, defaultPayload())
	w.checkAndUpload(t)
	if ph, _ := phaseOf(t, w.n); ph != 1 {
		t.Fatalf("window open: phase %d", ph)
	}
	if _, e := w.prepare(t); e != nil {
		t.Fatal(e)
	}
	w.waitWorker(t)
	if len(w.fs.writes) != 1 || !bytes.Equal(w.fs.writes[0], defaultPayload().members[2].data) {
		t.Fatalf("slot write got %d writes (want exactly the rootfs once)", len(w.fs.writes))
	}
	if got := strings.Join(w.fs.wroteBoot, ","); got != "boot/kernel8.img,boot/overlays/x.dtbo" {
		t.Fatalf("boot files handed to batman-slot: %s", got)
	}
	if _, err := os.Lstat(filepath.Join(w.fs.bulk, "payload")); !os.IsNotExist(err) {
		t.Fatal("the upload was not unlinked")
	}
	if _, err := os.Lstat(w.fs.wd); !os.IsNotExist(err) {
		t.Fatal("the work dir was not removed")
	}
	if ph, _ := phaseOf(t, w.n); ph != 3 {
		t.Fatalf("written: phase %d (want 3)", ph)
	}
	// otaBusy is false again, and apply arms + reboots
	if _, e := w.n.updateApply(w.owner, wire(t, cbor.M(1, w.sumSha))); e != nil {
		t.Fatal(e)
	}
	if !strings.HasPrefix(w.f.calls[len(w.f.calls)-1], "arm "+hex.EncodeToString(w.sumSha)) {
		t.Fatalf("arm call: %v", w.f.calls)
	}
	ul := w.n.upd.readUL()
	if ul == nil || !ul.Rebooting || ul.ApplyBootID != w.f.boot || ul.ToVersion != testRel || ul.ToSlot != "B" {
		t.Fatalf("update-last after apply: %+v", ul)
	}
	time.Sleep(100 * time.Millisecond)
	if c := w.fs.rebootCount(); c != 1 {
		t.Fatalf("reboots %d", c)
	}
}

func TestUpdateApplyRefusals(t *testing.T) {
	w := newWorkRig(t, defaultPayload())
	w.checkAndUpload(t)
	w.prepare(t)
	w.waitWorker(t)
	// another owner
	if _, e := w.n.updateApply(vPub(vKey("owner-2")), wire(t, cbor.M(1, w.sumSha))); e == nil || e.Why != 15 {
		t.Fatalf("other owner: %v", e)
	}
	// VERIFIED of another boot (A9-m17): arm must not be reached
	w.f.out["bootinfo"] = strings.Replace(w.f.out["bootinfo"], w.f.boot, "99999999-2222-3333-4444-555555555555", 1)
	n := len(w.f.calls)
	if _, e := w.n.updateApply(w.owner, wire(t, cbor.M(1, w.sumSha))); e == nil || e.Why != 15 {
		t.Fatalf("VERIFIED of another boot: %v", e)
	}
	for _, c := range w.f.calls[n:] {
		if strings.HasPrefix(c, "arm") {
			t.Fatal("arm was called")
		}
	}
}

func TestUpdateApplyArmFails(t *testing.T) {
	w := newWorkRig(t, defaultPayload())
	w.checkAndUpload(t)
	w.prepare(t)
	w.waitWorker(t)
	// rc 15: refused before the tryboot SET — the flag is untouched: no disarm (an operator's arm would be
	// cancelled), apply_boot_id cleared (review r2 A-m5)
	w.f.rc["arm"] = 15
	if _, e := w.n.updateApply(w.owner, wire(t, cbor.M(1, w.sumSha))); e == nil || e.Why != release.ReasonBootCfg {
		t.Fatalf("arm rc 15: %v", e)
	}
	if c := w.f.calls[len(w.f.calls)-1]; c == "disarm" {
		t.Fatalf("disarmed after an arm that never set the flag: %v", w.f.calls)
	}
	if ul := w.n.upd.readUL(); ul == nil || ul.ApplyBootID != "" {
		t.Fatalf("apply_boot_id not cleared after a refused arm: %+v", ul)
	}
	// rc 1: failed after the SET (the read-back) — disarm, then apply_boot_id cleared
	*w.clk = w.clk.Add(time.Minute)
	w.f.rc["arm"] = 1
	if _, e := w.n.updateApply(w.owner, wire(t, cbor.M(1, w.sumSha))); e == nil {
		t.Fatal("arm rc 1 accepted")
	}
	if c := w.f.calls[len(w.f.calls)-1]; c != "disarm" {
		t.Fatalf("after an arm that failed past the SET: %s (want disarm)", c)
	}
	if ul := w.n.upd.readUL(); ul == nil || ul.ApplyBootID != "" {
		t.Fatalf("apply_boot_id not cleared after a successful disarm: %+v", ul)
	}
	// p6 unwritable at "rebooting": disarm, E_STORAGE, no reboot (p6 goes away after the arm — not a chmod, which
	// root, the CI's prov_test run, ignores)
	w.f.rc["arm"] = 0
	*w.clk = w.clk.Add(time.Minute)
	w.f.onSlot = func(verb string) {
		if verb == "arm" {
			w.fs.p6ok = false
		}
	}
	if _, e := w.n.updateApply(w.owner, wire(t, cbor.M(1, w.sumSha))); e == nil || e.Code != EStorage {
		t.Fatalf("p6 read-only: %v", e)
	}
	if w.fs.rebootCount() != 0 {
		t.Fatal("rebooted although update-last could not be written")
	}
}

func TestUpdateLeaseRefusesAHeldWriter(t *testing.T) {
	w := newWorkRig(t, defaultPayload())
	w.checkAndUpload(t)
	held, err := os.OpenFile(filepath.Join(w.fs.bulk, "payload"), os.O_RDWR, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer held.Close()
	if _, e := w.prepare(t); e != nil {
		t.Fatal(e)
	}
	w.waitWorker(t)
	if len(w.fs.writes) != 0 {
		t.Fatal("a slot was written while another process held the upload open for writing (B11-MAJOR-1)")
	}
	if ph, r := phaseOf(t, w.n); ph != 0 || r != 15 {
		t.Fatalf("status %d / %d (want 0 + 15)", ph, r)
	}
}

func TestUpdateMaliciousPayloads(t *testing.T) {
	root := append([]byte("hsqs"), bytes.Repeat([]byte{7}, 5000)...)
	cases := map[string]func(p *payload){
		"metadata first":     func(p *payload) { p.first = "metadata" },
		"member after root":  func(p *payload) { p.extra = []member{{name: "boot/late.dtb", data: []byte("x")}} },
		"trailing gzip data": func(p *payload) { p.trailing = []byte("junk after the gzip member") },
		"second gzip member": func(p *payload) {
			var b bytes.Buffer
			g := gzip.NewWriter(&b)
			g.Write([]byte("x"))
			g.Close()
			p.trailing = b.Bytes()
		},
		"symlink member": func(p *payload) {
			p.members = append([]member{{name: "boot/evil.dtb", typ: tar.TypeSymlink}}, p.members...)
		},
		"unlisted boot member": func(p *payload) { p.sums = sumsOf(p.members[1:]) },
		"config.txt in SUMS": func(p *payload) {
			p.members = append([]member{{name: "boot/config.txt", data: []byte("arm_64bit=1")}}, p.members...)
		},
		"AutoBoot.txt in SUMS": func(p *payload) {
			p.members = append([]member{{name: "boot/AutoBoot.txt", data: []byte("x")}}, p.members...)
		},
		"not a slot boot file": func(p *payload) {
			p.members = append([]member{{name: "boot/README.md", data: []byte("x")}}, p.members...)
		},
		"garbage rootfs": func(p *payload) {
			s := sumsOf(p.members)
			p.members[2].data = append([]byte("hsqs"), bytes.Repeat([]byte{9}, 5000)...)
			p.sums = s
		},
		"rootfs size != meta": func(p *payload) {
			p.meta = []byte(fmt.Sprintf("board=ekh-bcm2711\nsize=%d\nrelease=%s\n", len(root)+1, testRel))
		},
		"metadata other board": func(p *payload) {
			p.meta = []byte(fmt.Sprintf("board=ekh-bcm2710\nsize=%d\nrelease=%s\n", len(root), testRel))
		},
		"metadata other release": func(p *payload) {
			p.meta = []byte(fmt.Sprintf("board=ekh-bcm2711\nsize=%d\nrelease=1.5.14-wsl.1\n", len(root)))
		},
		"listed symlink": func(p *payload) {
			// sha256 of NO bytes: the hash check alone would pass a symlink — only the type check refuses it
			s := string(sumsOf(p.members)) + "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  boot/evil.dtb\n"
			p.members = append([]member{{name: "boot/evil.dtb", typ: tar.TypeSymlink}}, p.members...)
			p.sums = []byte(s)
		},
		"protected name only in SUMS": func(p *payload) {
			p.sums = append(sumsOf(p.members), []byte(strings.Repeat("a", 64)+"  boot/AutoBoot.txt\n")...)
		},
		"dir traversal name": func(p *payload) {
			p.members = append([]member{{name: "boot/../x.dtb", data: []byte("x")}}, p.members...)
		},
	}
	for name, mod := range cases {
		p := defaultPayload()
		mod(p)
		w := newWorkRig(t, p)
		w.checkAndUpload(t)
		if _, e := w.prepare(t); e != nil {
			t.Fatalf("%s: prepare %v", name, e)
		}
		w.waitWorker(t)
		if len(w.fs.writes) != 0 {
			t.Fatalf("%s: a slot was written (the first pass must refuse before begin_write)", name)
		}
		if ph, r := phaseOf(t, w.n); ph != 0 || r != release.ReasonBad {
			t.Fatalf("%s: status %d / %d (want 0 + 11)", name, ph, r)
		}
	}
}

func sumsOf(ms []member) []byte {
	var lines []string
	for _, m := range ms {
		h := sha256.Sum256(m.data)
		lines = append(lines, hex.EncodeToString(h[:])+"  "+m.name)
	}
	sort.Strings(lines)
	return []byte(strings.Join(lines, "\n") + "\n")
}

func TestUpdateWriteRetriesBusy(t *testing.T) {
	w := newWorkRig(t, defaultPayload())
	w.fs.writeRC = []int{14, 0}
	w.checkAndUpload(t)
	w.prepare(t)
	w.waitWorker(t)
	if len(w.fs.writes) != 2 || !bytes.Equal(w.fs.writes[1], defaultPayload().members[2].data) {
		t.Fatalf("writes %d (want a retry from the start after rc 14)", len(w.fs.writes))
	}
	if ph, _ := phaseOf(t, w.n); ph != 3 {
		t.Fatalf("after the retry: phase %d", ph)
	}
	// 4 x busy -> 21
	w2 := newWorkRig(t, defaultPayload())
	w2.fs.writeRC = []int{14, 14, 14, 14}
	w2.checkAndUpload(t)
	w2.prepare(t)
	w2.waitWorker(t)
	if ph, r := phaseOf(t, w2.n); ph != 0 || r != 21 {
		t.Fatalf("always busy: %d / %d (want 0 + 21)", ph, r)
	}
}

func TestUpdatePrepareRefusals(t *testing.T) {
	w := newWorkRig(t, defaultPayload())
	w.checkAndUpload(t)
	// not the window's owner
	if _, e := w.n.updatePrepare(vPub(vKey("owner-2")), wire(t, cbor.M(1, w.sumSha))); e == nil || e.Why != 15 {
		t.Fatalf("other owner: %v", e)
	}
	// another sha
	if _, e := w.n.updatePrepare(w.owner, wire(t, cbor.M(1, bytes.Repeat([]byte{1}, 32)))); e == nil || e.Why != 15 {
		t.Fatalf("other sha: %v", e)
	}
	// an incomplete upload
	os.WriteFile(filepath.Join(w.fs.bulk, "payload"), w.tgz[:10], 0o600)
	if _, e := w.prepare(t); e == nil || e.Why != 15 {
		t.Fatalf("short upload: %v", e)
	}
	os.WriteFile(filepath.Join(w.fs.bulk, "payload"), w.tgz, 0o600)
	// an orphan write still holds the lock with its boot dir -> busy; without the lock the stale dir is removed
	os.MkdirAll(filepath.Join(w.fs.wd, "boot"), 0o700)
	w.fs.busy = true
	if _, e := w.prepare(t); e == nil || e.Code != EBusy {
		t.Fatalf("orphan write: %v", e)
	}
	w.fs.busy = false
	// p6 not mounted -> E_STORAGE, nothing started
	w.fs.p6ok = false
	if _, e := w.prepare(t); e == nil || e.Code != EStorage {
		t.Fatalf("p6 not mounted: %v", e)
	}
	w.fs.p6ok = true
	if _, e := w.prepare(t); e != nil {
		t.Fatalf("now: %v", e)
	}
	w.waitWorker(t)
	if len(w.fs.writes) != 1 {
		t.Fatalf("writes %d", len(w.fs.writes))
	}
}

func TestUpdateStatusTable(t *testing.T) {
	w := newWorkRig(t, defaultPayload())
	u := w.n.upd
	put := func(ul *updateLast) { u.updMu.Lock(); u.writeUL(ul); u.updMu.Unlock() }
	setSlot := func(s string, si slotInfo) { u.siMu.Lock(); u.slots[s] = si; u.slotsBad[s] = 0; u.siMu.Unlock() }
	sha := w.sumSha
	cur := w.f.ver
	base := func() *updateLast {
		return &updateLast{Sha: sha, FromSlot: "A", FromVersion: cur, ToSlot: "B", ToVersion: testRel}
	}
	if ph, _ := phaseOf(t, w.n); ph != 0 {
		t.Fatalf("nothing: %d", ph)
	}
	// row 5: the running version is neither from nor to
	ul := base()
	ul.FromVersion = "1.5.14-wsl.1"
	put(ul)
	if ph, r := phaseOf(t, w.n); ph != 0 || r != 0 {
		t.Fatalf("stale: %d/%d", ph, r)
	}
	// rows 6 / 7: running the new version in slot B
	put(base())
	w.f.active, w.f.ver = "B", testRel
	w.fs.trial = true
	if ph, _ := phaseOf(t, w.n); ph != 4 {
		t.Fatalf("trial: %d", ph)
	}
	w.fs.trial = false
	if ph, _ := phaseOf(t, w.n); ph != 5 {
		t.Fatalf("committed: %d", ph)
	}
	// row 8: back on A after an apply of another boot
	w.f.active, w.f.ver = "A", cur
	ul = base()
	ul.ApplyBootID, ul.Rebooting, ul.AclogOff = "00000000-2222-3333-4444-555555555555", true, 0
	put(ul)
	os.WriteFile(w.fs.aclog, []byte("20261111-1 TRIAL-REVERTED boot=1 slot=B version="+testRel+" waited=300s\n"), 0o644)
	if ph, r := phaseOf(t, w.n); ph != 6 || r != 0 {
		t.Fatalf("reverted: %d/%d", ph, r)
	}
	os.WriteFile(w.fs.aclog, []byte("20261111-1 NOT-COMMITTED boot=1 slot=B version="+testRel+"\n"+
		"20261111-1 COMMITTED boot=1 slot=B version="+testRel+"0\n"), 0o644) // not-committed / a longer version: no match
	if ph, r := phaseOf(t, w.n); ph != 6 || r != 18 {
		t.Fatalf("no verdict, rebooting: %d/%d (want 6 + 18)", ph, r)
	}
	os.WriteFile(w.fs.aclog, []byte("20261111-1 COMMITTED-BY-OPERATOR boot=1 slot=B version="+testRel+"\n"), 0o644)
	if ph, r := phaseOf(t, w.n); ph != 0 || r != 0 {
		t.Fatalf("committed then moved back: %d/%d", ph, r)
	}
	// rows 9 / 10: no apply; the target is BAD (a write cut short) / verified (written, never applied)
	os.Remove(w.fs.aclog)
	put(base())
	setSlot("B", slotInfo{Bad: true})
	if ph, r := phaseOf(t, w.n); ph != 0 || r != 22 {
		t.Fatalf("bad target: %d/%d (want 0 + 22)", ph, r)
	}
	setSlot("B", slotInfo{Verified: hex.EncodeToString(sha) + " 00000000-2222-3333-4444-555555555555"})
	if ph, r := phaseOf(t, w.n); ph != 0 || r != 23 {
		t.Fatalf("written, not applied: %d/%d (want 0 + 23)", ph, r)
	}
	// unknown update-last format -> as if none
	os.WriteFile(filepath.Join(w.fs.p6, "update-last"), []byte{0xa1, 0x00, 0x02}, 0o600)
	if ph, r := phaseOf(t, w.n); ph != 0 || r != 0 {
		t.Fatalf("format 2: %d/%d", ph, r)
	}
}

func TestUpdateTickDisarmRule(t *testing.T) {
	w := newWorkRig(t, defaultPayload())
	u := w.n.upd
	ul := &updateLast{Sha: w.sumSha, FromSlot: "A", FromVersion: w.f.ver, ToSlot: "B", ToVersion: testRel, ApplyBootID: w.f.boot}
	u.updMu.Lock()
	u.writeUL(ul)
	u.updMu.Unlock()
	countDisarm := func() int {
		c := 0
		for _, x := range w.f.calls {
			if x == "disarm" {
				c++
			}
		}
		return c
	}
	// apply_boot_id = this boot, not rebooting, slotMu held by an apply -> no disarm
	u.slotMu.Lock()
	w.n.UpdateTick()
	u.slotMu.Unlock()
	if countDisarm() != 0 {
		t.Fatal("disarmed while an apply held slotMu")
	}
	// disarm rc 14 -> apply_boot_id kept, retried next tick
	w.f.rc["disarm"] = 14
	w.n.UpdateTick()
	if countDisarm() != 1 || u.readUL().ApplyBootID != w.f.boot {
		t.Fatalf("disarm rc 14: %d calls, %+v", countDisarm(), u.readUL())
	}
	w.f.rc["disarm"] = 0
	w.n.UpdateTick()
	if countDisarm() != 2 || u.readUL().ApplyBootID != "" {
		t.Fatalf("disarm rc 0: apply_boot_id not cleared: %+v", u.readUL())
	}
	w.n.UpdateTick()
	if countDisarm() != 2 {
		t.Fatal("disarmed again after clearing")
	}
	// rebooting = true -> never disarmed (a reboot is under way)
	ul.ApplyBootID, ul.Rebooting = w.f.boot, true
	u.updMu.Lock()
	u.writeUL(ul)
	u.updMu.Unlock()
	w.n.UpdateTick()
	if countDisarm() != 2 {
		t.Fatal("disarmed although rebooting")
	}
	// an apply of another boot -> nothing to disarm (the flag died with that boot)
	ul.ApplyBootID, ul.Rebooting = "00000000-2222-3333-4444-555555555555", false
	u.updMu.Lock()
	u.writeUL(ul)
	u.updMu.Unlock()
	w.n.UpdateTick()
	if countDisarm() != 2 {
		t.Fatal("disarmed for another boot")
	}
}

func TestUpdateTickDeletesUploads(t *testing.T) {
	w := newWorkRig(t, defaultPayload())
	os.WriteFile(filepath.Join(w.fs.bulk, "payload"), []byte("x"), 0o600)
	os.WriteFile(filepath.Join(w.fs.bulk, "other"), []byte("x"), 0o600)
	tgt := filepath.Join(t.TempDir(), "victim")
	os.WriteFile(tgt, []byte("keep"), 0o600)
	os.Symlink(tgt, filepath.Join(w.fs.bulk, "link"))
	w.n.upd.window = &window{Owner: []byte("o"), Expiry: w.f.up + 900}
	w.n.UpdateTick()
	if _, err := os.Lstat(filepath.Join(w.fs.bulk, "payload")); err != nil {
		t.Fatal("deleted during an open window")
	}
	w.f.up += 901 // the window expires
	w.n.UpdateTick()
	ents, _ := os.ReadDir(w.fs.bulk)
	if len(ents) != 0 {
		t.Fatalf("left: %v", ents)
	}
	if b, _ := os.ReadFile(tgt); string(b) != "keep" {
		t.Fatal("followed a symlink")
	}
}

func TestUpdateLastRoundTrip(t *testing.T) {
	ul := &updateLast{Sha: bytes.Repeat([]byte{3}, 32), FromSlot: "A", FromVersion: "a", ToSlot: "B", ToVersion: "b",
		ApplyBootID: "x", AclogOff: 7, Rebooting: true}
	b, _ := ul.encode()
	got := decodeUpdateLast(b)
	if got == nil || !bytes.Equal(got.Sha, ul.Sha) || got.FromSlot != "A" || got.FromVersion != "a" || got.ToSlot != "B" ||
		got.ToVersion != "b" || got.ApplyBootID != "x" || got.AclogOff != 7 || !got.Rebooting {
		t.Fatalf("%+v", got)
	}
	if decodeUpdateLast([]byte{0xff}) != nil || decodeUpdateLast(nil) != nil {
		t.Fatal("garbage decoded")
	}
	_ = errors.New
}

func (f *fakeFS) rebootCount() int { f.mu.Lock(); defer f.mu.Unlock(); return f.reboots }

func TestUpdateApplyRebootingNotRecorded(t *testing.T) {
	w := newWorkRig(t, defaultPayload())
	w.checkAndUpload(t)
	w.prepare(t)
	w.waitWorker(t)
	w.f.onSlot = func(verb string) {
		if verb == "arm" {
			w.fs.p6ok = false // armed, then update-last cannot record "rebooting"
		}
	}
	if _, e := w.n.updateApply(w.owner, wire(t, cbor.M(1, w.sumSha))); e == nil || e.Code != EStorage {
		t.Fatalf("rebooting not recorded: %v (want E_STORAGE)", e)
	}
	if c := w.f.calls[len(w.f.calls)-1]; c != "disarm" {
		t.Fatalf("not disarmed: %v", w.f.calls)
	}
	time.Sleep(50 * time.Millisecond)
	if w.fs.rebootCount() != 0 {
		t.Fatal("rebooted into a trial update-last does not know about (A12-m4)")
	}
}

func TestUpdateFailureBoundToSha(t *testing.T) {
	p := defaultPayload()
	p.trailing = []byte("junk")
	w := newWorkRig(t, p)
	w.checkAndUpload(t)
	w.prepare(t)
	w.waitWorker(t)
	if ph, r := phaseOf(t, w.n); ph != 0 || r != release.ReasonBad {
		t.Fatalf("failed: %d/%d", ph, r)
	}
	// the owner checks ANOTHER release: the old failure must not be reported for it (A11-m2)
	p2 := defaultPayload()
	p2.members[2].data = append([]byte("hsqs"), bytes.Repeat([]byte{8}, 5000)...) // another release: another SHA256SUMS
	w2 := newWorkRig(t, p2)
	if bytes.Equal(w2.sumSha, w.sumSha) {
		t.Fatal("test setup: the two releases have the same sha")
	}
	w.f.out = w2.f.out
	w.mf, w.tgz, w.sumSha = w2.mf, w2.tgz, w2.sumSha
	ok, _, _, e := check(t, w.n, w.clk, w.mf, string(ownerID(w.owner)))
	if e != nil || !ok {
		t.Fatalf("second check: %v", e)
	}
	if ph, r := phaseOf(t, w.n); r == release.ReasonBad {
		t.Fatalf("the previous release's failure is reported for the new pending: %d/%d", ph, r)
	}
}

func TestUpdateStatusRevertedBeatsBad(t *testing.T) {
	w := newWorkRig(t, defaultPayload())
	u := w.n.upd
	ul := &updateLast{Sha: w.sumSha, FromSlot: "A", FromVersion: w.f.ver, ToSlot: "B", ToVersion: testRel,
		ApplyBootID: "00000000-2222-3333-4444-555555555555", Rebooting: true}
	u.updMu.Lock()
	u.writeUL(ul)
	u.updMu.Unlock()
	// autocommit reverted the trial and marked the slot BAD: the answer is "unhealthy, reverted" (6), not "write cut" (22)
	os.WriteFile(w.fs.aclog, []byte("20261111-1 TRIAL-REVERTED boot=1 slot=B version="+testRel+"\n"), 0o644)
	u.siMu.Lock()
	u.slots["B"] = slotInfo{Bad: true}
	u.siMu.Unlock()
	if ph, r := phaseOf(t, w.n); ph != 6 || r != 0 {
		t.Fatalf("reverted + bad: %d/%d (want 6)", ph, r)
	}
}

func TestUpdateLastFutureFormatIgnored(t *testing.T) {
	m := cbor.M(0, uint64(2), 1, bytes.Repeat([]byte{1}, 32), 2, "A", 3, "a", 4, "B", 5, "b", 6, "", 7, uint64(0), 8, false)
	b, _ := cbor.Encode(m)
	if decodeUpdateLast(b) != nil {
		t.Fatal("a complete update-last of format 2 was read as format 1")
	}
}

// owner/remove of the worker's owner (§3.7.5-9): the first pass stops before any slot write -> status 0;
// a write already begun is cut -> the target stays BAD -> status 0 + 22 (row 9). Never waits for the worker.
func TestUpdateOwnerRemovedFirstPass(t *testing.T) {
	w := newWorkRig(t, defaultPayload())
	hold, held := make(chan struct{}), make(chan struct{})
	firstPassDone = func() { close(held); <-hold }
	t.Cleanup(func() { firstPassDone = func() {} })
	w.checkAndUpload(t)
	if _, e := w.prepare(t); e != nil {
		t.Fatal(e)
	}
	<-held
	w.n.updOwnerRemoved(ownerID(w.owner))
	close(hold)
	w.waitWorker(t)
	if len(w.fs.writes) != 0 {
		t.Fatalf("a slot write after owner/remove in the first pass: %d", len(w.fs.writes))
	}
	if ph, r := phaseOf(t, w.n); ph != 0 || r != 0 {
		t.Fatalf("status after a first-pass cancel: %d/%d (want 0/0)", ph, r)
	}
	if w.n.upd.validPending() != nil {
		t.Fatal("the removed owner's pending survived")
	}
}

func TestUpdateOwnerRemovedSecondPass(t *testing.T) {
	w := newWorkRig(t, defaultPayload())
	w.fs.cutWrite = make(chan struct{})
	w.checkAndUpload(t)
	if _, e := w.prepare(t); e != nil {
		t.Fatal(e)
	}
	<-w.fs.cutWrite
	done := make(chan struct{})
	go func() { w.n.updOwnerRemoved(ownerID(w.owner)); close(done) }()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("owner/remove waited for the worker (lock order, §3.7.4)")
	}
	w.waitWorker(t)
	if ph, r := phaseOf(t, w.n); ph != 0 || r != 22 {
		t.Fatalf("status after a cut write: %d/%d (want 0/22)", ph, r)
	}
}

// another owner's removal leaves the pending and the window alone; after this boot's apply of it nothing is dropped
func TestUpdateOwnerRemovedOthers(t *testing.T) {
	w := newWorkRig(t, defaultPayload())
	w.checkAndUpload(t)
	u := w.n.upd
	w.n.updOwnerRemoved(ownerID(vPub(vKey("owner-2"))))
	if u.validPending() == nil || u.window == nil {
		t.Fatal("another owner's removal dropped the pending / window")
	}
	u.updMu.Lock()
	u.writeUL(&updateLast{Sha: w.sumSha, FromSlot: "A", FromVersion: w.f.ver, ToSlot: "B", ToVersion: testRel,
		ApplyBootID: w.f.boot, Rebooting: true})
	u.updMu.Unlock()
	w.n.updOwnerRemoved(ownerID(w.owner))
	if u.validPending() == nil {
		t.Fatal("owner/remove after the apply dropped the pending (the owner agreed, §3.7.4)")
	}
	if u.window != nil {
		t.Fatal("the removed owner's window survived")
	}
}

// the real owner.remove verb drops the removed owner's pending and window (§3.8.2)
func TestUpdateOwnerRemoveVerb(t *testing.T) {
	r, _ := memberRig(t)
	b, be := newKey(), newKey()
	se, _ := proto.SignES256(b, append([]byte(proto.LabelOwnerEnc), pub(be)...))
	if c, _ := r.call("owner.add", cbor.M(1, r.h, 2, r.envelope("owner/add", cbor.M(1, pub(b), 2, pub(be), 3, se), r.owner))); c != OK {
		t.Fatalf("owner adds B: %d", c)
	}
	w := newWorkRig(t, defaultPayload())
	r.n.SetUpdateSource(w.f, w.fs)
	u := r.n.upd
	kid := ownerID(pub(b))
	u.pend = &pending{R: &release.Release{SumsSha: w.sumSha, Version: testRel}, Owner: kid, BootID: w.f.boot, Expiry: w.f.up + 600}
	u.window = &window{Owner: kid, Expiry: w.f.up + 600}
	if c, _ := r.call("owner.remove", cbor.M(1, r.h, 2, r.envelope("owner/remove", cbor.M(1, kid), r.owner))); c != OK {
		t.Fatalf("owner removes B: %d", c)
	}
	if u.pend != nil || u.window != nil {
		t.Fatalf("B's pending / window survived its removal: %v %v", u.pend != nil, u.window != nil)
	}
}

// review r1 A-MAJOR-1: the real batman-slot write refuses (lock busy, precheck) BEFORE it reads stdin; a rootfs larger
// than the pipe buffer then fails the scan's write — the rc must still decide (14 = retry, 12 = reason 17)
func bigRootPayload() *payload {
	p := defaultPayload()
	p.members[2].data = append([]byte("hsqs"), bytes.Repeat([]byte{7}, 1<<20)...)
	return p
}

func TestUpdateWriteRefusedBeforeReading(t *testing.T) {
	w := newWorkRig(t, bigRootPayload())
	w.fs.earlyExit = true
	w.fs.writeRC = []int{14, 0}
	w.checkAndUpload(t)
	w.prepare(t)
	w.waitWorker(t)
	if ph, r := phaseOf(t, w.n); ph != 3 || r != 0 || len(w.fs.writes) != 2 {
		t.Fatalf("rc 14 before reading, then 0: phase %d reason %d, %d writes (want a retry -> 3)", ph, r, len(w.fs.writes))
	}
	w2 := newWorkRig(t, bigRootPayload())
	w2.fs.earlyExit = true
	w2.fs.writeRC = []int{12}
	w2.checkAndUpload(t)
	w2.prepare(t)
	w2.waitWorker(t)
	if ph, r := phaseOf(t, w2.n); ph != 0 || r != 17 {
		t.Fatalf("rc 12 before reading: %d/%d (want 0/17, not 11)", ph, r)
	}
}

// review r1 B-MAJOR-1 / §3.7.5-4: the rootfs is bounded by the target root partition, the stream by its total
func TestUpdateRootLargerThanSlot(t *testing.T) {
	w := newWorkRig(t, defaultPayload())
	w.f.rootBytes = 4000 // < the 5004 B rootfs
	w.checkAndUpload(t)
	w.prepare(t)
	w.waitWorker(t)
	if ph, r := phaseOf(t, w.n); ph != 0 || r != release.ReasonBad || len(w.fs.writes) != 0 {
		t.Fatalf("a rootfs larger than the slot: %d/%d, %d writes", ph, r, len(w.fs.writes))
	}
}

func TestUpdateDecompressionBound(t *testing.T) {
	p := defaultPayload()
	p.inGzTail = make([]byte, 4<<20) // compresses to ~4 KiB, inflates past the bound
	w := newWorkRig(t, p)
	w.f.rootBytes = 1 << 20 // bound = 256 KiB + 64 KiB + boot + 1 MiB + 1 MiB < 4 MiB
	w.checkAndUpload(t)
	w.prepare(t)
	w.waitWorker(t)
	if ph, r := phaseOf(t, w.n); ph != 0 || r != release.ReasonBad || len(w.fs.writes) != 0 {
		t.Fatalf("a stream that inflates past its bound: %d/%d, %d writes", ph, r, len(w.fs.writes))
	}
	q := defaultPayload()
	q.inGzTail = make([]byte, 512<<10) // within the bound: the tar end's padding, accepted as before
	w2 := newWorkRig(t, q)
	w2.f.rootBytes = 1 << 20
	w2.checkAndUpload(t)
	w2.prepare(t)
	w2.waitWorker(t)
	if ph, r := phaseOf(t, w2.n); ph != 3 || r != 0 {
		t.Fatalf("zeros within the bound refused: %d/%d", ph, r)
	}
}

func TestUpdateRootBytesUnknown(t *testing.T) {
	w := newWorkRig(t, defaultPayload())
	w.f.rootBytes = -1
	w.checkAndUpload(t)
	w.prepare(t)
	w.waitWorker(t)
	if ph, r := phaseOf(t, w.n); ph != 0 || r != 21 || len(w.fs.writes) != 0 {
		t.Fatalf("unknown slot size: %d/%d", ph, r)
	}
}

// a cancel during the first pass stops the read (not only between the passes)
func TestUpdateCancelInsideFirstPass(t *testing.T) {
	w := newWorkRig(t, defaultPayload())
	f, err := os.CreateTemp(t.TempDir(), "p")
	if err != nil {
		t.Fatal(err)
	}
	f.Write(w.tgz)
	f.Seek(0, 0)
	c := make(chan struct{})
	close(c)
	check(t, w.n, w.clk, w.mf, string(ownerID(w.owner)))
	var sums []byte
	if we := w.n.scan(cancelReader{f, c}, w.n.upd.pend.R, t.TempDir(), nil, &sums, 1<<33); we == nil {
		t.Fatal("a canceled first pass read the payload to its end")
	}
}

// review r1 A-m7: a refresh of the target slot that fails is not taken from the cache; rc 14 = E_BUSY at apply
func TestUpdateApplyTargetBusy(t *testing.T) {
	w := newWorkRig(t, defaultPayload())
	w.checkAndUpload(t)
	w.prepare(t)
	w.waitWorker(t)
	w.f.rc["bootinfo"] = 14
	if _, e := w.n.updateApply(w.owner, wire(t, cbor.M(1, w.sumSha))); e == nil || e.Code != EBusy {
		t.Fatalf("apply while bootinfo is busy: %v (want E_BUSY)", e)
	}
	for _, c := range w.f.calls {
		if strings.HasPrefix(c, "arm") {
			t.Fatal("armed without a fresh look at the target slot")
		}
	}
}

// owner/remove as the first pass begins: the pass stops reading (it does not run to its end first)
func TestUpdateCancelStopsFirstPass(t *testing.T) {
	w := newWorkRig(t, defaultPayload())
	done := false
	firstPassStart = func() { w.n.updOwnerRemoved(ownerID(w.owner)) }
	firstPassDone = func() { done = true }
	t.Cleanup(func() { firstPassStart, firstPassDone = func() {}, func() {} })
	w.checkAndUpload(t)
	w.prepare(t)
	w.waitWorker(t)
	if done {
		t.Fatal("the first pass read the whole payload after the cancel")
	}
	if len(w.fs.writes) != 0 {
		t.Fatal("a slot write after the cancel")
	}
}

// §3.7.4: update.check re-reads the target slot even when the cache has it (review r1 A-m8)
func TestUpdateCheckRereadsTarget(t *testing.T) {
	n, f, clk := updRig(t)
	f.out["bootinfo"] = bootinfoOut(strings.Repeat("c", 64))
	if ok, _, _, e := check(t, n, clk, relManifest(t, "plain"), "o1"); e != nil || !ok {
		t.Fatal("check 1")
	}
	before := 0
	for _, c := range f.calls {
		if c == "bootinfo B" {
			before++
		}
	}
	if ok, _, _, e := check(t, n, clk, relManifest(t, "plain"), "o1"); e != nil || !ok {
		t.Fatal("check 2")
	}
	after := 0
	for _, c := range f.calls {
		if c == "bootinfo B" {
			after++
		}
	}
	if before != 1 || after != 2 {
		t.Fatalf("bootinfo B calls: %d then %d (want 1 then 2: every check reads the slot)", before, after)
	}
}

// review r2 A-m6: the tick's disarm stops after 5 failures that are not the lock (14 is retried without a limit)
func TestUpdateTickDisarmGivesUp(t *testing.T) {
	w := newWorkRig(t, defaultPayload())
	u := w.n.upd
	ul := &updateLast{Sha: w.sumSha, FromSlot: "A", FromVersion: w.f.ver, ToSlot: "B", ToVersion: testRel, ApplyBootID: w.f.boot}
	u.updMu.Lock()
	u.writeUL(ul)
	u.updMu.Unlock()
	count := func() int {
		n := 0
		for _, c := range w.f.calls {
			if c == "disarm" {
				n++
			}
		}
		return n
	}
	w.f.rc["disarm"] = 14
	for i := 0; i < 8; i++ {
		w.n.UpdateTick()
	}
	if count() != 8 {
		t.Fatalf("rc 14 (the lock): %d disarms in 8 ticks (want every tick)", count())
	}
	w.f.rc["disarm"] = 18
	for i := 0; i < 8; i++ {
		w.n.UpdateTick()
	}
	if got := count() - 8; got != disarmTries {
		t.Fatalf("rc 18: %d disarms in 8 ticks (want %d, then it stops)", got, disarmTries)
	}
}

// review r2 A-m2: a PAX GNU-sparse member (GNU tar --format=pax --sparse) is read by archive/tar as a regular file
// with GNU.sparse.* records — refused (§3.7.5-4). The payload is made by GNU tar itself (the one that writes them).
func TestUpdatePAXSparseRefused(t *testing.T) {
	gt, err := exec.LookPath("tar")
	if err != nil {
		t.Fatal("GNU tar needed to make a PAX sparse member")
	}
	for _, ver := range []string{"1.0", "0.1"} {
		d := t.TempDir()
		os.MkdirAll(filepath.Join(d, "boot"), 0o755)
		k := filepath.Join(d, "boot", "kernel8.img")
		f, _ := os.Create(k)
		f.Truncate(1 << 20)
		f.Seek(0, 2)
		f.Write([]byte("tail"))
		f.Close()
		root := append([]byte("hsqs"), bytes.Repeat([]byte{7}, 5000)...)
		os.WriteFile(filepath.Join(d, "root.squashfs"), root, 0o644)
		kb, _ := os.ReadFile(k)
		hk, hr := sha256.Sum256(kb), sha256.Sum256(root)
		sums := []byte(hex.EncodeToString(hk[:]) + "  boot/kernel8.img\n" + hex.EncodeToString(hr[:]) + "  root.squashfs\n")
		os.WriteFile(filepath.Join(d, "SHA256SUMS"), sums, 0o644)
		meta := fmt.Sprintf("board=ekh-bcm2711\nversion=x\nsize=%d\nrelease=%s\n", len(root), testRel)
		os.WriteFile(filepath.Join(d, "metadata"), []byte(meta), 0o644)
		out := filepath.Join(d, "p.tar.gz")
		if o, err := exec.Command(gt, "-C", d, "--format=pax", "--sparse", "--sparse-version="+ver, "-czf", out,
			"SHA256SUMS", "metadata", "boot/kernel8.img", "root.squashfs").CombinedOutput(); err != nil {
			t.Fatalf("tar: %v %s", err, o)
		}
		tgz, _ := os.ReadFile(out)
		w := newWorkRig(t, defaultPayload())
		w.tgz, w.mf = tgz, signedManifest(t, uint64(len(tgz)), sums, uint64(len(kb)))
		sh := sha256.Sum256(sums)
		w.sumSha = sh[:]
		w.checkAndUpload(t)
		w.prepare(t)
		w.waitWorker(t)
		if ph, r := phaseOf(t, w.n); ph != 0 || r != release.ReasonBad || len(w.fs.writes) != 0 {
			t.Fatalf("sparse %s: %d/%d, %d writes (want 0/11, no write)", ver, ph, r, len(w.fs.writes))
		}
	}
}

// review r2 B-m2: the takeover refuses an upload with a second hard link, or not owned by provd (target untouched)
func TestUpdateTakeoverRefusals(t *testing.T) {
	w := newWorkRig(t, defaultPayload())
	w.checkAndUpload(t)
	if err := os.Link(filepath.Join(w.fs.bulk, "payload"), filepath.Join(w.fs.bulk, "second")); err != nil {
		t.Fatal(err)
	}
	w.prepare(t)
	w.waitWorker(t)
	if ph, r := phaseOf(t, w.n); ph != 0 || r != 15 || len(w.fs.writes) != 0 {
		t.Fatalf("an upload with two links: %d/%d, %d writes (want 0/15)", ph, r, len(w.fs.writes))
	}
	w2 := newWorkRig(t, defaultPayload())
	w2.fs.uid = os.Getuid() + 1
	w2.checkAndUpload(t)
	w2.prepare(t)
	w2.waitWorker(t)
	if ph, r := phaseOf(t, w2.n); ph != 0 || r != 15 || len(w2.fs.writes) != 0 {
		t.Fatalf("an upload not owned by provd: %d/%d, %d writes (want 0/15)", ph, r, len(w2.fs.writes))
	}
}
