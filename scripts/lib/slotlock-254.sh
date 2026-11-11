# shellcheck shell=bash disable=SC2034  # a library: SLOTLK / SLK_LIB are read by the scripts that source it
# scripts/lib/slotlock-254.sh — host side of the #254 S5 slot flock (254-p3-impl §3.7.3) for harness scripts that
# mount a boot FAT on a node (ab-selftest, eh13-pre-254, prov-chain0-254) or check that the lock was released:
#   SLOTLK   the head of a remote command: scripts/node/slotlock-lib-254.sh + `slk_take || exit 1` — the FAT work after
#            it runs only with the slot flock held (fd 9, until the remote shell exits). When the lock cannot be had
#            (held for SLK_TRIES s, run dir unusable, open fails) the output holds a "SLOTLK-BUSY <why>" line and
#            nothing else ran: the caller judges INVALID (slk_busy), never a product FAIL.
#   SLK_LIB  the node lib alone (for slk_free / slk_ticks in a remote command)
#   slk_busy <output>   rc 0 when <output> carries a SLOTLK-BUSY line
# A missing node lib is an error here (rc 1 from the `.`), never an empty prefix that would mount without the lock.
_slk_f=$(dirname "${BASH_SOURCE[0]}")/../node/slotlock-lib-254.sh
if [ -r "$_slk_f" ]; then
	SLK_LIB=$(cat "$_slk_f")
	SLOTLK="$SLK_LIB
slk_take || exit 1
"
	slk_busy(){ grep -q '^SLOTLK-BUSY' <<< "$1"; }
else
	echo "FAIL scripts/lib/slotlock-254.sh: $_slk_f missing — refusing to mount a boot FAT without the slot lock" >&2
	SLOTLK='echo "SLOTLK-BUSY the harness lacks scripts/node/slotlock-lib-254.sh"; exit 1
'
	SLK_LIB=$SLOTLK
	slk_busy(){ grep -q '^SLOTLK-BUSY' <<< "$1"; }
	false
fi
