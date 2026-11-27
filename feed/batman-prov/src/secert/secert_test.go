package secert_test

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/asn1"
	"encoding/hex"
	"math/big"
	"strings"
	"testing"
	"time"

	"batman-prov/cbor"
	"batman-prov/secert"
)

func key(t *testing.T) (*ecdsa.PrivateKey, [64]byte) {
	t.Helper()
	k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	b, _ := k.PublicKey.Bytes()
	return k, [64]byte(b[1:])
}

func keys(t *testing.T) secert.Keys {
	t.Helper()
	var k secert.Keys
	_, k.Session = key(t)
	_, k.Identity = key(t)
	_, k.ECDH = key(t)
	copy(k.ChipSN[:], []byte{0x01, 0x23, 0xba, 0x99, 0xe2, 0xca, 0x24, 0x8c, 0xee})
	return k
}

var maxSerial = []byte{0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF}

// E15's size question, answered on the developer PC (impl §3.1): with every variable-length field at its longest —
// an 8-byte serial, a 2-character issuer CN, a 72-byte signature — the certificate fits slot 8.
func TestWorstCaseFitsSlot8(t *testing.T) {
	root, _ := key(t)
	worst := 0
	for i := 0; i < 40; i++ {
		der, err := secert.Build(keys(t), "DR", maxSerial, root)
		if err != nil {
			t.Fatal(err)
		}
		c, err := x509.ParseCertificate(der)
		if err != nil {
			t.Fatal(err)
		}
		// The DER signature is 70-72 bytes depending on the high bits of r and s; nothing else in the certificate
		// varies in length. The BIT STRING and the outer SEQUENCE keep their length-of-length either way.
		if n := len(der) + 72 - len(c.Signature); n > worst {
			worst = n
		}
		if len(c.Signature) > 72 {
			t.Fatalf("a %d-byte ECDSA signature", len(c.Signature))
		}
	}
	t.Logf("worst-case certificate: %d bytes of %d", worst, secert.MaxLen)
	if worst > secert.MaxLen {
		t.Fatalf("worst case %d bytes does not fit slot 8 (%d): the profile must shrink or use slot 8 + 9 (impl §3.1)", worst, secert.MaxLen)
	}
	// control: the profile the reviewers measured at 448-469 bytes (a subject serialNumber and BasicConstraints
	// added back) must NOT fit, or this test could not have caught the v4 profile.
	k := keys(t)
	pub, _ := ecdsa.ParseUncompressedPublicKey(elliptic.P256(), append([]byte{0x04}, k.Identity[:]...))
	id := secert.DeviceID(k.Identity)
	ext, _ := cbor.Encode(cbor.M(0, make([]byte, 33), 2, make([]byte, 33), 7, k.ChipSN[:]))
	tpl := &x509.Certificate{
		SerialNumber:          new(big.Int).SetBytes(maxSerial),
		Subject:               pkix.Name{CommonName: secert.SubjectCN(k.Identity), SerialNumber: hex.EncodeToString(id[:])},
		NotBefore:             time.Date(2020, 1, 1, 0, 0, 0, 0, time.UTC),
		NotAfter:              time.Date(9999, 12, 31, 23, 59, 59, 0, time.UTC),
		BasicConstraintsValid: true,
		ExtraExtensions:       []pkix.Extension{{Id: asn1.ObjectIdentifier{1, 3, 6, 1, 4, 1, 99999, 1, 1}, Value: ext}},
	}
	parent := &x509.Certificate{Subject: pkix.Name{CommonName: "Batman bench dev root"}}
	old, err := x509.CreateCertificate(rand.Reader, tpl, parent, pub, root)
	if err != nil {
		t.Fatal(err)
	}
	if len(old) <= secert.MaxLen {
		t.Fatalf("control: the old profile is %d bytes and fits; the size assertion proves nothing", len(old))
	}
	t.Logf("control: the v4 profile is %d bytes", len(old))
}

func TestBuildParseVerify(t *testing.T) {
	root, _ := key(t)
	k := keys(t)
	der, err := secert.Build(k, "D", []byte{0x01}, root)
	if err != nil {
		t.Fatal(err)
	}
	got, issuer, err := secert.Parse(der)
	if err != nil || got != k || issuer != "D" {
		t.Fatalf("parse: %v, issuer %q, keys equal %v", err, issuer, got == k)
	}
	if err := secert.VerifyRoot(der, &root.PublicKey); err != nil {
		t.Fatal(err)
	}
	otherRoot, _ := key(t)
	if err := secert.VerifyRoot(der, &otherRoot.PublicKey); err == nil {
		t.Fatal("the certificate verifies against another root")
	}
	if err := secert.Matches(der, k); err != nil {
		t.Fatal(err)
	}
	// the subject CN is the device id of the slot 1 key, as the file backend derives it
	c, _ := x509.ParseCertificate(der)
	h := sha256.Sum256(append([]byte{0x04}, k.Identity[:]...))
	if c.Subject.CommonName != "se:"+hex.EncodeToString(h[:9]) {
		t.Fatalf("subject CN %q", c.Subject.CommonName)
	}

	// a certificate of chip A does not match chip B, whichever single field differs (config §5.4: two chips'
	// certificates swapped must be refused)
	for name, mut := range map[string]func(*secert.Keys){
		"session key":  func(x *secert.Keys) { _, x.Session = key(t) },
		"identity key": func(x *secert.Keys) { _, x.Identity = key(t) },
		"ECDH key":     func(x *secert.Keys) { _, x.ECDH = key(t) },
		"chip serial":  func(x *secert.Keys) { x.ChipSN[3] ^= 1 },
	} {
		other := k
		mut(&other)
		if err := secert.Matches(der, other); err == nil {
			t.Errorf("a certificate matched a chip with a different %s", name)
		}
	}
}

func TestBuildRefusesBadInput(t *testing.T) {
	root, _ := key(t)
	k := keys(t)
	for name, f := range map[string]func() error{
		"long issuer CN":       func() error { _, err := secert.Build(k, "DEV", []byte{1}, root); return err },
		"empty issuer CN":      func() error { _, err := secert.Build(k, "", []byte{1}, root); return err },
		"9-byte serial":        func() error { _, err := secert.Build(k, "D", make([]byte, 9), root); return err },
		"negative serial":      func() error { _, err := secert.Build(k, "D", []byte{0x80}, root); return err },
		"leading zero serial":  func() error { _, err := secert.Build(k, "D", []byte{0, 1}, root); return err },
		"key not on the curve": func() error { b := k; b.Session[5] ^= 1; _, err := secert.Build(b, "D", []byte{1}, root); return err },
	} {
		if f() == nil {
			t.Errorf("Build accepted: %s", name)
		}
	}
}

// Parse refuses everything outside the profile: built here with the standard library, each with one deviation.
func TestParseRefusesOtherProfiles(t *testing.T) {
	root, _ := key(t)
	k := keys(t)
	pub, _ := ecdsa.ParseUncompressedPublicKey(elliptic.P256(), append([]byte{0x04}, k.Identity[:]...))
	comp := func(xy [64]byte) []byte { return append([]byte{0x02 | xy[63]&1}, xy[:32]...) }
	goodExt, _ := cbor.Encode(cbor.M(0, comp(k.Session), 2, comp(k.ECDH), 7, k.ChipSN[:]))
	base := func() *x509.Certificate {
		return &x509.Certificate{
			SerialNumber:    big.NewInt(1),
			Subject:         pkix.Name{CommonName: secert.SubjectCN(k.Identity)},
			NotBefore:       time.Date(2020, 1, 1, 0, 0, 0, 0, time.UTC),
			NotAfter:        time.Date(9999, 12, 31, 23, 59, 59, 0, time.UTC),
			ExtraExtensions: []pkix.Extension{{Id: secert.OIDKeys, Value: goodExt}},
		}
	}
	mk := func(tpl *x509.Certificate, issuer string) []byte {
		der, err := x509.CreateCertificate(rand.Reader, tpl, &x509.Certificate{Subject: pkix.Name{CommonName: issuer}}, pub, root)
		if err != nil {
			t.Fatal(err)
		}
		return der
	}
	if _, _, err := secert.Parse(mk(base(), "D")); err != nil {
		t.Fatalf("control: the unmodified profile does not parse: %v", err)
	}
	badPoint := comp(k.Session)
	badPoint[7] ^= 0x01
	for i := 0; i < 16; i++ { // find an x that is not on the curve
		if x, _ := elliptic.UnmarshalCompressed(elliptic.P256(), badPoint); x == nil {
			break
		}
		badPoint[7]++
	}
	ext := func(m cbor.Map) []pkix.Extension {
		b, _ := cbor.Encode(m)
		return []pkix.Extension{{Id: secert.OIDKeys, Value: b}}
	}
	cases := map[string]func(*x509.Certificate){
		"a second extension": func(c *x509.Certificate) { c.BasicConstraintsValid = true },
		"a 20-byte serial": func(c *x509.Certificate) {
			c.SerialNumber = new(big.Int).SetBytes(bytes.Repeat([]byte{0x55}, 20))
		},
		"a 9-byte serial": func(c *x509.Certificate) {
			c.SerialNumber = new(big.Int).SetBytes(bytes.Repeat([]byte{0x55}, 9))
		},
		"signed with ecdsa-with-SHA384": func(c *x509.Certificate) { c.SignatureAlgorithm = x509.ECDSAWithSHA384 },
		"a second extension after the key extension": func(c *x509.Certificate) {
			c.ExtraExtensions = append(c.ExtraExtensions, pkix.Extension{Id: asn1.ObjectIdentifier{2, 999, 2}, Value: []byte{0x05, 0x00}})
		},
		"critical key extension":    func(c *x509.Certificate) { c.ExtraExtensions[0].Critical = true },
		"another OID":               func(c *x509.Certificate) { c.ExtraExtensions[0].Id = asn1.ObjectIdentifier{2, 999, 2} },
		"no extension":              func(c *x509.Certificate) { c.ExtraExtensions = nil },
		"subject with serialNumber": func(c *x509.Certificate) { c.Subject.SerialNumber = "x" },
		"subject CN of another key": func(c *x509.Certificate) { c.Subject.CommonName = "se:" + strings.Repeat("0", 18) },
		"file-style subject":        func(c *x509.Certificate) { c.Subject.CommonName = "dev:" + strings.Repeat("0", 18) },
		"other validity":            func(c *x509.Certificate) { c.NotAfter = time.Date(2120, 1, 1, 0, 0, 0, 0, time.UTC) },
		"extension with a 4th entry": func(c *x509.Certificate) {
			c.ExtraExtensions = ext(cbor.M(0, comp(k.Session), 2, comp(k.ECDH), 7, k.ChipSN[:], 9, []byte{1}))
		},
		"extension without the SN": func(c *x509.Certificate) { c.ExtraExtensions = ext(cbor.M(0, comp(k.Session), 2, comp(k.ECDH))) },
		"8-byte chip serial": func(c *x509.Certificate) {
			c.ExtraExtensions = ext(cbor.M(0, comp(k.Session), 2, comp(k.ECDH), 7, k.ChipSN[:8]))
		},
		"uncompressed slot 0 key": func(c *x509.Certificate) {
			c.ExtraExtensions = ext(cbor.M(0, k.Session[:], 2, comp(k.ECDH), 7, k.ChipSN[:]))
		},
		"slot 0 point off the curve": func(c *x509.Certificate) {
			c.ExtraExtensions = ext(cbor.M(0, badPoint, 2, comp(k.ECDH), 7, k.ChipSN[:]))
		},
		"extension is not CBOR": func(c *x509.Certificate) { c.ExtraExtensions[0].Value = []byte{0xFF, 0x00} },
	}
	for name, mut := range cases {
		c := base()
		mut(c)
		if _, _, err := secert.Parse(mk(c, "D")); err == nil {
			t.Errorf("Parse accepted: %s", name)
		}
	}
	if _, _, err := secert.Parse(mk(base(), "Batman dev root")); err == nil {
		t.Error("Parse accepted a long issuer name")
	}
	if _, _, err := secert.Parse(append(mk(base(), "D"), 0x00)); err == nil {
		t.Error("Parse accepted trailing bytes")
	}
	// The size cap, with a certificate that parses and is otherwise the profile with a longer (in-range) piece:
	// not available inside the profile (its worst case is 393 bytes), so the control is the error itself.
	big417 := mk(base(), "D")
	big417 = append(big417, make([]byte, 417-len(big417))...)
	if _, _, err := secert.Parse(big417); err == nil || !strings.Contains(err.Error(), "slot 8 holds") {
		t.Errorf("Parse of 417 bytes: %v, want the size error", err)
	}
	// An issuerUniqueID spliced into the TBS: the standard library parses it and exposes nothing of it, so only the
	// canonical re-encoding can notice (code review PR D2 B-m10). Built by re-signing a TBS with the field added.
	if der := withIssuerUniqueID(t, mk(base(), "D"), root); der != nil {
		if _, err := x509.ParseCertificate(der); err != nil {
			t.Fatalf("control: the spliced certificate does not even parse: %v", err)
		}
		if _, _, err := secert.Parse(der); err == nil {
			t.Error("Parse accepted a certificate with an issuerUniqueID")
		}
	}
}

// withIssuerUniqueID rebuilds der with an issuerUniqueID ([1] IMPLICIT BIT STRING) inserted before the extensions
// and signs the new TBS with root.
func withIssuerUniqueID(t *testing.T, der []byte, root *ecdsa.PrivateKey) []byte {
	t.Helper()
	var cert struct {
		TBS asn1.RawValue
		Alg asn1.RawValue
		Sig asn1.BitString
	}
	if _, err := asn1.Unmarshal(der, &cert); err != nil {
		t.Fatal(err)
	}
	var fields []asn1.RawValue
	rest := cert.TBS.Bytes
	for len(rest) > 0 {
		var f asn1.RawValue
		var err error
		if rest, err = asn1.Unmarshal(rest, &f); err != nil {
			t.Fatal(err)
		}
		fields = append(fields, f)
	}
	uid := asn1.RawValue{Class: asn1.ClassContextSpecific, Tag: 1, Bytes: []byte{0x00, 0xAB, 0xCD}}
	var body []byte
	for i, f := range fields {
		if i == len(fields)-1 { // the extensions [3] are last
			b, err := asn1.Marshal(uid)
			if err != nil {
				t.Fatal(err)
			}
			body = append(body, b...)
		}
		body = append(body, f.FullBytes...)
	}
	tbs, err := asn1.Marshal(asn1.RawValue{Class: asn1.ClassUniversal, Tag: asn1.TagSequence, IsCompound: true, Bytes: body})
	if err != nil {
		t.Fatal(err)
	}
	h := sha256.Sum256(tbs)
	sig, err := ecdsa.SignASN1(rand.Reader, root, h[:])
	if err != nil {
		t.Fatal(err)
	}
	out, err := asn1.Marshal(struct {
		TBS asn1.RawValue
		Alg asn1.RawValue
		Sig asn1.BitString
	}{asn1.RawValue{FullBytes: tbs}, cert.Alg, asn1.BitString{Bytes: sig, BitLength: 8 * len(sig)}})
	if err != nil {
		t.Fatal(err)
	}
	return out
}

// The to-be-signed bytes for fixed inputs are pinned. Parse accepts a certificate only if re-encoding it gives the
// same bytes, so if a Go release ever changed how crypto/x509 encodes this profile, every bench certificate already
// in a chip would stop parsing — and replacing one means re-flashing the card (config §5.3). This test is where that
// shows up first, at the toolchain bump, not on a node (round 2 A-N-m5).
func TestCanonicalEncodingGolden(t *testing.T) {
	fixedKey := func(seed byte) [64]byte {
		k, err := ecdsa.ParseRawPrivateKey(elliptic.P256(), bytes.Repeat([]byte{seed}, 32))
		if err != nil {
			t.Fatal(err)
		}
		b, _ := k.PublicKey.Bytes()
		return [64]byte(b[1:])
	}
	k := secert.Keys{Session: fixedKey(1), Identity: fixedKey(2), ECDH: fixedKey(3)}
	copy(k.ChipSN[:], []byte{0x01, 0x23, 0xba, 0x99, 0xe2, 0xca, 0x24, 0x8c, 0xee})
	root, _ := key(t)
	der, err := secert.Build(k, "D", []byte{0x01}, root)
	if err != nil {
		t.Fatal(err)
	}
	c, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	got := sha256.Sum256(c.RawTBSCertificate)
	const want = "e99528ba8d28e7248fded84aec5e03b690b45d4aa9defbac167fb19f62eb2fc9"
	if hex.EncodeToString(got[:]) != want {
		t.Fatalf("the canonical to-be-signed encoding changed: sha256 %x, want %s (%d bytes)", got, want, len(c.RawTBSCertificate))
	}
}
