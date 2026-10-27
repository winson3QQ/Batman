# shellcheck shell=bash disable=SC2034  # a library: its globals (ATK, …) are read by the caller
# scripts/dv/prov-lib-254.sh — the setup / restore half of scripts/dv/prov-claim-254.sh (#254 claim-lock fix,
# docs/design/254-claim-lock-fix.md §11.3). The caller sets PL_NAME, sources this file, then calls
#   pl_prep      preconditions (legacy, committed on either slot, helper up, publickey proven, probe musl == node libc),
#                prov-base snapshot S0, per-run owner / enc / attacker keys in WSL, provclient + cryptprobe on the node
#   pl_restore   S0 back (p5 + overlay restore, reboot committed, compare diffs=0, back to legacy / UNPROVISIONED)
#   pl_end       tools / keys removed, "fails=N", rc
# Helpers: q (ssh), nb (prov-base on the node), pc (provclient + WSL signer), probe, lockstate, p5shadow, offered,
# pk_proof, bid / waitboot / settle. Runs from Git Bash on the Windows host.
NODE=${NODE:-10.41.1.3}
RUN=${RUN:-${PL_NAME#prov-}$(date +%m%d%H%M)}
HT=$(mktemp -d); RUNLOG=$HT/out.log; exec > >(tee "$RUNLOG") 2>&1
H=$(cd "$(dirname "$0")/../.." && pwd)
TOOLS=${DV_PROV_TOOLS:?DV_PROV_TOOLS = host dir with provclient-arm64 (pushed to the node)}
TOOLS_WSL=${DV_PROV_TOOLS_WSL:-/home/yello/batman-dv-tools/prov}
PROBE=${DV_CRYPTPROBE:?DV_CRYPTPROBE = host dir from scripts/dv-cryptprobe-tools.sh (cryptprobe-arm64, MUSL, SHA256SUMS)}
LABKEY=${LABKEY:-$HOME/.ssh/id_ed25519}
SSHO="-o BatchMode=yes -o ConnectTimeout=6 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 -o IdentitiesOnly=yes"
WSLK=/home/yello/.batman-dv/prov-keys/$RUN
PCD=/tmp/run/batman-dvpc.$RUN   # 0711 (provclient drops to uid 471)
say(){ echo "[$(date +%H:%M:%S) $PL_NAME $RUN] $*"; }
fails=0; ok(){ echo "PASS $*"; }; no(){ echo "FAIL $*"; fails=$((fails + 1)); }
q(){ timeout 120 ssh $SSHO root@$NODE "$@" 2>/dev/null | tr -d '\r'; }
nb(){ timeout 900 ssh $SSHO root@$NODE sh -s -- "$@" < "$H/scripts/node/prov-base-254.sh" 2>&1 | tr -d '\r'; }
wsl_(){ MSYS_NO_PATHCONV=1 wsl.exe -d Ubuntu-24.04 -u yello -- "$@"; }
bid(){ timeout 20 ssh $SSHO root@$NODE 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null | tr -d '\r\n '; }
waitboot(){ local b0=$1 t0=$SECONDS b; while [ $((SECONDS-t0)) -lt 900 ]; do b=$(bid); [ -n "$b" ] && [ "$b" != "$b0" ] && return 0; sleep 10; done; return 1; }
settle(){ local t0=$SECONDS u; while [ $((SECONDS-t0)) -lt 600 ]; do u=$(q 'cut -d. -f1 /proc/uptime'); [ "${u:-0}" -ge 90 ] && return 0; sleep 10; done; return 1; }
# publickey PROOF: OpenSSH always tries `none` first and an open node accepts it, so the key is proven against a
# temporary publickey-only listener of the same dropbear (-s -g, port 2222, a tagged nft accept rule), whose own
# negative control is that `none` is denied there; listener and rule are removed and that is asserted.
PKO="-o BatchMode=yes -o ConnectTimeout=6 -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o PreferredAuthentications=publickey -o PubkeyAuthentication=yes -o IdentitiesOnly=yes -i $LABKEY -o LogLevel=VERBOSE"
NONEO="-o BatchMode=yes -o ConnectTimeout=6 -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o PreferredAuthentications=none -o PubkeyAuthentication=no -o LogLevel=ERROR"
pk_proof(){ local r=1 o
	q 'mkdir -p -m 0700 /tmp/run/batman-dv; pid=/tmp/run/batman-dv/dv-pk.pid; [ -s $pid ] && kill $(cat $pid) 2>/dev/null; nft -a list chain inet fw4 input 2>/dev/null | grep -q dv-pk-proof || nft insert rule inet fw4 input tcp dport 2222 accept comment "dv-pk-proof" 2>/dev/null; dropbear -s -g -p 2222 -P $pid && sleep 1 && [ -s $pid ] && echo LISTEN' | grep -q LISTEN || { echo "    pk_proof: listener did not start"; return 1; }
	o=$(timeout 30 ssh -p 2222 $PKO root@$NODE 'echo PKOK' 2>&1 | tr -d '\r')
	if grep -qE 'Authenticated to .* using "publickey"' <<< "$o" && grep -q PKOK <<< "$o"; then
		timeout 30 ssh -p 2222 $NONEO root@$NODE 'echo NONEOK' 2>&1 | grep -q "Permission denied" && r=0 || echo "    pk_proof: 'none' not denied on the publickey-only listener (probe invalid)"
	else echo "    pk_proof: no publickey authentication on the listener"; fi
	o=$(q 'pid=/tmp/run/batman-dv/dv-pk.pid; kill $(cat $pid) 2>/dev/null; rm -f $pid; for h in $(nft -a list chain inet fw4 input 2>/dev/null | sed -n "s/.*dv-pk-proof.*# handle \([0-9]*\).*/\1/p"); do nft delete rule inet fw4 input handle $h; done; sleep 1; echo "left=$(nft -a list chain inet fw4 input 2>/dev/null | grep -c dv-pk-proof) listen=$(netstat -ltn 2>/dev/null | grep -c ":2222 ")"')
	[ "$o" = "left=0 listen=0" ] || { echo "    pk_proof: cleanup incomplete ($o)"; r=1; }
	return $r; }
# the server's offered methods on port 22, read from a `none` attempt (not a wrong-password attempt)
offered(){ timeout 30 ssh -v $NONEO -o LogLevel=DEBUG root@$NODE true 2>&1 | tr -d '\r' | sed -n 's/.*Authentications that can continue: //p' | tail -1; }
# probe <pwfile on node> -> MATCH / NOMATCH / ... of crypt(password, shadow's root hash), computed ON the node
probe(){ q "h=\$(grep '^root:' /etc/shadow | cut -d: -f2); $PCD/cryptprobe \"\$h\" < $1"; }

# pc <key> [ENV=v ...] -- <op> [args]: provclient on the node; its "SIGN …" lines go to the WSL signer (coproc); each
# "SIG …" answer goes back on the node's stdin through a FIFO; every other line is the op's output (secrets as sha only)
pc(){
	local key=$1; shift; local envs=""; while [ "$1" != -- ]; do envs="$envs $1"; shift; done; shift
	local f; f=$(mktemp -d "$HT/fifo.XXXXXX")/p; mkfifo "$f"
	coproc SIGNP { wsl_ "$TOOLS_WSL/provclient-amd64" sign "$WSLK/$key"; }
	exec {W}<>"$f"
	local out="" line sig
	while IFS= read -r line; do
		line=$(printf '%s' "$line" | tr -d '\r')
		case "$line" in
			SIGN\ *) echo "$line" >&"${SIGNP[1]}"; IFS= read -r -t 30 sig <&"${SIGNP[0]}" || sig=ERR; printf '%s\n' "$sig" | tr -d '\r' >&"$W" ;;
			*) out="$out$line
" ;;
		esac
	done < <(ssh $SSHO root@$NODE "$envs $PCD/provclient node $*" < "$f" 2>&1)
	exec {W}>&-; kill "$SIGNP_PID" 2>/dev/null; rm -rf "${f%/p}"   # stop the signer ({SIGNP[1]}>&- is not valid bash)
	printf '%s' "$out"
}
lockstate(){ q 'echo "state=$(sed -n "s/.*state=\([a-z]*\).*/\1/p" /etc/batman-prov/prov.meta) lock=$(cat /opt/batdata/state/lock-status) pw=$(uci -q get dropbear.@dropbear[0].PasswordAuth) rootpw=$(uci -q get dropbear.@dropbear[0].RootPasswordAuth) tty=$(uci -q get system.@system[0].ttylogin) hash=$(grep ^root: /etc/shadow | cut -d: -f2 | cut -c1-3) lks=$(awk "NR==1 {print \$3}" /opt/batdata/state/prov-state) dbs=$(ubus call service list "{\"name\":\"dropbear\"}" | jsonfilter -e "@.dropbear.instances[*].command" | grep "\"-s\"" | grep -c "\"-g\"")"'; }
p5shadow(){ q 'd=$(mktemp -d /tmp/run/batman-dv/p5s.XXXXXX) && mount -o ro,noload /dev/mmcblk0p5 $d && { [ -s $d/identity/shadow-root ] && sha256sum < $d/identity/shadow-root | cut -c1-16 || echo none; [ -f $d/.seeded ] && echo seeded || echo unseeded; umount $d; }; rmdir $d'; }

pl_prep(){
# --- 0. preconditions: legacy, committed (either slot), helper serving; publickey proven
s=$(q 'echo "slot=$(batman-slot active) trial=$(batman-slot is-trial >/dev/null 2>&1; echo $?) state=$(sed -n "s/.*state=\([a-z]*\).*/\1/p" /etc/batman-prov/prov.meta) helper=$(pidof batman-provhelper >/dev/null && echo up || echo down) ver=$(sed -n s/^BATMAN_VERSION=//p /etc/batman-build)"')
say "pre: $s"
case "$s" in *"trial=1 state=legacy helper=up"*) ;; *) no "precondition (want committed, legacy, helper up): $s"; exit 1;; esac
pk_proof && ok "publickey proven before the claim (the claim turns password / none login off)" || { no "publickey not proven — not claiming"; exit 1; }
# probe tool and libc version (the probe is static against the toolchain's musl; refuse a mismatch)
(cd "$PROBE" && sha256sum -c --quiet SHA256SUMS) || { no "$PROBE/SHA256SUMS does not verify"; exit 1; }
nm=$(q '/lib/libc.so 2>&1 | sed -n "s/^Version //p"'); pm=$(cat "$PROBE/MUSL")
[ -n "$nm" ] && [ "$nm" = "$pm" ] && ok "probe musl $pm == node libc $nm" || { no "probe musl [$pm] != node libc [$nm]"; exit 1; }
# --- 1. snapshot (S0) and per-run owner keys (WSL ext4, 0600)
q "mkdir -p -m 0700 /tmp/run/batman-dv"; scp -q $SSHO "$H/tests/prov-p1/overlay-allow.txt" root@$NODE:/tmp/run/batman-dv/overlay-allow.txt || { no "allow-list upload"; exit 1; }
o=$(nb snap "$RUN"); echo "$o" | tail -1; grep -q "^SNAP $RUN" <<< "$o" || { no "snap"; exit 1; }
# (no loop variable: wsl.exe mangles an escaped `$k` on its way into bash -c)
wsl_ bash -c "umask 077; mkdir -p $WSLK && $TOOLS_WSL/provclient-amd64 keygen $WSLK/owner.pem > $WSLK/owner.pub && $TOOLS_WSL/provclient-amd64 keygen $WSLK/enc.pem > $WSLK/enc.pub && $TOOLS_WSL/provclient-amd64 keygen $WSLK/attacker.pem > $WSLK/attacker.pub && stat -c '%a' $WSLK/owner.pem"
OWNER=$(wsl_ cat $WSLK/owner.pub | tr -d '\r'); ENC=$(wsl_ cat $WSLK/enc.pub | tr -d '\r')
ATK=$(wsl_ cat $WSLK/attacker.pub | tr -d '\r')
[ ${#OWNER} = 130 ] && [ ${#ENC} = 130 ] || { no "owner keys"; exit 1; }

# --- 2. provclient + probe onto the node: $PCD root 0711, files root 0755 / 0700, sha checked
scp -q $SSHO "$TOOLS/provclient-arm64" root@$NODE:/tmp/run/batman-dv/pc.$RUN.upload && scp -q $SSHO "$PROBE/cryptprobe-arm64" root@$NODE:/tmp/run/batman-dv/cp.$RUN.upload || { no "upload"; exit 1; }
PSHA=$(sha256sum < "$TOOLS/provclient-arm64" | cut -c1-64); CSHA=$(sha256sum < "$PROBE/cryptprobe-arm64" | cut -c1-64)
q "set -e; mkdir -m 0711 $PCD; mv /tmp/run/batman-dv/pc.$RUN.upload $PCD/provclient; mv /tmp/run/batman-dv/cp.$RUN.upload $PCD/cryptprobe; chown root:root $PCD $PCD/provclient $PCD/cryptprobe; chmod 0755 $PCD/provclient; chmod 0700 $PCD/cryptprobe; [ \"\$(sha256sum < $PCD/provclient | cut -c1-64)\" = $PSHA ] && [ \"\$(sha256sum < $PCD/cryptprobe | cut -c1-64)\" = $CSHA ] && echo PCOK" | grep -q PCOK && ok "provclient + cryptprobe placed ($PCD, sha checked)" || no "tool placement"
}

pl_restore(){
# --- 10. restore S0 (the node is LOCKED: publickey still works, proven above)
o=$(nb p5-restore "$RUN"); echo "$o" | tail -1; grep -q "^P5-RESTORED" <<< "$o" || no "p5 restore"
o=$(nb overlay-restore "$RUN"); echo "$o" | grep -E "EXTRA-REMOVED|OVERLAY" | tail -8; grep -q "^OVERLAY-RESTORED" <<< "$o" || no "overlay restore"
b0=$(bid); q "(batman-slot reboot committed $PL_NAME </dev/null >/dev/null 2>&1 &)"; waitboot "$b0" && settle || no "reboot after restore"
q "mkdir -p -m 0700 /tmp/run/batman-dv"; scp -q $SSHO "$H/tests/prov-p1/overlay-allow.txt" root@$NODE:/tmp/run/batman-dv/overlay-allow.txt
q "/etc/init.d/joinwatch stop >/dev/null 2>&1"
o=""; for _ in 1 2 3; do nb manifest "$RUN" after >/dev/null; o=$(nb compare "$RUN" after); grep -q "p5 unreadable" <<< "$o" || break; sleep 10; done
q "/etc/init.d/joinwatch start >/dev/null 2>&1"; echo "$o" | sed 's/^/    /' | tail -30
if grep -q "diffs=0" <<< "$o"; then ok "S0 restored (p5 / overlay / uci / identity / p6 state)"; nb finish "$RUN" | tail -1; else no "S0 not restored — snapshot and dirty flag kept"; fi
st=$(q 'echo "state=$(sed -n "s/.*state=\([a-z]*\).*/\1/p" /etc/batman-prov/prov.meta) lock=$(cat /opt/batdata/state/lock-status) pw=$(uci -q get dropbear.@dropbear[0].PasswordAuth)"'); say "after restore: $st"
case "$st" in *"state=legacy lock=UNPROVISIONED pw=on"*) ok "back to legacy / UNPROVISIONED / password auth on";; *) no "not back to legacy: $st";; esac
}
pl_end(){
q "rm -rf $PCD"; wsl_ rm -rf "$WSLK"
say "fails=$fails"; rm -rf "$HT"; [ "$fails" = 0 ]
}
