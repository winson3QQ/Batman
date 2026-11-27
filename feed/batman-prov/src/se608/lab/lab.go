// Package lab holds the ATECC608B commands only the rig experiments use (255-608b-config.md §8.0;
// 255-608b-impl.md §2.2 "不實作", §5): Random, the random Nonce, MAC, GenDig, clear PrivWrite, UpdateExtra, Counter,
// internal Sign, every ECDH mode, SHA-HMAC, KDF, AES and a raw command. They run through se608.Session.Exec under
// Policy, which is wider than anything the product gets. No shipped binary may link this package
// (cmd/deps_test.go); se-lab is the only user.
//
// Formats: cryptoauthlib lib/calib and lib/host/atca_host.c at d0b9a77. ⚠️ None has run on a real chip; the rig is
// where they are first checked, and where a format turns out wrong `se-lab raw` can send corrected bytes without a
// new build.
package lab

import (
	"crypto/sha256"
	"fmt"
	"time"

	"batman-prov/se608"
)

var allowed = map[byte]bool{se608.OpRead: true, se608.OpMAC: true, se608.OpWrite: true, se608.OpGenDig: true,
	se608.OpNonce: true, se608.OpLock: true, se608.OpRandom: true, se608.OpUpdateExtra: true, se608.OpCounter: true,
	se608.OpCheckMac: true, se608.OpInfo: true, se608.OpGenKey: true, se608.OpSign: true, se608.OpECDH: true,
	se608.OpPrivWrite: true, se608.OpSHA: true, se608.OpAES: true, se608.OpKDF: true}

// Policy lets every opcode the experiments list through. DeriveKey, Verify and SelfTest are not on it: no
// experiment uses them. A no-CRC Lock is refused by se608 itself, whatever the policy.
func Policy(c se608.Cmd) error {
	if allowed[c.Op] {
		return nil
	}
	return fmt.Errorf("%w: opcode 0x%02x is not on se-lab's list", se608.ErrRefused, c.Op)
}

// Result is what a command of unknown outcome returned: a one-byte status, or data.
type Result struct {
	IsStatus bool
	Status   byte
	Data     []byte
}

func (r Result) String() string {
	if r.IsStatus {
		return fmt.Sprintf("status_%02x", r.Status)
	}
	return fmt.Sprintf("%x", r.Data)
}

// OK reports a zero status or any data.
func (r Result) OK() bool { return !r.IsStatus || r.Status == 0x00 }

// Try sends c and returns whatever came back without judging it: an experiment that must fail and one that must
// succeed go through the same code. Only transport failures are errors.
func Try(s *se608.Session, c se608.Cmd) (Result, error) {
	c.RespLen = -1
	if c.MaxExec == 0 {
		c.MaxExec = se608.MaxExec(c.Op)
	}
	d, err := s.Exec(c)
	if err != nil {
		return Result{}, err
	}
	if len(d) == 1 {
		return Result{IsStatus: true, Status: d[0]}, nil
	}
	return Result{Data: d}, nil
}

// Raw sends an arbitrary packet under Policy.
func Raw(s *se608.Session, op, p1 byte, p2 uint16, data []byte, maxExec time.Duration) (Result, error) {
	return Try(s, se608.Cmd{Op: op, P1: p1, P2: p2, Data: data, MaxExec: maxExec})
}

// Random is Random mode 0: 32 bytes (before the config lock: the fixed pattern FF FF 00 00 ..., E2).
func Random(s *se608.Session) (Result, error) { return Try(s, se608.Cmd{Op: se608.OpRandom}) }

// NonceRandom is Nonce mode 0: the chip returns RandOut and sets TempKey = NonceTempKey(RandOut, numIn, 0).
func NonceRandom(s *se608.Session, numIn [20]byte) (Result, error) {
	return Try(s, se608.Cmd{Op: se608.OpNonce, P1: 0x00, Data: numIn[:]})
}

// NonceTempKey is the host side of a random Nonce: SHA-256(RandOut ‖ NumIn ‖ 0x16 ‖ mode ‖ 0x00)
// (atcah_nonce).
func NonceTempKey(randOut []byte, numIn [20]byte, mode byte) [32]byte {
	m := append(append(append([]byte{}, randOut...), numIn[:]...), se608.OpNonce, mode, 0x00)
	return sha256.Sum256(m)
}

// MAC is the MAC command: mode bit 0 takes SHA block 2 from TempKey instead of chal, bit 1 block 1 from TempKey
// instead of the slot, bit 6 includes the serial number.
func MAC(s *se608.Session, mode byte, slot int, chal []byte) (Result, error) {
	return Try(s, se608.Cmd{Op: se608.OpMAC, P1: mode, P2: uint16(slot), Data: chal})
}

// HostMAC is what MAC returns for block1 ‖ block2 (atcah_mac, no OTP bits): SHA-256(block1 ‖ block2 ‖ 0x08 ‖ mode ‖
// keyID LE ‖ 11 zeros ‖ SN[8] ‖ SN[4:8] or zeros ‖ SN[0:2] ‖ SN[2:4] or zeros). With mode 0 and proto.OtherData =
// {0x08, 0, ...} this is exactly the CheckMac input for slot key ID 0 — see se-lab's mac command for the claim
// slot's real OtherData.
func HostMAC(block1, block2 []byte, mode byte, keyID uint16, sn [9]byte) [32]byte {
	m := append(append([]byte{}, block1...), block2...)
	m = append(m, se608.OpMAC, mode, byte(keyID), byte(keyID>>8))
	m = append(m, make([]byte, 11)...)
	m = append(m, sn[8])
	if mode&0x40 != 0 {
		m = append(m, sn[4:8]...)
	} else {
		m = append(m, 0, 0, 0, 0)
	}
	m = append(m, sn[0], sn[1])
	if mode&0x40 != 0 {
		m = append(m, sn[2], sn[3])
	} else {
		m = append(m, 0, 0)
	}
	return sha256.Sum256(m)
}

// GenDig zones.
const (
	GenDigConfig byte = 0
	GenDigOTP    byte = 1
	GenDigData   byte = 2
)

// GenDig mixes a stored value into TempKey. For a data slot configured NoMac the command must carry 4 bytes of
// OtherData, which replace opcode ‖ zone ‖ keyID in the hash (atcah_gen_dig).
func GenDig(s *se608.Session, zone byte, keyID uint16, other []byte) (Result, error) {
	return Try(s, se608.Cmd{Op: se608.OpGenDig, P1: zone, P2: keyID, Data: other})
}

// HostGenDig is the new TempKey after GenDig on a 32-byte stored value: SHA-256(stored ‖ 0x15 ‖ zone ‖ keyID LE ‖
// SN[8] ‖ SN[0:2] ‖ 25 zeros ‖ TempKey); a non-empty other (4 bytes) replaces the 4 header bytes.
func HostGenDig(stored []byte, zone byte, keyID uint16, sn [9]byte, tempKey [32]byte, other []byte) [32]byte {
	m := append([]byte{}, stored...)
	if len(other) == 4 {
		m = append(m, other...)
	} else {
		m = append(m, se608.OpGenDig, zone, byte(keyID), byte(keyID>>8))
	}
	m = append(m, sn[8], sn[0], sn[1])
	m = append(m, make([]byte, 25)...)
	m = append(m, tempKey[:]...)
	return sha256.Sum256(m)
}

// PrivWriteClear writes a P-256 private scalar into slot unencrypted (4 zero bytes ‖ scalar ‖ 32 ignored MAC
// bytes): only possible between the config lock and the data lock (calib_privwrite.c).
func PrivWriteClear(s *se608.Session, slot int, scalar [32]byte) (Result, error) {
	d := make([]byte, 68)
	copy(d[4:36], scalar[:])
	return Try(s, se608.Cmd{Op: se608.OpPrivWrite, P1: 0x00, P2: uint16(slot), Data: d})
}

// UpdateExtra modes.
const (
	UpdateUserExtra    byte = 0x00 // config byte 84
	UpdateUserExtraAdd byte = 0x01 // config byte 85 (the alternate I2C address, E12)
	UpdateDecCounter   byte = 0x02 // the 508A's limited-use decrement (E11: must fail or do nothing)
)

// UpdateExtra writes val to config byte 84 or 85 (mode 0 / 1). It needs no authorisation and works once per byte
// (F§9): on a chip that should be kept, never.
func UpdateExtra(s *se608.Session, mode, val byte) (Result, error) {
	return Try(s, UpdateExtraCmd(mode, val))
}

// UpdateExtraCmd and CounterCmd build the two packets that change a chip for good outside Lock, so a tool prints
// and sends the same value (code review PR D2 A-m1).
func UpdateExtraCmd(mode, val byte) se608.Cmd {
	return se608.Cmd{Op: se608.OpUpdateExtra, P1: mode, P2: uint16(val), MaxExec: se608.ForGoodPoll}
}

func CounterCmd(inc bool, id int) se608.Cmd {
	c := se608.Cmd{Op: se608.OpCounter, P1: 0x00, P2: uint16(id)}
	if inc {
		c.P1, c.MaxExec = 0x01, se608.ForGoodPoll
	}
	return c
}

// ForGood reports whether c changes a chip in a way nothing can undo: any Lock, UpdateExtra, or a Counter
// increment. se-lab's policies refuse these unless the invocation is one of the confirmed for-good commands.
func ForGood(c se608.Cmd) bool {
	return c.Op == se608.OpLock || c.Op == se608.OpUpdateExtra || (c.Op == se608.OpCounter && c.P1&0x01 != 0)
}

// CounterRead reads counter id (0 or 1); CounterInc increments it — for good, a counter cannot be reset (E11).
// The 4 data bytes are returned as the chip sent them.
func CounterRead(s *se608.Session, id int) (Result, error) { return Try(s, CounterCmd(false, id)) }

func CounterInc(s *se608.Session, id int) (Result, error) { return Try(s, CounterCmd(true, id)) }

// Sign sends Sign with any mode (0x00 internal, 0x40 internal with the serial number, 0x80 external).
func Sign(s *se608.Session, mode byte, slot int) (Result, error) {
	return Try(s, se608.Cmd{Op: se608.OpSign, P1: mode, P2: uint16(slot)})
}

// GenKey sends GenKey with any mode (0x04 create, 0x00 public; 0x08 / 0x10 are the digest modes).
func GenKey(s *se608.Session, mode byte, slot int) (Result, error) {
	return Try(s, se608.Cmd{Op: se608.OpGenKey, P1: mode, P2: uint16(slot)})
}

// ECDH modes beyond the product's clear output (calib_command.h ECDH_MODE_*).
const (
	ECDHCompatible byte = 0x00 // the 508A behaviour: SlotConfig bit 3 decides clear output or slot N+1
	ECDHToSlot     byte = 0x04 // result written to an EEPROM slot
	ECDHToTempKey  byte = 0x08
	ECDHClear      byte = 0x0C
	ECDHEncrypted  byte = 0x0E // clear | the output-encryption bit: must be refused on our config (E10)
)

// ECDH sends ECDH with any mode.
func ECDH(s *se608.Session, mode byte, slot int, peer [64]byte) (Result, error) {
	return Try(s, se608.Cmd{Op: se608.OpECDH, P1: mode, P2: uint16(slot), Data: peer[:]})
}

// CheckMac sends CheckMac mode 0 and returns the raw status (0x00 match, 0x01 miscompare, anything else).
func CheckMac(s *se608.Session, slot int, chal, resp [32]byte, other [13]byte) (Result, error) {
	d := append(append(append([]byte{}, chal[:]...), resp[:]...), other[:]...)
	return Try(s, se608.Cmd{Op: se608.OpCheckMac, P1: 0x00, P2: uint16(slot), Data: d})
}

// HMACStart is SHA mode 0x04 with the key slot in param2; SHAEnd is mode 0x02 with the last 0-63 message bytes and
// returns the digest (on the 608 the HMAC is finished with the same End mode, calib_command.h
// SHA_MODE_608_HMAC_END).
func HMACStart(s *se608.Session, slot int) (Result, error) {
	return Try(s, se608.Cmd{Op: se608.OpSHA, P1: 0x04, P2: uint16(slot)})
}

func SHAEnd(s *se608.Session, msg []byte) (Result, error) {
	if len(msg) > 63 {
		return Result{}, fmt.Errorf("lab: SHA End takes 0-63 bytes, got %d", len(msg))
	}
	return Try(s, se608.Cmd{Op: se608.OpSHA, P1: 0x02, P2: uint16(len(msg)), Data: msg})
}

// KDF modes (calib_command.h KDF_MODE_*): source | target | algorithm.
const (
	KDFSourceSlot   byte = 0x02
	KDFTargetSlot   byte = 0x08
	KDFTargetOutput byte = 0x10
	KDFTargetOutEnc byte = 0x14
	KDFAlgPRF       byte = 0x00
	KDFAlgAES       byte = 0x20
	KDFAlgHKDF      byte = 0x40
)

// KDF sends the KDF command. keyID is source slot | target slot << 8. For PRF and HKDF the message length goes in
// the top byte of details (calib_kdf.c: "all other algorithms encode message size in the last byte of details");
// this function sets it. For AES the message must be 16 bytes.
func KDF(s *se608.Session, mode byte, keyID uint16, details uint32, msg []byte) (Result, error) {
	if mode&0x60 == KDFAlgAES {
		if len(msg) != 16 {
			return Result{}, fmt.Errorf("lab: KDF AES takes a 16-byte message, got %d", len(msg))
		}
	} else {
		if len(msg) > 127 {
			return Result{}, fmt.Errorf("lab: KDF message of %d bytes", len(msg))
		}
		details = details&0x00FFFFFF | uint32(len(msg))<<24
	}
	d := []byte{byte(details), byte(details >> 8), byte(details >> 16), byte(details >> 24)}
	return Try(s, se608.Cmd{Op: se608.OpKDF, P1: mode, P2: keyID, Data: append(d, msg...)})
}

// AES encrypts (mode 0x00) or decrypts (0x01) one 16-byte block with the key at the start of slot.
func AES(s *se608.Session, mode byte, slot int, block [16]byte) (Result, error) {
	return Try(s, se608.Cmd{Op: se608.OpAES, P1: mode, P2: uint16(slot), Data: block[:]})
}
