#!/bin/bash
# tests/prov-p1/s5-payload.sh <scripts/build-ab-payload.sh> — #254 P3 S5 (254-p3-impl §3.7.2, F27 / F57): the payload
# the node's worker reads: SHA256SUMS first, metadata second, root.squashfs last; metadata release = the rootfs's own
# BATMAN_VERSION; only kernel8 / start* / fixup* / *.dtb / overlays go into boot/ (never config.txt / cmdline.txt);
# members by name still work for the sysupgrade path; no unsquashfs on the host = FAIL; a rootfs without the stamp =
# no release= + a WARN. A synthetic bcm2711 rootfs + boot dir (needs mksquashfs / unsquashfs). Nothing checked = FAIL.
exec </dev/null
B=$(readlink -f "${1:?usage: $0 <build-ab-payload.sh>}")
grep -q 'release=' "$B" || { echo "FAIL $B predates the S5 payload format: expected red until feat/254-p3 S5 lands (#254)"; exit 1; }
command -v mksquashfs >/dev/null && command -v unsquashfs >/dev/null || { echo "FAIL needs mksquashfs / unsquashfs (squashfs-tools)"; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0; n=0
ck() { n=$((n + 1)); if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got [$2] want [$3]"; fail=1; fi; }
V=1.5.14-wsl.26+abcdef1.fw0123456
mkdir -p $T/root/etc $T/boot/overlays
echo "BATMAN_VERSION=$V" > $T/root/etc/batman-build
echo "DISTRIB_TARGET='bcm27xx/bcm2711'" > $T/root/etc/openwrt_release
for f in kernel8.img start4.elf fixup4.dat bcm2711-rpi-4-b.dtb config.txt cmdline.txt; do echo "$f" > $T/boot/$f; done
echo ovl > $T/boot/overlays/vc4-kms-v3d.dtbo
mksquashfs $T/root $T/root.squashfs -quiet -noappend -all-root >/dev/null || { echo "FAIL mksquashfs"; exit 1; }
bash "$B" $T/root.squashfs $T/boot ekh-bcm2711 $T/p.tar.gz > $T/log 2>&1 || { cat $T/log; echo "FAIL build"; exit 1; }
tar -tzf $T/p.tar.gz > $T/list
ck "first member SHA256SUMS" "$(sed -n 1p $T/list)" SHA256SUMS
ck "second member metadata" "$(sed -n 2p $T/list)" metadata
ck "last member root.squashfs" "$(tail -1 $T/list)" root.squashfs
ck "metadata release = the stamp" "$(tar -xzOf $T/p.tar.gz metadata | sed -n 's/^release=//p')" "$V"
ck "metadata board" "$(tar -xzOf $T/p.tar.gz metadata | sed -n 's/^board=//p')" ekh-bcm2711
ck "no config.txt / cmdline.txt packed" "$(grep -cE 'boot/(config|cmdline)\.txt' $T/list)" 0
ck "by name: root.squashfs (as platform-ab.sh reads it)" "$(zcat $T/p.tar.gz | tar -xOf - root.squashfs | sha256sum | cut -d' ' -f1)" "$(sha256sum < $T/root.squashfs | cut -d' ' -f1)"
mkdir $T/x && tar -C $T/x -xzf $T/p.tar.gz && (cd $T/x && sha256sum -c --quiet SHA256SUMS) && ck "SHA256SUMS verifies" ok ok || ck "SHA256SUMS verifies" bad ok
UNSQUASHFS=/nonexistent/unsquashfs bash "$B" $T/root.squashfs $T/boot ekh-bcm2711 $T/nous.tar.gz > $T/log3 2>&1; ck "no unsquashfs -> FAIL" "$?" 1
ck "no unsquashfs -> no payload" "$([ -e $T/nous.tar.gz ] && echo made || echo none)" none
rm $T/root/etc/batman-build; mksquashfs $T/root $T/r2.squashfs -quiet -noappend -all-root >/dev/null
bash "$B" $T/r2.squashfs $T/boot ekh-bcm2711 $T/ns.tar.gz > $T/log2 2>&1
ck "no stamp -> no release=" "$(tar -xzOf $T/ns.tar.gz metadata | grep -c '^release=')" 0
ck "no stamp -> a WARN" "$(grep -c 'no BATMAN_VERSION' $T/log2)" 1
echo "S5-PAYLOAD checks=$n fail=$fail"
[ $fail = 0 ] && [ $n -gt 0 ]
