#!/bin/sh
# verify-profile-ots.sh — run the generic drift-check (scripts/verify-profile.sh) across ALL of the
# OTS stack's containers, each against its own <container>.hardening.env (#98 multi-container).
# The generic checker takes <container> <env-file>; this wrapper just supplies the right pairing.
# Runs on the busybox node. Exit non-zero if any container drifts.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
# locate the generic checker: next to us (node deploy dir) or in the repo's scripts/
VP="$HERE/verify-profile.sh"; [ -f "$VP" ] || VP="$HERE/../../scripts/verify-profile.sh"
[ -f "$VP" ] || { echo "cannot find verify-profile.sh (looked in $HERE and ../../scripts)"; exit 2; }

# container -> hardening.env  (the 4 app containers share ots.hardening.env)
set -- \
  "opentakserver:ots" \
  "ots_cot_parser:ots" \
  "ots_eud_handler:ots" \
  "ots_eud_handler_ssl:ots" \
  "ots-db:ots-db" \
  "rabbitmq:rabbitmq"

rc=0
for pair in "$@"; do
  cname=${pair%:*}; env=${pair#*:}
  envf="$HERE/$env.hardening.env"
  echo "==================== $cname  ($env.hardening.env) ===================="
  sh "$VP" "$cname" "$envf" || rc=1
done
echo "===================================================================="
[ "$rc" = 0 ] && echo "verify-profile-ots: ALL OK" || echo "verify-profile-ots: DRIFT (see above)"
exit $rc
