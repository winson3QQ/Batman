#!/bin/bash
# scripts/dv/fresh-254.sh — shared host-side helpers for a node that goes through fresh slots (#254 H4 §15 step 4):
# sourced by chain1-254.sh and prov-bench-s0-254.sh. Moved here unchanged from chain1-254.sh v3 (its lines 31-92 and
# 106-127 and 129-183 at be90b00); the comments keep chain1's review references. Git Bash.
# The caller sets, BEFORE sourcing: NODE (the committed address) MAC MACW (eth MAC, colon / Windows dash form) MDNS
# LABKEY, and before CALLING: V, FIP (set by find04), PCD TOOLS_WSL WSLK (pc), HOSTIP BASE RUN where used.
# restore_all / abort also need: BASE PAY PSHA BREWRITE REPO D PDIR DIRTY P1_0 and the flags STAGED SNAPPED RESTORING.
# Names say 04 (find04) for chain1's sake; the node is whichever NODE / MAC name.
SSHO="-o BatchMode=yes -o ConnectTimeout=6 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 -o LogLevel=ERROR"
# any slot of 04 on the lab LAN: host key changes with every fresh slot; `none` until the lab key is in, publickey after
FRESHO="$SSHO -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o PreferredAuthentications=publickey,none -o IdentitiesOnly=yes -i $LABKEY"
# publickey PROOF (review B-1): OpenSSH always tries `none` first, so a successful login proves nothing on an open node;
# the verbose client log names the method that authenticated. Own option set (ssh keeps the FIRST LogLevel given).
PKO="-o BatchMode=yes -o ConnectTimeout=6 -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o PreferredAuthentications=publickey -o PubkeyAuthentication=yes -o IdentitiesOnly=yes -i $LABKEY -o LogLevel=VERBOSE"
# On an OPEN node dropbear accepts `none` (blank root password) and the client never gets to publickey (review round 2
# B2-1; 04 probe 2026-10-26: 'Authenticated to 10.41.1.3 using "none"'). So the key is proven against a temporary
# publickey-only listener of the same daemon with the same authorized_keys (`dropbear -s -g -p 2222`), whose own
# negative control is that `none` is denied there; the listener is killed right after (04 probe: pk OK, none denied).
NONEO="-o BatchMode=yes -o ConnectTimeout=6 -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o PreferredAuthentications=none -o PubkeyAuthentication=no -o LogLevel=ERROR"
pk_proof(){ local ip=$1 r=1 o
	# fw4 input policy is drop with per-zone rules; a fresh slot's zones may not pass 2222 -> one temporary, tagged
	# rule at the top of the input chain (runtime only: gone with any fw reload / reboot; removed by handle below)
	timeout 30 ssh $FRESHO root@"$ip" 'mkdir -p -m 0700 /tmp/run/batman-dv; pid=/tmp/run/batman-dv/ch1-db.pid; [ -s $pid ] && kill $(cat $pid) 2>/dev/null; nft -a list chain inet fw4 input 2>/dev/null | grep -q ch1-pk-proof || nft insert rule inet fw4 input tcp dport 2222 accept comment "ch1-pk-proof" 2>/dev/null; dropbear -s -g -p 2222 -P $pid && sleep 1 && [ -s $pid ] && echo LISTEN' 2>/dev/null | tr -d '\r' | grep -q LISTEN || { echo "    pk_proof: listener did not start on $ip"; return 1; }
	o=$(timeout 30 ssh -p 2222 $PKO root@"$ip" 'echo PKOK' 2>&1 | tr -d '\r')
	if grep -qE 'Authenticated to .* using "publickey"' <<< "$o" && grep -q PKOK <<< "$o"; then
		timeout 30 ssh -p 2222 $NONEO root@"$ip" 'echo NONEOK' 2>&1 | tr -d '\r' | grep -q "Permission denied" && r=0 || echo "    pk_proof: 'none' was not denied on the publickey-only listener (probe invalid)"
	else echo "    pk_proof: no publickey authentication on the listener"; fi
	o=$(timeout 30 ssh $FRESHO root@"$ip" 'pid=/tmp/run/batman-dv/ch1-db.pid; kill $(cat $pid) 2>/dev/null; rm -f $pid; for h in $(nft -a list chain inet fw4 input 2>/dev/null | sed -n "s/.*ch1-pk-proof.*# handle \([0-9]*\).*/\1/p"); do nft delete rule inet fw4 input handle $h; done; echo "left=$(nft -a list chain inet fw4 input 2>/dev/null | grep -c ch1-pk-proof) listen=$(netstat -ltn 2>/dev/null | grep -c ":2222 ")"' 2>/dev/null | tr -d '\r')
	[ "$o" = "left=0 listen=0" ] || { echo "    pk_proof: cleanup incomplete on $ip ($o)"; r=1; }
	return $r; }
# lock assertion on port 22: `none` must be DENIED (a timeout / dead node is not a refusal; review B2-3)
none_refused(){ timeout 30 ssh $NONEO root@"$1" 'echo NONEOK' 2>&1 | tr -d '\r' | grep -q "Permission denied"; }
PH=pre; say(){ echo "[$(date +%H:%M:%S) $PH] $*"; }
fails=0; ok(){ echo "PASS [$PH] $*"; }; no(){ echo "FAIL [$PH] $*"; fails=$((fails + 1)); }; warn(){ echo "WARN [$PH] $*"; }
q(){ timeout 120 ssh $SSHO root@$NODE "$@" 2>/dev/null | tr -d '\r'; }
fq(){ timeout 120 ssh $FRESHO root@"$FIP" "$@" 2>/dev/null | tr -d '\r'; }
fqlong(){ timeout 900 ssh $FRESHO root@"$FIP" "$@" 2>/dev/null | tr -d '\r'; }
macips(){ arp -a | tr -d '\r' | awk -v m="$MACW" 'tolower($2)==m {print $1}'; }
sweep(){ local i; for i in $(seq 2 254); do ping -n 1 -w 200 $1.$i >/dev/null 2>&1 & [ $((i % 40)) = 0 ] && wait; done; wait; }
# ST carries the eth MAC: 02 runs the same version, so a stale ARP entry must not let a step act on 02 (review A-m2)
ST='echo "mac=$(cat /sys/class/net/eth0/address 2>/dev/null) slot=$(batman-slot active) ver=$(sed -n s/^BATMAN_VERSION=//p /etc/batman-build) trial_rc=$(batman-slot is-trial >/dev/null 2>&1; echo $?) dt_try=$(hexdump -v -e "1/1 \"%02x\"" /proc/device-tree/chosen/bootloader/tryboot 2>/dev/null) hold=[$(cat /opt/batdata/state/autocommit-hold-commit 2>/dev/null)] held=$(. /usr/lib/batman/rundir.sh; ls $RUNDIR/autocommit.ctl/hold-commit 2>/dev/null | wc -l) badslot=[$(cat /opt/batdata/state/bad-slot 2>/dev/null)] up=$(cut -d. -f1 /proc/uptime) boot=$(cut -c1-8 /proc/sys/kernel/random/boot_id)"'
PROT='echo "protA=[$(cat /opt/batdata/state/slot-A.protected 2>/dev/null)] protB=[$(cat /opt/batdata/state/slot-B.protected 2>/dev/null)]"'
DISARM='vcmailbox 0x00038064 4 4 0 >/dev/null 2>&1; r=$(vcmailbox 0x00030064 4 4 0 2>/dev/null); set -- $r; echo "tryboot_flag=${6:-?}"'
# p5 read-only view, with the SAME predicate the gate uses (prov_meta_status) and the identity check (review B-6)
P5RO='mkdir -p -m 0700 /tmp/run/batman-dv && m=$(mktemp -d /tmp/run/batman-dv/ch1.XXXXXX) && mount -o ro,noload /dev/mmcblk0p5 $m && { echo "seeded=$([ -f $m/.seeded ] && echo y || echo n) shadowroot=$([ -s $m/identity/shadow-root ] && echo y || echo n) prov_files=$(ls $m/identity/prov 2>/dev/null | wc -l) metastat=[$(. /usr/lib/batman/prov-lock.sh; prov_meta_status $m/prov.meta $m/prov.cbor)] ident=$(. /usr/lib/batman/prov-lock.sh; prov_ident_ok $m/identity/prov && echo ok || echo bad) idsame=$(cmp -s $m/identity/prov/node.cert /etc/batman-prov/identity/node.cert 2>/dev/null && echo y || echo n)"; umount $m; }; rmdir $m'
# A's boot FAT (p1) content hash: 7.2 / 8.6 rewrite A's boot files; prov-base covers p5 / upper / p6 only (round 2 m1)
P1LIST='cd /boot && find . -type f | sort | while IFS= read -r f; do sha256sum "$f"; done'   # per file, so a FAIL names the file (round 3 m3)
NOFORCE='echo "allow_unseeded=$([ -e /tmp/batman-slot.allow-unseeded ] && echo y || echo n) allow_stale=$([ -e /tmp/batman-slot.allow-stale-p5 ] && echo y || echo n) allow_txn=$([ -e /tmp/batman-slot.allow-unfinished-txn ] && echo y || echo n)"'
# is_on <ip> <pattern>: 04 (by MAC) answers there and its state matches the pattern
#   <pattern> starts at a field boundary (" $2", literal), so "slot=B ..." never matches inside
# "badslot=[slot=B ...]" or "hold=[slot=B ...]" (2026-11-08 incident; review 2026-11-09 B-MAJOR-2)
is_on(){ ping -n 1 -w 1000 "$1" >/dev/null 2>&1 || return 1; local s; s=$(timeout 30 ssh $FRESHO root@"$1" "$ST" 2>/dev/null | tr -d '\r'); case "$s" in "mac=$MAC "*) ;; *) return 1;; esac; case " $s" in *" $2"*) echo "$s"; return 0;; esac; return 1; }
SEEN=""   # every address 04 was found at in this run: tried first (review B-11: the reserved address is not in a swept /24)
# find04 <pattern> [exclude-boot]: sets FIP / FOUND_HOW / FOUND_STATE (never call in a subshell)
. "$(dirname "${BASH_SOURCE[0]}")/slot-guard-254.sh"   # rb_guarded: every rollback checks boot / slot / trial on the node
find04(){
	local ip s p ips
	for p in fixed seen mdns arp 10.41.254 10.41.1; do
		case "$p" in
			fixed) ips=$NODE ;;
			seen) ips=$SEEN ;;
			mdns) ips=$(ping -n 1 -w 1000 -4 $MDNS 2>/dev/null | tr -d '\r' | sed -n 's/.*\[\([0-9.]*\)\].*/\1/p' | head -1) ;;
			arp) ips=$(macips) ;;
			*) sweep $p; ips=$(macips) ;;
		esac
		for ip in $ips; do s=$(is_on "$ip" "$1") || continue; case "$s" in *" boot=${2:-none}"*) continue;; esac
			FIP=$ip; FOUND_HOW=$p; FOUND_STATE=$s; case " $SEEN " in *" $ip "*) ;; *) SEEN="$SEEN $ip";; esac; return 0; done
	done; return 1
}
FIP=""; FOUND_HOW=""; FOUND_STATE=""
# wait_find <seconds> <pattern> [exclude-boot]  (parent shell only)
wait_find(){ local t=$SECONDS; FIP=""; while [ $((SECONDS - t)) -lt "$1" ]; do find04 "$2" "${3:-none}" && return 0; sleep 10; done; return 1; }
bootof(){ echo "$1" | sed -n 's/.*boot=\([0-9a-f]*\).*/\1/p'; }

# provclient on the node at $FIP; SIGN lines answered by the WSL signer (owner key never on the node) — as prov-claim-254
pc(){
	local key=$1; shift
	local f; f=$(mktemp -d)/p; mkfifo "$f"
	coproc SIGNP { MSYS_NO_PATHCONV=1 wsl.exe -d Ubuntu-24.04 -u yello -- "$TOOLS_WSL/provclient-amd64" sign "$WSLK/$key"; }
	exec {W}<>"$f"
	local out="" line sig
	while IFS= read -r line; do
		line=$(printf '%s' "$line" | tr -d '\r')
		case "$line" in
			SIGN\ *) echo "$line" >&"${SIGNP[1]}"; IFS= read -r -t 30 sig <&"${SIGNP[0]}" || sig=ERR; printf '%s\n' "$sig" | tr -d '\r' >&"$W" ;;
			*) out="$out$line
" ;;
		esac
	done < <(ssh $FRESHO root@"$FIP" "$PCD/provclient node $*" < "$f" 2>&1)
	exec {W}>&-; kill "$SIGNP_PID" 2>/dev/null; rm -rf "${f%/p}"   # stop the signer ({SIGNP[1]}>&- is not valid bash, SC1083)
	printf '%s' "$out"
}

# land_quiet: first command after every restore landing — stop openmanetd so its address-reservation reboot cannot cut
# a p5 dd / overlay restore in half; confirm the boot did not change meanwhile (review A-M3). rc 1 = boot changed.
land_quiet(){ local b0 b1; b0=$(bootof "$FOUND_STATE"); fq '/etc/init.d/openmanetd stop >/dev/null 2>&1; true'; b1=$(fq 'cut -c1-8 /proc/sys/kernel/random/boot_id'); [ -n "$b1" ] && [ "$b1" = "$b0" ]; }

# ---- restore_all: from ANY state after the snapshot back to S0 (same path as step 9). Idempotent steps, each printed.
# RESTORE_PERSON=1 from the start of a restore until the snapshot is finished: any return before that (a failed step,
# compare / B rewrite / p1 FAIL with the snapshot kept) leaves 04 to a person — the caller reports it (needs-person.txt)
restore_all(){
	[ "$RESTORING" = 1 ] && return 1; RESTORING=1; PH=restore
	[ "$SNAPPED" = 1 ] || { say "RESTORE: no snapshot was taken — nothing to restore"; return 0; }
	RESTORE_PERSON=1
	say "RESTORE (${1:-step 9})"
	local s b o i cmp
	for i in 1 2 3; do
		wait_find 900 "ver=$V " || { say "RESTORE: 04 not found anywhere in 900 s — needs a person (snapshot $D on p6, dead-man staged=$STAGED)"; return 1; }
		say "04 at $FIP ($FOUND_HOW): $FOUND_STATE"; s=$FOUND_STATE
		# an uncommitted trial: leave it (reboot -> its committed default slot)
		case "$s" in *"trial_rc=0 "*) b=$(bootof "$s"); fq "$DISARM; (batman-slot reboot committed ch1-restore </dev/null >/dev/null 2>&1 &)" >/dev/null
			wait_find 900 "trial_rc=1 " "$b" || { say "RESTORE: no committed boot after leaving the trial"; return 1; }; s=$FOUND_STATE; say "committed: $s";; esac
		land_quiet && break; say "RESTORE: boot changed while quieting openmanetd — finding 04 again ($i/3)"
		[ "$i" = 3 ] && { say "RESTORE: 04 keeps rebooting under openmanetd — needs a person"; return 1; }
	done
	# on B: p5 back, then rollback to A
	case "$s" in *" slot=B "*)
		fq "rm -f /opt/batdata/state/autocommit-hold-commit; touch $BASE/ch1.cancel"
		o=$(fqlong "for m in /tmp/run/batman-dv/ch1.*; do [ -d \$m ] && umount \$m 2>/dev/null; rmdir \$m 2>/dev/null; done; sh $BASE/prov-base-254.sh p5-restore $RUN"); say "p5 (on B): $(echo "$o" | tail -1)"; grep -q "^P5-RESTORED $RUN " <<< "$o" || { say "RESTORE: p5-restore failed — needs a person"; return 1; }
		# guarded on the node: this boot, on B, committed, and chain1's dead-man neither fired nor running (it does its own
		# p5-restore + rollback; a second rollback from here would flip the default back to B) — review 2026-11-09 B-MAJOR-1
		b=$(bootof "$s"); o=$(fq "$(rb_guarded "$b" B 1 ch1-restore "[ ! -e $BASE/ch1.fired ] && ! ps w | grep -q '[c]h1-deadman.sh'")")
		say "    rollback: ${o:-no answer}"; [ "$o" = SENT ] || { say "RESTORE: rollback to A not sent ($o) — needs a person"; return 1; }
		wait_find 900 "slot=A ver=$V trial_rc=1 " "$b" || { say "RESTORE: A not found after the rollback"; return 1; }; s=$FOUND_STATE; say "on A: $s"
		land_quiet || { wait_find 900 "slot=A ver=$V trial_rc=1 " || return 1; s=$FOUND_STATE; land_quiet || { say "RESTORE: A keeps rebooting"; return 1; }; } ;;
	esac
	case "$s" in *" slot=A ver=$V trial_rc=1 "*) ;; *) say "RESTORE: not on A committed: $s"; return 1;; esac
	fq "touch $BASE/ch1.cancel; rm -f /opt/batdata/state/autocommit-hold-commit; b=\$(cat /opt/batdata/state/bad-slot 2>/dev/null); [ -n \"\$b\" ] && { echo \"bad-slot was [\$b] (residue of this run) — removing\"; rm -f /opt/batdata/state/bad-slot; }; true" | sed 's/^/    /'
	# p5 again ON A, always (2026-10-26 wsl.3 run: A booted with 8.6's claimed overlay and joinwatch running, and its
	# --on-join saved A's live root line into the p5 restored on B -> S0 compare diffs=3). p5-restore stops joinwatch /
	# helper / provd and nothing restarts them before the reboot below, so the overlay restore cannot be undone.
	o=$(fqlong "for m in /tmp/run/batman-dv/ch1.*; do [ -d \$m ] && umount \$m 2>/dev/null; rmdir \$m 2>/dev/null; done; sh $BASE/prov-base-254.sh p5-restore $RUN"); say "p5 (on A): $(echo "$o" | tail -1)"; grep -q "^P5-RESTORED $RUN " <<< "$o" || { say "RESTORE: p5-restore failed"; return 1; }
	o=$(fqlong "sh $BASE/prov-base-254.sh overlay-restore $RUN"); echo "$o" | grep -E "EXTRA-REMOVED|OVERLAY" | tail -12 | sed 's/^/    /'
	grep -q "^OVERLAY-RESTORED $RUN" <<< "$o" || { say "RESTORE: overlay-restore failed"; return 1; }
	b=$(bootof "$s"); fq "(batman-slot reboot committed ch1-restore </dev/null >/dev/null 2>&1 &)" >/dev/null
	local t=$SECONDS; FIP=""; while [ $((SECONDS - t)) -lt 900 ]; do s=$(is_on $NODE "slot=A ver=$V trial_rc=1 ") && case "$s" in *"boot=$b"*) ;; *) FIP=$NODE; break;; esac; sleep 15; done
	[ -n "$FIP" ] || { say "RESTORE: A not back at $NODE"; return 1; }
	t=$SECONDS; while [ $((SECONDS - t)) -lt 300 ]; do u=$(q 'cut -d. -f1 /proc/uptime'); [ "${u:-0}" -ge 150 ] && break; sleep 10; done
	say "A at $NODE: $(q "$ST")"
	# compare S0 (joinwatch stopped meanwhile so p5 is not rw-mounted under the manifest; review A-m4) — result KEPT
	q "/etc/init.d/joinwatch stop >/dev/null 2>&1; mkdir -p -m 0700 /tmp/run/batman-dv"; scp -q $SSHO "$REPO/tests/prov-p1/overlay-allow.txt" root@$NODE:/tmp/run/batman-dv/overlay-allow.txt
	cmp=""; for i in 1 2 3; do q "sh $BASE/prov-base-254.sh manifest $RUN after" | tail -1; o=$(q "sh $BASE/prov-base-254.sh compare $RUN after"); grep -q "p5 unreadable" <<< "$o" || break; sleep 10; done
	q "/etc/init.d/joinwatch start >/dev/null 2>&1"; echo "$o" | tail -15 | sed 's/^/    /'
	grep -q "diffs=0" <<< "$o" && { cmp=PASS; ok "S0 restored (p5 / overlay / uci / identity / p6 state)"; } || { cmp=FAIL; no "S0 not restored — snapshot kept"; }
	# B back to V (its overlay carries the dead-man and the claimed slot): brewrite = sysupgrade -n + hold + back_to_a
	o=$(NODE=$NODE N=1 PAY=$PAY PSHA=$PSHA bash "$BREWRITE" 2>&1); echo "$o" | grep -E "landed|post|RESULT" | cut -c1-220 | sed 's/^/    /'
	if grep -q "E3 RESULT: PASS" <<< "$o"; then ok "B rewritten with V"; else no "B rewrite"; cmp=FAIL; fi
	# p1 AFTER the B rewrite (it re-arms / commits through autoboot.txt on p1; round 3 m2); per-file diff names the file
	p1=$(q "$P1LIST")
	if [ "$p1" = "$P1_0" ]; then ok "A boot FAT (p1) identical to before ($(echo "$p1" | wc -l) files)"
	else cmp=FAIL; no "p1 changed:"; diff <(echo "$P1_0") <(echo "$p1") | grep '^[<>]' | sed 's/^/    p1 /'; fi
	# finish only when BOTH passed (review A-M4)
	if [ "$cmp" = PASS ]; then o=$(q "sh $BASE/prov-base-254.sh finish $RUN | tail -1; rm -rf $PDIR $BASE/ch1-deadman.sh $BASE/ch1.cancel $BASE/ch1.fired $BASE/prov-base-254.sh; cat $BASE/ch1-deadman.log > /dev/null 2>&1; rm -f $BASE/ch1-deadman.log")
		grep -q "^FINISHED $RUN" <<< "$o" && { ok "snapshot finished ($o)"; RESTORE_PERSON=0; } || no "finish: $o"
	else say "finish skipped: snapshot $D and dirty flag kept for a person"; fi
	say "after restore: $(q "$ST") $(q "$PROT") dirty=[$(q "cat $DIRTY 2>/dev/null")] dv-prov=[$(q "ls $BASE | tr '\n' ' '")] joinwatch=$(q 'ps w | grep -c "[/]usr/bin/joinwatch"')"
	return 0
}
abort(){ no "ABORT: $*"; restore_all "abort: $*"; exit 1; }
