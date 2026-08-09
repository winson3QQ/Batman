#!/usr/bin/env python3
"""Try all four SPI modes (CPOL/CPHA) against CMD5 and CMD52.

Rules out a clock polarity/phase mismatch. On this hardware mode 0 is correct and
none of the others improve the reply.
"""
import spidev


def crc7(data):
    crc = 0
    for b in data:
        for i in range(8):
            crc <<= 1
            if (b >> (7 - i)) & 1 ^ ((crc >> 7) & 1):
                crc ^= 0x09
            crc &= 0x7F
    return crc


def frame(cmd, arg=0):
    p = [0x40 | cmd] + list(arg.to_bytes(4, "big"))
    return p + [(crc7(p) << 1) | 1]


for mode in (0, 1, 2, 3):
    s = spidev.SpiDev()
    s.open(0, 0)
    s.max_speed_hz = 1_000_000
    s.mode = mode
    s.xfer2([0xFF] * 10)
    rx5 = s.xfer2(frame(5) + [0xFF] * 8)
    rx52 = s.xfer2(frame(52) + [0xFF] * 8)
    s.close()
    print(f"mode {mode}: CMD5  {' '.join(f'{b:02X}' for b in rx5[6:])}")
    print(f"        CMD52 {' '.join(f'{b:02X}' for b in rx52[6:])}")
