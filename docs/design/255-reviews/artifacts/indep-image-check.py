# Independent recomputation of the variant image from the design tables (config.md §4 + §8.1).
# Shares no code with se-lab. Values typed from the document tables.
import hashlib, re, sys
slot = {i: (0x8F9F, 0x001C) for i in range(16)}          # unused default (§4)
slot[0] = (0x2081, 0x0073); slot[1] = (0x2082, 0x0073); slot[2] = (0x2084, 0x0073)
slot[5] = (0x8F9F, 0x001C); slot[8] = (0x0F0F, 0x003C)
final = dict(slot)
slot[3] = (0x0F8F, 0x003C); slot[4] = (0x2083, 0x0073); slot[6] = (0x0F0F, 0x003C)   # §8.1 variant

def build(sl, b17):
    c = bytearray(128)
    c[16] = 0xC0; c[17] = b17; c[18] = 0; c[19] = 0
    for i in range(16):
        sc, kc = sl[i]
        c[20+2*i] = sc & 0xFF; c[21+2*i] = sc >> 8
        c[96+2*i] = kc & 0xFF; c[97+2*i] = kc >> 8
    c[88] = c[89] = 0xFF            # SlotLocked
    # 52-67 counters, 68-83, 84-87, 90-95 all 0x00 in the image
    return bytes(c[16:128])

def parse(path, tag, last=True):
    rows = {}
    for ln in open(path):
        m = re.match(r'%s\[\s*(\d+)\]=(.*)' % tag, ln.strip())
        if m: rows.setdefault(int(m.group(1)), []).append(bytes.fromhex(m.group(2).replace(' ', '')))
    out = bytearray(128)
    for off, v in rows.items():
        b = v[-1] if last else v[0]
        out[off:off+16] = b
    return bytes(out)

R = sys.argv[1]
var = build(slot, 0x00)
h = hashlib.sha256(var).hexdigest()
print('indep variant sha256 =', h)
print('se-lab        sha256 = 82fe0122113ddc511837f2f5fee71b51d38cbe1e96fed72f04b1b37e7be950f3')
print('HASH MATCH' if h == '82fe0122113ddc511837f2f5fee71b51d38cbe1e96fed72f04b1b37e7be950f3' else 'HASH MISMATCH')
img = parse(R + '/e3-image.txt', 'image')[16:]
print('indep == se-lab image bytes:', img == var)
chip = parse(R + '/e3-verify.txt', 'config')
blank = parse(R + '/e1-dump.txt', 'config')
cmp_ranges = [(16, 52), (68, 84), (88, 128)]
bad = [i for a, b in cmp_ranges for i in range(a, b) if chip[i] != var[i-16]]
print('chip readback vs indep over 16-51,68-83,88-127: diffs at', bad)
print('chip 52-67 (counters) =', chip[52:68].hex(), '| 84-87 =', chip[84:88].hex())
print('blank->written changed bytes:', [i for i in range(128) if blank[i] != chip[i]])
print('bytes 0-15 unchanged:', blank[:16] == chip[:16])
fin = build(final, 0x00)
print('final image sha256 (byte17=00) =', hashlib.sha256(fin).hexdigest())
print('variant vs final differ at bytes:', [i+16 for i in range(112) if var[i] != fin[i]])

def dec(i, sc, kc):
    rk = sc & 0xF; nomac = sc >> 4 & 1; lim = sc >> 5 & 1; enc = sc >> 6 & 1; sec = sc >> 7 & 1
    wk = sc >> 8 & 0xF; wc = sc >> 12
    priv = kc & 1; pub = kc >> 1 & 1; kt = kc >> 2 & 7; lock = kc >> 5 & 1; rr = kc >> 6 & 1; ra = kc >> 7 & 1
    rest = kc >> 8
    s = 'slot%2d SC=%04X KC=%04X | ReadKey=%X NoMac=%d Lim=%d EncRd=%d Secret=%d WriteKey=%X WriteCfg=%s | Priv=%d PubInfo=%d KeyType=%d Lockable=%d ReqRandom=%d ReqAuth=%d hi=%02X' % (
        i, sc, kc, rk, nomac, lim, enc, sec, wk, format(wc, '04b'), priv, pub, kt, lock, rr, ra, rest)
    if priv: s += ' | extSign=%d intSign=%d ECDH=%d ECDHtoNext=%d GenKey=%d PrivWrite=%d' % (rk & 1, rk >> 1 & 1, rk >> 2 & 1, rk >> 3 & 1, wc >> 1 & 1, wc >> 2 & 1)
    return s
print('--- variant decode')
for i in range(16): print(dec(i, *slot[i]))

# ---- config-lock CRC (independent CRC-16, checked against the wake response the real chip sent)
def rev8(b): return int('{:08b}'.format(b)[::-1], 2)
def crc16(data):
    # CRC-16 poly 0x8005, init 0, MSB-first shift register, each data byte bit-reversed first, no output reflection
    r = 0
    for b in data:
        r ^= rev8(b) << 8
        for _ in range(8):
            r = ((r << 1) ^ 0x8005) & 0xFFFF if r & 0x8000 else (r << 1) & 0xFFFF
    return r
# real-chip vector: wake response 04 11 33 43 (count, status, crc lo, crc hi)
c = crc16(bytes([0x04, 0x11])); print('vector 04 11 -> %02x %02x (chip sent 33 43)' % (c & 255, c >> 8), 'OK' if (c & 255, c >> 8) == (0x33, 0x43) else 'BAD')
rows = {}
sec = None
for ln in open(sys.argv[1] + "/e3-verify.txt"):
    m = re.match(r'config\[\s*(\d+)\]=(.*)', ln.strip())
    if m: rows[int(m.group(1))] = bytes.fromhex(m.group(2).replace(' ', ''))   # last occurrence = final dump
cfg = b''.join(rows[k] for k in sorted(rows)); assert len(cfg) == 128
c = crc16(cfg); print('config-lock CRC over the 128 read-back bytes = 0x%04x  -> Lock param2 bytes (LE): %02x %02x' % (c, c & 255, c >> 8))
pkt = bytes([0x07, 0x17, 0x00, c & 255, c >> 8]); p = crc16(pkt)
print('expected Lock(config, with CRC) packet: 03 ' + ' '.join('%02x' % b for b in pkt) + ' %02x %02x' % (p & 255, p >> 8))
