# FreeTAKServer build + deployment (payload host node) — #44 #119

Version-controlled FTS build that runs in a container on an OpenWrt/musl node.

- `Dockerfile` — `python:3.11-slim-bookworm` + FreeTAKServer 2.2.1 + `patch_fts.py`.
- `patch_fts.py` — fixes digitalpy's opentelemetry tracing crash and relocates the CoT
  (18087) and HTTP API (18080) ports off openmanetd.
- `requirements.txt` — the resolved dependency **lock**, committed so SBOM/CVE tools
  scan FTS's real deps (`ci.yml` Trivy/Syft on PRs; `release-scan.yml` Dependency-Check
  with the NVD key on release).
- `run.sh` — (re)creates the `fts` + `fts-ui` containers on the tenant layout below. The only
  supported way to start them; nothing is hand-typed on the node.
- `payload-host-packages.txt` — the docker-engine packages a Pi 4 payload host needs
  (offline-installed .ipk list with versions; **not** covered by the FTS image SBOM — #98).

## Tenant layout on the node (docs/storage-architecture.md, p5 sub-layout v1)

```
/opt/batdata/                 data partition, mounted by batdata-mount (S11)
  docker/                     docker data-root  (uci: dockerd.globals.data_root)
  apps/fts/                   FTS state -> container /opt/fts  (DBs, certs, FTSConfig.yaml, data packages)
  apps/fts-ui/                UI state  -> container /opt/ftsui-data  (FTSServer-UI.db, api-key)
```
Images are shared in `docker/`; each tenant owns only its `apps/<name>/`. The UI's FTS API
token lives in `apps/fts-ui/api-key` (raw token, mode 600); `run.sh` reads it. No
`dockermount` init is needed any more — the golden's storage hook mounts p3 before dockerd.

## Payload host: docker engine on OpenMANET 1.8.0 (offline)

The golden does not carry docker yet (#110 board profile decides). On a Pi 4 payload host:
1. On a machine with internet, download the packages in `payload-host-packages.txt` from the
   OpenWrt 24.10-SNAPSHOT feeds (`packages/aarch64_cortex-a72/{packages,base}`) and the OpenMANET
   kmod feed (`packages-repo/24.10/targets/bcm27xx/bcm2711/packages`); verify each `.ipk`
   SHA256 against the feed index (the index is signed; offline `opkg install ./x.ipk` does not).
2. `scp` them to the node, `opkg install /tmp/ipk/*.ipk`.
3. `uci set dockerd.globals.data_root=/opt/batdata/docker; uci commit dockerd;
   /etc/init.d/dockerd enable; /etc/init.d/dockerd start` — expect `Storage Driver: overlay2`,
   `Backing Filesystem: extfs`, `Cgroup Version: 2`. (`iptables-nft` coexists with fw4;
   `--network host` is used.)
   **Do not enable `cgroupfs-mount`** (`/etc/init.d/cgroupfs-mount disable` if the package got
   pulled in): at S01 it replaces procd's cgroup v2 with a v1 hierarchy, and the OpenMANET
   kernel has no `CONFIG_CGROUP_DEVICE` → dockerd dies at boot with "Devices cgroup isn't
   mounted". Docker runs fine on procd's cgroup2.
4. `sh deploy/fts/run.sh` (after `docker load` of the image, or with the images already in
   `docker/`).
5. Restart policy is `unless-stopped`: containers come back after a reboot or a dockerd
   restart, **but not after a manual `docker stop`** — use `docker restart`, or `docker start
   fts fts-ui` after maintenance that stopped them.

Validated 2026-09-11 on the ex-manet02 golden node: after the v1.1 reflash the p3 data
(images + FTS DBs/certs) was migrated in place into the layout above, docker reinstalled
offline, `run.sh` brought `fts:2.2.1-slim` + `fts-ui:2.2.1` back on the existing data, and
`functional-test.sh fts:2.2.1-slim` passed all 5 gates.

## Build off-node, load on the node (preferred — #85)

The node's ~3.9 GB overlay can't hold a non-trivial on-device build (an `apt upgrade` once
filled it and forced docker's btrfs loop read-only mid-build). So build in CI and ship a
`docker load`-able tarball:

1. Run the **build-fts-image** workflow (Actions → Run workflow, or it auto-runs on any
   `deploy/fts/**` change). It builds `linux/arm64`, scans the image, and uploads the
   artifact `fts-2.2.1-arm64-image` (`fts-2.2.1-arm64.tar.gz`).
2. Download the artifact; copy it to the node (while "借網" or over the mesh):
   `scp fts-2.2.1-arm64.tar.gz root@manet02.local:/tmp/`
3. On the node: `gunzip -c /tmp/fts-2.2.1-arm64.tar.gz | docker load`
4. Restart the containers onto the new image: `sh deploy/fts/run.sh --image fts:<tag>`.

## On-node build

`docker build --network=host -t fts:2.2.1-crypto .` — needs internet (借網) + `--network=host`
(OpenWrt firewall blocks the docker0 bridge). This is now safe: since 2026-09-10 the node's
docker data-root lives on a **27.5 GB ext4 partition (`mmcblk0p3`, LABEL=dockerdata)** with
~23 GB free (#85), not the old 2.4 GB btrfs loop on the cramped 4 GB overlay that used to hit
ENOSPC → btrfs-readonly on any non-trivial build/load. Prefer on-node build over `docker load`
of a CI tar — `load` can abort on a shared-layer `rename: file exists`, while a cached build
just adds the changed layer. The off-node CI build (build-fts-image) is still the canonical,
scanned artifact.

Node data-root: `/opt/batdata/docker` on p3 (see the tenant layout above). The old
`dockermount` init / `/opt/docker` mount and the `appdata/*` bind mounts are gone since the
v1.1 golden.

⚠️ Remaining CVEs: 12 python High (crypto cluster — version-coupled) + 15 Debian base-OS
Critical (#83). Clear them via the off-node build above; do not attempt on-node. See #45.
