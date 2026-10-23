// Package keystore is the helper's node identity (docs/design/254-stage1-impl.md §4.2). Stage 1 has the
// "file" backend only: 7 files in /etc/batman-prov/identity/ (dir 0700) — node.key, ecdh.key (P-256 PKCS#8, 0600),
// node.cert (self-signed CN=dev:<device_id>, serialNumber=<sn hex>, 2020-01-01 → 2120-01-01, 0644), claim.secret
// (32 B, 0600), backend, sn, sha256 (sha256sum list of the first 6). Secrets never leave this package except the
// public parts; signing is purpose-tagged and the signed bytes are assembled here (219-protocol §3.6).
package keystore

import (
	"bytes"
	"crypto/ecdh"
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
	"os"
	"path/filepath"
	"strings"
	"time"

	"batman-prov/proto"
)

// Files of the file backend, in the order of the sha256 list.
var Files = []string{"node.key", "ecdh.key", "node.cert", "claim.secret", "backend", "sn"}

// Keystore is the loaded identity.
type Keystore struct {
	dacKey   *ecdsa.PrivateKey
	ecdhKey  *ecdh.PrivateKey
	certDER  []byte
	claimSec []byte
	sn       []byte
}

// SN is the 9-byte serial: file backend = SHA-256(DAC pub SEC1 65 B)[:9] (219-protocol §3.3).
func (k *Keystore) SN() []byte { return append([]byte(nil), k.sn...) }

// DeviceID = lowercase hex(sn), 18 characters.
func (k *Keystore) DeviceID() string { return hex.EncodeToString(k.sn) }

// Cert is the DER of the (single, self-signed) DAC certificate.
func (k *Keystore) Cert() []byte { return append([]byte(nil), k.certDER...) }

// DACPub is the SEC1-uncompressed DAC public key.
func (k *Keystore) DACPub() []byte {
	b, _ := k.dacKey.PublicKey.Bytes()
	return b
}

// ECDHPub is the SEC1-uncompressed ECDH public key.
func (k *Keystore) ECDHPub() []byte { return k.ecdhKey.PublicKey().Bytes() }

// ECDH returns the x-coordinate shared secret — only for the helper's own use (net.apply, psk_replay).
func (k *Keystore) ECDH(peerPub65 []byte) ([]byte, error) { return proto.ECDHX(k.ecdhKey, peerPub65) }

// CheckMac verifies a claim response for a ClientChal the CALLER assembled from its own values, in constant time.
func (k *Keystore) CheckMac(clientChal, response []byte) bool {
	return proto.CheckMacOK(k.claimSec, clientChal, k.sn, response)
}

// Backend is "file" (608B "se" is #255).
func (k *Keystore) Backend() string { return "file" }

// Purposes the DAC may sign; the signed bytes are label ‖ fields, assembled by SignPurpose.
const (
	PurposeStatic = proto.LabelNodeStatic // s_node_pub(32) ‖ boot_id(16)
	PurposeECDH   = proto.LabelNodeECDH   // ecdh_pub(65) — fields ignored, the key is our own
	PurposePeer   = proto.LabelPeer       // nonce_app(32) ‖ nonce_node(32) ‖ h(32)
)

// SignPurpose signs label ‖ fields for one of the fixed purposes; it refuses anything else (never a bare value).
func (k *Keystore) SignPurpose(purpose string, fields ...[]byte) ([]byte, error) {
	msg := []byte(purpose)
	switch purpose {
	case PurposeStatic:
		if len(fields) != 2 || len(fields[0]) != 32 || len(fields[1]) != 16 {
			return nil, errors.New("keystore: static wants s_node_pub(32), boot_id(16)")
		}
	case PurposeECDH:
		fields = [][]byte{k.ECDHPub()}
	case PurposePeer:
		if len(fields) != 3 || len(fields[0]) != 32 || len(fields[1]) != 32 || len(fields[2]) != 32 {
			return nil, errors.New("keystore: peer wants nonce_app(32), nonce_node(32), h(32)")
		}
	default:
		return nil, fmt.Errorf("keystore: purpose %q not signable", purpose)
	}
	for _, f := range fields {
		msg = append(msg, f...)
	}
	return proto.SignES256(k.dacKey, msg)
}

var (
	devNotBefore = time.Date(2020, 1, 1, 0, 0, 0, 0, time.UTC)
	devNotAfter  = time.Date(2120, 1, 1, 0, 0, 0, 0, time.UTC)
)

// DevSubject is the subject (= issuer) of the self-signed dev certificate: CN = "dev:" + device_id, serialNumber = hex(sn).
func DevSubject(sn []byte) pkix.Name {
	return pkix.Name{CommonName: "dev:" + hex.EncodeToString(sn), SerialNumber: hex.EncodeToString(sn)}
}

// DevCert builds the self-signed file-backend DAC certificate (serial 1, BasicConstraints CA:FALSE critical).
func DevCert(key *ecdsa.PrivateKey) ([]byte, error) {
	pub, _ := key.PublicKey.Bytes()
	s := sha256.Sum256(pub)
	sn := s[:9]
	subj, err := asn1.Marshal(rdnSequence(sn))
	if err != nil {
		return nil, err
	}
	tpl := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		RawSubject:            subj,
		RawIssuer:             subj,
		NotBefore:             devNotBefore,
		NotAfter:              devNotAfter,
		BasicConstraintsValid: true,
		IsCA:                  false,
		SignatureAlgorithm:    x509.ECDSAWithSHA256,
	}
	return x509.CreateCertificate(rand.Reader, tpl, tpl, &key.PublicKey, key)
}

// rdnSequence encodes the name exactly as the protocol vectors do (Python cryptography: UTF8String CN,
// PrintableString serialNumber), so the TBS of a cert built here equals the vector's for the same key.
func rdnSequence(sn []byte) pkix.RDNSequence {
	oidCN := asn1.ObjectIdentifier{2, 5, 4, 3}
	oidSN := asn1.ObjectIdentifier{2, 5, 4, 5}
	cn := asn1.RawValue{Tag: asn1.TagUTF8String, Class: asn1.ClassUniversal, Bytes: []byte("dev:" + hex.EncodeToString(sn))}
	ser := asn1.RawValue{Tag: asn1.TagPrintableString, Class: asn1.ClassUniversal, Bytes: []byte(hex.EncodeToString(sn))}
	return pkix.RDNSequence{
		{{Type: oidCN, Value: cn}},
		{{Type: oidSN, Value: ser}},
	}
}

// CheckDevCert verifies the binding the app checks before a TOFU pin (219-protocol §3.3): self-signed, signature
// valid, device_id == hex(SHA-256(cert pub)[:9]) == CN suffix == serialNumber.
func CheckDevCert(der []byte) (deviceID string, err error) {
	c, err := x509.ParseCertificate(der)
	if err != nil {
		return "", err
	}
	// self-signed with CA:FALSE: CheckSignatureFrom would demand a CA parent, so verify the TBS with the cert's own key
	if !bytes.Equal(c.RawIssuer, c.RawSubject) || c.CheckSignature(c.SignatureAlgorithm, c.RawTBSCertificate, c.Signature) != nil {
		return "", errors.New("keystore: dev cert not self-signed / bad signature")
	}
	pk, ok := c.PublicKey.(*ecdsa.PublicKey)
	if !ok || pk.Curve != elliptic.P256() {
		return "", errors.New("keystore: dev cert key is not P-256")
	}
	pub, _ := pk.Bytes()
	s := sha256.Sum256(pub)
	id := hex.EncodeToString(s[:9])
	if c.Subject.CommonName != "dev:"+id || c.Subject.SerialNumber != id {
		return "", errors.New("keystore: dev cert CN / serialNumber does not match its own key")
	}
	return id, nil
}

// ---- the file backend on disk ------------------------------------------------------------------------------------

// Generate creates a fresh identity in dir (which must not exist): writes into dir+".tmp" then renames.
func Generate(dir string) error {
	if _, err := os.Lstat(dir); err == nil {
		return errors.New("keystore: identity dir already exists")
	}
	tmp := dir + ".tmp"
	_ = os.RemoveAll(tmp)
	if err := os.Mkdir(tmp, 0o700); err != nil {
		return err
	}
	dac, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return err
	}
	ek, err := ecdh.P256().GenerateKey(rand.Reader)
	if err != nil {
		return err
	}
	dacDER, err := x509.MarshalPKCS8PrivateKey(dac)
	if err != nil {
		return err
	}
	ekDER, err := x509.MarshalPKCS8PrivateKey(ek)
	if err != nil {
		return err
	}
	cert, err := DevCert(dac)
	if err != nil {
		return err
	}
	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		return err
	}
	pub, _ := dac.PublicKey.Bytes()
	s := sha256.Sum256(pub)
	content := map[string][]byte{
		"node.key": dacDER, "ecdh.key": ekDER, "node.cert": cert, "claim.secret": secret,
		"backend": []byte("file\n"), "sn": []byte(hex.EncodeToString(s[:9]) + "\n"),
	}
	var sums strings.Builder
	for _, f := range Files {
		mode := os.FileMode(0o600)
		if f == "node.cert" {
			mode = 0o644
		}
		if err := writeSync(filepath.Join(tmp, f), content[f], mode); err != nil {
			return err
		}
		h := sha256.Sum256(content[f])
		fmt.Fprintf(&sums, "%x  %s\n", h, f)
	}
	if err := writeSync(filepath.Join(tmp, "sha256"), []byte(sums.String()), 0o600); err != nil {
		return err
	}
	if err := syncDir(tmp); err != nil {
		return err
	}
	if err := os.Rename(tmp, dir); err != nil {
		return err
	}
	return syncDir(filepath.Dir(dir))
}

// Load reads and verifies an identity dir: every file regular (no symlink), the sha256 list matches, the cert
// binds to the DAC key, and sn = SHA-256(DAC pub)[:9].
func Load(dir string) (*Keystore, error) {
	if fi, err := os.Lstat(dir); err != nil || !fi.IsDir() || fi.Mode()&os.ModeSymlink != 0 {
		return nil, errors.New("keystore: identity dir missing or not a directory")
	}
	read := func(f string) ([]byte, error) {
		p := filepath.Join(dir, f)
		fi, err := os.Lstat(p)
		if err != nil || !fi.Mode().IsRegular() {
			return nil, fmt.Errorf("keystore: %s missing or not a regular file", f)
		}
		return os.ReadFile(p)
	}
	sums, err := read("sha256")
	if err != nil {
		return nil, err
	}
	content := map[string][]byte{}
	for _, f := range Files {
		b, err := read(f)
		if err != nil {
			return nil, err
		}
		h := sha256.Sum256(b)
		if !bytes.Contains(sums, []byte(fmt.Sprintf("%x  %s\n", h, f))) {
			return nil, fmt.Errorf("keystore: %s does not match the sha256 list", f)
		}
		content[f] = b
	}
	if strings.TrimSpace(string(content["backend"])) != "file" {
		return nil, errors.New("keystore: backend is not file (se backend is #255: fail-secure, refuse)")
	}
	k, err := x509.ParsePKCS8PrivateKey(content["node.key"])
	if err != nil {
		return nil, err
	}
	dac, ok := k.(*ecdsa.PrivateKey)
	if !ok || dac.Curve != elliptic.P256() {
		return nil, errors.New("keystore: node.key is not P-256")
	}
	e, err := x509.ParsePKCS8PrivateKey(content["ecdh.key"])
	if err != nil {
		return nil, err
	}
	var ek *ecdh.PrivateKey
	switch x := e.(type) {
	case *ecdh.PrivateKey:
		ek = x
	case *ecdsa.PrivateKey:
		if ek, err = x.ECDH(); err != nil {
			return nil, err
		}
	default:
		return nil, errors.New("keystore: ecdh.key is not P-256")
	}
	id, err := CheckDevCert(content["node.cert"])
	if err != nil {
		return nil, err
	}
	pub, _ := dac.PublicKey.Bytes()
	s := sha256.Sum256(pub)
	if hex.EncodeToString(s[:9]) != id || strings.TrimSpace(string(content["sn"])) != id {
		return nil, errors.New("keystore: cert / sn do not belong to node.key")
	}
	if len(content["claim.secret"]) != 32 {
		return nil, errors.New("keystore: claim.secret is not 32 B")
	}
	return &Keystore{dacKey: dac, ecdhKey: ek, certDER: content["node.cert"], claimSec: content["claim.secret"], sn: s[:9]}, nil
}

func writeSync(p string, b []byte, mode os.FileMode) error {
	f, err := os.OpenFile(p, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode)
	if err != nil {
		return err
	}
	if _, err := f.Write(b); err != nil {
		f.Close()
		return err
	}
	if err := f.Sync(); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}

func syncDir(d string) error {
	f, err := os.Open(d)
	if err != nil {
		return err
	}
	defer f.Close()
	return f.Sync()
}
