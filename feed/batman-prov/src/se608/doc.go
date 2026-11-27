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
// Confirmed on a real chip (measured on chip 0123ba99e2ca248cee, 2026-11-27 (E1-E3 on the rig; results in docs/design/255-608b-config.md §8.3)): the wake pulse and its
// response 04 11 33 43 (3/3), the packet with its CRC-16, the "read the count byte, then the rest" polling, Info,
// Read, Write and Random, and that this driver does not need the reset word before a receive. Bus 100 kHz.
// Still from the datasheet summary, not measured: every status code except 0x00 and 0x0F, and the execution-time
// caps (no command came near them, but the maxima themselves were not timed).
//
// The chip lock is an exclusive flock on the bus device (OpenI2C).
//
// The package is not linked into batman-provhelper yet (feed/batman-prov/Makefile builds only batman-provhelper and
// batman-provd); cmd/se-lab uses it on the rig.
package se608

// Provisional was true while the wire formats above were unconfirmed on a real chip. E1-E3 ran on 2026-11-27 and
// every format this package uses held on the first try (see the package comment for what is still unmeasured).
const Provisional = false
