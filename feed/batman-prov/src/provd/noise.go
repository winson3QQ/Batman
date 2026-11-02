// Package provd is the protocol half of the #254 provisioning service (docs/design/254-p2-impl.md): the Noise
// responder, GATT framing, the session state machine and its routing to batman-provhelper, the read-only cache.
// Transport-agnostic: the BLE (BlueZ D-Bus) and the prov_test frame socket live in cmd/batman-provd.
package provd

import (
	"crypto/rand"
	"errors"
	"io"

	"github.com/flynn/noise"
)

var suite = noise.NewCipherSuite(noise.DH25519, noise.CipherChaChaPoly, noise.HashSHA256)

// msg1 lengths (F-P13): NX = e (32); NXpsk0 = e + the AEAD tag of the empty payload (48).
const (
	Msg1NX  = 32
	Msg1PSK = 48
	// NumPSK candidates are tried in PSK mode, always (219 §3.4: owners <= 4, member, replay; padded with random).
	NumPSK = 6
)

// Prologue = "batman-prov/1" 0 "ble" 0 device_hint (219 §3.2; the frame socket also says "ble", as the vectors do).
func Prologue(deviceHint string) []byte {
	return append([]byte("batman-prov/1\x00ble\x00"), deviceHint...)
}

// GenerateStatic makes this provd start's s_node (219 §3.3: per start, memory only).
func GenerateStatic(rng io.Reader) (noise.DHKey, error) { return noise.DH25519.GenerateKeypair(rng) }

// Handshake is the result of answering one msg1.
type Handshake struct {
	Msg2 []byte
	Fake bool // msg2 is the same-length fake: wait for the handshake timeout, then disconnect
	PSK  int  // index of the candidate that opened msg1 (PSK mode), -1 for NX / fake
	H    []byte
	Recv *noise.CipherState // initiator -> responder
	Send *noise.CipherState // responder -> initiator
	// ReadAttempts counts ReadMessage calls (6 in PSK mode whatever happens: the unit test checks it)
	ReadAttempts int
}

func newResponder(static noise.DHKey, prologue, psk []byte, rng io.Reader) (*noise.HandshakeState, error) {
	cfg := noise.Config{CipherSuite: suite, Pattern: noise.HandshakeNX, Initiator: false, Prologue: prologue,
		StaticKeypair: static, Random: rng}
	if psk != nil {
		cfg.PresharedKey, cfg.PresharedKeyPlacement = psk, 0
	}
	return noise.NewHandshakeState(cfg)
}

// Respond answers msg1. psks == nil = NX mode (unclaimed / legacy); otherwise exactly NumPSK candidates, every one
// tried (no early exit, 219 §3.4). A wrong length, a PSK that opens nothing, or a PSK-length msg1 on an NX node gets
// the fake msg2: a fresh real ephemeral, the same two DHs as the real path (ee, se), random bytes to the real length.
func Respond(msg1 []byte, static noise.DHKey, prologue []byte, psks [][]byte, nodeCert []byte, rng io.Reader) (*Handshake, error) {
	if rng == nil {
		rng = rand.Reader
	}
	hs := &Handshake{PSK: -1}
	var ok *noise.HandshakeState
	if psks == nil {
		if len(msg1) == Msg1NX {
			st, err := newResponder(static, prologue, nil, rng)
			if err != nil {
				return nil, err
			}
			hs.ReadAttempts++
			if _, _, _, err := st.ReadMessage(nil, msg1); err == nil {
				ok = st
			}
		}
	} else {
		if len(psks) != NumPSK {
			return nil, errors.New("provd: PSK mode needs exactly 6 candidates")
		}
		for i, k := range psks {
			st, err := newResponder(static, prologue, k, rng)
			if err != nil {
				return nil, err
			}
			hs.ReadAttempts++
			_, _, _, err = st.ReadMessage(nil, msg1)
			if err == nil && ok == nil && len(msg1) == Msg1PSK {
				ok, hs.PSK = st, i
			}
		}
	}
	if ok == nil {
		hs.PSK = -1
		m, err := fakeMsg2(msg1, static, len(nodeCert), rng)
		if err != nil {
			return nil, err
		}
		hs.Msg2, hs.Fake = m, true
		return hs, nil
	}
	m2, cs1, cs2, err := ok.WriteMessage(nil, nodeCert)
	if err != nil {
		return nil, err
	}
	if cs1 == nil || cs2 == nil {
		return nil, errors.New("provd: handshake did not complete at msg2")
	}
	hs.Msg2, hs.H, hs.Recv, hs.Send = m2, ok.ChannelBinding(), cs1, cs2
	return hs, nil
}

// fakeMsg2 = e'_pub(32) || random(48 + certLen + 16) (F-P13: = len(real msg2)), after DH(e', e_phone) and
// DH(s_node, e_phone) — e_phone = msg1[:32], padded with random when msg1 is shorter.
func fakeMsg2(msg1 []byte, static noise.DHKey, certLen int, rng io.Reader) ([]byte, error) {
	e, err := noise.DH25519.GenerateKeypair(rng)
	if err != nil {
		return nil, err
	}
	ePhone := make([]byte, 32)
	n := copy(ePhone, msg1)
	if n < 32 {
		if _, err := io.ReadFull(rng, ePhone[n:]); err != nil {
			return nil, err
		}
	}
	noise.DH25519.DH(e.Private, ePhone)      // ee (errors on a low-order point are ignored: same work)
	noise.DH25519.DH(static.Private, ePhone) // se
	out := make([]byte, 32+48+certLen+16)
	copy(out, e.Public)
	if _, err := io.ReadFull(rng, out[32:]); err != nil {
		return nil, err
	}
	return out, nil
}
