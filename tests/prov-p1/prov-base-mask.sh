#!/bin/bash
# tests/prov-p1/prov-base-mask.sh <prov-base-254.sh> — the restore compare prints nothing derived from a secret value
# (#254 v1.6 g4 PR B, 254-v16-ud §4.4 "masked restore compare"; reviews v10 B M1 / A m1, v11 B m1). One fixture per name
# class (key, key2, private_key, preshared_key, secret, token, password, psk, sae_password, mesh_id, ssid, a list line),
# each a changed `uci export` value, plus a changed regular file under each secret-bearing manifest path. The compare's
# output must contain neither value, nor any 4..16-hex prefix of its sha256, nor (for the manifest) the file's sha256;
# it must still name the option / path and say <redacted changed>. A harmless option changes and is printed in full.
# Negative control: the compare before this change prints the raw values and the hashes (FAILs here).
# Root (prov-base refuses otherwise), under a throwaway PROV_BASE_TEST_ROOT. Prints "PROV-BASE-MASK cases=N fails=M".
PB=${1:?usage: $0 <prov-base-254.sh>}
R=$(mktemp -d); export PROV_BASE_TEST_ROOT=$R; trap 'rm -rf "$R"' EXIT
mkdir -p "$R/usr/lib/batman" "$R/tmp/run"; printf 'batman_rundir(){ return 0; }\nRUNDIR=%s/tmp/run/batman\n' "$R" > "$R/usr/lib/batman/rundir.sh"
D=$R/opt/batdata/dv-prov/t1; mkdir -p "$D/snap/state" "$D/now-x/state"
cases=0; fails=0
ok(){ echo "ok   $*"; }; no(){ echo "FAIL $*"; fails=$((fails + 1)); }
sh256(){ printf '%s' "$1" | sha256sum | cut -c1-64; }
# leaks <output> <value>: the value, a 4..16-hex prefix of its sha256 (with and without a newline), or its full sha
leaks(){ local o=$1 v=$2 h1 h2 k
	grep -qF -- "$v" <<< "$o" && { echo "raw value"; return 0; }
	h1=$(printf '%s' "$v" | sha256sum | cut -c1-64); h2=$(printf '%s\n' "$v" | sha256sum | cut -c1-64)
	for k in 16 12 8 6 4; do grep -qiF -- "${h1:0:$k}" <<< "$o" && { echo "sha256 prefix ${h1:0:$k}"; return 0; }; grep -qiF -- "${h2:0:$k}" <<< "$o" && { echo "sha256 prefix ${h2:0:$k}"; return 0; }; done
	return 1; }
base(){ local t g; for t in snap now-x; do find "$D/$t" -maxdepth 1 -type f -delete; : > "$D/$t/state/x"; for g in p5.manifest upper.manifest identity; do echo same > "$D/$t/$g"; done; done; }
run(){ OUT=$(ALLOW_FILE=/nonexistent sh "$PB" compare t1 x 2>&1); RC=$?; }
i=0
for spec in "option key" "option key2" "option private_key" "option preshared_key" "option secret" "option token" "option password" \
	"option psk" "option sae_password" "option mesh_id" "option ssid" "list key"; do
	i=$((i + 1)); cases=$((cases + 1)); kind=${spec%% *}; name=${spec#* }
	old="Old${i}Zq7vW${i}xR"; new="New${i}Kp3mT${i}yS"
	base
	printf "=== wireless\nconfig wifi-iface 'x'\n\t%s %s '%s'\n\toption channel '40'\n" "$kind" "$name" "$old" > "$D/snap/uci.export"
	printf "=== wireless\nconfig wifi-iface 'x'\n\t%s %s '%s'\n\toption channel '40'\n" "$kind" "$name" "$new" > "$D/now-x/uci.export"
	run
	l1=$(leaks "$OUT" "$old"); l2=$(leaks "$OUT" "$new")
	if [ "$RC" = 1 ] && [ -z "$l1$l2" ] && grep -qF "$kind $name '<redacted changed>'" <<< "$OUT" && [ "$(grep -c '^DIFF uci.export' <<< "$OUT")" = 2 ]; then ok "$kind $name: DIFF printed, value redacted"
	else no "$kind $name: rc=$RC old[$l1] new[$l2]"; fi
done
# a harmless option is printed in full (the redaction is not a blanket one)
cases=$((cases + 1)); base
printf "=== system\n\toption hostname 'alpha1'\n" > "$D/snap/uci.export"; printf "=== system\n\toption hostname 'beta2'\n" > "$D/now-x/uci.export"; run
grep -qF "option hostname 'alpha1'" <<< "$OUT" && grep -qF "option hostname 'beta2'" <<< "$OUT" && ok "a harmless option is printed as it is" || no "harmless option: $OUT"
# manifest lines: the hash of a secret-bearing file is redacted, path and mode kept; another file keeps its hash
for spec in "upper.manifest etc/config/wireless" "upper.manifest etc/shadow" "upper.manifest etc/batman-prov/prov.cbor" \
	"p5.manifest overrides.uci" "p5.manifest identity/node.key"; do
	cases=$((cases + 1)); f=${spec%% *}; pth=${spec#* }; base
	ho=$(sh256 "old $pth"); hn=$(sh256 "new $pth")
	printf -- '-rw------- 0:0 %s %s\n' "$ho" "$pth" > "$D/snap/$f"; printf -- '-rw------- 0:0 %s %s\n' "$hn" "$pth" > "$D/now-x/$f"
	echo "uci" > "$D/snap/uci.export"; echo "uci" > "$D/now-x/uci.export"; run
	if [ "$RC" = 1 ] && ! grep -qE '[0-9a-f]{64}' <<< "$OUT" && ! grep -qF "${ho:0:8}" <<< "$OUT" && ! grep -qF "${hn:0:8}" <<< "$OUT" \
		&& [ "$(grep -cF -- "-rw------- 0:0 <redacted changed> $pth" <<< "$OUT")" = 2 ]; then ok "$f $pth: mode and path kept, hash redacted"
	else no "$f $pth: rc=$RC $(grep DIFF <<< "$OUT" | head -2 | tr '\n' '|')"; fi
done
cases=$((cases + 1)); base; h=$(sh256 "bin"); printf -- '-rwxr-xr-x 0:0 %s usr/bin/x\n' "$h" > "$D/snap/upper.manifest"; echo "-rwxr-xr-x 0:0 $(sh256 bin2) usr/bin/x" > "$D/now-x/upper.manifest"
echo uci > "$D/snap/uci.export"; echo uci > "$D/now-x/uci.export"; run
grep -qF "$h usr/bin/x" <<< "$OUT" && ok "a file outside the secret paths keeps its hash" || no "usr/bin/x: $OUT"
echo "PROV-BASE-MASK cases=$cases fails=$fails"; [ "$cases" -gt 0 ] && [ "$fails" = 0 ]
