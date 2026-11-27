package se608

import (
	"errors"
	"fmt"
	"time"
)

// Word-address bytes: the first byte of every I2C write to the chip (0x00 reset and 0x01 sleep exist; this driver
// sends neither). Current cryptoauthlib also sends the reset word before each receive; this driver does not, and
// measured on chip 0123ba99e2ca248cee, 2026-11-27 (E1-E3 on the rig; results in docs/design/255-608b-config.md §8.3) shows our chip does not need it.
const (
	wordIdle    = 0x02
	wordCommand = 0x03
)

// Opcodes (ATECC608B datasheet summary, Table "Command Opcodes"; cryptoauthlib lib/calib/calib_command.h).
const (
	OpRead        byte = 0x02
	OpMAC         byte = 0x08
	OpWrite       byte = 0x12
	OpGenDig      byte = 0x15
	OpNonce       byte = 0x16
	OpLock        byte = 0x17
	OpRandom      byte = 0x1B
	OpDeriveKey   byte = 0x1C
	OpUpdateExtra byte = 0x20
	OpCounter     byte = 0x24
	OpCheckMac    byte = 0x28
	OpInfo        byte = 0x30
	OpGenKey      byte = 0x40
	OpSign        byte = 0x41
	OpECDH        byte = 0x43
	OpVerify      byte = 0x45
	OpPrivWrite   byte = 0x46
	OpSHA         byte = 0x47
	OpAES         byte = 0x51
	OpKDF         byte = 0x56
	OpSelfTest    byte = 0x77
)

var opNames = map[byte]string{OpRead: "Read", OpMAC: "MAC", OpWrite: "Write", OpGenDig: "GenDig", OpNonce: "Nonce",
	OpLock: "Lock", OpRandom: "Random", OpDeriveKey: "DeriveKey", OpUpdateExtra: "UpdateExtra", OpCounter: "Counter",
	OpCheckMac: "CheckMac", OpInfo: "Info", OpGenKey: "GenKey", OpSign: "Sign", OpECDH: "ECDH", OpVerify: "Verify",
	OpPrivWrite: "PrivWrite", OpSHA: "SHA", OpAES: "AES", OpKDF: "KDF", OpSelfTest: "SelfTest"}

// Mode bytes (param1) of the commands the product uses (cryptoauthlib calib_command.h).
const (
	NoncePassthrough byte = 0x03 // 32 input bytes go to TempKey unchanged
	GenKeyPublic     byte = 0x00 // compute the public key of the stored private key
	GenKeyCreate     byte = 0x04 // generate a new private key in the slot
	SignExternal     byte = 0x80 // sign the 32 bytes in TempKey
	ECDHClear        byte = 0x0C // slot key, result to the output buffer in clear
	CheckMacSlotChal byte = 0x00 // SHA block 1 from the slot, block 2 from ClientChal
	LockConfig       byte = 0x00 // with the summary CRC in param2
	LockData         byte = 0x01 // Data + OTP, with the summary CRC in param2
	lockSlot         byte = 0x02 // | slot << 2
	LockNoCRC        byte = 0x80 // "ignore the summary": never sent by this package
)

// Execution-time caps in milliseconds: cryptoauthlib lib/calib/calib_execution.c, device_execution_time_608_m0
// (clock divider 0, 255-608b-config.md §4). Not timed on a chip.
var execMs = map[byte]int{OpAES: 27, OpCheckMac: 40, OpCounter: 25, OpDeriveKey: 50, OpECDH: 75, OpGenDig: 25,
	OpGenKey: 115, OpInfo: 5, OpKDF: 165, OpLock: 35, OpMAC: 55, OpNonce: 20, OpPrivWrite: 50, OpRandom: 23,
	OpRead: 5, OpSelfTest: 250, OpSHA: 36, OpSign: 115, OpUpdateExtra: 10, OpVerify: 105, OpWrite: 45}

// LockPoll is how long the driver keeps polling for the answer to a Lock. Not the table's 35 ms: the 608B changed
// the timing of Lock (F§14.15), cryptoauthlib itself only polls on the 608B and waits far longer than its table
// (calib_execution.c), and giving up early on a command that cannot be repeated only loses the answer — the chip
// would be locked and the caller would not know (code review PR D2 B-M3). 500 ms keeps "read the zone, then Lock"
// in one sequence under the 0.7 s minimum watchdog.
const LockPoll = 500 * time.Millisecond

// ForGoodPoll is the same wait for the other two commands that cannot be undone, Counter increment and UpdateExtra:
// their 608B timing is not measured either (code review PR D2 round 2 B-m1).
const ForGoodPoll = LockPoll

// MaxExec is the cap for op (0 for an opcode this package does not know).
func MaxExec(op byte) time.Duration { return time.Duration(execMs[op]) * time.Millisecond }

// Zone selectors (param1 bits 0–1) and the 32-byte flag (bit 7).
type Zone byte

const (
	ZoneConfig Zone = 0x00
	ZoneOTP    Zone = 0x01
	ZoneData   Zone = 0x02
	zone32     byte = 0x80
)

const (
	maxData   = 150     // the input buffer bounds a packet
	minResp   = 4       // count + one byte + CRC
	maxResp   = 3 + 128 // the longest answers are 64 bytes (a public key, a signature) and KDF's 64 + 32
	ConfigLen = 128
)

// Cmd is one command packet. RespLen is the number of data bytes a success returns (1 = a status byte that must
// be 0x00; a negative RespLen returns whatever came back, for se-lab's raw command). MaxExec is the longest the chip may take (datasheet summary; not timed on a chip, but no command in
// E1-E3 came near its cap).
type Cmd struct {
	Op      byte
	P1      byte
	P2      uint16
	Data    []byte
	RespLen int
	MaxExec time.Duration
}

// Packet is the bytes Exec puts on the bus (word address .. CRC): what an operator checks before a Lock is sent.
func (c Cmd) Packet() ([]byte, error) { return c.encode() }

// encode builds word address + count + opcode + param1 + param2 (LE) + data + CRC (over count .. data).
func (c Cmd) encode() ([]byte, error) {
	if len(c.Data) > maxData {
		return nil, fmt.Errorf("se608: %d data bytes is over the %d-byte input buffer", len(c.Data), maxData)
	}
	n := 7 + len(c.Data)
	p := make([]byte, 0, n+1)
	p = append(p, wordCommand, byte(n), c.Op, c.P1, byte(c.P2), byte(c.P2>>8))
	p = append(p, c.Data...)
	return appendCRC(p, 1), nil
}

// Errors. A StatusError is the chip's own answer; the others are transport failures (retryable by the caller).
var (
	ErrNoResponse = errors.New("se608: no response")
	ErrComm       = errors.New("se608: bad response (length or CRC)")
	ErrWake       = errors.New("se608: wake failed")
	ErrRefused    = errors.New("se608: command not allowed by this driver's policy")
	ErrSession    = errors.New("se608: session already closed")
)

// StatusError is a one-byte status the chip returned instead of the expected data.
type StatusError struct {
	Op   byte
	Code byte
}

func (e *StatusError) Error() string {
	return fmt.Sprintf("se608: %s returned status 0x%02x (%s)", opName(e.Op), e.Code, StatusName(e.Code))
}

// StatusName names a status byte (datasheet summary "Status/Error Codes"). Only 0x00 and 0x0F have been seen on a
// real chip (measured on chip 0123ba99e2ca248cee, 2026-11-27 (E1-E3 on the rig; results in docs/design/255-608b-config.md §8.3)); the rest are still the datasheet's.
func StatusName(c byte) string {
	switch c {
	case 0x00:
		return "success"
	case 0x01:
		return "checkmac or verify miscompare"
	case 0x03:
		return "parse error"
	case 0x05:
		return "ECC fault"
	case 0x07:
		return "self-test error"
	case 0x08:
		return "health test error"
	case 0x0F:
		return "execution error"
	case 0x11:
		return "after wake"
	case 0xEE:
		return "watchdog about to expire"
	case 0xFF:
		return "CRC or other communication error"
	}
	return "unknown"
}

func opName(op byte) string {
	if n, ok := opNames[op]; ok {
		return n
	}
	return fmt.Sprintf("opcode 0x%02x", op)
}

// parseResp checks a full response (count .. CRC) and returns its data bytes.
func parseResp(b []byte) ([]byte, error) {
	if len(b) < minResp || int(b[0]) != len(b) {
		return nil, fmt.Errorf("%w: count %d, %d bytes", ErrComm, firstOr(b), len(b))
	}
	if !crcOK(b) {
		return nil, fmt.Errorf("%w: CRC mismatch", ErrComm)
	}
	return b[1 : len(b)-2], nil
}

func firstOr(b []byte) int {
	if len(b) == 0 {
		return -1
	}
	return int(b[0])
}
