# deploy/ots — OpenTAKServer (TAK server payload)

**Deploying a TAK server is a required platform capability.** FreeTAKServer (FTS) is
retired (upstream unmaintained); **OpenTAKServer (OTS)** replaces it. See #162 (parent #75).

This directory is the **version-controlled build recipe** for the OTS arm64 image.
It does **not** yet contain a production deployment — the node networking is
design-gated (see *Deployment: unresolved* below).

## What OTS is

Actively-maintained open-source TAK server (brian7704/OpenTAKServer), ATAK/iTAK/WinTAK
compatible. Multi-service stack (heavier than FTS's 2 containers):

| service | role | port(s) |
|---|---|---|
| `ots` | API / app | 8081 (loopback) |
| `ots_cot_parser` | CoT parser (RabbitMQ consumer) | — |
| `ots_eud_handler` | EUD TCP CoT listener | 8088 |
| `ots_eud_handler_ssl` | EUD SSL CoT listener | 8089 |
| `rabbitmq` | message broker (**required**) | 5672 |
| `ots-db` | PostGIS database (**required**) | 5432 |
| *(optional)* nginx-proxy / webui / MediaMTX / certbot / Mumble | web UI, video, voice | 80/443/… |

The four `ots_*` roles all run from **one image** (`Dockerfile`) via command override.

## Build

Upstream ships **amd64-only** images, so we build & own the arm64 set.

```sh
deploy/ots/build-arm64.sh          # -> /tmp/ots-arm64.tar.gz (docker-archive, arm64)
```

Runs on the WSL native docker + buildx + qemu toolchain (not Docker Desktop). The
image is pinned to **OTS 1.7.13 == commit `67903c26`** (by SHA — immutable).
Dependency images (`imresamu/postgis:18-3.6`, `rabbitmq:latest`) are pulled arm64 with
`docker save --platform linux/arm64` (the `--platform` flag is required to dodge a
Docker 29 containerd-store `content digest not found` bug).

Transfer to an air-gapped node: `scp` the tar (IPv6 link-local needs brackets:
`root@[fe80::…%15]:/path`), then `gunzip -c … | docker load`.

## Footprint — measured (Pi4 8GB arm64, docker+memcg, idle, no clients)

| component | RAM | pids |
|---|---|---|
| postgis 18-3.6 | 43 MiB | 9 |
| rabbitmq 4.x | 112 MiB | 29 |
| OTS python service (per container) | 116 MiB | 4 |

- **Core 6-container stack idle ≈ 620 MiB RAM; CPU ≈ 0; image disk ≈ 3.3 GB.**
- **An 8 GB Pi4 runs OTS comfortably (~8% RAM). Resources are not the blocker.**
- Reproduce with `footprint-spike.sh` (measures DB + broker + one OTS worker).

## Deployment: unresolved (design-gated — #162)

Bringing the full stack up on our nodes hit real integration walls, all reproduced
on-node during the spike. **These must be resolved by design-review before a
production deploy:**

1. **No arm64 upstream images** → self-build (handled by `build-arm64.sh`; ongoing
   maintenance = patch-and-own, like the vendored FTS cert_gen/protobuf).
2. **Networking (the hard one):**
   - Docker **bridge** networks are **default-rejected by the node fw3** → cross-container TCP refused.
   - **host-net collides** with node services: API 8081 vs **openmanetd (8081/8080/8087)**, web UI 80/443 vs **uhttpd**.
   - → need **OTS port remap** and/or a **fw3 zone for the docker bridge**. (FTS worked only because it used host-net + few ports.)
3. **non-root + volume ownership** — `ots` uid 1024 can't write a root-owned volume
   (`/app/ots/uploads`); the volume must be chowned to 1024 (or no volume for ephemeral).
4. **rabbitmq `.erlang.cookie` eacces** — run with `--user rabbitmq` + `RABBITMQ_ERLANG_COOKIE`.
5. **6–8 containers to harden** (vs FTS 2) — the app-agnostic profile mechanism
   (#153/#155) absorbs this, but per-service profiles must be authored.

CA + DB schema are **stateful** and created by the app at first boot — not baked into
the image.
