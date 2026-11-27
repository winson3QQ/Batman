//go:build linux

package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"batman-prov/se608"
	"batman-prov/se608/fakechip"
)

type rig struct {
	chip  *fakechip.Chip
	dir   string
	opens int
	busy  bool
}

func newRig(t *testing.T) *rig { return &rig{chip: fakechip.New(), dir: t.TempDir()} }

func (r *rig) allowFile(t *testing.T, serials ...[9]byte) string {
	t.Helper()
	var b strings.Builder
	b.WriteString("# sacrificial chips\n\n")
	for _, s := range serials {
		b.WriteString(hex.EncodeToString(s[:]) + "\n")
	}
	p := filepath.Join(r.dir, fmt.Sprintf("allow%d", len(serials)))
	if err := os.WriteFile(p, []byte(b.String()), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

func (r *rig) serial() [9]byte { return se608.Serial(r.chip.Config) }
func (r *rig) b17() string     { return fmt.Sprintf("%02x", r.chip.Config[17]) }

func (r *rig) run(t *testing.T, args ...string) (int, string, string) {
	t.Helper()
	var out, errOut bytes.Buffer
	e := env{
		openBus: func(string) (se608.Bus, func(), error) {
			r.opens++
			if r.busy {
				return nil, nil, se608.ErrBusy
			}
			return r.chip, func() {}, nil
		},
		out:    &out,
		errOut: &errOut,
	}
	rc := run(args, e)
	return rc, out.String(), errOut.String()
}

func countOp(c *fakechip.Chip, op byte) int {
	n := 0
	for _, o := range c.Ops {
		if o == op {
			n++
		}
	}
	return n
}

// E3 end to end on the fake: write, read back equal; then compare alone says EQUAL; a second write sends nothing.
func TestWriteImageThenCompare(t *testing.T) {
	r := newRig(t)
	allow := r.allowFile(t, r.serial())
	b17 := r.b17()
	rc, out, errOut := r.run(t, "-allow", allow, "-byte17", b17, "write-image")
	if rc != exitOK || !strings.Contains(out, "compare=EQUAL") || !strings.Contains(out, "written_words=16") {
		t.Fatalf("rc %d\n%s\n%s", rc, out, errOut)
	}
	if bad := se608.DiffImage(r.chip.Config, se608.Image(true, r.chip.Config[17])); len(bad) != 0 {
		t.Fatalf("chip differs from the variant image at %v", bad)
	}
	if r.chip.Config[17] != 0x3B {
		t.Fatalf("byte 17 changed to %#x", r.chip.Config[17])
	}
	if rc, out, _ := r.run(t, "-byte17", b17, "compare"); rc != exitOK || !strings.Contains(out, "compare=EQUAL") {
		t.Fatalf("compare after write: rc %d\n%s", rc, out)
	}
	n := countOp(r.chip, se608.OpWrite)
	if rc, out, _ := r.run(t, "-allow", allow, "-byte17", b17, "write-image"); rc != exitOK || countOp(r.chip, se608.OpWrite) != n || !strings.Contains(out, "written_words=0") {
		t.Fatalf("rewrite: rc %d, writes %d -> %d", rc, n, countOp(r.chip, se608.OpWrite))
	}
	if countOp(r.chip, 0x17) != 0 || countOp(r.chip, 0x20) != 0 {
		t.Fatal("lock-class opcode reached the chip")
	}
}

// compare on a blank chip says DIFFERENT (exit 4): the negative control for the EQUAL above. A wrong -byte17
// shows up as a difference at byte 17 after a write.
func TestCompareDiffers(t *testing.T) {
	r := newRig(t)
	rc, out, _ := r.run(t, "-byte17", r.b17(), "compare")
	if rc != exitDiffers || !strings.Contains(out, "compare=DIFFERENT") || !strings.Contains(out, "differs byte=") {
		t.Fatalf("rc %d\n%s", rc, out)
	}
	r = newRig(t)
	if rc, _, _ := r.run(t, "-allow", r.allowFile(t, r.serial()), "-byte17", r.b17(), "write-image"); rc != exitOK {
		t.Fatal("write-image failed")
	}
	rc, out, _ = r.run(t, "-byte17", "00", "compare")
	if rc != exitDiffers || !strings.Contains(out, "differs byte=17 chip=3b image=00") {
		t.Fatalf("wrong byte17: rc %d\n%s", rc, out)
	}
}

func TestRefusals(t *testing.T) {
	other := [9]byte{1, 2, 3, 4, 5, 6, 7, 8, 9}
	own := func(r *rig, t *testing.T) []string { return []string{"-allow", r.allowFile(t, r.serial())} }
	notListed := func(r *rig, t *testing.T) []string { return []string{"-allow", r.allowFile(t, other)} }
	img := func(r *rig) []string { return []string{"-byte17", r.b17(), "write-image"} }
	cases := []struct {
		name  string
		setup func(*rig)
		allow func(*rig, *testing.T) []string
		cmd   func(*rig) []string
		bus   bool // whether the bus may be opened at all
	}{
		{"no allow list", nil, func(*rig, *testing.T) []string { return nil }, img, false},
		{"random without allow list", nil, func(*rig, *testing.T) []string { return nil }, func(*rig) []string { return []string{"random"} }, false},
		{"not on the list", nil, notListed, img, true},
		{"random not on the list", nil, notListed, func(*rig) []string { return []string{"random"} }, true},
		{"data-write not on the list", nil, notListed, func(*rig) []string { return []string{"data-write", "8"} }, true},
		{"wrong revision", func(r *rig) { r.chip.Config[7] = 0x02 }, own, img, true},
		{"wrong revision, info", func(r *rig) { r.chip.Config[7] = 0x02 }, func(*rig, *testing.T) []string { return nil }, func(*rig) []string { return []string{"info"} }, true},
		{"config locked", func(r *rig) { r.chip.LockConfigForTest() }, own, img, true},
		{"data-write, config locked", func(r *rig) { r.chip.LockConfigForTest() }, own, func(*rig) []string { return []string{"data-write", "9"} }, true},
		{"wrong revision, data-write", func(r *rig) { r.chip.Config[7] = 0x02 }, own, func(*rig) []string { return []string{"data-write", "9"} }, true},
		{"wrong revision, random", func(r *rig) { r.chip.Config[7] = 0x02 }, own, func(*rig) []string { return []string{"random"} }, true},
		{"wrong revision, compare", func(r *rig) { r.chip.Config[7] = 0x02 }, func(*rig, *testing.T) []string { return nil }, func(r *rig) []string { return []string{"-byte17", r.b17(), "compare"} }, true},
		{"random, config locked", func(r *rig) { r.chip.LockConfigForTest() }, own, func(*rig) []string { return []string{"random"} }, true},
		{"wrong revision, dump", func(r *rig) { r.chip.Config[7] = 0x02 }, func(*rig, *testing.T) []string { return nil }, func(*rig) []string { return []string{"dump"} }, true},
		{"lock byte 0xAA", func(r *rig) { r.chip.Config[se608.LockConfigByte] = 0xAA }, own, img, true},
		{"byte17 differs", nil, own, func(*rig) []string { return []string{"-byte17", "00", "write-image"} }, true},
		{"lock held", func(r *rig) { r.busy = true }, func(*rig, *testing.T) []string { return nil }, func(*rig) []string { return []string{"info"} }, true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			r := newRig(t)
			if c.setup != nil {
				c.setup(r)
			}
			before := r.chip.Config
			args := append(c.allow(r, t), c.cmd(r)...)
			rc, out, errOut := r.run(t, args...)
			if rc != exitRefused || !strings.Contains(errOut, "refused") {
				t.Fatalf("rc %d\n%s\n%s", rc, out, errOut)
			}
			if n := countOp(r.chip, se608.OpWrite) + countOp(r.chip, se608.OpRandom); n != 0 {
				t.Fatalf("%d Write/Random commands sent", n)
			}
			if r.chip.Config != before {
				t.Fatal("config changed")
			}
			if !c.bus && r.opens != 0 {
				t.Fatal("bus opened before the allow-list check")
			}
		})
	}
}

// E1 / E2 on the fake: info, dump, random pattern, data write refused before the config lock at the right address.
func TestReadOnlyAndE2(t *testing.T) {
	r := newRig(t)
	before := r.chip.Config
	sn := r.serial()
	rc, out, _ := r.run(t, "info")
	if rc != exitOK || !strings.Contains(out, "revision=00006003") || !strings.Contains(out, "serial="+hex.EncodeToString(sn[:])) || !strings.Contains(out, "lock_config=55") {
		t.Fatalf("info rc %d\n%s", rc, out)
	}
	rc, out, _ = r.run(t, "dump")
	if rc != exitOK || strings.Count(out, "config[") != 8 || !strings.Contains(out, "byte17=3b") {
		t.Fatalf("dump rc %d\n%s", rc, out)
	}
	allow := r.allowFile(t, sn)
	rc, out, _ = r.run(t, "-allow", allow, "random")
	if rc != exitOK || !strings.Contains(out, "random=ffff0000") {
		t.Fatalf("random rc %d\n%s", rc, out)
	}
	rc, out, _ = r.run(t, "-allow", allow, "data-write", "9")
	if rc != exitOK || !strings.Contains(out, "data_write_slot9=status_0f") {
		t.Fatalf("data-write rc %d\n%s", rc, out)
	}
	last := r.chip.Pkts[len(r.chip.Pkts)-1]
	if last[1] != se608.OpWrite || last[2] != 0x82 || last[3] != 9<<3 || last[4] != 0 {
		t.Fatalf("data-write packet % x, want Write data32 slot 9", last)
	}
	if r.chip.Config != before {
		t.Fatal("a read-only command changed the config")
	}
}

// image: no bus, bytes 16-127 printed, the hash is over exactly those 112 bytes.
func TestImageOffline(t *testing.T) {
	r := newRig(t)
	rc, out, _ := r.run(t, "-byte17", "3b", "image")
	img := se608.Image(true, 0x3B)
	want := fmt.Sprintf("image_sha256=%x", sha256.Sum256(img[16:]))
	if rc != exitOK || r.opens != 0 || strings.Count(out, "image[") != 7 || !strings.Contains(out, want) || !strings.Contains(out, "image[ 16]=c0 3b 00 00") {
		t.Fatalf("rc %d opens %d\n%s", rc, r.opens, out)
	}
}

func TestUsage(t *testing.T) {
	for _, a := range [][]string{{}, {"lock"}, {"info", "x"}, {"data-write"}, {"data-write", "16"}, {"data-write", "a"},
		{"-nosuchflag", "info"}, {"image"}, {"compare"}, {"-byte17", "3", "image"}, {"-byte17", "zz", "compare"}} {
		r := newRig(t)
		if rc, _, _ := r.run(t, a...); rc != exitUsage || r.opens != 0 {
			t.Errorf("%q: rc %d opens %d", a, rc, r.opens)
		}
	}
	r := newRig(t)
	bad := filepath.Join(r.dir, "bad")
	_ = os.WriteFile(bad, []byte("0123\n"), 0o600)
	if rc, _, _ := r.run(t, "-allow", bad, "-byte17", "3b", "write-image"); rc != exitUsage || r.opens != 0 {
		t.Errorf("bad allow list: rc %d", rc)
	}
	empty := filepath.Join(r.dir, "empty")
	_ = os.WriteFile(empty, []byte("# nothing\n"), 0o600)
	if rc, _, _ := r.run(t, "-allow", empty, "-byte17", "3b", "write-image"); rc != exitUsage {
		t.Errorf("empty allow list: rc %d", rc)
	}
}
