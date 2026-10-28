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
echo "RESULT lint-wbox self-test: $pass ok, $bad bad"; [ $bad = 0 ] && [ $pass -gt 0 ]
