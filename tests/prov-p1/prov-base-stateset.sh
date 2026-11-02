#!/bin/bash
# tests/prov-p1/prov-base-stateset.sh — CI/WSL test of prov-base state-set (autocommit (8)): only ble-ok, only inside a
# unit, present writes this boot's id, absent removes. $1 = prov-base-254.sh. Root, throwaway PROV_BASE_TEST_ROOT.
PB=$1; R=$(mktemp -d); export PROV_BASE_TEST_ROOT=$R; fails=0
mkdir -p "$R/usr/lib/batman" "$R/tmp/run" "$R/opt/batdata/state"; printf 'batman_rundir(){ return 0; }
RUNDIR=%s/tmp/run/batman
' "$R" > "$R/usr/lib/batman/rundir.sh"
# shellcheck disable=SC2034  # read by the eval checks in t()
ST=$R/opt/batdata/state
t(){ # <want rc> <label> <check cmd> -- args
	local w=$1 l=$2 c=$3; shift 4; out=$(sh "$PB" "$@" 2>&1); rc=$?
	if [ "$rc" = "$w" ] && eval "$c"; then echo "ok   $l"; else echo "FAIL $l: rc=$rc want=$w :: $out"; fails=$((fails+1)); fi; }
t 1 "no snapshot -> refused" '[ ! -e $ST/ble-ok ]' -- state-set u1 ble-ok present
mkdir -p "$R/opt/batdata/dv-prov/u1"
t 1 "other file -> refused" '[ ! -e $ST/lock-status ]' -- state-set u1 lock-status absent
t 1 "bad value -> refused" '[ ! -e $ST/ble-ok ]' -- state-set u1 ble-ok yes
t 0 "present -> this boot id" '[ "$(cat $ST/ble-ok)" = "$(cat /proc/sys/kernel/random/boot_id)" ]' -- state-set u1 ble-ok present
t 0 "absent -> removed" '[ ! -e $ST/ble-ok ]' -- state-set u1 ble-ok absent
t 0 "absent when already absent" '[ ! -e $ST/ble-ok ]' -- state-set u1 ble-ok absent
rm -rf "$R"; echo "prov-base-stateset: fails=$fails"; [ "$fails" = 0 ]
