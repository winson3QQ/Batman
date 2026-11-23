package se608

// Bench config images (255-608b-config.md v7 §4 and §8.1). Only the bytes in ImageWords are meaningful; the rest
// of the array is left zero and never written.

type slotCfg struct{ slot, keyCfg uint16 }

// finalSlots is §4's slot table: SlotConfig, KeyConfig as 16-bit values, stored little-endian.
var finalSlots = [16]slotCfg{
	0: {0x2081, 0x0073}, // session key: external sign
	1: {0x2082, 0x0073}, // identity key: internal sign only
	2: {0x2084, 0x0073}, // ECDH
	3: {0x8F9F, 0x001C},
	4: {0x8F9F, 0x001C},
	5: {0x8F9F, 0x001C}, // claim secret
	6: {0x8F9F, 0x001C},
	7: {0x8F9F, 0x001C},
	8: {0x0F0F, 0x003C}, // dev-root certificate (not slot-locked on the bench)
	9: {0x8F9F, 0x001C}, 10: {0x8F9F, 0x001C}, 11: {0x8F9F, 0x001C}, 12: {0x8F9F, 0x001C},
	13: {0x8F9F, 0x001C}, 14: {0x8F9F, 0x001C}, 15: {0x8F9F, 0x001C},
}

// variantOverrides is §8.1: three unused slots changed for the rig's controls on chip 1.
var variantOverrides = map[int]slotCfg{
	3: {0x0F8F, 0x003C}, // secret, clear write, no NoMac: E8 control
	4: {0x2083, 0x0073}, // private key, GenKey, individually lockable: E6, E17, E9
	6: {0x0F0F, 0x003C}, // plain data, always writable, lockable: E6, E9, E13
}

// Image returns the config image. variant selects §8.1 (chip 1 on the rig) instead of §4. byte17 is the blank
// value E1 read (§4 keeps it as it was).
func Image(variant bool, byte17 byte) [ConfigLen]byte {
	var img [ConfigLen]byte
	img[16] = 0xC0 // I2C address 0x60
	img[17] = byte17
	img[18] = 0x00
	img[19] = 0x00 // ChipMode: no alternate address, fixed input levels, 1.3 s watchdog, fastest clock
	slots := finalSlots
	if variant {
		for k, v := range variantOverrides {
			slots[k] = v
		}
	}
	for k, s := range slots {
		img[20+2*k] = byte(s.slot)
		img[21+2*k] = byte(s.slot >> 8)
		img[96+2*k] = byte(s.keyCfg)
		img[97+2*k] = byte(s.keyCfg >> 8)
	}
	// 68-83: all zero (UseLock, VolatileKeyPermission, SecureBoot, KdfIvLoc, KdfIvStr, reserved).
	img[88], img[89] = 0xFF, 0xFF // SlotLocked: no slot locked
	img[90], img[91] = 0x00, 0x00 // ChipOptions 0x0000
	// 92-95: X509format, zero.
	return img
}
