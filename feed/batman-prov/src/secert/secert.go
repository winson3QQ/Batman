// Package secert builds and parses the chip-style node certificate that goes into slot 8 of a bench chip
// (255-608b-impl.md §3.1): X.509 v3, signed by the dev root, subject CN "se:<device_id>", subject key = the slot 1
// public key, and one private extension carrying the slot 0 and slot 2 public keys and the chip serial. It must fit
// the 416-byte slot; the test asserts the worst case.
//
// Build is se-sign's (the developer PC, PR 2); Parse is the structural check the node makes before it trusts a
// certificate read from the chip (255-608b-config.md §2: the node does not verify the dev root's signature, the app
// does). Nothing here touches a chip.
package secert

import (
	"bytes"
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/asn1"
	"encoding/hex"
	"errors"
	"fmt"
	"math/big"
	"time"

	"batman-prov/cbor"
)

// MaxLen is the size of slot 8.
const MaxLen = 416

// OIDKeys is the one extension. It is under joint-iso-itu-t(2) example(999), the arc reserved for examples: three
// content bytes, and honest about what this certificate is — a bench artefact the field app does not trust. The
// production chip's profile gets a registered OID when that chip is chosen (#426).
var OIDKeys = asn1.ObjectIdentifier{2, 999, 1}

var (
	notBefore = time.Date(2020, 1, 1, 0, 0, 0, 0, time.UTC)
	notAfter  = time.Date(9999, 12, 31, 23, 59, 59, 0, time.UTC)
)

// Keys is what the certificate binds: the three public keys (X ‖ Y, as the chip returns them) and the chip serial.
type Keys struct {
	Session  [64]byte // slot 0
	Identity [64]byte // slot 1: the certificate's subject key
	ECDH     [64]byte // slot 2
	ChipSN   [9]byte
}

// DeviceID is the node id: the first 9 bytes of SHA-256 over the SEC1 uncompressed identity key (65 bytes with the
// leading 0x04), as the file backend computes it (keystore.go).
func DeviceID(identity [64]byte) [9]byte {
	h := sha256.Sum256(append([]byte{0x04}, identity[:]...))
	return [9]byte(h[:9])
}

// SubjectCN is "se:" + hex(device id).
func SubjectCN(identity [64]byte) string {
	id := DeviceID(identity)
	return "se:" + hex.EncodeToString(id[:])
}

func pubKey(xy [64]byte) (*ecdsa.PublicKey, error) {
	return ecdsa.ParseUncompressedPublicKey(elliptic.P256(), append([]byte{0x04}, xy[:]...))
}

func compress(xy [64]byte) []byte {
	return append([]byte{0x02 | xy[63]&1}, xy[:32]...)
}

func decompress(b []byte) (xy [64]byte, err error) {
	if len(b) != 33 || (b[0] != 0x02 && b[0] != 0x03) {
		return xy, errors.New("not a 33-byte compressed point")
	}
	x, y := elliptic.UnmarshalCompressed(elliptic.P256(), b)
	if x == nil {
		return xy, errors.New("point is not on the curve")
	}
	x.FillBytes(xy[:32])
	y.FillBytes(xy[32:])
	return xy, nil
}

// Build returns the DER certificate for k, issued by a root whose name is CN = issuerCN (1 or 2 characters) and
// whose key is root. serial is the certificate serial number, 1 to 8 bytes, positive and minimally encoded.
func Build(k Keys, issuerCN string, serial []byte, root crypto.Signer) ([]byte, error) {
	if len(issuerCN) < 1 || len(issuerCN) > 2 {
		return nil, fmt.Errorf("secert: issuer CN %q must be 1 or 2 characters (size budget)", issuerCN)
	}
	if !serialOK(serial) {
		return nil, errors.New("secert: serial must be 1-8 bytes, positive, without a leading zero")
	}
	for _, p := range [][64]byte{k.Session, k.Identity, k.ECDH} {
		if _, err := pubKey(p); err != nil {
			return nil, fmt.Errorf("secert: public key: %w", err)
		}
	}
	der, err := encode(k, issuerCN, serial, root)
	if err != nil {
		return nil, err
	}
	if len(der) > MaxLen {
		return nil, fmt.Errorf("secert: certificate is %d bytes, slot 8 holds %d", len(der), MaxLen)
	}
	if _, _, err := Parse(der); err != nil {
		return nil, fmt.Errorf("secert: the built certificate does not parse back: %w", err)
	}
	return der, nil
}

// encode is the one place the profile is written down: Build signs it with the dev root, Parse re-encodes what it
// read with a throwaway key and requires the to-be-signed part to be byte-identical.
func encode(k Keys, issuerCN string, serial []byte, signer crypto.Signer) ([]byte, error) {
	subjectKey, err := pubKey(k.Identity)
	if err != nil {
		return nil, err
	}
	ext, err := cbor.Encode(cbor.M(0, compress(k.Session), 2, compress(k.ECDH), 7, k.ChipSN[:]))
	if err != nil {
		return nil, err
	}
	tpl := &x509.Certificate{
		SerialNumber:       new(big.Int).SetBytes(serial),
		Subject:            pkix.Name{CommonName: SubjectCN(k.Identity)},
		NotBefore:          notBefore,
		NotAfter:           notAfter,
		SignatureAlgorithm: x509.ECDSAWithSHA256,
		ExtraExtensions:    []pkix.Extension{{Id: OIDKeys, Critical: false, Value: ext}},
	}
	parent := &x509.Certificate{Subject: pkix.Name{CommonName: issuerCN}}
	return x509.CreateCertificate(rand.Reader, tpl, parent, subjectKey, signer)
}

func serialOK(serial []byte) bool {
	return len(serial) >= 1 && len(serial) <= 8 && serial[0]&0x80 == 0 && (serial[0] != 0 || len(serial) == 1)
}

// Parse checks the fixed structure and returns what the certificate binds and its issuer CN. It does NOT verify
// the signature (VerifyRoot does). Anything beyond the profile is an error: another extension, a critical one,
// more than a CN in the subject, a subject CN that is not the device id of the subject key, a key that is not
// P-256, an extension map with other keys, a serial longer than 8 bytes. The last step makes that complete: the
// profile is re-encoded from what was read, and the certificate's to-be-signed part must equal it byte for byte, so
// no field the checks above do not look at (issuer or subject unique IDs, another string type, a non-minimal
// encoding) gets through.
func Parse(der []byte) (Keys, string, error) {
	var k Keys
	if len(der) > MaxLen {
		return k, "", fmt.Errorf("secert: %d bytes, slot 8 holds %d", len(der), MaxLen)
	}
	c, err := x509.ParseCertificate(der)
	if err != nil {
		return k, "", fmt.Errorf("secert: %w", err)
	}
	if c.Version != 3 || c.SignatureAlgorithm != x509.ECDSAWithSHA256 {
		return k, "", errors.New("secert: not X.509 v3 with ecdsa-with-SHA256")
	}
	pub, ok := c.PublicKey.(*ecdsa.PublicKey)
	if !ok || pub.Curve != elliptic.P256() {
		return k, "", errors.New("secert: subject key is not P-256")
	}
	raw, err := pub.Bytes()
	if err != nil || len(raw) != 65 {
		return k, "", errors.New("secert: subject key encoding")
	}
	copy(k.Identity[:], raw[1:])
	if len(c.Subject.Names) != 1 || c.Subject.CommonName != SubjectCN(k.Identity) {
		return k, "", errors.New("secert: subject is not exactly CN = se:<device id of the subject key>")
	}
	if len(c.Issuer.Names) != 1 || len(c.Issuer.CommonName) < 1 || len(c.Issuer.CommonName) > 2 {
		return k, "", errors.New("secert: issuer is not exactly a 1-2 character CN")
	}
	if len(c.Extensions) != 1 || !c.Extensions[0].Id.Equal(OIDKeys) || c.Extensions[0].Critical {
		return k, "", errors.New("secert: want exactly one non-critical extension, the key extension")
	}
	v, err := cbor.Decode(c.Extensions[0].Value)
	if err != nil {
		return k, "", fmt.Errorf("secert: key extension: %w", err)
	}
	m, ok := v.(cbor.Map)
	if !ok || len(m) != 3 {
		return k, "", errors.New("secert: key extension is not a map of three entries")
	}
	get := func(key int, n int) ([]byte, error) {
		x, ok := m.Get(key)
		b, isBytes := x.([]byte)
		if !ok || !isBytes || len(b) != n {
			return nil, fmt.Errorf("secert: key extension entry %d is not %d bytes", key, n)
		}
		return b, nil
	}
	s0, err := get(0, 33)
	if err != nil {
		return k, "", err
	}
	s2, err := get(2, 33)
	if err != nil {
		return k, "", err
	}
	sn, err := get(7, 9)
	if err != nil {
		return k, "", err
	}
	if k.Session, err = decompress(s0); err != nil {
		return k, "", fmt.Errorf("secert: slot 0 key: %w", err)
	}
	if k.ECDH, err = decompress(s2); err != nil {
		return k, "", fmt.Errorf("secert: slot 2 key: %w", err)
	}
	copy(k.ChipSN[:], sn)
	if !c.NotBefore.Equal(notBefore) || !c.NotAfter.Equal(notAfter) {
		return k, "", errors.New("secert: validity is not the fixed 2020-01-01 .. 9999-12-31")
	}
	serial := c.SerialNumber.Bytes()
	if c.SerialNumber.Sign() == 0 {
		serial = []byte{0}
	}
	if c.SerialNumber.Sign() < 0 || !serialOK(serial) {
		return k, "", errors.New("secert: serial is not 1-8 bytes, positive")
	}
	throwaway, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return k, "", err
	}
	canon, err := encode(k, c.Issuer.CommonName, serial, throwaway)
	if err != nil {
		return k, "", fmt.Errorf("secert: re-encoding: %w", err)
	}
	cc, err := x509.ParseCertificate(canon)
	if err != nil || !bytes.Equal(cc.RawTBSCertificate, c.RawTBSCertificate) {
		return k, "", errors.New("secert: the certificate is not the canonical encoding of the profile")
	}
	return k, c.Issuer.CommonName, nil
}

// VerifyRoot checks the certificate's signature against the dev root's public key.
func VerifyRoot(der []byte, root *ecdsa.PublicKey) error {
	c, err := x509.ParseCertificate(der)
	if err != nil {
		return fmt.Errorf("secert: %w", err)
	}
	h := sha256.Sum256(c.RawTBSCertificate)
	if !ecdsa.VerifyASN1(root, h[:], c.Signature) {
		return errors.New("secert: signature does not verify against the dev root")
	}
	return nil
}

// Matches is the node's check of a certificate read from slot 8 against the chip it came from (config §2): the
// subject key is the slot 1 key, and the extension names this chip's slot 0 and slot 2 keys and serial.
func Matches(der []byte, chip Keys) error {
	k, _, err := Parse(der)
	if err != nil {
		return err
	}
	switch {
	case k.Identity != chip.Identity:
		return errors.New("secert: subject key is not the chip's slot 1 key")
	case k.Session != chip.Session:
		return errors.New("secert: slot 0 key differs from the chip's")
	case k.ECDH != chip.ECDH:
		return errors.New("secert: slot 2 key differs from the chip's")
	case !bytes.Equal(k.ChipSN[:], chip.ChipSN[:]):
		return errors.New("secert: chip serial differs")
	}
	return nil
}
