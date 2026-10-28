#!/bin/bash
# scripts/dv-sbx.sh — #254 dv-sbx: the provisioning sandbox (docs/design/254-h23-harness.md §4.4; 254-p1-impl §4.10, §5.1).
# Root on a throw-away Linux host (CI ubuntu-24.04-arm; locally WSL with arm64 binfmt). Never on a node.
#   dv-sbx.sh [--soc bcm2711|bcm2710] [--base <payload.tar.gz>] [--go <go binary>] [--feed <feed dir>] <case>[:<mutant>] ...
#     --soc bcm2710: the bcm2710 payload's rootfs as the base (prov-unit-bcm2710, a SMOKE: same cases, other base)
#     --feed: the product to test (default: this checkout's feed/); e.g. a P1b checkout's while this one is pre-P1b
#     builds $SBX/root once per call: the pinned base payload's rootfs (tests/prov-p1/sbx/base.env; sha checked) + this
#     checkout's feed/batman-provision files laid over by their Makefile install lines (lint-install first) + the
#     helper built from feed/batman-prov/src with -tags prov_test (arm64) + the call-logging stubs + the cases; then
#     runs each case in `unshare --mount --pid --fork --net --uts --ipc` (tests/prov-p1/sbx/setup.sh: private /dev,
#     /tmp, /tmp/run, /opt/batdata, a fake /proc/cmdline, read-only /proc/sys and sysrq-trigger, p5 = a loop device
#     on $SBX/p5.img) and `capsh` without cap_sys_boot / module / time / rawio / mknod, chrooted.
#   case "escape" = prov-unit-sbx: the sandbox's own negative tests, judged here on the host.
#   <case>:<mutant> must FAIL (the mutant is the case's own negative control); a plain case must report cases > 0 and
#   fails = 0. Any other result, or a case that runs nothing, FAILs.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd); SX=$REPO/tests/prov-p1/sbx
SBX=${SBX:-}; BASE=""; GO=${GO:-go}; FEED=$REPO/feed; SOC=bcm2711; fails=0
no(){ echo "FAIL $*"; fails=$((fails + 1)); }
die(){ echo "FAIL $*"; cleanup; exit 1; }
LOOP=""
cleanup(){ [ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null; LOOP=""; }
trap cleanup EXIT
while [ $# -gt 0 ]; do case "$1" in
	--base) BASE=$2; shift 2 ;;
	--go) GO=$2; shift 2 ;;
	--soc) SOC=$2; shift 2 ;;
	--feed) FEED=$(cd "$2" && pwd) || exit 2; shift 2 ;;
	-*) echo "usage: dv-sbx.sh [--base <payload>] [--go <go>] <case>[:<mutant>] ..."; exit 2 ;;
	*) break ;;
esac; done
[ $# -gt 0 ] || { echo "FAIL no case given"; exit 2; }
[ "$(id -u)" = 0 ] || { echo "FAIL root only (unshare / mount / losetup)"; exit 2; }
for t in unshare capsh chroot losetup unsquashfs mkfs.ext4 tar sha256sum; do command -v "$t" >/dev/null || die "missing host tool $t"; done
# shellcheck source=tests/prov-p1/sbx/base.env
. "$SX/base.env"
case "$SOC" in bcm2711) ;; bcm2710) BASE_URL=$BASE_URL_BCM2710; BASE_SHA256=$BASE_SHA256_BCM2710 ;; *) echo "FAIL --soc $SOC"; exit 2 ;; esac

# ---- build the root ---------------------------------------------------------------------------------------------------
# the work dir: a fresh private mktemp dir, or SBX = an existing root-owned directory (not a symlink) emptied here —
# never a predictable /tmp path root would rm -rf or follow (#280 tmp-trust)
if [ -z "$SBX" ]; then SBX=$(mktemp -d /tmp/dv-sbx.XXXXXX) || die "mktemp"
else [ -d "$SBX" ] && [ ! -L "$SBX" ] && [ -O "$SBX" ] || die "SBX=$SBX is not a root-owned directory (or is a symlink)"
	grep -q " $SBX/" /proc/mounts && die "something is still mounted under $SBX"; find "$SBX" -mindepth 1 -maxdepth 1 -exec rm -rf {} +; fi
RT=$SBX/root; echo "work dir $SBX"
if [ -n "$BASE" ]; then cp "$BASE" "$SBX/base.tgz" || die "copy $BASE"
else curl -fsSL --retry 3 -o "$SBX/base.tgz" "$BASE_URL" || die "download $BASE_URL"; fi
[ "$(sha256sum < "$SBX/base.tgz" | cut -c1-64)" = "$BASE_SHA256" ] || die "base payload sha != the pinned $SOC sha ($BASE_VER)"
tar -xzf "$SBX/base.tgz" -C "$SBX" root.squashfs && unsquashfs -q -d "$RT" "$SBX/root.squashfs" >/dev/null || die "unpack the base rootfs"
echo "base $BASE_VER $SOC unpacked ($(find "$RT" -xdev | wc -l) entries)"
bash "$REPO/scripts/lint-install.sh" "${FEED%/feed}" || die "lint-install"
F=$FEED/batman-provision
n=0
while read -r kind src dst; do
	case "$kind" in '$(INSTALL_BIN)') m=0755 ;; '$(INSTALL_DATA)') m=0644 ;; *) die "install kind $kind" ;; esac
	install -D -m "$m" "$F/${src#./}" "$RT/${dst#\$(1)/}" || die "install $src"; n=$((n + 1))
done < <(grep -oE '\$\(INSTALL_(BIN|DATA)\)[[:space:]]+\./files/[^[:space:]]+[[:space:]]+\$\(1\)/[^[:space:]]+' "$F/Makefile")
install -D -m 0755 "$FEED/batman-prov/files/batman-provhelper.init" "$RT/etc/init.d/batman-provhelper" || die "install helper init"
echo "product: $FEED"; echo "laid $n batman-provision files + the helper init over the base"
( cd "$FEED/batman-prov/src" && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 GOFLAGS=-mod=vendor GOTOOLCHAIN=local \
	"$GO" build -tags prov_test -trimpath -ldflags "-s -w" -o "$RT/usr/bin/batman-provhelper" ./cmd/batman-provhelper ) || die "helper build"
chroot "$RT" /usr/bin/batman-provhelper --version 2>/dev/null | grep -q BATMAN_PROV_TEST_BUILD_7f3a || die "the sandbox helper has no prov_test marker — pre-P1b product (no seams) in $FEED; red until feat/254-p1b-seams lands (#254)"
mkdir -p "$RT/sbx/bin" "$RT/sbx/cases"
install -m 0755 "$SX"/stubs/* "$RT/sbx/bin/" && install -m 0644 "$SX"/cases/*.sh "$RT/sbx/cases/" || die "stubs / cases"
# first boot's config_generate (board.json -> /etc/config/system) never ran on the squashfs: its system section is the
# one first-boot file the uci-defaults rely on (dv-sbx run 2: every prov_apply_lock stopped at `uci set
# system.@system[0].ttylogin` -> LOCK-INCOMPLETE). The stand-in = config_generate's defaults for the fields used here.
[ -e "$RT/etc/config/system" ] || printf "config system\n\toption hostname 'OpenWrt'\n\toption timezone 'UTC'\n\toption ttylogin '0'\n" > "$RT/etc/config/system"
cp -a "$RT/etc" "$RT/sbx/etc.lower" || die "etc.lower"
truncate -s 32M "$SBX/p5.img" || die "p5.img"
LOOP=$(losetup -f --show "$SBX/p5.img") || die "losetup"
# only our own regular file, never a device something mounts or the host's /overlay stands on (§4.10)
[ "$(losetup -nO BACK-FILE "$LOOP" | sed 's/[[:space:]]*$//')" = "$SBX/p5.img" ] || die "$LOOP is not backed by $SBX/p5.img"
grep -q "^$LOOP " /proc/mounts && die "$LOOP is mounted"
echo "p5 = $LOOP"

# ---- run the cases ----------------------------------------------------------------------------------------------------
run(){	# <case> <mutant|-> -> the case output on stdout
	SBX_HOST_BOOT=$(cat /proc/sys/kernel/random/boot_id) unshare --mount --pid --fork --net --uts --ipc --propagation private -- \
		bash "$SX/setup.sh" "$RT" "$LOOP" "$1" "$2" 2>&1
}
escape(){	# prov-unit-sbx: the host side of the sandbox's negative tests
	local b0 marker o ifn
	b0=$(cat /proc/sys/kernel/random/boot_id); marker="SBX-KMSG-$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')"
	ifn="sbx$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
	ip link show "$ifn" >/dev/null 2>&1 && { no "escape: the host already has $ifn (cannot judge)"; return; }
	o=$(SBX_MARKER=$marker SBX_IF=$ifn run escape -); echo "$o" | sed 's/^/    /'
	grep -q '^CASE escape cases=[1-9][0-9]* fails=0$' <<< "$o" || no "escape: the in-sandbox half failed"
	[ "$(cat /proc/sys/kernel/random/boot_id)" = "$b0" ] && echo "ok   escape: host boot_id unchanged after reboot -f in the sandbox" || no "escape: host boot_id changed"
	ip link show "$ifn" >/dev/null 2>&1 && { no "escape: $ifn made in the sandbox is visible on the host"; ip link del "$ifn"; } || echo "ok   escape: $ifn (made in the sandbox) not on the host (netns)"
	dmesg 2>/dev/null | grep -q "$marker" && no "escape: the sandbox's /dev/kmsg write reached the host dmesg" || echo "ok   escape: /dev/kmsg write not in the host dmesg"
	[ "$(hostname)" != x ] && echo "ok   escape: host hostname unchanged" || no "escape: host hostname changed"
}
for c in "$@"; do
	name=${c%%:*}; mut=-; [ "$c" != "$name" ] && mut=${c#*:}
	[ -f "$SX/cases/$name.sh" ] || { no "no case $name"; continue; }
	echo "== case $name${mut:+ mutant $mut}"
	if [ "$name" = escape ]; then escape; continue; fi
	o=$(run "$name" "$mut"); echo "$o" | sed 's/^/    /'
	v=$(grep -E '^CASE [a-z0-9-]+ cases=[0-9]+ fails=[0-9]+$' <<< "$o" | tail -1)
	cs=$(sed -n 's/.* cases=\([0-9]*\) .*/\1/p' <<< "$v"); fs=$(sed -n 's/.* fails=\([0-9]*\)$/\1/p' <<< "$v")
	if [ -z "$v" ] || [ "${cs:-0}" = 0 ]; then no "$c: ran nothing / no verdict line"
	elif [ "$mut" = - ]; then [ "$fs" = 0 ] && echo "ok   $c: $cs cases" || no "$c: $fs of $cs cases failed"
	else [ "$fs" -gt 0 ] && echo "ok   $c: the mutant is caught ($fs of $cs cases fail)" || no "$c: the mutant passed every case — the case does not discriminate"; fi
done
echo "DV-SBX fails=$fails"; [ "$fails" = 0 ]
