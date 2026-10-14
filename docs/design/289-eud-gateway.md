# #289 OTS EUD gateway — design v3

Status: v3 for whole re-review (round 3, authorised by the user 2026-10-14 beyond the two-round budget) · v1
(38e949d): A REJECT / B APPROVE-WITH-CHANGES; v2 (0709ff9): A2 REJECT (5 MAJOR) / B2 APPROVE-WITH-CHANGES (7 MAJOR);
every finding and its disposition is in §10. Parent #75. Facts, measurements and leftovers it builds on: #289 body
and comments; `264-ots-eud-patch.md` and `264-review-register.md`.

Review rules: `docs/design/REVIEW.md` plus the user's global rules. **Design freeze (the #264 lesson, in force from
this version):** the mechanism list is M1–M18 below. After the whole-design re-review reaches zero BLOCKER/MAJOR,
a finding in code review is fixed only if it is class A (field harm from the symptom this component exists to
stop: lost CoT, deaf or ghost sessions, the server down); anything else is recorded as a leftover and put to the
user. Review budget: at most two design rounds and two code-review rounds; if either is exceeded, work stops and
the user decides.

## User decisions this design honours

| # | decision | source |
|---|---|---|
| 1 | Data Sync / missions ARE needed → OTS stays; goatak rejected (#289 comment 2026-10-14: a burst loses 57 % and the record with it) | 2026-10-14 |
| 2 | Members use **8089 (client cert) only**; **8088 only for an allowlist of relay uids, default off** (implements #48's "disable plaintext CoT") | 2026-10-13 |
| 3 | **No per-address limit**; admission by device count and memory, sized to use the Pi 4's 8 GB | 2026-10-14 |
| 4 | A superseded connection keeps reading its uplink for the outage's length + 20 s, at most 120 s | 2026-10-14 (= #264 decision 6) |
| 5 | Relays stay in scope but are **not tied to the TAK path now**; taken up with Meshtastic | 2026-10-14 |
| 6 | **No dedup**; at-least-once, small numbers of duplicates accepted | 2026-10-14 |
| #264-1 | a device refused for a colliding callsign is still RECORDED (own row, own `<uid>` queue) | 2026-10-12 |
| #264-2 | CoT lost while the mesh path is down are lost; re-sending is the client's job | 2026-10-12 |
| #264-3 | accepted residuals A4-4, A4-6, A4-9 (#47), A4-10, B4-7 | 2026-10-12 |
| #264-5 | the same device's new connection takes the downlink at once; the previous keeps reading | 2026-10-12 |
| P1–P4 | presence owned by the gateway; bindings re-asserted; FK RESTRICT + conform check; 8088 allowlist | 2026-10-13 |

Decisions taken by the author in v2/v3 (for the user to overrule): stop tiers gateway 1 / cot_parser + opentakserver
2 (M13); RESTRICT also on `points` and `geochat` (M10); the retention jobs stay paused, the gateway watches
`apscheduler_jobs` and reports a resumed job (M10); a cert whose CN is not an active user is refused; `ca.crl` is
honoured only while it is valid by the node clock (M14); an oversize message is discarded, not the session (M1);
per-session uplink and per-user new-device rate bounds (M2); **v3: an 8089 cert holder claiming a uid owned by
ANOTHER user is refused outright (closed, logged) — a change from #264's "recorded, no subscription" (B2-6): on
8089-only, no member has a legitimate reason to claim another member's device, and the re-issued phone is the
accepted admin reassignment (B4-7)**; all suites move to 8089 (§7); #54/#219 is a hard deployment dependency, and
**one OTS user per member** is a #54 requirement the per-user caps rely on (§8).

Field scenario (the user, 2026-10-12; `project_ots_field_context`): off-grid tactical team, one node per member,
the phone joins its own node (Wi-Fi/BLE) and runs ATAK/iTAK; all nodes move; the OTS node is carried by the RTO,
so the whole team's sessions go stale at once and reconnect together (16 zombies + 16 reconnects, possibly twice
within 2 min); Meshtastic is the fallback when HaLow is jammed; batteries are swapped (power loss); OTA only in
maintenance; **the after-action review must restore every record**; OTS runs only on Pi 4 8 GB (04: MemTotal 7.6
GiB, MemAvailable 6.6 GiB). Capacity target: 16 phones. The node has no RTC: its clock is 2025-07 while rows carry
2026-10 timestamps from the phones (04, probed): **nothing in this design compares a row timestamp with the node
clock.**

Not captured from real devices (⚠️ assumptions, the deferred field test): SA within seconds of connect (A1),
background behaviour (A4), a new session per flap (A7), roaming (A8), the phones' addresses (D4). Each mechanism
that depends on one is bounded whatever the outcome (deadline, supersede, reap, caps).

## 0. What exists and what changes

Today (04, 1.5.10-wsl.1): six containers on `br-ots`: `ots-db` (postgis 18-3.6), `rabbitmq` (4.3.6, definitions
file with policy `batman-264-eud-queues`), `opentakserver` (Flask API 8081; **declares every exchange** — dms,
cot_parser, chatrooms, missions, groups, firehose, flask-socketio — `app.py:163-172`), `ots_cot_parser`,
`ots_eud_handler` (8088, 1280m) and `ots_eud_handler_ssl` (8089, 1536m), both under the 2205-line overlay
(bind-mounted ro, `MOUNTSHA`-pinned). fw4 DNATs 8088 → 172.20.0.10, 8089 → 172.20.0.12. `cot` 1060 rows, `euds` 27;
`cot_eud` and 13 other FKs to `euds` are `ON DELETE CASCADE`; `EUD.cots` has ORM `cascade="all, delete-orphan"`
(`models/EUD.py:35-49`). There is **no EUD delete route** in 1.7.13 (`/api/eud` GET only). The deleters of the record
are two scheduled jobs: `delete_old_data` (interval 1 min: `delete(EUD) where last_event_time <= now − 1 week`, then
points, then cot) and `purge_data` (daily: every table), both **paused** on 04 (`config.yml` `next_run_time: null`;
0 "Deleted data older" log lines in 9 h) and resumable through `scheduler_api.py` (reviewers A/B, 2026-10-14).

The upstream contract the gateway keeps (measured on 04, `cot_parser.py` 1.7.13):
- **Uplink:** JSON `{"uid": <device uid or null>, "cot": "<event …/>", "user_id": <int or null>}` to the durable
  direct exchange `cot_parser`, routing key `cot_parser`, `expiration` = `OTS_RABBITMQ_TTL` (86400000); a copy
  `{"uid","cot"}` to the fanout `firehose`. cot_parser consumes queue `cot_parser` (transient, default args,
  prefetch 2), `insert_cot` (FK: no `euds` row = `basic_nack(requeue=False)`, gone; KeyError on a missing
  `how/type/start/stale/time/uid` attribute = the same nack), parses, `route_cot` (DMs by `<dest callsign|uid>`,
  missions, groups), and on a `t-x-d-d` event sets the row `Disconnected` with `last_event_time` = the event's
  `start` and emits it to the web (`cot_parser.py:1253-1275`). It also inserts a `cot` row for that event.
- **Disconnect message** `{"uid","cot":null,"disconnected":true,"user_id"}` → `send_disconnect_cot` (`:940-1033`):
  raises on 8088 (A6-5); on 8089 publishes `t-x-d-d`, **binds** the departed `<uid>` queue to its groups and unbinds
  it from every mission (`:1012-1023`, the A7-11 mechanism). **The gateway never sends this message.**
- **Downlink:** per-EUD transient queues `<uid>` / `<callsign>` bound to `dms`, `groups` (`__ANON__.OUT` or
  `<group>.OUT`), `missions` (`missions`; `missions.<name>` placed by `mission_marti_api.py:1497-1507` with a
  `mission_roles` row and removed by `:1538-1558`, which deletes the row BEFORE unbinding); `group_marti_api.py:323-342`
  unbinds BEFORE its commit (a reconcile may see the old DB state for that window). `chatrooms` is declared but
  nothing binds EUD queues to it.
- **Web map:** `{"data": eud.to_json(), …}` to the fanout `flask-socketio` at identification (`EudHandler.py:290-305`);
  `to_json()` needs a Flask app context.
- **Identity on 8089:** cert CN → `find_user` with **no None/active check** (`EudHandlerSSL.py:14-30`); context
  `CERT_REQUIRED`, CA `/app/ots/ca/ca.pem`, server cert/key `/app/ots/ca/certs/opentakserver/`; `ca.crl` is a static
  638 B file written at CA creation, never updated (no revoke path in 1.7.13; `crl_index.txt` empty).
- **Orchestrator (payload-run, payload-stop, the guardian; verified 2026-10-14):** `MOUNT` must be a plain file name
  in the tenant dir and a regular file (`payload-run:340-358`); keys: ENV/VOLUME/MOUNT/MOUNTSHA/ENTRYPOINT/HARDEN/
  HEALTH/STOPTIER/SECRET; **no `init_once` key** (`profile.yaml` `init_once:` is a comment list); `HEALTH` runs
  only in the start gate (`health_gate`, 60 × 2 s), never afterwards; **start order: phase A starts the final tier
  (db, broker) and gates it; phase B `docker start`s every other container AT ONCE and gates afterwards**
  (`payload-run:476-517`) — so the gateway runs concurrently with opentakserver's first run, which creates the
  schema (alembic) and the CA/server certs; the guardian restarts EXITED containers every 60 s **with no give-up**
  (`payload-guardian-run.sh:66-80`); stop = `payload-stop.sh`: tiers ascending, each tier in parallel with `docker
  stop -t 5`, the final tier `-t 10`, K08's budget 15 s; `StopSignal` SIGINT; `STOPTIER` 1..98. **There is no
  node-side `payload-conform`**: `chk_conform` is a harness suite (`daily-validation.sh:337-385`); the guardian's
  verdict checks labels/mounts/restarts only. The OTS scheduler persists job state in the `apscheduler_jobs` table
  (SQLJobStore; the persisted row wins over `config.yml` on every restart — `sql_jobstore.py`), so "paused" is a DB
  fact, not a config fact. `firehose` has no bound queue on 04 (a `mandatory` publish to it is always returned).

After this change: `ots_eud_handler`, `ots_eud_handler_ssl`, the overlay, its generator and `MOUNTSHA` are gone; one
container **`ots_eud_gateway`** (172.20.0.10, 8088 + 8089, image `batman/ots`, entrypoint our zipapp) replaces them.
`ots-db`, `rabbitmq`, `opentakserver`, `ots_cot_parser` are unchanged except their stop tiers and one FK migration the
gateway applies at start (M10).

Scope: `deploy/ots/gateway/` (package + offline tests; built into one file `eud-gateway.pyz` by the Makefile),
`deploy/ots/profile.yaml` + generated files, the harness `conform` suite (FK + scheduler legs), the ported suites + new
suites, docs. Out of scope: UDP; the OTS web/API; relay semantics (decision 5); #47; the enrolment tool (#54 —
a hard dependency for deployment, §8); retention/archiving policy (the jobs stay paused).

## 1. Architecture

One process, `python3 /app/eud-gateway.pyz` inside `batman/ots:1.7.13-arm64` (Python 3.13.15, pika 1.3.2 with
`AsyncioConnection`, SQLAlchemy 2.0.44 + the OTS models, bs4 4.14.2 / lxml 6.0.2 — probed; no new image, no new
dependency). The OTS models are not importable standalone (`FsModels.db` is None, mapper configuration needs
every model imported): the gateway bootstraps exactly as `cot_parser.py:1336-1360` does (`create_app()` on
`/app/ots/config.yml`, which is therefore the source of the broker credentials, TTL, DB URI). `asyncio`
throughout; blocking DB calls run in a `ThreadPoolExecutor(4)` set as the loop's default executor, and anything a
worker thread must send on the AMQP channel is hopped to the loop with `call_soon_threadsafe`.

**Start sequence (A2-1, B2-8):** connect to the DB → wait until the schema exists (`alembic_version` present and the
tables `euds`, `cot`, `points`, `geochat`) and the TLS files exist and parse — polling every 5 s with a log line, for
ever (opentakserver's first run creates both; the guardian would otherwise crash-loop the gateway every 60 s with
no give-up) → M10 migration → M8 sweep → AMQP connect, declare → bind listeners → `/healthz` 200. `exit 2` is only
for a malformed config value (M16); a missing or late dependency is waited for, never exited on.

```
 phones ──8089 mTLS──┐                                ┌─► cot_parser exchange ──► ots_cot_parser ──► postgres
 relays ──8088 (off)─┤  Listeners → Pending cap → Framing → Identity/Admission → Session table (by DEVICE)
                     │                                       │
                     │                                       ▼
                     │  Uplink: parse → store-before-route → Publisher (one connection, confirms, per-session cache)
                     │                                       │
                     └◄── Downlink: one consumer + channel per device → bounded send queue → current socket
                           Presence (owner) · Bindings (reconciled) · Snapshot/metrics/log · Health/watchdog
```

| component | does | absorbs |
|---|---|---|
| **Listener** (×2) | `asyncio.start_server`; 8089 with an `SSLContext` (CERT_REQUIRED, CA, server cert, CRL when it parses) and a 10 s handshake timeout; 8088 bound only when the allowlist is non-empty | R12 |
| **Pending cap** | `MAX_PENDING` (128) not-yet-identified connections in total; beyond it the accept loop closes the socket at once (one log line per minute); the cgroup memory reserve is also checked at accept (µs) | R12's per-address rule (replaced, decision 3) — A1-4/B1-5 |
| **Framing** | bytes → complete `<event>…</event>` / `<auth>`; a message over `MAX_EVENT_BYTES` (64 KiB) or a carry-over over it closes the connection (logged); bs4 parse once; a message with a DOCTYPE is malformed (lxml yields no event: probed) | R1 — B1-7 |
| **Identity / Admission** | 8089: user = cert CN, must exist and be `active`, else closed before anything; uid/callsign from the first SA; ownership rule; 8088: uid on the allowlist or closed. Under the admission lock at identification: `MAX_DEVICES`, `MAX_DEVICES_PER_USER`, `MAX_CONNS_PER_DEVICE`, memory reserve | R7, R10, R12, R16, P4 — A1-5/B1-6/B1-10 |
| **Session table** | key = device: 8089 `(user_id, uid)`, 8088 `(address, uid)`; a session owns its AMQP channel + consumer, cache, placed bindings, snapshot row and the list of connections (current + ≤ 2 draining) | R17 by construction, R6 |
| **Uplink** | identify if needed → store-before-route → publish `{uid,cot,user_id}` to `cot_parser` and `firehose` | R14, R5, R4/R4b |
| **Publisher** | ONE AMQP connection for the gateway; one publishing channel (`confirm_delivery`, `mandatory`); on every connection open: declare EVERY exchange it uses with `app.py:163-172`'s exact arguments and `cot_parser` queue/binding with cot_parser's; per-session bounded cache; head-only retry on a return; reconnect with backoff; blocked callback → cache | R4, R4b, R5, R9, R13 — B1-9 |
| **Downlink** | per device: its own channel, `queue_declare(uid)` (+callsign when usable and free), bindings reconciled, `basic_consume` with `prefetch 50`, manual ack after the message is appended to the session's send queue; writer drains to the CURRENT socket with `set_write_buffer_limits(high=256 KiB, low=64 KiB)` and **no drain timeout** (a dead peer ends by `TCP_USER_TIMEOUT`); a channel exception affects that device only | R2 closed, R6 residual gone — A1-6/B1-8/B1-14 |
| **Presence** | owner of `last_status`/`last_event_time` for its devices (gateway clock); `Connected` at identification and re-asserted on the 30 s cycle; `Disconnected` + a `t-x-d-d` CoT at the device's last end; clock-free sweep at start | P1 — A1-8/B1-4/B1-12 |
| **Bindings** | reconciled: at identification, on the first SA after a (re)connect, every 30 s: bind `needed − placed`, unbind `placed − needed` (gateway-placed only); `needed` computed from the DB | P2 — A1-10/B1-15 |
| **Snapshot** | `/tmp/gateway/sessions.json` every 10 s (atomic rename) with counters and a monotonic `uptime_s` (no wall clock) | R17 registry (no files/signals/pids) — B1-18 |
| **Health / watchdog** | `GET /healthz` bound on `0.0.0.0:8090` inside the container netns (reachable as `localhost` for the start gate and as 172.20.0.10 on br-ots); 200 when both configured listeners are bound and AMQP is open; **the process exits 3** when AMQP has been down for `AMQP_MAX_DOWN_S` (300 s) or the loop is wedged (a 1 s heartbeat task not run for 30 s, checked by a thread) → the guardian's crash path | — A1-9/B1-13 |
| **Stop** | SIGINT and SIGTERM: ≤ 3 s plan (M13) | #274 — A1-3/B1-1 |

### 1.1 Mechanisms

**M1 Framing and uplink rate (A2-5, B2-4).** As R1: raw bytes until a closing tag; decode complete messages
only. A message over `MAX_EVENT_BYTES` (64 KiB) is **discarded to its closing tag and counted** (log `oversize
message from <uid|ip>: N bytes, discarded`); the session goes on (the "real CoT < 10 KiB" premise is uncaptured, so
closing could loop a legitimate app). The carry-over without a closing tag is bounded by `MAX_CARRY_BYTES` 1 MiB:
over it the connection is closed. Parsing is CPU on the single loop (probed: 77 KiB → 0.33 s; 1 MiB → 5.8 s / 88
MiB), so every session has an **uplink token bucket**: `UPLINK_BYTES_PER_S` 32 KiB (burst 256 KiB) and
`UPLINK_MSGS_PER_S` 20 (burst 100); when exhausted the connection's `transport.pause_reading()` until the bucket
refills (back-pressure, no close, counted). A real phone (SA every 2–5 s, chat, occasional 10 KiB) never touches it.
A malformed message (including one with a DOCTYPE) is dropped and logged; the session goes on (R14).

**M2 Admission (decision 3; A2-3, B2-3, B2-5, B2-11).**
1. Accept: the memory reserve (M12) holds, else close at once. The pending pool (not-yet-identified connections)
   is bounded by `MAX_PENDING` (1024, revised from rc 1's per-pending measurement): on overflow the **oldest
   pending connection is evicted** (closed), never the newcomer — a real phone's connection is pending for ~100 ms
   (handshake + first SA) and is therefore younger than any flood socket. Residual, stated with numbers: a certless
   flooder must sustain > `MAX_PENDING` / 10 s ≈ 100 new TLS connections per second to keep evicting faster than a
   phone identifies; at that rate the mesh link (HaLow, ~4 Mbit/s) is saturated anyway. Put to the user as the
   accepted residual of decision 3 (no per-address rule).
2. 8089: TLS handshake ≤ 10 s; the cert chain verified against `ca.pem` and the CRL when valid (M14); the CN must
   be an existing, `active` user. Not found or inactive → close, log `refusing cert CN=<cn>: <reason>` (rate-limited
   per CN). A DB error during the lookup → close too (the phone retries), logged as `db error`, not counted as a
   refusal (B2-11). This is the stack's revocation path (a captured phone: the operator deactivates the user).
3. 8088: bound only with a non-empty allowlist; the first identifying message's uid must be on it, else close.
4. Until identified: an **absolute** lifetime `IDENT_HARD_S` 120 s that nothing extends (pings included) plus the
   rolling `IDENT_MAX_S` 60 s between complete messages; after the handshake, at most `MAX_PENDING_PER_USER` (12)
   unidentified connections per user (the 13th closes the oldest of that user's). So a cert holder's ping-only
   sockets cannot hold the pool.
5. At identification, under the admission lock (asyncio; held across the checks and the table insert):
   `MAX_DEVICES` (64) total; `MAX_DEVICES_PER_USER` (4) live on 8089; **a per-user new-device token bucket**
   (`NEW_DEVICES_BURST` 4, `NEW_DEVICES_PER_H` 10) charged for every uid the user has not used since the gateway
   started — refused BEFORE any row or queue exists (a cert cycling fresh uids would otherwise create a bound queue
   per uid: ~200 queues ≈ the broker's 512m watermark in minutes); `MAX_CONNS_PER_DEVICE` (3 = current + 2
   draining: a 4th closes the oldest draining — decision #264-2 accepts that loss); the memory reserve. Refused →
   closed with one log line `refusing device <uid> from <ip>: <reason>`; the listener lives.
6. Pings (`t-x-c-t`) and `<auth>` are answered from the connection object; they never allocate a session; they
   move the rolling deadline only.
7. Re-check at every 8088 identification that the uid is not an 8089 user's device (the start-time check alone
   misses a user enrolled later); 8089 wins (B1-17).

**M3 Sessions by device; supersede (decisions 4, #264-5).** A new identified connection of a device already in
the table replaces the current socket: it gets the downlink at once; the old socket stops receiving downlink, is
read until `supersede_time + min(outage + 20 s, 120 s)` (outage = time since its last byte, gateway monotonic
clock), extended 20 s after every byte while a newer connection lives, then closed. A device whose last connection
ends (FIN/RST, `TCP_USER_TIMEOUT`, the M2 deadline, supersede deadline, stop) ends the session: consumer cancelled,
channel closed, gateway-placed bindings removed, presence `Disconnected` + `t-x-d-d`, row kept. 8089 key
`(user_id, uid)`: a phone back through ANOTHER node (new address) supersedes its old connection (A8 ⚠️); 8088
`(address, uid)`.

**M4 Identity and names (R10, P4).** uid and callsign are checked before any broker use (empty, > 255 bytes, `amq.`
prefix, a system name — `cot_parser`, `dms`, `chatrooms`, `missions`, `groups`, `firehose`, `flask-socketio`,
`meshtastic`, `dmrcot` —, non-printable): a bad uid → no subscription, **no row write of any kind**, one log line; a
bad or colliding callsign → not used as a queue, the device recorded under its uid without the callsign column
(UNIQUE; decision #264-1). 8089: a uid whose row has another `user_id` → **the identification is refused: the
connection is closed and logged `refusing device <uid>: owned by user <id>`; nothing is written, published or
subscribed** (B2-6: on 8089-only, planting CoT under a teammate's uid is the P4 threat; the re-issued phone keeps
being refused until the admin reassigns it, B4-7 — a change from #264's "recorded, no subscription", put to the
user in the header). An allowlisted 8088 uid equal to an 8089 user's device uid →
refused at that identification (8089 wins); at start the allowlist is validated for names only (the DB may be late:
a DB error at start is retried, not exit 2 — B1-18).

**M5 Store-before-route (R14, F1).** A device's first publish waits for its `euds` row: metadata written
defensively (phone digits, strings cut to 255, missing `start`/`role` tolerated), else a minimal row (uid, Connected,
user, callsign if free); a DB failure is retried every 30 s on the next CoT while the device's CoT are cached (M6
bounds). Relay hook (`minimal_row(uid)` per forwarded uid) is designed, not implemented (decision 5): an
allowlisted relay's CoT for unknown uids are FK-dropped by cot_parser today (stated).

**M6 Publisher (R4, R4b, R5, R9, R13, B1-9).** One `AsyncioConnection`. On every connection open: `exchange_declare`
for dms (direct), cot_parser (direct, durable), chatrooms, missions (topic), groups (topic), firehose (fanout,
durable), flask-socketio (fanout, non-durable) — **the exact types/durability of `app.py:163-172`** (a fresh broker
volume, or the gateway starting before opentakserver, must not 404 a bind); `queue_declare("cot_parser")` + bind as
cot_parser; `Confirm.Select` on the publishing channel. **`mandatory` only on the `cot_parser` publish** (B2-7:
`firehose` has no bound queue on 04, so a mandatory publish to it is always returned; the overlay too is mandatory
on `cot_parser` only, `EudHandler-264.py:1044-1057`); a firehose body is fire-and-forget (confirmed, never retried
on a return). Every `cot_parser` body held until its ack; nack/return → head of its session's cache; loss → unacked
bodies back in order, reconnect with backoff 1, 2, 4, 8, 16, 30 s ±25 %; order per
session kept; a session's TCP connection is never ended by a broker-side loss (its consumer/channel/bindings are
re-placed from the session's state when the connection is back: `queue_declare`, reconcile, `basic_consume`).
Broker blocked → cache, no timeout. AMQP down for `AMQP_MAX_DOWN_S` (300 s) → exit 3 (M17).

**M7 Downlink (R2, R6, A1-6, B1-8, B1-14).** One channel + one consumer per device (a 404/406 on one device's
channel closes that channel only; it is re-placed on the next reconcile; other devices unaffected). `prefetch 50`,
manual ack after append to the send queue (bounded 1 MiB / 200 msgs; `a-*` coalesced per uid, then drop-oldest +
count). The writer awaits `drain()` with **no timeout**; `set_write_buffer_limits(high=256 KiB, low=64 KiB)` turns
a slow reader into back-pressure that lands in the bounded queue; a dead peer ends by `TCP_USER_TIMEOUT` 120 s
(M11); `SO_SNDBUF` 256 KiB explicit (bounds the kernel's charge to the cgroup, A1-14). A superseded socket gets
nothing. Downlink to a device goes to its current socket only. **If the current connection ends while draining
ones live (the newest ended first, B2-10), the newest draining connection is promoted to current** (it is being
read anyway) so the consumer never acks into a socket nobody drains; a device ends only when its last connection
ends. Two consumers per device when the callsign queue is usable (uid + callsign), on the device's channel.

**M8 Presence (P1, A1-8, A1-11, B1-4, B1-12).**
- At start, **before binding the listeners**: `UPDATE euds SET last_status='Disconnected', last_event_time=:now
  WHERE last_status='Connected'` (the gateway owns zero sessions at start; no clock comparison; log the count; no
  `t-x-d-d` burst — the phones' next SA restores them).
- At identification and on the 30 s cycle: `Connected` + `last_event_time` = the device's last SA `start`
  (the phone's clock, as upstream `EudHandler.py:695` — B2-12: the node clock is 2025, writing it would make the
  web UI's "last seen" jump back 15 months) when the row differs (the re-assert undoes a late `t-x-d-d` written by
  cot_parser from the gateway's own queued event — the race B1-4; residual: one stale `t-x-d-d` to the team until
  the next SA). `Disconnected` writes `max(last SA start, node now)` (upstream's disconnect uses node time too).
- At the device's last end: row `Disconnected`, then a `t-x-d-d` CoT published as a normal uplink message with
  the body `{"uid": <device uid>, "cot": <event>, "user_id"}`; the event exactly as upstream's
  (`cot_parser.py:945-975`): `version="2.0" uid="<uuid4>" type="t-x-d-d" how="h-g-i-g-o" time/start=now
  stale=now+10s`, `<point ce="9999999" le="9999999" hae="0" lat="0" lon="0"/>`, `<detail><link relation="p-p"
  uid="<device uid>" type="<device type>"/></detail>` — every attribute cot_parser's `insert_cot` reads, so it is
  never nacked; cot_parser inserts a `cot` row for it, routes it to the team and sets the row (idempotent).
- Web map: `eud.to_json()` built in the executor thread holding an app context (impl-11), the publish hopped to
  the loop thread (`call_soon_threadsafe`) at identification.

**M9 Bindings (P2, A1-10, A2-11, B1-15, B2-13).** `needed(device)` = `dms`:uid (+callsign when usable), `groups`:
`__ANON__.OUT` or every enabled membership's `<group>.OUT` **with `direction = OUT` only** (upstream
`EudHandler.py:556-562`; the group API can place `<group>.IN` on a uid queue, `group_marti_api.py:331-340`, and
that binding is not the gateway's), `missions`:`missions`, `missions.<name>` for every `mission_roles` row of the
uid. Reconcile = bind `needed − placed`, unbind `placed − needed` (only what the gateway placed), `placed :=
needed`; log `rebind <uid> +N -M` only when N+M > 0. Triggers: identification; the first SA after a (re)connect;
every 30 s per device (16 devices ≈ 0.5 reconciles/s, 2 DB reads each; broker calls only on deltas). **At
identification `placed` is unknown (a crash or restart lost it): the gateway unbinds the full candidate set minus
`needed`** — candidates = every `<group>.OUT` of all groups and `missions.<name>` of all missions (bounded by the
tables' sizes, tens) — so a stale binding from the API race window or from before a crash is removed (⚠️ RabbitMQ's
`queue.unbind` on an absent binding returns unbind-ok per AMQP 0-9-1 since 3.x; probed at implementation; the
per-device channel bounds a 404 to that device). A removal by the admin takes effect within 30 s. Queues are
never deleted (R15 policy expires them after 24 h unused).

**M10 The record (P3, A1-7, A2-2, A2-7, B1-3, B2-2).** The record = `cot` + `points` (track) + `geochat` (chat).
Deleters today: `delete_old_data` (interval 1 min: `delete(EUD) where last_event_time <= now − 1 week`, then
**`geochat`, `points`, `cot` DIRECTLY by timestamp** in the same session, `scheduled_jobs.py:275-395`), `purge_data`
(daily: every table directly), any ORM `session.delete(eud)` (cascades first), a future upstream route. Both jobs
are paused on 04; their state is the `apscheduler_jobs` row (`next_run_time` NULL), which an API resume
(`scheduler_api.py:41-58`) changes for good regardless of `config.yml`.
- **What RESTRICT does and does not do, stated honestly:** the FK change makes an EUD-row delete fail when the
  device has history (the `delete_old_data` transaction then rolls back as a whole, deleting nothing, when at least
  one EUD older than the cutoff has children; with every device seen within a week it raises nothing and the job's
  direct timestamp deletes would run). **RESTRICT is therefore a guard against row-level deletes (ORM cascade, a
  future route, an operator `DELETE FROM euds`), not against the retention jobs. The control against the jobs is
  "they stay paused", and it is enforced by watching the DB, not the config.**
- Migration, owned by **the gateway at every start** (after the schema wait, before the listeners; as role `ots`,
  the table owner; idempotent): per FK, **two transactions** — `ALTER TABLE … DROP CONSTRAINT IF EXISTS <name>, ADD
  CONSTRAINT <name> … ON DELETE RESTRICT NOT VALID` then, separately, `VALIDATE CONSTRAINT` — each under
  `SET lock_timeout = '5s'`, retried with backoff while cot_parser inserts. Names/columns from the catalog
  (probed on 04): `cot_eud (sender_uid)`, `point_eud (device_uid)`, `geochat_eud (sender_uid)`. Log `fk <name>:
  RESTRICT (migrated|already)`.
- **Scheduler watch, owned by the gateway**: at start and every 30 s, `SELECT id FROM apscheduler_jobs WHERE id IN
  ('delete_old_data','purge_data') AND next_run_time IS NOT NULL`; a row → log `RESUMED job <id>` (once per change),
  snapshot counter `jobs_resumed`, `/healthz` body carries it. **No node-side verdict carries it today** (no
  payload-conform on the node; a guardian hook is a #274-scope PR, put to the user in §8); the harness `conform`
  suite (`chk_conform`) and `fk-restrict-289` check the FKs and the job rows; `daily-validation` runs daily (#290).
  Retention = archiving (out of scope).
- Not covered (stated): the other 11 CASCADE FKs to `euds` (not the record's track/chat); an ORM
  `session.delete(eud)` from a future upstream route cascades `cot` through the ORM before RESTRICT fires (no such
  route in 1.7.13; the image pin is the control); `purge_data` if resumed deletes the record directly (watched,
  not prevented).

**M11 Zombies (R6).** `SO_KEEPALIVE` 45/15/4 + `TCP_USER_TIMEOUT` 120 s on every accepted socket.

**M12 Resources (decision 3, A1-14, B1-5).** Container `memory` 1024m (to be revised from rc 1), `pids` 32
(asyncio main + 4 executor + health/watchdog threads + `docker exec` health = ~10), `MAX_PENDING` 1024 (revised
from rc 1's per-pending measurement; worst case 1024 × ~0.3 MiB ≈ 300 MiB is inside the arithmetic below),
`MAX_DEVICES` 64, `MAX_DEVICES_PER_USER` 4, `MAX_CONNS_PER_DEVICE` 3, cache 2 MiB/session, send queue 1 MiB/session,
`SO_SNDBUF`/`SO_RCVBUF` 256 KiB. Worst-case arithmetic: 64 devices × 3 conns × (256 KiB snd + 256 KiB rcv + ~0.2
MiB TLS/buffers) ≈ 140 MiB sockets + 64 × 3 MiB caches/queues ≈ 192 MiB + 1024 pending × 0.3 MiB ≈ 300 MiB + base
(~150 MiB with the OTS models) ≈ **780 MiB < 1024m** before the per-session Python cost (⚠️ measured in rc 1 by
`eud-mem-289` with its D2 leg, and the cap revised). The memory reserve `RESERVE_MB` 64 is read from the cgroup
(`memory.current − memory.stat file` vs `memory.max`) at accept and at identification; unreadable → no cap, logged.
Node budget after: opentakserver 1280 + cot_parser 1280 + gateway 1024 + rabbitmq 512 + ots-db 512 = 4.6 GiB < 6.6
GiB available. No `oom_score_adj`: the caps and bounds above are the defence; a kernel OOM kill of the gateway =
every session, phones reconnect, the guardian restarts it (lifecycle row).

**M13 Stop (A1-3, A1-12, A2-6, B1-1, B2-9).** Signals: SIGINT (the image's StopSignal) and SIGTERM, via
`loop.add_signal_handler` (no KeyboardInterrupt unwinding). Budget: **≤ 4.5 s** inside `docker stop -t 5`, every
step bounded: (1) stop accepting; (2) one `UPDATE euds … Disconnected WHERE uid IN (:live)` with `statement_timeout
1s` (skipped and counted if the DB stalls); (3) publish the `t-x-d-d` events and flush every cache, awaiting
confirms ≤ 1.5 s; (4) wait for cot_parser to drain: poll `queue_declare("cot_parser", passive=True)`'s
`message_count` until 0 or until t = 4 s (cot_parser is a forking parent that SIGINT ends at once when its tier
starts, so the only window in which it consumes the flushed bodies is while the gateway is still alive — B2-9);
(5) close sockets; (6) log `stop: N devices, M bodies confirmed, K unconfirmed, Q left in cot_parser queue`;
`os._exit(0)` (no thread can hold the exit). Stop tiers: **gateway 1; `ots_cot_parser` and `opentakserver` 2**
(two client tiers ≤ 10 s inside K08's 15 s; the final tier `-t 10` in K09 as today). Residual, stated: Q bodies not
consumed when the gateway exits plus cot_parser's prefetch 2 are lost when the broker stops (transient queue), as
today; K unconfirmed are counted and lost.

**M14 TLS (A2-4, B2-1).** `ssl.SSLContext(PROTOCOL_TLS_SERVER)`, `CERT_REQUIRED`, `load_verify_locations(ca.pem)`,
`load_cert_chain(opentakserver.pem, .nopass.key)` as `EudServerSSL.py:19-38`; handshake 10 s; close by the
transport (no `SSLSocket.shutdown` race). **CRL:** `ca.crl` is static (lastUpdate 2025-06-23, `nextUpdate
2027-06-23`, `default_crl_days 730`, no regeneration path in 1.7.13 — probed with openssl); with
`VERIFY_CRL_CHECK_LEAF` an expired CRL fails EVERY handshake (`openssl verify -crl_check -attime 2027-07-01` →
error 12). So the CRL is loaded only when `nextUpdate − now ≥ 30 days` by the node clock (today: 2025 clock →
loaded); otherwise the context runs without it (= today's behaviour), logs `CRL not honoured: <reason>` once and
sets the snapshot counter `crl_ignored` (fail-open on revocation only, stated: the alternative is a server that is
down for everyone). The context is rebuilt when any cert/CRL file's mtime changes and re-evaluated daily (a clock
jump re-evaluates it too). Regenerating the CRL is #54's.

**M15 Relays (decision 5).** The 8088 listener + allowlist are implemented (P4); relay semantics are the M5 hook
only; the allowlist ships empty (8088 not bound).

**M16 Configuration.** Env from the profile, validated at start (a malformed value → exit 2, fail-closed):
`GATEWAY_MAX_DEVICES` 64, `GATEWAY_MAX_DEVICES_PER_USER` 4, `GATEWAY_NEW_DEVICES_BURST` 4,
`GATEWAY_NEW_DEVICES_PER_H` 10, `GATEWAY_MAX_CONNS_PER_DEVICE` 3, `GATEWAY_MAX_PENDING` 1024,
`GATEWAY_MAX_PENDING_PER_USER` 12, `GATEWAY_RESERVE_MB` 64, `GATEWAY_IDENT_MAX_S` 60, `GATEWAY_IDENT_HARD_S` 120,
`GATEWAY_SUPERSEDE_QUIET_S` 20, `GATEWAY_SUPERSEDE_MAX_S` 120, `GATEWAY_MAX_EVENT_BYTES` 65536,
`GATEWAY_MAX_CARRY_BYTES` 1048576, `GATEWAY_UPLINK_BYTES_PER_S` 32768, `GATEWAY_UPLINK_MSGS_PER_S` 20,
`GATEWAY_CACHE_MB` 2, `GATEWAY_SENDQ_MB` 1, `GATEWAY_AMQP_MAX_DOWN_S` 300, `GATEWAY_8088_ALLOWLIST` "" (names
validated at start; DB cross-check at each identification). Secrets: none new.

**M17 Health and watchdog (A1-9, B1-13).** `/healthz` on `0.0.0.0:8090` (container netns; br-ots reachable; GET
only, request ≤ 1 KiB, 2 s timeout, no state change). The start gate's `HEALTH curl -fsS http://localhost:8090/healthz`
passes once both configured listeners are bound and AMQP is open. At runtime nothing polls it: the gateway
**exits 3** when AMQP is down > `AMQP_MAX_DOWN_S` or the loop heartbeat is stale > 30 s (a watchdog thread) → the
guardian restarts an EXITED container with backoff (sessions end, phones reconnect). **Losses at exit 3 / a crash /
a kernel OOM kill, stated (A2-10):** every session's cache and send queue, unsent `t-x-d-d` (the start sweep
covers presence), unread socket data; the guardian restarts for ever (no give-up), so a persistent cause (broker
gone, DB gone) is a 60 s crash loop visible as repeated `exit 3` lines and DRIFT.

**M18 Logging and readers (A1-13).** File `/app/ots/logs/eud_gateway.log` (daily rotation by count as upstream;
⚠️ C6 size on the `ots-appdata` volume measured by #287) + stdout. Lines read by tools (§3). The harness's
`ots_logc`/`rlog` readers move from `eud_handler_tcp.log`@`ots_eud_handler` to this file@`ots_eud_gateway` in the
harness PR that lands first (#290), with known-failures entries bound to this issue for the interval.

## 2. Ownership

| resource | owner (writes) | readers / notes |
|---|---|---|
| `eud-gateway.pyz` (golden, p6 `apps/opentakserver/`) | the build (golden refresh at boot; D7-7 DRIFT on edit) | payload-run (`MOUNT eud-gateway.pyz:/app/eud-gateway.pyz:ro`; its sha is a `fact`) |
| container `ots_eud_gateway` | payload-run (start), payload-stop (stop, tier 1), the guardian (restart of EXITED) | — |
| listeners, accepted sockets, pending count | the gateway process | kernel |
| session table, caches, send queues, admission lock, per-device channels/consumers | the gateway process (single loop) | snapshot (ro) |
| the gateway's AMQP connection | the gateway | broker |
| exchanges (7) | two idempotent declarers with identical args: opentakserver (`app.py`) and the gateway (M6) | cot_parser, plugins |
| `cot_parser` exchange/queue/binding | two idempotent declarers: cot_parser and the gateway | broker |
| per-EUD queues | declared by the gateway at identification/reconnect (and by the Marti API / plugins as upstream); never deleted by the gateway; expired by the broker policy | — |
| bindings of a live device's queues | **the gateway** reconciles what it placed; the Marti API also binds/unbinds `missions.<name>` and `<group>.OUT` on operator actions (second writer, stated): the gateway converges to the DB state within 30 s | cot_parser publishes |
| `euds.last_status`, `last_event_time` | **the gateway** (M8; sweep at start, re-assert on the cycle); cot_parser's `t-x-d-d` branch writes the same value for the gateway's own event (idempotent; a late one is undone by the re-assert) | web UI |
| other `euds` columns | the gateway at identification (defensive, only for an admitted, owned uid); the web UI/API | cot_parser |
| `cot`, `points`, `geochat` rows | cot_parser (insert); the retention jobs if resumed (direct deletes — watched, not prevented) | web/API, the AAR |
| FK definitions (3) | the gateway's start migration (M10) | the harness conform suite |
| `apscheduler_jobs` rows (`delete_old_data`, `purge_data`) | the OTS app (seeded from `config.yml` once) and operators via the scheduler API | the gateway's 30 s watch (ro), the harness |
| broker policy, vhost, user | `rabbitmq-definitions.json` (golden) | broker |
| `GATEWAY_*` env, allowlist, stop tiers | `profile.yaml` (golden) → manifest | the gateway, payload-stop |
| snapshot `/tmp/gateway/sessions.json`, counters | the gateway (atomic rename, 10 s) | suites, operators (ro) |
| `/healthz` | the gateway | the start gate (payload-run) |
| the node clock | the kernel (no RTC; NTP when reachable) | TLS validity (certs 2025-06-23 → 2035-06-21: ✅ today), log timestamps; **not** presence or any row comparison |
| TLS cert/key/CA/CRL files (`ots-appdata`) | OTS cert-gen / the operator (#54) | the gateway (reloaded on mtime change) |

## 3. Contracts

- **Uplink to cot_parser:** body/exchange/routing key/TTL exactly as §0; `mandatory` + confirms; at-least-once; order
  per session, not across a reconnect; stale replays stated. Trust: the broker and its publishers (guest, #47).
- **Presence `t-x-d-d` (M8):** the event and body exactly as stated; writer: the gateway; readers: cot_parser (row +
  route + a `cot` row), the phones. A client's own `t-x-d-d` passes through unchanged (upstream).
- **Downlink bodies:** `{"uid","cot"}` or a raw CoT string (both exist upstream); the `cot` field or the raw body is
  written unchanged; malformed → dropped and counted.
- **Client session:** a connection ends on FIN/RST, `TCP_USER_TIMEOUT`, the M2 deadline/caps, the supersede
  deadline, an oversize message, or stop. A device's session ends when its last connection ends. A broker-side loss
  ends nothing on the client side.
- **Allowlist:** comma-separated uids; empty = 8088 not bound; a name failing M4 → exit 2 at start; an 8089 user's
  device uid → refused at identification (8089 wins). Trust: golden, root-owned.
- **Snapshot:** `{"uptime_s", "written_monotonic", "devices": [{"key","uid","user","port","connections":[{"addr",
  "age_s","superseded_age_s","last_rx_age_s"}],"cache":n,"sendq":n,"bindings":[…]}], "counters": {…}}` — ages, not
  timestamps (the harness clock is ~6.5 h off the node's). Valid when `written_monotonic` is within 30 s of the
  container's `/proc/uptime`; stale/missing/malformed → the suites FAIL.
- **Log lines read by tools** (`/app/ots/logs/eud_gateway.log` in `ots_eud_gateway`; readers: `ots_logc`, `rlog`,
  the suites): `identified <uid> user=<u> port=<p> from <ip>`, `superseded <uid>: new connection from <ip>`, `ended
  <uid> (<reason>)`, `refusing device <uid> from <ip>: <reason>`, `refusing cert CN=<cn>: <reason>`, `refusing
  pending from <ip>: <reason>`, `oversize message from …`, `cache full for <uid>: dropped=N`, `sendq full for <uid>:
  dropped=N`, `AMQP lost: reconnecting in <s>`, `AMQP open`, `rebind <uid> +N -M`, `presence <uid> Disconnected`,
  `presence sweep: N rows`, `fk <name>: RESTRICT (migrated|already)`, `allowlist refused <uid> from <ip>`, `stop: N
  devices, M bodies confirmed, K unconfirmed`, `exit 3: <reason>`. `Failed to parse` kept for `ots_logc`.
- **Health 8090:** as M17; the start gate only.
- **FK + scheduler state:** written by the gateway (migration) and the OTS app/API (`apscheduler_jobs`); read by the
  gateway's 30 s watch (log line, snapshot counter `jobs_resumed`, `/healthz` body) and by the harness `conform`
  and `fk-restrict-289` suites. There is no node-side verdict for them (stated, §8); nothing stops.
- **Manifest (generated, no new key):** `CONTAINER ots_eud_gateway / IMAGE batman/ots:… / IP 172.20.0.10 / HARDEN
  ots_eud_gateway.hardening.env / ENV … / VOLUME ots-appdata:/app/ots / MOUNT eud-gateway.pyz:/app/eud-gateway.pyz:ro
  / ENTRYPOINT python3 /app/eud-gateway.pyz / HEALTH curl -fsS http://localhost:8090/healthz / STOPTIER 1`;
  `ots_cot_parser` and `opentakserver` `STOPTIER 2`. fw4: 8088 and 8089 → 172.20.0.10. Every key exists in the
  shipped payload-run (`:340-384`) — a downgrade of payload-run is not an issue; a downgrade of the manifest is the
  old stack (§4).

## 4. Lifecycle matrix

| path | today (overlay) | after | test |
|---|---|---|---|
| first boot / fresh volumes (no schema, no certs yet) | handlers crash until opentakserver's first run | phase B starts the gateway in parallel with opentakserver: it waits (5 s polls, logged) for the schema and the TLS files, then migration (M10) → sweep (M8) → declare exchanges+queue (M6) → bind listeners → healthz 200; the start gate may take minutes on a first boot (stated) | fresh-volumes-289 (tier B: pgdata + appdata volumes removed, stack rebuilt: the gateway never exits, identifies a phone once opentakserver is up), fk-restrict-289, fresh-broker-289 |
| restored / replaced `ots-pgdata` under an unchanged manifest | — | same wait loop (schema absent → wait, not exit) | fresh-volumes-289 |
| clock jump past the CRL's `nextUpdate` (2027-06-23) | n/a (no CRL) | the daily/clock re-evaluation drops the CRL, logs, counter; handshakes keep working | cert-reload-289 (CRL leg with a synthetic expired CRL file) |
| one cert cycling fresh uids | unbounded rows + queues | new-device bucket (4 burst, 10/h): refused before row/queue | cap-289 cycling leg |
| one cert streaming large CoT at link rate | loop stalls (overlay: per-process) | per-session uplink bucket pauses reading; other phones' ping RTT < 1 s | admission-289 (k) |
| boot / reboot / power loss | children SIGKILLed; caches lost | caches lost (stated); presence sweep at start (clock-free); phones reconnect | unclean-boot-274, presence-289 (sweep leg) |
| clean stop / OTA stage 1 | tier 1 `-t 5`, SIGINT; caches lost | M13 ≤ 3 s: rows, `t-x-d-d`, flush with confirms; cot_parser stopped in tier 2 after; residual stated | cleanstop-274 (asserts stored == sent for a stream running into the stop, minus the stated residual; negative control: today's parallel tier) |
| OTA stage 2 (new image) | MOUNTSHA refusal | the pyz imports the image's OTS models; a changed image breaks at import → exit 2, guardian crash loop (visible: DRIFT from the guardian's restart count, `exit 2` lines); fail-closed; offline test `import` against the pinned image digest in CI | first-ota + the harness conform suite |
| autocommit trial / revert | unchanged | unchanged | fi-s1 |
| downgrade to an image without the gateway | — | the old manifest rebuilds the two handler containers + overlay; RESTRICT FKs stay (cot_parser never deletes; the paused jobs would fail on EUD deletes — stated); stop tiers back to the old manifest's | downgrade (manual, stated) |
| gateway crash / crash loop | one session's child | every session ends; guardian restarts with backoff; sweep at start | crash-274 (ported) |
| gateway exit 3 (AMQP down > 300 s, loop wedged) | n/a | guardian restart; sessions end; phones reconnect | amqp-down-289 (tier B: broker stopped 6 min) |
| broker-side close | sessions END (R13) | sessions kept; reconnect, re-declare, re-place consumers/bindings, flush caches | amqp-close-289 |
| broker restart / fresh broker volume | C window | per-EUD queues gone → re-declared per device on reconnect; exchanges re-declared by the gateway (no 404 even before opentakserver) | broker-restart-289 (tier B), fresh-broker-289 |
| broker memory alarm | cache | same | alarm-289 (by code ⚠️) |
| cot_parser restart | queue persists | same | queue-gone-289 |
| opentakserver restart | — | no dependency (own app context); the web-map publish during its restart is a fanout to nobody (dropped, stated) | by code |
| ots-db down at start / during | — / retried | start: migration retried, listeners unbound meanwhile (fail-closed); during: identification retried, CoT cached ≤ 2 MiB/session, presence writes retried on the cycle | dbdown-289 (tier B) |
| dockerd restart | `--restart no`: the guardian's start path restarts the tenant | same (no change) | test-payload-guardian |
| br-ots / fw4 reload with sessions up | sockets survive a fw4 reload (conntrack kept, verified in #164/#165 design B) | same | by code |
| clock jump (NTP after boot) | — | nothing compares row times to the clock; TLS validity only | by code |
| cert rotation (#54) | restart needed | context reloaded on mtime change; existing sessions keep theirs | cert-reload-289 |
| `ots-appdata` volume full / read-only | log writes fail | logging to stdout continues; TLS files still readable; stated | by code |
| client network loss (no FIN) | ~2 min reap; same device → R17 | M11 reap; back on any address (8089) → M3 supersede | zombie-289, same-uid-end-289 |
| RTO out and back (16 + 16) | serialized admission, 1280/1536m | 16 supersedes, no new devices; memory flat (⚠️ measured) | rto-289, rto-ssl-289 |
| RTO flaps twice within 2 min | third generation may be refused | ≤ 3 connections per device by cap; nothing refused | rto-ssl-289 second flap |
| a phone flapping every second | unbounded | `MAX_CONNS_PER_DEVICE` 3: the oldest draining closed | same-uid-end-289 flap leg |
| one cert holder with many uids | — | `MAX_DEVICES_PER_USER` 4 | cap-289 per-user leg |
| certless flood (pre-TLS sockets) | 8 per address | pending pool 1024, evict-oldest, 120 s hard lifetime, memory reserve at accept: a phone identifies DURING the flood; residual > ~100 conn/s stated (decision 3) | admission-289 (i): a phone identifies while 1000 sockets/30 addresses churn |
| a cert holder's ping-only sockets | 8 per address | `MAX_PENDING_PER_USER` 12 + `IDENT_HARD_S` 120 s not extended by pings | admission-289 (i2) |
| a 1 MiB message | parsed (5.8 s stall) | discarded at 64 KiB, session kept; carry-over > 1 MiB closes | admission-289 (j) |
| retention job resumed through the API (`apscheduler_jobs`) | deletes | the gateway logs `RESUMED job` within 30 s, counter + healthz body; the harness suite FAILs; the record is NOT protected by RESTRICT against the jobs' direct deletes (stated) | fk-restrict-289 (API resume leg, throwaway rows) |
| a cert holder claims another user's device uid | recorded, no subscription (#264) | refused (closed, logged) | owner-8089-289 |
| slow reader at the edge of coverage | TCP_USER_TIMEOUT | back-pressure into the bounded queue; not closed | slowreader-289 |
| two app instances, one uid | newest gets the downlink | same | same-uid-end-289 |
| two devices, one callsign | both by uid | same | callsign-share-289 |
| device goes stale → presence | 8088 ghost (A6-5) | Disconnected + `t-x-d-d` on both ports; reconnect while cot_parser is busy → `Connected` within 30 s | presence-289 |
| admin disables a group / unsubscribes a mission of a live device | — | unbound within 30 s | rebind-289 |
| a late `t-x-d-d` vs a live session's missions | A7-11 | no disconnect message; reconcile ≤ 30 s | rebind-289 |
| a row-level EUD delete (operator SQL, a future route's ORM cascade) | CASCADE: history gone | RESTRICT on cot/points/geochat refuses it (ORM cascade caveat stated in M10) | fk-restrict-289 (psql delete leg on a throwaway uid with children) |
| cert of a deactivated user / revoked in `ca.crl` | admitted | refused before allocation | owner-8089-289 (revocation leg) |
| 8088 client, no allowlist | admitted | no listener | allowlist-289 |
| mesh outage > 2 min | reap; loss (decision #264-2) | same | zombie-289 |
| N devices > caps / memory | R7 | refused, logged; listener alive | cap-289 |
| 48 h soak | — | #287 on the gateway build | soak-cot-289 + #287 |
| Pi 3 (bcm2710) | bcm2711 only | unchanged | ab-card |

## 5. Assumptions with evidence

| assumption | evidence |
|---|---|
| pika 1.3.2 `AsyncioConnection`, `confirm_delivery`, return/blocked callbacks, `basic_qos`; SQLAlchemy 2.0.44; bs4 4.14.2; lxml 6.0.2; curl; cgroup v2 readable as uid 1000 | probed in the image 2026-10-14 (author, reviewers A/B; `asyncio_connection.py:143,150`, `channel.py:555,170`, `connection.py:1163`) |
| cot_parser body/exchange/TTL; `t-x-d-d` branch; nack on KeyError; FK nack | `cot_parser.py:101-130, 940-1033, 1142-1290` on 04 |
| exchanges declared only by opentakserver, their types/durability | `app.py:163-172` (reviewer B); definitions file has no `exchanges` |
| `send_disconnect_cot` raises on 8088, binds groups and unbinds all missions on 8089 | `cot_parser.py:945-1023` |
| `MOUNT` must be a regular file in the tenant dir; keys; HEALTH at start only; `STOPTIER` 1..98 | `payload-run:217-253, 340-384`; `profile-to-manifest.py:181-186` |
| start mode: phase A final tier gated, phase B everything else started at once, gated afterwards; guardian restarts every 60 s with no give-up | `payload-run:476-517`; `payload-guardian-run.sh:66-80` (reviewer A2) |
| no node-side payload-conform; `chk_conform` is a harness suite | `grep -rln conform feed/ scripts/ deploy/` → `daily-validation.sh:337-385` only (A2) |
| scheduler state persisted in `apscheduler_jobs` (SQLJobStore), persisted row wins over `config.yml` | `sql_jobstore.py` (ConflictingIdError swallowed), `scheduler_api.py:41-58` (B2) |
| `delete_old_data` deletes geochat/points/cot directly by timestamp; `purge_data` every table | `scheduled_jobs.py:169-193, 275-395` (A2/B2) |
| `ca.crl` nextUpdate 2027-06-23, static; expired CRL fails every handshake under `VERIFY_CRL_CHECK_LEAF` | `openssl crl -noout -nextupdate`; `openssl verify -crl_check -attime 2027-07-01` → error 12 (A2/B2) |
| `firehose` has no bound queue; the overlay is `mandatory` on `cot_parser` only | `rabbitmqctl list_bindings` on 04; `EudHandler-264.py:1044-1057, 1836-1839` (B2) |
| parse cost: 77 KiB → 0.33 s | probed in the image (B2) |
| FK names/columns: `cot_eud(sender_uid)`, `point_eud(device_uid)`, `geochat_eud(sender_uid)`; owner `ots`, superuser; PG 18.1 | psql catalog (A2/B2) |
| OTS models need the `create_app()` bootstrap (`FsModels.db` None standalone) | captured tracebacks (A2); `cot_parser.py:1336-1360` |
| upstream binds `<group>.OUT` only; the group API can bind `.IN` | `EudHandler.py:556-562`; `group_marti_api.py:331-340` (A2) |
| `parse_point` returns None for lat/lon 0,0: a `t-x-d-d` makes one `cot` row and no point | probed (B2) |
| `cot_parser` is a forking parent ended by SIGINT at once | `cot_parser.py:1371-1392` (B2) |
| 04 has one OTS user (`administrator`); euds user_id 1: 3 rows, NULL: 24 | psql (A2) → "one user per member" is a #54 requirement |
| stop: tiers ascending, each parallel `-t 5`, final `-t 10`, K08 15 s; StopSignal SIGINT | `payload-stop.sh:4-11, 62-92`; `docker inspect` (reviewers) |
| no `init_once` mechanism | `grep init_once payload-run profile-to-manifest.py` → none |
| no EUD delete route; retention jobs, their SQL, paused state, resumable | `api.py:497`, `scheduled_jobs.py:169-193, 275-298, 375-395`, `config.yml:30-47`, `scheduler_api.py:41-58` (reviewers) |
| 14 FKs to `euds`, 13 CASCADE; ORM cascade on `EUD.cots` | psql `\d euds`; `models/EUD.py:35-49` |
| CN → `find_user` without None/active check; `ca.crl` static | `EudHandlerSSL.py:14-30`; `certificate_authority.py:92-111`; `ls -l ca.crl` |
| mission subscriptions in `mission_roles`; unsubscribe deletes then unbinds; group API unbinds before commit | `mission_marti_api.py:1345-1360, 1497-1558`; `group_marti_api.py:323-342` |
| a 1 MiB event: 5.84 s / 88 MiB in bs4 | reviewer B, probed in `ots_cot_parser` |
| lxml does not expand a DOCTYPE entity bomb (no event found) | author, probed |
| node clock 2025-07 vs rows 2026-10 | `date`, `max(last_event_time)` on 04 |
| `ulimit -n` 1048576, `tcp_wmem` max 4 MiB charged to the cgroup | reviewer B; #264 R16 |
| identical re-declare accepted; mandatory return-then-ack | #264 probe 2026-10-11 (not repeated) |
| `points.device_uid`/`geochat.sender_uid` column names | ⚠️ `\d` at implementation (the migration is written from the catalog, not from memory) |
| asyncio per-session / per-pending memory | ⚠️ rc 1 (`eud-mem-289`), the cap revised from it |
| `set_write_buffer_limits` back-pressure on a 100 kbit/s link | ⚠️ `slowreader-289` is the measurement |
| ATAK/iTAK behaviour (A1, A4, A7, A8, D4) | ⚠️ not captured; bounded either way |

## 6. Security

- **Assets:** confidentiality of 8089 users' DMs/missions/groups; integrity and completeness of the record;
  availability of the TAK server to the team. The node is unchanged (ports, zone, DNAT target).
- **Actors:**
  - *Remote mesh client without a cert:* 8088 not bound (decision 2). Pre-TLS sockets on 8089: pending pool 1024
    with evict-oldest, 10 s handshake, 120 s hard lifetime, memory reserve at accept → a real phone identifies
    during a flood (admission-289 i); residual: a sustained > ~100 new TLS connections/s (a saturated HaLow link)
    can still starve admission — the accepted cost of decision 3, stated. With an allowlist, an allowlisted uid can
    be spoofed from the mesh (plain TCP) — the relay path's problem (decision 5).
  - *Hostile or captured member's phone (valid cert):* bounded by `MAX_PENDING_PER_USER` 12, `MAX_DEVICES_PER_USER`
    4, the new-device bucket (4 / 10 per h), `MAX_CONNS_PER_DEVICE` 3, 64 KiB messages, the per-session uplink
    bucket (CPU), per-session cache/queue, the memory reserve; **cannot identify as another user's device at all
    (refused, M4)**, cannot consume another user's queues, cannot delete history (M10), cannot forge presence for
    others (no disconnect message; a client-sent `t-x-d-d` naming another uid passes through as upstream — stated,
    B class), can send CoT under a uid of ITS OWN user (upstream, stated). The per-user bounds assume one OTS user
    per member (#54 requirement; on 04 today every device is `administrator`'s or unowned). **Revocation:** the
    operator deactivates the user (M2.2) or regenerates `ca.crl` (#54; honoured while valid, M14); the next
    connection is refused (owner-8089-289 revocation leg); the live session ends at its next reconnect only (stated:
    no active kill on deactivation — leftover).
  - *Local unprivileged process:* no interface (container tmpfs, root-owned golden, br-ots).
  - *Compromised tenant container:* reaches 172.20.0.10 ports only on br-ots; 8090 is GET-only, ≤ 1 KiB, 2 s;
    the broker credential is guest as today (#47).
  - *Physical capture of the node:* unchanged (#47). *Of a phone:* see revocation.
  - *Supply chain:* our zipapp in the pinned image; no upstream file overlaid; CI imports the pyz against the pinned
    digest.
  - *Our own mistakes:* fail-closed config; DRIFT on FK/scheduler/golden; one owner per resource; negative controls
    on the overlay build; the design freeze.
- **Attack-surface delta:** removed: fork per connection, the admission file lock, the R17 registry/signals, the
  fault-injection file, MOUNTSHA; added: `/healthz` (GET, bounded), `GATEWAY_*` env, the allowlist, the snapshot
  (gateway-only writer), the start migration (as `ots`, idempotent DDL).
- **Privilege:** uid 1000:1024, cap-drop ALL, no-new-privileges, ro rootfs, ports > 1024; DDL as the DB owner role
  the app already uses.
- **Secrets:** unchanged; never logged.
- **Failure mode:** fail-secure: bad config → exit 2; DB away at start → listeners stay unbound; unreadable cgroup →
  memory cap only is dropped (logged); allowlist empty → 8088 closed.

## 7. Tests

Harness changes land first in their own PR (#290); every new/changed suite carries "old build FAIL + rc PASS" in its
commit; every rc gets ≥ 1 full `daily-validation`; the shipping candidate = last harness commit + last rc. All
suites drive **8089** with the harness's 1-day test cert (`cert264`-style issuance of a non-admin test user), except
`allowlist-289`, which sets a one-run allowlist through the profile override path and is the only 8088 user.

| suite | what | negative control (shipped overlay 1.5.10-wsl.1 unless noted) |
|---|---|---|
| ots-cot-e2e-289 | sent == stored over a coalesced stream (8089) | overlay PASS (regression guard; upstream 0/20 by record) |
| admission-289 | a–h as #264 on 8089; (i) 1000 pre-TLS sockets from 30 addresses churning for 60 s: a phone identifies and stores 10/10 DURING the flood, process alive; (i2) one cert, 40 ping-only sockets: ≤ 12 open, all gone by 120 s, a phone of another user identifies; (j) 10 × 1 MiB from one client: discarded, session kept, another client's ping RTT < 1 s; (k) one cert streaming 64 KiB events at 8/s for 30 s: reading paused (counter), another client's ping RTT < 1 s | (i) overlay: by code (address rule); (i2) overlay: 8 per address, by code; (j) overlay: 5.8 s stall → FAIL; (k) overlay: separate processes, by code |
| zombie-289, same-uid-end-289 (+ flap leg: 10 connects/10 s → ≤ 3 sockets, survivors' reports stored), callsign-share-289, name-guard-289, exception-289, queue-gone-289, amqp-close-289 (session KEPT), alarm-289, queue-policy-289, cap16-289, rto-289, rto-ssl-289, soak-cot-289 | as #264, asserting the gateway's log/snapshot | overlay where the mechanism differs (amqp-close: overlay ENDS the session → FAIL; flap leg: overlay unbounded → FAIL) |
| owner-8089-289 | another user's uid: connection closed, `refusing device … owned by user` logged, no row/queue/CoT; revocation leg: a deactivated user's cert and a CRL-listed cert (a fresh CRL written by the suite with nextUpdate +1 y, restored after) refused before any identification line | overlay: recorded / admitted → FAIL |
| fresh-volumes-289 (tier B) | `ots-pgdata` + `ots-appdata` removed, stack rebuilt: the gateway logs `waiting for schema`/`waiting for TLS files`, never exits, identifies a phone once opentakserver is up; guardian shows 0 restarts of the gateway | v2 design would exit 2 (by code); overlay: handlers crash-loop until the first run → FAIL on "0 restarts" |
| cert-reload-289 (CRL leg) | an expired CRL file placed (nextUpdate in the past by the node clock): handshakes keep working, `crl_ignored` counter set; a valid CRL listing the test cert: refused | by code |
| presence-289 | device stale → row Disconnected ≤ 150 s and a group peer receives `t-x-d-d`; reconnect while cot_parser works a 600-CoT backlog → row `Connected` ≤ 60 s; sweep leg: gateway restart with 4 Connected rows and no clients → 4 Disconnected before the listener answers | overlay: 8088 ghost; race leg: overlay row stays Disconnected → FAIL |
| rebind-289 | (a) late `t-x-d-d`/API unbind of a live device's `missions.<name>` → re-bound ≤ 30 s, 10/10; (b) group disabled while live → 0/10 within 30 s | overlay: (a) 0/10 until reconnect; (b) keeps receiving → FAIL |
| fk-restrict-289 | (a) the three FKs RESTRICT after start (catalog); (b) `DELETE FROM euds WHERE uid=<throwaway with 3 cot, 1 point, 1 geochat>` as `ots` → refused, rows intact; (c) `delete_old_data` resumed through the scheduler API for one run with the cutoff set so only the throwaway EUD (with children) is older → the job fails on the EUD delete, nothing deleted; the gateway logs `RESUMED job` within 30 s and the snapshot shows it; the suite re-pauses the job (and a detached timer does too); (d) honest negative leg, reported as INFO not PASS: with the throwaway EUD having NO children older than the cutoff, the job's direct timestamp deletes DO run on throwaway cot rows — the record is not protected against a resumed job, only watched | overlay build: (b) rows gone, (c) EUD + children gone, no RESUMED line → FAIL |
| allowlist-289 | empty: no listener on 8088; `X`: X admitted, Y closed before any row/queue | overlay: Y admitted → FAIL |
| cap-289 | `MAX_DEVICES=4` for one run: the 5th refused; per-user leg: one cert, 6 uids → 4 admitted; cycling leg: one cert, 30 fresh uids in 60 s → 4 admitted, 26 refused with no row and no queue (`rabbitmqctl list_queues` count unchanged) | overlay: all admitted, 30 queues → FAIL |
| eud-mem-289 | 16 idle devices ≤ X MiB each (X from rc 1, provisional 4); D2 leg: 8 of 16 not reading under a 1 MB burst → peak ≤ 70 % of the cap, back to baseline | overlay: 23 MiB idle → FAIL at 4 |
| slowreader-289 | one phone at 64 kbit/s (tc on the bench node) under a 16-phone burst for 120 s: session kept, drops counted, others unaffected | overlay: by code (no close path) |
| fresh-broker-289 | the 7 exchanges deleted live (`rabbitmqctl delete_exchange` — ⚠️ confirm the CLI; else tier B with a fresh volume): a phone identifies, 10/10 | overlay: bind 404 → session ends → FAIL |
| broker-restart-289 (tier B) | `docker restart rabbitmq` with 4 devices: all kept, queues re-declared, 10/10 after | overlay: sessions end → FAIL on "kept" |
| amqp-down-289 (tier B) | broker stopped 6 min: the gateway exits 3, the guardian restarts it, phones reconnect after | by code |
| dbdown-289 (tier B) | `ots-db` stopped 20 s while 4 devices stream: all CoT stored after | overlay: FK-dropped → FAIL |
| cleanstop-274 (extended) | a stream running into `payload-stop`: stored == sent − stated residual; `stop:` line | today's tiers: cot_parser stopped in parallel → FAIL |
| cert-reload-289 | server cert re-issued: a new connection sees the new cert without restart | overlay: restart needed → FAIL |
| cleanstop-274 (extended) | plus: the `stop:` line's Q (left in the cot_parser queue) asserted 0 for a 20-CoT stream ending 1 s before the stop | — |
| offline (CI) | framing/oversize-discard/carry-over close, uplink bucket pause/resume, admission caps and buckets, pending evict-oldest and hard lifetime, supersede + promotion of a draining connection with loopback sockets, publisher with a fake channel (return on firehose must NOT retry; return/nack/loss/blocked on cot_parser), downlink bounds and back-pressure, presence event shape against cot_parser's `insert_cot` attribute list, reconcile add/remove incl. the candidate-set unbind, migration idempotency + lock_timeout retry against a postgres container, scheduler watch query, CRL validity gate (expired / valid / absent), stop sequence timing ≤ 4.5 s with a stalled fake DB, import against the pinned image digest | the suites FAIL on the previous gateway commit (register) |

Every suite removes the rows/queues it created and FAILs if anything is left; an empty or unreadable snapshot is a
FAIL.

## 8. Not in scope / leftovers for the user

- **Hard deployment dependency:** 8089-only needs a field enrolment flow for client certs (#54, or #219/#254 stage
  1) and the server cert ≤ 398 days for iOS (#170 note). Until then the build is validated with the harness's test
  certs only.
- **One OTS user per member** (the per-user caps and the ownership rule assume it): a #54 enrolment requirement; on
  04 today every device is `administrator`'s or unowned.
- **A node-side verdict for the record's controls** (FK + paused jobs): there is no node-side conform today; a
  guardian hook is a #274-scope PR — the user decides whether to add it; until then the daily harness run is the
  control.
- **Decision 3 residual**: a certless flood > ~100 TLS connections/s can starve admission (M2.1); a per-address
  rule would bound it — the user chose none.
- Relay semantics and `minimal_row` for forwarded uids (decision 5, with Meshtastic); #47; retention/archiving; an
  active kill of a live session on user deactivation (today: at its next reconnect); the other 11 CASCADE FKs; CRL
  regeneration (#54).
- The 1.8 GiB freed in the node budget: unassigned until #287 measures cot_parser/postgres under load.
- Upstream reports (A6-5, A4-13, `find_user` None): after validation; outside the project repos (ask first).

## 9. Open questions for the review

1. (Round 2: both agreed) one AMQP connection; RESTRICT on cot/points/geochat; stop tiers 1 / 2.
2. v3's refusal of a cert holder claiming another user's uid (M4) changes #264's "recorded, no subscription": the
   user's call (header).
3. The decision-3 residual (certless flood > ~100 conn/s) and the one-user-per-member assumption: the user's call.

## 10. Review register

### Round 2 (v2 → v3)

| finding | disposition in v3 |
|---|---|
| A2-1 / B2-8 phase-B parallel start; first boot has no schema/certs; exit 2 → crash loop | §1 start sequence: wait loop for schema + TLS files, exit 2 only for malformed config; §0 orchestrator facts; lifecycle rows fresh volumes / restored pgdata; fresh-volumes-289 |
| A2-2 / B2-2 jobs delete directly; no node-side conform; state in `apscheduler_jobs` | M10 rewritten (RESTRICT's real reach stated; scheduler watch on `apscheduler_jobs` by the gateway, 30 s; no node-side verdict — leftover for the user); fk-restrict-289 (b)(c)(d) incl. the honest negative leg |
| A2-3 / B2-5 pending pool lockout; pings extend the deadline for ever | M2.1 evict-oldest, pool 1024; M2.4 `IDENT_HARD_S` 120 s + `MAX_PENDING_PER_USER` 12; residual with numbers (§6, §8); admission-289 (i) asserts a phone identifies during the flood, (i2) |
| A2-4 / B2-1 CRL expiry fails every handshake | M14: CRL loaded only while valid ≥ 30 days by the node clock, re-evaluated daily/mtime/clock jump; counter; lifecycle row; cert-reload-289 CRL leg |
| A2-5 oversize closes the connection | M1: discard to the closing tag, keep the session; close only past 1 MiB carry-over |
| A2-6 stop UPDATE unbounded; thread holds exit | M13: `statement_timeout 1s`, `os._exit(0)` |
| A2-7 NOT VALID + VALIDATE in one transaction | M10: two transactions, `lock_timeout 5s`, retry; names/columns from the catalog |
| A2-8 models not importable standalone | §1: bootstrap = `cot_parser.py:1336-1360` (`create_app()` on config.yml) |
| A2-9 one user per member assumed | §6/§8: #54 requirement, stated |
| A2-10 losses at exit 3 / crash; crash loop no give-up | M17 |
| A2-11 direction OUT filter | M9 |
| B2-3 uid cycling fills the broker | M2.5 per-user new-device bucket before row/queue; cap-289 cycling leg |
| B2-4 CPU on the single loop | M1 per-session uplink bucket + `pause_reading`; admission-289 (k) |
| B2-6 track forgery by a cert holder | M4: refused outright (change from #264, header; §9) |
| B2-7 `mandatory` on firehose returns every body | M6: mandatory on `cot_parser` only; offline test |
| B2-9 cot_parser is ended by SIGINT at once | M13: drain poll of the `cot_parser` queue until 0 or t = 4 s; `Q` in the stop line |
| B2-10 device with only draining connections | M7: newest draining promoted to current |
| B2-11 DB error vs not-found at the cert lookup | M2.2 |
| B2-12 `last_event_time` semantics | M8: phone's SA `start` for Connected; `max(…, now)` for Disconnected |
| B2-13 stale binding after a crash / API race | M9: candidate-set unbind at identification (⚠️ unbind-ok on absent binding probed at implementation) |
| B2-14 two consumers; conform tick; web-map hop; exchange flags; column names | M7, M10, M8, M6 (flags = `app.py:163-172`, listed in §5), M10 |

### Round 1 (v1 → v2)

| finding | disposition in v2 |
|---|---|
| A1-1 / B1-2 `init_once` does not exist | M10: migration by the gateway at every start (NOT VALID + VALIDATE), retried on DB error; §2/§4 updated |
| A1-2 directory MOUNT refused | single file `eud-gateway.pyz`; manifest §3; no payload-run change |
| A1-3 / B1-1 / A1-12 stop 5 s, SIGINT, same tier | M13: ≤ 3 s plan, SIGINT+SIGTERM, tiers gateway 1 / cot_parser+opentakserver 2, residual stated, cleanstop-274 asserts the record |
| A1-4 / B1-5 unbounded pending | M2.1 `MAX_PENDING` 128 + reserve at accept; admission-289 (i) |
| A1-5 / B1-6 per-device / per-user unbounded | M2.5 caps 3 / 4; flap leg; cap-289 per-user leg |
| A1-6 / B1-8 drain timeout closes live phones | M7: no timeout, write-buffer limits, `SO_SNDBUF`; slowreader-289 |
| A1-7 / B1-3 real deleters are jobs; no delete API; ORM cascade; sibling FKs | M10 rewritten; §0 facts; conform checks FK + scheduler; fk-restrict-289 uses the job; leftovers stated |
| A1-8 / B1-12 clock-based sweep | M8: clock-free sweep of all Connected rows before listeners; node clock in §2; no row/clock comparison anywhere |
| A1-9 / B1-13 health contract | M17: bind 0.0.0.0, start gate only, exit 3 watchdog; amqp-down-289 |
| A1-10 / B1-15 re-assert only adds; cost | M9 reconcile add+remove, 30 s + first SA, deltas only; rebind-289 (b) |
| A1-11 / B1-18 `t-x-d-d` shape | M8: exact upstream event + body; offline test against `insert_cot`'s attribute list |
| A1-13 log readers | M18 + §3; harness PR first |
| A1-14 socket buffers, pids | M12 arithmetic, `SO_SNDBUF`, executor pinned, pids 32; eud-mem-289 D2 leg |
| A1-15 / B1-17 "recorded" ambiguity; allowlist re-check | M4: no row write for a refused uid; re-check at each 8088 identification |
| A1-16 / B1-9 queues/exchanges after a broker restart or fresh volume | M6 declares all 7 exchanges + per-device queues on reconnect; fresh-broker-289, broker-restart-289 |
| A1-17 / B1-16 lifecycle rows | §4: dockerd, br-ots, clock jump, opentakserver restart, broker away, volume full, cert rotation, DB late, fresh broker |
| A1-18 negative controls | §7: cap-289 real control; (i)/(j)/flap stated |
| B1-4 presence race | M8 re-assert on the cycle; presence-289 race leg |
| B1-7 1 MiB message | M1 `MAX_EVENT_BYTES` 64 KiB; admission-289 (j) |
| B1-10 inactive CN / CRL | M2.2 + M14; owner-8089-289 revocation leg; §6 captured phone |
| B1-11 suites on 8088; enrolment dependency | §7 all on 8089; §8 hard dependency |
| B1-14 channel topology | M7 channel per device |
| B1-18 snapshot ts, chatrooms, entrypoint, lock/reserve, allowlist DB at start | §3 ages not timestamps; chatrooms noted (nothing binds); entrypoint = pyz; M2.5 lock holds across checks+insert; M4 DB check at identification |
