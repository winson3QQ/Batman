"""The gateway process: start sequence (§1), M10 migration + scheduler watch, M8 sweep, M12 memory
reserve, M13 stop, M17 health + watchdog, the snapshot, logging. `python3 eud-gateway.pyz` runs main()."""
from __future__ import annotations

import asyncio
import json
import logging
import logging.handlers
import os
import signal
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor

from . import __version__, config, otsconfig
from .amqp import Broker
from .db import Database
from .server import Gateway
from .tls import TlsContextHolder

log = logging.getLogger("gateway")


# -- M12 memory reserve ------------------------------------------------------------------------------
class MemReserve:
    """used = memory.current − memory.stat file, against memory.max − reserve. Unreadable -> no cap."""

    def __init__(self, reserve_mb: int, cg: str = "/sys/fs/cgroup"):
        self.reserve = reserve_mb * 1024 * 1024
        self.cg = cg
        self._t = 0.0
        self._ok = True
        self.readable = True

    def ok(self) -> bool:
        now = time.monotonic()
        if now - self._t < 1.0:
            return self._ok
        self._t = now
        try:
            with open(os.path.join(self.cg, "memory.max")) as f:
                mx = f.read().strip()
            if mx == "max":
                self._ok = True; return True
            with open(os.path.join(self.cg, "memory.current")) as f:
                cur = int(f.read().strip())
            filec = 0
            with open(os.path.join(self.cg, "memory.stat")) as f:
                for line in f:
                    if line.startswith("file "):
                        filec = int(line.split()[1]); break
            self._ok = (int(mx) - (cur - filec)) > self.reserve
            self.readable = True
        except (OSError, ValueError):
            if self.readable:
                log.warning("cgroup memory unreadable: the memory reserve is not enforced")
            self.readable = False
            self._ok = True
        return self._ok


class App:
    def __init__(self, settings: config.Settings, ots: otsconfig.OtsConfig):
        self.s, self.ots = settings, ots
        self.loop = asyncio.new_event_loop()
        self.loop.set_default_executor(ThreadPoolExecutor(max_workers=4, thread_name_prefix="db"))
        self.db = Database(ots.db_uri)
        self.mem = MemReserve(settings.reserve_mb)
        self.tls = TlsContextHolder(ots.ca_pem, ots.server_pem, ots.server_key, ots.ca_crl)
        self.broker = Broker(self.loop, ots.rabbit_host, ots.rabbit_user, ots.rabbit_password, ots.rabbit_ttl_ms,
                             on_state=self._amqp_state)
        self.gw = Gateway(self.loop, settings, self.db, self.broker, self.mem.ok, self.tls)
        self.started = time.monotonic()
        self.listening = False
        self.stopping = False
        self.heartbeat = time.monotonic()
        self.jobs_resumed: list[str] = []
        self.jobs_logged: tuple = ()
        self.exit_code = 0
        self.stop_line = ""

    # -- start sequence (§1) ---------------------------------------------------------------------
    async def wait_dependencies(self) -> None:
        last = None
        while True:
            try:
                missing = await self.gw.db_call(self.db.schema_ready, timeout=15)
            except Exception as e:
                missing = [f"db: {e}"]
            tls_ok = self.tls.files_present()
            if not missing and tls_ok:
                return
            msg = ("waiting for schema (%s)" % ", ".join(missing)) if missing else "waiting for TLS files"
            if msg != last:
                log.info(msg)
                last = msg
            await asyncio.sleep(5)

    async def migrate(self) -> None:
        delay = 2
        while True:
            try:
                res = await self.gw.db_call(self.db.migrate_record_fks, timeout=60)
                for name, what in res.items():
                    log.info("fk %s: RESTRICT (%s)", name, what)
                return
            except Exception as e:
                log.warning("fk migration failed (%s): retry in %d s", e, delay)
                await asyncio.sleep(delay)
                delay = min(delay * 2, 30)

    async def sweep(self) -> None:
        try:
            n = await self.gw.db_call(self.db.sweep_connected, timeout=15)
            log.info("presence sweep: %d rows", n)
        except Exception as e:
            log.warning("presence sweep failed: %s", e)

    async def start(self) -> None:
        log.info("batman-eud-gateway %s starting; config %s", __version__, self.ots.redacted())
        check_ots_version(self.s.ots_version)
        await self.wait_dependencies()
        await self.migrate()
        await self.sweep()
        while True:                        # a half-written cert file is waited for, never a crash loop (C1A-10)
            try:
                self.tls.build(); break
            except Exception as e:
                log.warning("TLS context not built yet (%s): retry in 5 s", e)
                await asyncio.sleep(5)
        self.loop.create_task(self._periodic())
        threading.Thread(target=self._watchdog, name="watchdog", daemon=True).start()
        self.loop.create_task(self._health_server())
        self.broker.start()
        t0 = time.monotonic()               # §1 order: AMQP open and declared BEFORE the listeners bind
        while not self.broker.open:
            if time.monotonic() - t0 > 60 and int(time.monotonic() - t0) % 30 == 0:
                log.info("waiting for AMQP before binding the listeners")
            await asyncio.sleep(0.5)
        await self.gw.start_listeners()
        self.listening = True
        log.info("ready")

    # -- periodic (1 s) ---------------------------------------------------------------------------
    async def _periodic(self) -> None:
        n = 0
        while not self.stopping:
            now = time.monotonic()
            self.heartbeat = now
            try:
                self.gw.tick(now)
                if n % self.s.snapshot_s == 0:
                    self._snapshot(now)
                if n % self.s.reconcile_s == 0:
                    await self._watch_jobs()
                    if self.tls.refresh_if_needed():
                        # asyncio servers hold the SSLContext object: re-create the 8089 listener with the
                        # new one (existing connections keep theirs; M14 cert rotation without restart)
                        await self.gw.restart_tls_listener()
                self._amqp_down_check(now)
            except Exception as e:
                log.error("periodic: %s", e)
            n += 1
            await asyncio.sleep(1)

    async def _watch_jobs(self) -> None:
        try:
            resumed = await self.gw.db_call(self.db.resumed_jobs)
        except Exception as e:
            log.debug("scheduler watch: %s", e)   # a missing table on a first boot: retry next tick
            return
        self.jobs_resumed = resumed
        if tuple(resumed) != self.jobs_logged:
            for j in resumed:
                log.warning("RESUMED job %s (the record is not protected against it)", j)
            self.jobs_logged = tuple(resumed)

    def _amqp_state(self, up: bool) -> None:
        pass

    def _amqp_down_check(self, now: float) -> None:
        # only once the listeners are bound: the start sequence WAITS for the broker (§1), it never exits (C2A-5)
        if self.listening and self.broker.down_since is not None and now - self.broker.down_since > self.s.amqp_max_down_s:
            log.error("exit 3: AMQP down for %d s", int(now - self.broker.down_since))
            self._exit(3)

    def _watchdog(self) -> None:
        while not self.stopping:
            time.sleep(5)
            if self.listening and time.monotonic() - self.heartbeat > 30:
                log.error("exit 3: event loop wedged (%d s without a heartbeat)", int(time.monotonic() - self.heartbeat))
                os._exit(3)

    def _exit(self, code: int) -> None:
        self.exit_code = code
        try:
            self._snapshot(time.monotonic())
        finally:
            logging.shutdown()
            os._exit(code)

    # -- snapshot --------------------------------------------------------------------------------
    def _snapshot(self, now: float) -> None:
        snap = self.gw.table.snapshot(now)
        snap.update({
            "uptime_s": round(now - self.started, 1), "written_monotonic": round(now, 1),
            "version": __version__, "listening": self.listening, "amqp_open": self.broker.open,
            "amqp_down_s": (None if self.broker.down_since is None else round(now - self.broker.down_since, 1)),
            "jobs_resumed": self.jobs_resumed, "crl_honoured": self.tls.crl_honoured, "crl_reason": self.tls.crl_reason,
            "mem_cap_enforced": self.mem.readable, "stop": self.stop_line,
        })
        snap["counters"].update({k: v for k, v in self.broker.stats.items()})
        snap["counters"]["cache_total"] = self.broker.cached_total()
        snap["counters"]["inflight"] = self.broker.inflight_total()
        path = self.s.snapshot_path
        try:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            tmp = path + ".tmp"
            with open(tmp, "w") as f:
                json.dump(snap, f)
            os.replace(tmp, path)
        except OSError as e:
            log.debug("snapshot: %s", e)

    # -- health (M17) ----------------------------------------------------------------------------
    async def _health_server(self) -> None:
        async def handle(reader, writer):
            try:
                line = await asyncio.wait_for(reader.readline(), 2.0)
                await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), 2.0)
            except Exception:
                line = b""
            ok = self.listening and self.broker.open and not self.stopping
            body = json.dumps({"ok": ok, "amqp_open": self.broker.open, "listening": self.listening,
                               "jobs_resumed": self.jobs_resumed, "crl_honoured": self.tls.crl_honoured,
                               "devices": len(self.gw.table.devices)}).encode()
            status = b"200 OK" if (ok and line.startswith(b"GET")) else (b"503 Service Unavailable" if line.startswith(b"GET") else b"405 Method Not Allowed")
            writer.write(b"HTTP/1.0 " + status + b"\r\nContent-Type: application/json\r\nContent-Length: " +
                         str(len(body)).encode() + b"\r\nConnection: close\r\n\r\n" + body)
            try:
                await writer.drain()
            finally:
                writer.close()
        srv = await asyncio.start_server(handle, "0.0.0.0", self.s.health_port, limit=1024)
        async with srv:
            await srv.serve_forever()

    # -- stop (M13) ------------------------------------------------------------------------------
    def request_stop(self, signame: str) -> None:
        if self.stopping:
            return
        self.stopping = True
        log.info("stop requested (%s)", signame)
        self.loop.create_task(self._stop())

    async def _stop(self) -> None:
        t0 = time.monotonic()
        self.gw.stop_accepting()
        devices = list(self.gw.table.devices.values())
        uids = [d.uid for d in devices]
        # (1) close the sockets FIRST: what was read until now is published and counted; nothing more arrives (C1B-8)
        self.gw.stopping = True
        for proto in list(self.gw.conns.values()):
            proto.close("stop")
        await asyncio.sleep(0)
        rows = 0
        try:
            rows = await self.gw.db_call(self.db.set_disconnected, uids, 1000, timeout=1.2)
        except Exception as e:
            log.warning("stop: presence rows skipped (%s)", e)
        from . import cot
        for d in devices:
            if d.channel is not None:
                d.channel.unbind_placed_and_close()
            if d.cache is not None and d.row_ok:
                d.cache.hold = False
                self.broker.publish_cot(d.cache, d.uid, cot.PRESENCE_TYPE,
                                        cot.uplink_body(d.uid, cot.presence_offline(d.uid, d.last_type), d.user_id))
            d.ended = True
        self.broker.flush_all()
        # wait for confirms <= 1.5 s
        deadline = t0 + 1.5
        while time.monotonic() < deadline and self.broker.inflight_total() + self.broker.cached_total() > 0:
            await asyncio.sleep(0.05)
        unconfirmed = self.broker.inflight_total() + self.broker.cached_total()
        confirmed = self.broker.stats.get("confirmed", 0)
        # wait for cot_parser to drain the queue <= t0 + 4.0
        left = None
        while time.monotonic() < t0 + 4.0:
            fut = self.loop.create_future()
            self.broker.cot_parser_ready(lambda n: (not fut.done()) and fut.set_result(n))
            try:
                left = await asyncio.wait_for(fut, 0.5)
            except asyncio.TimeoutError:
                left = None
            if left == 0 or left is None:
                break
            await asyncio.sleep(0.1)
        self.stop_line = f"stop: {len(devices)} devices, {rows} rows, {confirmed} bodies confirmed, {unconfirmed} unconfirmed, {left if left is not None else '?'} left in cot_parser queue, {time.monotonic() - t0:.2f} s"
        log.info(self.stop_line)
        self._snapshot(time.monotonic())
        self.broker.close()
        logging.shutdown()
        os._exit(0)

    # -- run ------------------------------------------------------------------------------------
    def run(self) -> int:
        for sig in (signal.SIGINT, signal.SIGTERM):
            self.loop.add_signal_handler(sig, self.request_stop, sig.name)
        self.loop.run_until_complete(self.start())
        self.loop.run_forever()
        return self.exit_code


def check_ots_version(pin: str) -> None:
    """§4 OTA stage 2: the pyz runs only on the OTS version it was validated against (C1B-9)."""
    if not pin:
        return
    try:
        from importlib.metadata import version
        have = version("opentakserver")
    except Exception as e:
        log.error("exit 2: cannot read the installed opentakserver version: %s", e)
        os._exit(2)
    if have != pin:
        log.error("exit 2: installed opentakserver %s != pinned %s (this gateway was validated against %s)", have, pin, pin)
        os._exit(2)
    log.info("opentakserver %s == pin", have)


def setup_logging(path: str) -> None:
    fmt = logging.Formatter("[%(asctime)s] - eud_gateway - %(name)s - %(levelname)s - %(message)s")
    root = logging.getLogger()
    root.setLevel(logging.INFO)
    h = logging.StreamHandler(sys.stdout); h.setFormatter(fmt); root.addHandler(h)
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        fh = logging.handlers.TimedRotatingFileHandler(path, when="midnight", backupCount=7)
        fh.setFormatter(fmt); root.addHandler(fh)
    except OSError as e:
        root.warning("file log %s unavailable (%s): stdout only", path, e)
    logging.getLogger("pika").setLevel(logging.WARNING)


def main(argv: list[str] | None = None) -> int:
    try:
        settings = config.load()
    except config.ConfigError as e:
        print(f"exit 2: malformed configuration: {e}", file=sys.stderr)
        return 2
    setup_logging(settings.log_path)
    try:
        ots = otsconfig.load(os.path.join(settings.ots_dir, "config.yml"))
    except Exception as e:
        log.error("exit 2: cannot read %s/config.yml: %s", settings.ots_dir, e)
        return 2
    if not ots.db_uri:
        log.error("exit 2: no SQLALCHEMY_DATABASE_URI")
        return 2
    app = App(settings, ots)
    return app.run()
