# shellcheck shell=sh
# scripts/node/prov-tools-254.sh — tier A (#254 PR-H1 §4.9): the tools the provisioning code relies on exist AND behave.
# Sent as `ssh root@<n> sh -s < prov-tools-254.sh`. Uses only the harness scratch dir; leaves nothing behind.
# Exit 0 = all held. Negative control: run with PATH=/nonexistent -> FAIL.
rc=0
fail() { echo "FAIL $*"; rc=1; }
H=/tmp/run/batman-dv
{ [ -d "$H" ] || /bin/mkdir -m 700 "$H"; } && [ -O "$H" ] && [ ! -L "$H" ] || { echo "FAIL harness scratch $H unusable"; exit 1; }
t="$H/prov-tools.$$"; : > "$t" || { echo "FAIL cannot create $t"; exit 1; }

r=$(readlink -f /var/lib/bluetooth 2>/dev/null)
[ "$r" = /tmp/lib/bluetooth ] && echo "ok   readlink -f /var/lib/bluetooth = $r" || fail "readlink -f /var/lib/bluetooth = [$r]"
mountpoint -q /tmp 2>/dev/null && echo "ok   mountpoint -q /tmp" || fail "mountpoint -q /tmp did not succeed"
fsync "$t" 2>/dev/null && echo "ok   fsync <file>" || fail "fsync <file> failed"
if flock -n "$t" true 2>/dev/null; then
	# contention: while one holder keeps the lock, a second -n attempt must fail
	flock -n "$t" sleep 3 2>/dev/null &
	h=$!; sleep 1
	if flock -n "$t" true 2>/dev/null; then fail "flock -n succeeded while another process held the lock"
	else echo "ok   flock: free lock taken, held lock refused"; fi
	wait $h 2>/dev/null
else
	fail "flock -n on a free lock failed"
fi
/bin/rm -f "$t"		# absolute: the PATH negative control must not leave it behind
[ $rc = 0 ] && echo "PASS prov-tools-254"
exit $rc
