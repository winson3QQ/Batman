# FreeTAKServer build (for manet02) — #44

Version-controlled FTS build that runs in a container on an OpenWrt/musl node.

- `Dockerfile` — `python:3.11-slim-bookworm` + FreeTAKServer 2.2.1 + `patch_fts.py`.
- `patch_fts.py` — fixes digitalpy's opentelemetry tracing crash and relocates the CoT
  (18087) and HTTP API (18080) ports off openmanetd.
- `requirements.txt` — the resolved dependency **lock**, committed so SBOM/CVE tools
  scan FTS's real deps (`ci.yml` Trivy/Syft on PRs; `release-scan.yml` Dependency-Check
  with the NVD key on release).

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
4. Restart the container onto the new image:
   `docker rm -f fts; docker run -d --name fts --restart unless-stopped --network host -v /opt/fts-data:/opt/fts -e FTS_FIRST_START=false fts:2.2.1`

## On-node build

`docker build --network=host -t fts:2.2.1-crypto .` — needs internet (借網) + `--network=host`
(OpenWrt firewall blocks the docker0 bridge). This is now safe: since 2026-09-10 the node's
docker data-root lives on a **27.5 GB ext4 partition (`mmcblk0p3`, LABEL=dockerdata)** with
~23 GB free (#85), not the old 2.4 GB btrfs loop on the cramped 4 GB overlay that used to hit
ENOSPC → btrfs-readonly on any non-trivial build/load. Prefer on-node build over `docker load`
of a CI tar — `load` can abort on a shared-layer `rename: file exists`, while a cached build
just adds the changed layer. The off-node CI build (build-fts-image) is still the canonical,
scanned artifact.

Node data-root layout (for reference): `/etc/init.d/dockermount` mounts p3 at `/opt/docker`
(the old `/opt/docker.img` loop is kept as a commented fallback); the MBR partition-table
backup is off-node.

⚠️ Remaining CVEs: 12 python High (crypto cluster — version-coupled) + 15 Debian base-OS
Critical (#83). Clear them via the off-node build above; do not attempt on-node. See #45.
