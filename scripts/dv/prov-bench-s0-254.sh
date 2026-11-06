#!/bin/bash
# scripts/dv/prov-bench-s0-254.sh — #254 H4 §3.1: the bench base state S0-pre on ONE node, KEPT (no restore). Git Bash.
#   bash scripts/dv/prov-bench-s0-254.sh fresh <04|02>           make the node a fresh card, claim it, join N0, keep it
#   bash scripts/dv/prov-bench-s0-254.sh restore <04|02> <run>   back to the legacy state of <run>'s snapshot
#                                                                (<run> = the id printed by fresh, or keep-<id> after
#                                                                step 5; nodes.txt in the bench store has it)
# The node must be on the lab cable (a fresh slot has no mesh). User decision 2026-11-06: no card re-flash — the fresh
# card is made the way chain1-254.sh steps 1-6 and 8.2-8.4 make it (p5 snapshot -> mkfs -> V into B with a new overlay
# -> B committed unclaimed -> lab key -> claim), then the node joins the bench network N0 and STAYS there:
#   0 pre        A committed V, legacy, healthy, not dirty; payload sha AND version; lab key by publickey; bench keys H0
#   1 snap       prov-base snap (p5 image + A's overlay + p6 state) + A's p1 file list, on p6: the way back
#   2 fresh      p5 mkfs -> hold -> apply V to B (unseeded) -> reboot -> HELD unclaimed trial -> release -> B committed
#   3 claim      lab key first (publickey PROVEN), claim with the bench owner H0 (provclient over the helper socket)
#   4 join       first node: net-apply --first, N0 = mesh id bench-n0, the node's channel, bw 2, a key drawn on the node;
#                the values and the signed net_config go to the bench store as n0.pending / n0.cfg.pending.
#                second node (the store has n0): net-apply --join with that net_config and the same values (as
#                prov-netjoin-fleet-254). provclient's net_config says country "TW" (P2 does not look at it, 254-p3
#                F29): P3's country check will need N0 re-made with the P3 tools
#   5 keep       member + radio managed + wireless == N0 + p5 in sync -> the snapshot moves to dv-prov/keep-<run>, the
#                dirty flag goes, n0.pending is promoted, the new address / serial are stored (nodes.txt), known_hosts
#                gets the new host key
# Any failure from step 1 to the end of step 4 goes through restore_all (fresh-254.sh, chain1's step 9): back to the
# legacy A at the old address. After step 5: `restore <node> keep-<run>` (the same restore_all; not run by fresh).
# restore_all ends with brewrite-254.sh (B back to V), which wants a mesh neighbour: for a node whose peer has already
# left the fleet mesh that last part FAILs — the node is then on its legacy A, reachable, with the snapshot and the
# dirty flag kept (this is also where ANY abort of the second node's fresh run ends). Either run `restore` again
# once the peer is back on the fleet mesh (every step is idempotent, the B rewrite then has its neighbour), or a
# person checks the node and runs `sh /opt/batdata/dv-prov/prov-base-254.sh finish <run>` on it
# (<run> exactly as given to restore, e.g. keep-s004...; the snapshot's own mark /etc/.dv-prov-mark-<id> stays in A's
# overlay, harmless). restore needs V PAY PSHA too, and finds a kept node by nodes.txt's address (or IP=<address>).
# The bench store has ONE writer at a time: both nodes' runs take the same host lock as the prov units
# (batman-dv-04.lock), and a store that is neither complete (n0 + n0.cfg + nodes.txt) nor empty is refused, never
# repaired here. nodes.txt is the membership log: a kept node adds "node=<n> run=keep-<id> ...", a restore adds
# "node=<n> restored=<run> ..."; the LAST line of each node says whether it is on N0 now. To start N0 over (both nodes
# restored): remove n0, n0.cfg and nodes.txt from the store by hand.
# No dead-man here (chain1 has one because it must not leave 04 fresh; this run means to). A host that dies: before the
# release the held trial's own deadline returns the node to A (legacy overlay, new p5 identity: config-save freezes,
# the node is reachable at the old address) -> `restore`; after the release the node stays a fresh card, found by its
# eth MAC -> `restore`, or finish by hand.
# Dropped from chain1 on purpose (they test the product, not the bench): the addr-defer precondition, "p5 still
# unseeded after apply", prov_files / idsame, the L44 gate, the unclaimed and claimed OTAs.
# Side effects: new identity (serial, DAC), new ssh host key, new address (10.41.254.x, then openmanetd's), root
# password login off (claimed), the fleet mesh key replaced by N0's, 3-4 reboots, dockerd stopped for the first reboot,
# slot A keeps its legacy overlay until `sysupgrade -n`
# rewrites it (not done here: a member's trial needs a mesh neighbour, so A is rewritten once both nodes are on N0;
# a node that falls back to A meanwhile is locked to the lab key, at the old address, on the fleet mesh key, and
# `batman-slot rollback` brings it back to B).
# The phone AP password (C0) is NOT set here: the user keeps it and sets it (docs/validation/h4-manual-cases.md M4).
set -u
MODE=${1:-}
case "$MODE:${2:-}" in
	fresh:04|restore:04) NODE=10.41.1.3; MAC=88:a2:9e:b5:6c:89; MDNS=BCM2711-6c89.local ;;
	fresh:02|restore:02) NODE=10.41.1.1; MAC=d8:3a:dd:f8:45:d7; MDNS=BCM2711-45d7.local ;;   # eth0 address read on 02, 2026-11-06
	*) echo "usage: $0 fresh <04|02> | restore <04|02> <run>"; exit 2 ;;
esac
NN=$2; MACW=$(echo "$MAC" | tr : -)
V=${V:?version}; PAY=${PAY:?payload path on the node}; PSHA=${PSHA:?payload sha256}
OUTS=${OUTS:-//wsl.localhost/Ubuntu-24.04/home/yello/out}
REPO=${REPO:-$(cd "$(dirname "$0")/../.." && pwd)}; PB=$REPO/scripts/node/prov-base-254.sh
TOOLS=${DV_PROV_TOOLS:-/c/Users/yello/batman-dv-tools/prov}; TOOLS_WSL=/home/yello/batman-dv-tools/prov
BREWRITE=${BREWRITE:-$REPO/scripts/dv/brewrite-254.sh}; LABKEY=${LABKEY:-$HOME/.ssh/id_ed25519}; HOSTIP=${HOSTIP:-10.41.240.10}
if [ "$MODE" = restore ]; then RUN=${3:?run id}; case "$RUN" in *[!A-Za-z0-9_-]*) echo "bad run id"; exit 2;; esac; else RUN=s0$NN$(date +%m%d%H%M); fi
PCD=/tmp/run/batman-dvpc.$RUN; BASE=/opt/batdata/dv-prov; D=$BASE/$RUN; PDIR=$BASE/payload-s0; DIRTY=/opt/batdata/state/dv-prov-dirty
LOCKD=${TEMP:?TEMP unset - the host lock lives in the per-user temp dir, never in a shared tmp}/batman-dv-04.lock   # the prov units' lock (prov-254.sh), whichever node: they use both nodes
BENCH=/home/yello/.batman-dv/bench; WSLK=$BENCH/h0; N0=$BENCH/n0   # the bench store (254-h4 §3.2): WSL, 0700 / 0600
# shellcheck source=scripts/dv/fresh-254.sh
. "$(dirname "$0")/fresh-254.sh" || exit 1
# never a `$` inside a wsl_ command line: wsl.exe hands it to a login shell that expands it BEFORE the inner command runs
wsl_(){ MSYS_NO_PATHCONV=1 wsl.exe -d Ubuntu-24.04 -u yello -- "$@"; }
STAGED=0; SNAPPED=0; RESULT=FAIL; RESTORING=0; KEPT=0; PEND_MINE=0
say "RUN ID $RUN ($MODE $NN)"
mkdir "$LOCKD" 2>/dev/null || { echo "another dv run holds $LOCKD"; exit 1; }
pend_drop(){ wsl_ rm -f $N0.pending $N0.cfg.pending; }
RESTORED=0
abort(){ no "ABORT: $*"; restore_all "abort: $*" && RESTORED=1; exit 1; }   # fresh-254.sh's abort + the restore's outcome
pkp(){ pk_proof "$1" || { sleep 15; pk_proof "$1"; }; }   # one retry: a single dropped ssh must not restore a good node
on_exit(){ local rc=$?; if [ "$SNAPPED" = 1 ] && [ "$RESTORING" = 0 ] && [ "$KEPT" = 0 ]; then no "unexpected exit (rc $rc) — restoring"; restore_all "unexpected exit" && RESTORED=1; fi
	# only the pending pair THIS run wrote, and only when its node is back in the legacy state (a failed restore leaves
	# the node an N0 member: its values must not be lost)
	if [ "$PEND_MINE" = 1 ] && [ "$KEPT" = 0 ]; then [ "$RESTORED" = 1 ] && pend_drop || say "the bench store keeps $N0.pending / $N0.cfg.pending: the node was NOT restored"; fi
	rmdir "$LOCKD" 2>/dev/null; say "BENCH-S0 $MODE $NN RESULT: $RESULT (fails=$fails)"
	case "$RESULT" in PASS*) exit 0;; *) exit 1;; esac; }
trap on_exit EXIT
trap 'say "host interrupted"; [ "$SNAPPED" = 1 ] && [ "$KEPT" = 0 ] && restore_all "interrupted"; RESTORING=1; exit 1' INT TERM

# ======== restore <node> <run>: chain1's restore_all on a snapshot made by an earlier `fresh`
if [ "$MODE" = restore ]; then
	PH=restore-pre
	# a kept node's address is openmanetd's, outside the swept /24s: start from nodes.txt (or IP=)
	SEEN="${IP:-} $(wsl_ grep "^node=$NN " $BENCH/nodes.txt 2>/dev/null | tr -d '\r' | sed -n 's/.* ip=\([0-9.]*\) .*/\1/p' | tail -1)"
	wait_find 300 "ver=$V " || { say "$NN not found by its eth MAC (tried:$SEEN; give IP=<address>)"; exit 1; }
	say "$NN at $FIP ($FOUND_HOW): $FOUND_STATE"
	# nothing is written before these hold: slot A still carries V (restore_all waits for "slot=A ver=$V"), the payload
	# for the B rewrite is there
	o=$(fq "$PROT; sha256sum < $PAY | cut -c1-64"); case "$(echo $o)" in "protA=[$V] "*" $PSHA") ;; *) say "restore precondition: slot A is not $V or the payload sha differs: [$(echo $o)] — nothing written"; exit 1;; esac
	o=$(fq "[ -f $D/p5.img ] && echo p5img=y; [ -f $D/p1.list ] && echo p1list=y; echo dirty=[\$(cut -d' ' -f1 $DIRTY 2>/dev/null)]"); say "$(echo $o)"
	case "$o" in *"p5img=y"*"p1list=y"*) ;; *"p5img=y"*) say "snapshot $D has no p1 list: the run died right after its snapshot, the node was not changed — run sh $BASE/prov-base-254.sh finish $RUN on it (prov-base is scripts/node/prov-base-254.sh) and start joinwatch"; exit 1;; *) say "no snapshot $D on the node"; exit 1;; esac
	case "$o" in *"dirty=[]"*|*"dirty=[$RUN]"*|*"dirty=[${RUN#keep-}]"*) ;; *) say "the dirty flag names another run: $(echo $o) — not touching it"; exit 1;; esac
	# the legacy A answers at $NODE with its old host key; known_hosts may hold the kept slot's key for that address
	ssh-keygen -R "$NODE" >/dev/null 2>&1; SSHO="$SSHO -o StrictHostKeyChecking=accept-new"
	P1_0=$(fq "cat $D/p1.list"); [ "$(echo "$P1_0" | wc -l)" -ge 5 ] || { say "the snapshot's p1 list is unreadable"; exit 1; }
	scp -q $FRESHO "$PB" root@"$FIP":$BASE/prov-base-254.sh || { say "copy prov-base"; exit 1; }
	fq "[ -s $DIRTY ] || echo '$RUN restore' > $DIRTY; sync"   # chain1's restore expects the dirty flag of a run in progress
	SNAPPED=1; KEPT=1   # KEPT: a failure in here must not start a second restore from on_exit
	if restore_all "restore $RUN"; then [ "$fails" = 0 ] && RESULT="PASS — $NN restored to the legacy state of $RUN" || RESULT="RESTORED WITH $fails FAIL"
		# the node is off N0 (also when only the B rewrite failed): the membership log says so
		[ -n "$(wsl_ ls -1 $BENCH/nodes.txt 2>/dev/null)" ] && printf 'node=%s restored=%s date=%s\n' "$NN" "$RUN" "$(date +%F)" | wsl_ bash -c "umask 077; cat >> $BENCH/nodes.txt"
	else RESULT="RESTORE FAILED — needs a person"; fi
	exit 1   # on_exit sets the real code from RESULT
fi
# pcn <key> [FD3=<producer run ON the node>] -- <provclient node args>: as prov-254.sh pr_pc, at $FIP
pcn(){
	local key=$1 fd3="" f W line sig out="" cmd; shift
	while [ "$1" != -- ]; do case "$1" in FD3=*) fd3=${1#FD3=} ;; esac; shift; done; shift
	f=$(mktemp -d)/p; mkfifo "$f"
	coproc SIGNP { wsl_ "$TOOLS_WSL/provclient-amd64" sign "$WSLK/$key"; }
	exec {W}<>"$f"
	cmd="PROVCLIENT_TIMEOUT_S=600 $PCD/provclient node $*"
	[ -n "$fd3" ] && cmd="exec 4<&0; { $fd3; } | PROVCLIENT_TIMEOUT_S=600 $PCD/provclient node $* 3<&0 0<&4"
	while IFS= read -r line; do
		line=$(printf '%s' "$line" | tr -d '\r')
		case "$line" in
			SIGN\ *) echo "$line" >&"${SIGNP[1]}"; IFS= read -r -t 30 sig <&"${SIGNP[0]}" || sig=ERR; printf '%s\n' "$sig" | tr -d '\r' >&"$W" ;;
			*) out="$out$line
" ;;
		esac
	done < <(ssh $FRESHO root@"$FIP" "$cmd" < "$f" 2>&1)
	exec {W}>&-; kill "${SIGNP_PID:-}" 2>/dev/null; rm -rf "${f%/p}"
	printf '%s' "$out"
}
info(){ pcn owner.pem -- info | sed -n 's/^RESULT info.state code=0 state=\([a-z]*\) gen=\([0-9]*\) owners=\([0-9]*\) rm=\([a-z0-9]*\).*/state=\1 gen=\2 owners=\3 rm=\4/p'; }
pc_place(){ scp -q $FRESHO "$TOOLS/provclient-arm64" root@"$FIP":$PCD/provclient && fq "chmod 0755 $PCD/provclient" >/dev/null; }

# ======== 0. pre
s=$(q "$ST"); say "start: $s"
case "$s" in "mac=$MAC slot=A ver=$V trial_rc=1 dt_try="*" hold=[] held=0 badslot=[]"*) ;; *) say "precondition ($NN by MAC, A committed $V, no hold, no bad-slot)"; exit 1;; esac
a=$(q "awk -v b=\$(cat /proc/sys/kernel/random/boot_id) '\$1==b {print \"ps=\" \$2 \"/\" \$4}' /opt/batdata/state/prov-state; batman-config-save --check >/dev/null 2>&1; echo check_rc=\$?; echo dirty=[\$(cat $DIRTY 2>/dev/null)] undo=\$(ls /opt/batdata/state/dv-undo 2>/dev/null | wc -l)")
say "A: $(echo $a)"; case "$(echo $a)" in *"ps=helper/legacy"*"check_rc=0"*"dirty=[] undo=0"*) ;; *) say "A is not a healthy legacy node, or a dirty flag / undo journal is present"; exit 1;; esac
[ "$(q "sha256sum < $PAY | cut -c1-64")" = "$PSHA" ] || { say "payload sha"; exit 1; }
# payload version == V, from the build dir's SHA256SUMS (as chain1: a version mismatch discards the hold, and the fresh
# slot would commit a version nothing here looks for)
VPAY=""; for sums in "$OUTS"/*/ekh-bcm2711/SHA256SUMS; do grep -q "^$PSHA  .*-ab-payload\.tar\.gz$" "$sums" 2>/dev/null || continue
	d=${sums%/SHA256SUMS}; bs=$(sha256sum < "$d/batman-build.txt" | cut -c1-64); grep -q "^$bs  batman-build\.txt$" "$sums" || { say "batman-build.txt in $d does not match its SHA256SUMS"; exit 1; }
	VPAY=$(sed -n 's/^BATMAN_VERSION=//p' "$d/batman-build.txt" | tr -d '\r'); break; done
[ "$VPAY" = "$V" ] || { say "payload BATMAN_VERSION [$VPAY] != V [$V]"; exit 1; }; say "payload version $VPAY (build dir evidence)"
[ -s "$LABKEY.pub" ] || { say "no $LABKEY.pub"; exit 1; }
[ "$(q 'cat /sys/class/net/eth0/carrier 2>/dev/null')" = 1 ] || { say "$NN has no carrier on eth0: the lab cable must be on THIS node (a fresh slot has no mesh)"; exit 1; }
pk_proof $NODE || { say "lab key $LABKEY does not authenticate to A by publickey"; exit 1; }
[ -f "$TOOLS/provclient-arm64" ] && wsl_ test -x "$TOOLS_WSL/provclient-amd64" || { say "no provclient in $TOOLS"; exit 1; }   # -f: an arm64 binary for the node, never executed on the host
# bench keys H0: made once, kept (0700 dir / 0600 files); both nodes get the same owner
wsl_ bash -c "umask 077; mkdir -p $BENCH && chmod 700 $BENCH && { [ -s $WSLK/enc.pub ] || { rm -rf $WSLK.new && mkdir $WSLK.new && $TOOLS_WSL/provclient-amd64 keygen $WSLK.new/owner.pem > $WSLK.new/owner.pub && $TOOLS_WSL/provclient-amd64 keygen $WSLK.new/enc.pem > $WSLK.new/enc.pub && mv $WSLK.new $WSLK; }; }"
OWNER=$(wsl_ cat $WSLK/owner.pub | tr -d '\r'); ENC=$(wsl_ cat $WSLK/enc.pub | tr -d '\r')
[ ${#OWNER} = 130 ] && [ ${#ENC} = 130 ] || { say "bench owner keys (H0) unreadable in $WSLK"; exit 1; }
[ "$(wsl_ stat -c %a $BENCH $WSLK/owner.pem | tr -d '\r' | tr '\n' ' ')" = "700 600 " ] || { say "bench store modes are not 700 / 600"; exit 1; }
# N0 in the store: complete (n0 + n0.cfg) = this is the second node; nothing at all = the first; anything else
# (a pending file, half a pair, an unreadable store) is refused — a guess here makes two networks with one name
lsb=$(wsl_ ls -1 $BENCH | tr -d '\r'); grep -qx h0 <<< "$lsb" || { say "bench store unreadable (no h0 in its listing)"; exit 1; }
st=$(for f in n0 n0.cfg n0.pending n0.cfg.pending nodes.txt; do grep -qx "$f" <<< "$lsb" && printf '%s ' "$f"; done)
case "$st" in
	"n0 n0.cfg nodes.txt ") HAVEN0=y; [ "$(wsl_ grep -c '^sae=' $N0 | tr -d '\r')" = 1 ] && [ -n "$(wsl_ cat $N0.cfg | tr -d '\r\n')" ] || { say "bench store: n0 / n0.cfg are not complete"; exit 1; } ;;
	"") HAVEN0=n ;;
	*) say "bench store $BENCH holds [$st]: neither a complete N0 (n0 n0.cfg nodes.txt) nor empty. A pending pair belongs to a run that kept its node but did not promote it (mv n0.pending n0; mv n0.cfg.pending n0.cfg) or to one that died (remove it once the node is restored). Nothing done."; exit 1 ;;
esac
# is the OTHER node on N0 now? (the last nodes.txt line of each node: run=keep-... = on N0, restored=... = left)
PEERON=n; [ "$HAVEN0" = y ] && wsl_ cat $BENCH/nodes.txt | tr -d '\r' | awk -v me="node=$NN" '$1 != me { last[$1] = $2 } END { for (n in last) if (last[n] ~ /^run=keep-/) f = 1; exit !f }' && PEERON=y
say "bench store: H0 ${OWNER:0:10}… N0 present=$HAVEN0 peer on N0=$PEERON"
P1_0=$(q "$P1LIST"); [ "$(echo "$P1_0" | wc -l)" -ge 5 ] || { say "cannot hash p1"; exit 1; }
# the channel N0 uses: the first node's own; the second node takes the stored one
if [ "$HAVEN0" = y ]; then CHN=$(wsl_ sed -n 's/^channel=//p' $N0 | tr -d '\r'); else CHN=$(q 'uci -q get wireless.radio1.channel'); fi
case "$CHN" in ''|*[!0-9]*) say "N0 channel unreadable [$CHN]"; exit 1;; esac
o=$(q "mkdir -p -m 700 $PDIR && cd $PDIR && rm -rf ./* && tar -xzf $PAY && echo extracted; df -m /opt/batdata | awk 'NR==2 {print \"p6_free_mb=\" \$4}'"); say "$(echo $o)"
case "$(echo $o)" in "extracted p6_free_mb="[0-9]*) ;; *) say "payload not extracted to $PDIR"; exit 1;; esac
[ "$(echo "$o" | sed -n 's/^p6_free_mb=//p')" -ge 2048 ] || { say "p6 has less than 2 GB free for the snapshot"; exit 1; }
# ======== 1. snapshot (mesh markers into it: a fresh card has none)
PH=s1
o=$(timeout 900 ssh $SSHO root@$NODE "KEEP_JOINWATCH_STOPPED=1 sh -s -- snap $RUN" < "$PB" 2>&1 | tr -d '\r'); say "$(echo "$o" | tail -1)"
if ! grep -q "^SNAP $RUN" <<< "$o"; then
	# the ssh may have dropped after the snapshot was made: say what is there, start joinwatch again, do not guess
	say "snap failed: on the node now: $(q "ls -d $D 2>/dev/null; echo dirty=[\$(cat $DIRTY 2>/dev/null)]; /etc/init.d/joinwatch start >/dev/null 2>&1" | tr '\n' ' ')"
	say "if a snapshot is listed: sh $BASE/prov-base-254.sh finish $RUN on the node (prov-base is in scripts/node/), then run again"; exit 1
fi
SNAPPED=1; FIP=$NODE; FOUND_STATE=$s; say "RUN ID $RUN (restore $NN $RUN brings this node back)"
scp -q $SSHO "$PB" root@$NODE:$BASE/prov-base-254.sh || abort "copy prov-base"
printf '%s\n' "$P1_0" | ssh $SSHO root@$NODE "umask 077; cat > $D/p1.list" || abort "p1 list into the snapshot"
q "mkdir -p $D/marks; for m in mesh-joined mesh-expected; do [ -e /opt/batdata/state/\$m ] && mv /opt/batdata/state/\$m $D/marks/; done; echo marks=[\$(ls $D/marks | tr '\n' ' ')] p1_lines=\$(wc -l < $D/p1.list) snapshot p5 sha \$(cut -c1-16 $D/p5.img.sha)" | sed 's/^/    /'
# ======== 2. p5 idle -> mkfs -> hold + apply (unseeded) -> reboot -> HELD unclaimed trial -> release
PH=s2
o=$(q "grep -c '^/dev/mmcblk0p5 ' /proc/mounts; ps w | grep -c '[b]atman-config-save'"); [ "$(echo $o)" = "0 0" ] && ok "p5 idle" || abort "p5 busy: $(echo $o)"
o=$(q "mkfs.ext4 -F -q -L batconfig /dev/mmcblk0p5 && echo MKFS-OK; $P5RO"); say "p5 after mkfs: $(echo $o)"
case "$o" in *MKFS-OK*"seeded=n"*) ok "p5 empty, not seeded";; *) abort "mkfs";; esac
q "echo '$V' > /opt/batdata/state/autocommit-hold-commit; sync"
o=$(timeout 900 ssh $SSHO root@$NODE "BATMAN_ALLOW_UNSEEDED=1 BATMAN_ALLOW_STALE_P5=1 batman-slot apply $PDIR 2>&1 | tail -3" 2>/dev/null | tr -d '\r'); say "apply: $(echo $o)"
grep -q "armed as one-shot tryboot" <<< "$o" || { q "$DISARM" >/dev/null; abort "apply did not arm"; }
B0=$(q 'cut -c1-8 /proc/sys/kernel/random/boot_id')
q '(/etc/init.d/dockerd stop >/dev/null 2>&1; sync; sleep 1; reboot -f) </dev/null >/dev/null 2>&1 &'; t0=$SECONDS
FIP=""; while [ $((SECONDS - t0)) -lt 150 ] && [ -z "$FIP" ]; do sleep 10; find04 "slot=B ver=$V trial_rc=0 dt_try=00000001 " "$B0" || FIP=""; done
[ -n "$FIP" ] || abort "held fresh trial not found in 150 s"
say "held trial at $FIP ($FOUND_HOW) after $((SECONDS - t0)) s: $FOUND_STATE"; BT=$(bootof "$FOUND_STATE")
dec=""; ev=""; while [ $((SECONDS - t0)) -lt 180 ]; do ev=$(fq "logread | grep -E 'batman-autocommit|batman-provhelper'"); grep -q "mesh join required: 0 (prov=unclaimed" <<< "$ev" && grep -q "HELD" <<< "$ev" && { dec=ok; break; }; grep -q HOLD-COMMIT-DISCARDED <<< "$ev" && break; sleep 5; done
[ "$dec" = ok ] && ok "autocommit: mesh join required: 0 (prov=unclaimed + HELD" || abort "no unclaimed + HELD decision"
x=$(fq "echo meta=\$(sed -n 's/.*state=\([a-z]*\).*/\1/p' /etc/batman-prov/prov.meta) ap=\$(iw dev 2>/dev/null | grep -c 'type AP') mesh=\$(iw dev 2>/dev/null | grep -c 'type mesh point'); $P5RO")
say "trial: $(echo $x)"
for w in "meta=unclaimed" "ap=0" "mesh=0" "seeded=n" "metastat=[ok unclaimed]" "ident=ok"; do case "$x" in *"$w"*) ok "trial: $w";; *) abort "trial: want $w";; esac; done
r=$(fq 'batman-autocommit release --wait 2>&1 | tail -1'); say "release: $r"
s=$(fq "$ST"); case "$s" in *"slot=B "*"trial_rc=1 "*) ok "B committed (unclaimed)";; *) abort "B not committed after release: $s";; esac
# the reservation reboot follows on the committed slot (chain1 s6r)
t=$SECONDS; while [ $((SECONDS - t)) -lt 400 ]; do b=$(fq 'cut -c1-8 /proc/sys/kernel/random/boot_id'); [ "$b" = "$BT" ] || break; sleep 10; done
wait_find 600 "slot=B ver=$V trial_rc=1 " "$BT" || abort "B not found after the reservation reboot"
say "B committed at $FIP ($FOUND_HOW): $FOUND_STATE"
t=$SECONDS; d=""; while [ $((SECONDS - t)) -lt 300 ]; do d=$(fq 'echo "$(uci -q get openmanetd.config.dhcpconfigured) $(cut -d. -f1 /proc/uptime)"'); [ "${d%% *}" = 1 ] && [ "${d##* }" -ge 150 ] && break; sleep 10; done
[ "${d%% *}" = 1 ] && [ "${d##* }" -ge 150 ] && ok "B stable: dhcpconfigured=1, uptime ${d##* } s" || abort "B not stable after the reservation reboot: dhcpconfigured/uptime=[$d]"
# ======== 3. lab key (publickey proven BEFORE the claim), claim with H0
PH=s3
pub=$(cat "$LABKEY.pub"); fq "mkdir -p -m 0700 /etc/dropbear; grep -qxF '$pub' /etc/dropbear/authorized_keys 2>/dev/null || echo '$pub' >> /etc/dropbear/authorized_keys; chmod 0600 /etc/dropbear/authorized_keys; chown root:root /etc/dropbear/authorized_keys" >/dev/null
pk_proof "$FIP" && ok "lab key: publickey PROVEN" || abort "publickey does not authenticate — not claiming"
fq "mkdir -m 0711 $PCD && echo MADE" | grep -q MADE || abort "dvpc dir pre-exists: $PCD (refusing a planted provclient dir)"
pc_place || abort "provclient upload"
r=$(pcn owner.pem -- claim "$OWNER" "$ENC"); echo "$r" | sed 's/^/    /'
grep -q "RESULT claim.verify code=0 " <<< "$r" && ok "claim.verify code 0" || abort "claim failed"
x=$(fq "echo state=\$(sed -n 's/.*state=\([a-z]*\).*/\1/p' /etc/batman-prov/prov.meta) lock=\$(cat /opt/batdata/state/lock-status); $P5RO")
say "after claim: $(echo $x)"
for w in "state=claimed" "lock=LOCKED" "seeded=y" "metastat=[ok claimed]"; do case "$x" in *"$w"*) ok "claim: $w";; *) abort "claim: want $w";; esac; done
pkp "$FIP" && ok "publickey PROVEN after the claim" || abort "lost publickey login after the claim"
none_refused "$FIP" && ok "'none' refused after the claim" || abort "'none' still accepted on a LOCKED node"
# ======== 4. join N0 (the key never appears in argv or a log: drawn on the node / piped as a file)
PH=s4
if [ "$HAVEN0" = y ]; then
	wsl_ cat $N0 | ssh $FRESHO root@"$FIP" "umask 077; cat > $PCD/n0" || abort "N0 values to the node"
	NETCFG=$(wsl_ cat $N0.cfg | tr -d '\r\n'); case "$NETCFG" in ''|*[!0-9a-f]*) abort "the bench store has no net_config ($N0.cfg)";; esac
else
	fq "umask 077; s=\$(head -c 16 /dev/urandom | hexdump -v -e '1/1 \"%02x\"'); printf 'mesh_id=bench-n0\nchannel=%s\nbw=2\nsae=%s\n' '$CHN' \"\$s\" > $PCD/n0" || abort "N0 values not made"
	# to the store BEFORE the join (the node may reboot after it and $PCD is tmpfs); promoted in step 5 only
	PEND_MINE=1
	ssh $FRESHO root@"$FIP" "cat $PCD/n0" 2>/dev/null | wsl_ bash -c "umask 077; cat > $N0.pending" || abort "N0 values to the bench store"
	[ "$(wsl_ grep -c '^sae=' $N0.pending | tr -d '\r')" = 1 ] && [ "$(wsl_ stat -c %a $N0.pending | tr -d '\r')" = 600 ] || abort "N0 values in the bench store (pending) are not complete / not 0600"
fi
[ "$(fq "grep -c '^sae=' $PCD/n0")" = 1 ] || abort "N0 values are not on the node"
BJ=$(fq 'cut -c1-8 /proc/sys/kernel/random/boot_id')
if [ "$HAVEN0" = y ]; then	# the second node JOINS the first one's network: its signed net_config verbatim, its own net_secrets
	r=$(pcn owner.pem FD3="cat $PCD/n0" -- net-apply --join "$OWNER" "$NETCFG"); echo "$r" | grep RESULT | sed 's/^/    /'
	grep -q "RESULT net.apply(join) code=0 " <<< "$r" || abort "net-apply --join: $(echo "$r" | grep RESULT | tail -1)"
	ok "net-apply --join code 0 (N0 of the first node)"
else
	r=$(pcn owner.pem FD3="cat $PCD/n0" -- net-apply --first "$OWNER"); echo "$r" | grep RESULT | sed 's/^/    /'
	grep -q "RESULT net.apply code=0 " <<< "$r" || abort "net-apply --first: $(echo "$r" | grep RESULT | tail -1)"
	ok "net-apply --first code 0"
	NETCFG=$(sed -n 's/^NETCFG //p' <<< "$r"); case "$NETCFG" in ''|*[!0-9a-f]*) abort "no net_config in the reply";; esac
	printf '%s\n' "$NETCFG" | wsl_ bash -c "umask 077; cat > $N0.cfg.pending" || abort "net_config to the bench store"   # signed config, no keys
fi
# a reboot may follow the join (254-h4 F-H42 says openmanetd reboots a fresh card after it reserves an address; that
# one already happened in step 2): watch the boot for 240 s; if it changes, find the node again and let it settle
t=$SECONDS; nb=$BJ; while [ $((SECONDS - t)) -lt 240 ]; do nb=$(fq 'cut -c1-8 /proc/sys/kernel/random/boot_id'); [ -n "$nb" ] && [ "$nb" != "$BJ" ] && break; nb=$BJ; sleep 15; done
if [ "$nb" != "$BJ" ] || ! is_on "$FIP" "slot=B ver=$V trial_rc=1 " >/dev/null; then
	say "the node rebooted (or moved) after the join: finding it again"
	if [ "$nb" != "$BJ" ]; then wait_find 900 "slot=B ver=$V trial_rc=1 " "$BJ"; else wait_find 900 "slot=B ver=$V trial_rc=1 "; fi || abort "node not found after the join"
	t=$SECONDS; while [ $((SECONDS - t)) -lt 400 ]; do u=$(fq 'cut -d. -f1 /proc/uptime'); [ "${u:-0}" -ge 150 ] && break; sleep 15; done
	[ "${u:-0}" -ge 150 ] || abort "node not stable after the post-join reboot"
	fq "mkdir -m 0711 $PCD && echo MADE" | grep -q MADE || abort "dvpc dir pre-exists after the reboot: $PCD"   # tmpfs: gone with the reboot
	pc_place || abort "provclient upload (after the join)"
else say "no reboot in 240 s after the join (boot $BJ)"; fi
say "after the join at $FIP: $(fq "$ST")"
# the wireless transaction file is the dot file /etc/batman-prov/.txn (provstore.go); an empty answer is not "gone"
t=$SECONDS; x=""; while [ $((SECONDS - t)) -lt 180 ]; do x=$(fq '{ [ -e /etc/batman-prov/.txn ] || [ -L /etc/batman-prov/.txn ]; } && echo present || echo gone'); [ "$x" = gone ] && break; sleep 10; done
[ "$x" = gone ] && ok "no .txn left" || abort "the .txn is still there 180 s after the join [$x]"
i=""; for k in 1 2 3; do i=$(info); [ -n "$i" ] && break; sleep 15; done; say "info: $i"
case "$i" in "state=member "*"rm=true"*|"state=member "*"rm=1"*) ok "member, radio managed";; *) abort "not a managed member: [$i]";; esac
# up to 3 reads 15 s apart: --check answers 8 while config-save holds its lock, and a single sample must not restore a good node
WQ="echo mesh_id=\$(uci -q get wireless.default_radio1.mesh_id) enc=\$(uci -q get wireless.default_radio1.encryption) ch=\$(uci -q get wireless.radio1.channel) keysha=\$(uci -q get wireless.default_radio1.key | tr -d '\r\n' | sha256sum | cut -c1-16); batman-config-save --check >/dev/null 2>&1; echo check_rc=\$?"
# the key the store holds (pending for the first node), compared by sha: it passes through a pipe only
if [ "$HAVEN0" = y ]; then KS=$(wsl_ sed -n 's/^sae=//p' $N0 | tr -d '\r\n' | sha256sum | cut -c1-16); else KS=$(wsl_ sed -n 's/^sae=//p' $N0.pending | tr -d '\r\n' | sha256sum | cut -c1-16); fi
[ "$KS" != "$(printf '' | sha256sum | cut -c1-16)" ] || abort "the bench store's N0 key is unreadable"
for k in 1 2 3; do x=$(fq "$WQ"); case "$(echo $x) " in *"mesh_id=bench-n0 enc=sae ch=$CHN keysha=$KS check_rc=0 "*) break;; esac; [ "$k" = 3 ] || sleep 15; done
say "wireless: $(echo $x)"
for w in "mesh_id=bench-n0 " "enc=sae " "ch=$CHN " "keysha=$KS " "check_rc=0 "; do case "$(echo $x) " in *"$w"*) ok "join: $w";; *) abort "join: want $w";; esac; done
if [ "$PEERON" = y ]; then
	# the other node is on N0: this one must be IN the mesh with it, by the product's own definition (meshjoin.sh:
	# an ESTAB plink and a batman-adv neighbour, both on wlh0 — a neighbour over another hardif does not count).
	# Not restored when missing: this node's membership is proven above, the other node may be the one at fault.
	t=$SECONDS; mj=""; while [ $((SECONDS - t)) -lt 300 ]; do mj=$(fq '. /usr/lib/batman/meshjoin.sh; meshjoin_sample; echo "plink=$MJ_PLINK bat=$MJ_BAT"; meshjoin_joined && echo joined=y'); case "$mj" in *"joined=y"*) break;; esac; sleep 15; done
	case "$mj" in *"joined=y"*) ok "mesh: joined with the other node on N0 ($(echo $mj); $(fq 'batctl n 2>/dev/null | grep wlh0 | head -2' | tr -s ' ' | tr '\n' '|'))";; *) no "mesh: not joined after 300 s [$(echo $mj)] — the two nodes are NOT one mesh (kept as it is; check the other node)";; esac
else say "mesh: no other node is on N0 now (bench store) — this node is its only member, no neighbour expected"; fi
pkp "$FIP" && ok "publickey PROVEN after the join" || abort "lost publickey login after the join"
# ======== 5. keep: once the snapshot has moved nothing restores
PH=s5
KEEPC="[ -d $BASE/keep-$RUN ] || mv $D $BASE/keep-$RUN; [ -d $BASE/keep-$RUN ] && [ ! -e $D ] && rm -f $DIRTY; sync"   # the same in every try
o=$(fq "[ \"\$(cat /sys/class/net/eth0/address)\" = $MAC ] || exit 1; rm -rf $PCD $PDIR; $KEEPC; echo kept=\$(ls -d $BASE/keep-$RUN 2>/dev/null) run=\$(ls -d $D 2>/dev/null) dirty=[\$(cat $DIRTY 2>/dev/null)] sn=\$(tr -d '\n' < /etc/batman-prov/identity/sn) docker=\$(docker ps -q 2>/dev/null | wc -l)")
say "$o"
# the answer may be lost with the ssh although the move happened: read the node again before deciding
for k in 1 2 3; do case "$o" in "kept=$BASE/keep-$RUN run= dirty=[] sn="[0-9a-f]*) break;; esac; sleep 20; find04 "slot=B ver=$V trial_rc=1 " >/dev/null || true
	o=$(fq "[ \"\$(cat /sys/class/net/eth0/address)\" = $MAC ] || exit 1; $KEEPC; echo kept=\$(ls -d $BASE/keep-$RUN 2>/dev/null) run=\$(ls -d $D 2>/dev/null) dirty=[\$(cat $DIRTY 2>/dev/null)] sn=\$(tr -d '\n' < /etc/batman-prov/identity/sn) docker=\$(docker ps -q 2>/dev/null | wc -l)"); say "again: $o"; done
case "$o" in "kept=$BASE/keep-$RUN run= dirty=[] sn="[0-9a-f]*) KEPT=1; ok "legacy snapshot kept on p6 as keep-$RUN, dirty flag gone";;
	"kept= run=$D "*) abort "keep step did not happen: [$o]";;
	*) KEPT=1; no "keep step: the node's answer is unclear [$o] — NOT restoring; look at $BASE on the node";; esac
SN=$(echo "$o" | sed -n 's/.* sn=\([^ ]*\) .*/\1/p')
if [ "$HAVEN0" = n ]; then wsl_ mv $N0.pending $N0 && wsl_ mv $N0.cfg.pending $N0.cfg && [ "$(wsl_ stat -c %a $N0 | tr -d '\r')" = 600 ] && ok "N0 kept in the bench store (0600)" || no "N0 not promoted in the bench store: $N0.pending / $N0.cfg.pending hold it"; fi
ssh-keygen -R "$FIP" >/dev/null 2>&1; hk=$(timeout 30 ssh -o BatchMode=yes -o ConnectTimeout=6 -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes -i "$LABKEY" root@"$FIP" 'cat /sys/class/net/eth0/address' 2>/dev/null | tr -d '\r')
[ "$hk" = "$MAC" ] && ok "known_hosts: $FIP re-pinned (the node there has eth MAC $MAC)" || no "known_hosts: could not re-pin $FIP [$hk]"
printf 'node=%s run=keep-%s date=%s ip=%s mac=%s sn=%s version=%s\n' "$NN" "$RUN" "$(date +%F)" "$FIP" "$MAC" "$SN" "$V" | wsl_ bash -c "umask 077; cat >> $BENCH/nodes.txt"
[ "$(wsl_ grep -c "run=keep-$RUN " $BENCH/nodes.txt | tr -d '\r')" = 1 ] && ok "nodes.txt has this run" || no "nodes.txt was not written"
say "$NN is a claimed member of N0 at $FIP (was $NODE); $(fq "$ST")"
[ "$fails" = 0 ] && RESULT="PASS — $NN at $FIP sn $SN, way back: restore $NN keep-$RUN" || RESULT="KEPT WITH $fails FAIL (way back: restore $NN keep-$RUN)"
