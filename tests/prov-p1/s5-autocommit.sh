#!/bin/bash
# tests/prov-p1/s5-autocommit.sh <batman-autocommit> — #254 P3 S5 (254-p3-impl §3.7.6, D-16, D-17): health_ok wants
# inet fw4, a running helper (a disabled one: WARN once) and provd stable 60 s this boot (not required when provd or the
# helper is disabled); the BLE health line counts only when it is this boot's and <= 60 s old (WARN only). The blocks
# are extracted from the real file and run by busybox sh in a private mount namespace (stub /etc/init.d, stub nft, a
# scratch run dir). Root (or `unshare -r -m`). Nothing checked = FAIL: every check is counted and fewer than NMIN = FAIL.
# Negative controls (review r1 A-MAJOR-1 / B-M1, the BLE half used an undefined `ck` and passed vacuously): a copy
# without the boot_id / age test (the `[ "$hb" = … ] && … -le 60 ] ||` line and its `{ bh=""; … }`) FAILs good-other-boot
# and good-but-old; one without the provd-stable check FAILs provd-not-stable.
set -u
exec </dev/null
NMIN=18   # 10 health_ok cases + 3 WARN-log checks + 5 BLE cases
AC=$(readlink -f "${1:?usage: $0 <batman-autocommit>}")
[ "$(id -u)" = 0 ] || { echo "FAIL needs root (unshare -m)"; exit 1; }
grep -q 'provd-stable' "$AC" || { echo "FAIL $AC predates the S5 health checks: expected red until feat/254-p3 S5 lands (#254)"; exit 1; }
T=$(mktemp -d /tmp/act.XXXXXX)
mkdir -p $T/initd $T/bin $T/run
# the block from "inet fw4" to the end of the provd check, as a function
awk '/nft list table inet fw4/{on=1} on{print} on && /warn_once provd-disabled/{getline; print; exit}' "$AC" > $T/block
grep -q 'provd-stable' $T/block && grep -q 'inet fw4' $T/block || { echo "FAIL: block not extracted"; exit 1; }
{
	echo 'RUNDIR='$T/run
	echo 'log(){ echo "LOG $*" >> '$T'/log; }'
	sed -n '/^running(){/,/^}/p' "$AC"
	sed -n '/^warn_once(){/p' "$AC"
	echo 'p3check(){'; cat $T/block; echo 'return 0'; echo '}'
	echo 'p3check'
} > $T/fn.sh
grep -q '^warn_once' $T/fn.sh && grep -q '^running' $T/fn.sh || { echo "FAIL: helpers not extracted"; exit 1; }
stub_init() { # name enabled(0|1) running(0|1)
	printf '#!/bin/sh\ncase "$1" in enabled) exit %s ;; running) exit %s ;; esac\nexit 1\n' $((1 - $2)) $((1 - $3)) > $T/initd/$1
	chmod +x $T/initd/$1
}
fw() { if [ "$1" = 1 ]; then printf '#!/bin/sh\n[ "$*" = "list table inet fw4" ]\n' > $T/bin/nft; else printf '#!/bin/sh\nexit 1\n' > $T/bin/nft; fi; chmod +x $T/bin/nft; }
fail=0; n=0
pass() { n=$((n + 1)); echo "PASS $1"; }
flunk() { n=$((n + 1)); echo "FAIL $*"; fail=1; }
check() { # label want-rc want-text
	out=$(unshare -m sh -c "mount --bind $T/initd /etc/init.d && PATH=$T/bin:\$PATH busybox sh $T/fn.sh" 2>&1); rc=$?
	if [ "$rc" = "$2" ] && { [ -z "$3" ] || echo "$out" | grep -q "$3"; }; then pass "$1"; else flunk "$1: rc=$rc out=[$out] want rc=$2 [$3]"; fi
}
ck() { if [ "$2" = "$3" ]; then pass "$1"; else flunk "$1: got $2 want $3"; fi; }   # label got want
BOOT=$(cat /proc/sys/kernel/random/boot_id)
fw 1; stub_init batman-provhelper 1 1; stub_init batman-provd 1 1; echo "$BOOT" > $T/run/provd-stable
check all-good 0 ""
fw 0; check no-fw4 1 "inet fw4"
fw 1; stub_init batman-provhelper 1 0; check helper-down 1 "batman-provhelper down"
stub_init batman-provhelper 0 0; rm -f $T/run/autocommit.warn-*; : > $T/log
check helper-disabled 0 ""
grep -q "batman-provhelper is disabled" $T/log && pass helper-disabled-warned || flunk helper-disabled-warned
check helper-disabled-again 0 ""
[ "$(grep -c 'provhelper is disabled' $T/log)" = 1 ] && pass warned-once || flunk "warned-once ($(grep -c disabled $T/log))"
stub_init batman-provhelper 1 1
rm -f $T/run/provd-stable; check provd-not-stable 1 "not stable"
echo "00000000-0000-0000-0000-000000000000" > $T/run/provd-stable; check provd-stable-old-boot 1 "not stable"
stub_init batman-provd 0 0; check provd-disabled 0 ""
grep -q "batman-provd is disabled" $T/log && pass provd-disabled-warned || flunk provd-disabled-warned
# review r1 B-m2: the helper disabled, provd enabled and never stable: committable (only the helper writes the file)
stub_init batman-provhelper 0 0; stub_init batman-provd 1 1; rm -f $T/run/provd-stable $T/run/autocommit.warn-*
check helper-disabled-provd-not-required 0 ""
stub_init batman-provhelper 1 1
rm -f $T/initd/batman-provhelper; check no-helper-init 0 ""   # an image without the package: WARN
rm -rf "$T"

# ---- the BLE health line (WARN only)
T=$(mktemp -d /tmp/acb.XXXXXX)
awk '/if \[ -f "\$ST\/ble-ok" \] && \[ ! -f "\$RUNDIR\/autocommit.ble-warned" \]; then/{on=1} on{print} on && /^\tfi$/{exit}' "$AC" > $T/block
grep -q 'ble-warned' $T/block || { echo "FAIL: block not extracted"; cat $T/block; exit 1; }
run() { # <health line or -> -> warned yes|no
	rm -f $T/run/autocommit.ble-warned $T/log; mkdir -p $T/run $T/st; : > $T/st/ble-ok
	[ "$1" = - ] && rm -f $T/run/batman-prov.health || echo "$1" > $T/run/batman-prov.health
	{ echo "RUNDIR=$T/run; ST=$T/st"; echo 'up(){ cut -d. -f1 /proc/uptime; }'; echo "log(){ echo \"\$*\" >> $T/log; }"; cat $T/block; } > $T/s.sh
	busybox sh $T/s.sh; [ -f $T/run/autocommit.ble-warned ] && echo yes || echo no
}
B=$(cat /proc/sys/kernel/random/boot_id); U=$(cut -d. -f1 /proc/uptime)
G="bluetoothd=1 hci0_powered=1 adv_registered_once=1 privacy=1 sc=1 sc_file=1 bondable=0"
ck good-fresh "$(run "boot_id=$B ts=$U $G")" no
ck good-other-boot "$(run "boot_id=00000000-0000-0000-0000-000000000000 ts=$U $G")" yes
ck good-but-old "$(run "boot_id=$B ts=$((U - 120)) $G")" yes
ck bad-fresh "$(run "boot_id=$B ts=$U bluetoothd=0 hci0_powered=1 adv_registered_once=1")" yes
ck no-file "$(run -)" yes
rm -rf "$T"
[ "$n" -ge "$NMIN" ] || { echo "FAIL only $n checks ran, want >= $NMIN"; fail=1; }
[ $fail = 0 ] && { echo "S5-AUTOCOMMIT checks=$n ALL PASS"; exit 0; } || { echo "S5-AUTOCOMMIT checks=$n SOME FAIL"; exit 1; }
