# FreeTAKServer 2.2.1 for an OpenWrt/musl node (runs in a glibc container because the
# node has no python/toolchain). Built + deployed on manet02. See #44.
FROM python:3.11-slim-bookworm
ENV PIP_NO_CACHE_DIR=1 DEBIAN_FRONTEND=noninteractive PYTHONUNBUFFERED=1
RUN apt-get update && apt-get install -y --no-install-recommends \
      gcc libffi-dev libssl-dev libxml2-dev libxslt1-dev make \
    && rm -rf /var/lib/apt/lists/*
RUN pip install --upgrade pip
RUN pip install FreeTAKServer==2.2.1
# digitalpy imports pkg_resources, removed in setuptools>=81 -> pin back
RUN pip install "setuptools<81"
# patch: fix digitalpy opentel tracing (crashes on new opentelemetry) + relocate
# CoT 8087->18087 and HTTP API 8080->18080 (openmanetd owns 8087/8080 on the node)
COPY patch_fts.py /tmp/patch_fts.py
RUN python /tmp/patch_fts.py
RUN python -c "import pkg_resources, FreeTAKServer; print('imports OK')"
WORKDIR /opt/fts
EXPOSE 18087 8089 18080 8443 19023 9000
CMD ["python", "-m", "FreeTAKServer.controllers.services.FTS"]
