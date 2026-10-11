# #264 OTS eud_handler loses CoT — design v5

Status: v5 for review · 2026-10-11 · replaces v4 (REJECT by two reviewers) and v1–v3.2 (branch `feat/264-ots-eud`).

User decisions (2026-10-11):
- Delivery is **at-least-once**: publisher confirms; an occasional duplicate CoT is accepted.
- Every field-relevant defect found in review is fixed here, in #264.
- Stable problems get a root-cause fix. Reconnect and cache are protection layers.

Scope:
- the patched `EudHandler.py` (`deploy/ots/patches/`);
- the OTS manifest and profile;
- one new payload-run manifest key (R8);
- the batman-payload-ots Makefile;
- validation suites and CI.

The rabbitmq and cot_parser containers are not changed.

## 0. Background

Both CoT listeners run upstream OpenTAKServer 1.7.13 `EudHandler.py`: 8088 TCP and 8089 mTLS, where
`EudHandlerSSL` subclasses it. Upstream master on 2026-10-08 is the same.

Process model:
- `socketserver.ForkingTCPServer` (`EudServer.py:6`) forks one child per client session.
- Each child has a socket thread and a pika 1.3.2 `SelectConnection` ioloop thread.
- Sessions publish CoT to the `cot_parser` exchange. `ots_cot_parser` consumes the `cot_parser` queue and
  writes to postgres.

Measured on 04 (shipped 1.5.8-wsl.5):
- Each eud container has a 512 MiB limit.
- `memory.current` is 189 MB idle and 229 MB with one streaming client; 8 idle sessions measured +39 MB each (R7, fixed).
- Broker heartbeat 60 s.

## 1. Problems and fixes

### R1 — partial messages discarded (mechanism A)
- **Cause:** `handle()` keeps a partial message and then wipes it (upstream `:125-128`).
- **Reproduced:** P2B 0/20 on 8088 and 8089; 20–60 % loss on a coalesced stream.
- **Fix (v3.2 code, kept):**
  - Keep raw bytes until a closing tag; decode only complete messages; carry the remainder to the next recv.
  - The carry-over is bounded by `MAX_PENDING` = 1 MiB.
- **Test:** `ots-cot-e2e-264` and `-ssl`, P2B/P3 sent == stored. Negative control: unpatched gives 0/20.

### R2 — not in this change (user decision 2026-10-11)
- The natural cause of the one `missed heartbeats` event seen in the shipped soak is left unattributed (❓).
- Its consequence (a broker-side close) is covered by R4/R4b.
- `soak-cot-264` counts heartbeat closes per session. If they recur, they are handled later on that evidence,
  as a #264 checklist item.

### R3 — AMQP channel use only on the ioloop thread (kept from v3.2)
- **Cause:** upstream publishes from the socket thread (`:469`, `:477`), but pika connections are not
  thread-safe.
- **Fix:** every channel operation runs on the ioloop thread via `_io()` (`add_callback_threadsafe`). Session
  state is per instance.

### R4 — broker-side connection loss: reconnect (protection layer)
- **Cause:** upstream `on_close` stops the ioloop and ends the client session (`:325-327`).
- **Reproduced:** with `rabbitmqctl close_connection`, the client session is ended and in-flight CoT are lost,
  every time.
- **Fix:**
  - **Reconnect on the same ioloop.** A new `SelectConnection(..., custom_ioloop=<same ioloop>)`. Reviewer A
    verified that pika 1.3.2 never stops the ioloop on a connection close (`base_connection.py:367-377`,
    `connection.py:2005-2091`).
  - **Backoff with jitter:** 1, 2, 4, 8, 16, 30 s ±25 %. It runs while the client session lives. The timer is
    cancelled when the client leaves.
  - **On every channel open, in this order:**
    1. declare the exchanges and the `cot_parser` queue and binding (R5);
    2. replay the session's subscription;
    3. **only after the last DeclareOk/BindOk/ConsumeOk**, flush the cache. The steps are chained by callbacks.
  - **Replay failures:** a channel error during replay counts as a replay failure. After 3 consecutive
    failures, the subscription is dropped with an error log. The session keeps publishing (storage still
    works) and the replay is never looped.
  - **`on_channel_close` no longer sets `shutdown`.** `_reconnect` checks `_closing`.
- **Test:** `amqp-close-264`.
  - Steps: stream, then `close_connection` on the session's own connection, found by `connection_name` =
    `eud-<port>-<uid>` set in `client_properties`.
  - Asserts:
    - no client reconnect;
    - sent ≤ stored, with duplicates counted (at-least-once);
    - a CoT addressed to the session reaches its socket after the reconnect.
  - Negative control: unpatched gives reconn = 1 and loss.

### R4b — at-least-once delivery
- **Fix:**
  - `confirm_delivery` on each channel.
  - Each publish to `cot_parser` keeps its serialized body until Basic.Ack, keyed by delivery tag.
  - On Nack, return or connection loss, every unacked body goes back to the head of the cache.
  - Duplicates are possible after a reconnect. cot_parser inserts each message as a row, so a duplicate becomes
    a second row with the same `uid`/`time`. This is accepted and stated in the PR.
- **Residual loss, stated and not hidden:**
  - CoT already in the transient `cot_parser` queue but not yet processed are lost when the broker restarts.
    This covers the parser's prefetch of 2 and any backlog.
  - On a container stop, the forked children are SIGKILLed when the parent exits, so their caches are lost.
  - cot_parser drops a message it cannot insert (`basic_nack(requeue=False)` when the DB is down,
    `cot_parser.py:1285-1288`). That is cot_parser's behaviour, unchanged here, listed in the lifecycle table.

### R5 — the `cot_parser` queue missing after a broker restart (mechanism C)
- **Cause:**
  - the queue is transient and declared only by cot_parser (`cot_parser.py:90`);
  - the exchange is durable;
  - after a broker restart, a publish lands before the parser re-declares the queue, finds no queue, and is
    dropped.
- **Reproduced:** single-variable flip with eud_handler already running: queue present stored 1, removed 0, back
  1 (wsl.4 and wsl.5). cleanstop-274 lost its early CoT on 2 of ~12 boots.
- **Fix (root cause):**
  - On every channel open, eud declares `exchange_declare("cot_parser", direct, durable=True)` and
    `queue_declare("cot_parser")` with the **identical default arguments** of `cot_parser.py:90`, plus the same
    binding.
  - An identical redeclare is idempotent and accepted.
  - The queue then exists before the first publish of any session, and the broker buffers CoT while
    cot_parser is down (CQv2 pages to disk; per-message TTL 24 h).
  - Two declarers with identical arguments, eud and cot_parser, is safe; this is stated in the ownership table.
- **Protection:**
  - `mandatory=True` and a return callback.
  - A returned body goes back into the cache.
  - Retry is **head-only** with backoff (2, 4, 8 s): one message is re-sent, and the rest flush only after it is
    acked without a return. This avoids a return storm.
- **Assumption to verify by test (not yet probed; scratch-broker probes failed on node networking):** an
  identical second declare is accepted, and a mandatory publish with no bound queue is returned and then acked.
  The `queue-gone-264` negative control and the `amqp-*` suites prove it on the real broker.
- **Test:** `queue-gone-264`.
  - Steps: delete the `cot_parser` queue with `rabbitmqctl delete_queue` while the parser is running, then
    stream.
  - Asserts: everything sent is stored, because eud re-declares on its next channel open, or the return path
    fires.
  - Negative control: unpatched loses CoT.
  - The test stays inside the broker and never starts or stops containers (R-tests).

### R6 — sessions that outlive a lost client (network loss without a FIN)
- **Cause:** client sockets have no keepalive and no timeout (`EudHandlerSSL.py:20`, `settimeout(None)`;
  `tcp_keepalive_time` = 7200). A HaLow link loss, roaming or a phone switched off leaves the session alive
  indefinitely.
- **What goes wrong:**
  - Its consumers stay on the per-EUD queues, which the reconnected live session also consumes, so messages are
    shared between the two.
  - When the old session finally closes, its unbind (upstream `:759-774`) removes bindings the live session
    shares.
- **Reproduced on node 04, upstream 1.7.13, 2026-10-11 (scratchpad `264/zombie-repro2.log`):** B = live reading
  session of EUD X gets 10/10 of another EUD's plain CoT. A = stale session of X, its port black-holed on the
  bench node both ways: 30 s later the server still holds A (4 consumers on X's queue, 2nd AMQP connection) and
  B gets **0/10** (the deliveries went to the zombie, `auto_ack`). When A's socket finally closes (FIN), X's
  queue keeps only its default-exchange binding and B gets **0/10 for good** (cot_parser's `send_disconnect_cot`,
  `cot_parser.py:944-1033`, unbinds `<uid>` from every group and mission on the disconnect message, and
  upstream's close unbound dms/groups/missions as well).
- **Fix (root cause, `BATMAN-264-R6`, implemented after the reproduction):**
  - `SO_KEEPALIVE` with `TCP_KEEPIDLE` 45 s, `TCP_KEEPINTVL` 15 s, `TCP_KEEPCNT` 4 **and `TCP_USER_TIMEOUT`
    120 s** on every accepted socket, set in `setup()` before the SSL wrap (the options survive it). The kernel
    sends no keepalive probe while data is unacknowledged (review v5A-F1/v5B-M1: with other clients on the node
    the server is always writing to the zombie), so the user timeout is the bound that matters: a vanished peer
    ends its session in about 2 minutes either way. A `send()` blocked on the zombie's full buffer (the R2 stall)
    is bounded by the same 120 s: the write fails, `on_message` closes the session.
  - **Session end is guarded (B1):** on the ioloop, cancel this session's consumers, `queue_declare(passive)`
    the `<uid>` queue; only when `consumer_count` is 0 publish the disconnect message and unbind. With another
    live session of the same EUD: log `another session of <uid> is live: no disconnect, bindings kept`, close
    the channel. cot_parser therefore never sees a disconnect for an EUD that is still connected, so its own
    unbinds never run against a live session. A never-identified session (uid None) takes upstream's path.
- **Residual, stated:** deliveries during the zombie's last ~2 minutes go to the zombie and are lost (`auto_ack`
  round-robin); the live session is not told. An exclusive consumer would refuse the reconnecting phone instead,
  so not done. Other writers of the per-EUD bindings (group/mission APIs, register v5B-B1) are unchanged; they
  act on operator actions, not on session ends.
- **Test:** `zombie-264` (daily-validation tier A, about 4 min, `scripts/node/zombie-264.sh` on the bench node).
  - B live reading session of X; phase 0: 10 CoT from C → B 10/10.
  - A = second session of X, its port black-holed on the bench node both ways: own nft table `dvz264`, set
    elements with a 240 s timeout and a detached `delete table` after 300 s (review v5B-M8: nothing can stay
    behind if the harness dies); D streams 1 CoT/s for 150 s so data is pending towards A.
  - Asserts: X's queue goes from 2 consumers (A+B) to 1 within 180 s (A reaped); then phase 2: 10 CoT from
    C → B 10/10 (bindings kept); peer cleanup `LEFT 0`; the run's rows and queues removed.
  - Negative control: upstream, measured above (zombie outlives the black hole with its consumers; B 0/10 after
    A's end). Offline: 4 cases in `test-eudhandler-264-amqp.py` #9 (socket options; last session vs another
    consumer live vs uid None).

### R7 — memory per session (measured 2026-10-11 on node 04, implemented e106c04)
- **Step 1, measured with N clients (scratchpad `264/r7-mem.log`):** 8 idle 8088 sessions (one CoT each, then
  silent) took `ots_eud_handler` from 152.8 MB to 464.6 MB of `memory.current` = **39 MB per session**, back to
  153.8 MB after they left (no leak). Every child had `VmRSS` 132 MB (mostly pages shared with the parent; the
  cgroup counts the copied ones). `memory.max` 512 MiB, `oom_kill 0` so far: the 10th client would have been the
  OOM kill of the whole container (PID 1 = every session).
- **Attribution (throwaway container from the same image, `r7-attr.py`, two repetitions each):**

  | child does | cost |
  |---|---|
  | nothing (fork only) | 2.5 MB |
  | `gc.collect()` | 58.7 MB (the collector writes every gc header, so the parent's pages are copied) |
  | parent `gc.freeze()` first, then child `gc.collect()` | 2.6 MB |
  | `create_app()` (Flask + SQLAlchemy + flask-security) | 28.6 MB |
  | parent-built app shared, child `gc.collect()` with freeze | 2.6 MB |

  The 39 MB is create_app (28.6) plus the gc copies the child's own allocations trigger, plus pika/thread.
- **Fix (overlay, `BATMAN-264-R7`):**
  - `create_app()` reuses the app `eud_handler.py` already builds in the parent (`app = create_app()`, handed to
    the server as `app_context`); the child only disposes the inherited SQLAlchemy pool (`dispose(close=False)`:
    the parent's sockets, if any, are not closed). `config.yml` is now read when the handler process starts, not
    per session (the parent already reads it the same way).
  - `os.register_at_fork(before=gc.collect+gc.freeze, after_in_parent=gc.unfreeze)`: the child's collector never
    touches the parent's heap.
  - **Session cap, fail-closed:** `setup()` reads the container's own `/sys/fs/cgroup/memory.current|max` first;
    with less than `BATMAN_264_SESSION_RESERVE_MB` (40) left it logs `refusing session from <ip>` and closes the
    socket before any allocation, AMQP connect or declare. No cap when the cgroup is unreadable or unlimited
    (nothing to derive it from). The check is in the child after the fork (a fork is 2.5 MB with the freeze), so
    the parent keeps accepting and a client at the limit sees one refused connection instead of the kernel killing
    the container; the guardian never sees a crash, so no DRIFT and no OTA revert from a session flood.
- **What it does not do (register v5A-F2 / v5B-M6):** the SSL handler still runs `setup()` (now cheap) and the
  AMQP connect before `do_handshake()`; moving the handshake first needs the `EudHandlerSSL` overlay (F9). No
  per-source-IP cap and no pre-identification idle timeout: a dead peer is R6's keepalive; a silent *live* peer
  costs one session and is bounded only by the memory cap.
- **Tests:** `eud-mem-264` (daily-validation, tier A): 6 idle sessions from the bench node, <= 12 MiB per session
  (negative control: upstream 39, measured above), none refused, back within 15 MiB of the baseline after the
  clients leave, the run's EUD rows and rabbit queues removed. The cap itself: 5 offline cases
  (`test-eudhandler-264-amqp.py` #8) with the cgroup reader stubbed; on the node the refusal would need about 60
  sessions after the fix and is not exercised (stated, not claimed).
- **The cache bounds in R9 are sized against the measured per-session figure.**

### R8 — the patch must fail closed at runtime when the image changes
- **Today:** the sha check is CI-only and is not even wired into a workflow. At runtime, a re-tagged image with
  different upstream code would either run unpatched or be overwritten by an old patch.
- **Fix:**
  - New manifest key `MOUNTSHA <basename> <sha256>` on the containers that mount a code overlay. On every
    rebuild, payload-run reads the image's own file at the mount target (`docker run --rm --network none
    --entrypoint sha256sum <image> <target>`) and refuses the rebuild if it differs. The guardian then reports
    DRIFT.
  - The patched module logs `BATMAN-264 active upstream=<sha>` once at import. payload-conform asserts the log
    line exists for both eud containers.
  - The CI triggers include `deploy/ots/patches/**`, and the workflow runs `check-eudhandler-264.sh`.
- **Owner:** payload-run (from #274) stays the only container starter; this is one more refusal reason in its
  preflight.
- **Negative control:** a manifest with a wrong `MOUNTSHA` makes payload-run refuse, and DRIFT is reported.

### R9 — cache content and bounds
- **What is cached:** the serialized `(exchange, routing_key, body)` tuples, never BeautifulSoup objects. Reviewer A
  measured a cached parsed Tag at 25× its text size.
- **Bounds:** per session, entries `CACHE_MAX` and bytes `CACHE_MAX_BYTES`, both sized from the R7 measurement.
  Initial value 2 MiB per session.
- **Overflow:**
  - Coalesce position reports, keeping only the newest `a-*` event per uid.
  - Then drop the oldest, with an error log and a dropped-count line at session end.
  - The session is not closed (closing would drop the whole cache at once).
- **Firehose:** a firehose publish is never re-sent, only the `cot_parser` body, so there are no firehose
  duplicates from returns.
- **Broker flow control:** `add_on_connection_blocked_callback`. While the broker is blocked (memory alarm,
  `rabbitmq-extra.conf` 300 MB), the session caches instead of publishing. `blocked_connection_timeout` = 60 s
  ends the connection, and R4 reconnects.

### R10 — client-supplied identifiers used as broker resource names
- **Cause:** upstream uses the client-supplied callsign and uid directly as queue names and routing keys
  (`parse_device_info`, `:512-650`). On 8088 the client is unauthenticated.
- **Fix:** before any declare, bind or consume, validate both values. Reject:
  - empty values;
  - values over 255 bytes UTF-8;
  - values starting with `amq.`;
  - values equal to any broker resource OTS itself uses (`cot_parser`, `firehose`, `dms`, `groups`, `missions`,
    `chatrooms`, `flask-socketio`).

  For a rejected value, the session does not subscribe and logs an error. Its CoT are still stored.
- **Test:** `names-264`: a client with a reserved callsign. Asserts:
  - no per-EUD subscription is created;
  - the reserved queue's consumer count is unchanged;
  - its CoT are stored;
  - a normal client is unaffected.

  Negative control: unpatched creates the subscription.

### R11 — diagnosis aid
- `faulthandler.register(SIGUSR1, all_threads=True)` at module import, so the parent is covered too.
- Dumps go to the container log.
- The harness signals only processes whose PPid is the eud parent, never the container's PID 1.

## 2. Ownership

| resource | owner (writes) | readers / notes |
|---|---|---|
| golden `EudHandler-264.py` | the build | 95-batman-storage refresh |
| p6 `apps/opentakserver/EudHandler-264.py` | golden refresh at boot; D7-7 reports DRIFT if it differs | payload-run (MOUNT source) |
| `MOUNTSHA` value | the manifest (golden) | payload-run (preflight refusal) |
| the bind mount | payload-run | containers, ro |
| one session's AMQP connection, channel, cache, unacked set, subscription | that forked child, ioloop thread only | — |
| client socket of a session | that child (upstream behaviour unchanged; R2 not in this change) | — |
| `cot_parser` exchange, queue and binding | two idempotent declarers with identical arguments: cot_parser (upstream) and eud (R5) | broker |
| per-EUD queues and bindings | the session that identified the EUD. With R6, at most one live session per uid after ~60 s. Unbind only when there are no consumers. | web/API, other sessions (publish) |

## 3. Contracts

- **MOUNT and MOUNTSHA** (R8): valid only when the image's file sha256 equals `MOUNTSHA`. Otherwise payload-run
  refuses the rebuild. This is fail-closed: the old containers keep running and the guardian reports DRIFT.
- **AMQP towards cot_parser:**
  - same exchanges, routing keys and TTL property;
  - plus `mandatory` and confirms on the eud side;
  - at-least-once: a message can arrive later, and duplicates are possible after a reconnect;
  - order is not guaranteed across a reconnect;
  - replayed CoT may already be stale when cot_parser routes them (`route_cot`); this is stated.
- **Client session:** no longer ended by a broker-side close. It ends when the client leaves, on keepalive
  failure, or when the container stops.
- **Log lines other tools read:**
  - `Failed to parse` (ots_logc, info);
  - `RabbitMQ channel is closed, not publishing cot`, which now appears only when a CoT is **dropped**;
  - new: `cache overflow dropped=N`, `BATMAN-264 active upstream=<sha>`.

  `ots_logc` reads the TCP **and** SSL logs.

## 4. Lifecycle

| path | today | after | test |
|---|---|---|---|
| first boot / firstload | C window at broker start | eud declares the queue on its first channel open | cleanstop-274 step 6, queue-gone-264 |
| boot / reboot / power loss | C window every boot | as above | cleanstop-274, unclean-boot-274 |
| clean stop / OTA | children SIGKILLed after the parent exits; caches lost | same; stated as residual | cleanstop-274 (no regression) |
| autocommit trial | — | unchanged; the R tests never restart tenant containers, so they leave no DRIFT ledger | fi-s1 |
| restart of eud container (guardian) | clients reconnect | same | crash-274 |
| broker-side connection close (heartbeat) | session ends, CoT lost | reconnect, at-least-once | amqp-close-264 |
| broker restart (crash, guardian) | sessions end; C window; cot_parser exits (its BlockingConnection has no reconnect) and the guardian restarts it with backoff | sessions stay; eud re-declares the queue; the broker buffers until the parser is back; transient-queue backlog lost (residual) | `amqp-restart-264` (destructive: `docker kill rabbitmq`, the guardian restarts it, the ledger and DRIFT lines are asserted) |
| broker memory alarm | publishers blocked; pika buffers grow | cache instead; timeout → reconnect | covered by R9 unit test (fake connection) |
| cot_parser restart | queue persists while the broker is up | same | — |
| ots-db down | cot_parser nacks and drops (upstream) | unchanged; residual, stated | — |
| client network loss | session lives for hours | gone in ~60 s | zombie-264 |
| N concurrent clients | +39 MB each (measured), OOM kill of the container at ~10 | a few MB each; over the memory reserve a session is refused and logged | eud-mem-264 + offline cap cases |
| image changed under the patch | runs unpatched or the old patch overwrites newer code | refused at rebuild, DRIFT | MOUNTSHA negative control |
| downgrade to an image without the change | — | the old payload-run ignores `MOUNTSHA`? **must be checked**; the D6 prune deletes the p6 file once `.golden-files` lists it | first-ota / downgrade |
| bcm2711 / bcm2710 | — | the OTS package is bcm2711 only (`DEPENDS:=@TARGET_bcm27xx_bcm2711`); Pi 3 not applicable | ab-card |

## 5. Assumptions with evidence

- pika 1.3.2: `custom_ioloop`, `mandatory`, `add_on_return_callback`, `confirm_delivery`,
  `add_on_connection_blocked_callback`, `blocked_connection_timeout` (probed and source lines, reviewers A/B).
- pika never stops the ioloop on a connection close (reviewer A, source lines above).
- `ForkingTCPServer`, PID 1 python, StopSignal SIGINT (probed).
- The image's `.pyc` uses timestamp invalidation, so a mounted source is recompiled (reviewer B probe).
- The `cot_parser` exchange is durable and its queue transient; TTL 86400000 ms (probed).
- To verify by the suites' negative controls (not yet probed): identical-redeclare acceptance and mandatory
  return-then-ack on 4.3.6.

## 6. Security

- **Assets:** CoT confidentiality (8089 users) and availability; the node itself is unchanged.
- **Remote client, including unauthenticated on 8088:**
  - R10 closes the use of its identifiers as broker names.
  - R9 bounds its memory per session.
  - It cannot trigger a reconnect loop: replay failures are bounded (R4).
- **Compromised tenant:** no new interface.
- **Local non-root process:** none. Files are root-owned, mounted ro, and D7-7 reports DRIFT on an edit.
- **Supply chain:** the patch is generated from the pinned upstream; R8 enforces the pin at runtime.
- **Attack-surface delta:** none new (same ports and credentials); R10 reduces it.
- **Failure modes:**
  - image mismatch: fail-closed (refuse);
  - broker away: cache with bounds, then counted drops.

## 7. Tests and registration

| suite | tier | destructive | negative control |
|---|---|---|---|
| ots-cot-e2e-264 (8088), ots-cot-e2e-264-ssl (8089) | feature | no | unpatched P2B 0/20 |
| amqp-close-264 | feature | no (broker-side close only) | unpatched reconn = 1 + loss |
| queue-gone-264 | feature | no (`delete_queue` only) | unpatched loss |
| amqp-restart-264 | feature | yes (`docker kill rabbitmq`; guardian restart; DRIFT expected) | unpatched sessions end + loss |
| zombie-264 | feature | yes (peer firewall rule, removed in cleanup) | unpatched old session persists |
| names-264 | feature | no | unpatched subscription created |
| mountsha (in payload-conform / R8 suite) | feature | no | wrong sha → refuse |
| soak-cot-264 | soak | — | every sent CoT stored (duplicates counted, at-least-once); heartbeat closes recorded per session (info, R2) |
| offline: test-eudhandler-264.py (+ fake-pika state machine for R4/R4b/R5/R9) | CI | — | each case fails on the unpatched module |

Every suite deletes the per-EUD queues and DB rows it created, and its cleanup FAILs if anything is left. The
2026-10-11 residue queues on 04 are removed once, with the list printed first. The #264 known-failure entries
are removed when the suites pass.

## 8. Not in scope

- The upstream report and PR: outside the project's repos; asked separately after validation.
- The UDP listener: its port is not exposed.
