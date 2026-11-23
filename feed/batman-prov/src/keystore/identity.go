package keystore

// Identity is what the helper needs from a node identity backend (#255 phase 1, docs/design/255-phase1-impl.md
// PR 1). It has exactly the methods of today's file backend, with today's meaning; a secure-element backend will
// implement the same interface later. Secrets never leave an implementation: only public values, signatures over
// purpose-tagged messages, the ECDH shared secret for the helper's own use, and a yes/no claim check.
type Identity interface {
	// SN is the 9-byte serial used in the claim proof (proto.CheckMacInput).
	SN() []byte
	// DeviceID is lowercase hex of the device id, 18 characters.
	DeviceID() string
	// Cert is the DER of the identity certificate.
	Cert() []byte
	// DACPub is the SEC1-uncompressed identity public key.
	DACPub() []byte
	// ECDHPub is the SEC1-uncompressed ECDH public key.
	ECDHPub() []byte
	// ECDH returns the x-coordinate shared secret with peerPub65, for the helper's own use only.
	ECDH(peerPub65 []byte) ([]byte, error)
	// CheckMac verifies a claim response for a ClientChal the caller assembled, in constant time.
	CheckMac(clientChal, response []byte) bool
	// SignPurpose signs label ‖ fields for one of the fixed purposes and refuses anything else.
	SignPurpose(purpose string, fields ...[]byte) ([]byte, error)
	// Backend names the implementation ("file").
	Backend() string
}

// The file backend is an Identity.
var _ Identity = (*Keystore)(nil)
