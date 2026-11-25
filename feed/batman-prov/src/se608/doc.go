// Package se608 is the ATECC608B driver core for #255 in v2.0 (docs/design/255-608b-impl.md §2.2, PR D).
//
// PR D scope (agreed 2026-11-23): only what the rig experiments E0–E3 need (255-608b-config.md §8): the I2C wake /
// idle / sleep sequence, the command packet with its CRC-16, response polling, and the commands Info (revision),
// Read and Write (config and data zones; the OTP zone is refused), and Random for E2. Nothing here can lock a zone
// or a slot: Exec refuses every opcode outside allowedOps before touching the bus (Lock, UpdateExtra, GenKey,
// PrivWrite, ...). allowedOps is one list for the whole package; PR D2 splits the product driver's commands from
// se-lab's (255-608b-impl.md §2.2, §9). Sign, ECDH, CheckMac, GenKey and the burn flow come after
// E1–E3 have run on a real chip.
//
// PROVISIONAL(E1): the status codes, the wake response, the execution-time caps and the "read the count byte, then
// the rest" polling below come from the datasheet summary and cryptoauthlib's host code, not yet from a capture on
// our chip. E1 captures the real bytes; until then Provisional stays true, and PR 2's CI fails while it is.
//
// The chip lock is an exclusive flock on the bus device (OpenI2C).
//
// The package is not linked into batman-provhelper yet (feed/batman-prov/Makefile builds only batman-provhelper and
// batman-provd); cmd/se-lab uses it on the rig.
package se608

// Provisional is true while the wire formats above are unconfirmed on a real chip (see the package comment).
const Provisional = true
