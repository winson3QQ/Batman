package keystore

// Identity is what the helper needs from a node identity backend (#255 phase 1 PR 1, scope in #255
// issuecomment-7093091698). It has exactly the methods of today's file backend, with today's meaning; a
// secure-element backend will implement the same interface later. Secrets never leave an implementation: only
// public values, signatures over purpose-tagged messages, the ECDH shared secret for the helper's own use, and a
// yes/no claim check.
type Identity interface {
	// SN is the 9-byte serial used in the claim proof (proto.CheckMacOK / proto.CheckMacInput).
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
	// SignPurpose signs label ‖ fields for one of the fixed purposes and refuses anything else (never a bare
	// value). The field rules are part of the contract, not of one backend (see (*Keystore).SignPurpose):
	// PurposeStatic needs exactly s_node_pub(32) ‖ boot_id(16); PurposePeer exactly nonce_app(32) ‖
	// nonce_node(32) ‖ h(32); PurposeECDH ignores the caller's fields and signs the backend's own ECDHPub.
	SignPurpose(purpose string, fields ...[]byte) ([]byte, error)
	// Backend names the implementation ("file").
	Backend() string
}

// The file backend is an Identity.
var _ Identity = (*Keystore)(nil)
