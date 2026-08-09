#!/usr/bin/env python3
"""Sweep clock rates with a few TX patterns and print whatever MISO returns.

If the reply is bit-identical across every frequency, the problem is in the logic
layer, not signal integrity. That single observation is what ruled out "the SPI
clock is too fast" as a hypothesis.
"""
import spidev

PATTERNS = {
    "0x00 x8":      [0x00] * 8,
    "0xFF x8":      [0xFF] * 8,
    "CMD63-shaped": [0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF],
}

for speed in (1_000_000, 4_000_000, 10_000_000, 50_000_000):
    s = spidev.SpiDev()
    s.open(0, 0)
    s.max_speed_hz = speed
    s.mode = 0
    lines = []
    for name, tx in PATTERNS.items():
        rx = s.xfer2(list(tx))
        lines.append(f"{name:<13} -> {' '.join(f'{b:02X}' for b in rx)}")
    s.close()
    print(f"--- {speed // 1_000_000} MHz ---")
    for line in lines:
        print("   ", line)
