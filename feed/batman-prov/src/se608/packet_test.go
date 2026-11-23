package se608

import (
	"bytes"
	"errors"
	"testing"
)

// Vectors from outside this code: the wake response 04 11 33 43 is printed in the datasheet; the Info (revision)
// and 32-byte config-block-0 Read packets are the byte strings cryptoauthlib puts on the wire, as quoted in
// Microchip forum and library traces. PROVISIONAL(E1): E1 captures them from our chip.
func TestCRCVectors(t *testing.T) {
	for _, v := range []struct {
		in   []byte
		want []byte
	}{
		{[]byte{0x04, 0x11}, []byte{0x33, 0x43}},
		{[]byte{0x07, 0x30, 0x00, 0x00, 0x00}, []byte{0x03, 0x5D}},
		{[]byte{0x07, 0x02, 0x80, 0x00, 0x00}, []byte{0x09, 0xAD}},
	} {
		got := appendCRC(append([]byte(nil), v.in...), 0)[len(v.in):]
		if !bytes.Equal(got, v.want) {
			t.Errorf("CRC(% x) = % x, want % x", v.in, got, v.want)
		}
	}
	if CRC(nil) != 0 {
		t.Errorf("CRC(empty) = %#x, want 0", CRC(nil))
	}
}

func TestEncodeInfoAndRead(t *testing.T) {
	p, err := Cmd{Op: OpInfo}.encode()
	if err != nil || !bytes.Equal(p, []byte{0x03, 0x07, 0x30, 0x00, 0x00, 0x00, 0x03, 0x5D}) {
		t.Fatalf("Info packet % x, %v", p, err)
	}
	p, err = Cmd{Op: OpRead, P1: byte(ZoneConfig) | zone32, P2: 0}.encode()
	if err != nil || !bytes.Equal(p, []byte{0x03, 0x07, 0x02, 0x80, 0x00, 0x00, 0x09, 0xAD}) {
		t.Fatalf("Read packet % x, %v", p, err)
	}
	// param2 is little-endian, data follows it, the count covers count .. CRC.
	p, _ = Cmd{Op: OpWrite, P1: 0, P2: 0x0105, Data: []byte{1, 2, 3, 4}}.encode()
	if p[1] != 11 || p[4] != 0x05 || p[5] != 0x01 || !bytes.Equal(p[6:10], []byte{1, 2, 3, 4}) || !crcOK(p[1:]) {
		t.Fatalf("Write packet % x", p)
	}
	if _, err := (Cmd{Op: OpWrite, Data: make([]byte, maxData+1)}).encode(); err == nil {
		t.Fatal("oversized packet encoded")
	}
}

func TestParseResp(t *testing.T) {
	ok := []byte{0x04, 0x11, 0x33, 0x43}
	if d, err := parseResp(ok); err != nil || !bytes.Equal(d, []byte{0x11}) {
		t.Fatalf("wake response: % x, %v", d, err)
	}
	for name, b := range map[string][]byte{
		"bad CRC":       {0x04, 0x11, 0x33, 0x42},
		"count too big": {0x05, 0x11, 0x33, 0x43},
		"too short":     {0x03, 0x11, 0x33},
		"empty":         {},
	} {
		if _, err := parseResp(b); !errors.Is(err, ErrComm) {
			t.Errorf("%s: err = %v, want ErrComm", name, err)
		}
	}
}

func TestSizeFlag(t *testing.T) {
	for _, n := range []int{0, 1, 31, 33, 64} {
		if _, err := sizeFlag(ZoneConfig, n); err == nil {
			t.Errorf("size %d accepted", n)
		}
	}
	if _, err := sizeFlag(Zone(3), 4); err == nil {
		t.Error("zone 3 accepted")
	}
	if f, _ := sizeFlag(ZoneData, 32); f != 0x82 {
		t.Errorf("data 32 flag %#x", f)
	}
}

func TestImageWords(t *testing.T) {
	w := ImageWords()
	in := map[int]bool{}
	for _, x := range w {
		in[x] = true
	}
	for b := 0; b < ConfigLen; b++ {
		want := (b >= 16 && b <= 51) || (b >= 68 && b <= 83) || (b >= 88 && b <= 127)
		if in[b/4] != want {
			t.Errorf("byte %d written = %v, want %v", b, in[b/4], want)
		}
	}
}

// The variant image (255-608b-config.md §4 + §8.1), bytes 16-51, 68-83 and 88-127, transcribed by hand from the
// tables rather than from Image's code.
func TestVariantImageGolden(t *testing.T) {
	want := map[int][]byte{
		16: {0xC0, 0x5A, 0x00, 0x00},
		20: {0x81, 0x20, 0x82, 0x20, 0x84, 0x20, 0x8F, 0x0F, 0x83, 0x20, 0x9F, 0x8F, 0x0F, 0x0F, 0x9F, 0x8F,
			0x0F, 0x0F, 0x9F, 0x8F, 0x9F, 0x8F, 0x9F, 0x8F, 0x9F, 0x8F, 0x9F, 0x8F, 0x9F, 0x8F, 0x9F, 0x8F},
		68: make([]byte, 16),
		88: {0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},
		96: {0x73, 0x00, 0x73, 0x00, 0x73, 0x00, 0x3C, 0x00, 0x73, 0x00, 0x1C, 0x00, 0x3C, 0x00, 0x1C, 0x00,
			0x3C, 0x00, 0x1C, 0x00, 0x1C, 0x00, 0x1C, 0x00, 0x1C, 0x00, 0x1C, 0x00, 0x1C, 0x00, 0x1C, 0x00},
	}
	img := Image(true, 0x5A)
	n := 0
	for off, b := range want {
		if !bytes.Equal(img[off:off+len(b)], b) {
			t.Errorf("variant bytes %d..: % x, want % x", off, img[off:off+len(b)], b)
		}
		n += len(b)
	}
	if n != 4*len(ImageWords()) {
		t.Fatalf("golden covers %d bytes, image words %d", n, 4*len(ImageWords()))
	}
	// The final image differs from the variant only in slots 3, 4 and 6.
	fin := Image(false, 0x5A)
	var diff []int
	for i := range fin {
		if fin[i] != img[i] {
			diff = append(diff, i)
		}
	}
	for _, i := range diff {
		ok := false
		for _, s := range []int{3, 4, 6} {
			if i == 20+2*s || i == 21+2*s || i == 96+2*s || i == 97+2*s {
				ok = true
			}
		}
		if !ok {
			t.Errorf("final and variant differ at byte %d", i)
		}
	}
	if fin[30] != 0x9F || fin[31] != 0x8F || fin[106] != 0x1C || fin[107] != 0x00 {
		t.Errorf("slot 5 (claim secret) config % x / % x", fin[30:32], fin[106:108])
	}
}
