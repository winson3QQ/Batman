#!/bin/sh
# check-hardening-env.sh — HARD CI gate (#98 C1): the committed <app>.hardening.env MUST equal what
# scripts/profile-to-flags.py regenerates from deploy/<app>/profile.yaml. A stale env would make the
# node run flags that don't match the profile SoT while verify-profile.sh still passes (hidden drift).
# Fails non-zero if any app's env is out of sync. Wire into CI (.github/workflows/hardening-env-sync.yml).
set -e
cd "$(dirname "$0")/.."
PY="${PYTHON:-python3}"
rc=0
for prof in deploy/*/profile.yaml; do
  app=$(basename "$(dirname "$prof")")
  # every committed <app>/<name>.hardening.env must match what the emitter regenerates for that name.
  # Multi-container: an app profile can emit several (app + infra_values.*); check each one.
  found=0
  for env in deploy/"$app"/*.hardening.env; do
    [ -f "$env" ] || continue
    found=1
    base=$(basename "$env")
    tmp=$(mktemp); "$PY" scripts/profile-to-flags.py "$app" --check "$base" > "$tmp"
    if [ ! -s "$tmp" ]; then
      echo "ORPHAN $env has no matching target in $prof (stale — delete it or restore the profile block)"; rc=1
    elif ! diff -u "$env" "$tmp" >/dev/null 2>&1; then
      echo "DRIFT  $env is stale -- regenerate with: python3 scripts/profile-to-flags.py $app"
      diff -u "$env" "$tmp" || true
      rc=1
    else
      echo "OK     $env in sync with $prof"
    fi
    rm -f "$tmp"
  done
  [ "$found" = 1 ] || { echo "MISSING deploy/$app/*.hardening.env (run: profile-to-flags.py $app)"; rc=1; }
done
exit $rc
