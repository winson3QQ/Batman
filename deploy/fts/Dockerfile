# FreeTAKServer 2.2.1 for an OpenWrt/musl node (runs in a glibc container because the
# node has no python/toolchain). Built + deployed on manet02. See #44.
FROM python:3.11-slim-bookworm
ENV PIP_NO_CACHE_DIR=1 DEBIAN_FRONTEND=noninteractive PYTHONUNBUFFERED=1
RUN apt-get update && apt-get install -y --no-install-recommends \
      gcc libffi-dev libssl-dev libxml2-dev libxslt1-dev make \
    && rm -rf /var/lib/apt/lists/*
RUN pip install --upgrade pip
RUN pip install FreeTAKServer==2.2.1
# Security bump (#45): FTS 2.2.1 resolves pillow 9.3.0, which carries CVE-2023-4863
# (libwebp WebP heap overflow) — CISA KEV, actively exploited, EPSS ~100%. Force a fixed
# pillow after the FTS install (FTS uses pillow only via qrcode + image save).
RUN pip install "pillow>=10.3.0"
# Security bump (#45 P2): the High-severity crypto/web cluster FTS 2.2.1 pins old. Built
# OFF-node in CI (#85) so a broken bump fails on the runner, never on the field node. The
# import check below exercises the crypto + protobuf paths so an incompatible pin fails the
# build. Covers CVE-2023-0286 / -50782 / -49083 / CVE-2024-0727 (cryptography, coupled with
# pyOpenSSL), CVE-2024-34069 (werkzeug), CVE-2024-6221 (flask-cors), CVE-2025-4565
# (protobuf), + jinja2 / dnspython. cryptography also needed for #16 FIPS.
RUN pip install -U \
      "cryptography>=42.0.8" "pyOpenSSL>=24.0.0" \
      "werkzeug>=3.0.6" "jinja2>=3.1.4" "flask-cors>=4.0.1" \
      "dnspython>=2.6.1" "protobuf>=4.25.8"
# digitalpy imports pkg_resources, removed in setuptools>=81 -> pin back
RUN pip install "setuptools<81"
# patch: fix digitalpy opentel tracing (crashes on new opentelemetry) + relocate
# CoT 8087->18087 and HTTP API 8080->18080 (openmanetd owns 8087/8080 on the node)
COPY patch_fts.py /tmp/patch_fts.py
RUN python /tmp/patch_fts.py
# Compat gate (#45 P2): fail the build on the runner if a bump broke FTS. Exercises the
# bumped stack — cryptography/pyOpenSSL TLS, protobuf-generated FTS models, the flask/
# werkzeug/jinja web stack — so an incompatible pin surfaces here, not on the node.
RUN python -c "import pkg_resources, FreeTAKServer; \
import cryptography, OpenSSL, werkzeug, jinja2, flask_cors, dns.resolver, google.protobuf; \
from OpenSSL import crypto, SSL; \
from FreeTAKServer.controllers.services.FTS import FTS; \
print('crypto/web/protobuf + FTS imports OK', 'cryptography', cryptography.__version__)"
WORKDIR /opt/fts
# Non-interactive + reboot-safe (#45): FTS runs an interactive first-start wizard when
# FTS_FIRST_START is truthy and no /opt/fts/installation.json exists. On a headless field
# node with -d (no stdin) that wizard hits EOF and crash-loops on every (re)boot. Config is
# driven by the patched MainConfig defaults + the persistent /opt/fts volume, so disable
# the wizard. Runtime still overridable with -e FTS_FIRST_START=true for a genuine setup.
ENV FTS_FIRST_START=false
EXPOSE 18087 8089 18080 8443 19023 9000
CMD ["python", "-m", "FreeTAKServer.controllers.services.FTS"]
