//go:build linux

package main

import (
	"bytes"
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"math/big"
	"strconv"
	"time"

	"batman-prov/proto"
	"batman-prov/se608"
	"batman-prov/se608/lab"
)

// --- the test content of chip 1 -----------------------------------------------------------------------------

// testKey derives a 32-byte test value from a label and the chip's serial. It is not a secret (anyone who knows
// the serial can compute it) and is never a real claim secret: se-lab only ever works on sacrificial chips.
func testKey(label string, sn [9]byte) [32]byte {
	return sha256.Sum256(append([]byte("se-lab test "+label+" "), sn[:]...))
}

// modelSlot is what fill-data writes into slot: the claim test secret in slot 5, a MAC test key in slot 3 (the
// variant's control slot, §8.1), zeros everywhere else. The 4 bytes after a 32-byte key stay zero.
func modelSlot(slot int, sn [9]byte) []byte {
	b := make([]byte, se608.SlotSize[slot])
	switch slot {
	case 5:
		k := testKey("claim secret", sn)
		copy(b, k[:])
	case 3:
		k := testKey("slot 3 key", sn)
		copy(b, k[:])
	}
	return b
}

func modelKey(slot int, sn [9]byte) []byte { return modelSlot(slot, sn)[:32] }

// try runs one command in its own sequence and prints "key=<status or data>". ok is false on a transport failure.
func (c *ctx) try(key string, fn func(*se608.Session) (lab.Result, error)) (lab.Result, bool) {
	var r lab.Result
	err := c.d.Do(func(s *se608.Session) (err error) { r, err = fn(s); return })
	if err != nil {
		c.errf("%s: %v", key, err)
		return r, false
	}
	c.outf("%s=%s\n", key, r)
	return r, true
}

func exitFor(ok bool) int {
	if ok {
		return exitOK
	}
	return exitFail
}

func yesNo(b bool) string {
	if b {
		return "yes"
	}
	return "no"
}

// --- read-only ------------------------------------------------------------------------------------------------

// cmdSoak measures the bus: N times a wake, Info, a full config read and a comparison with the first read. A
// hand-soldered joint that is marginal shows up here as errors, before any step that cannot be repeated.
func cmdSoak(c *ctx) int {
	n, err := strconv.Atoi(c.args[0])
	if err != nil || n < 1 || n > 100000 {
		c.errf("soak count %q is not 1-100000", c.args[0])
		return exitUsage
	}
	var bad, differ int
	var first error
	for i := 0; i < n; i++ {
		var rev [4]byte
		err := c.d.Do(func(s *se608.Session) (err error) { rev, err = s.Revision(); return })
		var cfg [se608.ConfigLen]byte
		if err == nil {
			cfg, err = c.d.ReadConfig()
		}
		switch {
		case err != nil:
			bad++
			if first == nil {
				first = err
			}
		case rev != se608.Rev608B || cfg != c.cfg:
			differ++
		}
	}
	c.outf("soak_rounds=%d\nsoak_errors=%d\nsoak_differ=%d\n", n, bad, differ)
	if first != nil {
		c.outf("soak_first_error=%v\n", first)
	}
	return exitFor(bad == 0 && differ == 0)
}

func cmdPubKey(c *ctx) int {
	slot, ok := c.slotArg(0)
	if !ok {
		return exitUsage
	}
	_, ok = c.try("pubkey_slot"+c.args[0], func(s *se608.Session) (lab.Result, error) { return lab.GenKey(s, se608.GenKeyPublic, slot) })
	return exitFor(ok)
}

func cmdCounterRead(c *ctx) int { return c.counter(false) }
func cmdCounterInc(c *ctx) int  { return c.counter(true) }

func (c *ctx) counter(inc bool) int {
	id, err := strconv.Atoi(c.args[0])
	if err != nil || id < 0 || id > 1 {
		c.errf("counter %q is not 0 or 1", c.args[0])
		return exitUsage
	}
	key := "counter" + c.args[0]
	cmd := lab.CounterCmd(inc, id)
	if !inc {
		r, ok := c.try(key, func(s *se608.Session) (lab.Result, error) { return lab.Try(s, cmd) })
		if ok {
			c.printCounter(key, r)
		}
		return exitFor(ok)
	}
	if id != 1 {
		return c.refuse("counter-inc only increments Counter[1]: Counter[0] is never touched (255-608b-config.md E11)")
	}
	if !se608.ConfigLocked(c.cfg) {
		return c.refuse("counter-inc before the config lock is not an experiment in the list")
	}
	// The one step that is not idempotent: show where the counter is before anything is sent, in the dry run too,
	// so an operator back from a dropped connection can see whether it already happened (round 2 B-m9).
	before, ok := c.try(key+"_before", func(s *se608.Session) (lab.Result, error) { return lab.Try(s, lab.CounterCmd(false, id)) })
	if !ok {
		return exitFail
	}
	c.printCounter(key+"_before", before)
	pkt, _ := cmd.Packet()
	c.outf("packet=% x\n", pkt)
	if c.dry {
		c.outf("dry_run=nothing sent\n")
		return exitOK
	}
	var r lab.Result
	err = c.d.Do(func(s *se608.Session) (err error) { r, err = lab.Try(s, cmd); return })
	if err == nil {
		c.outf("%s_after_inc=%s\n", key, r)
		c.printCounter(key+"_after_inc", r)
		if r.IsStatus {
			c.outf("%s_inc_result=status_%02x\n", key, r.Status)
			return exitOK // E11 records a refusal as an answer, not a failure
		}
		c.outf("%s_inc_result=incremented\n", key)
		return exitOK
	}
	// No usable answer: the increment may or may not have happened. Read the counter, say which, never resend.
	c.errf("%s: %v", key, err)
	after, ok := c.try(key+"_read_back", func(s *se608.Session) (lab.Result, error) { return lab.Try(s, lab.CounterCmd(false, id)) })
	switch {
	case !ok || after.IsStatus || len(after.Data) != 4 || before.IsStatus || len(before.Data) != 4:
		c.outf("%s_inc_result=UNKNOWN_read_back_failed\n", key)
	case !bytes.Equal(after.Data, before.Data):
		c.printCounter(key+"_read_back", after)
		c.outf("%s_inc_result=INCREMENTED_answer_lost\n", key)
	default:
		c.outf("%s_inc_result=NOT_INCREMENTED_answer_lost\n", key)
	}
	return exitFail
}

func (c *ctx) printCounter(key string, r lab.Result) {
	if !r.IsStatus && len(r.Data) == 4 {
		d := r.Data
		c.outf("%s_le=%d\n", key, uint32(d[0])|uint32(d[1])<<8|uint32(d[2])<<16|uint32(d[3])<<24)
	}
}

func zoneArg(s string) (se608.Zone, bool) {
	switch s {
	case "config":
		return se608.ZoneConfig, true
	case "otp":
		return se608.ZoneOTP, true
	case "data":
		return se608.ZoneData, true
	}
	return 0, false
}

func (c *ctx) zoneAddr() (se608.Zone, uint16, bool) {
	z, ok := zoneArg(c.args[0])
	a, err := strconv.ParseUint(c.args[1], 16, 16)
	if !ok || err != nil {
		c.errf("want ZONE (config|otp|data) and P2 in hex, got %q %q", c.args[0], c.args[1])
		return 0, 0, false
	}
	return z, uint16(a), true
}

func sizeBit(n int) byte {
	if n == 32 {
		return 0x80
	}
	return 0
}

func cmdRead(c *ctx) int {
	z, addr, ok := c.zoneAddr()
	n, err := strconv.Atoi(c.args[2])
	if !ok || err != nil || (n != 4 && n != 32) {
		c.errf("read ZONE P2 LEN: LEN is 4 or 32")
		return exitUsage
	}
	_, ok = c.try("read_"+c.args[0]+"_"+c.args[1], func(s *se608.Session) (lab.Result, error) {
		return lab.Try(s, se608.Cmd{Op: se608.OpRead, P1: byte(z) | sizeBit(n), P2: addr})
	})
	return exitFor(ok)
}

func cmdSlotRead(c *ctx) int {
	slot, ok := c.slotArg(0)
	if !ok {
		return exitUsage
	}
	b, err := c.d.ReadSlot(slot)
	var se *se608.StatusError
	switch {
	case errors.As(err, &se):
		c.outf("slot%d=status_%02x\n", slot, se.Code)
		return exitOK
	case err != nil:
		c.errf("slot-read: %v", err)
		return exitFail
	}
	c.outf("slot%d=%s\n", slot, hex.EncodeToString(b))
	return exitOK
}

// --- rewritable -----------------------------------------------------------------------------------------------

func cmdConfigWrite(c *ctx) int {
	w, err := strconv.Atoi(c.args[0])
	if err != nil || w < 0 || w > 31 {
		c.errf("config word %q is not 0-31", c.args[0])
		return exitUsage
	}
	b, ok := c.hexArg(1, "the word", 4)
	if !ok {
		return exitUsage
	}
	_, ok = c.try("config_write_word"+c.args[0], func(s *se608.Session) (lab.Result, error) {
		return lab.Try(s, se608.Cmd{Op: se608.OpWrite, P1: byte(se608.ZoneConfig), P2: uint16(w), Data: b})
	})
	return exitFor(ok)
}

func cmdWrite(c *ctx) int {
	z, addr, ok := c.zoneAddr()
	if !ok {
		return exitUsage
	}
	b, ok := c.hexArg(2, "the data", 4, 32)
	if !ok {
		return exitUsage
	}
	_, ok = c.try("write_"+c.args[0]+"_"+c.args[1], func(s *se608.Session) (lab.Result, error) {
		return lab.Try(s, se608.Cmd{Op: se608.OpWrite, P1: byte(z) | sizeBit(len(b)), P2: addr, Data: b})
	})
	return exitFor(ok)
}

// cmdPrivWrite writes a test private key in clear (E6: must work before the data lock and fail after it) and
// prints the public key it belongs to, so a later `pubkey SLOT` can be compared.
func cmdPrivWrite(c *ctx) int {
	slot, ok := c.slotArg(0)
	if !ok {
		return exitUsage
	}
	scalar := testKey("private key slot "+c.args[0], c.sn)
	k, err := ecdh.P256().NewPrivateKey(scalar[:])
	if err != nil {
		c.errf("priv-write: test scalar: %v", err)
		return exitFail
	}
	c.outf("expected_pub_slot%d=%s\n", slot, hex.EncodeToString(k.PublicKey().Bytes()[1:]))
	_, ok = c.try("priv_write_slot"+c.args[0], func(s *se608.Session) (lab.Result, error) { return lab.PrivWriteClear(s, slot, scalar) })
	return exitFor(ok)
}

// cmdFillData writes the test content into every slot that is not a private key, and zeros into the OTP zone
// (E5: whether the chip takes an OTP write in this window is recorded, not required). It needs the config zone
// locked and the data zone not yet locked.
func cmdFillData(c *ctx) int {
	switch {
	case !se608.ConfigLocked(c.cfg):
		return c.refuse("the config zone is not locked: the data zone cannot be written yet")
	case se608.DataLocked(c.cfg):
		return c.refuse("the data zone is already locked")
	}
	failed := 0
	for slot := 0; slot < 16; slot++ {
		if se608.SlotIsPrivate(c.cfg, slot) {
			c.outf("slot%d=private_key_slot_skipped\n", slot)
			continue
		}
		err := c.d.WriteSlot(slot, modelSlot(slot, c.sn))
		if err != nil {
			failed++
			c.outf("slot%d=FAILED %v\n", slot, err)
			if se608.IsTransport(err) {
				c.errf("fill-data: %v", err)
				return exitFail
			}
			continue
		}
		c.outf("slot%d=written_%d_bytes\n", slot, se608.SlotSize[slot])
	}
	zero := make([]byte, 32)
	for b := 0; b < 2; b++ {
		_, ok := c.try("otp_write_block"+strconv.Itoa(b), func(s *se608.Session) (lab.Result, error) {
			return lab.Try(s, se608.Cmd{Op: se608.OpWrite, P1: byte(se608.ZoneOTP) | 0x80, P2: uint16(b) << 3, Data: zero})
		})
		if !ok {
			return exitFail
		}
	}
	c.outf("fill_data_failed_slots=%d\n", failed)
	return exitFor(failed == 0)
}

// cmdCheckMac builds the response the way the product's claim does (proto.CheckMacInput with the chip's serial and
// proto.OtherData) from the slot's test content, and asks the chip. With "wrong" one bit of the response is
// flipped: the chip must answer 0x01.
func cmdCheckMac(c *ctx) int {
	slot, ok := c.slotArg(0)
	if !ok {
		return exitUsage
	}
	wrong := len(c.args) == 2
	if wrong && c.args[1] != "wrong" {
		c.errf("checkmac SLOT [wrong]")
		return exitUsage
	}
	var chal, resp [32]byte
	_, _ = rand.Read(chal[:])
	in, err := proto.CheckMacInput(modelKey(slot, c.sn), chal[:], c.sn[:])
	if err != nil {
		c.errf("checkmac: %v", err)
		return exitFail
	}
	resp = sha256.Sum256(in)
	key := "checkmac_slot" + c.args[0]
	if wrong {
		resp[31] ^= 0x01
		key += "_wrong"
	}
	_, ok = c.try(key, func(s *se608.Session) (lab.Result, error) { return lab.CheckMac(s, slot, chal, resp, proto.OtherData) })
	return exitFor(ok)
}

func cmdGenKey(c *ctx) int {
	slot, ok := c.slotArg(0)
	if !ok {
		return exitUsage
	}
	_, ok = c.try("genkey_slot"+c.args[0], func(s *se608.Session) (lab.Result, error) { return lab.GenKey(s, se608.GenKeyCreate, slot) })
	return exitFor(ok)
}

func verifyRaw(pub, digest, sig []byte) bool {
	if len(pub) != 64 || len(sig) != 64 {
		return false
	}
	k := ecdsa.PublicKey{Curve: elliptic.P256(), X: new(big.Int).SetBytes(pub[:32]), Y: new(big.Int).SetBytes(pub[32:])}
	return ecdsa.Verify(&k, digest, new(big.Int).SetBytes(sig[:32]), new(big.Int).SetBytes(sig[32:]))
}

// cmdSign signs the product's way (pass-through Nonce 0x03, then external Sign 0x80, E17 / E14) and verifies the
// signature against the slot's public key.
func cmdSign(c *ctx) int {
	slot, ok := c.slotArg(0)
	if !ok {
		return exitUsage
	}
	var nonce [16]byte
	_, _ = rand.Read(nonce[:])
	digest := sha256.Sum256(append([]byte("se-lab sign test "), nonce[:]...))
	c.outf("digest=%x\n", digest)
	var n, sig lab.Result
	start := time.Now()
	err := c.d.Do(func(s *se608.Session) (err error) {
		if n, err = lab.Try(s, se608.Cmd{Op: se608.OpNonce, P1: se608.NoncePassthrough, Data: digest[:]}); err != nil || !n.OK() {
			return err
		}
		sig, err = lab.Sign(s, se608.SignExternal, slot)
		return err
	})
	took := time.Since(start)
	if err != nil {
		c.errf("sign: %v", err)
		return exitFail
	}
	c.outf("nonce_passthrough=%s\n", n)
	if !n.OK() {
		return exitOK
	}
	c.outf("sign_slot%d=%s\nsign_sequence_ms=%d\n", slot, sig, took.Milliseconds())
	if sig.IsStatus {
		return exitOK
	}
	pub, ok := c.try("pubkey_slot"+c.args[0], func(s *se608.Session) (lab.Result, error) { return lab.GenKey(s, se608.GenKeyPublic, slot) })
	if !ok {
		return exitFail
	}
	valid := !pub.IsStatus && verifyRaw(pub.Data, digest[:], sig.Data)
	c.outf("signature_valid=%s\n", yesNo(valid))
	return exitFor(valid)
}

// cmdSignInternal: a random Nonce, then an internal Sign. The result is only printed: no verifier in the design
// accepts an internal signature (C2), the experiments only need to know whether the chip gives one.
func cmdSignInternal(c *ctx) int {
	slot, ok := c.slotArg(0)
	if !ok {
		return exitUsage
	}
	var n, sig lab.Result
	err := c.d.Do(func(s *se608.Session) (err error) {
		if n, err = lab.NonceRandom(s, [20]byte{}); err != nil || n.IsStatus {
			return err
		}
		sig, err = lab.Sign(s, 0x00, slot)
		return err
	})
	if err != nil {
		c.errf("sign-internal: %v", err)
		return exitFail
	}
	c.outf("nonce_random=%s\n", n)
	if !n.IsStatus {
		c.outf("sign_internal_slot%d=%s\n", slot, sig)
	}
	return exitOK
}

// cmdMAC: MAC mode 0 on the slot with a fresh challenge. Where the chip returns a digest it is compared with the
// host computation over the slot's test content.
func cmdMAC(c *ctx) int {
	slot, ok := c.slotArg(0)
	if !ok {
		return exitUsage
	}
	chal := make([]byte, 32)
	_, _ = rand.Read(chal)
	r, ok := c.try("mac_slot"+c.args[0], func(s *se608.Session) (lab.Result, error) { return lab.MAC(s, 0x00, slot, chal) })
	if ok && !r.IsStatus {
		want := lab.HostMAC(modelKey(slot, c.sn), chal, 0x00, uint16(slot), c.sn)
		c.outf("mac_matches_host=%s\n", yesNo(bytes.Equal(r.Data, want[:])))
	}
	return exitFor(ok)
}

// cmdGenDigMAC: random Nonce, GenDig on the slot, then MAC with TempKey as the first block. A NoMac slot must make
// the final MAC fail (the NoMac flag follows the slot into TempKey).
func cmdGenDigMAC(c *ctx) int {
	slot, ok := c.slotArg(0)
	if !ok {
		return exitUsage
	}
	var other []byte
	if c.cfg[20+2*slot]&0x10 != 0 {
		other = []byte{0, 0, 0, 0} // a NoMac slot's GenDig carries 4 bytes of OtherData
	}
	chal := make([]byte, 32)
	_, _ = rand.Read(chal)
	var n, g, m lab.Result
	err := c.d.Do(func(s *se608.Session) (err error) {
		if n, err = lab.NonceRandom(s, [20]byte{}); err != nil || n.IsStatus {
			return err
		}
		if g, err = lab.GenDig(s, lab.GenDigData, uint16(slot), other); err != nil || !g.OK() {
			return err
		}
		m, err = lab.MAC(s, 0x02, slot, chal) // block 1 = TempKey (made by a random Nonce: source flag 0)
		return err
	})
	if err != nil {
		c.errf("gendig-mac: %v", err)
		return exitFail
	}
	c.outf("nonce_random=%s\n", n)
	if n.IsStatus {
		return exitOK
	}
	c.outf("gendig_slot%d=%s\n", slot, g)
	if !g.OK() {
		return exitOK
	}
	c.outf("mac_tempkey=%s\n", m)
	if !m.IsStatus {
		tk := lab.NonceTempKey(n.Data, [20]byte{}, 0x00)
		tk = lab.HostGenDig(modelKey(slot, c.sn), lab.GenDigData, uint16(slot), c.sn, tk, other)
		want := lab.HostMAC(tk[:], chal, 0x02, uint16(slot), c.sn)
		c.outf("mac_matches_host=%s\n", yesNo(bytes.Equal(m.Data, want[:])))
	}
	return exitOK
}

// cmdHMAC: SHA in HMAC mode keyed by the slot, over a fixed message.
func cmdHMAC(c *ctx) int {
	slot, ok := c.slotArg(0)
	if !ok {
		return exitUsage
	}
	msg := []byte("se-lab hmac test")
	var st, end lab.Result
	err := c.d.Do(func(s *se608.Session) (err error) {
		if st, err = lab.HMACStart(s, slot); err != nil || !st.OK() {
			return err
		}
		end, err = lab.SHAEnd(s, msg)
		return err
	})
	if err != nil {
		c.errf("hmac: %v", err)
		return exitFail
	}
	c.outf("hmac_start_slot%d=%s\n", slot, st)
	if !st.OK() {
		return exitOK
	}
	c.outf("hmac_end=%s\n", end)
	if !end.IsStatus {
		h := hmac.New(sha256.New, modelKey(slot, c.sn))
		h.Write(msg)
		c.outf("hmac_matches_host=%s\n", yesNo(bytes.Equal(end.Data, h.Sum(nil))))
	}
	return exitOK
}

// cmdKDF: KDF with the slot as the source key. Without TARGET the result goes to the output buffer in clear (E8);
// with TARGET it is written to that slot (E9).
func cmdKDF(c *ctx) int {
	var alg byte
	var details uint32
	switch c.args[0] {
	case "prf":
		alg, details = lab.KDFAlgPRF, 0x00000001 // 32-byte source key, 32-byte target
	case "hkdf":
		alg, details = lab.KDFAlgHKDF, 0x00000002 // the message is in the input parameter
	default:
		c.errf("kdf prf|hkdf SLOT [TARGET]")
		return exitUsage
	}
	c.args = c.args[1:]
	slot, ok := c.slotArg(0)
	if !ok {
		return exitUsage
	}
	mode, keyID, key := lab.KDFSourceSlot|lab.KDFTargetOutput|alg, uint16(slot), "kdf_"+kdfName(alg)+"_slot"+c.args[0]
	if len(c.args) == 2 {
		target, ok := c.slotArg(1)
		if !ok {
			return exitUsage
		}
		mode, keyID, key = lab.KDFSourceSlot|lab.KDFTargetSlot|alg, uint16(slot)|uint16(target)<<8, key+"_to_slot"+c.args[1]
	}
	_, ok = c.try(key, func(s *se608.Session) (lab.Result, error) {
		return lab.KDF(s, mode, keyID, details, []byte("se-lab kdf input"))
	})
	return exitFor(ok)
}

func kdfName(alg byte) string {
	if alg == lab.KDFAlgHKDF {
		return "hkdf"
	}
	return "prf"
}

func cmdAES(c *ctx) int {
	slot, ok := c.slotArg(0)
	if !ok {
		return exitUsage
	}
	_, ok = c.try("aes_encrypt_slot"+c.args[0], func(s *se608.Session) (lab.Result, error) { return lab.AES(s, 0x00, slot, [16]byte{}) })
	return exitFor(ok)
}

var ecdhModes = map[string]byte{"clear": lab.ECDHClear, "compat": lab.ECDHCompatible, "tempkey": lab.ECDHToTempKey,
	"enc": lab.ECDHEncrypted, "slot": lab.ECDHToSlot}

// cmdECDH: ECDH between the slot's key and a fresh host key. A 32-byte clear result is compared with the software
// computation against the slot's public key.
func cmdECDH(c *ctx) int {
	slot, ok := c.slotArg(0)
	if !ok {
		return exitUsage
	}
	mode, known := ecdhModes[c.args[1]]
	if !known {
		c.errf("ecdh SLOT clear|compat|tempkey|enc|slot")
		return exitUsage
	}
	host, err := ecdh.P256().GenerateKey(rand.Reader)
	if err != nil {
		c.errf("ecdh: %v", err)
		return exitFail
	}
	var peer [64]byte
	copy(peer[:], host.PublicKey().Bytes()[1:])
	r, ok := c.try("ecdh_"+c.args[1]+"_slot"+c.args[0], func(s *se608.Session) (lab.Result, error) { return lab.ECDH(s, mode, slot, peer) })
	if !ok {
		return exitFail
	}
	if r.IsStatus || len(r.Data) != 32 {
		return exitOK
	}
	pub, ok := c.try("pubkey_slot"+c.args[0], func(s *se608.Session) (lab.Result, error) { return lab.GenKey(s, se608.GenKeyPublic, slot) })
	if !ok {
		return exitFail
	}
	match := false
	if !pub.IsStatus && len(pub.Data) == 64 {
		if cp, err := ecdh.P256().NewPublicKey(append([]byte{0x04}, pub.Data...)); err == nil {
			if z, err := host.ECDH(cp); err == nil {
				match = bytes.Equal(z, r.Data)
			}
		}
	}
	c.outf("ecdh_matches_host=%s\n", yesNo(match))
	return exitFor(match)
}

func cmdSlotWrite(c *ctx) int {
	slot, ok := c.slotArg(0)
	if !ok {
		return exitUsage
	}
	b, ok := c.hexArg(1, "the content")
	if !ok {
		return exitUsage
	}
	if len(b) > se608.SlotSize[slot] {
		c.errf("%d bytes do not fit slot %d (%d bytes)", len(b), slot, se608.SlotSize[slot])
		return exitUsage
	}
	content := make([]byte, se608.SlotSize[slot])
	copy(content, b)
	err := c.d.WriteSlot(slot, content)
	var se *se608.StatusError
	switch {
	case errors.As(err, &se):
		c.outf("slot_write_slot%d=status_%02x\n", slot, se.Code)
		return exitFail
	case err != nil:
		c.errf("slot-write: %v", err)
		return exitFail
	}
	c.outf("slot_write_slot%d=written_%d_bytes\n", slot, len(content))
	return exitOK
}

// cmdRaw sends any opcode on se-lab's list — except the three whose effect cannot be undone, which only go through
// their named commands (and so through -serial).
func cmdRaw(c *ctx) int {
	var v [3]uint64
	for i := 0; i < 3; i++ {
		bits := 8
		if i == 2 {
			bits = 16
		}
		x, err := strconv.ParseUint(c.args[i], 16, bits)
		if err != nil {
			c.errf("raw OP P1 P2 [HEX]: %q is not hex", c.args[i])
			return exitUsage
		}
		v[i] = x
	}
	var data []byte
	if len(c.args) == 4 {
		var ok bool
		if data, ok = c.hexArg(3, "the data"); !ok {
			return exitUsage
		}
	}
	op := byte(v[0])
	if op == se608.OpLock || op == se608.OpCounter || op == se608.OpUpdateExtra {
		return c.refuse("opcode 0x%02x changes the chip for good: use lock-config, lock-data, lock-slot, counter-inc or update-extra", op)
	}
	_, ok := c.try("raw_"+c.args[0], func(s *se608.Session) (lab.Result, error) {
		return lab.Raw(s, op, byte(v[1]), uint16(v[2]), data, 250*time.Millisecond)
	})
	return exitFor(ok)
}

// --- for good -------------------------------------------------------------------------------------------------

var (
	errChanged = errors.New("the config zone changed since it was read: nothing sent")
	errReRead  = errors.New("the config zone could not be read again just before the Lock: nothing sent")
)

// cmdLockConfig locks the config zone (E4). It refuses unless the chip holds exactly the image, and unless the CRC
// it computes equals the one the operator brings from the independent check; it prints the packet first; it reads
// the zone again in the same sequence as the Lock and compares; and the chip itself checks the CRC once more.
func cmdLockConfig(c *ctx) int {
	switch {
	case se608.ConfigLocked(c.cfg):
		return c.refuse("the config zone is already locked")
	case c.cfg[17] != c.byte17:
		return c.refuse("chip byte 17 = %02x, -byte17 = %02x", c.cfg[17], c.byte17)
	}
	c.outf("image=variant\nimage_sha256=%x\n", sha256.Sum256(c.img[16:]))
	if rc := c.printDiff(); rc != exitOK {
		return c.refuse("the chip does not hold the image: write-image first")
	}
	crc := se608.ConfigCRC(c.cfg)
	cmd := se608.LockConfigCmd(crc)
	pkt, _ := cmd.Packet()
	c.outf("config_crc=%04x\nlock_packet=% x\n", crc, pkt)
	if crc != *c.expect {
		return c.refuse("computed CRC %04x, -expect-crc %04x: nothing sent", crc, *c.expect)
	}
	if c.dry {
		c.outf("dry_run=nothing sent\n")
		return exitOK
	}
	err := c.d.Do(func(s *se608.Session) error {
		for b := 0; b < 4; b++ {
			d, err := s.Read(se608.ZoneConfig, uint16(b)<<3, 32)
			if err != nil {
				return fmt.Errorf("%w: block %d: %v", errReRead, b, err)
			}
			if !bytes.Equal(d, c.cfg[b*32:b*32+32]) {
				return errChanged
			}
		}
		_, err := s.Exec(cmd)
		return err
	})
	return c.afterLock("lock_config", err, func(cfg [se608.ConfigLen]byte) bool { return se608.ConfigLocked(cfg) })
}

// cmdLockData locks the Data and OTP zones (E6) with the CRC of what fill-data wrote. The data zone cannot be read
// back before this lock, so the CRC is the only check that the content is what was intended.
func cmdLockData(c *ctx) int {
	switch {
	case !se608.ConfigLocked(c.cfg):
		return c.refuse("the config zone is not locked")
	case se608.DataLocked(c.cfg):
		return c.refuse("the data zone is already locked")
	}
	var data [16][]byte
	for i := range data {
		data[i] = modelSlot(i, c.sn)
	}
	var otp [se608.OTPLen]byte
	for i := range otp {
		otp[i] = c.otpFill
	}
	crc, err := se608.DataCRC(c.cfg, data, otp)
	if err != nil {
		c.errf("lock-data: %v", err)
		return exitFail
	}
	cmd := se608.LockDataCmd(crc)
	pkt, _ := cmd.Packet()
	c.outf("otp_fill=%02x\ndata_crc=%04x\nlock_packet=% x\n", c.otpFill, crc, pkt)
	if c.expect != nil && crc != *c.expect {
		return c.refuse("computed CRC %04x, -expect-crc %04x: nothing sent", crc, *c.expect)
	}
	if c.dry {
		c.outf("dry_run=nothing sent\n")
		return exitOK
	}
	err = c.d.Do(func(s *se608.Session) error { _, err := s.Exec(cmd); return err })
	return c.afterLock("lock_data", err, func(cfg [se608.ConfigLen]byte) bool { return se608.DataLocked(cfg) })
}

// lockableInLab are the only slots se-lab will send Lock(slot) for: the variant's two lockable control slots (4:
// E17, 6: E13) and the claim slot, which is configured not lockable and must refuse (E13). Not slot 8: locking the
// certificate slot would end E15, and no experiment asks for it.
var lockableInLab = map[int]bool{4: true, 5: true, 6: true}

// cmdLockSlot sends Lock(slot) whatever the slot's Lockable bit says (E13 needs to see the chip refuse a slot that
// is not lockable), but only for the three slots the experiments name, and only once both zones are locked: a slot
// locked earlier can never take its key or content (E6's control and E17 would be lost on the one chip 1).
func cmdLockSlot(c *ctx) int {
	slot, ok := c.slotArg(0)
	if !ok {
		return exitUsage
	}
	switch {
	case !lockableInLab[slot]:
		return c.refuse("lock-slot is only for slots 4, 5 and 6 (255-608b-config.md E17, E13)")
	case !se608.ConfigLocked(c.cfg) || !se608.DataLocked(c.cfg):
		return c.refuse("lock-slot needs both zones locked first (E17 and E13 come after E6)")
	}
	cmd := se608.LockSlotCmd(slot)
	pkt, _ := cmd.Packet()
	c.outf("slot=%d\nslot_config=%02x%02x\nkey_config=%02x%02x\nlockable=%s\nslot_already_locked=%s\nlock_packet=% x\n",
		slot, c.cfg[21+2*slot], c.cfg[20+2*slot], c.cfg[97+2*slot], c.cfg[96+2*slot],
		yesNo(c.cfg[96+2*slot]&0x20 != 0), yesNo(se608.SlotLocked(c.cfg, slot)), pkt)
	if c.dry {
		c.outf("dry_run=nothing sent\n")
		return exitOK
	}
	err := c.d.Do(func(s *se608.Session) error { _, err := s.Exec(cmd); return err })
	return c.afterLock("lock_slot"+c.args[0], err, func(cfg [se608.ConfigLen]byte) bool { return se608.SlotLocked(cfg, slot) })
}

// afterLock decides what to print after a Lock was (or was not) sent. The chip's own bytes are the only evidence of
// a lock: the zone is read again — with a few tries, a chip that has just written its EEPROM or a marginal bus may
// need one — and exactly one line `<key>_result=` says what is known:
//
//	locked                            the command answered success and the bytes say locked            exit 0
//	status_XX                         the chip refused (0f: CRC mismatch or not allowed); not locked    exit 1
//	status_XX_but_LOCKED              the chip refused and the bytes still say locked                   exit 1
//	LOCKED_answer_lost                no usable answer, but the bytes say locked: do NOT send again     exit 1
//	NOT_LOCKED_answer_lost            no usable answer and the bytes say not locked                     exit 1
//	NOT_LOCKED_after_success_status   the command answered success but the bytes say not locked         exit 1
//	UNKNOWN_read_back_failed          the zone could not be read afterwards: run `info`                 exit 1
func (c *ctx) afterLock(key string, err error, locked func([se608.ConfigLen]byte) bool) int {
	switch {
	case errors.Is(err, errChanged), errors.Is(err, errReRead):
		return c.refuse("%v", err)
	case errors.Is(err, se608.ErrRefused):
		return c.refuse("%v", err) // se-lab's own policy stopped it before the bus
	}
	var se *se608.StatusError
	isStatus := errors.As(err, &se)
	if err != nil && !isStatus {
		c.errf("%s: %v", key, err)
	}
	sleep := c.e.sleep
	if sleep == nil {
		sleep = time.Sleep
	}
	var cfg [se608.ConfigLen]byte
	var rerr error
	for try := 0; try < 5; try++ {
		if try > 0 {
			sleep(300 * time.Millisecond)
		}
		if cfg, rerr = c.d.ReadConfig(); rerr == nil {
			break
		}
	}
	if rerr != nil {
		c.errf("%s: read back: %v", key, rerr)
		c.outf("%s_result=UNKNOWN_read_back_failed\n", key)
		return exitFail
	}
	c.outf("lock_config_after=%02x\nlock_data_after=%02x\nslot_locked_after=%02x%02x\n",
		cfg[se608.LockConfigByte], cfg[se608.LockDataByte], cfg[89], cfg[88])
	is := locked(cfg)
	switch {
	case err == nil && is:
		c.outf("%s_result=locked\n", key)
		return exitOK
	case err == nil:
		c.outf("%s_result=NOT_LOCKED_after_success_status\n", key)
	case isStatus && is:
		c.outf("%s_result=status_%02x_but_LOCKED\n", key, se.Code)
	case isStatus:
		c.outf("%s_result=status_%02x\n", key, se.Code)
	case is:
		c.outf("%s_result=LOCKED_answer_lost\n", key)
	default:
		c.outf("%s_result=NOT_LOCKED_answer_lost\n", key)
	}
	return exitFail
}

// cmdUpdateExtra writes config byte 84 or 85 once (mode 0 / 1), or tries the 508A's decrement (mode 2). Only with
// both zones locked: the design's order puts E12 and E11's decrement after E6, and a write to byte 84 or 85 before
// the config lock would change the CRC the lock was prepared with.
func cmdUpdateExtra(c *ctx) int {
	mode, err := strconv.ParseUint(c.args[0], 10, 8)
	val, err2 := strconv.ParseUint(c.args[1], 16, 8)
	if err != nil || err2 != nil || mode > 2 {
		c.errf("update-extra MODE VAL: MODE is 0, 1 or 2, VAL two hex digits")
		return exitUsage
	}
	if !se608.ConfigLocked(c.cfg) || !se608.DataLocked(c.cfg) {
		return c.refuse("update-extra needs both zones locked first (E12 and E11 come after E6)")
	}
	cmd := lab.UpdateExtraCmd(byte(mode), byte(val))
	pkt, _ := cmd.Packet()
	c.outf("byte84_before=%02x\nbyte85_before=%02x\npacket=% x\n", c.cfg[84], c.cfg[85], pkt)
	if c.dry {
		c.outf("dry_run=nothing sent\n")
		return exitOK
	}
	_, ok := c.try("update_extra_mode"+c.args[0], func(s *se608.Session) (lab.Result, error) { return lab.Try(s, cmd) })
	cfg, rerr := c.d.ReadConfig()
	if rerr != nil {
		c.errf("update-extra: read back: %v", rerr)
		if !ok {
			c.outf("update_extra_result=UNKNOWN_read_back_failed\n")
		}
		return exitFail
	}
	c.outf("byte84_after=%02x\nbyte85_after=%02x\n", cfg[84], cfg[85])
	if !ok {
		// no usable answer: the bytes say what happened; never resend (a byte that is no longer 00 cannot be
		// written again anyway)
		if cfg[84] != c.cfg[84] || cfg[85] != c.cfg[85] {
			c.outf("update_extra_result=WRITTEN_answer_lost\n")
		} else {
			c.outf("update_extra_result=NOT_WRITTEN_answer_lost\n")
		}
		return exitFail
	}
	return exitOK
}
