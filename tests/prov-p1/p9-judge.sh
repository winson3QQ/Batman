#!/bin/bash
# tests/prov-p1/p9-judge.sh <prov-p9-254.sh> — #254 preflight P9's node judge (docs/design/254-h23-harness.md §4.7,
# §23.4) on fixtures: a fake root (P9_TEST_ROOT) with /rom, p6 state, /boot/autoboot.txt, bootfacts, helper and
# batman-slot, and stub batman-slot / mount / umount / logread / pidof on PATH. Each case changes ONE thing from a
# clean baseline and must FAIL / WARN for its own reason; the clean ones must say "P9 clean" with no WARN.
# Runs as any user (no root, no node). A run with zero cases FAILs.
set -u
J=$(readlink -f "${1:?usage: $0 <scripts/node/prov-p9-254.sh>}"); [ -f "$J" ] || { echo "FAIL no $J"; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; R=$T/root; B=$T/bin; mkdir -p "$B"
# the stubs below must be reached through PATH: busybox ash runs its own applets (pidof, mount, logread) instead, so
# the judge runs under sh here and busybox only checks its syntax (the node's shell)
cases=0; fails=0
if command -v busybox >/dev/null 2>&1; then busybox sh -n "$J" || { echo "FAIL $J does not parse in busybox sh"; exit 1; }; fi
ok(){ echo "ok   $*"; }; no(){ echo "FAIL $*"; fails=$((fails+1)); }
V=1.5.14-wsl.8+eee3f3a.fwccd0974; VW=$V.dirty.wbox-chan
# stubs: batman-slot answers from env; mount copies $R/slot-<pN> into the mountpoint (a read-only squashfs stand-in)
cat > "$B/batman-slot" <<'EOS'
#!/bin/sh
case "$1" in
	active) echo "$G_ACT" ;; is-trial) exit "$G_TRIAL" ;; layout) echo "${G_LAYOUT:-pi4}" ;;
	fw-part) [ "${G_FWEMPTY:-0}" = 1 ] && exit 1; case "$2" in A) echo 1 ;; B) echo 2 ;; esac ;;
	bootinfo) [ -n "${G_BI:-}" ] && printf '%s
' "-- slot $2" "$G_BI" ;;
esac
EOS
# the UD unit's P9 lines (254-v16-ud §4.3): uci changes from G_UCI; config-save --check answers the rc sequence G_CS
printf '#!/bin/sh
[ "$1" = changes ] && [ -n "${G_UCI:-}" ] && echo "$G_UCI"; exit 0
' > "$B/uci"
cat > "$B/batman-config-save" <<'EOS'
#!/bin/sh
n=$(cat "$P9_TEST_ROOT/cs.n" 2>/dev/null || echo 0); n=$((n + 1)); echo $n > "$P9_TEST_ROOT/cs.n"
rc=$(echo "${G_CS:-0}" | cut -d' ' -f$n); [ -n "$rc" ] || rc=$(echo "${G_CS:-0}" | awk '{print $NF}')
[ "$rc" = 5 ] && echo "p5 stale: wireless.default_radio0.ssid"
exit "$rc"
EOS
cat > "$B/mount" <<'EOS'
#!/bin/sh
for a; do d=$a; done; for a; do case "$a" in /dev/*) dev=$a ;; esac; done
[ "${G_MOUNTFAIL:-0}" = 1 ] && exit 32
src=$P9_TEST_ROOT/slot-${dev##*mmcblk0}; [ -d "$src" ] || exit 32
cp -a "$src"/. "$d"/
EOS
printf '#!/bin/sh\nrm -rf "${1:?}"/* 2>/dev/null; exit 0\n' > "$B/umount"
printf '#!/bin/sh\ncat "$P9_TEST_ROOT/logread" 2>/dev/null\n' > "$B/logread"
printf '#!/bin/sh\necho "${G_HPID:-4242}"\n' > "$B/pidof"
chmod 755 "$B"/*
stamp(){ mkdir -p "$1/etc"; printf 'BATMAN_VERSION=%s\n' "$2" > "$1/etc/batman-build"; [ -n "${3:-}" ] && echo "BATMAN_WBOX=$3" >> "$1/etc/batman-build"; return 0; }
base(){ rm -rf "$R"; mkdir -p "$R/opt/batdata/state" "$R/boot" "$R/usr/lib/batman" "$R/usr/bin" "$R/usr/sbin" "$R/tmp/run/batman-dv/bt" "$R/tmp/run/batman-dv/ble-state"
	stamp "$R/rom" "$V"; stamp "$R/slot-p2" "$V"; stamp "$R/slot-p4" "$V"
	echo "$V" > "$R/opt/batdata/state/slot-A.protected"; echo "$V" > "$R/opt/batdata/state/slot-B.protected"
	printf '[all]\ntryboot_a_b=1\nboot_partition=1\n\n[tryboot]\nboot_partition=2\n' > "$R/boot/autoboot.txt"
	printf 'bf_ab_all() { sed -n "/^\\[all\\]/,/^\\[/s/^boot_partition=//p" "${1:-/boot}/autoboot.txt" 2>/dev/null | head -n 1; }\nbf_dt() { [ "$1" = tryboot ] && echo "${G_DTTRY:-00000000}"; return 0; }\n' > "$R/usr/lib/batman/bootfacts.sh"
	printf '#!/bin/sh\n[ "$1" = --version ] && echo "batman-provhelper x" && exit 0\nexit 2\n' > "$R/usr/bin/batman-provhelper"; chmod 755 "$R/usr/bin/batman-provhelper"
	printf 'wbox_gate_self\necho "holds a -wbox test image"\n' > "$R/usr/sbin/batman-slot"
	: > "$R/mountinfo"; : > "$R/logread"
	G_ACT=A G_TRIAL=1 G_DTTRY=00000000 G_LAYOUT=pi4 G_MOUNTFAIL=0 G_FWEMPTY=0 G_BI="" G_UCI="" G_CS=0; }
run(){ OUT=$(env -i PATH="$B:/usr/bin:/bin" P9_TEST_ROOT="$R" G_ACT="$G_ACT" G_TRIAL="$G_TRIAL" G_DTTRY="$G_DTTRY" G_LAYOUT="$G_LAYOUT" G_MOUNTFAIL="$G_MOUNTFAIL" G_FWEMPTY="$G_FWEMPTY" G_BI="$G_BI" G_UCI="$G_UCI" G_CS="$G_CS" P9_RETRY_S=0 sh "$J" 2>&1); RC=$?; }
# want <case> clean|clean-nowarn|warn:<text>|fail:<text>|info:<text>
want(){ cases=$((cases+1)); local w=$2
	case "$w" in
		clean) [ $RC = 0 ] && grep -q '^P9 clean$' <<< "$OUT" ;;
		clean-nowarn) [ $RC = 0 ] && grep -q '^P9 clean$' <<< "$OUT" && ! grep -q '^WARN' <<< "$OUT" ;;
		warn:*) [ $RC = 0 ] && grep -q "^WARN .*${w#warn:}" <<< "$OUT" ;;
		info:*) [ $RC = 0 ] && grep -q "^INFO .*${w#info:}" <<< "$OUT" ;;
		fail:*) [ $RC != 0 ] && grep -q "^FAIL .*${w#fail:}" <<< "$OUT" ;;
	esac && ok "$1" || no "$1 — want $w: rc=$RC $(tr '\n' '|' <<< "$OUT" | cut -c1-300)"; }
base; run; want "baseline: committed A, [all]=A" clean-nowarn
base; G_ACT=B G_TRIAL=0 G_DTTRY=00000001; run; want "release trial on B ([all]=A, DT tryboot=1): clean, no WARN" clean-nowarn
base; G_ACT=B G_TRIAL=0 G_DTTRY=00000001; stamp "$R/slot-p2" "$VW" chan; echo "$VW" > "$R/opt/batdata/state/slot-A.protected"; run; want "[all] points at a wbox slot during a trial" "fail:\[all\] points at slot A, a -wbox image"
base; G_ACT=B G_TRIAL=1; run; want "stale fallback: running B committed-looking, [all]=A release -> WARN only" "warn:stale fallback"
base; G_ACT=B G_TRIAL=1; stamp "$R/slot-p2" "$VW" chan; run; want "[all] points at a wbox slot (not a trial)" "fail:\[all\] points at slot A, a -wbox image"
base; printf '[all]\nboot_partition=\n' > "$R/boot/autoboot.txt"; run; want "[all] unreadable" "fail:\[all\] boot_partition unreadable"
base; G_ACT=B G_TRIAL=1; G_MOUNTFAIL=1; run; want "[all] slot cannot be mounted" "fail:cannot be mounted"
base; G_ACT=B G_TRIAL=1; rm -f "$R/slot-p2/etc/batman-build"; run; want "[all] slot stamp unreadable" "fail:stamp is unreadable"
base; G_ACT=B G_TRIAL=1; rm -f "$R/slot-p2/etc/batman-build"; echo "BATMAN_VERSION=$V" > "$T/real"; ln -s "$T/real" "$R/slot-p2/etc/batman-build"; run; want "[all] slot stamp is a symlink (not followed)" "fail:stamp is unreadable"
base; G_ACT=B G_TRIAL=1; echo 1.5.12-wsl.9 > "$R/opt/batdata/state/slot-A.protected"; run; want ".protected disagrees with the slot's own stamp" "fail:slot-A.protected \[1.5.12-wsl.9\] != slot A's own stamp"
base; rm -f "$R/boot/autoboot.txt"; G_LAYOUT=golden; run; want "golden Pi 4 (no autoboot.txt): [all] not applicable" "info:not applicable"
base; stamp "$R/rom" "$VW" chan; run; want "the committed running slot is a wbox image" "fail:COMMITTED running slot A is a -wbox"
base; echo "$VW" > "$R/opt/batdata/state/slot-B.protected"; stamp "$R/slot-p4" "$VW" chan; run; want "slot B holds a wbox image" "fail:slot B holds a -wbox image"
base; printf 'x BATMAN_PROV_TEST_BUILD_7f3a x\n' >> "$R/usr/bin/batman-provhelper"; run; want "the running helper carries the marker" "fail:carries the prov_test marker"
base; echo 'Jul 1 daemon.info batman-provhelper[4242]: killpoint txn-2: armed' > "$R/logread"; run; want "the helper has a killpoint armed" "fail:has a killpoint armed"
base; printf '#!/bin/sh\nexit 2\n' > "$R/usr/bin/batman-provhelper"; run; want "pre-P1b helper: INFO only" "info:pre-P1b helper"
base; : > "$R/usr/sbin/batman-slot"; run; want "pre-gate image: INFO only (-wbox units stop before any OTA)" "info:pre-gate image"
base; echo "pbase1 abcd snap" > "$R/opt/batdata/state/dv-prov-dirty"; run; want "dirty flag" "fail:dv-prov-dirty"
base; echo "pnorm1 abcd" > "$R/opt/batdata/state/dv-prov-normalising"; run; want "normalising marker" "fail:dv-prov-normalising"
base; echo '266 23 0:19 /run/batman-dv/wbox/r1/test /usr/bin/batman-provhelper rw - tmpfs tmpfs rw' > "$R/mountinfo"; run; want "a harness bind left" "fail:harness bind mounts left: /usr/bin/batman-provhelper"
base; mkdir -p "$R/tmp/run/batman-prov-test"; run; want "killpoint dir left" "fail:the killpoint dir .*batman-prov-test exists"
base; mkdir -p "$R/opt/batdata/dv-prov"; : > "$R/opt/batdata/dv-prov/ch1-deadman.sh"; run; want "chain-1 dead-man left" "fail:chain-1 dead-man"
base; echo "slot=B version=$VW" > "$R/opt/batdata/state/bad-slot"; run; want "bad-slot present" "fail:bad-slot \[slot=B"
base; mkdir -p "$R/tmp/run/batman-dv/r1"; sleep 300 & sp=$!; echo $sp > "$R/tmp/run/batman-dv/r1/rbarm.pid"; run; kill $sp; want "a rollback arm still running (rbarm.pid alive)" "fail:rollback arm is still running"
base; mkdir -p "$R/tmp/run/batman-dv/r1"; echo 999999 > "$R/tmp/run/batman-dv/r1/rbarm.pid"; run; want "a dead rbarm.pid is no FAIL" clean
base; echo "r1 $(cat /proc/sys/kernel/random/boot_id) 99999" > "$R/tmp/run/batman-dv/bt/lease-prov"; run; want "a prov lease of this boot left" "fail:lease-prov of run r1"
base; echo 900 > "$R/opt/batdata/state/autocommit.timeout"; run; want "autocommit.timeout > 600 is printed" "info:autocommit.timeout=900"
# §23.4: batman-slot fw-part / active answering nothing (detect_layout died) is a FAIL, not "nothing to judge" (audit item 8)
base; G_FWEMPTY=1; run; want "batman-slot fw-part unreadable" "fail:fw-part / active unreadable"
base; G_ACT=""; run; want "batman-slot active unreadable" "fail:fw-part / active unreadable"
# the recovery script's pid file counts like the arm's (§23.2)
base; mkdir -p "$R/tmp/run/batman-dv/r1"; sleep 300 & sp=$!; echo $sp > "$R/tmp/run/batman-dv/r1/rbfix.pid"; run; kill $sp; want "a recovery (rbfix.pid) still running" "fail:rollback arm is still running"
# ---- #254 v1.6 g4 PR B (254-v16-ud §4.3 "P9 scope", §7, §7.1): the UD-RECOVER block and the gated / ungated lines
UD=pupdate2541123120000
blockok(){ grep -qx "UD-RECOVER-BEGIN $UD" <<< "$OUT" && grep -qx "UD-RECOVER-END $UD" <<< "$OUT" 	&& ! sed -n '/^UD-RECOVER-BEGIN/,/^UD-RECOVER-END/p' <<< "$OUT" | grep -qE '@(DEAD|V)@' 	&& sed -n '/^UD-RECOVER-BEGIN/,/^UD-RECOVER-END/p' <<< "$OUT" | grep -q "RUN=$UD PR_V=$V PR_BASE=member" 	&& [ "$(sed -n '/^UD-RECOVER-BEGIN/,/^UD-RECOVER-END/p' <<< "$OUT" | grep -c '@NODE@')" = 2 ]; }
base; echo "$UD 1a2b3c4d snap" > "$R/opt/batdata/state/dv-prov-dirty"; run; want "dirty flag of a prov-update-254 run: NEEDS-PERSON line" "fail:run $UD of prov-update-254 stopped mid-arm"
cases=$((cases + 1)); blockok && ok "  ... and the UD-RECOVER block with @DEAD@ / @V@ replaced, @NODE@ left for the host" || no "UD-RECOVER block: $(sed -n '/^UD-RECOVER-BEGIN/,/^UD-RECOVER-END/p' <<< "$OUT" | head -3 | tr '
' '|')"
for bad in pfoo2541123120000 " 1a2b snap" "pupdate254x/../.. 1a2b snap" pupdate2541123 pupdate25411231200000; do
	base; echo "$bad" > "$R/opt/batdata/state/dv-prov-dirty"; run
	cases=$((cases + 1)); if grep -q '^FAIL dv-prov-dirty .*run scripts/dv/prov-254.sh restore' <<< "$OUT" && ! grep -q 'UD-RECOVER' <<< "$OUT"; then ok "dirty flag [$bad]: the generic line, no block"; else no "dirty flag [$bad]: $(tr '
' '|' <<< "$OUT" | cut -c1-200)"; fi
done
base; echo "$UD 1a2b snap" > "$R/opt/batdata/state/dv-prov-dirty"; echo 'x/y&z' > "$R/opt/batdata/state/slot-A.protected"; run
cases=$((cases + 1)); grep -q '^FAIL dv-prov-dirty .*run scripts/dv/prov-254.sh restore' <<< "$OUT" && ! grep -q 'UD-RECOVER' <<< "$OUT" && ok "a slot-A version with / or & never reaches sed: the generic line" || no "bad V: $(tr '
' '|' <<< "$OUT" | cut -c1-200)"
base; mkdir -p "$R/opt/batdata/state/dv-undo/$UD"; echo "3 todo slot:A ssid-restore 6162" > "$R/opt/batdata/state/dv-undo/$UD/journal"; run; want "a pending undo journal: WARN" "warn:undo journal pending: $UD"
base; mkdir -p "$R/proc/4321"; printf 'sh\0/tmp/run/batman-dv/bt/x/ud9-watch-254.sh\0kill\0' > "$R/proc/4321/cmdline"; run; want "a live ud9-watch: FAIL" "fail:a ud9-watch is alive .pid 4321."
base; G_BI="bad=1 verified="; run; want "slot B bad=1, no UD dirty flag: WARN" "warn:slot B is BAD"
base; G_BI="bad=1 verified="; echo "$UD 1a2b snap" > "$R/opt/batdata/state/dv-prov-dirty"; run; want "slot B bad=1 with a UD dirty flag: FAIL" "fail:slot B is BAD .* — run $UD"
base; echo "$UD 1a2b snap" > "$R/opt/batdata/state/dv-prov-dirty"; mkdir -p "$R/opt/batdata/dv-prov/$UD/snap/state"; echo old > "$R/opt/batdata/dv-prov/$UD/snap/state/update-last"; echo new > "$R/opt/batdata/state/update-last"; run
want "update-last != the run's snapshot copy: FAIL" "fail:update-last differs from run $UD"
base; echo "$UD 1a2b snap" > "$R/opt/batdata/state/dv-prov-dirty"; mkdir -p "$R/opt/batdata/dv-prov/$UD/snap/state"; echo same > "$R/opt/batdata/dv-prov/$UD/snap/state/update-last"; echo same > "$R/opt/batdata/state/update-last"; run
cases=$((cases + 1)); grep -q 'update-last' <<< "$OUT" && no "an update-last equal to the snapshot copy was reported" || ok "update-last equal to the snapshot copy: nothing"
base; echo 1.5.14-wsl.36 > "$R/opt/batdata/state/autocommit-hold-commit"; run; want "hold flag on a committed boot, ungated: WARN" "warn:the hold flag"
base; G_UCI="wireless.default_radio0.ssid='x'"; run; want "uci changes staged: WARN" "warn:uci has 1 staged change"
base; G_CS=5; echo "$UD 1a2b snap" > "$R/opt/batdata/state/dv-prov-dirty"; run; want "--check rc 5 with a UD dirty flag: FAIL" "fail:batman-config-save --check rc 5"
base; G_CS="8 8 0"; run; want "--check rc 8 twice, then 0: clean (retried)" clean-nowarn
base; G_CS="8 8 8 8"; run; want "--check rc 8 four times: INFO, not judged" "info:rc 8 .busy. after 3 retries"
base; G_CS=3; run; want "--check rc 3: INFO" "info:batman-config-save --check rc 3"
[ "$cases" -gt 0 ] || { echo "FAIL no case ran"; exit 1; }
echo "P9-JUDGE cases=$cases fails=$fails"; [ "$fails" = 0 ]
