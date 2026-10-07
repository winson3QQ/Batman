# OpenTAKServer patches

**License: the files in this directory are GPL-3.0-or-later** (they are, or contain fragments of, OpenTAKServer source; OpenTAKServer 1.7.13 is GPL-3.0-or-later). The rest of the repository is MIT.

## #264 eud_handler CoT loss (stage 1)

| file | what |
|---|---|
| `EudHandler-264.py` | the shipped file: OpenTAKServer 1.7.13 `opentakserver/eud_handler/EudHandler.py` with the #264 fixes (every change marked `BATMAN-264`) |
| `eudhandler-264.patch` | `diff -u upstream → EudHandler-264.py`, for review and upstreaming |
| `make-eudhandler-264.py` | generator: upstream file → `EudHandler-264.py`; each edit asserts its upstream anchor |
| `UPSTREAM_SHA256` | sha256 of the upstream file the patch was made for (the file inside `batman/ots:1.7.13-arm64`) |
| `test-eudhandler-264.py` | offline tests of the patched `handle()` (split events, Chinese callsign 1 byte per recv, auth+event, malformed, >1 MiB) |
| `check-eudhandler-264.sh` | proves the four above are consistent (CI); `--image <ref>` also checks the image's own file |

**Delivery** (no new image): `batman-payload-ots` installs `EudHandler-264.py` into the payload golden (`/usr/share/batman/payload-golden/opentakserver/`). The boot-time golden refresh copies it to p6 `apps/opentakserver/`, and `profile.yaml` bind-mounts it read-only over the image's file in `ots_eud_handler` and `ots_eud_handler_ssl`. The containers are rebuilt when the config fingerprint changes (#274), so an OTA brings it in, and an OTA to a release with a different manifest takes it out again.

**Do not delete `apps/opentakserver/EudHandler-264.py` on a node** while any container mounts it.

**Upgrading OpenTAKServer**: the overlay replaces the whole file. CI refuses a profile that mounts it on an image other than `batman/ots:1.7.13-arm64`, and daily validation checks the image's own file against `UPSTREAM_SHA256`. When upgrading, regenerate from the new upstream, or drop the overlay if upstream has fixed #264.

Regenerate (WSL, base image loaded):
```
c=$(docker create batman/ots:1.7.13-arm64); docker cp $c:/app/venv/lib/python3.13/site-packages/opentakserver/eud_handler/EudHandler.py /tmp/up.py; docker rm $c
python3 make-eudhandler-264.py /tmp/up.py EudHandler-264.py
{ diff -u --label a/opentakserver/eud_handler/EudHandler.py --label b/opentakserver/eud_handler/EudHandler.py /tmp/up.py EudHandler-264.py || true; } > eudhandler-264.patch
sh check-eudhandler-264.sh --image batman/ots:1.7.13-arm64
```
