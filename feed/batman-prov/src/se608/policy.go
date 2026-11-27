package se608

import "fmt"

// Policy decides, before the bus is touched, whether a command may be sent. It returns nil or an error wrapping
// ErrRefused.
type Policy func(Cmd) error

func refuse(c Cmd, why string) error {
	return fmt.Errorf("%w: %s mode 0x%02x param2 0x%04x, %d data bytes: %s", ErrRefused, opName(c.Op), c.P1, c.P2, len(c.Data), why)
}

// PolicyDaemon is the running helper's list (impl §2.2), each command pinned to the slot the design gives it
// (config §3) and to its exact length: Info (revision), plain Read, Nonce (pass-through, 32 bytes), GenKey (public
// key of slots 0-2), Sign (external, slot 0), ECDH (slot 2, clear output) and CheckMac (mode 0, slot 5). Nothing
// here changes the chip's EEPROM. The chip enforces the slot rules too; this stops a confused caller inside the
// daemon, not a compromised one: code in the same process can build a Dev with any policy (NewBurn, NewPolicy) or
// use the open bus. The trust boundary is the process (root, /dev/i2c-1 0600, the flock): a compromised helper owns
// the chip (impl §2.7; code review PR D2 round 2 B-m7).
func PolicyDaemon(c Cmd) error {
	switch c.Op {
	case OpInfo:
		if c.P1 == 0x00 && c.P2 == 0 && len(c.Data) == 0 {
			return nil
		}
		return refuse(c, "only the revision")
	case OpRead:
		if c.P1&0x7C == 0 && Zone(c.P1&0x03) <= ZoneData && len(c.Data) == 0 {
			return nil
		}
		return refuse(c, "plain reads only")
	case OpNonce:
		if c.P1 == NoncePassthrough && c.P2 == 0 && len(c.Data) == 32 {
			return nil
		}
		return refuse(c, "pass-through with 32 bytes only")
	case OpGenKey:
		if c.P1 == GenKeyPublic && c.P2 <= SlotECDH && len(c.Data) == 0 {
			return nil
		}
		return refuse(c, "the daemon only reads the public keys of slots 0-2")
	case OpSign:
		if c.P1 == SignExternal && c.P2 == SlotSession && len(c.Data) == 0 {
			return nil
		}
		return refuse(c, "external signatures with the session key only")
	case OpECDH:
		if c.P1 == ECDHClear && c.P2 == SlotECDH && len(c.Data) == 64 {
			return nil
		}
		return refuse(c, "the ECDH slot with clear output only")
	case OpCheckMac:
		if c.P1 == CheckMacSlotChal && c.P2 == SlotClaim && len(c.Data) == 77 {
			return nil
		}
		return refuse(c, "mode 0 on the claim slot only")
	}
	return fmt.Errorf("%w: %s", ErrRefused, opName(c.Op))
}

// PolicyBurn is PolicyDaemon plus what the burn mode needs (impl §2.2, §2.5; config §5.2): plain Write, Lock of the
// config zone, of the data zone and of the three key slots — always with the chip's CRC check where there is one —
// and GenKey in create mode for those three slots. Slot 8 is never slot-locked on the bench (config §5.3), and no
// other slot is lockable in the final image, so the policy does not let the burn mode try.
func PolicyBurn(c Cmd) error {
	switch c.Op {
	case OpWrite:
		if c.P1&0x7C == 0 && Zone(c.P1&0x03) <= ZoneData && (len(c.Data) == 4 || len(c.Data) == 32) {
			return nil
		}
		return refuse(c, "plain writes only")
	case OpLock:
		if len(c.Data) != 0 {
			return refuse(c, "Lock takes no data")
		}
		if c.P1 == LockConfig || c.P1 == LockData {
			return nil
		}
		if c.P1&0xC3 == lockSlot && c.P1>>2 <= SlotECDH && c.P2 == 0 {
			return nil
		}
		return refuse(c, "config, data or one of the key slots 0-2")
	case OpGenKey:
		if c.P1 == GenKeyCreate && c.P2 <= SlotECDH && len(c.Data) == 0 {
			return nil
		}
	}
	return PolicyDaemon(c)
}
