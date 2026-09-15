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
# Base is Debian trixie (#83): trixie carries the security fixes bookworm marked won't-fix/no-dsa
# for glibc (CVE-2026-5450), sqlite3 (CVE-2025-7458) and openssl (CVE-2026-75803).
FROM python:3.11-slim-trixie AS builder
ENV PIP_NO_CACHE_DIR=1 DEBIAN_FRONTEND=noninteractive PYTHONUNBUFFERED=1
# libc6-dev + linux-libc-dev are explicit here: on trixie `gcc` no longer pulls libc6-dev under
# --no-install-recommends (it did on bookworm), so building the psutil sdist failed on
# `stdlib.h`/`linux/ethtool.h`. Builder-only — none of this ships to the runtime stage.
RUN apt-get update && apt-get install -y --no-install-recommends \
      gcc libc6-dev linux-libc-dev libffi-dev libssl-dev libxml2-dev libxslt1-dev make \
    && rm -rf /var/lib/apt/lists/*
RUN pip install --upgrade pip
RUN pip install FreeTAKServer==2.2.1
# Security bump (#45): pillow 9.3.0 carries CVE-2023-4863 (libwebp WebP heap overflow) —
# CISA KEV. Force a fixed pillow (FTS uses it via qrcode + image save).
RUN pip install "pillow>=10.3.0"
# Security bump (#45 P2 / #148): the old crypto/web cluster is now UNBLOCKED. FTS's
# certificate_generation.py was the only thing forcing pyOpenSSL <24 (it used crypto.CRL/
# Revoked/PKCS12/X509Extension, removed in pyOpenSSL 24/26). It is ported to `cryptography`
# (the vendored certificate_generation.py COPY'd in below), so we run the maintained libs:
#   cryptography >=42 clears CVE-2023-50782 + CVE-2024-0727; pyOpenSSL >=26 clears CVE-2026-27459.
# (cryptography also needed for #16 FIPS.) protobuf (old-protoc fig_pb2 breaks on >=4) +
# dnspython (frozen eventlet) stay frozen — separate #148 follow-up / risk-accepted.
RUN pip install -U \
      "cryptography>=42" "pyOpenSSL>=26" "protobuf>=7" \
      "werkzeug>=3.0.6,<3.1" "jinja2>=3.1.4,<3.2" "flask-cors>=4.0.1,<5"
# digitalpy imports pkg_resources, removed in setuptools>=81 -> pin back
RUN pip install "setuptools<81"
# patch: fix digitalpy opentel tracing (crashes on new opentelemetry) + relocate
# CoT 8087->18087 and HTTP API 8080->18080 (openmanetd owns 8087/8080 on the node)
COPY patch_fts.py /tmp/patch_fts.py
RUN python /tmp/patch_fts.py
# #148: replace certificate_generation.py with the cryptography-ported version (off pyOpenSSL's
# CRL/PKCS12/X509Extension, removed in 24/26). patch_fts.py above patches DIFFERENT files
# (opentel_tracing_provider.py, MainConfig.py) so there is no collision on this file.
COPY certificate_generation.py /usr/local/lib/python3.11/site-packages/FreeTAKServer/core/util/certificate_generation.py
RUN python -c "import ast; ast.parse(open('/usr/local/lib/python3.11/site-packages/FreeTAKServer/core/util/certificate_generation.py').read()); print('cert_gen patch syntax OK')"
# #148 follow-up: replace the protobuf-3.x-codegen *_pb2.py with protobuf-7-regenerated versions
# (clears protobuf CVE-2025-4565). Regen recipe (run once, output vendored in deploy/fts/protobufModel/):
#   python -m grpc_tools.protoc -I <proto> --python_out=<protobufModel> <proto>/*.proto
#   then sed the flat `import X_pb2` -> `import FreeTAKServer.model.protobufModel.X_pb2` (FTS's layout).
# Runtime protobuf must be >= the protoc that generated these (7.x) — pinned above (`protobuf>=7`).
COPY protobufModel/ /usr/local/lib/python3.11/site-packages/FreeTAKServer/model/protobufModel/
RUN python -c "import FreeTAKServer.model.protobufModel.takmessage_pb2, FreeTAKServer.model.protobufModel.fig_pb2; print('protobuf regen import OK')"

# ---------- runtime: slim, no toolchain, upgraded base ----------
FROM python:3.11-slim-trixie AS runtime
ENV PIP_NO_CACHE_DIR=1 DEBIAN_FRONTEND=noninteractive PYTHONUNBUFFERED=1
# Refresh the base + install ONLY the runtime shared libs FTS's C-extension wheels dlopen from
# the SYSTEM: libssl3 (python stdlib `ssl`), libsqlite3-0 (stdlib `sqlite3`), libffi8 (cffi).
# NOT libxml2 / libxslt1.1 (#83): lxml's manylinux wheel statically bundles its own libxml2
# (2.14.6, verified on manet02) + libxslt, so the system deb packages were unused by FTS and
# only dragged in their base Criticals (e.g. libxml2 CVE-2026-6653) — dropped here. NO gcc/*-dev.
RUN apt-get update && apt-get -y upgrade \
    && apt-get install -y --no-install-recommends \
      libssl3 libsqlite3-0 libffi8 \
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
