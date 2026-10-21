# shellcheck shell=sh
# scripts/node/ble-privacy-254.sh — tier-A BLE privacy judge (#254 PR-H1 §4.3). READ-ONLY: changes nothing on the
# node and stages no tool. Sent as `cat ble-lib-254.sh ble-privacy-254.sh | ssh root@<n> sh -s`.
# Every check reads the live node; anything unreadable is a FAIL. Exit 0 = all held.
rc=0
echo "node: $(sed -n 's/^BATMAN_VERSION=//p' /etc/batman-build) boot=$(bootid | cut -c1-8) up=$(up_s)s"

# 1. patch 900 status file: this boot, the live bluetoothd, mode 2 (only), status 0
sc_check && echo "ok   batman-sc: $(cat /var/lib/bluetooth/batman-sc)" || rc=1

# 2. current settings (non-interactive bluetoothctl registers no agent, E6) — tokens of that ONE line only
s=$(settings)
if [ -z "$s" ]; then fail "no 'current settings:' line from bluetoothctl mgmt.info"; rc=1
else
	bad=""
	for t in powered le secure-conn privacy; do has_tok "$s" "$t" || bad="$bad missing:$t"; done
	for t in bondable br/edr connectable discoverable; do has_tok "$s" "$t" && bad="$bad present:$t"; done
	if [ -n "$bad" ]; then fail "current settings [$s]:$bad"; rc=1; else echo "ok   current settings: $s"; fi
fi

# 3. the store: /var/lib/bluetooth -> /tmp/lib/bluetooth on tmpfs, root-only
t=$(readlink -f /var/lib/bluetooth)
[ "$t" = /tmp/lib/bluetooth ] || { fail "/var/lib/bluetooth resolves to [$t], not /tmp/lib/bluetooth"; rc=1; }
mountpoint -q /tmp && grep -q '^tmpfs /tmp tmpfs ' /proc/mounts || { fail "the tmp mount is not a tmpfs mountpoint"; rc=1; }
set -- $(lsinfo /tmp/lib)
case "$1" in d????-??-?) [ "$2" = 0 ] || { fail "/tmp/lib owner uid $2"; rc=1; };; *) fail "/tmp/lib mode [$1] (group/world writable or not a dir)"; rc=1;; esac
set -- $(lsinfo /tmp/lib/bluetooth)
[ "$1" = drwx------ ] && [ "$2" = 0 ] || { fail "/tmp/lib/bluetooth is [$1 uid $2], want drwx------ root"; rc=1; }
[ -L /tmp/lib ] || [ -L /tmp/lib/bluetooth ] && { fail "/tmp/lib or /tmp/lib/bluetooth is a symlink"; rc=1; }
n=0
for f in /tmp/lib/bluetooth/*/identity; do
	[ -e "$f" ] || continue; n=$((n + 1))
	file_ok "$f" && [ "$(ls -ln "$f" | awk '{print $1}')" = "-rw-------" ] || { fail "$f is not a 0600 root regular file"; rc=1; }
done
[ $n -ge 1 ] || { fail "no adapter identity file (privacy has no IRK on disk?)"; rc=1; }
[ $rc = 0 ] && echo "ok   store: tmpfs, /tmp/lib root, bluetooth 0700, $n identity file(s) 0600"

# 4. no AF_ALG (loaded or loadable), no bluetooth in sysupgrade keep lists, no old /etc keys dir
grep -q '^ALG ' /proc/net/protocols && { fail "AF_ALG is registered (/proc/net/protocols)"; rc=1; }
m=$(find "/lib/modules/$(uname -r)" -name 'af_alg*' -o -name 'algif_*' 2>/dev/null | head -3)
[ -z "$m" ] || { fail "AF_ALG modules present: $m"; rc=1; }
k=$(grep -ls bluetooth /lib/upgrade/keep.d/* 2>/dev/null)
[ -z "$k" ] || { fail "sysupgrade keeps bluetooth paths: $k"; rc=1; }
[ -e /etc/bluetooth/keys ] && { fail "/etc/bluetooth/keys exists (pre-tmpfs IRK store)"; rc=1; }

# 5. nothing an interrupted tier-B run left behind (flipped / irk-exposed / lease / deadman / harness procs / adv)
ble_state || rc=1

[ $rc = 0 ] && echo "PASS ble-privacy-254"
exit $rc
