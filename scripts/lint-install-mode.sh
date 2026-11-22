#!/bin/bash
# scripts/lint-install-mode.sh [repo] — #254 L75: every file a feed package installs with $(INSTALL_BIN) ./files/<path>
# is git mode 100755 in the repo (the image is right either way — INSTALL_BIN sets 0755 — but a 644 script in the repo
# is wrong for anyone running it from a checkout and hides which files are executables). Zero INSTALL_BIN lines = FAIL.
# Negative control: main 4b61b3c -> FAIL listing 41 files.
set -u
ROOT=$(cd "${1:-$(dirname "$0")/..}" && pwd); cd "$ROOT" || exit 2
n=0; bad=0
# the source path = everything between "./files/" and " $(1)/"; a conditional name ($(if $(filter …),-test)) counts
# both ways, with and without its text
names(){
	sed -n 's#^[[:space:]]*\$(INSTALL_BIN) \./files/\(.*[^[:space:]]\)[[:space:]][[:space:]]*\$(1)/.*#\1#p' "$1" | perl -ne '
		chomp;
		if (/\$\(if /) {
			(my $with = $_) =~ s/\$\(if .*?\),([^)]*)\)/$1/;
			(my $without = $_) =~ s/\$\(if .*?\),[^)]*\)//;
			print "$with\n$without\n";
		} else { print "$_\n" }' | sort -u
}
for mk in feed/*/Makefile; do
	d=${mk%/Makefile}
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		n=$((n + 1)); m=$(git ls-files -s "$d/files/$f" | awk '{print $1}')
		case "$m" in
			100755) ;;
			'') echo "MISSING $d/files/$f (installed by $mk, not in git)"; bad=$((bad + 1)) ;;
			*) echo "MODE $m $d/files/$f (installed with INSTALL_BIN: want 100755 — git update-index --chmod=+x)"; bad=$((bad + 1)) ;;
		esac
	done < <(names "$mk")
done
echo "LINT-INSTALL-MODE files=$n bad=$bad"
[ $n -gt 0 ] && [ $bad = 0 ]
