#!/bin/bash
# scripts/dv/chain1-254.sh v3 — #254 P1 residual "鏈 1" (docs/design/254-p1-impl.md §5.4 chain 1, steps 1-9) on 04, from Git Bash.
#   1 snap (+ mesh markers moved into the snapshot)   2 p5 idle   3 p5 mkfs   4 hold + apply V to B (unseeded) + reboot
#   5 HELD fresh trial on B: unclaimed assertions, and (P2 image) 02 reads STATUS over BLE = unclaimed, updating, the
#     serial's last 4 (h23 §6.3 prov-firstboot-254, provd side). The host reaches 02 only through 04's mesh, so 02 is
#     cut off while 04 is off the mesh: a time-limited reader started on 02 before step 4 reads STATUS every ~45 s
#     (02 uptime + value to a file); step 9 fetches it and judges the reads inside the trial window     6 gate (L44) + wsl.9 negative control; dead-man; release -> B committed
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
# 04 / 02 from the bench store's membership log (bench-254.sh: the last line of each node), or NODE= / PEER= given;
# no address -> refused (no guess: the pre-conversion fleet's 10.41.1.3 / .1 are gone)
# shellcheck source=scripts/dv/bench-254.sh
. "$(dirname "$0")/bench-254.sh"
[ -n "${NODE:-}" ] || NODE=$(bench_ip 04); [ -n "${PEER:-}" ] || PEER=$(bench_ip 02)
[ -n "$NODE" ] && [ -n "$PEER" ] || { echo "chain1: no address for 04 [$NODE] / 02 [$PEER] (bench store nodes.txt, or NODE= / PEER=)"; echo "CHAIN1 RESULT: FAIL (no addresses)"; exit 1; }
PEERMAC=${PEERMAC:-a8:dd:9f:4d:c7:60}   # 02's mesh interface (wlh0), as prov-254.sh: the neighbour must be 02
HOSTIP=${HOSTIP:-10.41.240.10}; MACW=88-a2-9e-b5-6c-89; MAC=88:a2:9e:b5:6c:89; MDNS=BCM2711-6c89.local
V=${V:?version}; PAY=${PAY:-/opt/batdata/ota-1.5.13-wsl.1.tar.gz}; PSHA=${PSHA:?payload sha256}
OUTS=${OUTS:-//wsl.localhost/Ubuntu-24.04/home/yello/out}
REPO=${REPO:-$(cd "$(dirname "$0")/../.." && pwd)}; PB=$REPO/scripts/node/prov-base-254.sh
TOOLS=${DV_PROV_TOOLS:-/c/Users/yello/batman-dv-tools/prov}; TOOLS_WSL=/home/yello/batman-dv-tools/prov
BREWRITE=${BREWRITE:-$REPO/scripts/dv/brewrite-254.sh}; WSL9_SLOT=${WSL9_SLOT:-$REPO/tests/prov-p1/fixtures/batman-slot.1.5.12-wsl.9}
LABKEY=${LABKEY:-$HOME/.ssh/id_ed25519}
RUN=ch1$(date +%m%d%H%M); PCD=/tmp/run/batman-dvpc.$RUN; BASE=/opt/batdata/dv-prov; D=$BASE/$RUN; PDIR=$BASE/payload-ch1; DIRTY=/opt/batdata/state/dv-prov-dirty
LOCKD=${TEMP:?TEMP unset - the host lock lives in the per-user temp dir, never in a shared tmp}/batman-dv-04.lock; WSLK=/home/yello/.batman-dv/prov-keys/$RUN
# ssh option sets, pk_proof / none_refused, say / ok / no, q / fq, find04 / wait_find, pc, land_quiet: shared with
# prov-bench-s0-254.sh
# shellcheck source=scripts/dv/fresh-254.sh
. "$(dirname "$0")/fresh-254.sh"
STAGED=0; SNAPPED=0; RESULT=FAIL; RESTORING=0
mkdir "$LOCKD" 2>/dev/null || { echo "another dv run holds $LOCKD"; exit 1; }
# an unexpected exit after the snapshot (set -u, a bug) still restores (review A-M1)
# the 02 STATUS reader (step 2-4) goes on every exit; 02 unreachable -> the next central session on 02 stops it
# on 02: every process naming the reader dir (the loop and an in-flight read, both setsid group leaders) with its group
C1RKILL='for p in $(grep -l "@D@/" /proc/[0-9]*/cmdline 2>/dev/null | cut -d/ -f3); do [ "$p" = $$ ] && continue; kill -TERM -- -$p 2>/dev/null; kill -TERM $p 2>/dev/null; done'
c1r_stop(){ [ -n "${P02_U0:-}" ] && timeout 20 ssh $SSHO root@$PEER "${C1RKILL//@D@/$C1R}; rm -rf $C1R" >/dev/null 2>&1; P02_U0=""; }
# 02's identity, labelled (an empty field never shifts another into its place): mac= mid= ps=
P02ID="echo \"mac=\$(cat /sys/class/net/wlh0/address 2>/dev/null) mid=\$(uci -q get wireless.default_radio1.mesh_id) ps=\$(awk -v b=\$(cat /proc/sys/kernel/random/boot_id) '\$1==b {print \$4}' /opt/batdata/state/prov-state 2>/dev/null)\""
p02f(){ sed -n "s/.*\\b$2=\\([^ ]*\\).*/\\1/p" <<< " $1"; }
# chk02_after: after ANY restore that finished (step 9, or an abort's), the live mesh (compare covers config only,
# review B-M4): 02 a neighbour of 04 again within 180 s, 02's identity as before. P02_DONE: once per run.
chk02_after(){ local t nbok=n p02_1 m
	[ "${P02_DONE:-0}" = 1 ] && return 0; P02_DONE=1
	t=$SECONDS; while [ $((SECONDS - t)) -lt 180 ]; do q "batctl n -n 2>/dev/null | tail -n +3 | grep -qiw -- $PEERMAC && echo NB" | grep -q NB && { nbok=y; break; }; sleep 10; done
	if [ $nbok = y ]; then ok "9 02 ($PEERMAC) is a mesh neighbour of 04 again"
	else no "9 02 ($PEERMAC) not a neighbour of 04 within 180 s of the restore"
		# 02 off the mesh has no remote way back (no cable, 254-h4 lifecycle row "02 離開 mesh") -> a person
		m="NEEDS-PERSON chain1-254 ($RUN): 02 ($PEERMAC) is not back on the mesh after the restore"; echo "$m"
		[ -n "${DV_DIR:-}" ] && echo "$m" >> "$DV_DIR/needs-person.txt"
	fi
	p02_1=$(timeout 30 ssh $SSHO root@$PEER "$P02ID" 2>/dev/null | tr -d '\r')
	[ -n "$(p02f "$p02_1" mid)" ] && [ "$p02_1" = "$p02_0" ] && ok "9 02 unchanged: [$p02_1]" || no "9 02 changed or unreadable: [$p02_0] -> [$p02_1]"
}
on_exit(){ local rc=$? m; c1r_stop; if [ "$SNAPPED" = 1 ] && [ "$RESTORING" = 0 ]; then no "unexpected exit (rc $rc) — restoring"; restore_all "unexpected exit"; fi
	if [ "$SNAPPED" = 1 ] && [ "${RESTORE_PERSON:-1}" = 1 ]; then
		# 04 is left to a person (snapshot / dirty flag kept): the run's later D suites on 04 must not touch it
		# (daily-validation.sh suite(): dnode_blocked reads $DV_DIR/needs-person.txt; review round 2 B-M2)
		m="NEEDS-PERSON chain1-254 ($RUN): the restore did not finish — snapshot $D and the dirty flag are kept on 04 ($NODE)"
		echo "$m"; [ -n "${DV_DIR:-}" ] && echo "$m" >> "$DV_DIR/needs-person.txt"; RESULT="RESTORE FAILED — needs a person"
	elif [ "$SNAPPED" = 1 ] && [ -n "${p02_0:-}" ]; then chk02_after; fi
	rmdir "$LOCKD" 2>/dev/null; MSYS_NO_PATHCONV=1 wsl.exe -d Ubuntu-24.04 -u yello -- rm -rf "$WSLK" 2>/dev/null; say "CHAIN1 RESULT: $RESULT (fails=$fails)"; }
trap on_exit EXIT
trap 'say "host interrupted"; [ "$SNAPPED" = 1 ] && restore_all "interrupted"; RESTORING=1; exit 1' INT TERM


# restore_all / abort: in fresh-254.sh

# ======== 0. pre
s=$(q "$ST"); say "start: $s"
case "$s" in "mac=$MAC slot=A ver=$V trial_rc=1 dt_try="*" hold=[] held=0 badslot=[]"*) ;; *) say "precondition (04 by MAC, A committed $V, no hold, no bad-slot)"; exit 1;; esac
a=$(q "awk -v b=\$(cat /proc/sys/kernel/random/boot_id) '\$1==b {print \"ps=\" \$2 \"/\" \$4}' /opt/batdata/state/prov-state; batman-config-save --check >/dev/null 2>&1; echo check_rc=\$?; /usr/libexec/batman-addr-defer status; echo dirty=[\$(cat $DIRTY 2>/dev/null)]")
# A = legacy (the pre-conversion fleet) or the bench member (S0-pre, prov-bench-s0-254.sh): the chain runs on B and p5
# and puts A back from its own snapshot either way
say "A: $(echo $a)"; A_PS=$(sed -n 's/.*ps=helper\/\([a-z]*\).*/\1/p' <<< "$a")
case "$A_PS" in legacy|member) ;; *) say "A is neither legacy nor member [$A_PS]"; exit 1;; esac
case "$a" in *"check_rc=0"*"want=stock env=absent openmanetd=up"*"dirty=[]"*) ;; *) say "A not healthy / dirty flag present"; exit 1;; esac
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
# 02 must be the bench peer, reachable, on N0 with 04 as a neighbour BEFORE anything is changed (review B-M4: a wrong
# PEER would otherwise surface only after the snapshot, as a destructive abort); its identity (P02ID, labelled) recorded
p02_0=$(timeout 30 ssh $SSHO root@$PEER "$P02ID" 2>/dev/null | tr -d '\r'); say "02: [$p02_0]"
[ -n "$peer0" ] && [ "$(p02f "$p02_0" mac)" = "$PEERMAC" ] && [ -n "$(p02f "$p02_0" mid)" ] && [ -n "$(p02f "$p02_0" ps)" ] \
	|| { say "02 at $PEER is not reachable / not the bench peer ($PEERMAC) / has no mesh id or prov state"; p02_0=""; exit 1; }
q "batctl n -n 2>/dev/null | tail -n +3 | grep -qiw -- $PEERMAC && echo NB" | grep -q NB || { say "02 ($PEERMAC) is not a neighbour of 04 before the run"; exit 1; }
P1_0=$(q "$P1LIST"); say "A boot FAT (p1, /boot) before: $(echo "$P1_0" | wc -l) files, list sha $(echo "$P1_0" | sha256sum | cut -c1-16)"; [ "$(echo "$P1_0" | wc -l)" -ge 5 ] || { say "cannot hash p1"; exit 1; }
q "mkdir -p -m 700 $PDIR && cd $PDIR && rm -rf ./* && tar -xzf $PAY && echo extracted" | sed 's/^/    /'
# ======== 1. snapshot; mesh markers into the snapshot dir (step 8's premise); dead-man staged on p6
PH=s1
o=$(timeout 900 ssh $SSHO root@$NODE "KEEP_JOINWATCH_STOPPED=1 sh -s -- snap $RUN" < "$PB" 2>&1 | tr -d '\r'); say "$(echo "$o" | tail -1)"
# the SNAP line lost (network, the 900 s timeout) does not mean the snapshot was not taken: the node's dirty flag says
# (prov-base-254.sh:157 writes "<run> <boot> snap" once the snapshot is complete; joinwatch stays stopped meanwhile,
# KEEP_JOINWATCH_STOPPED) -> this run's flag = snapshot taken, go on as after a snapshot (an abort restores);
# unreadable -> hand 04 to a person (review round 3 A-m5 / B-7)
if ! grep -q "^SNAP $RUN" <<< "$o"; then
	dfl=$(timeout 60 ssh $SSHO root@$NODE "cat $DIRTY 2>/dev/null; echo rc=\$?" 2>/dev/null | tr -d '\r')
	case "$dfl" in
		"$RUN "*" snap"*) say "snap: no SNAP line, but the dirty flag is this run's ($(head -1 <<< "$dfl")): the snapshot was taken"; SNAPPED=1; FIP=$NODE; FOUND_STATE=$s; abort "snap result lost (restoring from the taken snapshot)" ;;
		*rc=*) say "snap failed (dirty flag [$(head -1 <<< "$dfl")]: not this run's)"; q '/etc/init.d/joinwatch start >/dev/null 2>&1'; exit 1 ;;
		*) SNAPPED=1; RESTORE_PERSON=1; RESTORING=1; say "snap result lost and 04 unreadable: whether a snapshot exists is unknown"; exit 1 ;;
	esac
fi
SNAPPED=1; FIP=$NODE; FOUND_STATE=$s
SNAPSHA=$(q "cut -c1-16 $D/p5.img.sha")
# the p1 list into the snapshot (as prov-bench-s0 fresh does): finishing an aborted run with
# `prov-bench-s0-254.sh restore 04 <run>` needs it (2026-11-08: that restore refused the chain1 snapshot without it)
printf '%s\n' "$P1_0" | ssh $SSHO root@$NODE "umask 077; cat > $D/p1.list" || abort "p1 list into the snapshot"
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
# acting from here: the marker first, then the cancel check (restore touches ch1.cancel, then refuses its own rollback
# while ch1.running exists); a run that stopped half-way leaves the marker and the restore to a person
mkdir $BASE/ch1.running 2>/dev/null || exit 0
[ -f $BASE/ch1.cancel ] && { rmdir $BASE/ch1.running; exit 0; }
logger -t ch1-deadman 'restoring p5 and returning to A'
L=$BASE/ch1-deadman.log
/etc/init.d/openmanetd stop >> \$L 2>&1
sh $BASE/prov-base-254.sh p5-restore $RUN >> \$L 2>&1; p=\$?; echo \"p5-restore rc=\$p\" >> \$L
# a failed p5-restore: no rollback onto a half-written p5; ch1.running stays, a person takes over (round 7 B-MINOR-2)
[ \$p = 0 ] || { logger -t ch1-deadman 'p5-restore failed: no rollback, ch1.running kept for a person'; sync; exit 1; }
# an armed tryboot would make the rollback's reboot a plain one INTO the tryboot slot (batman-slot cmd_reboot): disarm,
# and read the flag with the product's own reader; not 0 -> nothing more, ch1.running kept for a person (round 8 A-m1)
vcmailbox 0x00038064 4 4 0 >/dev/null 2>&1; . /usr/lib/batman/bootfacts.sh; g=\$(bf_get); echo \"tryboot flag after disarm: \$g\" >> \$L
[ \"\$g\" = 0 ] || { logger -t ch1-deadman \"tryboot flag \$g after disarm: no rollback, ch1.running kept for a person\"; sync; exit 1; }
batman-slot rollback >> \$L 2>&1; r=\$?; echo \"rollback rc=\$r\" >> \$L
# done: ch1.fired, then the marker goes (a ch1.running left behind = a run cut short or failed; round 7 B-MINOR-3)
[ \$r = 0 ] && { : > $BASE/ch1.fired; rmdir $BASE/ch1.running; }; sync
batman-slot reboot committed ch1-deadman >> \$L 2>&1
DM
chmod 700 $BASE/ch1-deadman.sh; rm -rf $BASE/ch1.cancel $BASE/ch1.fired $BASE/ch1.running $BASE/ch1-deadman.log; sh -n $BASE/ch1-deadman.sh && echo ok" | grep -q '^ok$' || abort "dead-man write"
STAGED=1; say "dead-man staged (snapshot p5 sha $SNAPSHA)"
# ======== 2-4. p5 idle -> mkfs -> hold + apply (unseeded) -> controlled reboot
PH=s2-4
# 04 runs provd? (the fresh trial generates a NEW identity — p5 is mkfs'd — so its serial's last 4 is read in step 5;
# step 5's idsame=y only compares the new identity with its own p5 copy)
LAST4=$(q 'tr -d "\n" < /etc/batman-prov/identity/sn | tail -c 4'); HASPROVD=$(q '[ -x /usr/bin/batman-provd ] && echo y || echo n')
C1R=/tmp/run/batman-dv/ch1-$RUN; P02_U0=""; P02_S0=""
if [ "$HASPROVD" = y ]; then
	# 3600 s, then it ends by itself (a run that aborts leaves nothing behind on 02 for long); no state change on 02
	o=$(timeout 30 ssh $SSHO root@$PEER "mkdir -p -m 0700 /tmp/run/batman-dv && mkdir -m 0700 $C1R && cat > $C1R/c.sh && echo PUT" < "$REPO/scripts/node/prov-p2-central-254.sh" 2>/dev/null | tr -d '\r')
	[ "$o" = PUT ] || abort "02: could not place the STATUS reader"
	timeout 30 ssh $SSHO root@$PEER "setsid sh -c 'e=\$((\$(cut -d. -f1 /proc/uptime) + 3600)); while [ \$(cut -d. -f1 /proc/uptime) -lt \$e ]; do o=\$(BATMAN_DV_C1R=1 setsid sh $C1R/c.sh read - 2>/dev/null | sed -n \"s/^STATUS //p\"); echo \"\$(cut -d. -f1 /proc/uptime) \${o:--}\" >> $C1R/status.log; sleep 5; done' </dev/null >/dev/null 2>&1 &" >/dev/null 2>&1
	P02_U0=$(timeout 15 ssh $SSHO root@$PEER 'cut -d. -f1 /proc/uptime' 2>/dev/null | tr -d '\r'); P02_S0=$SECONDS
	case "$P02_U0" in ''|*[!0-9]*) abort "02 uptime unreadable (the reader's clock)";; esac
	say "02 STATUS reader started (02 uptime $P02_U0 = host +$P02_S0 s)"
fi
o=$(q "grep -c ' /dev/mmcblk0p5 ' /proc/mounts; ps w | grep -c '[b]atman-config-save'"); [ "$(echo $o)" = "0 0" ] && ok "p5 idle" || abort "p5 busy: $(echo $o)"
o=$(q "mkfs.ext4 -F -q -L batconfig /dev/mmcblk0p5 && echo MKFS-OK; $P5RO"); say "p5 after mkfs: $(echo $o)"
case "$o" in *MKFS-OK*"seeded=n"*) ok "p5 empty, not seeded";; *) abort "mkfs";; esac
# a fresh card has an empty p6 too: p6's prov-state is the fail-secure ratchet (batman-prov-lock: "p5 says - but p6
# says member — locking (any)"), so a member's p6 kept the fresh trial LOCKED -> no `none` login -> find04 never saw it
# (2026-11-08 chain1 on the member base: trial up at 10.41.254.76, dropbear "Exit before auth", 0 fails). prov-state is
# one of the snapshot's state files: overlay-restore puts it back, compare checks it
o=$(q "rm -f /opt/batdata/state/prov-state; sync; [ -e /opt/batdata/state/prov-state ] && echo P6-KEPT || echo P6-CLEARED")
[ "$o" = P6-CLEARED ] && ok "p6 prov-state cleared (fresh card)" || abort "p6 prov-state not cleared: [$o]"
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
# provd side: the exact STATUS (provd server.go Status): {1:[1,0], 2:["halow"], 3:0 unclaimed, 4:true trial, 5:last4}
if [ "$HASPROVD" = y ]; then
	L4N=$(fq 'tr -d "\n" < /etc/batman-prov/identity/sn | tail -c 4')
	case "$L4N" in [0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;; *) no "trial: the fresh serial's last 4 unreadable [$L4N]";; esac
	say "trial: fresh serial last 4 = $L4N (before the reboot: $LAST4)"
	WANT5="a50182010002816568616c6f77030004f50564$(printf '%s' "$L4N" | od -An -tx1 | tr -d ' \n')"
	say "trial: 02's reader judges STATUS at step 9 (window from the reboot, host +$t0 s, to the release)"
	# the trial would be released ~130 s after the reboot and a read takes 40-60 s (04 wsl.21 2026-11-02: one read, too
	# early, in a 20 s window): hold it to reboot + 330 s, well inside the 600 s deadline of a held trial
	w=$((t0 + 330 - SECONDS)); [ "$w" -gt 0 ] && { say "trial: holding the trial $w s more for 02's reader"; sleep "$w"; }
elif [ "$HASPROVD" = n ]; then no "trial: pre-P2 image (no batman-provd) — the provd-side assertions did not run"
else no "trial: cannot tell whether 04 has batman-provd [$HASPROVD] — the provd-side assertions did not run"; fi
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
T5E=$SECONDS; r=$(fqlong "$(release_guarded "$BT" B)" | tail -1); say "release: ${r:-no answer}"; case "$r" in WRONG-STATE*) abort "release not sent ($r)";; esac   # no answer: the state check below decides
# a lost answer: the release may still be committing (its own wait ends by the deadline): read for up to 5 min
for k in 1 2 3 4 5 6 7 8 9 10; do s=$(fq "$ST"); case "$s" in *" slot=B "*"trial_rc=1 "*) break;; esac; [ -n "$r" ] && break; sleep 30; done
case "$s" in *" slot=B "*"trial_rc=1 "*) ok "B committed (unclaimed)";; *) abort "B not committed after release: $s";; esac
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
# guarded: still the 7.2 trial (boot BA) on A, still a trial (its deadline may have returned it to B meanwhile)
PH=s7.3; o=$(fq "$(rb_guarded "$BA" A 0 ch1-b)"); say "7.3 back to B: ${o:-no answer}"; [ "$o" = SENT ] || abort "7.3: rollback to B not sent ($o)"
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
	PH=s8.8; o=$(fq "$(rb_guarded "$BA" A 0 ch1-b)"); say "8.8 back to B: ${o:-no answer}"; [ "$o" = SENT ] || abort "8.8: rollback to B not sent ($o)"
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
chk02_after   # the live mesh after the restore (also after an abort's restore: on_exit)
if [ "$HASPROVD" = y ] && [ -n "$P02_U0" ]; then
	sl=$(timeout 30 ssh $SSHO root@$PEER "${C1RKILL//@D@/$C1R}; cat $C1R/status.log; rm -rf $C1R" 2>/dev/null | tr -d '\r')
	# +90 s: a read that started before the reboot may finish (and be logged) just after it, with the old value
	lo=$((P02_U0 + t0 + 90 - P02_S0)); hi=$((P02_U0 + ${T5E:-0} - P02_S0))
	say "02 reader: $(grep -c . <<< "$sl") reads; trial window = 02 uptime $lo..$hi"
	echo "$sl" | sed 's/^/    02 read: /'
	inw=$(awk -v lo="$lo" -v hi="$hi" '$1 >= lo && $1 <= hi' <<< "$sl"); say "02 reads in the window: $(echo $inw | tr -s ' ' | cut -c1-400)"
	if [ -z "${T5E:-}" ]; then no "5 provd: the run ended before the release — no trial window to judge"
	elif grep -q " $WANT5\$" <<< "$inw"; then ok "5 provd: 02 read the fresh trial's STATUS over BLE = unclaimed, updating=1, last4 $L4N ($WANT5)"
	else no "5 provd: no read in the trial window equals $WANT5"; fi
	awk '$2 != "-"' <<< "$inw" | grep -v " $WANT5\$" | grep -q . && no "5 provd: other STATUS values inside the trial window: $(awk '$2 != "-"' <<< "$inw" | grep -v " $WANT5\$" | head -3 | tr '\n' '|')"
fi
[ "$(bootof "$peer0")" = "$(bootof "$p")" ] || warn "02 rebooted during the run (boot $(bootof "$peer0") -> $(bootof "$p")) — isolation > joinwatch's window (A-m6)"
[ "$fails" = 0 ] && RESULT=PASS || RESULT="FAIL ($fails)"
