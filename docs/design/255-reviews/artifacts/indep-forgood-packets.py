# Independent recomputation (no se-lab code) of chip 1's data-lock CRC and the other for-good packets.
import hashlib
def rev8(b): return int('{:08b}'.format(b)[::-1], 2)
def crc16(data):
    r = 0
    for b in data:
        r ^= rev8(b) << 8
        for _ in range(8):
            r = ((r << 1) ^ 0x8005) & 0xFFFF if r & 0x8000 else (r << 1) & 0xFFFF
    return r
def pkt(op, p1, p2):
    body = bytes([7, op, p1, p2 & 255, p2 >> 8]); c = crc16(body)
    return '03 ' + ' '.join('%02x' % b for b in body) + ' %02x %02x' % (c & 255, c >> 8)
sn = bytes.fromhex('0123ba99e2ca248cee')
size = [36]*8 + [416] + [72]*7
private = {0, 1, 2, 4}                       # variant image: KeyConfig bit 0
def key(label): return hashlib.sha256(('se-lab test ' + label + ' ').encode() + sn).digest()
slots = [bytes(n) for n in size]
slots[5] = key('claim secret') + bytes(4)
slots[3] = key('slot 3 key') + bytes(4)
for fill in (0x00, 0xFF):
    summary = b''.join(s for i, s in enumerate(slots) if i not in private) + bytes([fill]) * 64
    c = crc16(summary)
    print('data crc (OTP fill %02x) = %04x  lock-data packet: %s' % (fill, c, pkt(0x17, 0x01, c)))
print('counter-inc 1      :', pkt(0x24, 0x01, 1))
print('lock-slot 4        :', pkt(0x17, 0x02 | 4 << 2, 0))
print('lock-slot 6        :', pkt(0x17, 0x02 | 6 << 2, 0))
print('lock-slot 5        :', pkt(0x17, 0x02 | 5 << 2, 0))
print('update-extra 1 a0  :', pkt(0x20, 0x01, 0xa0))
print('update-extra 2 00  :', pkt(0x20, 0x02, 0x00))
