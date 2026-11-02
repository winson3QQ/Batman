#!/bin/bash
# scripts/dv/eh12-push-provd-254.sh — #254 H4 probe E-H12 (docs/design/254-h4-harness.md §5.3, §17): does a provd
# binary bind-mounted over /usr/bin/batman-provd (plus its test init over /etc/init.d/batman-provd) become THE jailed
# provd after one restart? ujail binds $PROG from the init's mount namespace, so it should see the bound file.
#
# Under the prov lease (host lock, staged scripts, deadman): the prov_test provd and its test init come from the
# -wbox test payload of $WBOX_V (default 1.5.14-wsl.21+2270e1e.fw45de3ea; payload sha checked against its SHA256SUMS);
# push-provd -> /proc/<jailed pid>/exe sha = the pushed binary; unbind-all -> provd restarted and /rom's again.
# Changes on 04: two provd restarts (BLE advertising off for a few seconds each), two binds in the run's tmpfs dir.
# Restore: unbind-all (also the lease deadman's first step), then the usual pr_release (radio / provd checks, lease).
# Runs from Git Bash on the Windows host.
PR_UNIT=prov-eh12-254
. "$(dirname "$0")/prov-254.sh"
WBOX_V=${WBOX_V:-1.5.14-wsl.21+2270e1e.fw45de3ea}
T=$(mktemp -d)
trap '[ "$PR_BEGUN" = 1 ] && pr_release; rm -rf "$T"' EXIT

pr_lock
o=$(pr_acquire 900) || { echo "$o"; pr_unlock; exit 1; }; PR_BEGUN=1
s=$(qr "$ST"); say "node: $s"

# the prov_test provd + test init of the wbox test payload (pr_rootfs_cat checks nothing itself: check the payload)
d="$PR_OUT/$WBOX_V.dirty.wbox-test/ekh-bcm2711"; p="$d/batman-$WBOX_V.dirty.wbox-test-ekh-bcm2711-ab-payload.tar.gz"
[ -f "$p" ] && grep -q "^$(sha256sum < "$p" | cut -c1-64)  $(basename "$p")\$" "$d/SHA256SUMS" \
	&& ok "wbox test payload matches its SHA256SUMS" || { no "wbox test payload missing / sha mismatch ($p)"; exit 1; }
pr_rootfs_cat "$WBOX_V.dirty.wbox-test" usr/bin/batman-provd > "$T/provd" < /dev/null
pr_rootfs_cat "$WBOX_V.dirty.wbox-test" etc/init.d/batman-provd > "$T/provd.init" < /dev/null
[ -s "$T/provd" ] && [ -s "$T/provd.init" ] || { no "could not read provd / its init from the payload"; exit 1; }
grep -q provd.env "$T/provd.init" && ok "the init read from the payload is the TEST init (reads provd.env)" || { no "not the test init"; exit 1; }
BS=$(sha256sum < "$T/provd" | cut -c1-64); IS=$(sha256sum < "$T/provd.init" | cut -c1-64)
RS=$(q 'sha256sum < /rom/usr/bin/batman-provd | cut -c1-64')
[ -n "$RS" ] && [ "$BS" != "$RS" ] && ok "pushed provd ${BS:0:16} differs from the release ${RS:0:16}" || { no "pushed provd is the release one"; exit 1; }

o=$(pw prep) || { no "W dir: $o"; exit 1; }
scp -q $SSHO "$T/provd" root@$NODE:/tmp/run/batman-dv/wbox/$RUN/provd-test && scp -q $SSHO "$T/provd.init" root@$NODE:/tmp/run/batman-dv/wbox/$RUN/provd-test.init || { no "scp"; exit 1; }
q "chmod 700 /tmp/run/batman-dv/wbox/$RUN/provd-test /tmp/run/batman-dv/wbox/$RUN/provd-test.init"

o=$(pw push-provd provd-test "$BS" provd-test.init "$IS"); say "$o"
grep -q '^PUSHED-PROVD' <<< "$o" && ok "E-H12: the jailed provd after one restart IS the bound binary (/proc/<pid>/exe sha)" || no "E-H12: push-provd: $o"
o=$(q 'for p in $(pidof batman-provd); do printf "%s exe=%s ppid=%s uid=%s\n" $p "$(readlink /proc/$p/exe)" "$(awk "/^PPid/{print \$2}" /proc/$p/status)" "$(awk "/^Uid/{print \$2}" /proc/$p/status)"; done'); say "processes: $(echo $o)"
grep -q 'uid=471' <<< "$o" && ok "the pushed provd still runs as uid 471 under ujail" || no "no uid-471 provd: $o"
sleep 20
o=$(pl provd-check 2>&1 | tail -3); say "provd-check (pushed): $(echo $o)"

o=$(pw unbind-all); say "$(echo $o)"
grep -q 'PROVD-RESTARTED' <<< "$o" && grep -q 'UNBIND-ALL ok' <<< "$o" && ok "unbind-all: provd restarted and /rom's again" || no "unbind-all: $o"
o=$(q 'awk "index(\$4, \"/batman-dv/wbox/\")" /proc/self/mountinfo | wc -l'); [ "$o" = 0 ] && ok "no harness bind left" || no "$o harness binds left"
pr_release; PR_BEGUN=0
say "fails=$fails invalid=$invalid"; [ "$fails" = 0 ] && echo "E-H12 PASS" || echo "E-H12 FAIL"
