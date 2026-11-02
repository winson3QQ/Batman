#!/bin/bash
# tests/prov-p1/prov-base-names.sh — offline test of prov-base tree_manifest (review A-m10): a manifest line is
# "<fields> <path>" and overlay-restore takes the LAST field, so a path name with a space / tab / newline must not be
# written as an ordinary line (it would name another path, which the restore would rm -rf): it is a BADNAME line and a
# non-zero rc. $1 = prov-base-254.sh. The function runs under busybox sh when there is one (the node's shell).
# No root, no network. Zero cases = FAIL.
PB=${1:?usage: prov-base-names.sh <prov-base-254.sh>}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; n=0; f=0
sed -n '/^tree_manifest() {/,/^}/p' "$PB" > "$T/fn.sh"
grep -q '^tree_manifest() {' "$T/fn.sh" || { echo "FAIL no tree_manifest in $PB"; exit 1; }
SH="sh"; command -v busybox >/dev/null 2>&1 && SH="busybox sh"
tm(){ $SH -c '. "$1"; tree_manifest "$2"' _ "$T/fn.sh" "$1" > "$T/out" 2>&1; echo $?; }
want(){ n=$((n + 1)); if [ "$2" = yes ]; then echo "ok   $1"; else echo "FAIL $1"; sed 's/^/     | /' "$T/out" | head -8; f=$((f + 1)); fi; }
mk(){ rm -rf "$T/r"; mkdir -p "$T/r/etc/config" "$T/r/usr/bin"; echo a > "$T/r/etc/config/system"; ln -s /bin/busybox "$T/r/usr/bin/x"; }
mk; rc=$(tm "$T/r")
want "clean tree: rc 0, no BADNAME, every last field is a real path" "$([ "$rc" = 0 ] && ! grep -q BADNAME "$T/out" && [ "$(wc -l < "$T/out")" = 6 ] && awk '{print $NF}' "$T/out" | while read -r p; do [ -e "$T/r/$p" ] || [ -L "$T/r/$p" ] || echo bad; done | grep -q bad || echo yes)"
mk; echo s > "$T/r/etc/sp ace"; rc=$(tm "$T/r")
want "a name with a space: BADNAME + rc != 0, never an ordinary line ending in 'ace'" "$([ "$rc" != 0 ] && grep -q '^BADNAME etc/sp ace$' "$T/out" && ! grep -v '^BADNAME' "$T/out" | grep -q ' ace$' && echo yes)"
mk; echo t > "$T/r/etc/tab"$'\t'"x"; rc=$(tm "$T/r")
want "a name with a tab: BADNAME + rc != 0" "$([ "$rc" != 0 ] && grep -q '^BADNAME etc/tab' "$T/out" && echo yes)"
mk; mkdir "$T/r/etc/nl"$'\n'"zzq"; rc=$(tm "$T/r")   # not $(printf): it strips the newline
want "a name with a newline: BADNAME for its pieces + rc != 0, no ordinary line for 'zzq'" "$([ "$rc" != 0 ] && grep -q '^BADNAME' "$T/out" && ! grep -v '^BADNAME' "$T/out" | awk '{print $NF}' | grep -qx zzq && echo yes)"
mk; mkdir "$T/r/etc/sp dir"; echo i > "$T/r/etc/sp dir/inner"; rc=$(tm "$T/r")
want "a directory with a space: it and its children are BADNAME + rc != 0" "$([ "$rc" != 0 ] && [ "$(grep -c '^BADNAME etc/sp dir' "$T/out")" = 2 ] && echo yes)"
echo "PROV-BASE-NAMES shell=[$SH] cases=$n fails=$f"; [ "$n" -gt 0 ] && [ "$f" = 0 ]
