package provd

import (
	"encoding/binary"
	"errors"
)

// GATT framing (219 §4.1): flags(1) ‖ seq(2 BE) ‖ data; bit0 = start, bit1 = end; seq from 0 for every Noise message.
const (
	FlagStart = 0x01
	FlagEnd   = 0x02
	// MaxFrame: a single inbound frame larger than this aborts (254-p2-impl §4.1)
	MaxFrame = 512
	// MaxMsg: the largest Noise message in stage 1 BLE (CTRL key 4)
	MaxMsg = 8192
	// OutFrame: the node's outbound frame limit before the MTU (CTRL key 3)
	OutFrame = 244
)

// ErrFrame is any framing violation: the connection is aborted (no unauthenticated abort flag, 219 §4.1).
var ErrFrame = errors.New("provd: framing violation")

// Reassembler rebuilds Noise messages from frames.
type Reassembler struct {
	buf    []byte
	next   uint16
	active bool
}

// Push takes one frame; a complete message is returned with done = true.
func (r *Reassembler) Push(f []byte) (msg []byte, done bool, err error) {
	if len(f) < 3 || len(f) > MaxFrame || f[0]&^(FlagStart|FlagEnd) != 0 {
		return nil, false, ErrFrame
	}
	flags, seq, data := f[0], binary.BigEndian.Uint16(f[1:3]), f[3:]
	if flags&FlagStart != 0 {
		if r.active || seq != 0 {
			return nil, false, ErrFrame
		}
		r.buf, r.next, r.active = nil, 0, true
	} else if !r.active {
		return nil, false, ErrFrame
	}
	if seq != r.next {
		return nil, false, ErrFrame
	}
	r.next++
	r.buf = append(r.buf, data...)
	if len(r.buf) > MaxMsg {
		return nil, false, ErrFrame
	}
	if flags&FlagEnd != 0 {
		msg, r.buf, r.active = r.buf, nil, false
		return msg, true, nil
	}
	return nil, false, nil
}

// Split cuts one Noise message into frames of at most limit bytes (header included).
func Split(msg []byte, limit int) [][]byte {
	per := limit - 3
	if per < 1 {
		per = 1
	}
	var out [][]byte
	seq := uint16(0)
	for off := 0; ; off += per {
		end := min(off+per, len(msg))
		f := make([]byte, 3, 3+end-off)
		if off == 0 {
			f[0] |= FlagStart
		}
		if end == len(msg) {
			f[0] |= FlagEnd
		}
		binary.BigEndian.PutUint16(f[1:3], seq)
		f = append(f, msg[off:end]...)
		out = append(out, f)
		seq++
		if end == len(msg) {
			return out
		}
	}
}
