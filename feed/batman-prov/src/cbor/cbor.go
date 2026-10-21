// Package cbor is the helper's own strict CBOR codec (RFC 8949): core deterministic encoding (§4.2.1)
// on output, and on input it accepts ONLY what that encoding would produce — shortest-form integers and
// lengths, definite lengths, map keys strictly ascending by their encoded bytes (so no duplicates), no
// floats, no undefined. Used for every signed object and every owner-op request (219-protocol §5.1, §5.7):
// a non-deterministic or duplicate-key body is rejected, never "normalised".
//
// Value model: uint64 / int64 (negative only) / []byte / string / bool / nil / []any / Map / Tag.
package cbor

import (
	"bytes"
	"errors"
	"fmt"
	"math"
	"sort"
)

// Map is an ordered CBOR map; Encode sorts it, Decode returns it in (verified) canonical order.
type Map []Entry

// Entry is one key/value pair of a Map. Keys are uint64, int64 (negative) or string.
type Entry struct {
	K any
	V any
}

// Tag is a tagged item (COSE_Sign1 = 18, COSE_Encrypt = 96).
type Tag struct {
	Num uint64
	V   any
}

// Get returns the value for an integer or string key.
func (m Map) Get(k any) (any, bool) {
	ek, err := Encode(normKey(k))
	if err != nil {
		return nil, false
	}
	for _, e := range m {
		b, err := Encode(normKey(e.K))
		if err == nil && bytes.Equal(b, ek) {
			return e.V, true
		}
	}
	return nil, false
}

// Without returns a copy of m without key k.
func (m Map) Without(k any) Map {
	ek, _ := Encode(normKey(k))
	out := make(Map, 0, len(m))
	for _, e := range m {
		b, _ := Encode(normKey(e.K))
		if !bytes.Equal(b, ek) {
			out = append(out, e)
		}
	}
	return out
}

func normKey(k any) any {
	switch v := k.(type) {
	case int:
		if v < 0 {
			return int64(v)
		}
		return uint64(v)
	case int64:
		if v >= 0 {
			return uint64(v)
		}
	}
	return k
}

// ---- encoding ----------------------------------------------------------------------------------------------

func head(buf *bytes.Buffer, major byte, n uint64) {
	switch {
	case n < 24:
		buf.WriteByte(major<<5 | byte(n))
	case n <= math.MaxUint8:
		buf.WriteByte(major<<5 | 24)
		buf.WriteByte(byte(n))
	case n <= math.MaxUint16:
		buf.WriteByte(major<<5 | 25)
		buf.Write([]byte{byte(n >> 8), byte(n)})
	case n <= math.MaxUint32:
		buf.WriteByte(major<<5 | 26)
		buf.Write([]byte{byte(n >> 24), byte(n >> 16), byte(n >> 8), byte(n)})
	default:
		buf.WriteByte(major<<5 | 27)
		for i := 7; i >= 0; i-- {
			buf.WriteByte(byte(n >> (8 * uint(i))))
		}
	}
}

// Encode returns the core deterministic encoding of v.
func Encode(v any) ([]byte, error) {
	var buf bytes.Buffer
	if err := enc(&buf, v, 0); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

const maxDepth = 16

func enc(buf *bytes.Buffer, v any, depth int) error {
	if depth > maxDepth {
		return errors.New("cbor: nesting too deep")
	}
	switch x := v.(type) {
	case nil:
		buf.WriteByte(0xf6)
	case bool:
		if x {
			buf.WriteByte(0xf5)
		} else {
			buf.WriteByte(0xf4)
		}
	case int:
		return enc(buf, normKey(x), depth)
	case uint64:
		head(buf, 0, x)
	case int64:
		if x >= 0 {
			head(buf, 0, uint64(x))
		} else {
			head(buf, 1, uint64(-(x + 1)))
		}
	case []byte:
		head(buf, 2, uint64(len(x)))
		buf.Write(x)
	case string:
		head(buf, 3, uint64(len(x)))
		buf.WriteString(x)
	case []any:
		head(buf, 4, uint64(len(x)))
		for _, e := range x {
			if err := enc(buf, e, depth+1); err != nil {
				return err
			}
		}
	case Map:
		type kv struct{ k, v []byte }
		items := make([]kv, 0, len(x))
		for _, e := range x {
			kb, err := Encode(normKey(e.K))
			if err != nil {
				return err
			}
			var vb bytes.Buffer
			if err := enc(&vb, e.V, depth+1); err != nil {
				return err
			}
			items = append(items, kv{kb, vb.Bytes()})
		}
		sort.Slice(items, func(i, j int) bool { return bytes.Compare(items[i].k, items[j].k) < 0 })
		for i := 1; i < len(items); i++ {
			if bytes.Equal(items[i].k, items[i-1].k) {
				return errors.New("cbor: duplicate map key")
			}
		}
		head(buf, 5, uint64(len(items)))
		for _, it := range items {
			buf.Write(it.k)
			buf.Write(it.v)
		}
	case Tag:
		head(buf, 6, x.Num)
		return enc(buf, x.V, depth+1)
	default:
		return fmt.Errorf("cbor: cannot encode %T", v)
	}
	return nil
}

// ---- strict decoding ---------------------------------------------------------------------------------------

// ErrNotDeterministic marks input that is valid CBOR but not in core deterministic form.
var ErrNotDeterministic = errors.New("cbor: not core deterministic encoding")

// Decode parses exactly one item that must fill b completely and be in core deterministic form.
func Decode(b []byte) (any, error) {
	d := decoder{b: b}
	v, err := d.item(0)
	if err != nil {
		return nil, err
	}
	if d.p != len(b) {
		return nil, errors.New("cbor: trailing bytes")
	}
	return v, nil
}

type decoder struct {
	b []byte
	p int
}

func (d *decoder) need(n uint64) error {
	if n > uint64(len(d.b)-d.p) {
		return errors.New("cbor: truncated")
	}
	return nil
}

// arg reads the head of an item: major type and argument, rejecting non-shortest forms and indefinite lengths.
func (d *decoder) arg() (byte, uint64, error) {
	if err := d.need(1); err != nil {
		return 0, 0, err
	}
	ib := d.b[d.p]
	d.p++
	major, ai := ib>>5, ib&0x1f
	var n uint64
	switch {
	case ai < 24:
		n = uint64(ai)
	case ai == 24:
		if err := d.need(1); err != nil {
			return 0, 0, err
		}
		n = uint64(d.b[d.p])
		d.p++
		if n < 24 {
			return 0, 0, ErrNotDeterministic
		}
	case ai == 25:
		if err := d.need(2); err != nil {
			return 0, 0, err
		}
		n = uint64(d.b[d.p])<<8 | uint64(d.b[d.p+1])
		d.p += 2
		if n <= math.MaxUint8 {
			return 0, 0, ErrNotDeterministic
		}
	case ai == 26:
		if err := d.need(4); err != nil {
			return 0, 0, err
		}
		for i := 0; i < 4; i++ {
			n = n<<8 | uint64(d.b[d.p+i])
		}
		d.p += 4
		if n <= math.MaxUint16 {
			return 0, 0, ErrNotDeterministic
		}
	case ai == 27:
		if err := d.need(8); err != nil {
			return 0, 0, err
		}
		for i := 0; i < 8; i++ {
			n = n<<8 | uint64(d.b[d.p+i])
		}
		d.p += 8
		if n <= math.MaxUint32 {
			return 0, 0, ErrNotDeterministic
		}
	default:
		return 0, 0, errors.New("cbor: indefinite length or reserved additional info")
	}
	return major, n, nil
}

func (d *decoder) item(depth int) (any, error) {
	if depth > maxDepth {
		return nil, errors.New("cbor: nesting too deep")
	}
	start := d.p
	major, n, err := d.arg()
	if err != nil {
		return nil, err
	}
	switch major {
	case 0:
		return n, nil
	case 1:
		if n > math.MaxInt64 {
			return nil, errors.New("cbor: negative integer out of range")
		}
		return -int64(n) - 1, nil
	case 2, 3:
		if err := d.need(n); err != nil {
			return nil, err
		}
		s := d.b[d.p : d.p+int(n)]
		d.p += int(n)
		if major == 2 {
			return append([]byte(nil), s...), nil
		}
		return string(s), nil
	case 4:
		if n > uint64(len(d.b)) {
			return nil, errors.New("cbor: array length exceeds input")
		}
		a := make([]any, 0, n)
		for i := uint64(0); i < n; i++ {
			v, err := d.item(depth + 1)
			if err != nil {
				return nil, err
			}
			a = append(a, v)
		}
		return a, nil
	case 5:
		if n > uint64(len(d.b)) {
			return nil, errors.New("cbor: map length exceeds input")
		}
		m := make(Map, 0, n)
		var prev []byte
		for i := uint64(0); i < n; i++ {
			ks := d.p
			k, err := d.item(depth + 1)
			if err != nil {
				return nil, err
			}
			switch k.(type) {
			case uint64, int64, string:
			default:
				return nil, errors.New("cbor: map key must be an integer or text")
			}
			kb := d.b[ks:d.p]
			if prev != nil && bytes.Compare(prev, kb) >= 0 {
				if bytes.Equal(prev, kb) {
					return nil, errors.New("cbor: duplicate map key")
				}
				return nil, ErrNotDeterministic
			}
			prev = kb
			v, err := d.item(depth + 1)
			if err != nil {
				return nil, err
			}
			m = append(m, Entry{k, v})
		}
		return m, nil
	case 6:
		v, err := d.item(depth + 1)
		if err != nil {
			return nil, err
		}
		return Tag{n, v}, nil
	case 7:
		switch d.b[start] {
		case 0xf4:
			return false, nil
		case 0xf5:
			return true, nil
		case 0xf6:
			return nil, nil
		}
		return nil, errors.New("cbor: float / undefined / simple value not accepted")
	}
	return nil, errors.New("cbor: bad major type")
}
