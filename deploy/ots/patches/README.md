# OpenTAKServer patches

**License: the files in this directory are GPL-3.0-or-later** (they are, or contain fragments of, OpenTAKServer source; OpenTAKServer 1.7.13 is GPL-3.0-or-later). The rest of the repository is MIT.

## #264 eud_handler CoT loss

What the overlay carries (`BATMAN_264 = "R1 R3 R5 R9"` in the file; design: `docs/design/264-ots-eud-patch.md`):
- **R1** a message cut by a recv boundary is carried to the next recv, not dropped (mechanism A);
- **R3** every channel operation runs on the pika ioloop thread;
- **R5** the session declares the `cot_parser` exchange/queue/binding itself (cot_parser's exact arguments) on its own
  channel, publishes with `mandatory`, and a returned (unroutable) message is re-queued, re-declared and retried
  head-first with backoff (mechanism C);
- **R9** the cache holds serialized bodies, bounded by count and bytes (position reports coalesced per uid/type),
  and a broker `connection.blocked` is cached instead of filling pika's write buffer.

| file | what |
|---|---|
| `EudHandler-264.py` | the shipped file: OpenTAKServer 1.7.13 `opentakserver/eud_handler/EudHandler.py` with the #264 fixes (every change marked `BATMAN-264`) |
| `eudhandler-264.patch` | `diff -u upstream → EudHandler-264.py`, for review and upstreaming |
| `make-eudhandler-264.py` | generator: upstream file → `EudHandler-264.py`; each edit asserts its upstream anchor |
| `UPSTREAM_SHA256` | sha256 of the upstream file the patch was made for (the file inside `batman/ots:1.7.13-arm64`); the single source the manifest's `MOUNTSHA` is generated from |
| `test-eudhandler-264.py` | offline tests of the patched `handle()` (split events, Chinese callsign 1 byte per recv, auth+event, malformed, >1 MiB) |
| `test-eudhandler-264-amqp.py` | offline tests of the AMQP side against a fake channel/ioloop (mandatory + return, declare channel, flow control, cache bounds) |
| `check-eudhandler-264.sh` | proves the files above are consistent and runs both offline tests (CI, via check-payload-manifest.sh); `--image <ref>` also checks the image's own file |

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
