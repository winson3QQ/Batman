#!/bin/bash
# tests/prov-p1/claim-lock-lints.sh <repo root> — #254 claim-lock fix: the cross-file contracts a unit test cannot see.
#  L1 the package installs /etc/init.d/batman-prov-lock AND enables it in postinst (no rc.d link = no boot-time lock,
#     and the rollback gate refuses every slot built from it)
#  L2 the helper's busy-retry match (node.go cfgSaveBusy) is a literal that batman-config-save really prints on rc 1:
#     rewording one side silently turns the retry off
#  L3 the two prov-lock.sh copies (feed / deploy) are identical
# Negative control: main 92f091c (1.5.13) -> L1 and L2 FAIL.
set -u
R=$(readlink -f "${1:?usage: $0 <repo root>}"); fails=0; cases=0
ok(){ echo "ok   $*"; }; no(){ echo "FAIL $*"; fails=$((fails+1)); }
c(){ cases=$((cases+1)); if eval "$2"; then ok "$1"; else no "$1"; fi; }
# shellcheck disable=SC2034  # used inside the eval'd conditions
MK=$R/feed/batman-provision/Makefile; F=$R/feed/batman-provision/files
c "L1 Makefile installs etc/init.d/batman-prov-lock" 'grep -q "INSTALL_BIN) ./files/etc/init.d/batman-prov-lock \$(1)/etc/init.d/batman-prov-lock" "$MK"'
c "L1 postinst enables batman-prov-lock" 'grep -E "^for s in .*[[:space:]]batman-prov-lock[[:space:];]" "$MK" | grep -q "; do"'
c "L1 the init exists and is START=13" '[ -f "$F/etc/init.d/batman-prov-lock" ] && grep -qx "START=13" "$F/etc/init.d/batman-prov-lock"'
lit=$(sed -n 's/.*func cfgSaveBusy.*//; s/.*strings\.Contains(out, "\([^"]*\)").*/\1/p' "$R/feed/batman-prov/src/node/node.go" | head -1)
c "L2 node.go cfgSaveBusy has a literal match (got: ${lit:-none})" '[ -n "$lit" ]'
c "L2 batman-config-save prints it on an exit 1 path" '[ -n "$lit" ] && grep -F "$lit" "$F/usr/bin/batman-config-save" | grep -q "exit 1"'
c "L3 feed and deploy prov-lock.sh identical" 'cmp -s "$F/usr/lib/batman/prov-lock.sh" "$R/deploy/provisioning/prov-lock.sh"'
echo "CLAIM-LOCK-LINTS cases=$cases fails=$fails"; [ "$cases" -gt 0 ] && [ $fails = 0 ]
