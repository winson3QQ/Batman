package lab_test

import (
	"bytes"
	"errors"
	"testing"

	"batman-prov/se608"
	"batman-prov/se608/fakechip"
	"batman-prov/se608/lab"
)

func last(c *fakechip.Chip) []byte { return c.Pkts[len(c.Pkts)-1] }

func do(t *testing.T, d *se608.Dev, fn func(*se608.Session) (lab.Result, error)) lab.Result {
	t.Helper()
	var r lab.Result
	if err := d.Do(func(s *se608.Session) (err error) { r, err = fn(s); return }); err != nil {
		t.Fatal(err)
	}
	return r
}

// The packets of the commands the fake does not model: opcode, mode, param2 and data as cryptoauthlib builds them
// (calib_kdf.c, calib_aes.c, calib_sha.c). The fake answers a parse error; only the bytes sent are asserted.
func TestPacketsOfUnmodelledCommands(t *testing.T) {
	chip := fakechip.New()
	d := se608.NewPolicy(chip, lab.Policy)
	msg := []byte("0123456789abcdef")

	do(t, d, func(s *se608.Session) (lab.Result, error) {
		return lab.KDF(s, lab.KDFSourceSlot|lab.KDFTargetOutput|lab.KDFAlgHKDF, 0x0005, 0x00000002, msg)
	})
	p := last(chip)
	want := append([]byte{0x56, 0x52, 0x05, 0x00, 0x02, 0x00, 0x00, 0x10}, msg...)
	if !bytes.Equal(p[1:len(p)-2], want) {
		t.Fatalf("KDF HKDF packet % x\nwant           % x", p[1:len(p)-2], want)
	}

	do(t, d, func(s *se608.Session) (lab.Result, error) {
		return lab.KDF(s, lab.KDFSourceSlot|lab.KDFTargetSlot|lab.KDFAlgPRF, 0x0603, 0x00000001, msg)
	})
	p = last(chip)
	want = append([]byte{0x56, 0x0A, 0x03, 0x06, 0x01, 0x00, 0x00, 0x10}, msg...)
	if !bytes.Equal(p[1:len(p)-2], want) {
		t.Fatalf("KDF PRF to slot packet % x\nwant                  % x", p[1:len(p)-2], want)
	}

	do(t, d, func(s *se608.Session) (lab.Result, error) { return lab.AES(s, 0x00, 3, [16]byte{}) })
	p = last(chip)
	if !bytes.Equal(p[1:5], []byte{0x51, 0x00, 0x03, 0x00}) || len(p) != 7+16 {
		t.Fatalf("AES packet % x", p)
	}

	do(t, d, func(s *se608.Session) (lab.Result, error) { return lab.HMACStart(s, 5) })
	if p = last(chip); !bytes.Equal(p[1:5], []byte{0x47, 0x04, 0x05, 0x00}) || len(p) != 7 {
		t.Fatalf("HMAC start packet % x", p)
	}
	do(t, d, func(s *se608.Session) (lab.Result, error) { return lab.SHAEnd(s, []byte("abc")) })
	if p = last(chip); !bytes.Equal(p[1:len(p)-2], []byte{0x47, 0x02, 0x03, 0x00, 'a', 'b', 'c'}) {
		t.Fatalf("SHA end packet % x", p)
	}
	if err := d.Do(func(s *se608.Session) error { _, err := lab.SHAEnd(s, make([]byte, 64)); return err }); err == nil {
		t.Fatal("SHA End accepted 64 bytes")
	}
}

func TestPacketsOfForGoodCommands(t *testing.T) {
	chip := fakechip.New()
	chip.LockConfigForTest()
	d := se608.NewPolicy(chip, lab.Policy)
	r := do(t, d, func(s *se608.Session) (lab.Result, error) { return lab.PrivWriteClear(s, 4, [32]byte{31: 1}) })
	p := last(chip)
	if p[1] != 0x46 || p[2] != 0x00 || p[3] != 4 || len(p) != 7+68 || !bytes.Equal(p[5:9], []byte{0, 0, 0, 0}) || p[40] != 1 {
		t.Fatalf("PrivWrite packet % x", p)
	}
	if !r.IsStatus || r.Status != 0x0F {
		t.Fatalf("PrivWrite into a slot that is not a private key: %s, want status 0f", r)
	}
	r = do(t, d, func(s *se608.Session) (lab.Result, error) { return lab.UpdateExtra(s, lab.UpdateUserExtraAdd, 0x50) })
	if p = last(chip); !bytes.Equal(p[1:5], []byte{0x20, 0x01, 0x50, 0x00}) || !r.OK() || chip.Config[85] != 0x50 {
		t.Fatalf("UpdateExtra packet % x, result %s, byte 85 = %02x", p, r, chip.Config[85])
	}
	// byte 85 is write-once
	if r = do(t, d, func(s *se608.Session) (lab.Result, error) { return lab.UpdateExtra(s, lab.UpdateUserExtraAdd, 0x51) }); r.OK() {
		t.Fatal("byte 85 was written twice")
	}
	r = do(t, d, func(s *se608.Session) (lab.Result, error) { return lab.CounterInc(s, 1) })
	if p = last(chip); !bytes.Equal(p[1:5], []byte{0x24, 0x01, 0x01, 0x00}) || !bytes.Equal(r.Data, []byte{1, 0, 0, 0}) {
		t.Fatalf("Counter packet % x, result %s", p, r)
	}
	if r = do(t, d, func(s *se608.Session) (lab.Result, error) { return lab.CounterRead(s, 0) }); !bytes.Equal(r.Data, []byte{0, 0, 0, 0}) {
		t.Fatalf("counter 0 moved: %s", r)
	}
}

// prepared is a fake with the variant image, both zones locked, a MAC key in slot 3 (no NoMac) and a secret in
// slot 5 (NoMac), written straight into the fake's memory.
func prepared(t *testing.T) (*fakechip.Chip, *se608.Dev, [9]byte) {
	t.Helper()
	chip := fakechip.New()
	img := se608.Image(true, chip.Config[17])
	for _, w := range se608.ImageWords() {
		copy(chip.Config[4*w:4*w+4], img[4*w:4*w+4])
	}
	chip.Config[se608.LockConfigByte], chip.Config[se608.LockDataByte] = 0x00, 0x00
	for i := 0; i < 32; i++ {
		chip.Data[3][i] = byte(0x30 + i)
		chip.Data[5][i] = byte(0x50 + i)
	}
	return chip, se608.NewPolicy(chip, lab.Policy), se608.Serial(chip.Config)
}

// HostMAC, NonceTempKey and HostGenDig compute what the (fake) chip returns; a NoMac slot gives nothing, directly
// or through GenDig (config C4, E8).
func TestMACClassOnTheFake(t *testing.T) {
	chip, d, sn := prepared(t)
	chal := bytes.Repeat([]byte{0xC4}, 32)

	r := do(t, d, func(s *se608.Session) (lab.Result, error) { return lab.MAC(s, 0x00, 3, chal) })
	want := lab.HostMAC(chip.Data[3][:32], chal, 0x00, 3, sn)
	if r.IsStatus || !bytes.Equal(r.Data, want[:]) {
		t.Fatalf("MAC slot 3: %s\nhost       %x", r, want)
	}
	r = do(t, d, func(s *se608.Session) (lab.Result, error) { return lab.MAC(s, 0x40, 3, chal) })
	want = lab.HostMAC(chip.Data[3][:32], chal, 0x40, 3, sn)
	if r.IsStatus || !bytes.Equal(r.Data, want[:]) {
		t.Fatalf("MAC slot 3 with the serial: %s", r)
	}
	if r = do(t, d, func(s *se608.Session) (lab.Result, error) { return lab.MAC(s, 0x00, 5, chal) }); !r.IsStatus || r.Status != 0x0F {
		t.Fatalf("MAC on the NoMac slot: %s, want status 0f", r)
	}

	seq := func(slot int, other []byte) (n, g, m lab.Result) {
		err := d.Do(func(s *se608.Session) (err error) {
			if n, err = lab.NonceRandom(s, [20]byte{7}); err != nil {
				return err
			}
			if g, err = lab.GenDig(s, lab.GenDigData, uint16(slot), other); err != nil {
				return err
			}
			m, err = lab.MAC(s, 0x02, slot, chal)
			return err
		})
		if err != nil {
			t.Fatal(err)
		}
		return
	}
	n, g, m := seq(3, nil)
	tk := lab.NonceTempKey(n.Data, [20]byte{7}, 0x00)
	tk = lab.HostGenDig(chip.Data[3][:32], lab.GenDigData, 3, sn, tk, nil)
	want = lab.HostMAC(tk[:], chal, 0x02, 3, sn)
	if !g.OK() || m.IsStatus || !bytes.Equal(m.Data, want[:]) {
		t.Fatalf("Nonce + GenDig(3) + MAC: gendig %s mac %s\nhost %x", g, m, want)
	}
	_, g, m = seq(5, []byte{0, 0, 0, 0})
	if !g.OK() || !m.IsStatus || m.Status != 0x0F {
		t.Fatalf("Nonce + GenDig(NoMac slot) + MAC: gendig %s mac %s, want the MAC refused", g, m)
	}
}

func TestRandomAndPolicy(t *testing.T) {
	chip := fakechip.New()
	d := se608.NewPolicy(chip, lab.Policy)
	r := do(t, d, lab.Random)
	if r.IsStatus || !bytes.Equal(r.Data[:8], []byte{0xFF, 0xFF, 0, 0, 0xFF, 0xFF, 0, 0}) {
		t.Fatalf("Random before the config lock: %s", r)
	}
	chip.LockConfigForTest()
	r2 := do(t, d, lab.Random)
	if r2.IsStatus || bytes.Equal(r2.Data, r.Data) {
		t.Fatalf("Random after the config lock is still the pattern: %s", r2)
	}
	ops := len(chip.Ops)
	for _, op := range []byte{se608.OpDeriveKey, se608.OpVerify, se608.OpSelfTest, 0x99} {
		err := d.Do(func(s *se608.Session) error { _, err := lab.Raw(s, op, 0, 0, nil, 0); return err })
		if !errors.Is(err, se608.ErrRefused) {
			t.Fatalf("opcode %#x: %v, want ErrRefused", op, err)
		}
	}
	// se-lab's policy is wider than the product's, but a no-CRC Lock still cannot be sent
	err := d.Do(func(s *se608.Session) error { _, err := lab.Raw(s, se608.OpLock, 0x80, 0, nil, 0); return err })
	if !errors.Is(err, se608.ErrRefused) || len(chip.Ops) != ops {
		t.Fatalf("no-CRC Lock under the lab policy: %v", err)
	}
}

func TestForGood(t *testing.T) {
	for _, k := range []struct {
		c    se608.Cmd
		want bool
	}{
		{se608.LockConfigCmd(1), true}, {se608.LockDataCmd(1), true}, {se608.LockSlotCmd(6), true},
		{lab.UpdateExtraCmd(0, 1), true}, {lab.UpdateExtraCmd(1, 0xa0), true}, {lab.UpdateExtraCmd(2, 0), true},
		{lab.CounterCmd(true, 0), true}, {lab.CounterCmd(true, 1), true}, {lab.CounterCmd(false, 1), false},
		{se608.Cmd{Op: se608.OpWrite, P1: 0x82}, false}, {se608.Cmd{Op: se608.OpGenKey, P1: 0x04}, false},
		{se608.Cmd{Op: se608.OpRandom}, false},
	} {
		if got := lab.ForGood(k.c); got != k.want {
			t.Errorf("ForGood(opcode %#x mode %#x) = %v, want %v", k.c.Op, k.c.P1, got, k.want)
		}
	}
}
