# FreeTAKServer 2.2.1 for an OpenWrt/musl node (runs in a glibc container because the
# node has no python/toolchain). Built OFF-node in CI (#85) + deployed on manet02. See #44.
#
# Multi-stage (#83): the build toolchain (gcc, make, the -dev headers) is needed only to
# install FTS, and it dragged a batch of Debian base Criticals into the shipped image
# (libxml2-dev, libssl-dev, libc6-dev, binutils …). Build in a full stage, then copy just
# the installed Python packages into a lean runtime stage that carries only the runtime
# shared libs + an `apt upgrade`. The functional gate (deploy/fts/functional-test.sh) proves
# FTS still works after the slim-down.

# ---------- builder: full toolchain, install + patch FTS ----------
FROM python:3.11-slim-bookworm AS builder
ENV PIP_NO_CACHE_DIR=1 DEBIAN_FRONTEND=noninteractive PYTHONUNBUFFERED=1
RUN apt-get update && apt-get install -y --no-install-recommends \
      gcc libffi-dev libssl-dev libxml2-dev libxslt1-dev make \
    && rm -rf /var/lib/apt/lists/*
RUN pip install --upgrade pip
RUN pip install FreeTAKServer==2.2.1
# Security bump (#45): pillow 9.3.0 carries CVE-2023-4863 (libwebp WebP heap overflow) —
# CISA KEV. Force a fixed pillow (FTS uses it via qrcode + image save).
RUN pip install "pillow>=10.3.0"
# Security bump (#45 P2): the High-severity crypto/web cluster FTS 2.2.1 pins old. Upper
# bounds keep each within its compatible major. Frozen-upstream bind (both edges hit in CI):
# FTS's certificate_generation.py calls OpenSSL.crypto.CRL (REMOVED in pyOpenSSL 24 → the
# functional gate caught the runtime crash), so pyOpenSSL must stay <24; and pyOpenSSL 23.x
# requires cryptography <42 → cryptography capped at 41.x. 41.0.7 clears CVE-2023-0286/-49083
# + the 2023 set; CVE-2023-50782 / CVE-2024-0727 (42+-only) deferred (docs/fts-cve-triage.md).
# protobuf (old-protoc fig_pb2 breaks on >=4) and dnspython (frozen eventlet breaks on >=2.8)
# are left frozen. cryptography also needed for #16 FIPS.
RUN pip install -U \
      "cryptography>=41.0.7,<42" "pyOpenSSL>=23.3.0,<24" \
      "werkzeug>=3.0.6,<3.1" "jinja2>=3.1.4,<3.2" "flask-cors>=4.0.1,<5"
# digitalpy imports pkg_resources, removed in setuptools>=81 -> pin back
RUN pip install "setuptools<81"
# patch: fix digitalpy opentel tracing (crashes on new opentelemetry) + relocate
# CoT 8087->18087 and HTTP API 8080->18080 (openmanetd owns 8087/8080 on the node)
COPY patch_fts.py /tmp/patch_fts.py
RUN python /tmp/patch_fts.py

# ---------- runtime: slim, no toolchain, upgraded base ----------
FROM python:3.11-slim-bookworm AS runtime
ENV PIP_NO_CACHE_DIR=1 DEBIAN_FRONTEND=noninteractive PYTHONUNBUFFERED=1
# Refresh the Debian base (security point releases) and install ONLY the runtime shared libs
# FTS's C-extension wheels dlopen (TLS, XML/XSLT, sqlite, ffi) — NO gcc / make / *-dev.
# This is what drops the #83 base Criticals that came from the build toolchain.
RUN apt-get update && apt-get -y upgrade \
    && apt-get install -y --no-install-recommends \
      libssl3 libxml2 libxslt1.1 libsqlite3-0 libffi8 \
    && rm -rf /var/lib/apt/lists/*
# Bring the installed + patched Python environment from the builder.
COPY --from=builder /usr/local/lib/python3.11/site-packages /usr/local/lib/python3.11/site-packages
COPY --from=builder /usr/local/bin /usr/local/bin
# Compat gate (#45/#83): fail the build if the slim-down dropped a lib FTS needs, or a bump
# broke it. Exercises the crypto/pyOpenSSL TLS, protobuf-generated models, flask/werkzeug/
# jinja web stack + FTS startup import — an incompatible pin or a missing .so surfaces here.
RUN python -c "import pkg_resources, FreeTAKServer; \
import cryptography, OpenSSL, werkzeug, jinja2, flask_cors, dns.resolver, google.protobuf; \
import sqlite3, lxml.etree, _cffi_backend; \
from OpenSSL import crypto, SSL; \
from FreeTAKServer.controllers.services.FTS import FTS; \
print('runtime imports OK', 'cryptography', cryptography.__version__)"
WORKDIR /opt/fts
# Non-interactive + reboot-safe (#45): FTS's interactive first-start wizard EOF-crash-loops
# on a headless node. Config comes from the patched MainConfig defaults + the persistent
# /opt/fts volume; disable the wizard. Overridable at runtime with -e FTS_FIRST_START=true.
ENV FTS_FIRST_START=false
EXPOSE 18087 8089 18080 8443 19023 9000
CMD ["python", "-m", "FreeTAKServer.controllers.services.FTS"]
