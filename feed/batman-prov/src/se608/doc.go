// Package se608 is the ATECC608B driver core for #255 in v2.0 (docs/design/255-608b-impl.md §2.2, PR D).
//
// It holds the I2C wake / idle sequence, the command packet with its CRC-16, response polling, and the nine
// commands the product needs: Info, Read, Write, Lock, Nonce (pass-through), GenKey, Sign (external), ECDH and
// CheckMac (255-608b-impl.md §2.2). What a Dev may send is decided by its Policy before the bus is touched:
// New gives the daemon's list (nothing that changes the chip), NewBurn adds Write, Lock and key generation for the
// burn mode. Everything else the chip can do (Random, MAC, GenDig, KDF, AES, Counter, UpdateExtra, PrivWrite, ...)
// is only in package se608/lab, which se-lab uses on the rig and no shipped binary links. A Lock that skips the
// chip's CRC check is refused under every policy.
//
// Confirmed on a real chip (measured on chip 0123ba99e2ca248cee, 2026-11-27 (E1-E3 on the rig; results in docs/design/255-608b-config.md §8.3)): the wake pulse and its
// response 04 11 33 43 (3/3), the packet with its CRC-16, the "read the count byte, then the rest" polling, Info,
// Read, Write and Random, and that this driver does not need the reset word before a receive. Bus 100 kHz.
// Still from the datasheet summary, not measured: every status code except 0x00 and 0x0F, and the execution-time
// caps (no command came near them, but the maxima themselves were not timed). Not yet run on a real chip at all:
// Lock, Nonce, GenKey, Sign, ECDH and CheckMac (cmds.go) — E4, E6, E17, E8, E10 and E14 are where they first do.
//
// The chip lock is an exclusive flock on the bus device (OpenI2C).
//
// The package is not linked into batman-provhelper yet (feed/batman-prov/Makefile builds only batman-provhelper and
// batman-provd); cmd/se-lab uses it on the rig.
package se608

// Provisional was true while the wire formats above were unconfirmed on a real chip. E1-E3 ran on 2026-11-27 and
// every format this package uses held on the first try (see the package comment for what is still unmeasured).
const Provisional = false
