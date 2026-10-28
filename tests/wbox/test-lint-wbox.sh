#!/bin/bash
# test-lint-wbox.sh — self-test of scripts/lint-wbox.sh on a fake repo: the good set passes; each broken patch FAILs
# for its own reason (a FAIL for another reason is BAD).
set -u
L=$(cd "$(dirname "$0")/../.." && pwd)/scripts/lint-wbox.sh
[ -f "$L" ] || { echo "no $L"; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; bad=0
mkrepo(){ local r=$T/$1; rm -rf $r; mkdir -p $r/tests/wbox $r/feed/batman-prov/src/node $r/feed/batman-provision/files/etc/uci-defaults $r/feed/batman-provision/files/etc/init.d $r/feed/other
	printf 'package node\n\nfunc f(log func(string)) {\n\tlog("start")\n}\n' > $r/feed/batman-prov/src/node/n.go
	printf '#!/bin/sh\necho base\n' > $r/feed/batman-provision/files/etc/uci-defaults/96-x; seq 1 40 > $r/feed/other/y; : > $r/tests/wbox/.keep   # tracked, so `git clean -d` keeps the dir
	git -C $r init -q; git -C $r -c user.email=t@t -c user.name=t add -A; git -C $r -c user.email=t@t -c user.name=t commit -qm base; echo $r; }
# patch helpers: write a patch made by really editing the repo, then reset
mkpatch(){ local r=$1 name=$2 desc=$3 wit=$4; shift 4; "$@"; git -C $r add -A feed
	{ echo "# wbox $name: $desc"; echo "# wbox-witness: $wit"; git -C $r diff --cached; } > $T/$name.patch; git -C $r reset -q --hard; git -C $r clean -qfd feed; mv $T/$name.patch $r/tests/wbox/; }
gogood(){ sed -i 's/log("start")/log("start")\n\tlog("WBOX-gov-0a0a0a0a: mutant")/' $1/feed/batman-prov/src/node/n.go; }
gocomment(){ sed -i 's/log("start")/log("start") \/\/ WBOX-gocom-0b0b0b0b/' $1/feed/batman-prov/src/node/n.go; }
shgood(){ printf '#!/bin/sh\n# WBOX-shv-0c0c0c0c\necho mutant\n' > $1/feed/batman-provision/files/etc/uci-defaults/96-x; }
uci99(){ printf '#!/bin/sh\n# WBOX-ucix-0d0d0d0d\n' > $1/feed/batman-provision/files/etc/uci-defaults/$2; }
initx(){ printf '#!/bin/sh /etc/rc.common\n# WBOX-initx-0e0e0e0e\nSTART=99\n' > $1/feed/batman-provision/files/etc/init.d/$2; }
outside(){ echo WBOX-outv-0f0f0f0f > $1/feed/other/y; }
renamein(){ git -C $1 mv feed/other/y feed/batman-prov/y; echo WBOX-renv-1a1a1a1a >> $1/feed/batman-prov/y; }
lst(){ printf '%s\n' "$@" > $R/tests/wbox/helpers.list; }
run(){ out=$(bash $L $R 2>&1); rc=$?; }
want(){ local exp=$1 d=$2; run
	case "$exp" in
		PASS) [ $rc = 0 ] && ok=1 || ok=0 ;;
		*) [ $rc != 0 ] && case "$out" in *"$exp"*) ok=1 ;; *) ok=0 ;; esac || ok=0 ;;
	esac
	if [ $ok = 1 ]; then pass=$((pass+1)); echo "ok   $d"; else bad=$((bad+1)); echo "BAD  want [$exp]: $d — rc=$rc $(echo "$out" | tr '\n' ' ' | cut -c1-200)"; fi; }
R=$(mkrepo good)
mkpatch $R gov "go mutant" WBOX-gov-0a0a0a0a gogood $R
mkpatch $R shv "shell mutant" WBOX-shv-0c0c0c0c shgood $R
lst "test prov_test helper" "gov prov_test helper" "shv release same"
want PASS "good set (go + shell)"
lst "test prov_test helper" "gov release same" "shv release same";            want "helpers.list differs" "helpers.list: wrong tag for a src/ patch"
lst "test prov_test helper" "gov prov_test helper";                           want "helpers.list differs" "helpers.list: a patch missing from it"
lst "test prov_test helper" "gov prov_test helper" "shv release same" "x release same"; want "helpers.list differs" "helpers.list: an entry without a patch"
R=$(mkrepo empty); lst "test prov_test helper";                               want "no tests/wbox/*.patch at all" "no patch at all"
R=$(mkrepo wfmt); mkpatch $R shv "x" WBOX-shv-zz shgood $R; lst "test prov_test helper" "shv release same"; want "is not WBOX-shv-<8 hex>" "witness of the wrong format"
R=$(mkrepo wonce); mkpatch $R shv "x" WBOX-shv-0c0c0c0d shgood $R; lst "test prov_test helper" "shv release same"; want "witness appears < 2 times" "witness only in the header"
R=$(mkrepo gocom); mkpatch $R gocom "x" WBOX-gocom-0b0b0b0b gocomment $R; lst "test prov_test helper" "gocom prov_test helper"; want "outside a string literal" "go witness in a comment"
R=$(mkrepo noapply); mkpatch $R shv "x" WBOX-shv-0c0c0c0c shgood $R; echo changed > $R/feed/batman-provision/files/etc/uci-defaults/96-x; git -C $R -c user.email=t@t -c user.name=t commit -qam drift
lst "test prov_test helper" "shv release same"; want "does not apply" "patch no longer applies"
R=$(mkrepo outside); mkpatch $R outv "x" WBOX-outv-0f0f0f0f outside $R; lst "test prov_test helper" "outv release same"; want "touches feed/other/y" "patch outside the two packages"
R=$(mkrepo rename); mkpatch $R renv "x" WBOX-renv-1a1a1a1a renamein $R; lst "test prov_test helper" "renv release same"; want "renames / copies" "rename into the package (source outside)"
R=$(mkrepo uci); mkpatch $R ucix "x" WBOX-ucix-0d0d0d0d uci99 $R 99-wbox-ucix; lst "test prov_test helper" "ucix release same"; want "want 99zz-wbox-*" "new uci-defaults without the 99zz-wbox- prefix"
R=$(mkrepo uciok); mkpatch $R ucix "x" WBOX-ucix-0d0d0d0d uci99 $R 99zz-wbox-ucix; lst "test prov_test helper" "ucix release same"; want PASS "new uci-defaults 99zz-wbox-ucix"
R=$(mkrepo init); mkpatch $R initx "x" WBOX-initx-0e0e0e0e initx $R chanx; lst "test prov_test helper" "initx release same"; want "want wbox-*" "new init script without the wbox- prefix"
R=$(mkrepo hdr); mkpatch $R shv "x" WBOX-shv-0c0c0c0c shgood $R; sed -i '1s/.*/# something else/' $R/tests/wbox/shv.patch; lst "test prov_test helper" "shv release same"; want "first line is not" "missing '# wbox <name>:' header"
# ---- §23.9: protected set, misc scope, gate lines, busybox sh -n, nohold ----
prot(){ mkdir -p $1/feed/batman-provision/files/usr/lib/batman $1/feed/batman-provision/files/usr/bin
	printf '#!/bin/sh\notalog(){ :; }\n' > $1/feed/batman-provision/files/usr/lib/batman/otatrace.sh
	printf '#!/bin/sh\nWBOX_STATE=release\nlog(){ :; }\nlog "start"\ncase "$1" in\n\ta) echo a ;;\nesac\n' > $1/feed/batman-provision/files/usr/bin/batman-autocommit
	git -C $1 -c user.email=t@t -c user.name=t add -A; git -C $1 -c user.email=t@t -c user.name=t commit -qm prot; }
otaedit(){ printf '# WBOX-otav-2a2a2a2a\n' >> $1/feed/batman-provision/files/usr/lib/batman/otatrace.sh; }
miscok(){ sed -i 's/^log "start"$/log "start"\nlog "WBOX-misc-ok-2b2b2b2b"/' $1/feed/batman-provision/files/usr/bin/batman-autocommit; }
miscuci(){ printf '#!/bin/sh\n# WBOX-misc-uci-2c2c2c2c\n' > $1/feed/batman-provision/files/etc/uci-defaults/96-x; }
ucinames(){ printf '#!/bin/sh\n# WBOX-ucin-2d2d2d2d\nsed -i s/x/y/ /usr/bin/batman-autocommit\n' > $1/feed/batman-provision/files/etc/uci-defaults/99zz-wbox-ucin; }
ucibootf(){ printf '#!/bin/sh\n# WBOX-ucib-2e2e2e2e\necho x >> /boot/autoboot.txt\n' > $1/feed/batman-provision/files/etc/uci-defaults/99zz-wbox-ucib; }
miscgate(){ sed -i 's/^WBOX_STATE=release$/: WBOX-misc-gate-2f2f2f2f/' $1/feed/batman-provision/files/usr/bin/batman-autocommit; }
miscsyn(){ sed -i 's/^\ta) echo a ;;$/\ta) echo a ;;\n\techo WBOX-misc-syn-3a3a3a3a/' $1/feed/batman-provision/files/usr/bin/batman-autocommit; }
R=$(mkrepo prot1); prot $R; mkpatch $R otav "x" WBOX-otav-2a2a2a2a otaedit $R; lst "test prov_test helper" "otav release same"; want "touches the protected usr/lib/batman/otatrace.sh" "non-misc patch edits otatrace.sh (protected)"
R=$(mkrepo prot2); prot $R; mkpatch $R misc-ok "x" WBOX-misc-ok-2b2b2b2b miscok $R; lst "test prov_test helper" "misc-ok release same"; want PASS "misc-* edits batman-autocommit only"
R=$(mkrepo prot3); prot $R; mkpatch $R misc-uci "x" WBOX-misc-uci-2c2c2c2c miscuci $R; lst "test prov_test helper" "misc-uci release same"; want "a misc-* variant touches feed/batman-provision/files/etc/uci-defaults/96-x" "misc-* edits another file"
R=$(mkrepo prot4); prot $R; mkpatch $R ucin "x" WBOX-ucin-2d2d2d2d ucinames $R; lst "test prov_test helper" "ucin release same"; want "an added line names the protected batman-autocommit" "uci mutant whose added line names /usr/bin/batman-autocommit"
R=$(mkrepo prot5); prot $R; mkpatch $R ucib "x" WBOX-ucib-2e2e2e2e ucibootf $R; lst "test prov_test helper" "ucib release same"; want "an added line names the protected autoboot.txt" "uci mutant whose added line names autoboot.txt"
R=$(mkrepo prot6); prot $R; mkpatch $R misc-gate "x" WBOX-misc-gate-2f2f2f2f miscgate $R; lst "test prov_test helper" "misc-gate release same"; want "removes / changes / adds a wbox-gate line" "misc-* removes the WBOX_STATE line"
R=$(mkrepo prot7); prot $R; mkpatch $R misc-syn "x" WBOX-misc-syn-3a3a3a3a miscsyn $R; lst "test prov_test helper" "misc-syn release same"; want "does not parse in busybox sh" "a line inserted after ';;' (busybox sh -n)"
R=$(mkrepo nobb); prot $R; mkpatch $R misc-ok "x" WBOX-misc-ok-2b2b2b2b miscok $R; lst "test prov_test helper" "misc-ok release same"
mkdir -p $T/nobb; for d in /usr/local/bin /usr/bin /bin; do for c in "$d"/*; do [ -e "$c" ] || continue; b=${c##*/}; [ "$b" = busybox ] || [ -e "$T/nobb/$b" ] || ln -s "$c" "$T/nobb/$b"; done; done
out=$(PATH=$T/nobb bash $L $R 2>&1); rc=$?; [ $rc != 0 ] && case "$out" in *"no busybox"*) true ;; *) false ;; esac && { pass=$((pass+1)); echo "ok   no busybox on the host -> FAIL"; } || { bad=$((bad+1)); echo "BAD  no busybox: rc=$rc $out"; }
# review A-m2: a misc patch that ADDS a WBOX_STATE override, and one that disables the stamp detection (_wf)
miscadd(){ sed -i 's/^log "start"$/log "start"\nWBOX_STATE=release # WBOX-misc-add-3b3b3b3b/' $1/feed/batman-provision/files/usr/bin/batman-autocommit; }
miscwf(){ sed -i 's/^WBOX_STATE=release$/WBOX_STATE=release\n_wf=\/dev\/null # WBOX-misc-wf-3c3c3c3c/' $1/feed/batman-provision/files/usr/bin/batman-autocommit; }
R=$(mkrepo prot8); prot $R; mkpatch $R misc-add "x" WBOX-misc-add-3b3b3b3b miscadd $R; lst "test prov_test helper" "misc-add release same"; want "adds a wbox-gate line" "misc-* adds a WBOX_STATE override line"
R=$(mkrepo prot9); prot $R; mkpatch $R misc-wf "x" WBOX-misc-wf-3c3c3c3c miscwf $R; lst "test prov_test helper" "misc-wf release same"; want "adds a wbox-gate line" "misc-* repoints the stamp detection (_wf)"
# review A-m2: every member of the protected set, touched by a non-misc variant -> FAIL (one case each)
for q in usr/sbin/batman-slot usr/bin/batman-autocommit etc/init.d/batman-autocommit usr/lib/batman/otatrace.sh usr/lib/batman/rundir.sh usr/lib/batman/bootfacts.sh usr/lib/batman/meshjoin.sh; do
	n=pm$(echo "$q" | tr -dc 'a-z' | tail -c 9)
	R=$(mkrepo "$n"); prot $R; mkdir -p "$R/feed/batman-provision/files/$(dirname $q)"; [ -f "$R/feed/batman-provision/files/$q" ] || { printf '#!/bin/sh\n: base\n' > "$R/feed/batman-provision/files/$q"; git -C $R -c user.email=t@t -c user.name=t add -A; git -C $R -c user.email=t@t -c user.name=t commit -qm "$q"; }
	pmedit(){ printf ': WBOX-%s-4d4d4d4d\n' "$n" >> "$1/feed/batman-provision/files/$q"; }
	mkpatch $R "$n" "x" "WBOX-$n-4d4d4d4d" pmedit $R; lst "test prov_test helper" "$n release same"; want "touches the protected $q" "non-misc patch edits the protected $q"
done
# nohold: definition exempt, the unit allowed, any other call FAILs
R=$(mkrepo nh); prot $R; mkpatch $R misc-ok "x" WBOX-misc-ok-2b2b2b2b miscok $R; lst "test prov_test helper" "misc-ok release same"; mkdir -p $R/scripts/dv
printf 'pr_ota_b() {\n\tcase "$4" in nohold) hold=0 ;; esac\n}\n' > $R/scripts/dv/prov-254.sh
printf 'prov_wbox_nocommit_254() {\n\tpr_ota_b "$pl" "$sha" B nohold\n}\n' > $R/scripts/dv/prov-wbox-254.sh
want PASS "nohold in pr_ota_b() and in the unit prov_wbox_nocommit_254"
printf 'prov_other_254() {\n\tpr_ota_b "$pl" "$sha" B nohold\n}\n' > $R/scripts/dv/prov-other-254.sh
want "nohold used outside the unit prov-wbox-nocommit-254: scripts/dv/prov-other-254.sh:2" "a second nohold call in another unit"
rm $R/scripts/dv/prov-other-254.sh; printf 'pr_ota_b() {\n\t:\n}\nx() {\n\tpr_ota_b a b B nohold\n}\n' > $R/scripts/dv/prov-254.sh
want "nohold used outside the unit prov-wbox-nocommit-254: scripts/dv/prov-254.sh:5" "nohold in prov-254.sh outside pr_ota_b()"
echo "RESULT lint-wbox self-test: $pass ok, $bad bad"; [ $bad = 0 ] && [ $pass -gt 0 ]
