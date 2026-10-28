# shellcheck shell=bash
# scripts/dv/prov-dv-254.sh — sourced by scripts/daily-validation.sh: the #254 H2 prov units as suites
# (docs/design/254-h23-harness.md §4.4 order, §6.2). Each unit is its own script (scripts/dv/prov-<x>-254.sh) that ends
# with "UNIT <name> PASS|FAIL|INVALID"; the suite passes only on PASS with no FAIL line (cl_judge).
# 04-specific (MAC / peer 02 hard-coded in scripts/dv/prov-254.sh), like chain1-254.
# A unit that hands 04 to a person (NEEDS-PERSON, $DIR/needs-person.txt) blocks every later prov unit of the run:
# "FAIL blocked: DNODE …" (never a known failure, NEVER_KNOWN).
PV_TOOLS=${DV_PROV_TEST:-$HOME/batman-dv-tools/prov-test}
pv_ver() { cl_ssh "$1" 20 'sed -n "s/^BATMAN_VERSION=//p" /etc/batman-build'; }
# pv_pre <dnode>: the prov units' common preconditions
pv_pre() {
	local v
	[ "$1" = 10.41.1.3 ] || { echo "FAIL the prov units are 04-specific (MAC / peer 02 hard-coded in scripts/dv/prov-254.sh) and DNODE is $1"; return 1; }
	[ -s "$DIR/needs-person.txt" ] && { echo "FAIL blocked: DNODE — NEEDS-PERSON earlier in this run: $(tail -1 "$DIR/needs-person.txt")"; return 1; }
	v=$(pv_ver "$1"); case "$v" in *.wbox-*) v=${v%%.dirty.wbox-*} ;; esac
	[ -n "$v" ] || { echo "FAIL $1 unreachable (no BATMAN_VERSION)"; return 1; }
	[ -f "$PV_TOOLS/$v/test/batman-provhelper" ] || { echo "FAIL no prov test tools for $v in $PV_TOOLS — run: bash scripts/dv-prov-tools.sh $v"; return 1; }
	return 0
}
# bchk_prov_254 <dnode> <unit script name> [args...]
bchk_prov_254() {
	local n=$1 u=$2; shift 2
	pv_pre "$n" || return 1
	NODE=$n DV_DIR=$DIR bash "$REPO/scripts/dv/$u.sh" "$@" 2>&1 | cl_judge '^UNIT prov-[a-z0-9-]+-254 PASS$'
}
# bchk_prov_normalise_254 <dnode>: the head of the block — 04 committed on A with its running version
bchk_prov_normalise_254() {
	local v
	pv_pre "$1" || return 1
	v=$(pv_ver "$1")
	NODE=$1 DV_DIR=$DIR bash "$REPO/scripts/dv/prov-normalise-254.sh" "$v" 2>&1 | cl_judge '^UNIT prov-normalise-254 PASS$'
}
# the block, in order: name | script | args (§4.4: normalise -> base -> revert type -> hold type -> killpoint type ->
# chain 0 -> netjoin-fleet -> (7) -> legacy-upgrade)
# shellcheck disable=SC2034  # read by scripts/daily-validation.sh (section 2f2)
PROV_B_UNITS="prov-base-254|prov-base-254|
prov-ac-radio1off-254|prov-ac-radio1off-254|
prov-wbox-nocommit-254|prov-wbox-nocommit-254|
prov-ota-254|prov-ota-254|
prov-ac-noarm-254|prov-ac-noarm-254|
prov-ac-forge-254|prov-ac-forge-254|
prov-ac-ble-254|prov-ac-ble-254|
prov-ac-flap-254|prov-ac-flap-254|
prov-trial-busy-254|prov-trial-busy-254|
prov-downgrade-254|prov-downgrade-254|
prov-leave-ota-254|prov-leave-ota-254|
prov-overlay-corrupt-254|prov-overlay-corrupt-254|
prov-overlay-wipe-254|prov-overlay-wipe-254|
prov-netjoin-254|prov-netjoin-254|
prov-netupdate-254|prov-netupdate-254|
prov-misc-254|prov-misc-254|
prov-powerloss-txn1-254|prov-powerloss-254|1
prov-powerloss-txn2-254|prov-powerloss-254|2
prov-powerloss-txn2-neg-a-254|prov-powerloss-254|2 neg-a
prov-powerloss-txn2-neg-b-254|prov-powerloss-254|2 neg-b
prov-powerloss-txn3-254|prov-powerloss-254|3
prov-powerloss-txn3-neg-254|prov-powerloss-254|3 neg
prov-powerloss-txn4-254|prov-powerloss-254|4
prov-powerloss-txn5-254|prov-powerloss-254|5
prov-lock-failsecure-254|prov-lock-failsecure-254|
prov-claim-kp-254|prov-claim-kp-254|
prov-chain0-254|-|
prov-netjoin-fleet-254|-|
prov-ac-fleetchan-254|prov-ac-fleetchan-254|
prov-legacy-upgrade-254|prov-legacy-upgrade-254|"
