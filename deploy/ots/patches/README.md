# OpenTAKServer patches

**License: the files in this directory are GPL-3.0-or-later** (they are, or contain fragments of, OpenTAKServer source; OpenTAKServer 1.7.13 is GPL-3.0-or-later). The rest of the repository is MIT.

## #264 eud_handler CoT loss

What the overlay carries (`BATMAN_264 = "R1 R3 R4 R4b R5 R6 R7 R9 R10 R12 R13 R14 R16 R17"` in the file; design and
every review finding: `docs/design/264-ots-eud-patch.md`, `docs/design/264-review-register.md`):
- **R1** a message cut by a recv boundary is carried to the next recv, not dropped (mechanism A);
- **R3** every channel operation runs on the pika ioloop thread;
- **R4/R4b** publisher confirms (at-least-once: a body is kept until its ack, nack/return/close put it back),
  reconnect on the session's own ioloop with backoff while the session delivers its cache, a bounded drain when the
  client leaves while the broker is away;
- **R5** the session declares the `cot_parser` exchange/queue/binding itself (cot_parser's exact arguments) on its own
  channel, publishes with `mandatory`, and a returned (unroutable) message is re-queued, re-declared and retried
  head-first with backoff (mechanism C);
- **R6** keepalive + `TCP_USER_TIMEOUT` on the client socket (a vanished phone is gone in about 2 min); a session end
  never unbinds or deletes the queues of another live session of the same EUD; the last session removes its idle,
  empty queues;
- **R7** the parent's app is shared with the children (no per-session Flask build), the parent's heap is frozen once
  before the first fork, the ORM pre-warmed; a session is refused when the container's memory (current minus page
  cache) is within `BATMAN_264_SESSION_RESERVE_MB` (96) of its limit;
- **R9** the cache holds serialized bodies, bounded by count and bytes (position reports coalesced per uid/type),
  and a broker `connection.blocked` is cached instead of filling pika's write buffer;
- **R10** uid/callsign are checked before they become queue names (empty, >255 bytes, `amq.*`, system names,
  non-printable); an 8088 client cannot subscribe as an authenticated user's device, an 8089 user not as another
  user's device; an unusable or owned callsign is not used as a queue and the device is still recorded;
- **R12** admission: 8 sessions per client address, the memory reserve and (8089) the TLS handshake before anything
  is allocated; a first-message deadline; at the first complete message a serialized admission (a lock in the
  container's own tmpfs) with the memory reserve again, and only then the AMQP connection;
- **R13** after a broker-side loss the session delivers its cache, then ends (the phone reconnects clean);
- **R14** an exception in one message drops that message only; an identification that fails is retried, and a
  device is always recorded (a minimal row if the full row cannot be written);
- **R16** each session process volunteers as the OOM killer's first choice (`oom_score_adj` 1000), so an OOM takes a
  session, never the listener;
- **R17** one downlink per device: when the same device opens a new session (8089: the same OTS user; 8088: the same
  address) its previous session stops its downlink at once, keeps reading its uplink, and ends after
  `BATMAN_264_SUPERSEDE_QUIET_S` (20) without data; a newer session counts as live at any end.

Not in the overlay (stated leftovers): R2 (a client that stops reading can still block the ioloop's send for up to
`TCP_USER_TIMEOUT`), R11 (faulthandler diagnosis aid). Test hook: `/tmp/batman-264-fi` in the eud container makes one
message of a session raise (validation suite exception-264); absent in normal operation.

**Manual install on a node** (what the payload golden does): copy `EudHandler-264.py` to
`/opt/batdata/apps/opentakserver/EudHandler-264.py` next to `ots.manifest` (which carries the `MOUNT` and
`MOUNTSHA` lines) and let the guardian rebuild; never edit it in place while a container mounts it.

| file | what |
|---|---|
| `EudHandler-264.py` | the shipped file: OpenTAKServer 1.7.13 `opentakserver/eud_handler/EudHandler.py` with the #264 fixes (every change marked `BATMAN-264`) |
| `eudhandler-264.patch` | `diff -u upstream → EudHandler-264.py`, for review and upstreaming |
| `make-eudhandler-264.py` | generator: upstream file → `EudHandler-264.py`; each edit asserts its upstream anchor |
| `UPSTREAM_SHA256` | sha256 of the upstream file the patch was made for (the file inside `batman/ots:1.7.13-arm64`); the single source the manifest's `MOUNTSHA` is generated from |
| `test-eudhandler-264.py` | offline tests of the patched `handle()` (split events, Chinese callsign 1 byte per recv, auth+event, malformed, >1 MiB) |
| `test-eudhandler-264-amqp.py` | offline tests of the AMQP side against a fake channel/ioloop (mandatory + return, declare channel, flow control, cache bounds, the session end) |
| `test-eudhandler-264-ident.py` | offline tests of identification and the EUD row (R14: identified once, always recorded; the real minimal-row writer) |
| `test-eudhandler-264-supersede.py` | offline tests of R17 with real forked processes (SIGUSR1, the registry, pid reuse, malformed entries) |
| `check-eudhandler-264.sh` | proves the files above are consistent and runs every offline test (CI, via check-payload-manifest.sh); `--image <ref>` also checks the image's own file |

**Delivery** (no new image): `batman-payload-ots` installs `EudHandler-264.py` into the payload golden (`/usr/share/batman/payload-golden/opentakserver/`). The boot-time golden refresh copies it to p6 `apps/opentakserver/`, and `profile.yaml` bind-mounts it read-only over the image's file in `ots_eud_handler` and `ots_eud_handler_ssl`. The containers are rebuilt when the config fingerprint changes (#274), so an OTA brings it in, and an OTA to a release with a different manifest takes it out again.

**Do not delete `apps/opentakserver/EudHandler-264.py` on a node** while any container mounts it (payload-run then refuses a rebuild: MOUNT source missing).

**Upgrading OpenTAKServer**: the overlay replaces the whole file, so it is pinned at runtime: the manifest's `MOUNTSHA` (generated from `UPSTREAM_SHA256`) makes payload-run read the image's own file before every rebuild and refuse when it differs — fail-closed, the old containers keep running and the guardian reports DRIFT. CI (`check-payload-manifest.sh`) asserts the pin and the overlay's consistency. When upgrading, regenerate from the new upstream, or drop the overlay if upstream has fixed #264.

Regenerate (WSL, base image loaded):
```
c=$(docker create batman/ots:1.7.13-arm64); docker cp $c:/app/venv/lib/python3.13/site-packages/opentakserver/eud_handler/EudHandler.py /tmp/up.py; docker rm $c
python3 make-eudhandler-264.py /tmp/up.py EudHandler-264.py
{ diff -u --label a/opentakserver/eud_handler/EudHandler.py --label b/opentakserver/eud_handler/EudHandler.py /tmp/up.py EudHandler-264.py || true; } > eudhandler-264.patch
sh check-eudhandler-264.sh --image batman/ots:1.7.13-arm64
```
