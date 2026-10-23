// Package proto holds the helper-side computations of the provisioning protocol (docs/design/219-protocol.md
// v0.7): purpose labels, the CheckMac-shaped claim response, owner-op signature input, ES256 (low-s) verification
// and the HKDF derivations. Every signed / MAC'd input starts with its label and contains a value the node itself
// produced (h, nonce) — the node never signs or MACs a value handed to it (§3.6).
package proto

import (
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/hkdf"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/binary"
	"errors"
	"math/big"

	"batman-prov/cbor"
)

// Purpose labels (219-protocol §3.6).
const (
	LabelNodeStatic = "batman-node-static-v1"
	LabelNodeECDH   = "batman-node-ecdh-v1"
	LabelPeer       = "batman-peer-v1"
	LabelOwnerAuth  = "batman-owner-auth-v1"
	LabelOwnerOp    = "batman-owner-op-v1"
	LabelPskReplay  = "batman-psk-replay-v1"
	LabelClaim      = "batman-claim-v1"
	LabelNetcfg     = "batman-netcfg-v1"
	LabelMembers    = "batman-members-v1"
	LabelSecrets    = "batman-secrets-v1"
	LabelOwnerEnc   = "batman-owner-enc-v1"
)

// OtherData of the 608B CheckMac mode 0 (§5.4).
var OtherData = [13]byte{0x08}

func sha(parts ...[]byte) []byte {
	h := sha256.New()
	for _, p := range parts {
		h.Write(p)
	}
	return h.Sum(nil)
}

// ClientChal = SHA-256("batman-claim-v1" ‖ nonce ‖ h ‖ SHA-256(DAC DER) ‖ owner_pub) — always recomputed by the
// node from its OWN nonce, h, DAC and the owner_pub about to be stored (§5.4).
func ClientChal(nonce, h, dacDER, ownerPub []byte) []byte {
	return sha([]byte(LabelClaim), nonce, h, sha(dacDER), ownerPub)
}

// CheckMacInput is the 88-byte SHA-256 input of the 608B CheckMac mode 0 (§5.4).
func CheckMacInput(k, clientChal, sn []byte) ([]byte, error) {
	if len(k) != 32 || len(clientChal) != 32 || len(sn) != 9 {
		return nil, errors.New("proto: CheckMac wants K 32 B, ClientChal 32 B, SN 9 B")
	}
	in := make([]byte, 0, 88)
	in = append(in, k...)
	in = append(in, clientChal...)
	in = append(in, OtherData[0:4]...)
	in = append(in, make([]byte, 8)...)
	in = append(in, OtherData[4:7]...)
	in = append(in, sn[8])
	in = append(in, OtherData[7:11]...)
	in = append(in, sn[0:2]...)
	in = append(in, OtherData[11:13]...)
	return in, nil
}

// CheckMacOK compares a client's response with the expected one in constant time.
func CheckMacOK(k, clientChal, sn, response []byte) bool {
	in, err := CheckMacInput(k, clientChal, sn)
	if err != nil || len(response) != 32 {
		return false
	}
	return subtle.ConstantTimeCompare(sha(in), response) == 1
}

// ArgsHash = SHA-256(deterministic CBOR(request body without key 31)) (§5.7).
func ArgsHash(body cbor.Map) ([]byte, error) {
	b, err := cbor.Encode(body.Without(31))
	if err != nil {
		return nil, err
	}
	return sha(b), nil
}

// OwnerOpInput = "batman-owner-op-v1" ‖ h ‖ nonce_helper ‖ u8(len(verb)) ‖ verb ‖ args_hash (§5.7).
// verb is the ENVELOPE type, never the verb field of the owner-op itself.
func OwnerOpInput(h, nonceHelper []byte, verb string, argsHash []byte) ([]byte, error) {
	if len(h) != 32 || len(nonceHelper) != 32 || len(argsHash) != 32 || len(verb) < 1 || len(verb) > 255 {
		return nil, errors.New("proto: bad owner-op input sizes")
	}
	in := []byte(LabelOwnerOp)
	in = append(in, h...)
	in = append(in, nonceHelper...)
	in = append(in, byte(len(verb)))
	in = append(in, verb...)
	in = append(in, argsHash...)
	return in, nil
}

var p256HalfN = new(big.Int).Rsh(elliptic.P256().Params().N, 1)

// VerifyES256 verifies a raw r‖s ES256 signature over msg with an SEC1-uncompressed P-256 key, rejecting high-s.
func VerifyES256(pub65, msg, sig []byte) bool {
	if len(sig) != 64 {
		return false
	}
	pub, err := ecdsa.ParseUncompressedPublicKey(elliptic.P256(), pub65)
	if err != nil {
		return false
	}
	r, s := new(big.Int).SetBytes(sig[:32]), new(big.Int).SetBytes(sig[32:])
	if r.Sign() == 0 || s.Sign() == 0 || s.Cmp(p256HalfN) > 0 {
		return false
	}
	return ecdsa.Verify(pub, sha(msg), r, s)
}

// SignES256 signs msg and returns raw r‖s normalised to low-s.
func SignES256(key *ecdsa.PrivateKey, msg []byte) ([]byte, error) {
	r, s, err := ecdsa.Sign(nil, key, sha(msg))
	if err != nil {
		return nil, err
	}
	if s.Cmp(p256HalfN) > 0 {
		s.Sub(elliptic.P256().Params().N, s)
	}
	out := make([]byte, 64)
	r.FillBytes(out[:32])
	s.FillBytes(out[32:])
	return out, nil
}

// HKDF32 = HKDF-SHA256(ikm, salt = empty, info, L = 32) (§6).
func HKDF32(ikm, info []byte) []byte {
	k, err := hkdf.Key(sha256.New, ikm, nil, string(info), 32)
	if err != nil {
		panic(err) // only on L > 255*32
	}
	return k
}

func cat(parts ...[]byte) []byte {
	var out []byte
	for _, p := range parts {
		out = append(out, p...)
	}
	return out
}

func u32be(v uint32) []byte { b := make([]byte, 4); binary.BigEndian.PutUint32(b, v); return b }

// Derivations (§6). device_id is ASCII and always the last field of info.
func PskOwner(ownerTagKey []byte, deviceID string) []byte {
	return HKDF32(ownerTagKey, cat([]byte("batman-psk-owner-v1"), []byte(deviceID)))
}
func AdvOwner(advOwnerKey []byte, deviceID string) []byte {
	return HKDF32(advOwnerKey, cat([]byte("batman-adv-owner-v1"), []byte(deviceID)))
}
func PskMember(netRoot, netID []byte, version uint32) []byte {
	return HKDF32(netRoot, cat([]byte("batman-psk-member-v1"), netID, u32be(version)))
}
func AdvMember(netRoot, netID []byte, version uint32) []byte {
	return HKDF32(netRoot, cat([]byte("batman-adv-member-v1"), netID, u32be(version)))
}

// PskReplay = HKDF(z, "batman-psk-replay-v1" ‖ device_id), z = x of ECDH(node_ecdh_priv, owner_enc_pub).
func PskReplay(z []byte, deviceID string) []byte {
	return HKDF32(z, cat([]byte(LabelPskReplay), []byte(deviceID)))
}

// ECDHX returns the 32-byte x-coordinate shared secret of priv and an SEC1-uncompressed P-256 public key.
func ECDHX(priv *ecdh.PrivateKey, peerPub65 []byte) ([]byte, error) {
	pub, err := ecdh.P256().NewPublicKey(peerPub65)
	if err != nil {
		return nil, err
	}
	return priv.ECDH(pub)
}
