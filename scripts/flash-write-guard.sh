#!/bin/sh
# flash-write-guard.sh <node> — placement guard for the write-placement contract
# (docs/storage-architecture.md). Flags any app/daemon that writes STATE (a database) to the
# rootfs overlay — which a hard power-off can corrupt (#41/#104) — regardless of how often it
# writes. Read-only over SSH; makes no changes.
#
#   scripts/flash-write-guard.sh <node>
#
# PASS = no unexpected state DBs on /overlay/upper. FAIL = a new violator appeared.
# Known/accepted exception (documented, #104): openmanetd's own DB, an upstream dependency
# tracked in storage-architecture.md — reported, not failed.
set -u
NODE=${1:?usage: flash-write-guard.sh <node>}
SSHOPT="-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8"
ACCEPT_PREFIX='/overlay/upper/etc/openmanetd/'   # openmanetd DB — accepted #104 exception

# shellcheck disable=SC2086  # SSHOPT is a deliberate multi-option word list
# `[ -d ] && find || true` so a node without an overlay yields an empty (PASS) result rather
# than a non-zero exit that the check below would misreport as an SSH failure.
found=$(timeout 15 ssh $SSHOPT "root@$NODE" \
  '[ -d /overlay/upper ] && find /overlay/upper -type f \( -name "*.db" -o -name "*.db-wal" -o -name "*.db-shm" -o -name "*.sqlite" -o -name "*.sqlite3" \) 2>/dev/null || true') \
  || { echo "flash-write-guard: SSH to $NODE failed"; exit 2; }

echo "state DBs on the rootfs overlay of $NODE:"
if [ -z "$found" ]; then
  echo "  (none)"
else
  printf '%s\n' "$found" | sed 's/^/  /'
fi

unexpected=$(printf '%s\n' "$found" | grep -v '^$' | grep -v "^$ACCEPT_PREFIX" || true)
if [ -n "$unexpected" ]; then
  echo "FAIL: unexpected app/daemon state on the rootfs overlay (violates the write-placement contract):"
  printf '%s\n' "$unexpected" | sed 's/^/  x /'
  echo "  → move it to the data partition (persist) or tmpfs (volatile); see storage-architecture.md"
  exit 1
fi
echo "PASS: no unexpected state DBs on the overlay (openmanetd DB is the known #104 exception)"
exit 0
