package se608

import (
	"bytes"
	"errors"
	"fmt"
	"sync"
	"time"
)

// Addr is the chip's 7-bit I2C address (config byte 16 = 0xC0, 255-608b-config.md §4).
const Addr uint16 = 0x60

// Bus is one I2C master. Write and Read are single transactions to a 7-bit address; a NACK is an error.
type Bus interface {
	Write(addr uint16, p []byte) error
	Read(addr uint16, p []byte) error
}

// Timing. tWHI is cryptoauthlib's default wake delay for the 608; the execution caps are the
// fastest-clock maxima (ChipMode clock divider 0, 255-608b-config.md §4); pollMargin covers the bus.
// Measured on chip 0123ba99e2ca248cee, 2026-11-27 (E1-E3 on the rig): these values worked for Info, Read, Write
// and Random; no command needed a retry and none came near its cap. The caps themselves were not timed.
const (
	tWHI       = 1500 * time.Microsecond
	pollFirst  = 1 * time.Millisecond
	pollEvery  = 1 * time.Millisecond
	pollMargin = 20 * time.Millisecond
	execInfo   = 5 * time.Millisecond
	execRead   = 5 * time.Millisecond
	execWrite  = 45 * time.Millisecond
	execRandom = 23 * time.Millisecond
)

var wakeOK = [4]byte{0x04, 0x11, 0x33, 0x43}

// Dev is one chip on one bus. Do runs one command sequence at a time (the driver's mutex, impl §2.2); across
// processes the chip lock is the exclusive flock OpenI2C takes on the bus device.
type Dev struct {
	bus   Bus
	mu    sync.Mutex
	sleep func(time.Duration)
	now   func() time.Time
}

// New returns a Dev on bus at Addr.
func New(bus Bus) *Dev { return &Dev{bus: bus, sleep: time.Sleep, now: time.Now} }

// SetClock replaces sleep and now (tests with a fake chip).
func (d *Dev) SetClock(sleep func(time.Duration), now func() time.Time) { d.sleep, d.now = sleep, now }

// Session is valid only inside the Do callback that received it.
type Session struct {
	d    *Dev
	done bool
}

// Do wakes the chip, runs fn, and always sends idle afterwards so the watchdog (about 1.3 s, F§9) restarts from the
// next wake. fn should stay well under the watchdog; long work is split over several Do calls.
func (d *Dev) Do(fn func(*Session) error) error {
	d.mu.Lock()
	defer d.mu.Unlock()
	if err := d.wake(); err != nil {
		return err
	}
	s := &Session{d: d}
	err := fn(s)
	s.done = true
	if ierr := d.bus.Write(Addr, []byte{wordIdle}); ierr != nil && err == nil {
		err = fmt.Errorf("%w: idle: %v", ErrNoResponse, ierr)
	}
	return err
}

// wake sends the wake pulse (one byte to the general-call address: at 100 kHz or slower SDA is low for longer
// than tWLO = 60 us; current cryptoauthlib sends 0x01 there, the byte does not reach the chip either way), waits
// tWHI and reads the 4-byte wake response. measured on chip 0123ba99e2ca248cee, 2026-11-27 (E1-E3 on the rig; results in docs/design/255-608b-config.md §8.3): the pulse woke the chip
// and the response was 04 11 33 43 on all three tries. ⚠️ On that rig the same transfer to the general-call address
// returned rc 0; whether a device really ACKs 0x00 or i2ctransfer just does not report the NACK is not settled. A chip that was still awake
// from an interrupted sequence answers with whatever is in its output buffer: then send idle and try once more.
func (d *Dev) wake() error {
	var last []byte
	var lastErr error
	for try := 0; try < 2; try++ {
		_ = d.bus.Write(0x00, []byte{0x00})
		d.sleep(tWHI)
		var r [4]byte
		err := d.bus.Read(Addr, r[:])
		if err == nil && r == wakeOK {
			return nil
		}
		lastErr = err
		if err == nil {
			last = append(last[:0], r[:]...)
		}
		_ = d.bus.Write(Addr, []byte{wordIdle})
		d.sleep(tWHI)
	}
	if lastErr != nil {
		return fmt.Errorf("%w: wake: %v", ErrNoResponse, lastErr)
	}
	if len(last) == 4 && last[0] == 0x04 && crcOK(last) {
		return fmt.Errorf("%w: status 0x%02x (%s)", ErrWake, last[1], StatusName(last[1]))
	}
	return fmt.Errorf("%w: response % x", ErrWake, last)
}

// Exec sends one command and returns its data bytes. Only opcodes in allowedOps are sent.
func (s *Session) Exec(c Cmd) ([]byte, error) {
	if s.done {
		return nil, ErrSession
	}
	if _, ok := allowedOps[c.Op]; !ok {
		return nil, fmt.Errorf("%w: opcode 0x%02x", ErrRefused, c.Op)
	}
	pkt, err := c.encode()
	if err != nil {
		return nil, err
	}
	d := s.d
	if err := d.bus.Write(Addr, pkt); err != nil {
		return nil, fmt.Errorf("%w: send %s: %v", ErrNoResponse, opName(c.Op), err)
	}
	deadline := d.now().Add(c.MaxExec + pollMargin)
	d.sleep(pollFirst)
	var cnt [1]byte
	for {
		err := d.bus.Read(Addr, cnt[:])
		if err == nil {
			break
		}
		if d.now().After(deadline) {
			return nil, fmt.Errorf("%w: %s not done within %v", ErrNoResponse, opName(c.Op), c.MaxExec+pollMargin)
		}
		d.sleep(pollEvery)
	}
	n := int(cnt[0])
	if n < minResp || n > maxResp {
		return nil, fmt.Errorf("%w: count byte %d", ErrComm, n)
	}
	resp := make([]byte, n)
	resp[0] = cnt[0]
	if err := d.bus.Read(Addr, resp[1:]); err != nil {
		return nil, fmt.Errorf("%w: read %s response: %v", ErrNoResponse, opName(c.Op), err)
	}
	data, err := parseResp(resp)
	if err != nil {
		return nil, err
	}
	switch {
	case len(data) == 1 && (c.RespLen != 1 || data[0] != 0x00):
		return nil, &StatusError{Op: c.Op, Code: data[0]}
	case len(data) != c.RespLen:
		return nil, fmt.Errorf("%w: %s returned %d data bytes, want %d", ErrComm, opName(c.Op), len(data), c.RespLen)
	}
	return data, nil
}

// Rev608B is the revision E1 must read; any other value stops the rig work (255-608b-config.md §8.0).
var Rev608B = [4]byte{0x00, 0x00, 0x60, 0x03}

// Revision is Info mode 0x00: 4 bytes, 00 00 60 03 on an ATECC608B (255-608b-config.md §4, E1).
func (s *Session) Revision() ([4]byte, error) {
	var r [4]byte
	data, err := s.Exec(Cmd{Op: OpInfo, P1: 0x00, P2: 0, RespLen: 4, MaxExec: execInfo})
	if err == nil {
		copy(r[:], data)
	}
	return r, err
}

// Read reads 4 or 32 bytes. For the config and OTP zones addr is the word address (block<<3 | word); for the data
// zone it is slot<<3 | block<<8 | word.
func (s *Session) Read(z Zone, addr uint16, n int) ([]byte, error) {
	p1, err := sizeFlag(z, n)
	if err != nil {
		return nil, err
	}
	return s.Exec(Cmd{Op: OpRead, P1: p1, P2: addr, RespLen: n, MaxExec: execRead})
}

// Write writes 4 or 32 plain bytes (no MAC, no encryption) to the config or data zone. The OTP zone is refused in
// PR D: after the data lock an OTP write cannot be undone (code review PR D B-m3).
func (s *Session) Write(z Zone, addr uint16, data []byte) error {
	if z == ZoneOTP {
		return fmt.Errorf("%w: Write to the OTP zone", ErrRefused)
	}
	p1, err := sizeFlag(z, len(data))
	if err != nil {
		return err
	}
	_, err = s.Exec(Cmd{Op: OpWrite, P1: p1, P2: addr, Data: data, RespLen: 1, MaxExec: execWrite})
	return err
}

// Random is the Random command, mode 0 (E2 records it before the config lock: a fixed test pattern, F§12).
func (s *Session) Random() ([]byte, error) {
	return s.Exec(Cmd{Op: OpRandom, P1: 0x00, P2: 0, RespLen: 32, MaxExec: execRandom})
}

func sizeFlag(z Zone, n int) (byte, error) {
	if z > ZoneData {
		return 0, fmt.Errorf("se608: zone %d", z)
	}
	switch n {
	case 4:
		return byte(z), nil
	case 32:
		return byte(z) | zone32, nil
	}
	return 0, fmt.Errorf("se608: %d-byte access (4 or 32 only)", n)
}

// DataAddr is the data-zone address of slot, 32-byte block and 4-byte word.
func DataAddr(slot, block, word int) uint16 { return uint16(slot<<3 | block<<8 | word) }

// ReadConfig reads the whole 128-byte config zone as four 32-byte blocks in one sequence.
func (d *Dev) ReadConfig() ([ConfigLen]byte, error) {
	var cfg [ConfigLen]byte
	err := d.Do(func(s *Session) error {
		for b := 0; b < 4; b++ {
			data, err := s.Read(ZoneConfig, uint16(b)<<3, 32)
			if err != nil {
				return fmt.Errorf("config block %d: %w", b, err)
			}
			copy(cfg[b*32:], data)
		}
		return nil
	})
	return cfg, err
}

// Serial is the 9-byte chip serial: config bytes 0-3 and 8-12.
func Serial(cfg [ConfigLen]byte) [9]byte {
	var sn [9]byte
	copy(sn[:4], cfg[0:4])
	copy(sn[4:], cfg[8:13])
	return sn
}

// Lock bytes (F§1.2): 0x55 = unlocked, 0x00 = locked.
const (
	LockDataByte   = 86
	LockConfigByte = 87
	unlocked       = 0x55
)

// ConfigLocked reports whether byte 87 says the config zone is locked. Anything but 0x55 counts as locked, so a
// write is never attempted on a chip whose lock byte is not the blank value.
func ConfigLocked(cfg [ConfigLen]byte) bool { return cfg[LockConfigByte] != unlocked }

// ImageWords lists the config words (4 bytes each, word w = bytes 4w..4w+3) a bench image writes: 16-51, 68-83
// and 88-127. Not 0-15 (serial, revision: not writable), not 52-67 (the counters: left alone), not 84-87
// (UserExtra, UserExtraAdd and the two lock bytes: Write cannot touch them). 255-608b-config.md §4.
func ImageWords() []int {
	var w []int
	for i := 4; i <= 12; i++ {
		w = append(w, i)
	}
	for i := 17; i <= 20; i++ {
		w = append(w, i)
	}
	for i := 22; i <= 31; i++ {
		w = append(w, i)
	}
	return w
}

// writeOrder is ImageWords with word 4 (I2C address, ChipMode) last: if a changed byte there took effect before
// the lock, it could only cut off the writes after it (still unknown whether it does: measured on chip 0123ba99e2ca248cee, 2026-11-27 (E1-E3 on the rig; results in docs/design/255-608b-config.md §8.3),
// E3 wrote 16 differing words in this order and the read-back matched, so the order is at least safe).
func writeOrder() []int {
	w := ImageWords()
	return append(w[1:], w[0])
}

// wordsPerSeq keeps a sequence of 4-byte writes far below the watchdog: 4 x (45 ms + margin).
const wordsPerSeq = 4

// WriteConfigImage writes the ImageWords of img that differ from the chip with 4-byte writes, a few per sequence,
// word 4 last (an interrupted run re-writes only what is still different). It reads the config zone first and
// refuses a chip whose config zone is locked. It never sends Lock. It returns how many words it wrote (on an
// error: how many of the chunks before the failing one).
func (d *Dev) WriteConfigImage(img [ConfigLen]byte) (int, error) {
	cur, err := d.ReadConfig()
	if err != nil {
		return 0, err
	}
	if ConfigLocked(cur) {
		return 0, fmt.Errorf("se608: config zone is locked (byte 87 = 0x%02x): nothing written", cur[LockConfigByte])
	}
	var words []int
	for _, w := range writeOrder() {
		if !bytes.Equal(cur[4*w:4*w+4], img[4*w:4*w+4]) {
			words = append(words, w)
		}
	}
	for i := 0; i < len(words); i += wordsPerSeq {
		chunk := words[i:min(i+wordsPerSeq, len(words))]
		err := d.Do(func(s *Session) error {
			for _, w := range chunk {
				if err := s.Write(ZoneConfig, uint16(w), img[4*w:4*w+4]); err != nil {
					return fmt.Errorf("config word %d (bytes %d-%d): %w", w, 4*w, 4*w+3, err)
				}
			}
			return nil
		})
		if err != nil {
			return i, err
		}
	}
	return len(words), nil
}

// DiffImage returns the byte offsets inside ImageWords where got differs from img: the E3 read-back rule before
// any lock. The post-burn rule (locked bytes 86-89) is PR 2's.
func DiffImage(got, img [ConfigLen]byte) []int {
	var bad []int
	for _, w := range ImageWords() {
		if bytes.Equal(got[4*w:4*w+4], img[4*w:4*w+4]) {
			continue
		}
		for i := 4 * w; i < 4*w+4; i++ {
			if got[i] != img[i] {
				bad = append(bad, i)
			}
		}
	}
	return bad
}

// IsTransport reports whether err is a bus or framing failure (retry later) rather than the chip's own status.
func IsTransport(err error) bool {
	return errors.Is(err, ErrNoResponse) || errors.Is(err, ErrComm) || errors.Is(err, ErrWake)
}
