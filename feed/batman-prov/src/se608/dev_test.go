package se608_test

import (
	"bytes"
	"errors"
	"testing"
	"time"

	"batman-prov/se608"
	"batman-prov/se608/fakechip"
)

// fakeClock makes polling deterministic: sleep advances now, nothing really waits.
type fakeClock struct{ t time.Time }

func (c *fakeClock) sleep(d time.Duration) { c.t = c.t.Add(d) }
func (c *fakeClock) now() time.Time        { return c.t }

// recBus records every write so a test can assert what went on the wire.
type recBus struct {
	se608.Bus
	writes [][]byte
}

func (r *recBus) Write(addr uint16, p []byte) error {
	r.writes = append(r.writes, append([]byte{byte(addr)}, p...))
	return r.Bus.Write(addr, p)
}

func newDev(t *testing.T) (*se608.Dev, *fakechip.Chip, *recBus) {
	t.Helper()
	chip := fakechip.New()
	rb := &recBus{Bus: chip}
	d := se608.New(rb)
	c := &fakeClock{t: time.Unix(0, 0)}
	d.SetClock(c.sleep, c.now)
	return d, chip, rb
}

func TestRevisionAndConfig(t *testing.T) {
	d, chip, _ := newDev(t)
	var rev [4]byte
	if err := d.Do(func(s *se608.Session) (err error) { rev, err = s.Revision(); return }); err != nil {
		t.Fatal(err)
	}
	if rev != se608.Rev608B {
		t.Fatalf("revision % x", rev)
	}
	cfg, err := d.ReadConfig()
	if err != nil {
		t.Fatal(err)
	}
	if cfg != chip.Config {
		t.Fatalf("config read back differs:\n% x\n% x", cfg, chip.Config)
	}
	sn := se608.Serial(cfg)
	if !bytes.Equal(sn[:4], cfg[0:4]) || !bytes.Equal(sn[4:], cfg[8:13]) {
		t.Fatalf("serial % x", sn)
	}
	if se608.ConfigLocked(cfg) {
		t.Fatal("blank chip reported locked")
	}
}

// E3 on the fake: the variant image goes in, reads back equal, and nothing outside the image words changes.
func TestWriteConfigImage(t *testing.T) {
	d, chip, rb := newDev(t)
	before := chip.Config
	img := se608.Image(true, before[17])
	if _, err := d.WriteConfigImage(img); err != nil {
		t.Fatal(err)
	}
	got, err := d.ReadConfig()
	if err != nil {
		t.Fatal(err)
	}
	if bad := se608.DiffImage(got, img); len(bad) != 0 {
		t.Fatalf("read-back differs at %v", bad)
	}
	for i := 0; i < se608.ConfigLen; i++ {
		inImage := (i >= 16 && i <= 51) || (i >= 68 && i <= 83) || i >= 88
		if !inImage && got[i] != before[i] {
			t.Errorf("byte %d changed: %#x -> %#x", i, before[i], got[i])
		}
	}
	for _, op := range chip.Ops {
		if op != se608.OpRead && op != se608.OpWrite {
			t.Errorf("opcode %#x sent", op)
		}
	}
	// No packet on the wire carries the Lock or UpdateExtra opcode.
	for _, w := range rb.writes {
		if len(w) > 3 && w[0] == byte(se608.Addr) && w[1] == 0x03 && (w[3] == 0x17 || w[3] == 0x20) {
			t.Errorf("lock-class packet on the wire: % x", w)
		}
	}
	// The negative control: DiffImage finds a single changed byte.
	got[30] ^= 0x01
	if bad := se608.DiffImage(got, img); len(bad) != 1 || bad[0] != 30 {
		t.Fatalf("DiffImage after flipping byte 30: %v", bad)
	}
}

func TestWriteConfigImageRefusesLockedChip(t *testing.T) {
	d, chip, _ := newDev(t)
	chip.LockConfigForTest()
	_, err := d.WriteConfigImage(se608.Image(true, 0))
	if err == nil {
		t.Fatal("wrote to a locked chip")
	}
	for _, op := range chip.Ops {
		if op == se608.OpWrite {
			t.Fatal("a Write was sent to a locked chip")
		}
	}
}

func TestExecRefusesIrreversibleOps(t *testing.T) {
	d, chip, _ := newDev(t)
	for _, op := range []byte{0x17 /* Lock */, 0x20 /* UpdateExtra */, 0x40 /* GenKey */, 0x46 /* PrivWrite */, 0x41, 0x43, 0x28, 0x99} {
		err := d.Do(func(s *se608.Session) error {
			_, err := s.Exec(se608.Cmd{Op: op, RespLen: 1, MaxExec: time.Second})
			return err
		})
		if !errors.Is(err, se608.ErrRefused) {
			t.Errorf("opcode %#x: err = %v, want ErrRefused", op, err)
		}
	}
	if len(chip.Ops) != 0 {
		t.Fatalf("refused opcodes reached the chip: % x", chip.Ops)
	}
}

func TestBusyPolling(t *testing.T) {
	d, chip, _ := newDev(t)
	chip.BusyPolls = 5
	if err := d.Do(func(s *se608.Session) error { _, err := s.Revision(); return err }); err != nil {
		t.Fatalf("5 busy polls: %v", err)
	}
	chip.BusyPolls = 1000 // never ready within the cap
	err := d.Do(func(s *se608.Session) error { _, err := s.Revision(); return err })
	if !errors.Is(err, se608.ErrNoResponse) || !se608.IsTransport(err) {
		t.Fatalf("stuck chip: err = %v, want ErrNoResponse", err)
	}
}

// "N times no response, then recover" (impl §2.2): one dropped wake is absorbed by the retry; two fail the
// sequence; the next sequence works.
func TestDroppedWakes(t *testing.T) {
	d, chip, _ := newDev(t)
	chip.DropWakes = 1
	if err := d.Do(func(*se608.Session) error { return nil }); err != nil {
		t.Fatalf("one dropped wake: %v", err)
	}
	chip.DropWakes = 2
	if err := d.Do(func(*se608.Session) error { return nil }); !errors.Is(err, se608.ErrNoResponse) {
		t.Fatalf("two dropped wakes: err = %v, want ErrNoResponse", err)
	}
	if err := d.Do(func(*se608.Session) error { return nil }); err != nil {
		t.Fatalf("after recovery: %v", err)
	}
}

// A chip left awake by an interrupted sequence answers the wake read with stale output; Do idles and retries.
func TestStaleAwakeChip(t *testing.T) {
	d, chip, _ := newDev(t)
	_ = chip.Write(0x00, []byte{0x00})
	var r [4]byte
	_ = chip.Read(se608.Addr, r[:])                                                    // consume the wake response
	_ = chip.Write(se608.Addr, []byte{0x03, 0x07, 0x30, 0x00, 0x00, 0x00, 0x03, 0x5D}) // Info, never read
	var rev [4]byte
	if err := d.Do(func(s *se608.Session) (err error) { rev, err = s.Revision(); return }); err != nil {
		t.Fatal(err)
	}
	if rev != se608.Rev608B || chip.Wakes != 2 {
		t.Fatalf("rev % x, wakes %d", rev, chip.Wakes)
	}
}

func TestCorruptResponse(t *testing.T) {
	d, chip, _ := newDev(t)
	chip.CorruptNext = true
	err := d.Do(func(s *se608.Session) error { _, err := s.Revision(); return err })
	if !errors.Is(err, se608.ErrComm) || !se608.IsTransport(err) {
		t.Fatalf("err = %v, want ErrComm", err)
	}
}

// E2 on the fake: data write refused before the config lock (status 0x0F), Random is the test pattern.
func TestBeforeConfigLock(t *testing.T) {
	d, _, _ := newDev(t)
	var rnd []byte
	err := d.Do(func(s *se608.Session) error {
		werr := s.Write(se608.ZoneData, se608.DataAddr(8, 0, 0), make([]byte, 32))
		var se *se608.StatusError
		if !errors.As(werr, &se) || se.Code != 0x0F {
			t.Errorf("data write before lock: %v, want status 0x0F", werr)
		}
		var err error
		rnd, err = s.Random()
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(rnd[:4], []byte{0xFF, 0xFF, 0x00, 0x00}) {
		t.Fatalf("random before lock % x", rnd)
	}
}

func TestSessionNotReusable(t *testing.T) {
	d, _, _ := newDev(t)
	var keep *se608.Session
	_ = d.Do(func(s *se608.Session) error { keep = s; return nil })
	if _, err := keep.Revision(); !errors.Is(err, se608.ErrSession) {
		t.Fatalf("reuse after Do: %v", err)
	}
}

// Every sequence ends with idle (word address 0x02), also when fn fails.
func TestIdleAfterEverySequence(t *testing.T) {
	d, _, rb := newDev(t)
	_ = d.Do(func(*se608.Session) error { return errors.New("boom") })
	last := rb.writes[len(rb.writes)-1]
	if !bytes.Equal(last, []byte{byte(se608.Addr), 0x02}) {
		t.Fatalf("last write % x, want idle", last)
	}
}

// DataAddr reaches the right slot, block and word: after the config lock (data zone still open) a write lands in
// the fake's slot buffer at block*32 + word*4 and reads back the same.
func TestDataAddr(t *testing.T) {
	d, chip, _ := newDev(t)
	chip.LockConfigForTest()
	pat32 := bytes.Repeat([]byte{0xC3}, 32)
	pat4 := []byte{1, 2, 3, 4}
	err := d.Do(func(s *se608.Session) error {
		if err := s.Write(se608.ZoneData, se608.DataAddr(9, 1, 0), pat32); err != nil {
			return err
		}
		return s.Write(se608.ZoneData, se608.DataAddr(8, 2, 5), pat4)
	})
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(chip.Data[9][32:64], pat32) || !bytes.Equal(chip.Data[9][:32], make([]byte, 32)) {
		t.Fatalf("slot 9: % x", chip.Data[9][:64])
	}
	if !bytes.Equal(chip.Data[8][2*32+5*4:2*32+6*4], pat4) {
		t.Fatalf("slot 8 block 2 word 5: % x", chip.Data[8][64:96])
	}
	for s := 0; s < 16; s++ {
		if s != 8 && s != 9 && !bytes.Equal(chip.Data[s], make([]byte, len(chip.Data[s]))) {
			t.Errorf("slot %d written", s)
		}
	}
}

// A count byte below 4 is a framing error, not a panic or a short read.
func TestZeroCountByte(t *testing.T) {
	d, chip, _ := newDev(t)
	chip.ZeroCountNext = true
	err := d.Do(func(s *se608.Session) error { _, err := s.Revision(); return err })
	if !errors.Is(err, se608.ErrComm) {
		t.Fatalf("err = %v, want ErrComm", err)
	}
}

// The image write is split so no sequence can outlast the watchdog; the fake's watchdog is the control that a
// single long sequence would fail (TestWatchdogControl).
func TestWatchdogControl(t *testing.T) {
	d, chip, _ := newDev(t)
	err := d.Do(func(s *se608.Session) error {
		for i := 0; i < 23; i++ {
			if err := s.Write(se608.ZoneConfig, 22, []byte{0xFF, 0xFF, 0, 0}); err != nil {
				return err
			}
		}
		return nil
	})
	if !errors.Is(err, se608.ErrNoResponse) {
		t.Fatalf("23 writes in one wake: err = %v, want ErrNoResponse (watchdog)", err)
	}
	// Every image word differs from the chip, so all 23 are written: chunked, they stay under the watchdog.
	for _, w := range se608.ImageWords() {
		copy(chip.Config[4*w:4*w+4], []byte{0xEE, 0xEE, 0xEE, 0xEE})
	}
	n := len(chip.Ops)
	if _, err := d.WriteConfigImage(se608.Image(true, 0x3B)); err != nil {
		t.Fatalf("chunked image write: %v", err)
	}
	writes := 0
	for _, op := range chip.Ops[n:] {
		if op == se608.OpWrite {
			writes++
		}
	}
	if writes != 23 {
		t.Fatalf("%d writes, want 23", writes)
	}
}

func TestWriteOTPRefused(t *testing.T) {
	d, chip, _ := newDev(t)
	err := d.Do(func(s *se608.Session) error { return s.Write(se608.ZoneOTP, 0, make([]byte, 4)) })
	if !errors.Is(err, se608.ErrRefused) || len(chip.Ops) != 0 {
		t.Fatalf("OTP write: %v, ops % x", err, chip.Ops)
	}
}

// A reply shorter than the command's data is a framing error, not zeros.
func TestRespLenMismatch(t *testing.T) {
	d, _, _ := newDev(t)
	err := d.Do(func(s *se608.Session) error {
		_, err := s.Exec(se608.Cmd{Op: se608.OpRead, P1: 0x00, P2: 0, RespLen: 32, MaxExec: time.Millisecond})
		return err
	})
	if !errors.Is(err, se608.ErrComm) {
		t.Fatalf("4-byte reply to a 32-byte read: %v, want ErrComm", err)
	}
}

// Any lock byte but 0x55 counts as locked.
func TestConfigLockedAnyNon55(t *testing.T) {
	for _, v := range []byte{0x00, 0xAA, 0x54, 0xFF} {
		var c [se608.ConfigLen]byte
		c[se608.LockConfigByte] = v
		if !se608.ConfigLocked(c) {
			t.Errorf("byte 87 = %#x reported unlocked", v)
		}
	}
	d, chip, _ := newDev(t)
	chip.Config[se608.LockConfigByte] = 0xAA
	if _, err := d.WriteConfigImage(se608.Image(true, 0)); err == nil {
		t.Fatal("wrote with byte 87 = 0xAA")
	}
}

// A second image write sends nothing (only differing words are written), and word 4 goes last.
func TestImageRewriteOnlyDiffers(t *testing.T) {
	d, chip, _ := newDev(t)
	img := se608.Image(true, chip.Config[17])
	img[19] = 0x01 // make word 4 differ from the blank chip, so its position is visible
	if _, err := d.WriteConfigImage(img); err != nil {
		t.Fatal(err)
	}
	var lastWrite []byte
	for _, p := range chip.Pkts {
		if p[1] == se608.OpWrite {
			lastWrite = p
		}
	}
	if lastWrite == nil || lastWrite[3] != 4 {
		t.Fatalf("last write packet % x, want word 4", lastWrite)
	}
	n := len(chip.Ops)
	if _, err := d.WriteConfigImage(img); err != nil {
		t.Fatal(err)
	}
	for _, op := range chip.Ops[n:] {
		if op == se608.OpWrite {
			t.Fatal("rewrite of an equal image sent a Write")
		}
	}
}
