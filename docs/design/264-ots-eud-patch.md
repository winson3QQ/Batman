# #264 OTS eud_handler loses CoT — design v5

Status: v5 for review · 2026-10-11 · replaces v4 (REJECT by two reviewers) and v1–v3.2 (branch `feat/264-ots-eud`).
Revised after code review rounds 1–3 (2026-10-12, f3f7c9d); every finding and its status is in
`264-review-register.md`.

User decisions (2026-10-11):
- Delivery is **at-least-once**: publisher confirms; an occasional duplicate CoT is accepted.
- Every field-relevant defect found in review is fixed here, in #264.
- Stable problems get a root-cause fix. Reconnect and cache are protection layers.

User decisions (2026-10-12, code review rounds 2–3):
- The criterion: the user experience stays stable over time and no resource is consumed for nothing.
- Findings are classed A (#264 itself), B (upstream, unrelated to the symptom), C (caused by our change). From
  round 4 on, a new B finding is recorded as a leftover and does not block the merge; A and C are fixed.
- Capacity target: **16 phones** on the node at once.
- After a broker-side loss the client session ends once its cache is delivered (R13, "end-on-loss"); no replay.
- An 8089 session may not claim the uid of another user's device; callsigns stay shared as upstream (R10).
- Field tests with real ATAK/iTAK devices are deferred (not enough devices now): a #264 leftover.
- (Review round 5) Accepted as stated, with the reasons given in the register (A4-4: a node-wide OOM takes phone
  sessions before the node's daemons; A4-9: the definitions file owns the broker credential, #47 must change both;
  A4-10: an away 8089 device re-subscribes its missions after 24 h; B4-7: a re-issued 8089 phone needs an admin
  reassignment; A4-6: what a server-side close leaves unread is the client's to re-send, as decision 2).
- (Review round 4) A device refused by R10 for a colliding callsign is still RECORDED: its own row, its own `<uid>`
  queue only. CoT lost while the mesh path to OTS is down are lost: re-sending them is the client's job (the server
  keeps R6's ~2 min reap; it does not hold sockets open to catch retransmissions).

Field scenario (the user, 2026-10-12): off-grid tactical team. Each member carries a node and their phone joins
that node over Wi-Fi (or BLE) and runs a TAK client. All nodes move; the OTS node is carried by the RTO.
Meshtastic is the fallback when HaLow is jammed (positions and short messages). Batteries are swapped when flat.
OTA happens during maintenance, not on missions. **After the mission the review must restore every record**;
a few duplicate rows are acceptable. **OTS runs only on Pi 4 8 GB.** A 48-hour duty soak (16 clients, 2 CoT/min)
is scheduled after this issue as #287.

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
- Each eud container had a 512 MiB limit (now 1280m, R16).
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

### R4 — broker-side connection loss: reconnect (protection layer; revised by R13)
- **Revised (review r3 A3-3, the user's decision 2026-10-12):** the reconnect now serves only to deliver the
  session's cache; then the client session ends (R13). The replay of a recorded subscription described below is
  gone: it silently lost bindings made after identification (Marti API missions/groups). The text below is the
  round-1 mechanism, kept for the reconnect, backoff and open-error parts, which still apply.
- **Cause:** upstream `on_close` stops the ioloop and ends the client session (`:325-327`).
- **Reproduced:** with `rabbitmqctl close_connection`, the client session is ended and in-flight CoT are lost,
  every time.
- **Fix:**
  - **Reconnect on the same ioloop.** A new `SelectConnection(..., custom_ioloop=<same ioloop>)`. Reviewer A
    verified that pika 1.3.2 never stops the ioloop on a connection close (`base_connection.py:367-377`,
    `connection.py:2005-2091`).
  - **Backoff with jitter:** 1, 2, 4, 8, 16, 30 s ±25 %. It runs while the client session lives. The timer is
    cancelled when the client leaves.
  - **On every connection open (as implemented, c5eb1ea/a978af2):** the `cot_parser` declare runs on its own
    channel (R5); on the publishing channel: `Confirm.Select`, the unacked bodies of the previous channel go
    back to the cache head, the subscription is replayed, then the cache is flushed. The steps are not chained
    by callbacks: with confirms, a publish that lands on a channel the replay then breaks is simply unconfirmed
    and goes back to the cache, so nothing is lost by flushing early (review v4B-4).
  - **Channel closed while the connection lives** (refused declare, bad name on replay): the channel is
    reopened on the same connection and the subscription replayed. **Three channel closes within 60 s end the
    session loudly** (the client reconnects clean) instead of a session that looks connected and receives
    nothing (review v5B-M2).
  - **Broker down at connect or reconnect:** `on_open_error` retries with the same backoff instead of ending
    the session (upstream let pika's default raise inside the ioloop).
  - **`on_channel_close` no longer sets `shutdown`.** The reconnect, open-error and close paths check `_closed`.
- **Test (as of R13):** `amqp-close-264` asserts the opposite of the round-1 text below: the client sees the drop
  (`CONNLOST`) only after the cache was delivered, every CoT sent before it is stored, and the handler logs the R13
  line. Negative control: rc wsl.10 (the session was kept, no R13 line). Round-1 text:
  `amqp-close-264` (daily-validation tier A, about 90 s): one session streams 120 unique CoT at 2/s
  from the bench node (`scripts/node/cot-stream-264.sh`); at 15 s and 35 s the harness closes that session's
  broker connection with `rabbitmqctl close_connection`, found by the client's peer address (so the negative
  control finds an unpatched session too, review v5A-F7; the `connection_name` is
  `eud-<listener port>-<client ip>:<client port>`, no client-controlled value). Asserts: both closes landed, the
  client's TCP session never dropped (`CONNLOST` = FAIL), `distinct(uid) == sent` with duplicates reported,
  two reconnect lines in the handler's log file, rows and queues removed. Negative control measured on
  upstream (2026-10-11): the session ends, the client sees the drop, the CoT in flight are lost.

### R4b — at-least-once delivery (as implemented, c5eb1ea/a978af2)
- **Fix:**
  - `confirm_delivery` on the publishing channel. Every publish on that channel is numbered as the broker
    numbers it (firehose, flask-socketio and the disconnect message included); the `cot_parser` bodies are
    kept until their Basic.Ack, `multiple=True` honoured; numbering restarts with every channel.
  - A Basic.Nack puts only the nacked bodies back at the head of the cache and schedules the head retry.
  - A `basic.return` carries no tag: the returned body is matched to its unacked entry by content and marked,
    so the ack that follows a return is not counted as a delivery (the body is already back in the cache).
  - On any channel close or connection loss, the unacked bodies (not the returned ones, already cached) go back
    to the cache head in publish order.
  - **Order:** a new body queues behind a non-empty cache (a return retry or a reconnect flush in progress);
    only the head retry goes ahead. Old PLI never lands after newer PLI of the same session.
  - **Bound:** with `CACHE_MAX` publishes unconfirmed, further bodies are held in the cache (the same bound)
    and released in order as acks arrive; the unacked set can never exceed the cache budget.
  - **Session end (review round 2, A2-4/A2-6/A-F18):** `close_connection` starts the end exactly once (a lock:
    the handler thread, the ioloop on a send failure and the channel-error rule can all call it). The end runs on
    the ioloop: the cache is flushed and the end WAITS until every body is acked (a body returned during the end
    goes back to the cache and is retried; a broker that is away is reconnected for it), bounded by `DRAIN_MAX_S`
    (60 s, then the counts are logged and the session ends anyway). Only then the R6 session end runs. The
    handler thread always waits for the end (`_wait_end`, at most 70 s), whoever started it, so the forked child
    never `os._exit`s with the drain or the goodbye in flight; intermediate channel/connection closes no longer
    release it (the old "drained" latch did).
  - Duplicates are possible after a close (a publish acked after it was re-cached). cot_parser inserts each
    message as a row, so a duplicate becomes a second row with the same `uid`/`time`, and `route_cot` re-sends
    it to DM and group recipients (review v5A-F16). This is accepted and stated in the PR. R9 coalescing uses
    insertion order, not the CoT `time`.
- **Residual loss, stated and not hidden:**
  - A server-side close (R13, the R12 deadline, the channel-error rule, R6's reap) loses what the server had not
    read yet: complete messages still in the session's buffer and bytes in the kernel's receive queue (review r4
    A4-6/B4-6). R13 loses nothing the server had already read. Re-sending is the client's job (the user, 2026-10-12).
  - A mesh outage longer than ~2 min: the session is reaped (R6) and what the phone sent meanwhile is lost unless
    the client re-sends it (the user's decision, review r4 B4-3).
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
- **Probed on the live broker (2026-10-11, read-only, #264 comment 6103334725):** an identical second declare
  (including the server-added `x-queue-type`) is accepted, a different one is 406; a mandatory publish with no
  bound queue is returned and then acked, the message preserved. Scratch-broker probes on the node and in WSL
  failed (docker `iptables=0`, erlang cookie), so this is the evidence.
- **Test:** `queue-gone-264`.
  - Steps: delete the `cot_parser` queue with `rabbitmqctl delete_queue` while the parser is running, then
    stream.
  - Asserts: everything sent is stored, because eud re-declares on its next channel open, or the return path
    fires.
  - Negative control: unpatched loses CoT.
  - The test stays inside the broker and never starts or stops containers (R-tests).

### R6 — sessions that outlive a lost client (network loss without a FIN)
- **Order (review r4 B4-11):** a subscription is placed as declares, then consumers, then bindings, so an old
  session's end (which judges "last" by the consumer count) sees the new session before its bindings exist.
- **A session that never subscribed (review r3 B3-10):** at its end, an identified session that is not refused
  declares its `<uid>` (not passively: a missing queue must not close the channel) and sends the disconnect when
  nobody consumes it, so its EUD row does not stay "Connected"; never for a refused uid (r2 B2-1). The queue that
  declare re-created is removed again when idle, empty and unowned (review r5 B5-11).
- **The end after a broker restart (review r5 A5-3/B5-5):** every end declares its queues normally, not passively:
  the per-EUD queues are transient, so after a broker restart (or after the other device of a shared callsign deleted
  the callsign queue) a passive declare was a 404 that closed the channel: no disconnect, a ghost "Connected" row.
  The handler waits up to 2 x DRAIN_MAX_S + 10 s, room for the one retried goodbye (review r5 A5-7).
- **F3 and an owned uid (review r3 B3-7):** an 8088 session never deletes `<uid>` when that uid's EUD row has a
  user (cot_parser's 8089 disconnect binds it); one database lookup at the end, kept on a lookup failure.
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
  - **Shared queues (review round 2, B2-1/B2-4/A2-2/A2-3, all reproduced on node 04 with rc wsl.8):** a
    reconnecting phone and a second device with the same callsign are subscribed AT ONCE, next to any other
    consumer, as upstream did. The round-1 "busy" guard (wait until the other consumer is gone) was removed: it
    left the second device with no downlink for its whole session (measured 0/10), and the stale session, being
    the only consumer, always took itself for the last one and sent cot_parser the disconnect that unbinds an
    8089 user's missions.
  - **Session end is guarded:** on the ioloop, cancel this session's consumers, then `queue_declare(passive)` the
    `<uid>` and `<callsign>` queues. The `<uid>` queue's consumer count decides: another consumer -> log
    `another session of <uid> is live: no disconnect, bindings kept`; none -> publish the disconnect and unbind
    this session's bindings, except the `<callsign>` binding while another device still consumes that queue.
    cot_parser therefore never sees a disconnect for an EUD that is still connected.
  - **Only what the session placed (B2-1):** the bindings are recorded when the subscription is actually placed.
    A session that never subscribed (a refused name, a refused owner) removes nothing and sends no disconnect for
    the uid (measured on wsl.8: such a session's end took the live session's dms/`__ANON__`/missions bindings,
    0/10). A relay platform (Meshtastic/ICU/DMRCOT, no queues of its own) and a never-identified session keep
    upstream's disconnect.
- **Orphan queues (review F3):** the last session of an **8088** EUD deletes its idle queues (`if_unused`,
  `if_empty`; a queue holding messages stays, TTL 24 h); the `<uid>` queue last (a broadcast landing in it between
  the check and the delete makes the broker refuse with 406, which closes the channel and drops every later delete;
  rc wsl.7, register impl-4). **An authenticated (8089) session's queues are never deleted** (review round 2,
  A2-1, reproduced under load on wsl.8: cot_parser's 8089 disconnect branch BINDS `<uid>` to the user's groups,
  `cot_parser.py:989`; on a deleted queue that is a 404, the channel closes, `basic_nack` raises, the container
  exits and the unacked disconnect is redelivered first: 6 crashes until the group membership was removed). Their
  orphans are bounded by the enrolled devices.
- **Residual, stated:** while the zombie lives (~2 minutes) deliveries alternate between it (lost, `auto_ack`)
  and the live session; an exclusive consumer would refuse the reconnecting phone instead, so not done. Two
  devices sharing a callsign that end at the same instant both see the other consumer and both keep the callsign
  queue (an empty orphan). A `<uid>` queue kept because it held messages becomes an empty orphan once they expire.
  Other writers of the per-EUD bindings (group/mission APIs, register v5B-B1) are unchanged; they act on operator
  actions, not on session ends.
- **Tests (each FAILs on rc wsl.8, measured):**
  - `zombie-264` (field order, `scripts/node/zombie-264.sh`): A goes stale (its port black-holed on the bench
    node both ways, own nft table, self-expiring), B (same EUD) reconnects, D streams so data is pending towards A.
    Asserted: 2 consumers at once and a `shared with` line; A reaped within 200 s and its end logs `another
    session of <uid> is live` from A's handler pid; 0 cot_parser disconnects for the uid; then 10/10 for B; the
    last end leaves no empty queue. Upstream: the zombie kept its consumers, B 0/10 after A's end.
  - `same-uid-end-264` (B2-1): a second session of the same uid/callsign connects and leaves; the first keeps
    its bindings and gets 10/10 (wsl.8: 0/10).
  - `callsign-share-264` (B2-4): two devices, same callsign, different uids: 10/10 each, no empty queue left
    (wsl.8: 10/0).
  - `group-disc-264` (A2-1, destructive on a broken build): an 8089 member of a group ends its session while
    cot_parser is busy (600-CoT burst): no `crash ots_cot_parser`, no broker `no queue '<uid>'`.
  - Offline: `test-eudhandler-264-amqp.py` #9 (socket options; last / another consumer live / shared callsign /
    never subscribed / relay / uid None / authenticated: no delete), #14 (end flow), #16 (shared subscribe), #23
    (one end from eight concurrent calls).

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
  - `os.register_at_fork(before=_before_fork)`: once, before the first fork, the parent pre-warms the ORM and
    freezes its heap (`gc.collect(); gc.freeze()`); it is never unfrozen or collected again, so no child's
    collector and no later parent collection writes the frozen gc headers (the first variant that unfroze and
    re-collected per fork cost 78 MB per session, measured).
  - **Session cap, fail-closed:** `setup()` reads the container's own cgroup first (`memory.stat` `anon`, the
    unreclaimable part, against `memory.max`; `memory.current` also counts page cache and would refuse sessions
    after days of log writes);
    with less than `BATMAN_264_SESSION_RESERVE_MB` (40) left it logs `refusing session from <ip>` and closes the
    socket before any allocation, AMQP connect or declare. No cap when the cgroup is unreadable or unlimited
    (nothing to derive it from). The check is in the child after the fork (a fork is 2.5 MB with the freeze), so
    the parent keeps accepting and a client at the limit sees one refused connection instead of the kernel killing
    the container; the guardian never sees a crash, so no DRIFT and no OTA revert from a session flood.
- **Admission before allocation:** see R12 (review round 2, B2-6): the TLS handshake, a per-address limit and a
  first-message deadline now come before anything a session allocates.
- **Tests:** `eud-mem-264` (daily-validation, tier A): 6 idle sessions from the bench node, <= 25 MiB per session (measured 23)
  (negative control: upstream 39, measured above), none refused, back within 15 MiB of the baseline after the
  clients leave, the run's EUD rows and rabbit queues removed. The cap itself: 5 offline cases
  (`test-eudhandler-264-amqp.py` #8) with the cgroup reader stubbed; on the node the refusal would need about 60
  sessions after the fix and is not exercised (stated, not claimed).
- **Second measurement (rc 1.5.9-wsl.4, freeze-once, `eud-mem-264`): 31 MiB per idle session**, memory back to
  the baseline when the clients leave. The first implementation (collect+freeze before every fork, unfreeze
  after) measured 33 MB then 78 MB per session: the parent's full collection after each fork wrote every gc
  header and copied the parent's heap for the parent while children were alive. Fixed by freezing once.
- **Third attribution (`r7-attr3.py`): the first ORM statement in a child costs 19.6 MB** (SQLAlchemy's lazy
  mapper configuration and compiled caches), the engine object 3.9, the XML parser 3.9, pika parameters 3.0;
  with the parent pre-warming these once before the first fork (`_prewarm_parent`: `db.engine`,
  `configure_mappers()`, one EUD select, one XML parse) the same child costs 8.6 MB, idle 2.7 MB. To be measured
  on the node with rc 1.5.9-wsl.6; `eud-mem-264`'s limit stays 12 MiB until then.
- **The cache bounds in R9 are sized against the measured per-session figure.**
- **Capacity (review r3 B3-4; the user's target 16 phones):**
  - Measured on rc wsl.7: **23 MiB per idle session** (`eud-mem-264`: 147 -> 285 MiB with 6). With 111 MiB anon at
    0 sessions and 512 MiB, the reserve refused after about 15 sessions per listener.
  - Mass reconnect (power back, OTA): measured on rc wsl.10, 16 sessions at once all passed a 110 MiB check and
    then used 474 MiB anon of 512 (93 %), 0 refused, 0 OOM: one phone short of the OOM kill of every session.
  - Fix: the eud containers' `memory` is 768m in round 3, 1280m since R16 (profile); admissions are serialized (R12 admission lock) so each
    memory check sees the sessions admitted before it; the listen backlog is 64 (upstream 5 dropped the last ACK
    of a crowd: 10 at once from one address -> 8 accepted).
  - Test: `cap16-264`: 16 identifying sessions at once from two addresses (8 + 8): all subscribed, none refused,
    `oom_kill` unchanged, anon peak <= 85 % of `memory.max`; rows and queues removed. Negative control: rc wsl.10
    (93 %).
  - 4 app containers x 256 MiB more is a limit, not use; the node-wide memory with 16 phones is measured by
    `cap16-264` (container side only, ⚠️ node total not asserted).

### R8 — the patch must fail closed at runtime when the image changes
- **Today:** the sha check is CI-only and is not even wired into a workflow. At runtime, a re-tagged image with
  different upstream code would either run unpatched or be overwritten by an old patch.
- **Fix:**
  - New manifest key `MOUNTSHA <target> <sha256>` on the containers that mount a code overlay (generated from
    `patches/UPSTREAM_SHA256` by profile-to-manifest). In the preflight of every rebuild, payload-run reads the
    image's own file at the mount target without running the image (`docker create --network none
    --security-opt no-new-privileges` + `docker cp` + `sha256sum`, then `docker rm`) and refuses the rebuild if
    it differs; the old containers keep running and the guardian reports DRIFT.
  - No import-time log line (it would not reach the sink before `setup_logging`): payload-conform instead
    reads the overlay where the process reads it (sha256 inside the container == the p6 source, and the
    module-level `BATMAN_264` item list) and the image's own file == MOUNTSHA.
  - The CI triggers include `deploy/ots/patches/**`, and the workflow runs `check-eudhandler-264.sh`.
- **Owner:** payload-run (from #274) stays the only container starter; this is one more refusal reason in its
  preflight.
- **The refused converge (review round 2, B2-5):** when a converge is refused, payload-run starts the EXISTING
  stack on its old config, and docker re-reads a bind-mount source at start: an overlay that the update replaced
  on p6 would run over the OLD image. Before that start, every container with a `MOUNTSHA` is checked against ITS
  OWN image (`docker inspect .Image`, probe by id, no pull); a mismatch or a probe that cannot run keeps that
  container stopped (log `kept STOPPED on its old config`, verdict DRIFT). Fail-closed: code never validated
  against that image never runs; the other containers start as before.
- **The hold (review r3 B3-1, reproduced on rc wsl.10: the guardian's `--restart-exited` started the held
  container 30 s later):** the decision is written to `$RUNDIR/batman-payload-<tenant>.mountsha-hold` (root-only
  run dir, gone at boot) and EVERY later start of this boot honours it (`start_group` skips a held container and
  logs `is held stopped`). Only a converge that succeeds removes it (a preflighted rebuild, or a stack that matches
  the current config). Owner: payload-run writes and removes it; the guardian reads nothing (it runs payload-run).
- **Negative control:** a manifest with a wrong `MOUNTSHA` makes payload-run refuse, and DRIFT is reported;
  `test-payload-run.sh` #28 (the refused converge keeps the mismatching overlay container stopped; fails on the
  previous payload-run, which started it); #29 (the hold survives `--restart-exited` and `--start-only`, a
  successful converge clears it; fails on d7b59d1); `r8-hold-264` (destructive, on the node through the real
  guardian; negative control rc wsl.10).

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
  `rabbitmq-extra.conf` 300 MB), the session caches instead of publishing (R9 bounds) and resumes when unblocked.
  No `blocked_connection_timeout` (review r4 A4-8/B4-5): with R13 it ended every session after 60 s of alarm and the
  drain, which a blocked broker never acks, dropped each cache every ~2 min.

### R10 — client-supplied identifiers used as broker resource names (implemented d129c40 / 9fae867, revised fad4091)
- **Cause:** upstream uses the client-supplied callsign and uid directly as queue names and routing keys
  (`parse_device_info`, `:512-650`). On 8088 the client is unauthenticated.
- **Fix:**
  - Before any declare, bind or consume, both values are checked: empty, over 255 bytes UTF-8, `amq.` prefix
    (any case), a system queue/exchange name (`cot_parser`, `dms`, `chatrooms`, `missions`, `groups`,
    `firehose`, `flask-socketio`, `meshtastic`, `dmrcot`; exact, case-sensitive like queue names, review r2 B2-3)
    or a non-printable character -> no subscription, no EUD row, one error log line.
  - An 8088 client whose uid OR callsign equals the uid OR callsign of an authenticated user's device
    (`EUD.user_id` set) gets no subscription and no EUD row update. Both names are checked against both columns
    (review r2 B2-2, reproduced on wsl.8: a callsign equal to a user's uid consumed the user's `<uid>` queue).
    Fail closed when the lookup fails (retried on the next identifying CoT).
  - **8089 (review r3 B3-5, the user's decision 2026-10-12):** an authenticated session whose uid is the uid of a
    device row owned by ANOTHER user gets no subscription and no EUD row update (reproduced on rc wsl.10: the row's
    `user_id` went from 1 to 2, the device was taken from its user). Callsigns are not checked on 8089: two users
    naming their phones alike is common in the field, and upstream shares them.
  - **A colliding or unusable CALLSIGN (review r4 A4-2/B4-1, the user's decision 2026-10-12):** the callsign is not
    used as a queue (no declare, bind or consume on it, and the end never checks, unbinds or deletes it); the device
    is subscribed by its own `<uid>` and RECORDED. Before, the whole device was refused, it had no EUD row, and
    cot_parser's FK (`CoT.sender_uid -> euds.uid`) dropped every CoT it sent (measured on rc wsl.12).
  - **euds.callsign is UNIQUE** (live `models/EUD.py`): a callsign already held by another device's row made the
    row insert fail and the fallback update match nothing, so the second device of a shared callsign was never
    recorded (upstream; measured on rc wsl.12, callsign-share). Such a device is recorded under its uid without the
    callsign column (its CoT keep their callsign).
  - **A refused uid** (another user's device on 8089, an authenticated user's device on 8088, or not a usable name):
    no subscription and no row update; its CoT go to the existing row of that uid if there is one.
  - **A refused session (fail-secure, stated):** no subscription, so it receives nothing.
    Corrected (review r3 A3-9): the CoT it sends still carry the claimed uid, and cot_parser stores and routes
    them under that uid when its row exists. Track pollution by a client that names another device is upstream
    behaviour on an unauthenticated port; it is a B leftover.
  - The subscription is made once per session (upstream identifies once too); after a broker-side loss the session
    ends (R13) and the phone's new session subscribes from the database. No "busy" refusal any more (R6).
- **Residual, stated:** a phone re-issued to a new user keeps its uid; its 8089 session is refused the
  subscription until an admin reassigns the device in the web UI (recorded, no downlink; review r4 B4-7). A name never
  seen on 8089 (no row with a user) is not protected from an 8088 client that
  connects first (it shares the queue, as upstream); an 8088 session that subscribed before the user's first 8089
  session keeps its share until it ends; the reserved list is a constant in the overlay, not generated from the
  pinned source. Deleting an EUD row (web UI/API) deletes every CoT that device sent (`ondelete=CASCADE`, upstream;
  B leftover, review r4 A4-13). An 8088 client naming an OFFLINE unowned EUD places that EUD's own bindings and removes them at
  its end (review r3 B3-6: a binding is (exchange, queue, key)); DMs to that EUD are unroutable until it
  reconnects (upstream; B leftover). An 8089 user that once used an 8088 phone's name makes R10 refuse that phone
  (review r3 B3-5 residual; B leftover).
- **Tests:** `name-guard-264` (a callsign `cot_parser`: the `cot_parser` queue keeps 1 consumer, "is not used as a
  queue" logged, the device RECORDED; rc wsl.12: 0 stored, rc wsl.13 before its update: the suite still expected the
  old refusal, review r5); `owner-swap-264` (an 8089 user's uid used as an 8088 callsign, and as an 8088 uid:
  both refused, no consumer on the user's queues; wsl.8: the swap was subscribed); `owner-8089-264` (an 8089 user
  claiming another user's uid: refused, none of that user's queues consumed, the row keeps its user; rc wsl.10:
  taken over). Offline #15 (names).

### R11 — diagnosis aid (not implemented)
- Planned: `faulthandler.register(SIGUSR1, all_threads=True)`. It is not in the overlay (`BATMAN_264` lists no R11;
  review r3 A3-11 caught the stale text). No suite depends on it.

### R12 — admission before allocation (review round 2, B2-6; the user's decision 2026-10-12: fixed in #264)
- **Cause:** about 16 idle sockets exhausted the R7 memory reserve and locked every new phone out: an 8088 socket
  that never sends is never closed (no deadline before identification), and the SSL handler allocated the session
  (memory, AMQP connection) before the TLS handshake (`EudHandlerSSL.setup` calls `super().setup()` first).
- **Fix (`BATMAN-264-R12`), order as revised in review round 3 (B3-2: the handshake used to come first, so
  sockets that never finished TLS were bounded by nothing for 10 s):**
  1. At most `BATMAN_264_PER_IP_MAX` (8) established sessions per client address, counted from the container's own
     `/proc/net/tcp`/`tcp6` (the forked sessions share the network namespace; not-yet-handshaken sockets count).
     The mesh routes phones with their own addresses (fw4 masquerades on wan only, checked on the nodes).
  2. The R7 memory reserve.
  3. 8089 only: the TLS handshake (10 s). `EudHandlerSSL.setup`'s own `do_handshake()` afterwards is a no-op on
     an established TLS connection (probed with Python's ssl).
  4. At the session's FIRST COMPLETE MESSAGE (review r4 A4-3/B4-9: a socket that sends nothing never holds it):
     the admission lock (`flock` on `/tmp/batman-264-admit.lock` in the container; wait at most 30 s, held until
     the session's subscription is placed or fails, or 20 s), then the memory reserve again: a crowd is checked
     one after the other (R7 capacity, R16). Without the lock the check still runs (logged). Each admission logs
     `lock taken` / `lock released after N ms`. A first message that is a ping or an `<auth>` does not release the
     lock (review r5 B5-9). Residual, stated (review r5 B5-3): a session's setup (its AMQP connection) runs before
     the lock; the serialized check sees it, and the flip at 768m on the shipping order is in the register (fs-1).
  - **Deadline (review r3 B3-3, reproduced on rc wsl.10: one empty `<event></event>` cleared it, the socket was
    still open at 88 s):** until the client identifies (uid set), every complete message only moves the deadline
    `BATMAN_264_IDENT_MAX_S` (60 s) further; identification clears it once. A relay that keeps sending is never
    cut; a socket that goes silent before identifying is. After identification R6 keepalive bounds a dead peer.
  - The listen backlog is 64 (upstream 5; R7 capacity).
- **Residual, stated:** a mesh insider with many addresses still gets 8 sessions per address (the phones' side is
  one bridged /16), bounded by the memory reserve; an unidentified client that keeps sending well-formed messages
  holds its session (it is then bounded like any talking client: R9 per session, the memory reserve); when the
  per-address count cannot be read only the memory reserve applies (logged; IPv6 peers are not counted, not
  reachable today: the listener is AF_INET); a refused 8089 session logs upstream's handshake warning once more.
  A stale socket of a flapping phone counts against its 8 for up to ~2 min (R6), and clients behind one NAT share
  the 8. The premise "ATAK/iTAK send their SA at once" is not yet captured from real devices (review r3 A3-8):
  part of the deferred field test.
- **Test:** `admission-264`: (c) 3 sockets to 8089 that never start TLS get no AMQP connection and are closed
  within ~10 s; (b) 10 silent sockets from one address, opened 1 s apart: at least 2 refused; (a) 3 silent sockets
  under the limit are closed at 60 s; (d) an empty event then silence: still closed at the deadline. Negative
  control: rc wsl.8 (a, b, c), rc wsl.10 (d). Offline #21 (address count), #22/#22b (order, lock), the handle()
  tests (rolling deadline).

### R16 — a reconnecting crowd never takes the listener down (field scenario 2026-10-12)
- **Cause (reproduced twice on node 04 with rc wsl.11, 768m; `scratchpad/264/r4/rto-rc11.log`, `negrto11`):** the RTO
  walks out of range and is back within ~2 min. The team's 16 sessions are still on the server (zombies, no FIN)
  when the same 16 phones reconnect at once. R7 refused 3, then the memcg OOM killer killed the LARGEST process,
  the listener parent (anon-rss 118 MB): the container exited, every session and every cache with it (an AAR gap),
  and the guardian restarted it; 0/16 reconnects kept. Three causes: the OOM killer picks the parent; the
  admission lock was released at the first message, before the session had grown (subscription, AMQP); the
  reserve read only `anon`, while the zombies' unsent data sits in socket buffers charged to the same limit
  (tcp_wmem max 4 MiB each).
- **Validation note (review r4 A4-1/B4-4):** rto-264 passes at 1280m without any OOM, so the R16 code is proven by
  a separate flip at 768m with the same build (register fs-1).
- **Fix (`BATMAN-264-R16`):**
  - each session process writes `oom_score_adj` 1000 for itself at setup (raising one's own score needs no
    privilege; probed as uid 1000 on 04): an OOM kills one session, whose phone reconnects, never the listener;
  - the admission lock is held until the session's subscription is placed or fails (`_subscribe`), a
    non-identifying session releases it at its first message, `ADMIT_HOLD_S` 20 s is the fallback;
  - "used" for the reserve = `memory.current` minus the page cache (`file`): anon plus kernel memory, socket
    buffers included (log page cache is still excluded, review B-6);
  - the app containers' limit is 1280m: OTS runs only on Pi 4 8 GB; 4 x 1280m + 2 x 512m = 6.0 GiB, below the
    6.6 GiB available, so even every cap hit at once does not OOM the node.
- **Residual, stated:** a session killed by the OOM killer loses its cache (bounded by R9) and ends without its
  goodbye (its queues stay until R15's expiry); a refused phone records nothing until it is admitted.
  `oom_score_adj` also applies to a NODE-wide OOM (review r4 A4-4): phone sessions go before the node's own daemons,
  which is the intended order (a session reconnects; the mesh daemons keep the node reachable). The containers'
  caps (6.0 GiB) are below the available memory, so OTS itself cannot cause a node-wide OOM.
- **Platform (review r4 A4-5):** the caps hold only on a Pi 4 8 GB, where OTS is installed (the user). The manifest
  states the minimum and payload-run refuses to start the tenant on a smaller board.
- **Test:** `rto-264` (16 zombies black-holed on 02/03, the same 16 uids reconnecting from inside two OTS
  containers; asserts all 16 kept for 120 s, `ots_eud_handler` StartedAt unchanged, no OOM kill). Negative
  control: rc wsl.11 (0/16, listener restarted). `cap16-264` now also compares StartedAt (an OOM-killed listener
  comes back in a new cgroup whose `oom_kill` count starts at 0: seen as "0 -> 0" while it had restarted).
  Offline #20 (used = current - file), #24 (oom_score_adj; lock release), handle() R16 cases.

### R13 — end-on-loss (review r3 A3-3; the user's decision 2026-10-12)
- **Cause:** R4 replayed the subscription recorded at identification after a reconnect; bindings made later
  through the Marti API (missions, group changes) were silently missing until the phone reconnected.
- **Fix (`BATMAN-264-R13`):** a lost AMQP connection or channel puts the unacked bodies back in the cache; the
  ioloop reconnects (R4 backoff) only to deliver the cache and wait for its acks (R4b, bounded by `DRAIN_MAX_S`);
  then the CLIENT session ends. The phone reconnects and its new session is subscribed from the database, as
  upstream does. While a connection is opening no second one is created (review r2 A2-9 / r3 A3-5).
- **Difference from upstream, stated:** upstream also ended the session, but lost what was in flight; R13 loses
  nothing the server had already read (what was still unread is lost, R4b residual). The phone sees one reconnect
  per broker-side loss.
- **The goodbye (review r3 A3-6):** a channel or connection lost while the disconnect/unbinds are in flight is
  retried once (a new DRAIN_MAX_S deadline), then given up. An end with no uid, no cache and nothing unacked
  completes at once (review r3 A3-7).
- **Test:** `amqp-close-264` (R4 above). Offline #11 (R13), #17 (no replay).

### R14 — an exception in one message ends nothing else (review r3 A3-2)
- **Cause (reproduced on rc wsl.10):** any exception out of `handle_cot`/`handle_auth` (a CoT without a `start`
  attribute: `KeyError` in `parse_device_info`) ended the child with no session end: its queues stayed bound with
  no consumer.
- **Fix:** the failing message is dropped (logged once with its traceback); the session goes on. `handle()` runs
  its loop in `try/finally`: whatever leaves it, the admission lock is released, the session end runs and is
  waited for.
- **Identification (review r4 A4-7/B4-2, measured on rc wsl.12):** `parse_device_info` sets the uid before it
  writes the EUD row; an exception in between left the uid set and no row, so the session never identified again
  and every later CoT was dropped by cot_parser's FK. Now the uid is reset (the next report identifies again) and
  the CoT is still published (cot_parser decides whether it can store it).
- **A row that can never be written (review r5 A5-2/B5-1; psql on 04: `'555-123-4567'::bigint` is refused):** the
  metadata is written defensively (a phone reduced to its digits for the BigInteger column, strings cut to 255, a
  missing `start` or `role` tolerated); if the row still fails, a minimal row (uid, "Connected", the user, the callsign
  if free) is written so cot_parser's FK accepts the device's CoT. Re-identification stops after 3 failures (the
  uid is kept, a minimal row written). Offline `test-eudhandler-264-ident.py`: identified once in 1000 CoT and
  recorded; on 162af3a it re-identified 1000 times (a new postgres connection each) and was not recorded.
- **Test:** `exception-264` (a CoT without `start`, then a valid CoT: no traceback ending the child, the session
  ends properly, no empty queue left, and the valid CoT is STORED). Negative controls: rc wsl.10 (child ended),
  rc wsl.12 (0 stored: FK). Offline: the handle() tests.

### R15 — per-EUD queues bounded by a broker policy (review r3, resources)
- **Cause (reproduced on rc wsl.10):** cot_parser's 8089 disconnect BINDS the departed device's `<uid>` queue to
  its groups (`cot_parser.py:989`), and the queue is never deleted (F3 skips 8089, A2-1). It kept filling with
  group traffic for nobody: 12 messages in 40 s. Upstream behaviour (B), fixed under the user's criterion "no
  resource consumed for nothing".
- **Fix:** broker policy `batman-264-eud-queues` on every queue but `cot_parser` and `meshtastic`: `max-length`
  500, `max-length-bytes` 1 MiB, `overflow drop-head`, `expires` 24 h unused. A policy, not queue arguments: the
  Marti API declares the same queues without arguments (`group_marti_api.py:330`, `mission_marti_api.py:1504`), a
  mismatch would be 406. Imported at every broker start from `/etc/rabbitmq/batman-definitions.json`
  (`rabbitmq-extra.conf`), which also declares vhost `/`, user `guest` (the password OTS uses, hashed) and its
  permissions: with a definitions file the broker seeds no default vhost or user (probed with a throwaway
  `rabbitmq:4.3.6` container, `--network none`: guest logs in, the policy applies, 0 errors).
- **Residual, stated:** a reconnecting phone finds at most the newest 500 messages of its queue (upstream: all);
  DMs older than that are dropped while it is away. A device away more than 24 h finds its queue deleted with its
  mission bindings (`missions.<name>`); its Data Sync downlink returns when it re-subscribes (review r4 A4-10; a
  broker restart does the same to these transient queues today).
- **Ownership (review r4 A4-9/B4-10):** the definitions file is imported at every broker start and OWNS the broker
  credential (user `guest`, the password OTS uses). Rotating it means changing both this file and OTS's
  `config.yml`; a change made with `rabbitmqctl` alone is reverted at the next broker start (noted for #47,
  per-node credentials). After a downgrade the policy stays in the broker's metadata (`ots-mqdata`): harmless.
- **Test:** `queue-policy-264` (a departed 8089 group member's queue stops at 500 under a burst; `cot_parser` is not
  under the policy). Negative control: rc wsl.10 (grew without bound).

## 2. Ownership

| resource | owner (writes) | readers / notes |
|---|---|---|
| golden `EudHandler-264.py` | the build | 95-batman-storage refresh |
| p6 `apps/opentakserver/EudHandler-264.py` | golden refresh at boot; D7-7 reports DRIFT if it differs | payload-run (MOUNT source) |
| `MOUNTSHA` value | the manifest (golden) | payload-run (preflight refusal) |
| the bind mount | payload-run | containers, ro |
| one session's AMQP connection, channel, cache, unacked set, subscription | that forked child, ioloop thread only | — |
| client socket of a session | that child (keepalive/user timeout R6, admission deadline R12; R2 not in this change) | — |
| `cot_parser` exchange, queue and binding | two idempotent declarers with identical arguments: cot_parser (upstream) and eud (R5) | broker |
| per-EUD queues and bindings | every live session of the EUD (shared, as upstream); a binding is removed only by a session that placed it, when no other consumer is left on that queue; queues are deleted only by the last 8088 session (never for 8089: cot_parser binds them on the disconnect) | web/API, cot_parser (8089 disconnect), other sessions (publish) |
| the session end of one child | that child: started once (lock), run on its ioloop, waited for by its handler thread | — |
| admission lock `/tmp/batman-264-admit.lock` (container tmpfs) | each child holds it from its memory check until its subscription is placed (or 20 s; flock, released by the kernel on exit) | — |
| a session process's `oom_score_adj` | that process (sets 1000 for itself, R16) | kernel OOM killer |
| R8 hold file `$RUNDIR/batman-payload-<tenant>.mountsha-hold` | payload-run (written by a refused converge, removed by a successful one) | every start path of payload-run (incl. the guardian's `--restart-exited`) |
| broker policy `batman-264-eud-queues`, vhost `/`, user `guest` | `batman-definitions.json` (golden, imported at every broker start) | broker; OTS logs in as guest |

## 3. Contracts

- **MOUNT and MOUNTSHA** (R8): valid only when the image's file sha256 equals `MOUNTSHA`. Otherwise payload-run
  refuses the rebuild. This is fail-closed: the old containers keep running and the guardian reports DRIFT.
- **AMQP towards cot_parser:**
  - same exchanges, routing keys and TTL property;
  - plus `mandatory` and confirms on the eud side;
  - at-least-once: a message can arrive later, and duplicates are possible after a reconnect;
  - order is not guaranteed across a reconnect;
  - replayed CoT may already be stale when cot_parser routes them (`route_cot`); this is stated.
- **Client session:** ends when the client leaves, on keepalive failure, at the R12 deadline before
  identification, when the container stops, or after a broker-side loss once its cache is delivered (R13).
- **R8 hold file:** one container name per line, root-only run dir; missing = nothing held; unreadable = nothing
  held from it (the refused converge in the same run still holds by its in-memory list).
- **Broker definitions:** a definitions file without vhost `/` stops a fresh broker from starting (probed); a
  malformed or missing file: ⚠️ not probed, expected to stop the broker (rabbitmq fails a configured import), which
  the guardian reports as a crash.
- **Log lines other tools read:**
  - `Failed to parse` (ots_logc, info);
  - `RabbitMQ channel is closed, not publishing cot: cache full, dropped=N`, which now appears only when a CoT
    is **dropped** (the upstream prefix is kept so ots_logc keeps counting);
  - new, read by the suites from `/app/ots/logs/eud_handler_tcp.log` inside the container (the handler logs to
    that file, not to stdout): `refusing session from <ip>` (R7), `another session of <uid> is live` (R6),
    `RabbitMQ reconnect for <ip>` (R4), `refusing the subscription of <ip>` (R10, a refused uid), `is not used as a queue` (R10, a refused callsign), `subscribed <uid>/<callsign>`,
    `queue <q> shared with <n> other consumer(s)` (R6), `belong to an authenticated user` (R10),
    `sessions from this address` and `sent no complete message within` (R12); payload-run: `kept STOPPED on its old
    config` (R8).
- **Container env (profile-owned, optional):** `BATMAN_264_SESSION_RESERVE_MB` (40), `BATMAN_264_PER_IP_MAX` (8),
  `BATMAN_264_IDENT_MAX_S` (60). The admission wait (30 s) and hold (20 s) are constants. Malformed -> the handler fails to import (`int()`), the container exits and the
  guardian reports it: fail-closed and visible.

  `ots_logc` reads the TCP log only (the SSL suite judges by storage, not by log lines).

## 4. Lifecycle

| path | today | after | test |
|---|---|---|---|
| first boot / firstload | C window at broker start | eud declares the queue on its first channel open | cleanstop-274 step 6, queue-gone-264 |
| boot / reboot / power loss | C window every boot | as above | cleanstop-274, unclean-boot-274 |
| clean stop / OTA | children SIGKILLed after the parent exits; caches lost | same; stated as residual | cleanstop-274 (no regression) |
| autocommit trial | — | unchanged; the R tests never restart tenant containers, so they leave no DRIFT ledger | fi-s1 |
| restart of eud container (guardian) | clients reconnect | same | crash-274 |
| broker-side connection close (heartbeat) | session ends, CoT lost | cache delivered (reconnect, at-least-once), then the session ends and the phone reconnects (R13) | amqp-close-264 |
| broker restart (crash, guardian) | sessions end; C window; cot_parser exits (its BlockingConnection has no reconnect) and the guardian restarts it with backoff | caches delivered once the broker is back, then the sessions end and the phones reconnect (R13); eud re-declares the queue; the policy is re-imported; transient-queue backlog lost (residual) | amqp-close-264 (mechanism B) + queue-gone-264 (mechanism C); no broker kill (§7) |
| broker memory alarm | publishers blocked; pika buffers grow | the sessions cache (bounded) and resume after the alarm; no timeout (r4) | R9 unit test (fake connection); node test: leftover |
| cot_parser restart | queue persists while the broker is up | same | — |
| ots-db down | cot_parser nacks and drops (upstream) | unchanged; residual, stated | — |
| client network loss | session lives for hours; its end unbinds the EUD's live session | gone in ~2 min (TCP_USER_TIMEOUT 120 s, keepalive 45/15/4); the reconnecting phone is subscribed at once (shared); the stale end sees it live and keeps everything | zombie-264 (field order) |
| a phone flapping at the edge of range / two app instances | the second session's end unbinds the first | the first keeps its bindings | same-uid-end-264 |
| two devices with one callsign | both shared (round-robin on the callsign queue) | same; each has its own `<uid>` queue | callsign-share-264 |
| 8089 group member leaves while cot_parser is busy | (upstream keeps the queue) | queues kept (never deleted for 8089) | group-disc-264 |
| the RTO walks out of range and back (16 zombies + 16 reconnects) | (upstream: OOM kill of the container) | each reconnect admitted after the previous one is placed; an OOM kills a session, never the listener; 1280m | rto-264 |
| N concurrent clients / mass reconnect after power loss | +39 MB each (measured), OOM kill of the container at ~10 | 23 MiB each (rc wsl.7); 1280m (R16); 8 per address and the memory reserve before TLS, serialized admission, rolling deadline until identified, backlog 64; target 16 phones | eud-mem-264, admission-264, cap16-264 + offline cases |
| a CoT that makes cot_parser's helpers raise | the child dies, queues left bound | that message dropped, session goes on (R14) | exception-264 |
| an 8089 group member leaves for good | its queue bound to its groups, fills for ever | capped at 500 / 1 MiB, deleted 24 h unused (R15) | queue-policy-264 |
| guardian restart after a refused converge | (R8 new) | the held container stays stopped until a converge succeeds | test-payload-run #29, r8-hold-264 |
| first install with a MOUNTSHA mismatch | — | the rebuild is refused: no TAK server until the image matches (fail-closed, stated; review r3 B3-9) | MOUNTSHA negative control |
| image changed under the patch | runs unpatched or the old patch overwrites newer code | refused at rebuild, DRIFT; on the refused converge the mismatching overlay container stays stopped, for every later start of the boot (hold) | MOUNTSHA negative control, test-payload-run #27/#28/#29, r8-hold-264 |
| downgrade to an image without the change (broker) | — | the R15 policy and the definitions' user stay in `ots-mqdata` (harmless) | — |
| power loss of the OTS node | children SIGKILLed | the sessions' caches, the transient cot_parser backlog and unread socket data are lost; phones reconnect (cap16/rto) | cleanstop-274, unclean-boot-274 |
| downgrade to an image without the change | — | the shipped payload-run (main d43025c) has no default branch in its manifest-key case, so `MOUNTSHA` is silently ignored and the overlay mounts unpinned; the D6 prune removes the p6 overlay once `.golden-files` no longer lists it, and the mount then fails closed (source missing) until the next OTA | first-ota / downgrade (manual, stated) |
| bcm2711 / bcm2710 | — | the OTS package is bcm2711 only (`DEPENDS:=@TARGET_bcm27xx_bcm2711`); Pi 3 not applicable | ab-card |

## 5. Assumptions with evidence

- pika 1.3.2: `custom_ioloop`, `mandatory`, `add_on_return_callback`, `confirm_delivery`,
  `add_on_connection_blocked_callback`, `blocked_connection_timeout` (probed and source lines, reviewers A/B).
- pika never stops the ioloop on a connection close (reviewer A, source lines above).
- `ForkingTCPServer`, PID 1 python, StopSignal SIGINT (probed).
- The image's `.pyc` uses timestamp invalidation, so a mounted source is recompiled (reviewer B probe).
- The `cot_parser` exchange is durable and its queue transient; TTL 86400000 ms (probed).
- Identical-redeclare acceptance and mandatory return-then-ack on RabbitMQ 4.3.6: probed on the live broker
  (R5 above).

## 6. Security

- **Assets:** CoT confidentiality (8089 users) and availability; the node itself is unchanged.
- **Remote client, including unauthenticated on 8088:**
  - R10 closes the use of its identifiers as broker names and of an authenticated user's names (both columns).
  - R12 bounds what it can hold before it identifies: 8 sessions per address and the memory reserve before
    anything else (TLS included), a deadline that a silent socket cannot reset; on 8089 nothing is allocated
    before the client certificate is verified. A client that keeps sending is bounded per session by R9 and in
    total by the memory reserve, not by time (stated, R12).
  - It cannot remove the bindings of a LIVE session: a session removes only what it placed, only when nobody else
    consumes the queue (R6); a refused session removes nothing. It can remove an offline unowned EUD's bindings
    by naming it (B3-6, upstream, stated in R10).
  - It cannot take an authenticated user's queues (8088, both names) or, as another authenticated user, a device
    uid of another user (8089, R10). It can still send CoT under another device's uid (A3-9, upstream, stated).
  - It cannot crash cot_parser through our queue deletes: 8089 queues are never deleted (R6/F3).
  - It cannot trigger a reconnect loop: there is no replay (R13); a session ends once its cache is delivered.
- **Compromised tenant:** no new interface.
- **Local non-root process:** none. Files are root-owned, mounted ro, and D7-7 reports DRIFT on an edit.
- **Supply chain:** the patch is generated from the pinned upstream; R8 enforces the pin at runtime.
- **Attack-surface delta:** same ports and credentials. New inputs the overlay reads: the container's own
  cgroup files (`memory.stat`, `memory.max`: kernel-owned, read-only), the broker's DeclareOk/Return/Ack
  frames (the broker is trusted as before), the `x-b264-uid`/`x-b264-type` headers of our own returned
  messages (only our own publishes come back), and `BATMAN_264_SESSION_RESERVE_MB` from the container env
  (profile-owned). Client-supplied uid/callsign are now checked before they become broker names (R10).
- **Admission lock:** in the container's own tmpfs, reachable only from the eud processes (same uid). A session
  takes it only after its first complete message (review r4: a silent 8088 socket held it 20 s), so an
  unauthenticated 8088 client holds it at most `ADMIT_HOLD_S` per message-sending session (8 per address); a
  compromised eud process can hold it, which only delays admissions by 30 s (then checked without it).
- **Broker definitions:** contain the guest password hash (the default credential OTS already uses); root-owned,
  mounted ro; no new secret.
- **Failure modes:**
  - image mismatch: fail-closed (refuse the rebuild; on a refused converge keep the overlay container stopped);
  - `/proc/net/tcp` unreadable: the per-address limit is skipped (logged), the memory reserve still applies
    (fail-open with reason: refusing every session would be a self-inflicted outage);
  - broker away: cache with bounds, then counted drops.

## 7. Tests and registration

| suite | tier | destructive | negative control |
|---|---|---|---|
| ots-cot-e2e-264 (8088), ots-cot-e2e-264-ssl (8089) | feature | no | unpatched P2B 0/20 |
| amqp-close-264 | feature | no (`rabbitmqctl close_connection` of the session's own connection, found by its `connection_name`) | upstream: the session is dropped and the CoT in flight lost; rc wsl.10: the session was kept, no R13 line |
| queue-gone-264 | feature | no (`delete_queue` only) | unpatched loss |
| amqp-restart-264 | not built: a broker restart is mechanism B (amqp-close-264) plus mechanism C (queue-gone-264), both covered without killing a container | — | — |
| zombie-264 | feature | peer-side nft rules on the test client's port only, self-expiring (300 s), table deleted by a detached timer | upstream: zombie outlives the black hole, live session 0/10; wsl.8: 1 consumer (held off), the stale end sent the disconnect |
| same-uid-end-264 | feature | no | wsl.8: the live session 0/10 |
| callsign-share-264 | feature | no | wsl.8: 10/0 |
| owner-swap-264 | feature | no (a 1-day test cert in the container's tmpfs, removed) | wsl.8: the swap was subscribed |
| admission-264 | feature | no | wsl.8: AMQP before the handshake, nothing refused, silent sockets kept; wsl.10: (d) an empty event cleared the deadline |
| exception-264 | feature | no | wsl.10: the raising CoT ended the child, an empty queue left |
| owner-8089-264 | feature | no (a 1-day test cert in the container's tmpfs, removed) | wsl.10: the row was taken over |
| queue-policy-264 | feature | no | wsl.10: the departed member's queue grew without bound |
| cap16-264 | feature | no | wsl.10: anon peak 93 % of memory.max |
| rto-264 (8088), rto-ssl-264 (8089) | feature | no (peer-side nft on the test clients' ports only, self-expiring; 8089 copies a 1-day test cert to 02/03 and removes it) | wsl.11: the listener OOM-killed, 0/16 kept |
| r8-hold-264 | tier B | yes (stops the OTS overlay containers, restores from the golden) | wsl.10: the guardian started the held container |
| group-disc-264 | feature | yes on a broken build (cot_parser crash loop; ends when the test membership is removed, which every exit path does) | wsl.8: 6 x crash ots_cot_parser |
| name-guard-264 | feature | no | by code: upstream subscribes unconditionally; rc wsl.12: the device not recorded (0 rows) |
| alarm-264 | feature | no (the broker watermark is lowered ~75 s, restored by the suite and by a detached 150 s timer on the node) | by code only: rc wsl.12's blocked_connection_timeout=60 ended the sessions (rc12 no longer installed) |
| eud-mem-264 | feature | no | measured on upstream: 39 MB per idle session |
| mountsha (in payload-conform / R8 suite) | feature | no | wrong sha → refuse |
| soak-cot-264 | soak | — | every sent CoT stored (duplicates counted, at-least-once); heartbeat closes recorded per session (info, R2) |
| offline: test-eudhandler-264.py, test-eudhandler-264-amqp.py (fake pika) | CI | — | regression tests of the overlay's own logic; most do not run against the unpatched module (they call overlay methods), so the node suites above are the negative controls |

Every suite deletes the per-EUD queues and DB rows it created, and its cleanup FAILs if anything is left. The
2026-10-11 residue queues on 04 are removed once, with the list printed first. The #264 known-failure entries
are removed when the suites pass.

## 8. Not in scope

- The upstream report and PR: outside the project's repos; asked separately after validation.
- The UDP listener: its port is not exposed, and it is unsupported with the overlay (`setup`/`handle` assume a
  stream socket; review r3 A3-11).
