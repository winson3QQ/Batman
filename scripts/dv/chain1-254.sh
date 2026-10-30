#!/bin/bash
# scripts/dv/chain1-254.sh v3 — #254 P1 residual "鏈 1" (docs/design/254-p1-impl.md §5.4 chain 1, steps 1-9) on 04, from Git Bash.
#   1 snap (+ mesh markers moved into the snapshot)   2 p5 idle   3 p5 mkfs   4 hold + apply V to B (unseeded) + reboot
#   5 HELD fresh trial on B: unclaimed assertions     6 gate (L44) + wsl.9 negative control; dead-man; release -> B committed
#   7 unclaimed OTA: 7.1 negative (platform.sh without prov-lock.sh in RAMFS_COPY_DATA -> stage 2 dies on "not seeded",
#     A untouched)  7.2 positive (A HELD unclaimed trial)  7.3 back_to_b
#   8 claim on B (lab key first, publickey PROVEN by ssh -v) -> LOCKED + p5 seeded -> claimed OTA into A (HELD,
#     "mesh join required: 0 (prov=claimed") + autocommit dry-run negative (mesh-expected back) -> back_to_b.
#     On an image with the #254 claim-lock bug (1.5.13): 8.3 FAILs (not locked / not seeded) and 8.6 must be REFUSED by
#     the stage-1 gate ("not seeded") — a gate LEAK (an A trial appears) is a FAIL.
#   9 restore: p5 back on B -> rollback -> A -> overlay-restore -> reboot committed -> compare -> B rewrite -> finish
# Side effects (user-authorised 2026-10-26): 04 off the mesh ~60-90 min, 02 isolated meanwhile, OTS down, A and B both
# rewritten with V, p5 mkfs'd (snapshot), several reboots. Every failure after the snapshot goes through restore_all
# (same path as step 9), also on an unexpected exit; a one-shot dead-man on B (p6 + B's rc.local, 25 min after each B
# boot) brings 04 back to A if this host dies — a dead-man return lands on A's overlay as left by the chain and needs a
# person to run restore (overlay-restore + compare) afterwards.
# Reviews: 2026-10-26 round 1 A (APPROVE-WITH-CHANGES, 5 MAJOR) / B (REJECT); all findings addressed in v2.
set -u
NODE=10.41.1.3; PEER=10.41.1.1; HOSTIP=${HOSTIP:-10.41.240.10}; MACW=88-a2-9e-b5-6c-89; MAC=88:a2:9e:b5:6c:89; MDNS=BCM2711-6c89.local
V=${V:?version}; PAY=${PAY:-/opt/batdata/ota-1.5.13-wsl.1.tar.gz}; PSHA=${PSHA:?payload sha256}
OUTS=${OUTS:-//wsl.localhost/Ubuntu-24.04/home/yello/out}
REPO=${REPO:-$(cd "$(dirname "$0")/../.." && pwd)}; PB=$REPO/scripts/node/prov-base-254.sh
TOOLS=${DV_PROV_TOOLS:-/c/Users/yello/batman-dv-tools/prov}; TOOLS_WSL=/home/yello/batman-dv-tools/prov
BREWRITE=${BREWRITE:-$REPO/scripts/dv/brewrite-254.sh}; WSL9_SLOT=${WSL9_SLOT:-$REPO/tests/prov-p1/fixtures/batman-slot.1.5.12-wsl.9}
LABKEY=${LABKEY:-$HOME/.ssh/id_ed25519}
RUN=ch1$(date +%m%d%H%M); PCD=/tmp/run/batman-dvpc.$RUN; BASE=/opt/batdata/dv-prov; D=$BASE/$RUN; PDIR=$BASE/payload-ch1; DIRTY=/opt/batdata/state/dv-prov-dirty
LOCKD=${TEMP:?TEMP unset - the host lock lives in the per-user temp dir, never in a shared tmp}/batman-dv-04.lock; WSLK=/home/yello/.batman-dv/prov-keys/$RUN
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
is_on(){ ping -n 1 -w 1000 "$1" >/dev/null 2>&1 || return 1; local s; s=$(timeout 30 ssh $FRESHO root@"$1" "$ST" 2>/dev/null | tr -d '\r'); case "$s" in "mac=$MAC "*$2*) echo "$s"; return 0;; esac; return 1; }
SEEN=""   # every address 04 was found at in this run: tried first (review B-11: the reserved address is not in a swept /24)
# find04 <pattern> [exclude-boot]: sets FIP / FOUND_HOW / FOUND_STATE (never call in a subshell)
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
		for ip in $ips; do s=$(is_on "$ip" "$1") || continue; case "$s" in *"boot=${2:-none}"*) continue;; esac
			FIP=$ip; FOUND_HOW=$p; FOUND_STATE=$s; case " $SEEN " in *" $ip "*) ;; *) SEEN="$SEEN $ip";; esac; return 0; done
	done; return 1
}
FIP=""; FOUND_HOW=""; FOUND_STATE=""
# wait_find <seconds> <pattern> [exclude-boot]  (parent shell only)
wait_find(){ local t=$SECONDS; FIP=""; while [ $((SECONDS - t)) -lt "$1" ]; do find04 "$2" "${3:-none}" && return 0; sleep 10; done; return 1; }
bootof(){ echo "$1" | sed -n 's/.*boot=\([0-9a-f]*\).*/\1/p'; }
STAGED=0; SNAPPED=0; RESULT=FAIL; RESTORING=0
mkdir "$LOCKD" 2>/dev/null || { echo "another dv run holds $LOCKD"; exit 1; }
# an unexpected exit after the snapshot (set -u, a bug) still restores (review A-M1)
on_exit(){ local rc=$?; if [ "$SNAPPED" = 1 ] && [ "$RESTORING" = 0 ]; then no "unexpected exit (rc $rc) — restoring"; restore_all "unexpected exit"; fi
	rmdir "$LOCKD" 2>/dev/null; MSYS_NO_PATHCONV=1 wsl.exe -d Ubuntu-24.04 -u yello -- rm -rf "$WSLK" 2>/dev/null; say "CHAIN1 RESULT: $RESULT (fails=$fails)"; }
trap on_exit EXIT
trap 'say "host interrupted"; [ "$SNAPPED" = 1 ] && restore_all "interrupted"; RESTORING=1; exit 1' INT TERM

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
restore_all(){
	[ "$RESTORING" = 1 ] && return 1; RESTORING=1; PH=restore
	[ "$SNAPPED" = 1 ] || { say "RESTORE: no snapshot was taken — nothing to restore"; return 0; }
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
	case "$s" in *"slot=B "*)
		fq "rm -f /opt/batdata/state/autocommit-hold-commit; touch $BASE/ch1.cancel"
		o=$(fqlong "for m in /tmp/run/batman-dv/ch1.*; do [ -d \$m ] && umount \$m 2>/dev/null; rmdir \$m 2>/dev/null; done; sh $BASE/prov-base-254.sh p5-restore $RUN"); say "p5 (on B): $(echo "$o" | tail -1)"; grep -q "^P5-RESTORED $RUN " <<< "$o" || { say "RESTORE: p5-restore failed — needs a person"; return 1; }
		b=$(bootof "$s"); fq "batman-slot rollback >/dev/null 2>&1 && (batman-slot reboot committed ch1-restore </dev/null >/dev/null 2>&1 &) && echo SENT" | sed 's/^/    rollback: /'
		wait_find 900 "slot=A ver=$V trial_rc=1 " "$b" || { say "RESTORE: A not found after the rollback"; return 1; }; s=$FOUND_STATE; say "on A: $s"
		land_quiet || { wait_find 900 "slot=A ver=$V trial_rc=1 " || return 1; s=$FOUND_STATE; land_quiet || { say "RESTORE: A keeps rebooting"; return 1; }; } ;;
	esac
	case "$s" in *"slot=A ver=$V trial_rc=1 "*) ;; *) say "RESTORE: not on A committed: $s"; return 1;; esac
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
		grep -q "^FINISHED $RUN" <<< "$o" && ok "snapshot finished ($o)" || no "finish: $o"
	else say "finish skipped: snapshot $D and dirty flag kept for a person"; fi
	say "after restore: $(q "$ST") $(q "$PROT") dirty=[$(q "cat $DIRTY 2>/dev/null")] dv-prov=[$(q "ls $BASE | tr '\n' ' '")] joinwatch=$(q 'ps w | grep -c "[/]usr/bin/joinwatch"')"
	return 0
}
abort(){ no "ABORT: $*"; restore_all "abort: $*"; exit 1; }

# ======== 0. pre
s=$(q "$ST"); say "start: $s"
case "$s" in "mac=$MAC slot=A ver=$V trial_rc=1 dt_try="*" hold=[] held=0 badslot=[]"*) ;; *) say "precondition (04 by MAC, A committed $V, no hold, no bad-slot)"; exit 1;; esac
a=$(q "awk -v b=\$(cat /proc/sys/kernel/random/boot_id) '\$1==b {print \"ps=\" \$2 \"/\" \$4}' /opt/batdata/state/prov-state; batman-config-save --check >/dev/null 2>&1; echo check_rc=\$?; /usr/libexec/batman-addr-defer status; echo dirty=[\$(cat $DIRTY 2>/dev/null)]")
say "A: $(echo $a)"; case "$a" in *"ps=helper/legacy"*"check_rc=0"*"want=stock env=absent openmanetd=up"*"dirty=[]"*) ;; *) say "A not healthy / dirty flag present"; exit 1;; esac
[ "$(q "sha256sum < $PAY | cut -c1-64")" = "$PSHA" ] || { say "payload sha"; exit 1; }
# payload version == V, from the build dir's SHA256SUMS (a version mismatch discards the hold, review A-M2)
VPAY=""; for sums in "$OUTS"/*/ekh-bcm2711/SHA256SUMS; do grep -q "^$PSHA  .*-ab-payload\.tar\.gz$" "$sums" 2>/dev/null || continue
	d=${sums%/SHA256SUMS}; bs=$(sha256sum < "$d/batman-build.txt" | cut -c1-64); grep -q "^$bs  batman-build\.txt$" "$sums" || { say "batman-build.txt in $d does not match its SHA256SUMS"; exit 1; }
	VPAY=$(sed -n 's/^BATMAN_VERSION=//p' "$d/batman-build.txt" | tr -d '\r'); break; done
[ "$VPAY" = "$V" ] || { say "payload BATMAN_VERSION [$VPAY] != V [$V]"; exit 1; }; say "payload version $VPAY (build dir evidence)"
pk_proof $NODE || { say "lab key $LABKEY does not authenticate to A by publickey"; exit 1; }
[ -f "$TOOLS/provclient-arm64" ] || { say "no $TOOLS/provclient-arm64"; exit 1; }   # -f: an arm64 binary for the node, never executed on the host (Git Bash has no x bit for it)
# the wsl.9 negative control must BE the wsl.9 batman-slot (review B-10)
w9=$(MSYS_NO_PATHCONV=1 wsl.exe -d Ubuntu-24.04 -u yello -- bash -c "cd /home/yello/Batman && git show f2f2bf6:feed/batman-provision/files/usr/sbin/batman-slot | sha256sum | cut -c1-64" | tr -d '\r')
[ "$(sha256sum < "$WSL9_SLOT" | cut -c1-64)" = "$w9" ] && ! grep -q '#254 L44' "$WSL9_SLOT" || { say "WSL9_SLOT is not the f2f2bf6 batman-slot (or carries L44)"; exit 1; }
peer0=$(timeout 30 ssh $SSHO root@$PEER "$ST" 2>/dev/null | tr -d '\r'); say "02 before: [$peer0]"
P1_0=$(q "$P1LIST"); say "A boot FAT (p1, /boot) before: $(echo "$P1_0" | wc -l) files, list sha $(echo "$P1_0" | sha256sum | cut -c1-16)"; [ "$(echo "$P1_0" | wc -l)" -ge 5 ] || { say "cannot hash p1"; exit 1; }
q "mkdir -p -m 700 $PDIR && cd $PDIR && rm -rf ./* && tar -xzf $PAY && echo extracted" | sed 's/^/    /'
# ======== 1. snapshot; mesh markers into the snapshot dir (step 8's premise); dead-man staged on p6
PH=s1
o=$(timeout 900 ssh $SSHO root@$NODE "KEEP_JOINWATCH_STOPPED=1 sh -s -- snap $RUN" < "$PB" 2>&1 | tr -d '\r'); say "$(echo "$o" | tail -1)"
grep -q "^SNAP $RUN" <<< "$o" || { say "snap failed"; exit 1; }
SNAPPED=1; FIP=$NODE; FOUND_STATE=$s
SNAPSHA=$(q "cut -c1-16 $D/p5.img.sha")
scp -q $SSHO "$PB" root@$NODE:$BASE/prov-base-254.sh || abort "copy prov-base"
q "mkdir -p $D/marks; for m in mesh-joined mesh-expected; do [ -e /opt/batdata/state/\$m ] && mv /opt/batdata/state/\$m $D/marks/; done; echo marks=[\$(ls $D/marks | tr '\n' ' ')]" | sed 's/^/    /'
q "cat > $BASE/ch1-deadman.sh <<'DM'
#!/bin/sh
# chain-1 dead-man ($RUN): slot B only, only while the dirty flag names this run; one-shot.
[ \"\$(batman-slot active)\" = B ] || exit 0
[ -f $BASE/ch1.cancel ] && exit 0
[ -f $BASE/ch1.fired ] && exit 0
grep -q '^$RUN ' $DIRTY 2>/dev/null || { logger -t ch1-deadman 'dirty flag does not name $RUN: not acting'; exit 0; }
[ -f $D/p5.img ] || { logger -t ch1-deadman 'snapshot missing: not acting'; exit 0; }
logger -t ch1-deadman 'restoring p5 and returning to A'
L=$BASE/ch1-deadman.log
/etc/init.d/openmanetd stop >> \$L 2>&1
sh $BASE/prov-base-254.sh p5-restore $RUN >> \$L 2>&1; echo \"p5-restore rc=\$?\" >> \$L
batman-slot rollback >> \$L 2>&1; r=\$?; echo \"rollback rc=\$r\" >> \$L
[ \$r = 0 ] && : > $BASE/ch1.fired; sync
batman-slot reboot committed ch1-deadman >> \$L 2>&1
DM
chmod 700 $BASE/ch1-deadman.sh; rm -f $BASE/ch1.cancel $BASE/ch1.fired $BASE/ch1-deadman.log; sh -n $BASE/ch1-deadman.sh && echo ok" | grep -q '^ok$' || abort "dead-man write"
STAGED=1; say "dead-man staged (snapshot p5 sha $SNAPSHA)"
# ======== 2-4. p5 idle -> mkfs -> hold + apply (unseeded) -> controlled reboot
PH=s2-4
o=$(q "grep -c ' /dev/mmcblk0p5 ' /proc/mounts; ps w | grep -c '[b]atman-config-save'"); [ "$(echo $o)" = "0 0" ] && ok "p5 idle" || abort "p5 busy: $(echo $o)"
o=$(q "mkfs.ext4 -F -q -L batconfig /dev/mmcblk0p5 && echo MKFS-OK; $P5RO"); say "p5 after mkfs: $(echo $o)"
case "$o" in *MKFS-OK*"seeded=n"*) ok "p5 empty, not seeded";; *) abort "mkfs";; esac
q "echo '$V' > /opt/batdata/state/autocommit-hold-commit; sync"
o=$(timeout 900 ssh $SSHO root@$NODE "BATMAN_ALLOW_UNSEEDED=1 BATMAN_ALLOW_STALE_P5=1 batman-slot apply $PDIR 2>&1 | tail -3" 2>/dev/null | tr -d '\r'); say "apply: $(echo $o)"
grep -q "armed as one-shot tryboot" <<< "$o" || { q "$DISARM" >/dev/null; abort "apply did not arm"; }
o=$(q "$P5RO"); case "$o" in *"seeded=n"*) ok "p5 still unseeded after apply";; *) q "$DISARM" >/dev/null; abort "p5 seeded by apply: $o";; esac
B0=$(q 'cut -c1-8 /proc/sys/kernel/random/boot_id')
q '(/etc/init.d/dockerd stop >/dev/null 2>&1; sync; sleep 1; reboot -f) </dev/null >/dev/null 2>&1 &'; t0=$SECONDS
# ======== 5. HELD fresh trial on B, assertions within ~150 s (F34)
PH=s5; FIP=""; ev=""
while [ $((SECONDS - t0)) -lt 150 ] && [ -z "$FIP" ]; do sleep 10; find04 "slot=B ver=$V trial_rc=0 dt_try=00000001 " "$B0" || FIP=""; done
[ -n "$FIP" ] || abort "held fresh trial not found in 150 s"
say "held trial at $FIP ($FOUND_HOW) after $((SECONDS - t0)) s: $FOUND_STATE"; BT=$(bootof "$FOUND_STATE")
dec=""; while [ $((SECONDS - t0)) -lt 180 ]; do ev=$(fq "logread | grep -E 'batman-autocommit|batman-provhelper'"); grep -q "mesh join required: 0 (prov=unclaimed" <<< "$ev" && grep -q "HELD" <<< "$ev" && { dec=ok; break; }; grep -q HOLD-COMMIT-DISCARDED <<< "$ev" && break; sleep 5; done
echo "$ev" | grep -E "mesh join required|HELD|boot rc=" | tail -4 | sed 's/^/    trial: /'
[ "$dec" = ok ] && ok "autocommit: mesh join required: 0 (prov=unclaimed + HELD" || abort "no unclaimed + HELD decision"
x=$(fq "echo ifaces=\$(iw dev 2>/dev/null | grep -c Interface) ap=\$(iw dev 2>/dev/null | grep -c 'type AP') mesh=\$(iw dev 2>/dev/null | grep -c 'type mesh point') helper7=[\$(logread | grep 'batman-provhelper.*boot rc=7' | tail -1 | sed 's/.*boot //')] meta=\$(sed -n 's/.*state=\([a-z]*\).*/\1/p' /etc/batman-prov/prov.meta) idmode=\$(ls -ld /etc/batman-prov/identity | cut -c1-10); $P5RO")
say "trial: $(echo $x)"
case "$x" in *"ifaces="[1-9]*) ok "trial: iw lists interfaces";; *) no "trial: iw lists no interface (ap/mesh counts meaningless)";; esac
for w in "ap=0" "mesh=0" "meta=unclaimed" "idmode=drwx------" "seeded=n" "prov_files=7" "metastat=[ok unclaimed]" "ident=ok" "idsame=y"; do case "$x" in *"$w"*) ok "trial: $w";; *) no "trial: want $w";; esac; done
case "$x" in *"helper7=[rc=7 "*"persist rc=0]"*) ok "trial: helper boot rc=7 ... persist rc=0";; *) no "trial: helper rc=7 / persist rc=0 not logged";; esac
# ======== 6. gate (L44) on the same HELD trial + wsl.9 negative control; dead-man on B; release -> committed
PH=s6
fq "mkdir -p -m 0700 /tmp/run/batman-dv" >/dev/null; scp -q $FRESHO "$WSL9_SLOT" root@"$FIP":/tmp/run/batman-dv/batman-slot.wsl9 || abort "upload wsl.9 batman-slot"
o=$(fq ". /usr/lib/batman/rundir.sh; t0=\$(date +%s); sleep 1; o=\$(BATMAN_ALLOW_TRIAL_APPLY=1 batman-slot precheck-node 2>&1); rc=\$?; echo \"rc=\$rc\"; echo \"\$o\"; echo \"rcfile=[\$(cat \$RUNDIR/p5-check.rc 2>/dev/null)] newer=\$([ \$(date -r \$RUNDIR/p5-check.rc +%s 2>/dev/null || echo 0) -ge \$t0 ] && echo y || echo n)\"")
echo "$o" | sed 's/^/    gate: /'
case "$o" in "rc=0"*) no "gate: precheck-node passed on an unseeded trial";; *) ok "gate: precheck-node refused (rc ≠ 0)";; esac
grep -qF "p5 not seeded but holds an unclaimed provisioning record — allowed (#254 L44)" <<< "$o" && ok "gate: the L44 branch ran (review B-3)" || no "gate: L44 line missing"
grep -q "mis-aimed tryboot" <<< "$o" && ok "gate: ends on mis-aimed tryboot (F6)" || no "gate: no mis-aimed tryboot"
case "$o" in *"rcfile=[skip:unseeded "*"newer=y"*) ok "gate: p5-check.rc = skip:unseeded, written now";; *) no "gate: p5-check.rc not skip:unseeded / not updated";; esac
o=$(fq ". /usr/lib/batman/rundir.sh; m0=\$(date -r \$RUNDIR/p5-check.rc +%s 2>/dev/null); sleep 1; o=\$(BATMAN_ALLOW_TRIAL_APPLY=1 sh /tmp/run/batman-dv/batman-slot.wsl9 precheck-node 2>&1); rc=\$?; echo \"rc=\$rc out=[\$(echo \"\$o\" | tail -1)] same_mtime=\$([ \"\$(date -r \$RUNDIR/p5-check.rc +%s 2>/dev/null)\" = \"\$m0\" ] && echo y || echo n)\"; rm -f /tmp/run/batman-dv/batman-slot.wsl9")
say "gate wsl.9 (negative): $o"
case "$o" in "rc=1 "*"not seeded"*"same_mtime=y"*) ok "gate negative: wsl.9 batman-slot -> rc 1, not seeded, p5-check.rc untouched";; *) no "gate negative control: $o";; esac
fq "rl=\$(mktemp /tmp/run/ch1-rcl.XXXXXX) && { grep -v '^exit 0' /etc/rc.local; echo '( ping -c 5 $HOSTIP; sleep 1500; sh $BASE/ch1-deadman.sh ) </dev/null >/dev/null 2>&1 & # ch1-deadman'; echo 'exit 0'; } > \$rl && cat \$rl > /etc/rc.local && rm -f \$rl; sync; setsid sh -c 'sleep 1500; sh $BASE/ch1-deadman.sh' </dev/null >/dev/null 2>&1 & echo planted" >/dev/null
pl=$(fq "echo rclocal=\$(grep -c ch1-deadman /etc/rc.local) script=\$([ -x $BASE/ch1-deadman.sh ] && echo y) timer=\$(ps w | grep -c '[s]leep 1500')")
say "dead-man on B: $pl"; case "$pl" in "rclocal=1 script=y timer="[1-9]*) ;; *) abort "dead-man not armed on B";; esac
r=$(fq 'batman-autocommit release --wait 2>&1 | tail -1'); say "release: $r"
s=$(fq "$ST"); case "$s" in *"slot=B "*"trial_rc=1 "*) ok "B committed (unclaimed)";; *) abort "B not committed after release: $s";; esac
# the reservation reboot follows on the committed slot (E1c: ~145 s); wait for B's next boot and find it again
PH=s6r; t=$SECONDS; while [ $((SECONDS - t)) -lt 400 ]; do b=$(fq 'cut -c1-8 /proc/sys/kernel/random/boot_id'); [ "$b" = "$BT" ] || break; sleep 10; done
wait_find 600 "slot=B ver=$V trial_rc=1 " "$BT" || abort "B not found after the reservation reboot"
say "B committed at $FIP ($FOUND_HOW): $FOUND_STATE"; BB=$(bootof "$FOUND_STATE")
t=$SECONDS; d=""; while [ $((SECONDS - t)) -lt 300 ]; do d=$(fq 'echo "$(uci -q get openmanetd.config.dhcpconfigured) $(cut -d. -f1 /proc/uptime)"'); [ "${d%% *}" = 1 ] && [ "${d##* }" -ge 150 ] && break; sleep 10; done
say "B stable: dhcpconfigured/uptime=$d"
# ======== 7. unclaimed OTA
PH=s7.1; P0=$(fq "$PROT"); say "before: $P0"
case "$P0" in "protA=[$V]"*) ok "7.1 slot-A.protected = V before (so 'unchanged' means something)";; *) no "7.1 protA not V: $P0";; esac
nf=$(fq "$NOFORCE"); [ "$nf" = "allow_unseeded=n allow_stale=n allow_txn=n" ] && ok "7.x no override files ($nf)" || abort "override files present: $nf"
o=$(fq 'set -e; d=/tmp/run/batman-dv; mkdir -p -m 0700 $d; sed "s| /usr/lib/batman/prov-lock.sh'"'"'$|'"'"'|" /lib/upgrade/platform.sh > $d/platform.noprovlock; a=$(grep -c "^RAMFS_COPY_DATA=.*prov-lock.sh" /lib/upgrade/platform.sh); b=$(grep -c "^RAMFS_COPY_DATA=.*prov-lock.sh" $d/platform.noprovlock || true); l0=$(wc -l < /lib/upgrade/platform.sh); l1=$(wc -l < $d/platform.noprovlock); if [ "$a" = 1 ] && [ "$b" = 0 ] && [ "$l0" = "$l1" ]; then mount --bind $d/platform.noprovlock /lib/upgrade/platform.sh; echo "variant=ok binds=$(grep -c " /lib/upgrade/platform.sh " /proc/mounts)"; else echo "variant=bad a=$a b=$b l0=$l0 l1=$l1"; fi')
say "7.1 variant: $o"; case "$o" in *"variant=ok binds=1"*) ;; *) abort "7.1 variant not built";; esac
# the trace lines of THIS OTA, found by the boot id it was started in (stage 1 and stage 2 log that boot id) — not by
# a line offset: 95-batman-storage trims ota-trace.log to its last 1500 lines at boot when it passes 256 KiB
# (95:713), which shifted the offset under the 2026-10-26 wsl.3 run (otan.71=1791 > 1579 lines left). Kept on p6.
fq "cut -c1-8 /proc/sys/kernel/random/boot_id > $D/otab.71; echo '$V' > /opt/batdata/state/autocommit-hold-commit; sync; setsid sh -c 'sysupgrade -n $PAY >/opt/batdata/sysup-ch1-71.log 2>&1' </dev/null >/dev/null 2>&1 &" >/dev/null
wait_find 900 "slot=B ver=$V trial_rc=1 " "$BB" || abort "7.1: B not back (committed) after the stage-2 failure"
say "7.1 back: $FIP $FOUND_STATE"; BB=$(bootof "$FOUND_STATE")
tr=$(fq "b=\$(cat $D/otab.71); [ \${#b} = 8 ] && grep -F \" boot=\$b \" /opt/batdata/log/ota-trace.log | grep -E 'S2 |SLOT DIE|REFUS'"); echo "$tr" | sed 's/^/    trace: /'
case "$tr" in *"S2 BEGIN"*) ok "7.1 stage 2 ran (S2 BEGIN of this OTA's boot)";; *) no "7.1 no S2 BEGIN for this OTA's boot";; esac
grep -E "DIE" <<< "$tr" | grep -q "not seeded" && ok "7.1 stage 2 died on 'not seeded' (prov-lock.sh absent from the ramfs)" || no "7.1 no SLOT DIE ... not seeded"
grep -q "S2 END rc=[1-9]" <<< "$tr" && ok "7.1 S2 END rc != 0" || no "7.1 no failing S2 END"
P1=$(fq "$PROT"); [ "$P0" = "$P1" ] && ok "7.1 A untouched ($P1)" || no "7.1 .protected changed: $P0 -> $P1"
fq 'grep -c " /lib/upgrade/platform.sh " /proc/mounts' | grep -qx 0 && ok "7.1 bind gone after the reboot" || no "7.1 bind still present"
fq 'rm -f /opt/batdata/state/autocommit-hold-commit' >/dev/null
PH=s7.2
nf=$(fq "$NOFORCE"); [ "$nf" = "allow_unseeded=n allow_stale=n allow_txn=n" ] || abort "override files present: $nf"
fq "cut -c1-8 /proc/sys/kernel/random/boot_id > $D/otab.72; echo '$V' > /opt/batdata/state/autocommit-hold-commit; sync; setsid sh -c 'sysupgrade -n $PAY >/opt/batdata/sysup-ch1-72.log 2>&1' </dev/null >/dev/null 2>&1 &" >/dev/null
wait_find 600 "slot=A ver=$V trial_rc=0 dt_try=00000001 " "$BB" || abort "7.2: A trial not found"
say "7.2 A trial at $FIP ($FOUND_HOW): $FOUND_STATE"; BA=$(bootof "$FOUND_STATE")
ev=""; t=$SECONDS; while [ $((SECONDS - t)) -lt 150 ]; do ev=$(fq "logread | grep -E 'batman-autocommit|batman-provhelper'"); grep -q HELD <<< "$ev" && break; sleep 5; done
x=$(fq "b=\$(cat $D/otab.72); [ \${#b} = 8 ] && grep -F \" boot=\$b \" /opt/batdata/log/ota-trace.log | grep -E 'S2 END' | tail -1; echo meta=\$(sed -n 's/.*state=\([a-z]*\).*/\1/p' /etc/batman-prov/prov.meta) ifaces=\$(iw dev 2>/dev/null | grep -c Interface) ap=\$(iw dev 2>/dev/null | grep -c 'type AP'); $P5RO")
say "7.2: $(echo $x)"
case "$x" in *"S2 END rc=0"*) ok "7.2 stage 2 rc=0 (this OTA)";; *) no "7.2 stage 2 rc";; esac
case "$x" in *"ifaces="[1-9]*) ;; *) no "7.2 iw lists no interface";; esac
for w in "meta=unclaimed" "ap=0" "seeded=n" "metastat=[ok unclaimed]"; do case "$x" in *"$w"*) ok "7.2 trial: $w";; *) no "7.2 trial: want $w";; esac; done
grep -E "batman-provhelper.*boot rc=(7|0) " <<< "$ev" | tail -1 | grep -q "verdict=unclaimed" && ok "7.2 helper boot rc 7/0 + unclaimed" || no "7.2 helper boot line"
grep -q "mesh join required: 0 (prov=unclaimed" <<< "$ev" && ok "7.2 autocommit: mesh join required: 0 (prov=unclaimed" || no "7.2 autocommit decision"
grep -q "HELD" <<< "$ev" && ok "7.2 HELD" || no "7.2 not HELD"
PH=s7.3; fq "batman-slot rollback >/dev/null 2>&1; (batman-slot reboot committed ch1-b </dev/null >/dev/null 2>&1 &)" >/dev/null
wait_find 600 "slot=B ver=$V trial_rc=1 " "$BA" || abort "7.3: B not found after back_to_b"
say "7.3 B: $FIP $FOUND_STATE"; BB=$(bootof "$FOUND_STATE")
case "$FOUND_STATE" in *"badslot=[]"*) ok "7.3 back on B committed, no bad-slot";; *) no "7.3 bad-slot: $FOUND_STATE";; esac
# ======== 8. claim on B, then the claimed OTA
PH=s8.2
pub=$(cat "$LABKEY.pub"); fq "mkdir -p -m 0700 /etc/dropbear; grep -qxF '$pub' /etc/dropbear/authorized_keys 2>/dev/null || echo '$pub' >> /etc/dropbear/authorized_keys; chmod 0600 /etc/dropbear/authorized_keys; chown root:root /etc/dropbear/authorized_keys" >/dev/null
pk_proof "$FIP" && ok "8.2 lab key: publickey PROVEN (ssh -v: Authenticated using publickey)" || abort "8.2 publickey does not authenticate — not claiming"
PH=s8.3
MSYS_NO_PATHCONV=1 wsl.exe -d Ubuntu-24.04 -u yello -- bash -c "umask 077; mkdir -p $WSLK && $TOOLS_WSL/provclient-amd64 keygen $WSLK/owner.pem > $WSLK/owner.pub && $TOOLS_WSL/provclient-amd64 keygen $WSLK/enc.pem > $WSLK/enc.pub"
OWNER=$(MSYS_NO_PATHCONV=1 wsl.exe -d Ubuntu-24.04 -u yello -- cat $WSLK/owner.pub | tr -d '\r'); ENC=$(MSYS_NO_PATHCONV=1 wsl.exe -d Ubuntu-24.04 -u yello -- cat $WSLK/enc.pub | tr -d '\r')
[ ${#OWNER} = 130 ] && [ ${#ENC} = 130 ] || abort "owner keys"
# per run, created without -p: an existing dir / symlink there is refused (254-h23 F23; tmpfs: gone with every reboot)
fq "mkdir -m 0711 $PCD && echo MADE" | grep -q MADE || abort "FAIL dvpc dir pre-exists: $PCD (refusing a planted provclient dir)"
scp -q $FRESHO "$TOOLS/provclient-arm64" root@"$FIP":$PCD/provclient && fq "chmod 0755 $PCD/provclient" >/dev/null || abort "provclient upload"
r=$(pc owner.pem claim "$OWNER" "$ENC"); echo "$r" | sed 's/^/    /'
grep -q "RESULT claim.verify code=0 " <<< "$r" && ok "8.3 claim.verify code 0" || abort "8.3 claim failed"
x=$(fq "echo state=\$(sed -n 's/.*state=\([a-z]*\).*/\1/p' /etc/batman-prov/prov.meta) lock=\$(cat /opt/batdata/state/lock-status) pw=\$(uci -q get dropbear.@dropbear[0].PasswordAuth) rootpw=\$(uci -q get dropbear.@dropbear[0].RootPasswordAuth) tty=\$(uci -q get system.@system[0].ttylogin) hash=\$(grep ^root: /etc/shadow | cut -d: -f2 | cut -c1-3); logread | grep 'batman-provhelper' | grep -E 'claim|lock|save' | tail -3; $P5RO")
say "8.3 after claim: $(echo $x)"
for w in "state=claimed" "lock=LOCKED" " pw=off " "rootpw=off" "tty=1" 'hash=$6$' "seeded=y" "shadowroot=y" "metastat=[ok claimed]"; do case "$x" in *"$w"*) ok "8.3 $w";; *) no "8.3 want $w";; esac; done
SEEDED=n; case "$x" in *"seeded=y"*) SEEDED=y;; esac
PH=s8.4
pk_proof "$FIP" && ok "8.4 publickey PROVEN after the claim (L47)" || abort "8.4 lost publickey login"
if none_refused "$FIP"; then ok "8.4 'none' refused after the claim (publickey-only)"; else case "$x" in *"lock=LOCKED"*) no "8.4 'none' still accepted on a LOCKED node";; *) warn "8.4 'none' accepted — not discriminating (node not locked, see 8.3)";; esac; fi
PH=s8.5; fq 'ls /opt/batdata/state/mesh-joined /opt/batdata/state/mesh-expected 2>/dev/null | wc -l' | grep -qx 0 && ok "8.5 no mesh markers on p6" || no "8.5 mesh markers present"
PH=s8.6
nf=$(fq "$NOFORCE"); [ "$nf" = "allow_unseeded=n allow_stale=n allow_txn=n" ] || abort "override files present: $nf"
fq "echo '$V' > /opt/batdata/state/autocommit-hold-commit; sync; setsid sh -c 'sysupgrade -n $PAY >/opt/batdata/sysup-ch1-86.log 2>&1' </dev/null >/dev/null 2>&1 &" >/dev/null
FIP0=$FIP   # wait_find clears FIP on a miss (review round 2 m3)
if [ "$SEEDED" = n ]; then
	# known bug path: the stage-1 gate must refuse (claimed + unseeded), B stays on the same boot (review A-M5 / B-5)
	t=$SECONDS; lg=""; while [ $((SECONDS - t)) -lt 90 ]; do lg=$(fq 'cat /opt/batdata/sysup-ch1-86.log 2>/dev/null'); grep -q "REFUSING" <<< "$lg" && break; sleep 5; done
	echo "$lg" | tail -3 | sed 's/^/    sysup: /'
	b=$(fq 'cut -c1-8 /proc/sys/kernel/random/boot_id')
	if grep -q "REFUSING (node not ready" <<< "$lg" && grep -q "not seeded" <<< "$lg" && [ "$b" = "$BB" ]; then ok "8.6 gate refused the claimed + unseeded OTA in stage 1 (same boot) — consequence of the 8.3 bug"
	elif wait_find 600 "slot=A ver=$V trial_rc=0 " "$BB"; then no "8.6 GATE LEAK: claimed + unseeded node entered an A trial"; else no "8.6 neither refused nor landed (boot $BB -> $b)"; FIP=$FIP0; fi
	FIP=${FIP:-$FIP0}; fq 'rm -f /opt/batdata/state/autocommit-hold-commit' >/dev/null
	echo "NOTDONE 8.6 (claimed trial decision) / 8.7 (dry-run negative): blocked by the 8.3 product bug"
elif wait_find 600 "slot=A ver=$V trial_rc=0 dt_try=00000001 " "$BB"; then
	say "8.6 A trial at $FIP: $FOUND_STATE"; BA=$(bootof "$FOUND_STATE")
	ev=""; t=$SECONDS; while [ $((SECONDS - t)) -lt 150 ]; do ev=$(fq "logread | grep -E 'batman-autocommit'"); grep -q HELD <<< "$ev" && break; sleep 5; done
	echo "$ev" | grep -E "mesh join required|HELD" | tail -3 | sed 's/^/    /'
	grep -q "mesh join required: 0 (prov=claimed mesh_expect=0" <<< "$ev" && grep -q HELD <<< "$ev" && ok "8.6 claimed trial: mesh join required: 0 (prov=claimed mesh_expect=0 + HELD" || no "8.6 claimed trial decision"
	x=$(fq "echo lock=\$(cat /opt/batdata/state/lock-status) tty=\$(uci -q get system.@system[0].ttylogin) hash=\$(grep ^root: /etc/shadow | cut -d: -f2 | cut -c1-3)")
	case "$x" in *"lock=LOCKED"*"tty=1"*'hash=$6$'*) ok "8.6 claimed trial is locked, root hash restored from p5 ($x)";; *) no "8.6 claimed trial lock: $x";; esac
	PH=s8.7   # no `timeout` applet in the node busybox (2026-10-26 wsl.3 run: "ash: timeout: not found"): a sleep + kill watchdog
	o=$(fqlong "cp -p $D/marks/mesh-expected /opt/batdata/state/mesh-expected 2>/dev/null || echo 'ch1 white-box' > /opt/batdata/state/mesh-expected; u=\$(cut -d. -f1 /proc/uptime); { AUTOCOMMIT_DRYRUN=1 AUTOCOMMIT_TIMEOUT=\$((u + 60)) batman-autocommit run 2>&1 & p=\$!; ( sleep 90; kill \$p 2>/dev/null ) & w=\$!; wait \$p; kill \$w 2>/dev/null; } | tail -3; logread | grep -E 'claimed with the placeholder mesh key|mesh join required: 1 ' | tail -2; rm -f /opt/batdata/state/mesh-expected")
	echo "$o" | sed 's/^/    dry: /'
	grep -q "claimed with the placeholder mesh key, but p6 says this node has been in a mesh — neighbours required (fail-closed)" <<< "$o" && grep -q "mesh join required: 1 (prov=claimed mesh_expect=0" <<< "$o" \
		&& ok "8.7 negative: mesh-expected back -> claimed+placeholder needs neighbours, mesh join required: 1 (prov=claimed" || no "8.7 negative control (review B-4 strings)"
	PH=s8.8; fq "batman-slot rollback >/dev/null 2>&1; (batman-slot reboot committed ch1-b </dev/null >/dev/null 2>&1 &)" >/dev/null
	wait_find 600 "slot=B ver=$V trial_rc=1 " "$BA" || abort "8.8: B not found"
	say "8.8 B: $FIP $FOUND_STATE"
else
	FIP=$FIP0; sysl=$(fq 'tail -3 /opt/batdata/sysup-ch1-86.log' | tr '\n' ' ')
	no "8.6 seeded claimed node: OTA did not land in an A trial (sysup: $sysl)"
	fq 'rm -f /opt/batdata/state/autocommit-hold-commit' >/dev/null
fi
# ======== 9. restore
restore_all "step 9" || { RESULT="RESTORE FAILED — needs a person"; exit 1; }
p=$(timeout 30 ssh $SSHO root@$PEER "$ST" 2>/dev/null | tr -d '\r'); say "02 after: [$p]"
[ "$(bootof "$peer0")" = "$(bootof "$p")" ] || warn "02 rebooted during the run (boot $(bootof "$peer0") -> $(bootof "$p")) — isolation > joinwatch's window (A-m6)"
[ "$fails" = 0 ] && RESULT=PASS || RESULT="FAIL ($fails)"
