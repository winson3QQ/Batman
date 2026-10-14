# #289 OTS EUD gateway — design v1

Status: v1 for review · 2026-10-14 · replaces the `EudHandler-264.py` overlay (#264, PR #288) with a component of
our own. Parent #75. Facts, measurements and leftovers it builds on: #289 body and comments; `264-ots-eud-patch.md`
and `264-review-register.md` (the overlay's seventeen mechanisms R1–R17 and every finding).

Review rules: `docs/design/REVIEW.md` plus the user's global rules (ownership, contracts, lifecycle matrix, evidence
for every assumption, security per actor; two independent reviewers; BLOCKER/MAJOR to zero before code).

## User decisions this design honours

| # | decision | source |
|---|---|---|
| 1 | Data Sync / missions ARE needed in the field → OTS stays (cot_parser, postgres, web, enrollment); goatak rejected (#289 comment 2026-10-14: burst loses 57 % and the record with it) | 2026-10-14 |
| 2 | Team members use **8089 (client cert) only**; **8088 only for an allowlist of relay uids, default off** (this implements #48's "disable plaintext CoT") | 2026-10-13 |
| 3 | **No per-address limit**; admission by device count and memory only, sized to use the Pi 4's 8 GB | 2026-10-14 |
| 4 | A superseded connection keeps reading its uplink for the outage's length + 20 s, at most 120 s | 2026-10-14 (= #264 decision 6) |
| 5 | Relays stay in scope but are **not tied to the TAK path now**; the Meshtastic relay is taken up when Meshtastic is scheduled | 2026-10-14 |
| 6 | **No dedup** at the gateway; at-least-once, small numbers of duplicates accepted | 2026-10-14 |
| #264-1 | a device refused for a colliding callsign is still RECORDED (own row, own `<uid>` queue) | 2026-10-12 |
| #264-2 | CoT lost while the mesh path is down are lost; re-sending is the client's job | 2026-10-12 |
| #264-3 | accepted residuals A4-4 (OOM order), A4-6 (unread uplink on a server-side close), A4-9 (definitions file owns the broker credential, #47), A4-10 (24 h queue expiry), B4-7 (re-issued phone needs an admin reassignment) | 2026-10-12 |
| #264-5 | when the same device opens a new session, the previous one stops its downlink at once and keeps reading | 2026-10-12 |
| P1–P4 | presence owned by the gateway; bindings re-asserted idempotently; FK CASCADE→RESTRICT migration + conform check; 8088 allowlist | 2026-10-13 ("都納入") |

Field scenario (the user, 2026-10-12; `project_ots_field_context`): off-grid tactical team, one node per member,
the phone joins its own node (Wi-Fi/BLE) and runs ATAK/iTAK; all nodes move; the OTS node is carried by the RTO,
so the whole team's sessions go stale at once and reconnect together (16 zombies + 16 reconnects, possibly twice
within 2 min); Meshtastic is the fallback when HaLow is jammed; batteries are swapped (power loss); OTA only in
maintenance; **the after-action review must restore every record**; OTS runs only on Pi 4 8 GB (04: MemTotal 7.6
GiB, MemAvailable 6.6 GiB). Capacity target: 16 phones.

What is NOT captured from real devices (⚠️ assumptions, the deferred field test): whether ATAK/iTAK send their SA
within seconds of connecting (A1), what they do in the background (A4), whether a flap opens a new session (A7),
how phones roam between nodes (A8), the phones' addresses as OTS sees them (D4). Every mechanism below that
depends on one of these says so.

## 0. What exists and what changes

Today (04, 1.5.10-wsl.1): six containers on `br-ots`: `ots-db` (postgis 18-3.6), `rabbitmq` (4.3.6, definitions
file with policy `batman-264-eud-queues`), `opentakserver` (Flask API 8081), `ots_cot_parser`, `ots_eud_handler`
(8088, 1280m) and `ots_eud_handler_ssl` (8089, 1536m); both listeners run upstream OTS 1.7.13 `EudHandler.py` under
the 2205-line overlay (bind-mounted ro, `MOUNTSHA`-pinned). fw4 DNATs 8088 → 172.20.0.10 and 8089 → 172.20.0.12.
`cot` has 1060 rows, `euds` 27; FK `cot_eud` is `ON DELETE CASCADE` (psql, 2026-10-14).

The upstream contract the gateway keeps (measured on 04, `cot_parser.py` 1.7.13):
- **Uplink:** JSON `{"uid": <session uid or null>, "cot": "<event …/>", "user_id": <int or null>}` published to the
  durable direct exchange `cot_parser`, routing key `cot_parser`, property `expiration` = `OTS_RABBITMQ_TTL`
  (86400000); a copy `{"uid","cot"}` to the fanout exchange `firehose` (plugins). `cot_parser` consumes queue
  `cot_parser` (transient, declared by cot_parser with default arguments, prefetch 2), inserts the row (FK
  `cot.sender_uid → euds.uid`: no row = `basic_nack(requeue=False)`, the CoT is gone), parses, routes (`route_cot`:
  DMs by `<dest callsign|uid>`, missions, groups `__ANON__.OUT` or `<group>.OUT`), and on a `t-x-d-d` event sets the
  EUD row `Disconnected` and emits it to the web (`cot_parser.py:1253-1275`).
- **Disconnect message:** `{"uid","cot":null,"disconnected":true,"user_id"}` → `send_disconnect_cot`
  (`cot_parser.py:940-1033`): on 8088 it raises (`BlockingChannel.is_closing`, A6-5) before updating the row; on 8089
  it publishes `t-x-d-d` to the user's groups and **binds** the departed `<uid>` queue to them (R15's filling queue),
  then sets the row `Disconnected`. **The gateway never sends this message** (P1).
- **Downlink:** per-EUD transient queues `<uid>` and `<callsign>` bound to `dms` (routing keys uid/callsign),
  `groups` (`__ANON__.OUT` or the user's `<group>.OUT` keys), `missions` (`missions`, plus `missions.<name>` placed by
  the Marti API `mission_marti_api.py:1504` and by cot_parser on a mission change), `chatrooms`. Consumed by every
  session of that uid (`auto_ack=True`, round-robin) upstream.
- **Web map:** the handler publishes `{"data": eud.to_json(), …}` to the fanout exchange `flask-socketio` at
  identification (`EudHandler.py:291-305`); `to_json()` needs a Flask app context (impl-11).
- **Identity on 8089:** the client cert's CN is an OTS `user.username` (`EudHandlerSSL.setup`, `find_user`); the
  server context is `CERT_REQUIRED`, CA `/app/ots/ca/ca.pem`, server cert/key under `/app/ots/ca/certs/opentakserver/`
  (`EudServerSSL.py:19-38`); no CRL is loaded there (⚠️ grep only: to confirm against `ca.crl` use elsewhere).

After this change: `ots_eud_handler`, `ots_eud_handler_ssl`, the overlay, its generator, `MOUNTSHA` and the
`patches/` directory are gone; one container **`ots_eud_gateway`** (172.20.0.10, both ports, image `batman/ots`,
entrypoint our module) replaces them. `ots-db`, `rabbitmq`, `opentakserver`, `ots_cot_parser` are unchanged (one
idempotent DB migration, P3, runs in the tenant's `init_once`; the broker definitions keep R15's policy).

Scope: `deploy/ots/gateway/` (the gateway package + its offline tests), `deploy/ots/profile.yaml` + generated
manifest/fw4/hardening files, `payload-conform` (one FK check), the #264 validation suites ported to the gateway,
new suites for P1–P4, docs. Out of scope: the UDP listener (unsupported today too), the OTS web/API, Meshtastic
relay semantics (decision 5), per-node broker credentials (#47), the enrolment tool (#54).

## 1. Architecture

One process, `python3 -m batman_eud_gateway` inside the existing `batman/ots:1.7.13-arm64` image (Python 3.13,
pika 1.3.2 with `AsyncioConnection`, SQLAlchemy + the OTS models, bs4/lxml: all present — probed 2026-10-14; no new
image, no new dependency). `asyncio` throughout; blocking database calls run in a bounded thread pool (4 threads)
so no DB stall ever blocks the event loop. Language choice stated: Python keeps the OTS models (euds, users, groups,
missions) and the image; the per-session cost of an asyncio session is the thing to measure first (M12).

```
 phones ──8089 mTLS──┐                                ┌─► cot_parser exchange ──► ots_cot_parser ──► postgres
 relays ──8088 (off)─┤  Listeners → Admission → Session table (by DEVICE)        (unchanged)        │
                     │     │            │             │                                              │
                     │     ▼            ▼             ▼                                              ▼
                     │  Framing     Identity      Uplink: parse → store-before-route → Publisher (confirms, cache)
                     │                                │
                     │                                ▼
                     └◄── Downlink: one consumer per device → bounded per-session send queue → current socket
                           Presence (owner) · Bindings (owner, re-asserted) · Registry/metrics/log
```

Components and the overlay mechanism each one absorbs:

| component | does | absorbs |
|---|---|---|
| **Listener** (×2) | `asyncio.start_server`; 8089 with `ssl.SSLContext` (CERT_REQUIRED, CA, server cert) and a 10 s handshake timeout; 8088 only when `GATEWAY_8088_ALLOWLIST` is non-empty, else not bound at all | R12 (handshake before allocation) |
| **Admission** | per-connection: nothing allocated before the first complete message (a 64 KiB read buffer only); a rolling first-message deadline of 60 s until identified; device-count cap and memory check **at identification**, serialized by one asyncio lock (no file lock, one process) | R7, R12, R16 (no per-address rule: decision 3) |
| **Framing** | bytes → complete `<event>…</event>` / `<auth>` messages, carry-over bounded 1 MiB, bs4 parse once | R1 |
| **Identity** | 8089: user = cert CN; uid/callsign from the first SA; ownership rule (another user's device uid → refused subscription, recorded); 8088: uid must be on the allowlist (else the connection is closed before any allocation and logged once per address per minute); name guard for every broker name | R10, P4 |
| **Session table** | key = device: 8089 `(user_id, uid)`, 8088 `(address, uid)`; value = one session object owning the AMQP consumer, the cache, the bindings it placed, the registry row and **a list of connections** (the current socket + superseded ones draining) | R17 by construction (one downlink per device), R6 |
| **Uplink** | per message: identify if needed → **store-before-route** (euds row written or confirmed before the first publish) → publish `{uid,cot,user_id}` to `cot_parser` and `firehose` | R14 (an exception drops the message, not the session), R5, R4/R4b |
| **Publisher** | ONE AMQP connection and one publishing channel for the whole gateway (`confirm_delivery`, `mandatory`); per-session bounded cache (2 MiB / 500 entries, a-* coalesced per uid on overflow, then drop-oldest with a count); head-only retry on a return; reconnect with backoff on loss; declares `cot_parser` exchange/queue/binding with cot_parser's exact arguments on every channel open; blocked-connection callback → cache | R4, R4b, R5, R9, R13 (no session end on a broker loss: the connection is the gateway's, the session keeps its socket and its cache) |
| **Downlink** | one consumer per device on `<uid>` (and `<callsign>` when the callsign is usable and free), `auto_ack=False`, ack after the message is queued to the socket; per-session send queue bounded (1 MiB / 200 msgs, a-* coalesced per uid, then drop-oldest + count); writes are `transport.write` + `drain()` with a 5 s timeout → the socket is closed (the kernel buffer is full: the phone is not reading); never blocks another session | R2 (closed), R6 shared-queue residual (gone) |
| **Presence** | owner of `euds.last_status/last_event_time` for its devices: `Connected` at identification, `Disconnected` at the device's last connection end (incl. reap), and a `t-x-d-d` CoT (`<link uid= type= relation="p-p"/>`) published as a NORMAL uplink message so cot_parser routes it to the team and sets the row (its existing `t-x-d-d` branch, both ports) | P1, A6-5 |
| **Bindings** | owner of the per-EUD queue bindings of live devices: placed at identification from the DB (dms, groups or `__ANON__`, `missions`, mission subscriptions of the user), **re-asserted idempotently on every SA of the device and every 30 s**; unbound at the device's last end only what this gateway placed; queues deleted only for 8088 relays' own queues (none: relays get no queues) | P2, A7-11, R6, R15 |
| **Registry** | in-memory table + a JSON snapshot every 10 s to the container's tmpfs (for `docker exec` diagnosis and the suites: `/tmp/gateway/sessions.json`); prometheus-style counters in the same file | R17 registry (no files, no signals, no pids) |
| **Health** | `GET /healthz` on 172.20.0.10:8090 (br-ots only): 200 when both listeners are bound and the AMQP connection is open, else 503 → guardian `HEALTH` | #156/#274 guardian |

### 1.1 Mechanisms stated as rules

**M1 Framing.** As R1: raw bytes kept until a closing tag; decode only complete messages; carry-over ≤ 1 MiB,
then the connection is closed (logged). A malformed message is dropped and logged; the session goes on (R14).

**M2 Admission (decision 3).**
1. 8089: TLS handshake within 10 s or the socket is closed; nothing else allocated before it.
2. 8088: the listener exists only when the allowlist is non-empty; a connection whose first identifying message
   carries a uid not on the allowlist is closed at once; a non-identifying first message (ping, `<auth>`) is
   answered and the deadline keeps running.
3. Until identified: rolling deadline `IDENT_MAX_S` 60 s moved by every complete message (a silent socket is cut,
   a relay that keeps sending is not), as R12 (B3-3).
4. At identification, under the admission lock (asyncio, held only across the check and the table insert, µs):
   - **device cap** `MAX_DEVICES` (default 64 = 16 phones × 3 generations in flight + margin; a superseded
     connection counts as its device's, not as a new device);
   - **memory**: the container's own cgroup `memory.current − memory.stat file` against `memory.max` with a reserve
     `RESERVE_MB` 64 (fail-closed: unreadable cgroup → no cap, logged, as R7);
   - refused → the connection is closed with one log line `refusing device <uid> from <ip>: <reason>`; the phone
     reconnects later. A device already in the table is never refused (its new connection supersedes, M3).
5. Pings (`t-x-c-t`) and `<auth>` never allocate a session (answered from the connection object).

**M3 Sessions by device; supersede (decisions 4, #264-5).** A new identified connection of a device already in the
table replaces the current socket: the new socket gets the downlink at once; the old socket stops receiving
downlink, keeps being read, and is closed at `supersede_time + min(outage + 20 s, 120 s)`, extended by 20 s after
every byte that arrives while a newer connection lives (`outage` = time since the old socket's last byte). A device
whose socket dies (FIN/RST, `TCP_USER_TIMEOUT` 120 s, keepalive 45/15/4) with no other live connection ends the
session: consumer cancelled, bindings removed, presence `Disconnected` + `t-x-d-d`, row kept. A device on 8089 is
identified by `(user_id, uid)`, so a phone coming back through ANOTHER node (new address) supersedes its old
connection the same way (A8 ⚠️ assumed). On 8088 `(address, uid)`: a relay from another address is another device.

**M4 Identity and names (R10, P4).** uid and callsign are checked before any broker use: empty, >255 bytes, `amq.`
prefix, a system name (`cot_parser`, `dms`, `chatrooms`, `missions`, `groups`, `firehose`, `flask-socketio`,
`meshtastic`, `dmrcot`), non-printable → the uid gives no subscription and no row (one log line), the callsign is not
used as a queue and the device is recorded under its uid (decision #264-1). 8089: a uid whose row belongs to another
user → recorded, no subscription (B4-7 reassignment in the web UI). The callsign column is written only when free
(`euds.callsign` UNIQUE). 8088 uids come only from the allowlist, so the "8088 client naming a user's device" rules of
R10 reduce to: an allowlisted uid that equals an 8089 user's device uid is refused at config validation (the gateway
refuses to start with a log line; fail-closed).

**M5 Store-before-route (R14, F1).** The first publish of a device waits for its euds row: metadata written
defensively (phone digits only, strings cut to 255, missing `start`/`role` tolerated), else a minimal row (uid,
Connected, user, callsign if free); a DB failure is retried every 30 s on the device's next CoT while its CoT are
cached (bounded, M6) instead of being FK-dropped by cot_parser. Relays (deferred, decision 5): their forwarded CoT
need a row per forwarded uid; the hook is a `minimal_row(uid)` call per distinct event uid, rate-limited; **not
implemented now**, so an allowlisted relay's CoT for unknown uids is dropped by cot_parser's FK today (stated).

**M6 Publisher (R4, R4b, R5, R9, R13).** One `AsyncioConnection`; on every channel open: declare exchange
`cot_parser` (direct, durable), queue `cot_parser` (default args), bind; `Confirm.Select`. Every body is held until
its ack; a nack or return puts it back at the head of its session's cache; on channel/connection loss all unacked
bodies go back in publish order and the connection reconnects with backoff 1, 2, 4, 8, 16, 30 s ±25 %. Order per
session is kept (a new body queues behind a non-empty cache). The session's TCP connection is NOT ended on a
broker-side loss (the overlay had to, R13, because its subscription lived on the lost connection; here the consumer
is re-placed from the session's recorded bindings when the connection is back — the gateway is the owner of those
bindings, P2, so nothing placed through the Marti API is lost: those bindings live in the broker, not in the
connection). Broker blocked (memory alarm) → cache, resume on unblock, no timeout.

**M7 Downlink (R2, R6).** Consumer per device, `prefetch` 50, manual ack after the message is appended to the
session's send queue; the writer task drains the queue to the CURRENT socket with `await drain()` bounded by 5 s;
on timeout or error the socket is closed (the device's session survives if another connection exists, else ends).
Queue overflow coalesces `a-*` by uid, then drops the oldest and counts. A superseded socket gets nothing.
With one consumer per device the broker never splits the device's downlink with a zombie (the overlay's residual).

**M8 Presence (P1).** The gateway writes `last_status`/`last_event_time` and publishes a `t-x-d-d` event for
the device at its last end (and at a reap). It never sends the `disconnected` JSON, so cot_parser's 8088 raise and
8089 queue-binding paths are not exercised. cot_parser's own `t-x-d-d` branch sets the row again (idempotent) and
emits it to the web. At identification the gateway publishes `{"data": eud.to_json(), …}` to `flask-socketio` from a
worker thread holding an app context (impl-11).

**M9 Bindings (P2).** The set a device needs = `dms`:uid (+callsign when usable), `groups`: `__ANON__.OUT` or each
`<group>.OUT` of the user's memberships, `missions`:`missions`, and `missions.<name>` for every mission the device is
subscribed to (DB truth = `mission_roles`: `mission_subscribe` adds a role row and binds, `mission_unsubscribe`
deletes the row and unbinds — `mission_marti_api.py:1345-1555`, probed 2026-10-14; `mission_uids` is mission
content, not subscriptions). Placed at
identification and re-asserted (idempotent `queue_bind`) on every SA and every 30 s; a late `t-x-d-d` or a Marti
API change can therefore remove a binding for at most 30 s / one SA. Unbound at the device's last end: only what the
gateway placed. Queues are never deleted for 8089 devices (R15's policy expires them after 24 h unused).

**M10 FK migration (P3).** `init_once` (tenant, runs with the DB up, idempotent SQL): `ALTER TABLE cot DROP
CONSTRAINT cot_eud; ALTER TABLE cot ADD CONSTRAINT cot_eud FOREIGN KEY (sender_uid) REFERENCES euds(uid) ON DELETE
RESTRICT`. `payload-conform` queries `pg_get_constraintdef` and reports DRIFT when it is not RESTRICT (an OTS
upgrade's migration could revert it). A device with history can no longer be deleted from the web UI (the API
returns an error; archiving is the operator's path).

**M11 Zombies (R6).** `SO_KEEPALIVE` 45/15/4 + `TCP_USER_TIMEOUT` 120 s on every accepted socket; a vanished peer
ends its connection in ≤ ~2 min either way; a blocked writer is bounded by M7's 5 s drain, not by 120 s.

**M12 Resources (decision 3).** Container cap `GATEWAY_MEMORY` 1024m (one process; expected ≤ 2 MiB per session:
**to be measured in the first rc, the cap is revised from the measurement**), `pids` 64 (asyncio + 4 DB threads),
`MAX_DEVICES` 64, cache 2 MiB/session (worst case 128 MiB), send queue 1 MiB/session. Node budget after the change:
opentakserver 1280 + cot_parser 1280 + gateway 1024 + rabbitmq 512 + ots-db 512 = **4.6 GiB** < 6.6 GiB available
(was 6.4). The 1.8 GiB freed is not reassigned by this design (the user: use the 8 GB — the gateway's cap is sized
from the measurement, not from the 1280m era; cot_parser/postgres caps are #171-closed figures, re-measured in
#287's soak). `oom_score_adj` is NOT raised (one process = the listener; an OOM would take everything, so the cap +
reserve + bounded caches are the defence; the kernel OOM is a backstop the lifecycle table states).

**M13 Graceful stop (#274).** SIGTERM: stop accepting, publish presence `Disconnected`+`t-x-d-d` for every device,
drain caches ≤ 60 s, close sockets, exit 0. The guardian's stop tier 1 (before opentakserver, then db/broker).
SIGKILL (power loss): caches and unread data lost (stated, as today).

**M14 TLS.** `ssl.SSLContext(PROTOCOL_TLS_SERVER)`, `verify_mode CERT_REQUIRED`, `load_verify_locations(ca.pem)`,
`load_cert_chain(opentakserver.pem, .nopass.key)` as `EudServerSSL.py`; handshake 10 s; shutdown by closing the
transport (asyncio never calls `SSLSocket.shutdown` on the raw socket: no clear-text race). CRL: as upstream (none
loaded in the listener ⚠️); revocation is #54/#219's concern.

**M15 Relays (decision 5).** The 8088 listener and the allowlist are implemented (P4). Relay semantics (no queues,
rolling deadline, `minimal_row` per forwarded uid, status of forwarded devices) are designed here only as the hook
in M5 and are NOT implemented; the allowlist ships empty (listener not bound). Taken up with Meshtastic.

**M16 Configuration.** Env from the profile (all optional, validated at start, a malformed value → exit 2 with a
log line, fail-closed): `GATEWAY_MAX_DEVICES` (64), `GATEWAY_RESERVE_MB` (64), `GATEWAY_IDENT_MAX_S` (60),
`GATEWAY_SUPERSEDE_QUIET_S` (20), `GATEWAY_SUPERSEDE_MAX_S` (120), `GATEWAY_8088_ALLOWLIST` ("" = listener off; a
comma-separated uid list), `GATEWAY_CACHE_MB` (2), `GATEWAY_SENDQ_MB` (1). Secrets: none new (the broker guest
credential and the DB URI come from `env_common` as today, #47 unchanged).

## 2. Ownership

| resource | owner (writes) | readers / notes |
|---|---|---|
| gateway package (golden, p6 `apps/opentakserver/gateway/`) | the build (golden refresh at boot; D7-7 DRIFT on edit) | payload-run (bind mount ro into the container) |
| container `ots_eud_gateway` | payload-run (starter), the guardian (health, restart) | — |
| the TCP/TLS listeners, every accepted socket | the gateway process (asyncio) | kernel |
| session table, caches, send queues, admission lock | the gateway process (single event loop) | `/tmp/gateway/sessions.json` snapshot: read-only for `docker exec` and the suites |
| the gateway's AMQP connection, channels, consumers | the gateway process | broker |
| `cot_parser` exchange/queue/binding | two idempotent declarers with identical args: cot_parser (upstream) and the gateway (M6) | broker |
| per-EUD queues `<uid>`, `<callsign>` | declared by the gateway at identification (and by the Marti API, cot_parser's disconnect path — not exercised, and plugins as upstream); never deleted by the gateway; expired by the broker policy (definitions file) | — |
| bindings of a live device's queues | **the gateway** (placed, re-asserted, removed only what it placed); the Marti API also binds `missions.<name>` on subscribe/unsubscribe (operator action, upstream) — two writers, stated: the gateway re-asserts the DB truth within 30 s, so the API's add is kept and the API's remove is honoured because the gateway's set is computed from the DB at each re-assert | cot_parser (publishes to them) |
| `euds.last_status`, `last_event_time` of a device with a live session | **the gateway** (M8); cot_parser's `t-x-d-d` branch writes the same value (idempotent) | web UI (reads) |
| other `euds` columns (metadata, callsign, user_id, team) | the gateway at identification (defensive write, as the overlay); the web UI/API (operator) | cot_parser |
| `cot` rows | cot_parser (insert); nobody deletes (P3 RESTRICT) | web/API, the AAR |
| FK `cot_eud` definition | `init_once` migration (P3) | payload-conform (DRIFT check) |
| broker policy, vhost, user | `rabbitmq-definitions.json` (golden) | broker |
| `GATEWAY_*` env, allowlist | `profile.yaml` (golden) | the gateway at start |
| snapshot `/tmp/gateway/sessions.json`, counters | the gateway (atomic rename, every 10 s) | suites, operators (ro) |
| health endpoint 8090 | the gateway | the guardian (`HEALTH curl -fsS http://localhost:8090/healthz` inside the container) |

## 3. Contracts

- **Uplink to cot_parser:** body, exchange, routing key, TTL property exactly as upstream (§0); `mandatory` + confirms
  on our side; at-least-once; order kept per session, not across a reconnect; a replayed CoT may be stale when routed
  (stated). Trust: only the gateway and upstream's own publishers write to the exchange; the broker is trusted.
- **Downlink from the broker:** JSON bodies as upstream (`{"uid","cot"}` or the CoT string: ⚠️ both forms exist
  upstream, `route_cot` publishes `str(event)` — the gateway sends the `cot` field or the raw body unchanged, as the
  overlay does). Malformed → dropped and counted.
- **`t-x-d-d` presence event (M8):** a CoT event `type="t-x-d-d"` with `<link uid="<uid>" type="<device type>"
  relation="p-p"/>`, `uid="<uid>"`; written by the gateway; read by cot_parser (route + row) and by the phones (contact
  removed). Valid whenever the device's last connection ended. Trust: only the gateway (and cot_parser upstream) emit
  it; a client's own `t-x-d-d` goes through unchanged (upstream behaviour).
- **Client session:** a connection ends on FIN/RST, `TCP_USER_TIMEOUT`, the M2 deadline, M7's drain timeout, the M3
  supersede deadline, a refused admission, or container stop. A device's session ends when its last connection ends.
  A broker-side loss ends nothing on the client side (M6).
- **Allowlist `GATEWAY_8088_ALLOWLIST`:** comma-separated uids, written by the profile; empty = 8088 not bound;
  a uid failing M4's name guard or equal to an 8089 user's device uid → the gateway exits 2 at start (fail-closed,
  visible as a guardian crash + DRIFT). Trust boundary: root-owned golden file.
- **`/tmp/gateway/sessions.json`:** `{"ts", "devices": [{"key","uid","user","port","connections":[{"addr","since",
  "superseded_at","last_rx"}],"cache":n,"sendq":n,"bindings":[…]}], "counters": {…}}`; valid when `ts` is < 30 s
  old; stale/missing/malformed → the suites FAIL (never report clean, per the validation rules). Written only by the
  gateway (container tmpfs, uid 1000).
- **Log lines other tools read** (file `/app/ots/logs/eud_gateway.log`, daily rotation by count as upstream, plus
  stdout): `identified <uid> user=<u> port=<p> from <ip>`, `superseded <uid>: new connection from <ip>`, `ended <uid>
  (<reason>)`, `refusing device <uid> from <ip>: <reason>`, `cache full for <uid>: dropped=N`, `sendq full for
  <uid>: dropped=N`, `AMQP lost: reconnecting in <s>`, `AMQP open`, `rebind <uid> +N -M`, `presence <uid>
  Disconnected`, `allowlist refused <uid> from <ip>`. `ots_logc` counts `Failed to parse` (kept) and `dropped=` lines.
- **Health 8090:** 200 only with both configured listeners bound and the AMQP connection open; 503 otherwise;
  unreachable = the guardian's existing crash path.
- **FK `cot_eud`:** RESTRICT after `init_once`; payload-conform reads it at every boot: not RESTRICT → DRIFT (the
  stack keeps running: the gateway does not depend on it; the record's safety does, so it is visible, not fatal).
- **Manifest (generated):** container `ots_eud_gateway`, IP 172.20.0.10, `HARDEN ots_eud_gateway.hardening.env`
  (1024m, pids 64, cap-drop ALL, ro rootfs, tmpfs /tmp 64m, user 1000:1024), `VOLUME ots-appdata:/app/ots`, `MOUNT
  gateway/:/app/gateway:ro` (no MOUNTSHA: it overlays no upstream file; the image pin stays the digest), `ENTRYPOINT
  python3 /app/gateway/main.py`, `HEALTH`, `STOPTIER 1`. fw4 publish: 8088 and 8089 both to 172.20.0.10. Downgrade
  to an image whose payload-run lacks nothing new: no new manifest key is introduced (checked: every key above
  exists in `payload-run` today — MOUNT/HEALTH/STOPTIER/ENTRYPOINT/HARDEN; ✅ by the current manifest).

## 4. Lifecycle matrix

| path | today (overlay) | after | test |
|---|---|---|---|
| first boot / firstload | handlers start after broker; C window (R5 fixed) | `init_once` migration (P3) then the stack; the gateway declares `cot_parser` on its first channel open; allowlist empty → 8088 not bound | cleanstop-274 step 6, queue-gone-289, fk-restrict-289 |
| boot / reboot / power loss | as above; children SIGKILLed, caches lost | the gateway starts health-gated; caches lost at SIGKILL (stated); phones reconnect; presence rows of devices live at the loss are set `Disconnected` at the next start (startup sweep: every row `Connected` with `last_event_time` older than the boot is set Disconnected — ⚠️ new, the only writer is the gateway at start) | unclean-boot-274, presence-289 |
| clean stop / OTA (stage 1) | handlers SIGINT; caches lost | M13: presence out, caches drained ≤ 60 s, sockets closed | cleanstop-274 (asserts the drain log line) |
| OTA stage 2 (new image) | overlay refused if MOUNTSHA differs | no overlay: the gateway runs on the image's Python; an image whose OTS models differ breaks at import → exit 2, guardian crash, DRIFT (fail-closed) | first-ota + payload-conform |
| autocommit trial / revert | unchanged | unchanged (no state outside the containers and the tmpfs) | fi-s1 |
| downgrade to an image without the gateway | — | the old manifest names the two handler containers and the overlay; payload-run rebuilds them; the FK stays RESTRICT (harmless for the old stack: cot_parser never deletes); the web UI's EUD delete fails on devices with history (stated) | downgrade (manual, stated) |
| gateway crash / crash loop | per-session child death ended one session | every session ends; phones reconnect; the guardian restarts with backoff; presence sweep at start | crash-274 (ported) |
| broker-side connection close / broker restart | caches delivered then the sessions END (R13) | sessions kept; the gateway reconnects, re-declares, re-places every live device's consumer and bindings, flushes caches; transient `cot_parser` backlog lost (residual, as today) | amqp-close-289, queue-gone-289 |
| broker memory alarm | cache, no timeout | same | alarm-289 (negative control by code: ⚠️ as before) |
| cot_parser restart | queue persists | same | queue-gone-289 |
| ots-db down at identification / during | identification retried; minimal row retried 30 s; cot_parser nacks (upstream) | same; the gateway caches the device's CoT until its row exists (bounded) | exception-289 (fault injection by a DB stop? ⚠️ no node test with the DB stopped today — proposed: tier B `dbdown-289`, stops `ots-db` 20 s) |
| client network loss (no FIN) | ~2 min reap (R6); same device back → R17 supersede | M11 reap; back on any address (8089) → M3 supersede; one downlink by construction | zombie-289, same-uid-end-289 |
| RTO walks out and back (16 zombies + 16 reconnects) | 1280m/1536m, serialized admission | 16 supersedes (no new devices); memory flat (⚠️ to measure) | rto-289, rto-ssl-289 |
| RTO flaps twice within 2 min | third generation may be refused by R7 | 16 devices, ≤ 3 connections each; no refusal (devices unchanged) | rto-ssl-289 second flap |
| two app instances, one uid, one device | newest gets the downlink | same (the second is a supersede) | same-uid-end-289 |
| two devices, one callsign | both subscribed by uid; callsign queue shared | same; callsign queue only for the first (M4) | callsign-share-289 |
| a device goes stale → presence | 8088 stays Connected for ever (A6-5); 8089 via cot_parser | gateway sets Disconnected + `t-x-d-d` on both ports | presence-289 (negative control: today's stack keeps 8088 Connected) |
| a late disconnect vs a live session's missions | A7-11: missions unbound until the next reconnect | no disconnect message exists; bindings re-asserted ≤ 30 s | rebind-289 (negative control: today's stack loses the binding) |
| deleting an EUD with history (web UI) | CASCADE: the device's CoT history gone | RESTRICT: the delete fails, nothing lost | fk-restrict-289 (negative control: today a delete removes the rows — run on a throwaway uid only) |
| 8088 client not on the allowlist | admitted (8088 open) | listener off by default; with an allowlist, refused before allocation | allowlist-289 |
| hostile 8089 client (valid cert): floods, huge messages, XML bombs, pings | R12 bounds | M1 1 MiB, M2 deadline, M7 drain timeout, bs4/lxml with `resolve_entities` off (⚠️ confirm the parser used: lxml-xml; entity expansion is lxml's default-off for XML? — probe) | admission-289 (a–h ported) |
| mesh outage > 2 min | reap; what the phone queued is lost unless re-sent (decision #264-2) | same | zombie-289 |
| N devices > MAX_DEVICES / memory reserve | R7/R16 | refused at identification, logged; listener never dies | cap-289 (negative control: a cap of 4 with 6 devices) |
| 48 h soak | — | #287 on the gateway build | soak-cot-289 + #287 |
| Pi 3 (bcm2710) | OTS package bcm2711 only | unchanged | ab-card |

## 5. Assumptions with evidence

| assumption | evidence |
|---|---|
| pika 1.3.2 `AsyncioConnection` is in the image | probed 2026-10-14 on 04: `pika.adapters.asyncio_connection.AsyncioConnection` imports |
| cot_parser body/exchange/TTL contract | `cot_parser.py:1214-1290`, `EudHandler.py:190-210, 455-484` (04, 1.7.13) |
| cot_parser's `t-x-d-d` branch sets `Disconnected` and emits to the web, both ports | `cot_parser.py:1253-1275` (uid from the body or the event) |
| `send_disconnect_cot` raises on 8088 and binds queues on 8089 | `cot_parser.py:940-1033`; #264 register A6-5, R15 |
| identical re-declare of `cot_parser` queue is accepted; mandatory return-then-ack | probed on the live broker 2026-10-11 (#264 comment 6103334725) |
| FK today is CASCADE | psql 04 2026-10-14: `cot_eud FOREIGN KEY (sender_uid) REFERENCES euds(uid) ON DELETE CASCADE` |
| TLS context: CERT_REQUIRED, CA path, server cert path | `EudServerSSL.py:19-38` |
| user = cert CN via `find_user` | `EudHandlerSSL.py` setup |
| `euds.callsign` UNIQUE, `phone_number` bigint | `\d euds` 04; #264 R10 |
| overlay facts: per-session 23 MiB, 16 reconnects, R6/R17 behaviour | #264 suites on rc wsl.20/21 (register) |
| payload-run supports MOUNT/HEALTH/STOPTIER/ENTRYPOINT/HARDEN | current `ots.manifest` on 04 uses them |
| mission subscriptions live in `mission_roles` (API subscribe adds a row + binds; unsubscribe deletes + unbinds) | `mission_marti_api.py:1345-1555` on 04 (probed 2026-10-14) |
| cot_parser's 8089 disconnect unbinds the uid from EVERY mission (`missions.<name>` for all rows of `missions`) | `cot_parser.py:1012-1023` on 04 — the A7-11 mechanism; not exercised by the gateway (no disconnect message) |
| bs4 `"xml"` (bs4 4.14.2 / lxml 6.0.2) does not expand a DOCTYPE entity bomb: the event is not found (parse recovers to nothing), 5 ms | probed in `ots_cot_parser` 2026-10-14 (3-level entity, no expansion, `event None`) → such a message is "malformed", dropped by M1 |
| no CRL is loaded by the listeners | `grep -ri crl eud_handler/` on 04: empty |
| ATAK/iTAK connect/reconnect behaviour (A1, A4, A7, A8, D4) | ⚠️ not captured (deferred field test); every mechanism is stated so that any outcome is bounded (deadline, supersede, reap) |
| asyncio per-session memory ≤ 2 MiB | ⚠️ to measure in rc 1 (`eud-mem-289`); the cap is revised from it |

## 6. Security

- **Assets:** CoT confidentiality (8089 users' DMs/missions), integrity of the record (every CoT, no planted tracks),
  availability of the TAK server to the team; the node itself is unchanged (same ports, zone, DNAT target IP).
- **Actors:**
  - *Remote mesh client without a cert:* 8088 is not bound by default (decision 2): nothing to reach. With an
    allowlist: a uid not on it is closed before any allocation; an allowlisted uid can be spoofed by anyone on the
    mesh (plain TCP) — stated, the relay path's own problem (decision 5), bounded by M1/M2/M7 per connection and by
    MAX_DEVICES in total.
  - *Remote client with a valid cert (a compromised or hostile member's phone):* can hold its own device's session,
    flood (bounded per connection by M1 1 MiB, M7 queues, M6 cache; globally by MAX_DEVICES and the memory
    reserve); cannot take another user's device uid (M4), cannot read another user's queues (consumer per device of
    its own user only), cannot delete history (P3), cannot plant a `disconnected` for others (no such message),
    can still send CoT under a claimed uid of ITS OWN user's devices (upstream, stated). XML bombs: ⚠️ parser probe.
  - *Local unprivileged process on the node:* no interface (container tmpfs, root-owned golden files, br-ots only).
  - *Compromised tenant container (another app):* reaches 172.20.0.10:8088/8089/8090 only if on br-ots (intra-zone
    accept); 8090 is health only (GET, no state change); the broker credential is the same guest as today (#47).
  - *Physical capture:* unchanged (rootfs not encrypted, #47).
  - *Supply chain:* the gateway is our code in the pinned image; no upstream file is overlaid; the image digest pin
    is the existing control.
  - *Our own mistakes:* fail-closed config (exit 2), DRIFT on FK/golden edits, one owner per resource (§2), suites
    with negative controls on the overlay build.
- **Attack-surface delta:** removed: two listeners' per-connection fork, the admission file lock, the R17 signal
  registry, the fault-injection file, MOUNTSHA path; added: `/healthz` on br-ots (read-only), `GATEWAY_*` env
  (golden), the allowlist (golden), `/tmp/gateway/sessions.json` (gateway-only writer, uid 1000 tmpfs).
- **Privilege:** uid 1000:1024, cap-drop ALL, no-new-privileges, ro rootfs, ports > 1024; the DB migration runs as
  the `ots` DB role (owner of the table) via `init_once`.
- **Secrets:** unchanged (DB URI, broker guest, TLS key on the `ots-appdata` volume, 0700/1000). Never logged.
- **Failure mode:** fail-secure: a bad config stops the gateway (no TAK server rather than an open one); an
  unreadable cgroup drops only the memory cap (logged) because refusing everyone would be a self-inflicted outage
  (as R7); a missing allowlist = 8088 closed.
- **Negative tests:** allowlist-289 (unlisted uid refused; listener absent when empty); owner-8089-289 (another
  user's uid refused); admission-289 (floods hold up no phone); fk-restrict-289 (delete refused); a non-root `docker
  exec` cannot write the golden or the snapshot of another container (by confinement, existing suites).

## 7. Tests

Every `-264` suite is ported as `-289` against the gateway, each with its negative control run on the shipped
overlay build (1.5.10-wsl.1) where the behaviour differs, or "by code" stated; new suites: presence-289 (P1),
rebind-289 (P2), fk-restrict-289 (P3), allowlist-289 (P4), cap-289 (device cap), dbdown-289 (tier B), eud-mem-289
(per-session memory, the figure that sets the cap). Offline: the gateway's own pytest (framing, admission,
supersede with real sockets on loopback, publisher with a fake channel incl. return/nack/loss, downlink bounds,
presence). Harness changes go in their own PR before the product PR (#290 rule); every rc gets at least one full
`daily-validation` run; the shipping candidate is the last harness commit + the last rc.

| suite | what | negative control |
|---|---|---|
| ots-cot-e2e-289 (+ssl) | sent == stored over a coalesced stream | R1 overlay = PASS; upstream 0/20 (by record) |
| admission-289 | a–h: silent, pre-TLS, ping-only, `<auth>` flood, contact-less stream hold up no phone | overlay: same PASS; the test proves no regression |
| zombie-289, same-uid-end-289, callsign-share-289, owner-8089-289, name-guard-289, exception-289, queue-gone-289, amqp-close-289, alarm-289, queue-policy-289, cap16-289, rto-289, rto-ssl-289, soak-cot-289 | as #264, asserting the gateway's log lines and snapshot instead of the overlay's | overlay build where the mechanism differs (amqp-close: the overlay ENDS the session → FAIL on the new assertion "session kept") |
| presence-289 | an 8089 device (and an allowlisted 8088 uid) goes stale: row Disconnected within 150 s, teammates receive `t-x-d-d` | overlay: 8088 row stays Connected (A6-5) → FAIL |
| rebind-289 | a late `t-x-d-d`/API unbind of a live device's `missions.<name>`: re-bound within 30 s, downlink 10/10 | overlay: 0/10 until reconnect (A7-11) → FAIL |
| fk-restrict-289 | delete an EUD with 3 CoT via the API: refused, rows intact; payload-conform reports the FK | overlay build: rows gone → FAIL |
| allowlist-289 | allowlist empty: 8088 connection refused (no listener); allowlist with uid X: X admitted, Y closed before any row/queue | overlay: Y admitted → FAIL |
| cap-289 | `GATEWAY_MAX_DEVICES=4` for one run (profile env override via the reconciler's pause flag as rto768 does): the 5th device refused, logged, the listener alive | overlay: n/a (by code) |
| eud-mem-289 | 16 idle devices: ≤ X MiB each (X from rc 1; assert ≤ 4 MiB provisional), back to baseline | overlay: 23 MiB → FAIL at 4 |
| dbdown-289 (tier B) | stop `ots-db` 20 s while 4 devices stream: all CoT stored after it is back | overlay: FK-dropped → FAIL |
| r8-hold-264 | retired with MOUNTSHA (payload-run keeps the mechanism for other tenants; its test stays in test-payload-run) | — |

## 8. Not in scope / leftovers for the user

- Relay semantics (decision 5), `minimal_row` for forwarded uids, Meshtastic bridge: with the Meshtastic work.
- #47 per-node broker/DB credentials; #54 enrolment; CRL in the listener.
- The 1.8 GiB freed in the node budget: left unassigned until #287 measures cot_parser/postgres under load.
- Upstream reports (A6-5, A4-13): after validation, with the gateway's evidence; outside the project repos (ask).

## 9. Open questions for the review

1. Is one AMQP connection for the whole gateway acceptable (a broker-side close now affects every device at once,
   but no session ends) versus one connection per device (the overlay's model, 16 connections)? Proposed: one, with
   the reconnect bounded by backoff; the consumers are re-placed within seconds.
2. M9's 30 s re-assert window vs. an operator's unsubscribe through the API: verified — the API deletes the
   `mission_roles` row before it unbinds (`mission_marti_api.py:1544-1555`), so the gateway's next re-assert computes
   the set without that mission and the unbind holds. Remaining window: an API subscribe/unsubscribe racing a
   re-assert is at most one 30 s cycle out of date, then converges.
3. The startup presence sweep (lifecycle "power loss"): acceptable as the only writer at start?
