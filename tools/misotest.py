#!/usr/bin/env python3
"""Minimal check that MISO is actually driven by the slave.

Clock out eight 0x00 bytes. All-0xFF back means the line is just idling high
(pull-up, nothing driving it); anything else means the slave is responding.
"""
import spidev

s = spidev.SpiDev()
s.open(0, 0)
s.max_speed_hz = 1_000_000
s.mode = 0
rx = s.xfer2([0x00] * 8)
print("   ", " ".join(f"{b:02X}" for b in rx))
s.close()
