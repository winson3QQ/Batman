"""blebridge — the Windows half of peer.py's BLE transport (docs/design/254-h4-harness.md §4.2). Transport only: it
never sees a secret in clear (only Noise ciphertext and the public CTRL / STATUS reads), and it never decides
anything. peer.py (WSL) starts it through interop with the absolute Windows python path and talks one line per
message on stdin / stdout:

  -> SCAN <seconds>          <- DEV <addr> <rssi>  (one per provd advertiser, filtered on the provd service UUID)
                             <- SCAN-END <count>
  -> CONNECT <addr>          <- CONNECTED <addr> wmax=<n> mtu=<n>    |  ERR connect <reason>
                             (GATT discovery uncached: WinRT asks the node, so the node's btmon sees the discovery —
                             prov-gatt-254 takes the ATT handles from it; bleak winrt/client.py use_cached_services)
  -> FRAME <n>               (CTRL key 3, decoded by peer.py)  <- FRAMESIZE <min(244, n, wmax)>
  -> FRAMEMAX <n>            (prov-gatt-254 S512 only)          <- FRAMESIZE <min(n, wmax, 513)>: the 244 clamp lifted
  -> READ CTRL|STATUS        <- VAL <hex>                             |  ERR read <reason>
  -> MSG1                    (marks the start of the handshake: frames are counted from here on)
  -> W <hex>                 (one GATT frame, write-without-response on rx)   |  ERR write bad-hex
                             <- N <hex>   (every notification on tx, as it arrives)
  -> TS on                   <- TS on: from now on notifications are "NT <monotonic ms> <hex>" (default "N <hex>",
                             which older peers parse: peer.py's N reader takes everything after "N " as hex)
  -> PID                     <- PID <n>
  -> HB                      (no answer) arms the stdin watchdog on its first use: from then on, no stdin LINE for
                             WATCHDOG_S seconds = the peer is dead or stuck -> disconnect, "WATCHDOG exit", exit.
                             The time is taken by the stdin reader thread when a line ARRIVES, not when its command
                             is handled: a slow CONNECT or a long write burst never starves it (review A3-m5 / n8).
                             A peer that never sends HB (eh9) is never watched.
  -> CLOSE                   <- CLOSED <addr> sent_after_msg1=<n>
  any failure / link loss    <- ERR <what> <reason>  /  <- LOST <addr>
  stdin EOF (peer.py or WSL died) -> disconnect and exit: an orphan bridge must not hold the link (provd withdraws its
  advertising while a link is up, bluez.go:771-774).

The frame size is min(244, the CTRL key-3 max frame peer.py sends with FRAME, the write-without-response size bleak
reports once the MTU exchange has settled — read twice, equal), never above provd's inbound MaxFrame 512
(provd/frame.go:12-17) unless FRAMEMAX asks for exactly the boundary test. The bridge decodes no CBOR: Windows needs
only bleak (requirements-win.txt).

`python blebridge.py --selftest` drives the line protocol against a fake backend (no Bluetooth needed).
"""
import asyncio
import io
import os
import sys
import threading
import time

SVC = "540aa38c-0086-4d58-a9c0-c7c9d1e1bd42"
RX = "540aa38c-0086-4d59-a9c0-c7c9d1e1bd42"
TX = "540aa38c-0086-4d5a-a9c0-c7c9d1e1bd42"
CTRL = "540aa38c-0086-4d5b-a9c0-c7c9d1e1bd42"
STATUS = "540aa38c-0086-4d5c-a9c0-c7c9d1e1bd42"
OUT_FRAME = 244
IN_MAX = 512
FRAME_MAX_TEST = 513     # FRAMEMAX may reach one byte past provd's MaxFrame: the S512 boundary's other side
WATCHDOG_S = 10.0


class Bridge:
    def __init__(self, scanner_cls, client_cls, out, watchdog_s=WATCHDOG_S, on_exit=None):
        self.scanner_cls, self.client_cls, self.out = scanner_cls, client_cls, out
        self.client, self.addr, self.frame = None, None, OUT_FRAME
        self.counting, self.sent_after_msg1 = False, 0
        self.devices = {}
        self.lock = threading.Lock()
        self.ts = False
        self.watchdog_s = watchdog_s
        self.armed = False                   # set by the first HB
        self.last_rx = time.monotonic()      # written by the stdin reader thread only
        self.on_exit = on_exit or (lambda: os._exit(0))

    def say(self, line):
        with self.lock:
            self.out.write(line + "\n")
            self.out.flush()

    def note_rx(self, line):
        """Called by the stdin reader thread for every line as it arrives (the watchdog's clock)."""
        self.last_rx = time.monotonic()
        if line.strip() == "HB":
            self.armed = True

    async def watchdog(self):
        while True:
            await asyncio.sleep(min(1.0, self.watchdog_s / 4))
            if self.armed and time.monotonic() - self.last_rx > self.watchdog_s:
                self.say("WATCHDOG exit (no stdin line for %.0f s)" % self.watchdog_s)
                await self.close()
                self.on_exit()
                return

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
        c = self.client_cls(dev, disconnected_callback=lambda _c: self.say("LOST %s" % addr),
                            winrt={"use_cached_services": False})
        try:
            await c.connect()
            await c.start_notify(TX, self._notify)
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

    def _notify(self, _h, data):
        if self.ts:
            self.say("NT %d %s" % (int(time.monotonic() * 1000), bytes(data).hex()))
        else:
            self.say("N " + bytes(data).hex())

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
        try:
            data = bytes.fromhex(hexframe)
        except ValueError:
            self.say("ERR write bad-hex")
            return
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
        elif cmd == "FRAMEMAX" and len(parts) == 2 and parts[1].isdigit():
            self.frame = min(int(parts[1]), getattr(self, "wmax", OUT_FRAME), FRAME_MAX_TEST)
            self.say("FRAMESIZE %d" % self.frame)
        elif cmd == "MSG1":
            self.counting, self.sent_after_msg1 = True, 0
        elif cmd == "W" and len(parts) == 2:
            await self.write(parts[1])
        elif cmd == "TS" and len(parts) == 2 and parts[1] in ("on", "off"):
            self.ts = parts[1] == "on"
            self.say("TS %s" % parts[1])
        elif cmd == "PID":
            self.say("PID %d" % os.getpid())
        elif cmd == "HB":
            pass                                   # the reader thread already took its time
        elif cmd == "CLOSE":
            await self.close()
        else:
            self.say("ERR proto %s" % cmd[:16])
        return True

    async def run(self, lines):
        """lines: an asyncio.Queue of stdin lines, None = EOF."""
        wd = asyncio.ensure_future(self.watchdog())
        try:
            while True:
                line = await lines.get()
                if line is None:
                    break
                await self.handle(line.strip())
            await self.close()
        finally:
            wd.cancel()


def _stdin_queue(loop, bridge):
    q = asyncio.Queue()

    def reader():
        for line in sys.stdin:
            bridge.note_rx(line)          # the arrival time, in this thread (the watchdog's clock)
            loop.call_soon_threadsafe(q.put_nowait, line)
        loop.call_soon_threadsafe(q.put_nowait, None)

    threading.Thread(target=reader, daemon=True).start()
    return q


def main():
    from bleak import BleakClient, BleakScanner
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    b = Bridge(BleakScanner, BleakClient, sys.stdout)
    loop.run_until_complete(b.run(_stdin_queue(loop, b)))


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
    kwargs = []
    disconnects = 0
    connect_delay = 0.0

    def __init__(self, dev, disconnected_callback=None, **kw):
        self.dev, self.services, self.mtu_size = dev, _Svcs(), 517
        _FakeClient.kwargs.append(kw)

    async def connect(self):
        await asyncio.sleep(_FakeClient.connect_delay)

    async def read_gatt_char(self, u):
        return bytes.fromhex("a4010102000318f404192000") if u == CTRL else bytes.fromhex("a10302")

    async def start_notify(self, _u, cb):
        self.cb = cb

    async def write_gatt_char(self, _u, data, response):
        _FakeClient.written.append((bytes(data), response))
        self.cb(None, b"\x00\x00\x01" + bytes(data))  # echo as a notification

    async def disconnect(self):
        _FakeClient.disconnects += 1


def _run(bridge_cls, script=None, watchdog_s=WATCHDOG_S, feed=None, exits=None):
    """script: lines fed at once, or feed(queue, bridge) feeds them over time. Returns the output lines."""
    out = io.StringIO()
    b = bridge_cls(_FakeScanner, _FakeClient, out, watchdog_s=watchdog_s,
                   on_exit=(lambda: exits.append(1)) if exits is not None else None)

    async def go():
        q = asyncio.Queue()
        if feed is None:
            for s in script:
                b.note_rx(s)
                q.put_nowait(s)
            q.put_nowait(None)
            await b.run(q)
        else:
            t = asyncio.ensure_future(b.run(q))
            await feed(q, b)
            try:
                await asyncio.wait_for(t, 30)
            except asyncio.TimeoutError:
                pass

    asyncio.run(go())
    return out.getvalue().splitlines()


def selftest():
    fails, n = [], 0

    def check(name, cond, lines=None):
        nonlocal n
        n += 1
        if not cond:
            fails.append("%s  (output: %s)" % (name, lines))

    _FakeClient.written = []
    script = ["SCAN 0", "CONNECT AA:01", "FRAME 300", "READ STATUS", "W " + "11" * 10, "MSG1", "W " + "22" * 10,
              "W " + "33" * 245, "CLOSE", "CONNECT BB:99", "BOGUS"]
    lines = _run(Bridge, script)
    check("SCAN lists only provd advertisers, strongest first", lines[:3] == ["DEV AA:01 -60", "DEV AA:02 -80", "SCAN-END 2"], lines)
    check("CONNECTED reports WinRT's wmax", "CONNECTED AA:01 wmax=514 mtu=517" in lines, lines)
    check("CONNECT asks WinRT for uncached GATT discovery (the node's btmon must see it)",
          {"winrt": {"use_cached_services": False}} in _FakeClient.kwargs, _FakeClient.kwargs)
    check("frame = min(244, FRAME 300, wmax 514) = 244 (never the 514 WinRT reports)", "FRAMESIZE 244" in lines, lines)
    check("READ STATUS -> VAL hex", "VAL a10302" in lines, lines)
    check("notifications are relayed as N lines", any(l.startswith("N 000001" + "11" * 10) for l in lines), lines)
    check("a frame above the frame size is refused, not sent", any(l.startswith("ERR write frame-too-long 245>244") for l in lines)
          and all(len(w) <= 244 for w, _r in _FakeClient.written), lines)
    check("writes are write-without-response", all(r is False for _w, r in _FakeClient.written), lines)
    check("frames are counted from MSG1 on (1 after, not the one before)", "CLOSED AA:01 sent_after_msg1=1" in lines, lines)
    check("a device that does not advertise provd cannot be connected", "ERR connect not-scanned" in lines, lines)
    check("unknown command -> ERR proto", "ERR proto BOGUS" in lines, lines)
    check("negative: the counter does not count the pre-MSG1 frame", "CLOSED AA:01 sent_after_msg1=2" not in lines, lines)
    check("stdin EOF closes the link (orphan bridge must not hold it)", lines[-1].startswith("CLOSED"), lines)

    # ---- prov-gatt-254 additions
    _FakeClient.written = []
    lines = _run(Bridge, ["SCAN 0", "CONNECT AA:01", "W 01", "W 0300", "FRAMEMAX 600", "W " + "44" * 513,
                          "W " + "45" * 514, "TS on", "W 0a0b", "PID", "W 0", "W zz", "W 01HB", "CLOSE"])
    check("1 B and 2 B frames pass the bridge (the 3 B minimum is provd's rule, the thing under test)",
          (b"\x01", False) in _FakeClient.written and (b"\x03\x00", False) in _FakeClient.written, lines)
    check("FRAMEMAX lifts the clamp to min(n, wmax, 513)", "FRAMESIZE 513" in lines
          and any(len(w) == 513 for w, _r in _FakeClient.written), lines)
    check("FRAMEMAX still refuses 514", "ERR write frame-too-long 514>513" in lines, lines)
    check("TS on -> NT <ms> <hex> notifications", "TS on" in lines
          and any(l.startswith("NT ") and l.endswith(" 0000010a0b") for l in lines), lines)
    check("PID answers this process's pid", "PID %d" % os.getpid() in lines, lines)
    check("a bad hex line (odd / not hex / an interleaved line) is ERR write bad-hex, never a crash",
          lines.count("ERR write bad-hex") == 3 and lines[-1].startswith("CLOSED"), lines)
    lines = _run(Bridge, ["SCAN 0", "CONNECT AA:01", "W 0a0b", "CLOSE"])
    check("old peer + new bridge: without TS on, notifications stay N <hex>",
          "N 0000010a0b" in lines and not any(l.startswith("NT ") for l in lines), lines)

    # watchdog: HB once, then silence -> disconnect + WATCHDOG exit
    exits = []
    _FakeClient.disconnects = 0

    async def silent(q, b):
        for s in ["SCAN 0", "CONNECT AA:01", "HB"]:
            b.note_rx(s)
            q.put_nowait(s)
        await asyncio.sleep(2.0)          # > watchdog 0.6 s
        q.put_nowait(None)
    lines = _run(Bridge, watchdog_s=0.6, feed=silent, exits=exits)
    check("watchdog: HB then silence > WATCHDOG_S -> WATCHDOG exit, link closed",
          any(l.startswith("WATCHDOG exit") for l in lines) and bool(exits) and _FakeClient.disconnects >= 1, lines)

    # watchdog clock = line ARRIVAL: a CONNECT that takes 1.5 s while HBs keep arriving must not trigger it
    async def busy(q, b):
        for s in ["SCAN 0", "HB", "CONNECT AA:01"]:
            b.note_rx(s)
            q.put_nowait(s)
        for _ in range(8):                # HBs arrive while CONNECT is being handled
            await asyncio.sleep(0.2)
            b.note_rx("HB")
            q.put_nowait("HB")
        b.note_rx("CLOSE")
        q.put_nowait("CLOSE")
        q.put_nowait(None)
    exits = []
    _FakeClient.connect_delay = 1.5
    lines = _run(Bridge, watchdog_s=0.6, feed=busy, exits=exits)
    check("watchdog: a slow handler with HBs arriving meanwhile does NOT trigger it (reader-thread clock)",
          not exits and not any(l.startswith("WATCHDOG") for l in lines) and any(l.startswith("CONNECTED") for l in lines), lines)

    # negative control of that check: a bridge that stamps the time in the HANDLER fires on the same input
    class HandlerClock(Bridge):
        def note_rx(self, line):
            if line.strip() == "HB":
                self.armed = True

        async def handle(self, line):
            self.last_rx = time.monotonic()
            return await Bridge.handle(self, line)
    exits = []
    lines = _run(HandlerClock, watchdog_s=0.6, feed=busy, exits=exits)
    _FakeClient.connect_delay = 0.0
    check("negative: a handler-time watchdog fires on the same slow CONNECT (the check can tell the two apart)",
          bool(exits), lines)

    # no HB ever (eh9): never watched
    async def nohb(q, b):
        for s in ["SCAN 0", "CONNECT AA:01"]:
            b.note_rx(s)
            q.put_nowait(s)
        await asyncio.sleep(1.5)
        q.put_nowait(None)
    exits = []
    lines = _run(Bridge, watchdog_s=0.6, feed=nohb, exits=exits)
    check("a peer that never sends HB is never cut by the watchdog", not exits, lines)

    for f in fails:
        print("FAIL blebridge selftest:", f)
    print("blebridge selftest: %d checks, %d failed" % (n, len(fails)))
    return 1 if fails else 0


if __name__ == "__main__":
    if sys.argv[1:2] == ["--selftest"]:
        sys.exit(selftest())
    main()
