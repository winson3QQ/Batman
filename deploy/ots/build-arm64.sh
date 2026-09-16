#!/bin/bash
# Build the OpenTAKServer arm64 image for the Batman payload host.
#
# Runs on the WSL native docker + buildx + qemu toolchain (NOT Docker Desktop).
# Upstream ships amd64-only images, so we build and own the arm64 image ourselves.
# Prereq (one-time): WSL Ubuntu-24.04 with docker-ce, a buildx docker-container
# builder named "batman-arm64", and qemu arm64 binfmt installed.
#
# Output: a gzipped docker-archive tar ready to scp to a node and `docker load`.
# (We export via buildx --output type=docker,dest=... because `docker save` on a
#  buildx/multi-arch image trips a "content digest not found" bug in Docker 29.)
set -euo pipefail

OTS_REF=${OTS_REF:-67903c26d95552738d85be4bc3c3ff3321378dbe}   # OTS 1.7.13
TAG=${TAG:-batman/ots:1.7.13-arm64}
OUT=${OUT:-/tmp/ots-arm64.tar}
HERE=$(cd "$(dirname "$0")" && pwd)

echo "== ensure buildx arm64 builder =="
docker buildx use batman-arm64 2>/dev/null || \
  docker buildx create --name batman-arm64 --driver docker-container --bootstrap --use

echo "== build $TAG (arm64, OTS_REF=$OTS_REF) — slow under qemu (~8-10 min) =="
docker buildx build --platform linux/arm64 \
  --build-arg OTS_REF="$OTS_REF" \
  -t "$TAG" \
  --output "type=docker,dest=${OUT}" \
  "$HERE"

gzip -1f "$OUT"
echo "== done: ${OUT}.gz =="
echo "Deps (pull once, arm64): imresamu/postgis:18-3.6, rabbitmq:latest"
echo "  docker save --platform linux/arm64 <img> | gzip -1 > <img>.tar.gz   # note --platform (Docker 29 store bug)"
echo "Transfer: scp the .tar.gz to node (IPv6 link-local needs brackets: root@[fe80::..%15]:/path)"
echo "Load on node: gunzip -c <tar.gz> | docker load"
