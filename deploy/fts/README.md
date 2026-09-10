# FreeTAKServer build (for manet02) — #44

Version-controlled FTS build that runs in a container on an OpenWrt/musl node.

- `Dockerfile` — `python:3.11-slim-bookworm` + FreeTAKServer 2.2.1 + `patch_fts.py`.
- `patch_fts.py` — fixes digitalpy's opentelemetry tracing crash and relocates the CoT
  (18087) and HTTP API (18080) ports off openmanetd.
- `requirements.txt` — the resolved dependency **lock**, committed so SBOM/CVE tools
  scan FTS's real deps (`ci.yml` Trivy/Syft on PRs; `release-scan.yml` Dependency-Check
  with the NVD key on release).

Build/run (on the node): `docker build -t fts:2.2.1 .` then
`docker run -d --name fts --restart unless-stopped --network host -v /opt/fts-data:/opt/fts -e FTS_FIRST_START=false fts:2.2.1`.

⚠️ Several pins are old with known CVEs (cryptography 36.0.2 …) — see #45.
