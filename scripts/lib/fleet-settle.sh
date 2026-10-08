# shellcheck shell=bash
# scripts/lib/fleet-settle.sh — sourced by daily-validation.sh (and scripts/test-harness-265.sh).
# Needs from the caller: up <node>, fssh <node> <timeout> <cmd>, isint, and the report globals
# DIR, NFAIL, FAILED, ROWS.
# Fleet settle (#265 v1.2 H2): a suite that reboots a node — above all DNODE, the host's only bridge into the
# mesh — leaves the others unreachable for minutes, and the next suite's one-shot `up` turned that into a
# SKIP (rc4: ramoops-173 -> cleanstop-274 / halow-fi-263 "did not answer"). After every suite that RAN:
# fast path = one `up` per fleet node; a destructive suite (declared by its caller: 4th arg D — no name
# list to drift) or any node down = slow path, each node must answer 3x, 5 s apart, from the same boot,
# up >= 60 s, within 300 s. A node still out after 300 s is a FAIL row of its own (a finding, not a SKIP)
# and leaves the fleet so it is not waited for again; later suites SKIP it with their reason, nothing hidden.
FLEET=""
fleet_init() { local n; for n in "$@"; do [ -n "$n" ] || continue; case " $FLEET " in *" $n "*) continue;; esac
  if up "$n"; then FLEET="$FLEET $n"; else echo "fleet: $n not reachable at start — not settled for (its suites SKIP with a reason)"; fi; done
  FLEET=${FLEET# }; echo "fleet: [$FLEET]"; }
node_stable() { local n=$1 t0=$SECONDS k=0 p="" o b u
  while [ $((SECONDS - t0)) -lt "${FLEET_SETTLE_MAX:-300}" ]; do
    o=$(fssh "$n" 12 'echo "$(cat /proc/sys/kernel/random/boot_id) $(cut -d. -f1 /proc/uptime)"' 2>/dev/null | tr -d '\r')
    b=${o% *}; u=${o##* }
    if [ -n "$o" ] && isint "$u" && [ "$u" -ge 60 ] && { [ "$k" = 0 ] || [ "$b" = "$p" ]; }; then
      k=$((k + 1)); p=$b; [ "$k" -ge 3 ] && return 0
    else k=0; fi
    sleep 5
  done; return 1; }
fleet_settle() { local name=$1 kind=$2 n down="" keep="" row t0=$SECONDS
  [ -n "$FLEET" ] || return 0
  if [ "$kind" != D ]; then for n in $FLEET; do up "$n" || down="$down $n"; done; [ -z "$down" ] && return 0; fi
  for n in $FLEET; do
    if node_stable "$n"; then keep="$keep $n"
    else
      row="fleet-settle-after-$name"
      { echo "# $(date -Is)"; echo "FAIL fleet node $n not stably reachable within ${FLEET_SETTLE_MAX:-300} s after $name — left the fleet; later suites SKIP it"; } >> "$DIR/$row.log"
      NFAIL=$((NFAIL+1)); FAILED+=("$row"); ROWS+=("| $row | **FAIL** | node $n not back within ${FLEET_SETTLE_MAX:-300}s after $name |"); echo "FAIL  $row ($n)"
    fi
  done
  FLEET=${keep# }; echo "      fleet settled after $name in $((SECONDS - t0)) s${down:+ (was down:$down)}"; }
