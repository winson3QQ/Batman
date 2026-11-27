package se608_test

import (
	"bytes"
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"errors"
	"math/big"
	"testing"
	"time"

	"batman-prov/proto"
	"batman-prov/se608"
	"batman-prov/se608/fakechip"
)

// PR 2's CI must not start while the wire formats are unconfirmed (impl §2.2): this is the consumer of the mark.
func TestWireFormatsConfirmed(t *testing.T) {
	if se608.Provisional {
		t.Fatal("se608.Provisional is still set: E1-E3 must run on a real chip before the driver is used")
	}
}

func cmd(op, p1 byte, p2 uint16, n int) se608.Cmd {
	return se608.Cmd{Op: op, P1: p1, P2: p2, Data: make([]byte, n), RespLen: 1}
}

func TestPolicies(t *testing.T) {
	cases := []struct {
		name         string
		c            se608.Cmd
		daemon, burn bool
	}{
		{"Info revision", cmd(se608.OpInfo, 0, 0, 0), true, true},
		{"Info other mode", cmd(se608.OpInfo, 1, 0, 0), false, false},
		{"Read config 32", cmd(se608.OpRead, 0x80, 0, 0), true, true},
		{"Read data 4", cmd(se608.OpRead, 0x02, 0x40, 0), true, true},
		{"Read encrypted bit", cmd(se608.OpRead, 0x42, 0x40, 0), false, false},
		{"Nonce pass-through 32", cmd(se608.OpNonce, 0x03, 0, 32), true, true},
		{"Nonce pass-through 31", cmd(se608.OpNonce, 0x03, 0, 31), false, false},
		{"Nonce pass-through with a param2", cmd(se608.OpNonce, 0x03, 1, 32), false, false},
		{"Nonce random", cmd(se608.OpNonce, 0x00, 0, 20), false, false},
		{"Nonce pass-through to the alternate buffer", cmd(se608.OpNonce, 0x83, 0, 32), false, false},
		{"GenKey public", cmd(se608.OpGenKey, 0x00, 1, 0), true, true},
		{"GenKey create", cmd(se608.OpGenKey, 0x04, 1, 0), false, true},
		{"GenKey create slot 4", cmd(se608.OpGenKey, 0x04, 4, 0), false, false},
		{"GenKey public slot 2", cmd(se608.OpGenKey, 0x00, 2, 0), true, true},
		{"GenKey public slot 4", cmd(se608.OpGenKey, 0x00, 4, 0), false, false},
		{"GenKey digest", cmd(se608.OpGenKey, 0x10, 1, 0), false, false},
		{"Sign external", cmd(se608.OpSign, 0x80, 0, 0), true, true},
		{"Sign external slot 1", cmd(se608.OpSign, 0x80, 1, 0), false, false},
		{"Sign external slot 2", cmd(se608.OpSign, 0x80, 2, 0), false, false},
		{"Sign internal", cmd(se608.OpSign, 0x00, 1, 0), false, false},
		{"Sign internal with the session key slot", cmd(se608.OpSign, 0x00, 0, 0), false, false},
		{"Sign internal with SN, session key slot", cmd(se608.OpSign, 0x40, 0, 0), false, false},
		{"Sign internal with SN", cmd(se608.OpSign, 0x40, 1, 0), false, false},
		{"ECDH clear", cmd(se608.OpECDH, 0x0C, 2, 64), true, true},
		{"ECDH clear slot 0", cmd(se608.OpECDH, 0x0C, 0, 64), false, false},
		{"ECDH clear, 63 bytes", cmd(se608.OpECDH, 0x0C, 2, 63), false, false},
		{"ECDH to TempKey", cmd(se608.OpECDH, 0x08, 2, 64), false, false},
		{"ECDH encrypted", cmd(se608.OpECDH, 0x0E, 2, 64), false, false},
		{"ECDH to a slot", cmd(se608.OpECDH, 0x04, 2, 64), false, false},
		{"CheckMac mode 0", cmd(se608.OpCheckMac, 0x00, 5, 77), true, true},
		{"CheckMac slot 3", cmd(se608.OpCheckMac, 0x00, 3, 77), false, false},
		{"CheckMac, 76 bytes", cmd(se608.OpCheckMac, 0x00, 5, 76), false, false},
		{"CheckMac copy mode", cmd(se608.OpCheckMac, 0x01, 5, 77), false, false},
		{"Write config", cmd(se608.OpWrite, 0x00, 5, 4), false, true},
		{"Write OTP", cmd(se608.OpWrite, 0x81, 0, 32), false, true},
		{"Write encrypted", cmd(se608.OpWrite, 0xC2, 0, 64), false, false},
		{"Lock config", cmd(se608.OpLock, 0x00, 0x1234, 0), false, true},
		{"Lock data", cmd(se608.OpLock, 0x01, 0x1234, 0), false, true},
		{"Lock slot 0", cmd(se608.OpLock, 0x02, 0, 0), false, true},
		{"Lock slot 2", cmd(se608.OpLock, 0x0A, 0, 0), false, true},
		{"Lock slot 3", cmd(se608.OpLock, 0x0E, 0, 0), false, false},
		{"Lock slot 4", cmd(se608.OpLock, 0x12, 0, 0), false, false},
		{"Lock slot 8 (the certificate: never on the bench)", cmd(se608.OpLock, 0x22, 0, 0), false, false},
		{"Lock slot with a CRC field", cmd(se608.OpLock, 0x06, 0x0001, 0), false, false},
		{"Lock config with data", cmd(se608.OpLock, 0x00, 0x1234, 1), false, false},
		{"Write of 5 bytes", cmd(se608.OpWrite, 0x00, 5, 5), false, false},
		{"Lock zone 3", cmd(se608.OpLock, 0x03, 0, 0), false, false},
		{"UpdateExtra", cmd(se608.OpUpdateExtra, 1, 0x50, 0), false, false},
		{"PrivWrite", cmd(se608.OpPrivWrite, 0, 4, 68), false, false},
		{"Counter", cmd(se608.OpCounter, 1, 1, 0), false, false},
		{"Random", cmd(se608.OpRandom, 0, 0, 0), false, false},
		{"MAC", cmd(se608.OpMAC, 0, 5, 32), false, false},
		{"KDF", cmd(se608.OpKDF, 0x52, 5, 20), false, false},
	}
	for _, c := range cases {
		if got := se608.PolicyDaemon(c.c) == nil; got != c.daemon {
			t.Errorf("%s: daemon allows = %v, want %v", c.name, got, c.daemon)
		}
		if got := se608.PolicyBurn(c.c) == nil; got != c.burn {
			t.Errorf("%s: burn allows = %v, want %v", c.name, got, c.burn)
		}
		if err := se608.PolicyDaemon(c.c); err != nil && !errors.Is(err, se608.ErrRefused) {
			t.Errorf("%s: %v does not wrap ErrRefused", c.name, err)
		}
	}
}

func allowAll(se608.Cmd) error { return nil }

// A Lock that tells the chip to skip its CRC check is never sent, whatever the policy. The control: the same
// packets put on the bus directly do lock the fake, so it is the driver that stops them.
func TestNoCRCLockNeverSent(t *testing.T) {
	modes := []byte{0x80, 0x81, 0x92, 0x40}
	for _, p := range []se608.Policy{se608.PolicyDaemon, se608.PolicyBurn, allowAll} {
		chip := fakechip.New()
		d := se608.NewPolicy(chip, p)
		for _, m := range modes {
			err := d.Do(func(s *se608.Session) error {
				_, err := s.Exec(se608.Cmd{Op: se608.OpLock, P1: m, RespLen: 1, MaxExec: se608.MaxExec(se608.OpLock)})
				return err
			})
			if !errors.Is(err, se608.ErrRefused) {
				t.Fatalf("Lock mode %#x: %v, want ErrRefused", m, err)
			}
		}
		if len(chip.Ops) != 0 || chip.Config[se608.LockConfigByte] != 0x55 {
			t.Fatalf("a no-CRC Lock reached the chip: ops % x", chip.Ops)
		}
	}
	// control
	chip := fakechip.New()
	pkt, err := se608.Cmd{Op: se608.OpLock, P1: 0x80}.Packet()
	if err != nil {
		t.Fatal(err)
	}
	_ = chip.Write(0x00, []byte{0x00})
	if err := chip.Write(se608.Addr, pkt); err != nil {
		t.Fatal(err)
	}
	if chip.Config[se608.LockConfigByte] != 0x00 {
		t.Fatal("control: the fake did not honour a no-CRC Lock, so the test above proves nothing")
	}
}

func verify(t *testing.T, pub [64]byte, digest [32]byte, sig [64]byte) bool {
	t.Helper()
	k := ecdsa.PublicKey{Curve: elliptic.P256(), X: new(big.Int).SetBytes(pub[:32]), Y: new(big.Int).SetBytes(pub[32:])}
	return ecdsa.Verify(&k, digest[:], new(big.Int).SetBytes(sig[:32]), new(big.Int).SetBytes(sig[32:]))
}

type burned struct {
	chip   *fakechip.Chip
	secret [32]byte
	pub    [3][64]byte
}

// burn walks the bench burn (255-608b-config.md §5.2, S0-S2) on a fake with the product's burn policy: the final
// image, the config lock, the data content, the data lock, three keys, three slot locks.
func burn(t *testing.T) burned {
	t.Helper()
	chip := fakechip.New()
	d := se608.NewBurn(chip)
	img := se608.Image(false, chip.Config[17])
	if _, err := d.WriteConfigImage(img); err != nil {
		t.Fatal(err)
	}
	cfg, err := d.ReadConfig()
	if err != nil || len(se608.DiffImage(cfg, img)) != 0 {
		t.Fatalf("read back: %v", err)
	}
	if err := d.Do(func(s *se608.Session) error { return s.LockConfig(se608.ConfigCRC(cfg)) }); err != nil {
		t.Fatal(err)
	}
	b := burned{chip: chip}
	_, _ = rand.Read(b.secret[:])
	var data [16][]byte
	for i := range data {
		data[i] = make([]byte, se608.SlotSize[i])
		if i == 5 {
			copy(data[i], b.secret[:])
		}
		if se608.SlotIsPrivate(cfg, i) {
			continue
		}
		if err := d.WriteSlot(i, data[i]); err != nil {
			t.Fatalf("slot %d: %v", i, err)
		}
	}
	var otp [se608.OTPLen]byte
	if err := d.Do(func(s *se608.Session) error {
		if err := s.Write(se608.ZoneOTP, 0, otp[:32]); err != nil {
			return err
		}
		return s.Write(se608.ZoneOTP, 1<<3, otp[32:])
	}); err != nil {
		t.Fatal(err)
	}
	crc, err := se608.DataCRC(cfg, data, otp)
	if err != nil {
		t.Fatal(err)
	}
	if err := d.Do(func(s *se608.Session) error { return s.LockData(crc) }); err != nil {
		t.Fatalf("data lock: %v", err)
	}
	for slot := 0; slot < 3; slot++ {
		if err := d.Do(func(s *se608.Session) (err error) {
			if b.pub[slot], err = s.GenKeyCreate(slot); err != nil {
				return err
			}
			return s.LockSlot(slot)
		}); err != nil {
			t.Fatalf("slot %d: %v", slot, err)
		}
	}
	return b
}

func wantStatus(t *testing.T, what string, err error, code byte) {
	t.Helper()
	var se *se608.StatusError
	if !errors.As(err, &se) || se.Code != code {
		t.Fatalf("%s: %v, want status 0x%02x", what, err, code)
	}
}

// The burned chip through the daemon's driver: the three key roles (config §2), the claim check, and the lock
// state the read-back rule of config §4 expects.
func TestBurnedChipAsTheDaemonSeesIt(t *testing.T) {
	b := burn(t)
	d := se608.New(b.chip)
	cfg, err := d.ReadConfig()
	if err != nil {
		t.Fatal(err)
	}
	if cfg[86] != 0x00 || cfg[87] != 0x00 || cfg[88] != 0xF8 || cfg[89] != 0xFF {
		t.Fatalf("lock bytes 86-89 = % x, want 00 00 f8 ff (config §4)", cfg[86:90])
	}

	// slot 0: the session key signs a digest the host gives it
	digest := sha256.Sum256([]byte("batman-node-session-v1 test"))
	sig, err := d.SignDigest(0, digest)
	if err != nil || !verify(t, b.pub[0], digest, sig) {
		t.Fatalf("slot 0 external sign: %v", err)
	}
	other := sha256.Sum256([]byte("another digest"))
	if verify(t, b.pub[0], other, sig) {
		t.Fatal("control: the signature verifies for a different digest")
	}
	// slot 1 (internal sign only) and slot 2 (ECDH only): the daemon's policy does not send it, and the chip
	// itself refuses when it is sent anyway
	anyDev := se608.NewPolicy(b.chip, allowAll)
	for _, slot := range []int{1, 2} {
		ops := len(b.chip.Ops)
		if _, err = d.SignDigest(slot, digest); !errors.Is(err, se608.ErrRefused) || len(b.chip.Ops) != ops+1 {
			t.Fatalf("daemon: external sign with slot %d: %v (only the Nonce may have been sent)", slot, err)
		}
		_, err = anyDev.SignDigest(slot, digest)
		wantStatus(t, "external sign with a slot that may not", err, 0x0F)
	}

	// slot 2: ECDH equals the software computation; slots 0 and 1 refuse
	host, _ := ecdh.P256().GenerateKey(rand.Reader)
	var peer [64]byte
	copy(peer[:], host.PublicKey().Bytes()[1:])
	var z [32]byte
	if err := d.Do(func(s *se608.Session) (err error) { z, err = s.ECDH(2, peer); return }); err != nil {
		t.Fatal(err)
	}
	chipPub, _ := ecdh.P256().NewPublicKey(append([]byte{0x04}, b.pub[2][:]...))
	want, _ := host.ECDH(chipPub)
	if !bytes.Equal(z[:], want) {
		t.Fatal("ECDH differs from the software result")
	}
	for _, slot := range []int{0, 1} {
		ops := len(b.chip.Ops)
		err := d.Do(func(s *se608.Session) (err error) { _, err = s.ECDH(slot, peer); return })
		if !errors.Is(err, se608.ErrRefused) || len(b.chip.Ops) != ops {
			t.Fatalf("daemon: ECDH with slot %d: %v", slot, err)
		}
		err = anyDev.Do(func(s *se608.Session) (err error) { _, err = s.ECDH(slot, peer); return })
		wantStatus(t, "ECDH with a slot that may not", err, 0x0F)
	}

	// public keys read back equal the ones GenKey returned
	for slot := 0; slot < 3; slot++ {
		var pub [64]byte
		if err := d.Do(func(s *se608.Session) (err error) { pub, err = s.PubKey(slot); return }); err != nil || pub != b.pub[slot] {
			t.Fatalf("slot %d public key: %v", slot, err)
		}
	}

	// slot 5: CheckMac with the product's hash input and the chip's own serial
	sn := se608.Serial(cfg)
	var chal [32]byte
	_, _ = rand.Read(chal[:])
	in, err := proto.CheckMacInput(b.secret[:], chal[:], sn[:])
	if err != nil {
		t.Fatal(err)
	}
	resp := sha256.Sum256(in)
	check := func(resp [32]byte) (ok bool, err error) {
		err = d.Do(func(s *se608.Session) (err error) { ok, err = s.CheckMac(5, chal, resp, proto.OtherData); return })
		return
	}
	if ok, err := check(resp); err != nil || !ok {
		t.Fatalf("CheckMac with the right response: %v %v", ok, err)
	}
	bad := resp
	bad[0] ^= 0x80
	if ok, err := check(bad); err != nil || ok {
		t.Fatalf("CheckMac with a wrong response: %v %v, want false, nil", ok, err)
	}
	// a chip that does not answer is an error, never "wrong response" (review v6set-A M2)
	b.chip.DropWakes = 2
	if ok, err := check(resp); err == nil || ok || !se608.IsTransport(err) {
		t.Fatalf("CheckMac with the chip silent: %v %v, want a transport error", ok, err)
	}
	// neither is a garbled answer to the command itself, nor a status other than "miscompare"
	b.chip.CorruptNext = true
	if ok, err := check(resp); err == nil || ok || !se608.IsTransport(err) {
		t.Fatalf("CheckMac with a corrupt response: %v %v, want a transport error", ok, err)
	}
	var okPriv bool
	err = anyDev.Do(func(s *se608.Session) (err error) { okPriv, err = s.CheckMac(0, chal, resp, proto.OtherData); return })
	if okPriv {
		t.Fatal("CheckMac on a private-key slot reported a match")
	}
	wantStatus(t, "CheckMac on a slot the chip refuses", err, 0x0F)
	// the secret cannot be read
	err = d.Do(func(s *se608.Session) (err error) {
		_, err = s.Read(se608.ZoneData, se608.DataAddr(5, 0, 0), 32)
		return
	})
	wantStatus(t, "read of the claim slot", err, 0x0F)
	// the daemon cannot write, lock or generate
	for name, fn := range map[string]func(*se608.Session) error{
		"Write": func(s *se608.Session) error {
			return s.Write(se608.ZoneData, se608.DataAddr(8, 0, 0), make([]byte, 32))
		},
		"LockSlot":     func(s *se608.Session) error { return s.LockSlot(8) },
		"GenKeyCreate": func(s *se608.Session) error { _, err := s.GenKeyCreate(0); return err },
	} {
		ops := len(b.chip.Ops)
		if err := d.Do(fn); !errors.Is(err, se608.ErrRefused) || len(b.chip.Ops) != ops {
			t.Fatalf("daemon %s: %v", name, err)
		}
	}
}

// After the burn the chip itself holds the line, burn-mode driver or not (config C1, C9).
func TestBurnedChipRefusesChanges(t *testing.T) {
	b := burn(t)
	d := se608.NewBurn(b.chip)
	for slot := 0; slot < 3; slot++ {
		err := d.Do(func(s *se608.Session) (err error) { _, err = s.GenKeyCreate(slot); return })
		wantStatus(t, "GenKey on a locked key slot", err, 0x0F)
	}
	for _, slot := range []int{3, 5, 15} {
		err := d.Do(func(s *se608.Session) error {
			return s.Write(se608.ZoneData, se608.DataAddr(slot, 0, 0), make([]byte, 32))
		})
		wantStatus(t, "write to a never-writable slot", err, 0x0F)
	}
	err := d.Do(func(s *se608.Session) error { return s.Write(se608.ZoneConfig, 5, make([]byte, 4)) })
	wantStatus(t, "config write after the lock", err, 0x0F)
	ops := len(b.chip.Ops)
	for _, slot := range []int{5, 8} {
		if err = d.Do(func(s *se608.Session) error { return s.LockSlot(slot) }); !errors.Is(err, se608.ErrRefused) || len(b.chip.Ops) != ops {
			t.Fatalf("burn mode: Lock of slot %d was not stopped by the policy: %v", slot, err)
		}
	}
	err = se608.NewPolicy(b.chip, allowAll).Do(func(s *se608.Session) error { return s.LockSlot(5) })
	wantStatus(t, "slot lock of a slot that is not lockable", err, 0x0F)
	// slot 8 (the certificate) stays writable and readable: 416 bytes round-trip
	cert := make([]byte, se608.SlotSize[8])
	_, _ = rand.Read(cert[:300])
	if err := d.WriteSlot(8, cert); err != nil {
		t.Fatal(err)
	}
	got, err := se608.New(b.chip).ReadSlot(8)
	if err != nil || !bytes.Equal(got, cert) {
		t.Fatalf("slot 8 round-trip: %v", err)
	}
}

// A wrong CRC makes the chip refuse the lock and leaves it unlocked: the driver's CRC functions are what the lock
// depends on, and the chip is what checks them.
func TestLockRefusedOnWrongCRC(t *testing.T) {
	chip := fakechip.New()
	d := se608.NewBurn(chip)
	img := se608.Image(true, chip.Config[17])
	if _, err := d.WriteConfigImage(img); err != nil {
		t.Fatal(err)
	}
	cfg, _ := d.ReadConfig()
	crc := se608.ConfigCRC(cfg)
	err := d.Do(func(s *se608.Session) error { return s.LockConfig(crc ^ 1) })
	wantStatus(t, "config lock with a wrong CRC", err, 0x0F)
	if cfg, _ = d.ReadConfig(); se608.ConfigLocked(cfg) {
		t.Fatal("locked despite the wrong CRC")
	}
	// a byte changed between the read and the lock: the CRC of the earlier read no longer fits
	chip.Config[84] = 0x01
	err = d.Do(func(s *se608.Session) error { return s.LockConfig(crc) })
	wantStatus(t, "config lock after a byte changed", err, 0x0F)
	chip.Config[84] = 0x00
	if err := d.Do(func(s *se608.Session) error { return s.LockConfig(crc) }); err != nil {
		t.Fatal(err)
	}
	cfg, _ = d.ReadConfig()

	var data [16][]byte
	for i := range data {
		data[i] = make([]byte, se608.SlotSize[i])
	}
	var otp [se608.OTPLen]byte
	data[6][35] = 0x5A // written to the chip below: the last 4 bytes of a 36-byte slot count (E6)
	if err := d.WriteSlot(6, data[6]); err != nil {
		t.Fatal(err)
	}
	// Non-zero content in slot 3, right before the private-key slot 4: a CRC that wrongly included slot 4's 36
	// bytes would now differ (zeros in front of everything else would not show, the CRC starts at 0).
	data[3][0] = 0x33
	if err := d.WriteSlot(3, data[3]); err != nil {
		t.Fatal(err)
	}
	// A 72-byte slot: two blocks and two tail words, every byte different, so a wrong tail address shows.
	for i := range data[9] {
		data[9][i] = byte(i + 1)
	}
	if err := d.WriteSlot(9, data[9]); err != nil || !bytes.Equal(chip.Data[9], data[9]) {
		t.Fatalf("72-byte slot: %v\nchip % x", err, chip.Data[9])
	}
	good, _ := se608.DataCRC(cfg, data, otp)
	withPrivate := se608.CRC(append(append(append([]byte{}, flat(data[:4])...), make([]byte, 36)...), append(flat(data[5:]), otp[:]...)...))
	if good == withPrivate {
		t.Fatal("the test content cannot tell whether the private slot 4 is skipped")
	}
	data[6][35] = 0x00
	stale, _ := se608.DataCRC(cfg, data, otp)
	if good == stale {
		t.Fatal("the CRC does not cover the tail of a 36-byte slot")
	}
	err = d.Do(func(s *se608.Session) error { return s.LockData(stale) })
	wantStatus(t, "data lock with the CRC of other content", err, 0x0F)
	if err := d.Do(func(s *se608.Session) error { return s.LockData(good) }); err != nil {
		t.Fatal(err)
	}
}

// The variant image on the real blank chip's bytes (E1 dump) gives the CRC and the Lock packet the independent
// check computed from the real chip's read-back (255-608b-config.md §8.3: 0x9022, 03 07 17 00 22 90 1d 15).
func TestChip1LockPacketGolden(t *testing.T) {
	chip := fakechip.New()
	chip.Config = fakechip.RealBlank()
	d := se608.NewBurn(chip)
	n, err := d.WriteConfigImage(se608.Image(true, 0x00))
	if err != nil || n != 16 {
		t.Fatalf("wrote %d words (the real chip: 16): %v", n, err)
	}
	cfg, err := d.ReadConfig()
	if err != nil {
		t.Fatal(err)
	}
	if crc := se608.ConfigCRC(cfg); crc != 0x9022 {
		t.Fatalf("config CRC %04x, want 9022", crc)
	}
	pkt, _ := se608.LockConfigCmd(se608.ConfigCRC(cfg)).Packet()
	if want := []byte{0x03, 0x07, 0x17, 0x00, 0x22, 0x90, 0x1d, 0x15}; !bytes.Equal(pkt, want) {
		t.Fatalf("lock packet % x, want % x", pkt, want)
	}
	final := se608.Image(false, 0x00)
	if got := sha256.Sum256(final[16:]); got != [32]byte(mustHex(t, "2484b15e80f81f58ea4de0387d5b9ddb81b455b4e14ca0c528a6ef8d44fb0e2c")) {
		t.Fatalf("final image hash %x differs from the independent check", got)
	}
}

func mustHex(t *testing.T, s string) []byte {
	t.Helper()
	b := make([]byte, len(s)/2)
	for i := range b {
		var v byte
		for _, c := range []byte(s[2*i : 2*i+2]) {
			v <<= 4
			switch {
			case c >= '0' && c <= '9':
				v |= c - '0'
			case c >= 'a' && c <= 'f':
				v |= c - 'a' + 10
			default:
				t.Fatalf("bad hex %q", s)
			}
		}
		b[i] = v
	}
	return b
}

// The product's sign sequence fits the watchdog with margin; a sequence that does not is cut off by the fake.
func TestSignSequenceUnderWatchdog(t *testing.T) {
	b := burn(t)
	b.chip.Watchdog = 200 * time.Millisecond // Nonce 20 + 20, Sign 115 + 20 = 175 ms worst case
	if _, err := se608.New(b.chip).SignDigest(0, [32]byte{1}); err != nil {
		t.Fatalf("sign under a 200 ms watchdog: %v", err)
	}
	b.chip.Watchdog = 150 * time.Millisecond
	if _, err := se608.New(b.chip).SignDigest(0, [32]byte{1}); err == nil {
		t.Fatal("control: the fake's watchdog did not cut a 175 ms sequence at 150 ms")
	}
}

func flat(slots [][]byte) []byte {
	var out []byte
	for _, s := range slots {
		out = append(out, s...)
	}
	return out
}

// A Dev made without a policy gets the daemon's, not "everything".
func TestNilPolicyIsTheDaemons(t *testing.T) {
	chip := fakechip.New()
	d := se608.NewPolicy(chip, nil)
	err := d.Do(func(s *se608.Session) error { return s.Write(se608.ZoneConfig, 5, make([]byte, 4)) })
	if !errors.Is(err, se608.ErrRefused) || len(chip.Ops) != 0 {
		t.Fatalf("a Write under a nil policy: %v", err)
	}
	if err := d.Do(func(s *se608.Session) error { _, err := s.Revision(); return err }); err != nil {
		t.Fatal(err)
	}
}

// A Lock keeps being polled well past the vendor table's 35 ms (code review PR D2 B-M3): the 608B's Lock timing is
// not the table's, and an answer given up on is a lock nobody knows about.
func TestLockIsPolledPastTheTable(t *testing.T) {
	chip := fakechip.New()
	d := se608.NewBurn(chip)
	fc := &fakeClock{t: time.Unix(0, 0)}
	d.SetClock(fc.sleep, fc.now)
	img := se608.Image(false, chip.Config[17])
	if _, err := d.WriteConfigImage(img); err != nil {
		t.Fatal(err)
	}
	cfg, _ := d.ReadConfig()
	chip.SlowLockPolls = 400 // 400 polls of 1 ms: far beyond 35 + 20 ms, inside 500 + 20 ms
	if err := d.Do(func(s *se608.Session) error { return s.LockConfig(se608.ConfigCRC(cfg)) }); err != nil {
		t.Fatalf("a Lock that answers after 200 ms: %v", err)
	}
	if se608.LockPoll < 400*time.Millisecond || se608.LockPoll > 550*time.Millisecond {
		t.Fatalf("LockPoll %v: long enough for a slow Lock, short enough that 4 reads + Lock stay under the 0.7 s watchdog", se608.LockPoll)
	}
}

// With a fake clock the cap is exact: an answer later than LockPoll + the margin is given up on (the control: the
// test above is not passing because the driver waits forever).
func TestLockPollIsACap(t *testing.T) {
	chip := fakechip.New()
	d := se608.NewBurn(chip)
	fc := &fakeClock{t: time.Unix(0, 0)}
	d.SetClock(fc.sleep, fc.now)
	if _, err := d.WriteConfigImage(se608.Image(false, chip.Config[17])); err != nil {
		t.Fatal(err)
	}
	cfg, _ := d.ReadConfig()
	chip.SlowLockPolls = 700
	err := d.Do(func(s *se608.Session) error { return s.LockConfig(se608.ConfigCRC(cfg)) })
	if !se608.IsTransport(err) {
		t.Fatalf("an answer after 700 ms: %v, want a transport error", err)
	}
}

// Every Lock the burn mode sends is in a sequence of its own or after at most the four config reads: with the driver
// waiting up to LockPoll, a Lock that shares a sequence with GenKey (115 ms) and more must be cut by the fake's
// watchdog, so a burn tool that packs them together fails in CI and not on the chip (round 2 A-N-m2).
func TestLongSequencesHitTheWatchdog(t *testing.T) {
	b := burn(t) // burn() puts GenKey + Lock(slot) of one slot per sequence: 115 + 500 + 2*20 = 655 ms, under 700
	d := se608.NewPolicy(b.chip, allowAll)
	// two slot locks and a GenKey in one sequence: 115 + 2*500 + 3*20 > 700
	err := d.Do(func(s *se608.Session) error {
		if _, err := s.PubKey(0); err != nil {
			return err
		}
		if err := s.LockSlot(1); se608.IsTransport(err) {
			return err // cut already
		} // a refusal (slot 1 is locked) is not the point here: the chip still spent the time
		return s.LockSlot(2)
	})
	if err == nil || !se608.IsTransport(err) {
		t.Fatalf("a sequence of GenKey + two Locks: %v, want the watchdog to cut it", err)
	}
}
