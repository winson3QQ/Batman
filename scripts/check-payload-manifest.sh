#!/bin/sh
# check-payload-manifest.sh — HARD CI gate (#167). Two invariants:
#  1) SYNC: the committed payload artifacts MUST equal what the emitters regenerate from
#     deploy/<app>/profile.yaml — the fw4 rules (profile-to-fw4.py) and, for tenants that opted into
#     the generic manager, the manifest + net.alloc + per-tenant guardian init (profile-to-manifest.py).
#     A stale artifact would make the node run a config that doesn't match the profile SoT (hidden
#     drift) while everything still "looks" fine. (Closes review m3: fw4 was previously ungated.)
#  2) NO-COLLISION: the committed set of tenants must be arbiter-clean — no two share a host port,
#     subnet, fw4 zone, or bridge (#167 §3). Catches a collision at commit time, not at deploy.
# Fails non-zero on any drift or collision. Wire into CI alongside hardening-env-sync.
set -e
cd "$(dirname "$0")/.."
PY="${PYTHON:-python3}"
ARB=feed/batman-provision/files/usr/bin/payload-arbiter
rc=0

# --- 1) regenerate committed artifacts in place, then detect drift via git ---
for prof in deploy/*/profile.yaml; do
	app=$(basename "$(dirname "$prof")")
	# fw4: any tenant that ships a committed *.fw4.uci (has a top-level network: block)
	if ls deploy/"$app"/*.fw4.uci >/dev/null 2>&1; then
		"$PY" scripts/profile-to-fw4.py "$app" >/dev/null || { echo "FAIL: fw4 emit failed for $app"; rc=1; }
	fi
	# manifest trio: only tenants that opted into the generic manager (a committed *.manifest)
	if ls deploy/"$app"/*.manifest >/dev/null 2>&1; then
		"$PY" scripts/profile-to-manifest.py "$app" >/dev/null || { echo "FAIL: manifest emit failed for $app"; rc=1; }
	fi
done

# Drift = regeneration changed a tracked artifact (working-tree vs index/HEAD). A brand-new tenant's
# artifacts are compared once committed/staged; git diff (not status) avoids flagging a clean staged
# add as drift, while still catching a stale committed artifact.
PATHS="deploy/*/*.fw4.uci deploy/*/*.manifest deploy/*/*.net.alloc deploy/*/batman-payload-*.init"
# shellcheck disable=SC2086  # PATHS is a deliberate list of git pathspecs
if ! git diff --quiet -- $PATHS 2>/dev/null; then
	echo "DRIFT: regenerated payload artifacts differ from committed — regenerate & commit:"
	echo "  python3 scripts/profile-to-fw4.py <app> ; python3 scripts/profile-to-manifest.py <app>"
	# shellcheck disable=SC2086
	git --no-pager diff -- $PATHS || true
	rc=1
fi

# --- 2) arbiter: the committed tenant set must be collision-free ---
for na in deploy/*/*.net.alloc; do
	[ -f "$na" ] || continue
	if ! sh "$ARB" "$na" deploy >/dev/null 2>&1; then
		echo "COLLISION: $na collides with another committed tenant:"
		sh "$ARB" "$na" deploy 2>&1 | sed 's/^/  /' || true
		rc=1
	fi
done
rm -f deploy/.arbiter.lock 2>/dev/null || true
rmdir deploy/.arbiter.lock.d 2>/dev/null || true

[ "$rc" = 0 ] && echo "OK: payload artifacts in sync + no tenant collisions"
exit "$rc"
