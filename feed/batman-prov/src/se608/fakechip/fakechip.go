// Package fakechip is a stateful ATECC608B stand-in on the se608.Bus interface, for CI and for se-lab's tests
// (255-608b-impl.md §7 "假晶片"). It speaks the byte protocol (wake, word address, count, CRC), so the driver's
// framing is exercised end to end.
//
// PR D models only what E0-E3 need: wake / idle / sleep, Info, Read, Write and Random, the config and data zones,
// and the two lock bytes as state (no Lock command: a test locks the chip by setting the bytes). Behaviour that
// only the datasheet summary stated is now confirmed against a real chip (measured on chip 0123ba99e2ca248cee, 2026-11-27 (E1-E3 on the rig; results in docs/design/255-608b-config.md §8.3)):
// a data-zone write before the config lock is refused with 0x0F, and Random returns the fixed test pattern.
package fakechip

import (
	"crypto/rand"
	"errors"
	"sync"
	"time"

	"batman-prov/se608"
)

// ErrNACK is what the bus returns when no device acknowledges.
var ErrNACK = errors.New("fakechip: NACK")

// Blank is the made-up blank config zone of a fresh chip. Serial bytes 0-3 and 8-12 are not a real chip's; byte
// 13 (AES_Enable) and byte 17 are placeholders until E1 reads real ones.
func Blank() [se608.ConfigLen]byte {
	var c [se608.ConfigLen]byte
	copy(c[0:4], []byte{0x01, 0x23, 0x9A, 0x4C})
	copy(c[4:8], se608.Rev608B[:])
	copy(c[8:13], []byte{0x5E, 0x21, 0x07, 0x42, 0xEE})
	c[13] = 0x01 // AES_Enable (placeholder)
	c[14] = 0x01 // I2C_Enable
	c[16] = 0xC0
	// The real blank chip reads 0x00 here (measured on chip 0123ba99e2ca248cee, 2026-11-27 (E1-E3 on the rig; results in docs/design/255-608b-config.md §8.3)). The fake keeps a non-zero
	// placeholder on purpose: it is what makes a dropped or wrong byte 17 visible in the tests.
	c[17] = 0x3B
	c[se608.LockDataByte] = 0x55
	c[se608.LockConfigByte] = 0x55
	c[88], c[89] = 0xFF, 0xFF
	return c
}

var slotSize = [16]int{36, 36, 36, 36, 36, 36, 36, 36, 416, 72, 72, 72, 72, 72, 72, 72}

// Chip is one fake device at se608.Addr. Exported fields are test knobs; read them under no concurrent use.
type Chip struct {
	mu     sync.Mutex
	Config [se608.ConfigLen]byte
	Data   [16][]byte

	// BusyPolls: after each command, NACK this many reads before the response is ready.
	BusyPolls int
	// DropWakes: the next N wake pulses are ignored (the chip stays asleep: "N times no response, then recover").
	DropWakes int
	// CorruptNext: flip a bit in the next response's CRC.
	CorruptNext bool
	// ZeroCountNext: the next response's count byte reads 0x00.
	ZeroCountNext bool
	// Watchdog: the chip falls asleep when the worst-case times of the commands since the wake add up to more than
	// this. Default 700 ms: well under the nominal 1.3 s (F§9), so a sequence passes only with margin. The fake charges each command its datasheet maximum plus the driver's 20 ms polling
	// margin, not real time, so a sequence that could outlast the watchdog on a slow chip fails here.
	Watchdog time.Duration

	// Ops records every opcode the chip received, in order, and Pkts the packets (count .. CRC); Wakes counts wake
	// pulses that woke it.
	Ops   []byte
	Pkts  [][]byte
	Wakes int

	awake bool
	out   []byte
	busy  int
	spent time.Duration
}

var cost = map[byte]time.Duration{se608.OpInfo: 5 * time.Millisecond, se608.OpRead: 5 * time.Millisecond,
	se608.OpWrite: 45 * time.Millisecond, se608.OpRandom: 23 * time.Millisecond}

// New returns a blank, unlocked chip.
func New() *Chip {
	c := &Chip{Config: Blank(), Watchdog: 700 * time.Millisecond}
	for i := range c.Data {
		c.Data[i] = make([]byte, slotSize[i])
	}
	return c
}

// LockConfigForTest sets the config lock byte (there is no Lock command in PR D).
func (c *Chip) LockConfigForTest() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.Config[se608.LockConfigByte] = 0x00
}

func (c *Chip) configLocked() bool { return c.Config[se608.LockConfigByte] != 0x55 }

// Write implements se608.Bus.
func (c *Chip) Write(addr uint16, p []byte) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if addr == 0x00 {
		// The general-call pulse. No device ACKs it; it wakes a sleeping chip and leaves an awake one alone.
		if !c.awake {
			if c.DropWakes > 0 {
				c.DropWakes--
			} else {
				c.awake = true
				c.Wakes++
				c.out = status(0x11)
				c.busy = 0
				c.spent = 0
			}
		}
		return ErrNACK
	}
	if addr != se608.Addr || !c.awake || len(p) == 0 {
		return ErrNACK
	}
	switch p[0] {
	case 0x00: // reset the I/O buffer
		c.out = nil
	case 0x01, 0x02: // sleep, idle
		c.awake = false
		c.out = nil
	case 0x03:
		if len(p) > 2 {
			c.spent += cost[p[2]] + 20*time.Millisecond // + the driver's polling margin: the worst a sequence may last
		}
		if c.spent > c.Watchdog {
			c.awake = false // the watchdog put it to sleep: this command is lost
			c.out = nil
			return nil
		}
		c.out = c.command(p[1:])
		c.busy = c.BusyPolls
		if c.CorruptNext && len(c.out) > 0 {
			c.out[len(c.out)-1] ^= 0x01
			c.CorruptNext = false
		}
		if c.ZeroCountNext && len(c.out) > 0 {
			c.out[0] = 0x00
			c.ZeroCountNext = false
		}
	default:
		return ErrNACK
	}
	return nil
}

// Read implements se608.Bus. It hands out the output buffer front to back across reads, as the chip does.
func (c *Chip) Read(addr uint16, p []byte) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if addr != se608.Addr || !c.awake {
		return ErrNACK
	}
	if c.busy > 0 {
		c.busy--
		return ErrNACK
	}
	for i := range p {
		if len(c.out) > 0 {
			p[i] = c.out[0]
			c.out = c.out[1:]
		} else {
			p[i] = 0xFF
		}
	}
	return nil
}

func respond(data []byte) []byte {
	b := append([]byte{byte(len(data) + 3)}, data...)
	crc := se608.CRC(b)
	return append(b, byte(crc), byte(crc>>8))
}

func status(code byte) []byte { return respond([]byte{code}) }

// command parses count .. CRC and runs it.
func (c *Chip) command(pkt []byte) []byte {
	if len(pkt) < 7 || int(pkt[0]) != len(pkt) {
		return status(0xFF)
	}
	n := len(pkt) - 2
	crc := se608.CRC(pkt[:n])
	if pkt[n] != byte(crc) || pkt[n+1] != byte(crc>>8) {
		return status(0xFF)
	}
	op, p1 := pkt[1], pkt[2]
	p2 := uint16(pkt[3]) | uint16(pkt[4])<<8
	data := pkt[5:n]
	c.Ops = append(c.Ops, op)
	c.Pkts = append(c.Pkts, append([]byte(nil), pkt...))
	switch op {
	case se608.OpInfo:
		if p1 != 0x00 || len(data) != 0 {
			return status(0x03)
		}
		return respond(c.Config[4:8])
	case se608.OpRead:
		return c.read(p1, p2, data)
	case se608.OpWrite:
		return c.write(p1, p2, data)
	case se608.OpRandom:
		if len(data) != 0 {
			return status(0x03)
		}
		out := make([]byte, 32)
		if !c.configLocked() {
			// Confirmed on a real chip: before the config lock Random returns a fixed test pattern (F§12).
			for i := 0; i < 32; i += 4 {
				out[i], out[i+1] = 0xFF, 0xFF
			}
		} else {
			_, _ = rand.Read(out)
		}
		return respond(out)
	}
	return status(0x03)
}

func size(p1 byte) int {
	if p1&0x80 != 0 {
		return 32
	}
	return 4
}

// configOff maps a config/OTP word address to a byte offset (block<<3 | word; a 32-byte access needs word 0).
func configOff(p2 uint16, n int, zoneLen int) (int, bool) {
	block, word := int(p2>>3)&0x1F, int(p2&7)
	if n == 32 && word != 0 {
		return 0, false
	}
	off := block*32 + word*4
	return off, off+n <= zoneLen
}

// dataOff maps a data-zone address (slot<<3 | block<<8 | word) to a slot and offset.
func dataOff(p2 uint16, n int) (slot, off int, ok bool) {
	slot, block, word := int(p2>>3)&0xF, int(p2>>8), int(p2&7)
	if n == 32 && word != 0 {
		return 0, 0, false
	}
	off = block*32 + word*4
	return slot, off, off+n <= slotSize[slot]
}

func (c *Chip) read(p1 byte, p2 uint16, data []byte) []byte {
	n := size(p1)
	if len(data) != 0 || p1&0x7C != 0 {
		return status(0x03)
	}
	switch p1 & 0x03 {
	case byte(se608.ZoneConfig):
		off, ok := configOff(p2, n, se608.ConfigLen)
		if !ok {
			return status(0x03)
		}
		return respond(c.Config[off : off+n])
	case byte(se608.ZoneData):
		// Data-zone reads are refused until the zones are locked (datasheet summary; the write side was confirmed).
		if !c.configLocked() || c.Config[se608.LockDataByte] == 0x55 {
			return status(0x0F)
		}
		slot, off, ok := dataOff(p2, n)
		if !ok {
			return status(0x03)
		}
		return respond(c.Data[slot][off : off+n])
	}
	return status(0x03)
}

func (c *Chip) write(p1 byte, p2 uint16, data []byte) []byte {
	n := size(p1)
	if len(data) != n || p1&0x3C != 0 || p1&0x40 != 0 {
		return status(0x03)
	}
	switch p1 & 0x03 {
	case byte(se608.ZoneConfig):
		if c.configLocked() {
			return status(0x0F)
		}
		off, ok := configOff(p2, n, se608.ConfigLen)
		if !ok {
			return status(0x03)
		}
		// Bytes 0-15 and 84-87 cannot be written with Write (datasheet summary; E3 never wrote them, so untested).
		if off < 16 || (off < 88 && off+n > 84) {
			return status(0x0F)
		}
		copy(c.Config[off:], data)
		return status(0x00)
	case byte(se608.ZoneData):
		// Confirmed on a real chip: a data write before the config lock is refused with 0x0F.
		if !c.configLocked() {
			return status(0x0F)
		}
		slot, off, ok := dataOff(p2, n)
		if !ok {
			return status(0x03)
		}
		copy(c.Data[slot][off:], data)
		return status(0x00)
	}
	return status(0x03)
}
