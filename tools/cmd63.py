#!/usr/bin/env python3
"""Send raw SD/SDIO-over-SPI commands with a correct CRC7 and dump the reply.

CMD63 is Morse Micro's SDIO->SPI init command; CMD0/CMD52/CMD5 are standard and
useful for cross-checking that the slave is alive.
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


s = spidev.SpiDev()
s.open(0, 0)
s.max_speed_hz = 1_000_000
s.mode = 0

# SD convention: at least 74 clocks with CS deasserted before the first command.
s.xfer2([0xFF] * 10)

for cmd, arg in ((63, 0), (0, 0), (52, 0), (5, 0)):
    payload = [0x40 | cmd] + list(arg.to_bytes(4, "big"))
    frame = payload + [(crc7(payload) << 1) | 1]
    rx = s.xfer2(frame + [0xFF] * 10)
    print(f"CMD{cmd:<2} tx {' '.join(f'{b:02X}' for b in frame)}")
    print(f"      rx {' '.join(f'{b:02X}' for b in rx)}")

s.close()
