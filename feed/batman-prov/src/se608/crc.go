package se608

// CRC is the ATECC CRC-16: polynomial 0x8005, initial value 0, data bits taken LSB first, no final XOR — the
// bit-by-bit form of cryptoauthlib's atCRC. The packet carries it little-endian (low byte first).
func CRC(data []byte) uint16 {
	var crc uint16
	for _, b := range data {
		for m := byte(1); m != 0; m <<= 1 {
			dataBit := b&m != 0
			crcBit := crc&0x8000 != 0
			crc <<= 1
			if dataBit != crcBit {
				crc ^= 0x8005
			}
		}
	}
	return crc
}

// appendCRC appends CRC(p[from:]) little-endian.
func appendCRC(p []byte, from int) []byte {
	c := CRC(p[from:])
	return append(p, byte(c), byte(c>>8))
}

// crcOK reports whether the last two bytes of p are the little-endian CRC of the bytes before them.
func crcOK(p []byte) bool {
	if len(p) < 3 {
		return false
	}
	n := len(p) - 2
	c := CRC(p[:n])
	return p[n] == byte(c) && p[n+1] == byte(c>>8)
}
