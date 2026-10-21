#!/bin/sh
# scripts/node/prov-p1-254.sh — #254 PR-H2 tier A, read-only judge of the P1 provisioning helper on a node
# (docs/design/254-p1-impl.md §5.2 prov-boot-254). Runs as root via `ssh node sh -s`. Writes nothing persistent:
# --prov-get and the sysupgrade backup LIST go to a private dir under the root-only run dir, removed at the end.
# Every check prints PASS/FAIL; anything that cannot be read is a FAIL, never a skip. Exit 0 only with no FAIL.
set -u
RD=/tmp/run/batman-dv/prov-p1.$$
P=/etc/batman-prov
ST=/opt/batdata/state
fails=0
ok() { echo "PASS $*"; }
no() { echo "FAIL $*"; fails=$((fails + 1)); }
mkdir -p /tmp/run/batman-dv && chmod 700 /tmp/run/batman-dv && mkdir -m 700 "$RD" || { echo "FAIL cannot make $RD"; exit 1; }
trap 'rm -rf "$RD"' EXIT
boot=$(cat /proc/sys/kernel/random/boot_id)
up=$(cut -d. -f1 /proc/uptime)

# 0) the helper exists and runs (wsl.9 and older: this FAILs — that is the negative control)
[ -x /usr/bin/batman-provhelper ] || { no "no helper (/usr/bin/batman-provhelper missing)"; exit 1; }
pidof batman-provhelper >/dev/null && ok "helper running" || no "helper not running"

# 1) prov-state written this boot by the helper
set -- $(head -n 1 "$ST/prov-state" 2>/dev/null)
if [ $# -ge 6 ] && [ "$1" = "$boot" ] && [ "$2" = helper ]; then ok "prov-state this boot, writer=helper, verdict=$4 last_known=$3 mesh_expect=$6"
else no "prov-state not this boot / not the helper's: [$*]"; fi
verdict=${4:-}

# 2) overlay record == p5 record (generation and sha), identity dir permissions
case "$verdict" in unknown*) no "verdict is $verdict" ;; esac
om=$(cat "$P/prov.meta" 2>/dev/null)
[ -n "$om" ] && ok "overlay prov.meta present" || no "overlay prov.meta missing"
batman-config-save --prov-get "$RD/p5" >"$RD/get.out" 2>&1; grc=$?
[ "$grc" = 0 ] && ok "p5 --prov-get rc=0" || no "p5 --prov-get rc=$grc ($(tail -1 "$RD/get.out"))"
pm=$(cat "$RD/p5/prov.meta" 2>/dev/null)
[ -n "$om" ] && [ "$om" = "$pm" ] && ok "overlay prov.meta == p5 prov.meta" || no "overlay / p5 prov.meta differ"
if [ -f "$RD/p5/identity/sha256" ] && cmp -s "$RD/p5/identity/sha256" "$P/identity/sha256"; then ok "identity on p5 == overlay"; else no "identity on p5 != overlay (or missing)"; fi
d=$(ls -ld "$P/identity" 2>/dev/null | cut -c1-10); [ "$d" = drwx------ ] && ok "identity dir 0700" || no "identity dir mode [$d]"
for f in node.key ecdh.key claim.secret; do
	m=$(ls -l "$P/identity/$f" 2>/dev/null | cut -c1-10); [ "$m" = "-rw-------" ] && ok "$f 0600" || no "$f mode [$m]"
done

# 3) health file: this boot, fresh, every field present, consistent with the live system
h=$(cat /tmp/run/batman/batman-prov.health 2>/dev/null)
hb=$(echo "$h" | sed -n 's/.*boot_id=\([^ ]*\).*/\1/p'); hts=$(echo "$h" | sed -n 's/.* ts=\([0-9]*\).*/\1/p')
[ "$hb" = "$boot" ] && ok "health boot_id this boot" || no "health boot_id [$hb]"
[ -n "$hts" ] && [ $((up - hts)) -le 60 ] && ok "health fresh (age $((up - ${hts:-0}))s)" || no "health stale or missing ts [$hts] up=$up"
for k in bluetoothd hci0_powered adv_registered_once privacy sc sc_file bondable; do
	echo "$h" | grep -q " $k=[01]" || no "health field $k missing"
done
btd=0; pidof bluetoothd >/dev/null && btd=1
echo "$h" | grep -q " bluetoothd=$btd" && ok "health bluetoothd=$btd matches pidof" || no "health bluetoothd disagrees with pidof ($btd)"

# 4) --check: no prov staleness; no p5 write counters advanced (the helper persisted nothing on a quiet boot)
c=$(batman-config-save --check 2>&1); case "$c" in *"p5 stale: prov"*) no "--check reports prov stale: $c" ;; *) ok "--check: no prov staleness (${c##*: })" ;; esac

# 5) nothing of /etc/batman-prov travels in a sysupgrade backup (LIST only — no archive with secrets is written)
if sysupgrade -l >"$RD/backup.list" 2>/dev/null; then
	grep -q '^/etc/batman-prov' "$RD/backup.list" && no "sysupgrade -l lists /etc/batman-prov" || ok "sysupgrade -l does not list /etc/batman-prov ($(wc -l < "$RD/backup.list") entries)"
else no "sysupgrade -l failed"; fi
grep -rqs 'batman-prov' /lib/upgrade/keep.d/ && no "keep.d mentions batman-prov" || ok "keep.d does not keep /etc/batman-prov"

# 6) canary: no identity secret in the log ring (first 16 hex chars of claim.secret, base64 head of the keys)
cs=$(hexdump -v -e '/1 "%02x"' "$P/identity/claim.secret" 2>/dev/null | cut -c1-16)
[ -n "$cs" ] || no "claim.secret unreadable"
if [ -n "$cs" ] && logread 2>/dev/null | grep -qi "$cs"; then no "claim.secret appears in logread"; else ok "claim.secret not in logread"; fi

echo "prov-p1-254: fails=$fails verdict=${verdict:-?}"
[ "$fails" = 0 ]
