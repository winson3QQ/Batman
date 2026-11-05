"""blebridge — the Windows half of peer.py's BLE transport (docs/design/254-h4-harness.md §4.2). Transport only: it
never sees a secret in clear (only Noise ciphertext and the public CTRL / STATUS reads), and it never decides
anything. peer.py (WSL) starts it through interop with the absolute Windows python path and talks one line per
message on stdin / stdout:

  -> SCAN <seconds>          <- DEV <addr> <rssi>  (one per provd advertiser, filtered on the provd service UUID)
                             <- SCAN-END <count>
  -> CONNECT <addr>          <- CONNECTED <addr> wmax=<n> mtu=<n>    |  ERR connect <reason>
  -> FRAME <n>               (CTRL key 3, decoded by peer.py)  <- FRAMESIZE <min(244, n, wmax)>
  -> READ CTRL|STATUS        <- VAL <hex>                             |  ERR read <reason>
  -> MSG1                    (marks the start of the handshake: frames are counted from here on)
  -> W <hex>                 (one GATT frame, write-without-response on rx)
                             <- N <hex>   (every notification on tx, as it arrives)
  -> CLOSE                   <- CLOSED <addr> sent_after_msg1=<n>
  any failure / link loss    <- ERR <what> <reason>  /  <- LOST <addr>
  stdin EOF (peer.py or WSL died) -> disconnect and exit: an orphan bridge must not hold the link (provd withdraws its
  advertising while a link is up, bluez.go:771-774).

The frame size is min(244, the CTRL key-3 max frame peer.py sends with FRAME, the write-without-response size bleak
reports once the MTU exchange has settled — read twice, equal), never above provd's inbound MaxFrame 512
(provd/frame.go:12-17). The bridge decodes no CBOR: Windows needs only bleak (requirements-win.txt).

`python blebridge.py --selftest` drives the line protocol against a fake backend (no Bluetooth needed).
"""
import asyncio
import sys
import threading

SVC = "540aa38c-0086-4d58-a9c0-c7c9d1e1bd42"
RX = "540aa38c-0086-4d59-a9c0-c7c9d1e1bd42"
TX = "540aa38c-0086-4d5a-a9c0-c7c9d1e1bd42"
CTRL = "540aa38c-0086-4d5b-a9c0-c7c9d1e1bd42"
STATUS = "540aa38c-0086-4d5c-a9c0-c7c9d1e1bd42"
OUT_FRAME = 244
IN_MAX = 512


class Bridge:
    def __init__(self, scanner_cls, client_cls, out):
        self.scanner_cls, self.client_cls, self.out = scanner_cls, client_cls, out
        self.client, self.addr, self.frame = None, None, OUT_FRAME
        self.counting, self.sent_after_msg1 = False, 0
        self.devices = {}
        self.lock = threading.Lock()

    def say(self, line):
        with self.lock:
            self.out.write(line + "\n")
            self.out.flush()

    async def scan(self, secs):
        found = {}

        def cb(d, ad):
            if SVC in [u.lower() for u in (ad.service_uuids or [])]:
                found[d.address] = (d, ad.rssi)

        s = self.scanner_cls(cb)
        await s.start()
        await asyncio.sleep(secs)
        await s.stop()
        self.devices = {a: d for a, (d, _r) in found.items()}
        for a, (_d, r) in sorted(found.items(), key=lambda x: -x[1][1]):
            self.say("DEV %s %d" % (a, r))
        self.say("SCAN-END %d" % len(found))

    async def connect(self, addr):
        if self.client is not None:
            self.say("ERR connect already-connected")
            return
        dev = self.devices.get(addr)
        if dev is None:
            self.say("ERR connect not-scanned")
            return
        c = self.client_cls(dev, disconnected_callback=lambda _c: self.say("LOST %s" % addr))
        try:
            await c.connect()
            await c.start_notify(TX, lambda _h, data: self.say("N " + bytes(data).hex()))
        except Exception as e:  # noqa: BLE001 — reported, never raised
            self.say("ERR connect %s" % type(e).__name__)
            try:
                await c.disconnect()
            except Exception:  # noqa: BLE001
                pass
            return
        self.client, self.addr = c, addr
        self.counting, self.sent_after_msg1 = False, 0
        # MTU: wait until the write-without-response size reads the same twice (WinRT reports 20 first)
        w1, w2 = None, None
        for _ in range(20):
            w2 = self._wmax()
            if w2 == w1 and w2:
                break
            w1 = w2
            await asyncio.sleep(0.25)
        self.wmax = w2 or OUT_FRAME
        self.frame = min(OUT_FRAME, self.wmax, IN_MAX)
        self.say("CONNECTED %s wmax=%d mtu=%s" % (addr, self.wmax, getattr(c, "mtu_size", "?")))

    def _wmax(self):
        try:
            ch = self.client.services.get_characteristic(RX)
            return int(ch.max_write_without_response_size)
        except Exception:  # noqa: BLE001
            return None

    async def read(self, which):
        if self.client is None:
            self.say("ERR read not-connected")
            return
        try:
            v = await self.client.read_gatt_char(CTRL if which == "CTRL" else STATUS)
            self.say("VAL " + bytes(v).hex())
        except Exception as e:  # noqa: BLE001
            self.say("ERR read %s" % type(e).__name__)

    async def write(self, hexframe):
        if self.client is None:
            self.say("ERR write not-connected")
            return
        data = bytes.fromhex(hexframe)
        if len(data) > self.frame:
            self.say("ERR write frame-too-long %d>%d" % (len(data), self.frame))
            return
        try:
            await self.client.write_gatt_char(RX, data, response=False)
            if self.counting:
                self.sent_after_msg1 += 1
        except Exception as e:  # noqa: BLE001
            self.say("ERR write %s" % type(e).__name__)

    async def close(self):
        if self.client is not None:
            try:
                await self.client.disconnect()
            except Exception:  # noqa: BLE001
                pass
        # sent_after_msg1 counts the frames peer sent from the MSG1 mark on, msg1's own frames included; peer.py
        # subtracts msg1's frame count to get "frames after msg1" (254-h4 §4.2 (a)(b))
        self.say("CLOSED %s sent_after_msg1=%d" % (self.addr, self.sent_after_msg1))
        self.client, self.addr = None, None

    async def handle(self, line):
        parts = line.split()
        if not parts:
            return True
        cmd = parts[0]
        if cmd == "SCAN":
            await self.scan(float(parts[1]) if len(parts) > 1 else 10.0)
        elif cmd == "CONNECT" and len(parts) == 2:
            await self.connect(parts[1])
        elif cmd == "READ" and len(parts) == 2 and parts[1] in ("CTRL", "STATUS"):
            await self.read(parts[1])
        elif cmd == "FRAME" and len(parts) == 2 and parts[1].isdigit():
            self.frame = min(OUT_FRAME, int(parts[1]), getattr(self, "wmax", OUT_FRAME), IN_MAX)
            self.say("FRAMESIZE %d" % self.frame)
        elif cmd == "MSG1":
            self.counting, self.sent_after_msg1 = True, 0
        elif cmd == "W" and len(parts) == 2:
            await self.write(parts[1])
        elif cmd == "CLOSE":
            await self.close()
        else:
            self.say("ERR proto %s" % cmd[:16])
        return True

    async def run(self, lines):
        """lines: an asyncio.Queue of stdin lines, None = EOF."""
        while True:
            line = await lines.get()
            if line is None:
                break
            await self.handle(line.strip())
        await self.close()


def _stdin_queue(loop):
    q = asyncio.Queue()

    def reader():
        for line in sys.stdin:
            loop.call_soon_threadsafe(q.put_nowait, line)
        loop.call_soon_threadsafe(q.put_nowait, None)

    threading.Thread(target=reader, daemon=True).start()
    return q


def main():
    from bleak import BleakClient, BleakScanner
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    b = Bridge(BleakScanner, BleakClient, sys.stdout)
    loop.run_until_complete(b.run(_stdin_queue(loop)))


# ---- selftest: a fake bleak ----

class _Ad:
    def __init__(self, uuids, rssi):
        self.service_uuids, self.rssi = uuids, rssi


class _Dev:
    def __init__(self, a):
        self.address = a


class _FakeScanner:
    ADS = [("AA:01", [SVC], -60), ("AA:02", [SVC], -80), ("BB:99", ["0000180f-0000-1000-8000-00805f9b34fb"], -40)]

    def __init__(self, cb):
        self.cb = cb

    async def start(self):
        for a, u, r in self.ADS:
            self.cb(_Dev(a), _Ad(u, r))

    async def stop(self):
        pass


class _Ch:
    max_write_without_response_size = 514          # what WinRT reports at MTU 517: above provd's 512


class _Svcs:
    def get_characteristic(self, _u):
        return _Ch()


class _FakeClient:
    written = []

    def __init__(self, dev, disconnected_callback=None):
        self.dev, self.services, self.mtu_size = dev, _Svcs(), 517

    async def connect(self):
        pass

    async def read_gatt_char(self, u):
        return bytes.fromhex("a4010102000318f404192000") if u == CTRL else bytes.fromhex("a10302")

    async def start_notify(self, _u, cb):
        self.cb = cb

    async def write_gatt_char(self, _u, data, response):
        _FakeClient.written.append((bytes(data), response))
        self.cb(None, b"\x00\x00\x01" + bytes(data))  # echo as a notification

    async def disconnect(self):
        pass


def selftest():
    import io
    out = io.StringIO()
    b = Bridge(_FakeScanner, _FakeClient, out)
    script = ["SCAN 0", "CONNECT AA:01", "FRAME 300", "READ STATUS", "W " + "11" * 10, "MSG1", "W " + "22" * 10,
              "W " + "33" * 245, "CLOSE", "CONNECT BB:99", "BOGUS"]

    async def go():
        q = asyncio.Queue()
        for s in script:
            q.put_nowait(s)
        q.put_nowait(None)
        await b.run(q)

    asyncio.run(go())
    lines = out.getvalue().splitlines()
    fails, n = [], 0

    def check(name, cond):
        nonlocal n
        n += 1
        if not cond:
            fails.append("%s  (output: %s)" % (name, lines))

    check("SCAN lists only provd advertisers, strongest first", lines[:3] == ["DEV AA:01 -60", "DEV AA:02 -80", "SCAN-END 2"])
    check("CONNECTED reports WinRT's wmax", "CONNECTED AA:01 wmax=514 mtu=517" in lines)
    check("frame = min(244, FRAME 300, wmax 514) = 244 (never the 514 WinRT reports)", "FRAMESIZE 244" in lines)
    check("READ STATUS -> VAL hex", "VAL a10302" in lines)
    check("notifications are relayed as N lines", any(l.startswith("N 000001" + "11" * 10) for l in lines))
    check("a frame above the frame size is refused, not sent", any(l.startswith("ERR write frame-too-long 245>244") for l in lines)
          and all(len(w) <= 244 for w, _r in _FakeClient.written))
    check("writes are write-without-response", all(r is False for _w, r in _FakeClient.written))
    check("frames are counted from MSG1 on (1 after, not the one before)", "CLOSED AA:01 sent_after_msg1=1" in lines)
    check("a device that does not advertise provd cannot be connected", "ERR connect not-scanned" in lines)
    check("unknown command -> ERR proto", "ERR proto BOGUS" in lines)
    # negative control of the counter: a bridge that counted every frame would report 2 here
    check("negative: the counter does not count the pre-MSG1 frame", "CLOSED AA:01 sent_after_msg1=2" not in lines)
    # EOF closes: the last line after EOF is a CLOSED from run()'s final close()
    check("stdin EOF closes the link (orphan bridge must not hold it)", lines[-1].startswith("CLOSED"))
    for f in fails:
        print("FAIL blebridge selftest:", f)
    print("blebridge selftest: %d checks, %d failed" % (n, len(fails)))
    return 1 if fails else 0


if __name__ == "__main__":
    if sys.argv[1:2] == ["--selftest"]:
        sys.exit(selftest())
    main()
