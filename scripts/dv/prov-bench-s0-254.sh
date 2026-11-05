#!/bin/bash
# scripts/dv/prov-bench-s0-254.sh — #254 H4 §3.1: the bench base state S0-pre on ONE node, KEPT (no restore). Git Bash.
#   bash scripts/dv/prov-bench-s0-254.sh fresh <04|02>
# The node must be on the lab cable (a fresh slot has no mesh). User decision 2026-11-06: no card re-flash — the fresh
# card is made the way chain1-254.sh steps 1-6 and 8.2-8.4 make it (p5 snapshot -> mkfs -> V into B with a new overlay
# -> B committed unclaimed -> lab key -> claim), then the node joins the bench network N0 and STAYS there:
#   0 pre        A committed V, legacy, healthy, not dirty; payload sha; lab key by publickey; bench keys H0
#   1 snap       prov-base snap (p5 image + A's overlay + p6 state) on p6: the only way back to the legacy state
#   2 fresh      p5 mkfs -> hold -> apply V to B (unseeded) -> reboot -> HELD unclaimed trial -> release -> B committed
#   3 claim      lab key first (publickey PROVEN), claim with the bench owner H0 (provclient over the helper socket)
#   4 join       first node: net-apply --first, N0 = mesh id bench-n0, the node's channel, bw 2, a key drawn on the node
#                and kept in the bench store (~/.batman-dv/bench/n0, WSL, 0600) with the signed net_config (n0.cfg);
#                second node: net-apply --join with that net_config and the same values (as prov-netjoin-fleet-254).
#                provclient's net_config says country "TW" (P2 does not look at it, 254-p3 F29): P3's country check
#                will need N0 re-made with the P3 tools
#   5 keep       member + radio managed + wireless == N0 + p5 in sync -> the snapshot moves to dv-prov/keep-<run>, the
#                dirty flag goes, the new address / serial are printed and stored, known_hosts gets the new host key
# Any failure from step 1 to the end of step 4 goes through restore_all (fresh-254.sh, chain1's step 9): back to the
# legacy A at the old address. After step 5 the way back is by hand: move keep-<run> back, then chain1's restore.
# No dead-man here (chain1 has one because it must not leave 04 fresh; this run means to): a host that dies mid-run
# leaves the node where it is, found by its eth MAC, and the snapshot on p6.
# Side effects: new identity (serial, DAC), new ssh host key, new address (10.41.254.x, then openmanetd's), root
# password login off (claimed), the fleet mesh key replaced by N0's, 3-4 reboots, dockerd stopped for the first reboot,
# slot A keeps its legacy overlay until `sysupgrade -n` rewrites it (not done here: a claimed member's trial needs a
# mesh neighbour, so A is rewritten once both nodes are on N0).
# The phone AP password (C0) is NOT set here: the user keeps it and sets it (docs/validation/h4-manual-cases.md M4).
set -u
[ "${1:-}" = fresh ] || { echo "usage: $0 fresh <04|02>"; exit 2; }
case "${2:-}" in
	04) NODE=10.41.1.3; MAC=88:a2:9e:b5:6c:89; MDNS=BCM2711-6c89.local ;;
	02) NODE=10.41.1.1; MAC=d8:3a:dd:f8:45:d7; MDNS=BCM2711-45d7.local ;;
	*) echo "usage: $0 fresh <04|02>"; exit 2 ;;
esac
NN=$2; MACW=$(echo "$MAC" | tr : -)
V=${V:?version}; PAY=${PAY:?payload path on the node}; PSHA=${PSHA:?payload sha256}
REPO=${REPO:-$(cd "$(dirname "$0")/../.." && pwd)}; PB=$REPO/scripts/node/prov-base-254.sh
TOOLS=${DV_PROV_TOOLS:-/c/Users/yello/batman-dv-tools/prov}; TOOLS_WSL=/home/yello/batman-dv-tools/prov
BREWRITE=${BREWRITE:-$REPO/scripts/dv/brewrite-254.sh}; LABKEY=${LABKEY:-$HOME/.ssh/id_ed25519}; HOSTIP=${HOSTIP:-10.41.240.10}
RUN=s0$NN$(date +%m%d%H%M); PCD=/tmp/run/batman-dvpc.$RUN; BASE=/opt/batdata/dv-prov; D=$BASE/$RUN; PDIR=$BASE/payload-s0; DIRTY=/opt/batdata/state/dv-prov-dirty
LOCKD=${TEMP:?TEMP unset - the host lock lives in the per-user temp dir, never in a shared tmp}/batman-dv-$NN.lock
BENCH=/home/yello/.batman-dv/bench; WSLK=$BENCH/h0; N0=$BENCH/n0   # the bench store (254-h4 §3.2): WSL, 0700 / 0600
# shellcheck source=scripts/dv/fresh-254.sh
. "$(dirname "$0")/fresh-254.sh"
wsl_(){ MSYS_NO_PATHCONV=1 wsl.exe -d Ubuntu-24.04 -u yello -- "$@"; }
STAGED=0; SNAPPED=0; RESULT=FAIL; RESTORING=0; KEPT=0
mkdir "$LOCKD" 2>/dev/null || { echo "another dv run holds $LOCKD"; exit 1; }
on_exit(){ local rc=$?; if [ "$SNAPPED" = 1 ] && [ "$RESTORING" = 0 ] && [ "$KEPT" = 0 ]; then no "unexpected exit (rc $rc) — restoring"; restore_all "unexpected exit"; fi
	rmdir "$LOCKD" 2>/dev/null; say "BENCH-S0 $NN RESULT: $RESULT (fails=$fails)"; }
trap on_exit EXIT
trap 'say "host interrupted"; [ "$SNAPPED" = 1 ] && [ "$KEPT" = 0 ] && restore_all "interrupted"; RESTORING=1; exit 1' INT TERM
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

# ======== 0. pre
s=$(q "$ST"); say "start: $s"
case "$s" in "mac=$MAC slot=A ver=$V trial_rc=1 dt_try="*" hold=[] held=0 badslot=[]"*) ;; *) say "precondition ($NN by MAC, A committed $V, no hold, no bad-slot)"; exit 1;; esac
a=$(q "awk -v b=\$(cat /proc/sys/kernel/random/boot_id) '\$1==b {print \"ps=\" \$2 \"/\" \$4}' /opt/batdata/state/prov-state; batman-config-save --check >/dev/null 2>&1; echo check_rc=\$?; echo dirty=[\$(cat $DIRTY 2>/dev/null)] undo=\$(ls /opt/batdata/state/dv-undo 2>/dev/null | wc -l)")
say "A: $(echo $a)"; case "$a" in *"ps=helper/legacy"*"check_rc=0"*"dirty=[] undo=0"*) ;; *) say "A is not a healthy legacy node, or a dirty flag / undo journal is present"; exit 1;; esac
[ "$(q "sha256sum < $PAY | cut -c1-64")" = "$PSHA" ] || { say "payload sha"; exit 1; }
pk_proof $NODE || { say "lab key $LABKEY does not authenticate to A by publickey"; exit 1; }
[ -f "$TOOLS/provclient-arm64" ] && wsl_ test -x "$TOOLS_WSL/provclient-amd64" || { say "no provclient in $TOOLS"; exit 1; }   # -f: an arm64 binary for the node, never executed on the host
# bench keys H0: made once, kept (0700 dir / 0600 files); both nodes get the same owner
wsl_ bash -c "umask 077; mkdir -p $BENCH && chmod 700 $BENCH && { [ -s $WSLK/owner.pem ] || { mkdir $WSLK && $TOOLS_WSL/provclient-amd64 keygen $WSLK/owner.pem > $WSLK/owner.pub && $TOOLS_WSL/provclient-amd64 keygen $WSLK/enc.pem > $WSLK/enc.pub; }; }"
OWNER=$(wsl_ cat $WSLK/owner.pub | tr -d '\r'); ENC=$(wsl_ cat $WSLK/enc.pub | tr -d '\r')
[ ${#OWNER} = 130 ] && [ ${#ENC} = 130 ] || { say "bench owner keys (H0) unreadable in $WSLK"; exit 1; }
[ "$(wsl_ stat -c '%a %a' $BENCH $WSLK/owner.pem | tr -d '\r' | tr '\n' ' ')" = "700 600 " ] || { say "bench store modes are not 700 / 600"; exit 1; }
HAVEN0=$(wsl_ bash -c "[ -s $N0 ] && echo y || echo n" | tr -d '\r'); say "bench store: H0 ${OWNER:0:10}… N0 present=$HAVEN0"
P1_0=$(q "$P1LIST"); [ "$(echo "$P1_0" | wc -l)" -ge 5 ] || { say "cannot hash p1"; exit 1; }
CH0=$(q 'uci -q get wireless.radio1.channel'); case "$CH0" in ''|*[!0-9]*) say "radio1 channel unreadable [$CH0]"; exit 1;; esac
q "mkdir -p -m 700 $PDIR && cd $PDIR && rm -rf ./* && tar -xzf $PAY && echo extracted" | sed 's/^/    /'
# ======== 1. snapshot (mesh markers into it: a fresh card has none)
PH=s1
o=$(timeout 900 ssh $SSHO root@$NODE "KEEP_JOINWATCH_STOPPED=1 sh -s -- snap $RUN" < "$PB" 2>&1 | tr -d '\r'); say "$(echo "$o" | tail -1)"
grep -q "^SNAP $RUN" <<< "$o" || { say "snap failed"; exit 1; }
SNAPPED=1; FIP=$NODE; FOUND_STATE=$s
scp -q $SSHO "$PB" root@$NODE:$BASE/prov-base-254.sh || abort "copy prov-base"
q "mkdir -p $D/marks; for m in mesh-joined mesh-expected; do [ -e /opt/batdata/state/\$m ] && mv /opt/batdata/state/\$m $D/marks/; done; echo marks=[\$(ls $D/marks | tr '\n' ' ')] snapshot p5 sha \$(cut -c1-16 $D/p5.img.sha)" | sed 's/^/    /'
# ======== 2. p5 idle -> mkfs -> hold + apply (unseeded) -> reboot -> HELD unclaimed trial -> release
PH=s2
o=$(q "grep -c ' /dev/mmcblk0p5 ' /proc/mounts; ps w | grep -c '[b]atman-config-save'"); [ "$(echo $o)" = "0 0" ] && ok "p5 idle" || abort "p5 busy: $(echo $o)"
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
say "B stable: dhcpconfigured/uptime=$d"
# ======== 3. lab key (publickey proven BEFORE the claim), claim with H0
PH=s3
pub=$(cat "$LABKEY.pub"); fq "mkdir -p -m 0700 /etc/dropbear; grep -qxF '$pub' /etc/dropbear/authorized_keys 2>/dev/null || echo '$pub' >> /etc/dropbear/authorized_keys; chmod 0600 /etc/dropbear/authorized_keys; chown root:root /etc/dropbear/authorized_keys" >/dev/null
pk_proof "$FIP" && ok "lab key: publickey PROVEN" || abort "publickey does not authenticate — not claiming"
fq "mkdir -m 0711 $PCD && echo MADE" | grep -q MADE || abort "dvpc dir pre-exists: $PCD (refusing a planted provclient dir)"
scp -q $FRESHO "$TOOLS/provclient-arm64" root@"$FIP":$PCD/provclient && fq "chmod 0755 $PCD/provclient" >/dev/null || abort "provclient upload"
r=$(pcn owner.pem -- claim "$OWNER" "$ENC"); echo "$r" | sed 's/^/    /'
grep -q "RESULT claim.verify code=0 " <<< "$r" && ok "claim.verify code 0" || abort "claim failed"
x=$(fq "echo state=\$(sed -n 's/.*state=\([a-z]*\).*/\1/p' /etc/batman-prov/prov.meta) lock=\$(cat /opt/batdata/state/lock-status); $P5RO")
say "after claim: $(echo $x)"
for w in "state=claimed" "lock=LOCKED" "seeded=y" "metastat=[ok claimed]"; do case "$x" in *"$w"*) ok "claim: $w";; *) abort "claim: want $w";; esac; done
pk_proof "$FIP" && ok "publickey PROVEN after the claim" || abort "lost publickey login after the claim"
none_refused "$FIP" && ok "'none' refused after the claim" || abort "'none' still accepted on a LOCKED node"
# ======== 4. join N0 (the key never appears in argv or a log: drawn on the node / piped as a file)
PH=s4
if [ "$HAVEN0" = y ]; then
	wsl_ cat $N0 | ssh $FRESHO root@"$FIP" "umask 077; cat > $PCD/n0" || abort "N0 values to the node"
	[ "$(fq "grep -c '^sae=' $PCD/n0")" = 1 ] || abort "N0 values did not arrive"
else
	fq "umask 077; s=\$(head -c 16 /dev/urandom | hexdump -v -e '1/1 \"%02x\"'); printf 'mesh_id=bench-n0\nchannel=%s\nbw=2\nsae=%s\n' '$CH0' \"\$s\" > $PCD/n0; grep -c '^sae=' $PCD/n0" | grep -qx 1 || abort "N0 values not made"
fi
BJ=$(fq 'cut -c1-8 /proc/sys/kernel/random/boot_id')
if [ "$HAVEN0" = y ]; then	# the second node JOINS the first one's network: its signed net_config verbatim, its own net_secrets
	NETCFG=$(wsl_ cat $N0.cfg | tr -d '\r\n'); case "$NETCFG" in ''|*[!0-9a-f]*) abort "the bench store has no net_config ($N0.cfg)";; esac
	r=$(pcn owner.pem FD3="cat $PCD/n0" -- net-apply --join "$OWNER" "$NETCFG"); echo "$r" | grep RESULT | sed 's/^/    /'
	grep -q "RESULT net.apply(join) code=0 " <<< "$r" || abort "net-apply --join: $(echo "$r" | grep RESULT | tail -1)"
	ok "net-apply --join code 0 (N0 of the first node)"
else
	r=$(pcn owner.pem FD3="cat $PCD/n0" -- net-apply --first "$OWNER"); echo "$r" | grep RESULT | sed 's/^/    /'
	grep -q "RESULT net.apply code=0 " <<< "$r" || abort "net-apply --first: $(echo "$r" | grep RESULT | tail -1)"
	ok "net-apply --first code 0"
	NETCFG=$(sed -n 's/^NETCFG //p' <<< "$r"); case "$NETCFG" in ''|*[!0-9a-f]*) abort "no net_config in the reply";; esac
	printf '%s\n' "$NETCFG" | wsl_ bash -c "umask 077; cat > $N0.cfg" || abort "net_config to the bench store"   # signed config, no keys
	ssh $FRESHO root@"$FIP" "cat $PCD/n0" 2>/dev/null | wsl_ bash -c "umask 077; cat > $N0.new && [ \$(grep -c '^sae=' $N0.new) = 1 ] && mv $N0.new $N0" || abort "N0 values to the bench store"
	[ "$(wsl_ stat -c %a $N0 | tr -d '\r')" = 600 ] && ok "N0 kept in the bench store (0600)" || abort "bench store N0 mode"
fi
# openmanetd may reboot the node once after the join (254-h4 F-H42): wait until the boot holds for 150 s
wait_find 900 "slot=B ver=$V trial_rc=1 " || abort "node not found after the join"
t=$SECONDS; while [ $((SECONDS - t)) -lt 600 ]; do u=$(fq 'cut -d. -f1 /proc/uptime'); [ "${u:-0}" -ge 150 ] && break; sleep 15; find04 "slot=B ver=$V trial_rc=1 " >/dev/null || true; done
say "after the join at $FIP: $FOUND_STATE (boot at the join: $BJ)"
fq "[ -d $PCD ] || mkdir -m 0711 $PCD" >/dev/null; scp -q $FRESHO "$TOOLS/provclient-arm64" root@"$FIP":$PCD/provclient && fq "chmod 0755 $PCD/provclient" >/dev/null || abort "provclient upload (after the join)"
i=$(info); say "info: $i"
case "$i" in "state=member "*"rm=true"*) ok "member, radio managed";; *) abort "not a managed member: [$i]";; esac
x=$(fq "echo mesh_id=\$(uci -q get wireless.default_radio1.mesh_id) enc=\$(uci -q get wireless.default_radio1.encryption) ch=\$(uci -q get wireless.radio1.channel) txn=\$(ls /etc/batman-prov/*.txn 2>/dev/null | wc -l); batman-config-save --check >/dev/null 2>&1; echo check_rc=\$?")
say "wireless: $(echo $x)"
case "$x" in *"mesh_id=bench-n0 enc=sae ch=$CH0 txn=0 check_rc=0"*) ok "wireless == N0, no txn left, p5 in sync";; *) abort "wireless / p5 after the join: $(echo $x)";; esac
pk_proof "$FIP" && ok "publickey PROVEN after the join" || abort "lost publickey login after the join"
# ======== 5. keep: from here on nothing restores
PH=s5; KEPT=1
o=$(fq "rm -rf $PCD; mv $D $BASE/keep-$RUN && rm -f $DIRTY /etc/.dv-prov-mark-$RUN $BASE/prov-base-254.sh && rm -rf $PDIR; sync; echo kept=\$(ls -d $BASE/keep-$RUN) dirty=[\$(cat $DIRTY 2>/dev/null)] sn=\$(tr -d '\n' < /etc/batman-prov/identity/sn) docker=\$(docker ps -q 2>/dev/null | wc -l)")
say "$o"; case "$o" in *"kept=$BASE/keep-$RUN dirty=[] sn="?*) ok "legacy snapshot kept on p6, dirty flag gone";; *) no "keep step: $o";; esac
SN=$(echo "$o" | sed -n 's/.* sn=\([^ ]*\) .*/\1/p')
ssh-keygen -R "$FIP" >/dev/null 2>&1; hk=$(timeout 30 ssh -o BatchMode=yes -o ConnectTimeout=6 -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes -i "$LABKEY" root@"$FIP" 'cat /sys/class/net/eth0/address' 2>/dev/null | tr -d '\r')
[ "$hk" = "$MAC" ] && ok "known_hosts: $FIP re-pinned (the node there has eth MAC $MAC)" || no "known_hosts: could not re-pin $FIP [$hk]"
printf 'node=%s run=%s date=%s ip=%s mac=%s sn=%s version=%s keep=%s\n' "$NN" "$RUN" "$(date +%F)" "$FIP" "$MAC" "$SN" "$V" "$BASE/keep-$RUN" | wsl_ bash -c "umask 077; cat >> $BENCH/nodes.txt"
say "$NN is a claimed member of N0 at $FIP (was $NODE); $(fq "$ST")"
[ "$fails" = 0 ] && RESULT="PASS — $NN at $FIP sn $SN" || RESULT="KEPT WITH $fails FAIL"
