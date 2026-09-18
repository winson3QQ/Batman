#!/bin/sh
# verify-profile-ots.sh — run the generic confinement drift-check (scripts/verify-profile.sh) across
# ALL of the OTS stack's containers, each against its own <container>.hardening.env (#98 multi-container).
# The generic checker takes <container> <env-file>; this wrapper supplies the right pairing and rolls up
# the per-container verdicts for the #156 reconciler.
#
# Per-container exit codes from verify-profile.sh: 0=OK, 1=DRIFT, 2=usage, 3=UNKNOWN(skip).
# Wrapper exit: 1 if ANY container is DRIFT (caller alarms); else 0 (unknowns are skipped, NOT alarmed).
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

drift=0; unknown=0; ok=0
for pair in "$@"; do
  cname=${pair%:*}; env=${pair#*:}
  envf="$HERE/$env.hardening.env"
  echo "==================== $cname  ($env.hardening.env) ===================="
  # don't let `set -e` abort on a non-zero (drift/unknown) verdict — we roll them up
  sh "$VP" "$cname" "$envf" && ec=0 || ec=$?
  case "$ec" in
    0) ok=$((ok+1)) ;;
    3) unknown=$((unknown+1)); echo ">> $cname: UNKNOWN (skipped, not counted as drift)" ;;
    *) drift=$((drift+1)) ;;   # 1=DRIFT, 2=usage -> both are real problems to surface
  esac
done
echo "===================================================================="
echo "verify-profile-ots: ok=$ok drift=$drift unknown=$unknown"
if [ "$drift" -gt 0 ]; then echo "verify-profile-ots: DRIFT"; exit 1; fi
echo "verify-profile-ots: OK (no drift; $unknown skipped)"
exit 0
