package se608

import (
	"errors"
	"fmt"
)

// The commands the product needs beyond Info / Read / Write (impl §2.2). Formats: cryptoauthlib lib/calib at
// d0b9a77 (calib_nonce.c, calib_genkey.c, calib_sign.c, calib_ecdh.c, calib_checkmac.c, calib_lock.c). None of
// these has run on a real chip yet: E4, E6, E17, E8, E10 and E14 are where they first do (255-608b-config.md §8).

// ProvisionalCmds stays true until those experiments have run and their captures are back-filled here: the formats
// of Lock, Nonce, GenKey, Sign, ECDH and CheckMac are the vendor library's, not yet a real chip's. It is separate
// from Provisional (the wake / packet / polling formats, confirmed by E1-E3). PR 2 must not ship a chip image while
// this is set: its CI gets the test that fails on it (impl §2.2; code review PR D2 B-m2).
const ProvisionalCmds = true

// The slots the design gives each role (255-608b-config.md §3).
const (
	SlotSession  = 0 // external sign
	SlotIdentity = 1 // internal sign only; the certificate's subject key
	SlotECDH     = 2
	SlotClaim    = 5 // CheckMac only
	SlotCert     = 8
)

// NoncePassthrough loads 32 bytes into TempKey unchanged (Nonce mode 0x03).
func (s *Session) NoncePassthrough(v [32]byte) error {
	_, err := s.Exec(Cmd{Op: OpNonce, P1: NoncePassthrough, P2: 0, Data: v[:], RespLen: 1, MaxExec: MaxExec(OpNonce)})
	return err
}

// PubKey computes the public key (X ‖ Y, 64 bytes) of the private key in slot (GenKey mode 0x00).
func (s *Session) PubKey(slot int) ([64]byte, error) { return s.genKey(GenKeyPublic, slot) }

// GenKeyCreate generates a new private key in slot and returns its public key (GenKey mode 0x04). Burn mode only.
func (s *Session) GenKeyCreate(slot int) ([64]byte, error) { return s.genKey(GenKeyCreate, slot) }

func (s *Session) genKey(mode byte, slot int) ([64]byte, error) {
	var pub [64]byte
	if err := slotOK(slot); err != nil {
		return pub, err
	}
	d, err := s.Exec(Cmd{Op: OpGenKey, P1: mode, P2: uint16(slot), RespLen: 64, MaxExec: MaxExec(OpGenKey)})
	if err == nil {
		copy(pub[:], d)
	}
	return pub, err
}

// SignExternal signs the 32 bytes in TempKey with the key in slot (Sign mode 0x80) and returns R ‖ S.
func (s *Session) SignExternal(slot int) ([64]byte, error) {
	var sig [64]byte
	if err := slotOK(slot); err != nil {
		return sig, err
	}
	d, err := s.Exec(Cmd{Op: OpSign, P1: SignExternal, P2: uint16(slot), RespLen: 64, MaxExec: MaxExec(OpSign)})
	if err == nil {
		copy(sig[:], d)
	}
	return sig, err
}

// ECDH returns the shared secret of the private key in slot and the peer's public key (X ‖ Y), in clear
// (ECDH mode 0x0C).
func (s *Session) ECDH(slot int, peer [64]byte) ([32]byte, error) {
	var z [32]byte
	if err := slotOK(slot); err != nil {
		return z, err
	}
	d, err := s.Exec(Cmd{Op: OpECDH, P1: ECDHClear, P2: uint16(slot), Data: peer[:], RespLen: 32, MaxExec: MaxExec(OpECDH)})
	if err == nil {
		copy(z[:], d)
	}
	return z, err
}

// CheckMac asks the chip to compare resp with SHA-256(slot key ‖ chal ‖ other ‖ the chip's own serial bytes)
// (CheckMac mode 0x00; the hash input is proto.CheckMacInput). It returns false with a nil error only when the
// chip itself answered "miscompare" (status 0x01); every other failure is an error, so a chip fault is never taken
// for a wrong response (impl §2.1, review v6set-A M2).
func (s *Session) CheckMac(slot int, chal, resp [32]byte, other [13]byte) (bool, error) {
	if err := slotOK(slot); err != nil {
		return false, err
	}
	data := make([]byte, 0, 77)
	data = append(data, chal[:]...)
	data = append(data, resp[:]...)
	data = append(data, other[:]...)
	_, err := s.Exec(Cmd{Op: OpCheckMac, P1: CheckMacSlotChal, P2: uint16(slot), Data: data, RespLen: 1, MaxExec: MaxExec(OpCheckMac)})
	var se *StatusError
	if errors.As(err, &se) && se.Code == 0x01 {
		return false, nil
	}
	return err == nil, err
}

// LockConfig locks the config zone. crc is the CRC-16 of the 128 config bytes as the caller read them: the chip
// compares it with its own and refuses on a difference, which is the check that nothing changed in between.
func (s *Session) LockConfig(crc uint16) error { return s.lock(LockConfigCmd(crc)) }

// LockData locks the Data and OTP zones together. crc is DataCRC over what was written.
func (s *Session) LockData(crc uint16) error { return s.lock(LockDataCmd(crc)) }

// LockSlot locks one slot for good (KeyConfig.Lockable must be 1). There is no CRC for a slot.
func (s *Session) LockSlot(slot int) error {
	if err := slotOK(slot); err != nil {
		return err
	}
	return s.lock(LockSlotCmd(slot))
}

func (s *Session) lock(c Cmd) error {
	_, err := s.Exec(c)
	return err
}

// LockConfigCmd, LockDataCmd and LockSlotCmd build the Lock packets, so a tool can show the exact bytes first.
func LockConfigCmd(crc uint16) Cmd {
	return Cmd{Op: OpLock, P1: LockConfig, P2: crc, RespLen: 1, MaxExec: LockPoll}
}

func LockDataCmd(crc uint16) Cmd {
	return Cmd{Op: OpLock, P1: LockData, P2: crc, RespLen: 1, MaxExec: LockPoll}
}

func LockSlotCmd(slot int) Cmd {
	return Cmd{Op: OpLock, P1: lockSlot | byte(slot)<<2, P2: 0, RespLen: 1, MaxExec: LockPoll}
}

func slotOK(slot int) error {
	if slot < 0 || slot > 15 {
		return fmt.Errorf("se608: slot %d", slot)
	}
	return nil
}

// SlotSize is the size in bytes of each data slot.
var SlotSize = [16]int{36, 36, 36, 36, 36, 36, 36, 36, 416, 72, 72, 72, 72, 72, 72, 72}

// OTPLen is the size of the OTP zone.
const OTPLen = 64

// ConfigCRC is the summary CRC Lock(config) checks: over all 128 config bytes (F§1.3).
func ConfigCRC(cfg [ConfigLen]byte) uint16 { return CRC(cfg[:]) }

// SlotIsPrivate reports KeyConfig.Private of slot in cfg.
func SlotIsPrivate(cfg [ConfigLen]byte, slot int) bool { return cfg[96+2*slot]&0x01 != 0 }

// SlotLocked reports whether the SlotLocked bit of slot is 0 (locked) in cfg.
func SlotLocked(cfg [ConfigLen]byte, slot int) bool { return cfg[88+slot/8]>>(slot%8)&1 == 0 }

// DataLocked reports whether byte 86 says the Data and OTP zones are locked (anything but 0x55).
func DataLocked(cfg [ConfigLen]byte) bool { return cfg[LockDataByte] != unlocked }

// DataCRC is the summary CRC Lock(data) checks: the slots in order, the slots configured as ECC private keys
// skipped, then the OTP zone (F§1.3, from the 508A data sheet §9.10; ⚠️ first confirmed by E6: a wrong CRC makes
// the chip refuse the lock, it does not lock anything). data[i] must be SlotSize[i] bytes for every slot that is
// not private.
func DataCRC(cfg [ConfigLen]byte, data [16][]byte, otp [OTPLen]byte) (uint16, error) {
	var all []byte
	for i := range data {
		if SlotIsPrivate(cfg, i) {
			continue
		}
		if len(data[i]) != SlotSize[i] {
			return 0, fmt.Errorf("se608: slot %d content is %d bytes, want %d", i, len(data[i]), SlotSize[i])
		}
		all = append(all, data[i]...)
	}
	return CRC(append(all, otp[:]...)), nil
}

// SignDigest signs digest with the key in slot in one sequence: pass-through Nonce, then an external Sign (the
// product's session proof, impl §2.1). The sequence stays far under the watchdog.
func (d *Dev) SignDigest(slot int, digest [32]byte) (sig [64]byte, err error) {
	err = d.Do(func(s *Session) error {
		if err := s.NoncePassthrough(digest); err != nil {
			return err
		}
		sig, err = s.SignExternal(slot)
		return err
	})
	return sig, err
}

type slotWrite struct {
	addr uint16
	b    []byte
}

// WriteSlot writes content (exactly SlotSize[slot] bytes) to a data slot in clear: 32-byte blocks, then 4-byte
// words for the tail (a 36-byte slot is one block and one word, E6), a few writes per sequence.
func (d *Dev) WriteSlot(slot int, content []byte) error {
	if err := slotOK(slot); err != nil {
		return err
	}
	if len(content) != SlotSize[slot] {
		return fmt.Errorf("se608: slot %d content is %d bytes, want %d", slot, len(content), SlotSize[slot])
	}
	var ws []slotWrite
	off := 0
	for ; off+32 <= len(content); off += 32 {
		ws = append(ws, slotWrite{DataAddr(slot, off/32, 0), content[off : off+32]})
	}
	for ; off < len(content); off += 4 {
		ws = append(ws, slotWrite{DataAddr(slot, off/32, off%32/4), content[off : off+4]})
	}
	for i := 0; i < len(ws); i += wordsPerSeq {
		chunk := ws[i:min(i+wordsPerSeq, len(ws))]
		err := d.Do(func(s *Session) error {
			for _, w := range chunk {
				if err := s.Write(ZoneData, w.addr, w.b); err != nil {
					return fmt.Errorf("slot %d addr 0x%04x: %w", slot, w.addr, err)
				}
			}
			return nil
		})
		if err != nil {
			return err
		}
	}
	return nil
}

// ReadSlot reads a whole data slot (allowed only where the slot's configuration permits a clear read).
func (d *Dev) ReadSlot(slot int) ([]byte, error) {
	if err := slotOK(slot); err != nil {
		return nil, err
	}
	n := SlotSize[slot]
	out := make([]byte, 0, n)
	for off := 0; off < n; {
		err := d.Do(func(s *Session) error {
			for k := 0; k < 8 && off < n; k++ {
				sz := 32
				if n-off < 32 {
					sz = 4
				}
				b, err := s.Read(ZoneData, DataAddr(slot, off/32, off%32/4), sz)
				if err != nil {
					return fmt.Errorf("slot %d offset %d: %w", slot, off, err)
				}
				out = append(out, b...)
				off += sz
			}
			return nil
		})
		if err != nil {
			return nil, err
		}
	}
	return out, nil
}
