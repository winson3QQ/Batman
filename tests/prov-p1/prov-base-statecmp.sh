#!/bin/bash
# tests/prov-p1/prov-base-statecmp.sh — CI/WSL test of prov-base compare's p6 state rules (round-7 B-M6): boot_id-only changes pass, real changes fail.
# $1 = prov-base-254.sh. Runs as root (the script refuses otherwise) under a throwaway PROV_BASE_TEST_ROOT.
PB=$1; R=$(mktemp -d); export PROV_BASE_TEST_ROOT=$R; fails=0
mkdir -p "$R/usr/lib/batman" "$R/tmp/run"; printf 'batman_rundir(){ return 0; }\nRUNDIR=%s/tmp/run/batman\n' "$R" > "$R/usr/lib/batman/rundir.sh"   # the fixed prov-base sources it through the test root
D=$R/opt/batdata/dv-prov/t1; mkdir -p $D/snap/state $D/now-x/state
for f in p5.manifest upper.manifest uci.export identity; do echo same > $D/snap/$f; echo same > $D/now-x/$f; done
setstate(){ # $1 snap|now-x, $2 name, $3 content or ABSENT
	rm -f $D/$1/state/$2; [ "$3" = ABSENT ] || printf '%s\n' "$3" > $D/$1/state/$2; }
base(){ for t in snap now-x; do rm -f $D/$t/state/*
	setstate $t lock-status UNPROVISIONED; setstate $t mesh-expected "seeded --on-join"; done
	setstate snap prov-state "aaaa helper legacy legacy - today"; setstate now-x prov-state "bbbb helper legacy legacy - today"
	setstate snap ble-ok aaaa; setstate now-x ble-ok bbbb; }
run(){ # $1 want rc, $2 label
	out=$(sh "$PB" compare t1 x 2>&1); rc=$?
	if [ "$rc" = "$1" ]; then echo "ok   $2 (rc=$rc)"; else echo "FAIL $2: rc=$rc want=$1 :: $(echo "$out" | grep DIFF | head -3)"; fails=$((fails+1)); fi; }
base; run 0 "only boot_ids differ (prov-state field 1, ble-ok content)"
base; setstate now-x prov-state "bbbb helper claimed claimed - 0"; run 1 "prov-state verdict changed"
base; setstate now-x ble-ok ABSENT; run 1 "ble-ok vanished"
base; setstate now-x lock-status LOCKED; run 1 "lock-status changed"
base; setstate snap ota-armed.mesh "aaaa B joined"; run 0 "ota-armed.mesh consumed"
base; setstate now-x ota-armed.mesh "bbbb B joined"; run 1 "ota-armed.mesh appeared"
base; setstate snap ota-armed.mesh "aaaa B joined"; setstate now-x ota-armed.mesh "bbbb A radio"; run 1 "ota-armed.mesh slot/mode changed"
base; setstate now-x mesh-expected ABSENT; run 1 "mesh-expected vanished"
base; echo different > $D/now-x/p5.manifest; run 1 "p5 manifest differs (fresh test root: the diff dir did not exist, A-m12)"; echo same > $D/now-x/p5.manifest
base; rm -f $D/now-x/upper.manifest; run 1 "upper manifest missing on one side"; echo same > $D/now-x/upper.manifest
# overlay allow-list (tests/prov-p1/overlay-allow.txt): runtime churn of openmanetd's SQLite store is allowed as
# "content" (must exist on both sides); any other path, or the same path vanishing, still fails; no allow-list -> fails
AL=$(cd "$(dirname "$0")" && pwd)/overlay-allow.txt
m1="-rw-r--r-- 0:0 aaaa etc/openmanetd/openmanetd.db
-rw-r--r-- 0:0 bbbb etc/config/wireless"
m2="-rw-r--r-- 0:0 cccc etc/openmanetd/openmanetd.db
-rw-r--r-- 0:0 bbbb etc/config/wireless"
base; printf '%s
' "$m1" > $D/snap/upper.manifest; printf '%s
' "$m2" > $D/now-x/upper.manifest
ALLOW_FILE=$AL run 0 "openmanetd.db content differs -> allowed by overlay-allow.txt"
ALLOW_FILE=/nonexistent run 1 "same difference without an allow-list -> FAIL"
printf '%s
' "-rw-r--r-- 0:0 bbbb etc/config/wireless" > $D/now-x/upper.manifest; ALLOW_FILE=$AL run 1 "openmanetd.db vanished -> not covered by kind content -> FAIL"
printf '%s
' "-rw-r--r-- 0:0 aaaa etc/openmanetd/openmanetd.db
-rw-r--r-- 0:0 dddd etc/config/wireless" > $D/now-x/upper.manifest; ALLOW_FILE=$AL run 1 "etc/config/wireless content differs -> FAIL even with the allow-list"
printf '%s
' "-rw-r--r-- 0:0 aaaa etc/board.json" > $D/snap/upper.manifest; printf '%s
' "-rw-r--r-- 0:0 bbbb etc/board.json" > $D/now-x/upper.manifest
ALLOW_FILE=$AL run 0 "etc/board.json content differs (board_detect per-boot probe) -> allowed"
echo same > $D/snap/upper.manifest; echo same > $D/now-x/upper.manifest
# review A-M1: overlay-restore keeps an extra directory that /rom has ($D/kept-dirs); compare drops exactly those "+ d" lines
printf '%s\n' "-rw-r--r-- 0:0 aaaa etc/x" > $D/snap/upper.manifest
printf '%s\n' "-rw-r--r-- 0:0 aaaa etc/x" "drwxr-xr-x 0:0 - usr" "drwxr-xr-x 0:0 - usr/bin" > $D/now-x/upper.manifest
base; rm -f $D/kept-dirs; ALLOW_FILE=/nonexistent run 1 "extra upper dirs, no kept-dirs list -> FAIL"
base; printf 'usr\nusr/bin\n' > $D/kept-dirs; ALLOW_FILE=/nonexistent run 0 "extra upper dirs listed in kept-dirs -> dropped"
base; printf 'usr\n' > $D/kept-dirs; ALLOW_FILE=/nonexistent run 1 "only one of two extra dirs listed -> the other still FAILs"
printf '%s\n' "-rw-r--r-- 0:0 aaaa etc/x" "-rw-r--r-- 0:0 cccc usr" > $D/now-x/upper.manifest
base; printf 'usr\n' > $D/kept-dirs; ALLOW_FILE=/nonexistent run 1 "a FILE at a kept-dirs path -> not dropped (directories only)"
printf '%s\n' "-rw-r--r-- 0:0 aaaa etc/x" > $D/now-x/upper.manifest
printf '%s\n' "-rw-r--r-- 0:0 aaaa etc/x" "drwxr-xr-x 0:0 - usr" > $D/snap/upper.manifest
base; printf 'usr\n' > $D/kept-dirs; ALLOW_FILE=/nonexistent run 1 "a snapshot dir that VANISHED (- d) -> not dropped"
rm -f $D/kept-dirs; echo same > $D/snap/upper.manifest; echo same > $D/now-x/upper.manifest
rm -rf $R; echo "STATECMP fails=$fails"; [ $fails = 0 ]
