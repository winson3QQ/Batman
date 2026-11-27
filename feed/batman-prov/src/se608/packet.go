package se608

import (
	"errors"
	"fmt"
	"time"
)

// Word-address bytes: the first byte of every I2C write to the chip (0x00 reset and 0x01 sleep exist; PR D sends
// neither). Current cryptoauthlib also sends the reset word before each receive; this driver does not, and
// measured on chip 0123ba99e2ca248cee, 2026-11-27 (E1-E3 on the rig; results in docs/design/255-608b-config.md §8.3) shows our chip does not need it.
const (
	wordIdle    = 0x02
	wordCommand = 0x03
)

// Opcodes (ATECC608B datasheet summary, Table "Command Opcodes"; cryptoauthlib calib_command.h).
const (
	OpRead   byte = 0x02
	OpWrite  byte = 0x12
	OpRandom byte = 0x1B
	OpInfo   byte = 0x30
)

// allowedOps is the closed list Exec sends in PR D. Everything else — in particular Lock (0x17) and UpdateExtra
// (0x20), which change the chip for good — is refused before the bus is touched.
var allowedOps = map[byte]string{OpRead: "Read", OpWrite: "Write", OpRandom: "Random", OpInfo: "Info"}

// Zone selectors (param1 bits 0–1) and the 32-byte flag (bit 7).
type Zone byte

const (
	ZoneConfig Zone = 0x00
	ZoneOTP    Zone = 0x01
	ZoneData   Zone = 0x02
	zone32     byte = 0x80
)

const (
	maxData   = 150 // the input buffer bounds a packet; PR D never sends more than 32 data bytes
	minResp   = 4   // count + one byte + CRC
	maxResp   = 3 + 72
	ConfigLen = 128
)

// Cmd is one command packet. RespLen is the number of data bytes a success returns (1 = a status byte that must
// be 0x00). MaxExec is the longest the chip may take (datasheet summary; not timed on a chip, but no command in
// E1-E3 came near its cap).
type Cmd struct {
	Op      byte
	P1      byte
	P2      uint16
	Data    []byte
	RespLen int
	MaxExec time.Duration
}

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
	ErrRefused    = errors.New("se608: command not allowed in this build")
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
	if n, ok := allowedOps[op]; ok {
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
