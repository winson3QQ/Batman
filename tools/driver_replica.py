#!/usr/bin/env python3
"""Replicate morse_spi_cmd() byte-for-byte and decode the reply the way
morse_spi_find_response() does.

This is the script that identified the root cause: the response is correct but
arrives two bit-times late, so the driver reads 0xC0 where it expects 0x00.
"""
import spidev


def crc7_be(data):
    """CRC7 as used by the driver's crc7_be() — result is already left-shifted by 1."""
    crc = 0
    for b in data:
        for i in range(8):
            crc <<= 1
            if ((b >> (7 - i)) & 1) ^ ((crc >> 7) & 1):
                crc ^= 0x09
            crc &= 0x7F
    return crc << 1


def build(cmd, arg=0, size=20):
    """SPI_COMMAND_BUF_SIZE is 20; the command itself is the first 7 bytes."""
    buf = [0xFF] * size
    buf[1] = 0x40 | cmd                      # start bit + transmission bit
    buf[2:6] = list(arg.to_bytes(4, "big"))  # argument, big endian
    buf[6] = crc7_be(buf[1:6]) | 0x01        # CRC7 + end bit
    return buf


s = spidev.SpiDev()
s.open(0, 0)
s.mode = 0

for speed in (1_000_000, 50_000_000):
    s.max_speed_hz = speed
    for cmd in (63, 0):
        rx = s.xfer2(build(cmd))
        tail = rx[8:]                        # SPI_RESP_OFFSET = 8
        first = next((b for b in tail if b != 0xFF), None)
        if first == 0x00:
            verdict = "OK (0x00)"
        elif first == 0xFE:
            verdict = "shifted by one bit (0xFE) -> -ECOMM"
        elif first is not None:
            verdict = f"0x{first:02X} -> -EPROTO (-71)"
        else:
            verdict = "no response -> -ENODATA"
        print(f"{speed // 1_000_000:2d} MHz  CMD{cmd:<2}  "
              f"response window: {' '.join(f'{b:02X}' for b in tail)}")
        print(f"                    verdict: {verdict}")

s.close()
