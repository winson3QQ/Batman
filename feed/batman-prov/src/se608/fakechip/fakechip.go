// Package fakechip is a stateful ATECC608B stand-in on the se608.Bus interface, for CI and for se-lab's tests
// (255-608b-impl.md §4.4 "假晶片"). It speaks the byte protocol (wake, word address, count, CRC), so the driver's
// framing is exercised end to end.
//
// It models: wake / idle / sleep and the watchdog; the config, data and OTP zones; the config lock, the data lock
// and the per-slot locks, with the chip's CRC checks; real P-256 keys (GenKey, clear PrivWrite, external Sign,
// ECDH); CheckMac with a real comparison; TempKey with its NoMac flag (Nonce, GenDig, MAC); the two counters;
// UpdateExtra. SHA, AES and KDF are not modelled (parse error): se-lab's tests check only the packets it sends for
// those.
//
// Where the behaviour comes from. Confirmed on a real chip (0123ba99e2ca248cee, 2026-11-27, 255-608b-config.md
// §8.3): a data-zone write before the config lock is refused with 0x0F; Random returns the fixed test pattern
// before the config lock; a config image written word by word reads back equal. Everything about the locks, keys,
// CheckMac, MAC, GenDig, counters and UpdateExtra is from the documents (255-reviews/608b-facts.md) and
// cryptoauthlib's host-side code: it is what E4-E17 are expected to show, not what they have shown. A rule marked
// "inferred" below has no direct statement behind it at all. Also assumed, with no source: a blank data zone and
// OTP zone read as zeros, and a Lock with a wrong CRC answers 0x0F. The fake checks a Lock's CRC with the driver's
// own se608.CRC, so it cannot catch a CRC bug: the golden vector from the real chip's bytes does
// (se608 TestChip1LockPacketGolden).
package fakechip

import (
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"errors"
	"sync"
	"time"

	"batman-prov/se608"
)

// ErrNACK is what the bus returns when no device acknowledges.
var ErrNACK = errors.New("fakechip: NACK")

// Blank is the made-up blank config zone of a fresh chip. Serial bytes 0-3 and 8-12 are not a real chip's.
func Blank() [se608.ConfigLen]byte {
	var c [se608.ConfigLen]byte
	copy(c[0:4], []byte{0x01, 0x23, 0x9A, 0x4C})
	copy(c[4:8], se608.Rev608B[:])
	copy(c[8:13], []byte{0x5E, 0x21, 0x07, 0x42, 0xEE})
	c[13] = 0x01 // AES_Enable (the real blank chip reads 0x61)
	c[14] = 0x01 // I2C_Enable
	c[16] = 0xC0
	// The real blank chip reads 0x00 here (255-608b-config.md §8.3). The fake keeps a non-zero placeholder on
	// purpose: it is what makes a dropped or wrong byte 17 visible in the tests.
	c[17] = 0x3B
	c[se608.LockDataByte] = 0x55
	c[se608.LockConfigByte] = 0x55
	c[88], c[89] = 0xFF, 0xFF
	return c
}

// RealBlank is the config zone read from the first real blank ATECC608B-SSHDA-B before anything was written
// (E1, 2026-11-27, 255-608b-config.md §8.3; raw output in the rig results, e1-dump.txt).
func RealBlank() [se608.ConfigLen]byte {
	return [se608.ConfigLen]byte{
		0x01, 0x23, 0xba, 0x99, 0x00, 0x00, 0x60, 0x03, 0xe2, 0xca, 0x24, 0x8c, 0xee, 0x61, 0x19, 0x00,
		0xc0, 0x00, 0x00, 0x00, 0x83, 0x20, 0x87, 0x20, 0x8f, 0x20, 0xc4, 0x8f, 0x8f, 0x8f, 0x8f, 0x8f,
		0x9f, 0x8f, 0xaf, 0x8f, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
		0x00, 0x00, 0xaf, 0x8f, 0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff,
		0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
		0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x55, 0x55, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
		0x33, 0x00, 0x33, 0x00, 0x33, 0x00, 0x1c, 0x00, 0x1c, 0x00, 0x1c, 0x00, 0x1c, 0x00, 0x1c, 0x00,
		0x3c, 0x00, 0x3c, 0x00, 0x3c, 0x00, 0x3c, 0x00, 0x3c, 0x00, 0x3c, 0x00, 0x3c, 0x00, 0x1c, 0x00,
	}
}

// CounterMax is the highest value a counter reaches (F§7).
const CounterMax = 2097151

// Chip is one fake device at se608.Addr. Exported fields are test knobs; read them under no concurrent use.
type Chip struct {
	mu     sync.Mutex
	Config [se608.ConfigLen]byte
	Data   [16][]byte
	OTP    [se608.OTPLen]byte
	// Keys holds the private key of each slot that has one (GenKey or PrivWrite).
	Keys     [16]*ecdsa.PrivateKey
	Counters [2]uint32

	// BusyPolls: after each command, NACK this many reads before the response is ready.
	BusyPolls int
	// DropWakes: the next N wake pulses are ignored (the chip stays asleep: "N times no response, then recover").
	DropWakes int
	// CorruptNext: flip a bit in the next response's CRC.
	CorruptNext bool
	// ZeroCountNext: the next response's count byte reads 0x00.
	ZeroCountNext bool
	// OTPReadOnly: the OTP zone refuses writes between the config lock and the data lock (the other reading of
	// F§16 U13; E5 settles which one the real chip is).
	OTPReadOnly bool
	// LockLies: Lock answers success but locks nothing (a chip or bus fault no document describes: the tool must
	// believe the chip's lock bytes, not the status).
	LockLies bool
	// SecretTailReadOnly: a 4-byte write to a slot with IsSecret set is refused. facts §2.1 (from the 508A table)
	// says IsSecret prohibits 4-byte reads and writes; whether that holds in the window between the two locks — where
	// "most write restrictions are ignored" — no source says, and the default fake accepts it. So fill-data passing
	// on the default fake says nothing about E6; this knob is the other answer (code review PR D2 A-m12).
	SecretTailReadOnly bool
	// LockThenRefuse: a Lock locks and still answers 0x0F (a chip or bus fault no document describes: the tool must
	// report what the bytes say, not only the status).
	LockThenRefuse bool
	// SlowLockPolls: a Lock, Counter increment or UpdateExtra is executed at once but its answer is ready only after this many
	// NACKed reads (the 608B's timing of these is not the table's, F§14.15).
	SlowLockPolls int
	// Watchdog: the chip falls asleep when the worst-case times of the commands since the wake add up to more than
	// this. Default 700 ms: well under the nominal 1.3 s (F§9), so a sequence passes only with margin. The fake
	// charges each command its cap plus the driver's 20 ms polling margin, not real time, so a sequence that could
	// outlast the watchdog on a slow chip fails here.
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
	tk    tempKey
}

// tempKey is the chip's volatile register: kept across idle, lost on sleep and when the watchdog fires.
type tempKey struct {
	v      [32]byte
	valid  bool
	random bool // made by a random Nonce (SourceFlag 0); false = pass-through input
	noMac  bool // a NoMac slot went into it through GenDig: MAC must refuse it
}

// New returns a blank, unlocked chip.
func New() *Chip {
	c := &Chip{Config: Blank(), Watchdog: 700 * time.Millisecond}
	for i := range c.Data {
		c.Data[i] = make([]byte, se608.SlotSize[i])
	}
	return c
}

// LockConfigForTest sets the config lock byte without a Lock command.
func (c *Chip) LockConfigForTest() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.Config[se608.LockConfigByte] = 0x00
}

func (c *Chip) configLocked() bool { return c.Config[se608.LockConfigByte] != 0x55 }
func (c *Chip) dataLocked() bool   { return c.Config[se608.LockDataByte] != 0x55 }

func (c *Chip) slotCfg(i int) uint16  { return uint16(c.Config[20+2*i]) | uint16(c.Config[21+2*i])<<8 }
func (c *Chip) keyCfg(i int) uint16   { return uint16(c.Config[96+2*i]) | uint16(c.Config[97+2*i])<<8 }
func (c *Chip) private(i int) bool    { return c.keyCfg(i)&0x0001 != 0 }
func (c *Chip) lockable(i int) bool   { return c.keyCfg(i)&0x0020 != 0 }
func (c *Chip) readKey(i int) uint16  { return c.slotCfg(i) & 0x000F }
func (c *Chip) noMac(i int) bool      { return c.slotCfg(i)&0x0010 != 0 }
func (c *Chip) secret(i int) bool     { return c.slotCfg(i)&0x0080 != 0 }
func (c *Chip) writeCfg(i int) uint16 { return c.slotCfg(i) >> 12 }
func (c *Chip) slotLocked(i int) bool { return c.Config[88+i/8]>>(i%8)&1 == 0 }

func (c *Chip) sn() [9]byte { return se608.Serial(c.Config) }

func (c *Chip) sleepNow() {
	c.awake = false
	c.out = nil
	c.tk = tempKey{}
}

// Write implements se608.Bus.
func (c *Chip) Write(addr uint16, p []byte) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if addr == 0x00 {
		// The general-call pulse. The chip does not ACK it; it wakes a sleeping or idle chip and leaves an awake
		// one alone.
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
	case 0x01: // sleep: TempKey is lost
		c.sleepNow()
	case 0x02: // idle: TempKey is kept (F§9)
		c.awake = false
		c.out = nil
	case 0x03:
		if len(p) > 3 {
			c.spent += charge(p[2], p[3]) + 20*time.Millisecond // + the driver's polling margin
		}
		if c.spent > c.Watchdog {
			c.sleepNow() // the watchdog put it to sleep: this command is lost
			return nil
		}
		c.out = c.command(p[1:])
		c.busy = c.BusyPolls
		if len(p) > 3 && (p[2] == se608.OpLock || (p[2] == se608.OpCounter && p[3]&1 != 0) || p[2] == se608.OpUpdateExtra) && c.SlowLockPolls > 0 {
			c.busy = c.SlowLockPolls
		}
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

// charge is the worst case the driver may spend on one command: the vendor table, except for the three commands
// that cannot be undone, which the driver polls for up to se608.LockPoll / ForGoodPoll (code review PR D2 round 2
// A-N-m2: a burn sequence of GenKey + Lock(slot) that fits the table but not the real wait must fail here).
func charge(op, p1 byte) time.Duration {
	switch {
	case op == se608.OpLock:
		return se608.LockPoll
	case op == se608.OpUpdateExtra, op == se608.OpCounter && p1&1 != 0:
		return se608.ForGoodPoll
	}
	return se608.MaxExec(op)
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

const (
	stOK       = 0x00
	stMiscomp  = 0x01
	stParse    = 0x03
	stExec     = 0x0F
	stCommFail = 0xFF
)

// command parses count .. CRC and runs it.
func (c *Chip) command(pkt []byte) []byte {
	if len(pkt) < 7 || int(pkt[0]) != len(pkt) {
		return status(stCommFail)
	}
	n := len(pkt) - 2
	crc := se608.CRC(pkt[:n])
	if pkt[n] != byte(crc) || pkt[n+1] != byte(crc>>8) {
		return status(stCommFail)
	}
	op, p1 := pkt[1], pkt[2]
	p2 := uint16(pkt[3]) | uint16(pkt[4])<<8
	data := pkt[5:n]
	c.Ops = append(c.Ops, op)
	c.Pkts = append(c.Pkts, append([]byte(nil), pkt...))
	switch op {
	case se608.OpInfo:
		if p1 != 0x00 || len(data) != 0 {
			return status(stParse)
		}
		return respond(c.Config[4:8])
	case se608.OpRead:
		return c.read(p1, p2, data)
	case se608.OpWrite:
		return c.write(p1, p2, data)
	case se608.OpRandom:
		if len(data) != 0 {
			return status(stParse)
		}
		return respond(c.random())
	case se608.OpLock:
		return c.lock(p1, p2, data)
	case se608.OpNonce:
		return c.nonce(p1, data)
	case se608.OpGenKey:
		return c.genKey(p1, p2, data)
	case se608.OpPrivWrite:
		return c.privWrite(p1, p2, data)
	case se608.OpSign:
		return c.sign(p1, p2, data)
	case se608.OpECDH:
		return c.ecdh(p1, p2, data)
	case se608.OpCheckMac:
		return c.checkMac(p1, p2, data)
	case se608.OpMAC:
		return c.mac(p1, p2, data)
	case se608.OpGenDig:
		return c.genDig(p1, p2, data)
	case se608.OpCounter:
		return c.counter(p1, p2, data)
	case se608.OpUpdateExtra:
		return c.updateExtra(p1, p2, data)
	}
	return status(stParse) // SHA, AES, KDF and the rest: not modelled
}

// random: confirmed on a real chip — before the config lock Random returns a fixed test pattern (F§12).
func (c *Chip) random() []byte {
	out := make([]byte, 32)
	if !c.configLocked() {
		for i := 0; i < 32; i += 4 {
			out[i], out[i+1] = 0xFF, 0xFF
		}
	} else {
		_, _ = rand.Read(out)
	}
	return out
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
	return slot, off, off+n <= se608.SlotSize[slot]
}

func (c *Chip) read(p1 byte, p2 uint16, data []byte) []byte {
	n := size(p1)
	if len(data) != 0 || p1&0x7C != 0 {
		return status(stParse)
	}
	switch p1 & 0x03 {
	case byte(se608.ZoneConfig):
		off, ok := configOff(p2, n, se608.ConfigLen)
		if !ok {
			return status(stParse)
		}
		return respond(c.Config[off : off+n])
	case byte(se608.ZoneOTP):
		if !c.dataLocked() {
			return status(stExec)
		}
		off, ok := configOff(p2, n, se608.OTPLen)
		if !ok {
			return status(stParse)
		}
		return respond(c.OTP[off : off+n])
	case byte(se608.ZoneData):
		// Nothing in the data zone can be read until both zones are locked (F§1.3).
		if !c.configLocked() || !c.dataLocked() {
			return status(stExec)
		}
		slot, off, ok := dataOff(p2, n)
		if !ok {
			return status(stParse)
		}
		if c.private(slot) || c.secret(slot) {
			return status(stExec) // IsSecret with no encrypted read: never readable
		}
		return respond(c.Data[slot][off : off+n])
	}
	return status(stParse)
}

func (c *Chip) write(p1 byte, p2 uint16, data []byte) []byte {
	n := size(p1)
	if len(data) != n || p1&0x3C != 0 || p1&0x40 != 0 {
		return status(stParse)
	}
	switch p1 & 0x03 {
	case byte(se608.ZoneConfig):
		if c.configLocked() {
			return status(stExec)
		}
		off, ok := configOff(p2, n, se608.ConfigLen)
		if !ok {
			return status(stParse)
		}
		// Bytes 0-15 and 84-87 cannot be written with Write (datasheet summary; E3 never wrote them, so untested).
		if off < 16 || (off < 88 && off+n > 84) {
			return status(stExec)
		}
		copy(c.Config[off:], data)
		return status(stOK)
	case byte(se608.ZoneOTP):
		if !c.configLocked() || c.dataLocked() || c.OTPReadOnly {
			return status(stExec)
		}
		off, ok := configOff(p2, n, se608.OTPLen)
		if !ok {
			return status(stParse)
		}
		copy(c.OTP[off:], data)
		return status(stOK)
	case byte(se608.ZoneData):
		// Confirmed on a real chip: a data write before the config lock is refused with 0x0F.
		if !c.configLocked() {
			return status(stExec)
		}
		slot, off, ok := dataOff(p2, n)
		if !ok {
			return status(stParse)
		}
		// A slot-locked slot cannot be written even while the data zone is unlocked; a private-key slot is never
		// written with Write (F§1.3, §10).
		if c.slotLocked(slot) || c.private(slot) {
			return status(stExec)
		}
		if c.SecretTailReadOnly && n == 4 && c.secret(slot) {
			return status(stExec)
		}
		// After the data lock the slot's WriteConfig decides: only "Always" (0) takes a clear write.
		if c.dataLocked() && c.writeCfg(slot) != 0 {
			return status(stExec)
		}
		copy(c.Data[slot][off:], data)
		return status(stOK)
	}
	return status(stParse)
}

// dataSummary is what the chip CRCs for Lock(data): the slots in order, private-key slots skipped, then OTP
// (F§1.3). Written here on its own, not through se608.DataCRC, so the driver's function is checked against it.
func (c *Chip) dataSummary() []byte {
	var all []byte
	for i := range c.Data {
		if !c.private(i) {
			all = append(all, c.Data[i]...)
		}
	}
	return append(all, c.OTP[:]...)
}

func (c *Chip) lock(p1 byte, p2 uint16, data []byte) []byte {
	if len(data) != 0 || p1&0x40 != 0 {
		return status(stParse)
	}
	noCRC := p1&0x80 != 0 // the real chip honours it; the driver must never send it
	if c.LockLies {
		return status(stOK)
	}
	if c.LockThenRefuse {
		c.LockThenRefuse = false
		c.lock(p1, p2, data)  // locks if the Lock itself is valid ...
		return status(stExec) // ... and answers an error either way
	}
	switch p1 & 0x03 {
	case 0x00:
		if p1&0x3C != 0 {
			return status(stParse)
		}
		if c.configLocked() || (!noCRC && se608.CRC(c.Config[:]) != p2) {
			return status(stExec)
		}
		c.Config[se608.LockConfigByte] = 0x00
		return status(stOK)
	case 0x01:
		if p1&0x3C != 0 {
			return status(stParse)
		}
		if !c.configLocked() || c.dataLocked() || (!noCRC && se608.CRC(c.dataSummary()) != p2) {
			return status(stExec)
		}
		c.Config[se608.LockDataByte] = 0x00
		return status(stOK)
	case 0x02:
		slot := int(p1>>2) & 0x0F
		// Inferred: a slot lock needs the config zone locked (the Lockable bits are only fixed then), and is
		// possible before the data lock. se-lab does not rely on the second half: it refuses lock-slot until both
		// zones are locked.
		if !c.configLocked() || !c.lockable(slot) || c.slotLocked(slot) {
			return status(stExec)
		}
		c.Config[88+slot/8] &^= 1 << (slot % 8)
		return status(stOK)
	}
	return status(stParse)
}

func (c *Chip) nonce(p1 byte, data []byte) []byte {
	switch p1 {
	case 0x03: // pass-through to TempKey
		if len(data) != 32 {
			return status(stParse)
		}
		c.tk = tempKey{valid: true}
		copy(c.tk.v[:], data)
		return status(stOK)
	case 0x00, 0x01: // random: TempKey = SHA-256(RandOut ‖ NumIn ‖ 0x16 ‖ mode ‖ 0x00)
		if len(data) != 20 {
			return status(stParse)
		}
		r := c.random()
		m := append(append(append([]byte{}, r...), data...), se608.OpNonce, p1, 0x00)
		c.tk = tempKey{v: sha256.Sum256(m), valid: true, random: true}
		return respond(r)
	}
	return status(stParse)
}

func pubBytes(k *ecdsa.PrivateKey) []byte {
	b, err := k.PublicKey.Bytes()
	if err != nil || len(b) != 65 {
		panic("fakechip: public key encoding")
	}
	return b[1:]
}

func (c *Chip) genKey(p1 byte, p2 uint16, data []byte) []byte {
	slot := int(p2)
	if len(data) != 0 || slot > 15 {
		return status(stParse)
	}
	switch p1 {
	case se608.GenKeyCreate:
		// GenKey always errors before the config lock; a slot-locked slot is frozen; after the data lock the slot
		// needs SlotConfig bit 13 (F§1.3, §3, §10).
		if !c.configLocked() || !c.private(slot) || c.slotLocked(slot) {
			return status(stExec)
		}
		if c.dataLocked() && c.writeCfg(slot)&0x2 == 0 {
			return status(stExec)
		}
		k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		if err != nil {
			return status(stExec)
		}
		c.Keys[slot] = k
		return respond(pubBytes(k))
	case se608.GenKeyPublic:
		if !c.private(slot) || c.Keys[slot] == nil {
			return status(stExec)
		}
		return respond(pubBytes(c.Keys[slot]))
	}
	return status(stParse)
}

func (c *Chip) privWrite(p1 byte, p2 uint16, data []byte) []byte {
	slot := int(p2)
	if slot > 15 || len(data) != 68 {
		return status(stParse)
	}
	// Only the clear form is modelled: allowed between the config lock and the data lock (F§10). After the data
	// lock a clear PrivWrite always fails; the encrypted form needs SlotConfig bit 14, which our images never set.
	if p1 != 0x00 || !c.configLocked() || c.dataLocked() || !c.private(slot) || c.slotLocked(slot) {
		return status(stExec)
	}
	if data[0]|data[1]|data[2]|data[3] != 0 {
		return status(stParse)
	}
	k, err := ecdsa.ParseRawPrivateKey(elliptic.P256(), data[4:36])
	if err != nil {
		return status(stExec)
	}
	c.Keys[slot] = k
	return status(stOK)
}

func (c *Chip) sign(p1 byte, p2 uint16, data []byte) []byte {
	slot := int(p2)
	if len(data) != 0 || slot > 15 {
		return status(stParse)
	}
	if !c.private(slot) || c.Keys[slot] == nil || !c.tk.valid {
		return status(stExec)
	}
	var digest []byte
	switch p1 {
	case se608.SignExternal:
		// ⚠️ Inferred: KeyConfig.ReqRandom does not stop an external Sign of a pass-through TempKey (E14, E17).
		if c.readKey(slot)&0x1 == 0 {
			return status(stExec)
		}
		digest = append([]byte(nil), c.tk.v[:]...)
	case 0x00, 0x40:
		// Internal: never before the data lock (F§10). The signed message is NOT the chip's 55-byte one; no test
		// may depend on its content.
		if c.readKey(slot)&0x2 == 0 || !c.dataLocked() {
			return status(stExec)
		}
		d := sha256.Sum256(append([]byte("fakechip internal sign"), c.tk.v[:]...))
		digest = d[:]
	default:
		return status(stParse)
	}
	c.tk = tempKey{}
	r, s, err := ecdsa.Sign(rand.Reader, c.Keys[slot], digest)
	if err != nil {
		return status(stExec)
	}
	sig := make([]byte, 64)
	r.FillBytes(sig[:32])
	s.FillBytes(sig[32:])
	return respond(sig)
}

func (c *Chip) ecdh(p1 byte, p2 uint16, data []byte) []byte {
	slot := int(p2)
	if len(data) != 64 || slot > 15 {
		return status(stParse)
	}
	if !c.private(slot) || c.Keys[slot] == nil || c.readKey(slot)&0x4 == 0 {
		return status(stExec)
	}
	peer, err := ecdh.P256().NewPublicKey(append([]byte{0x04}, data...))
	if err != nil {
		return status(stExec) // not on the curve
	}
	priv, err := c.Keys[slot].ECDH()
	if err != nil {
		return status(stExec)
	}
	z, err := priv.ECDH(peer)
	if err != nil {
		return status(stExec)
	}
	switch p1 {
	case 0x0C:
		return respond(z)
	case 0x00:
		// The 508A-compatible mode: SlotConfig bit 3 = 0 gives the secret in clear.
		if c.readKey(slot)&0x8 == 0 {
			return respond(z)
		}
		return status(stExec)
	case 0x08:
		c.tk = tempKey{valid: true}
		copy(c.tk.v[:], z)
		return status(stOK)
	case 0x0E:
		// ⚠️ Inferred: with ChipOptions = 0x0000 (no IO protection key) the encrypted output is refused (E10).
		return status(stExec)
	case 0x04:
		// Result written to slot+1: needs SlotConfig bit 3, which our images never set (E9).
		return status(stExec)
	}
	return status(stParse)
}

// macInput is the 88-byte message of MAC and of CheckMac with OtherData = the MAC header (atcah_mac,
// atcah_check_mac): b1 ‖ b2 ‖ hdr[0:4] ‖ 8 zeros ‖ hdr[4:7] ‖ SN[8] ‖ hdr[7:11] ‖ SN[0:2] ‖ hdr[11:13].
func (c *Chip) macInput(b1, b2 []byte, hdr [13]byte) []byte {
	sn := c.sn()
	m := append(append([]byte{}, b1...), b2...)
	m = append(m, hdr[0:4]...)
	m = append(m, make([]byte, 8)...)
	m = append(m, hdr[4:7]...)
	m = append(m, sn[8])
	m = append(m, hdr[7:11]...)
	m = append(m, sn[0], sn[1])
	m = append(m, hdr[11:13]...)
	return m
}

func (c *Chip) checkMac(p1 byte, p2 uint16, data []byte) []byte {
	slot := int(p2)
	if len(data) != 77 || slot > 15 {
		return status(stParse)
	}
	// Only mode 0 is modelled (slot key, ClientChal). NoMac does not stop CheckMac: that is the point of the
	// claim slot. Inferred: the data zone must be locked for the slot to be usable (GenKey in public mode, external
	// Sign and ECDH are not gated on the data lock here; F§10 states it only for Sign).
	if p1 != 0x00 || !c.dataLocked() || c.private(slot) {
		return status(stExec)
	}
	var other [13]byte
	copy(other[:], data[64:77])
	want := sha256.Sum256(c.macInput(c.Data[slot][:32], data[0:32], other))
	if subtle.ConstantTimeCompare(want[:], data[32:64]) != 1 {
		return status(stMiscomp)
	}
	return status(stOK)
}

func (c *Chip) mac(p1 byte, p2 uint16, data []byte) []byte {
	slot := int(p2)
	if p1&^0x47 != 0 || slot > 15 { // the OTP bits (4, 5) are not modelled
		return status(stParse)
	}
	useTK1, useTK2 := p1&0x02 != 0, p1&0x01 != 0
	if (useTK2 && len(data) != 0) || (!useTK2 && len(data) != 32) {
		return status(stParse)
	}
	if !c.dataLocked() {
		return status(stExec)
	}
	var b1, b2 []byte
	if useTK1 || useTK2 {
		// TempKey must be valid, must not carry a NoMac slot, and mode bit 2 must match its source flag
		// (0 = random Nonce, 1 = pass-through).
		if !c.tk.valid || c.tk.noMac || (p1&0x04 != 0) == c.tk.random {
			return status(stExec)
		}
	}
	if useTK1 {
		b1 = c.tk.v[:]
	} else {
		if c.private(slot) || c.noMac(slot) {
			return status(stExec)
		}
		b1 = c.Data[slot][:32]
	}
	if useTK2 {
		b2 = c.tk.v[:]
	} else {
		b2 = data
	}
	hdr := [13]byte{se608.OpMAC, p1, byte(p2), byte(p2 >> 8)}
	if p1&0x40 != 0 {
		sn := c.sn()
		copy(hdr[7:11], sn[4:8])
		copy(hdr[11:13], sn[2:4])
	}
	d := sha256.Sum256(c.macInput(b1, b2, hdr))
	c.tk = tempKey{}
	return respond(d[:])
}

func (c *Chip) genDig(p1 byte, p2 uint16, data []byte) []byte {
	slot := int(p2)
	// Only the data zone is modelled.
	if p1 != 0x02 || slot > 15 {
		return status(stParse)
	}
	nm := c.noMac(slot)
	if (nm && len(data) != 4) || (!nm && len(data) != 0) {
		return status(stParse)
	}
	if !c.dataLocked() || !c.tk.valid || c.private(slot) {
		return status(stExec)
	}
	sn := c.sn()
	m := append([]byte{}, c.Data[slot][:32]...)
	if nm {
		m = append(m, data...)
	} else {
		m = append(m, se608.OpGenDig, p1, byte(p2), byte(p2>>8))
	}
	m = append(m, sn[8], sn[0], sn[1])
	m = append(m, make([]byte, 25)...)
	m = append(m, c.tk.v[:]...)
	c.tk.v = sha256.Sum256(m)
	c.tk.noMac = c.tk.noMac || nm
	return status(stOK)
}

func (c *Chip) counter(p1 byte, p2 uint16, data []byte) []byte {
	if len(data) != 0 || p2 > 1 || p1 > 1 {
		return status(stParse)
	}
	// Inferred: counters need the config zone locked. No authorisation is modelled (F§16 U11; E11 measures it).
	if !c.configLocked() {
		return status(stExec)
	}
	if p1 == 0x01 {
		if c.Counters[p2] >= CounterMax {
			return status(stExec)
		}
		c.Counters[p2]++
	}
	v := c.Counters[p2]
	return respond([]byte{byte(v), byte(v >> 8), byte(v >> 16), byte(v >> 24)})
}

func (c *Chip) updateExtra(p1 byte, p2 uint16, data []byte) []byte {
	if len(data) != 0 {
		return status(stParse)
	}
	switch p1 {
	case 0x00, 0x01:
		// Bytes 84 / 85: anyone on the bus may write each once, while it is still zero (F§9). Inferred: also
		// before the config lock.
		i := 84 + int(p1)
		if c.Config[i] != 0x00 {
			return status(stExec)
		}
		c.Config[i] = byte(p2)
		return status(stOK)
	case 0x02:
		return status(stExec) // the 508A's limited-use decrement: nothing to decrement on our config
	}
	return status(stParse)
}
