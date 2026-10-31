# shellcheck shell=bash
# scripts/lib/wbox-stamp.sh — #254 (code review B-M2 / A-m3): the card writers refuse a -wbox TEST rootfs. Slot A of a
# new card boots committed, so a wbox image written to a card would be the default from its first boot, past every
# node-side gate (batman-slot commit / rollback, autocommit). Same rule as batman-slot wbox_stamp: BATMAN_WBOX=<non-
# empty>, or a BATMAN_VERSION naming .wbox-, is a wbox image. The stamp is EXTRACTED (unsquashfs -d), never `-cat`:
# a symlinked stamp must not be followed into some other file.
#   card_wbox_check <squashfs> strict|lenient   rc 0 = may be written; otherwise prints the refusal, rc 1
#     strict   (build-ab-image.sh) an unreadable stamp is refused too: cards are built only from stamped images
#     lenient  (build-gpt-ab-card.sh: migrating a v1.1 node's own p2 dump, which predates the stamp) only a readable
#              wbox stamp is refused
card_wbox_check(){
	local sq=$1 mode=$2 t f s
	case "$mode" in strict|lenient) ;; *) echo "card_wbox_check: bad mode [$mode]"; return 1 ;; esac
	command -v unsquashfs >/dev/null || { echo "refusing: no unsquashfs (squashfs-tools) to read the image stamp of $sq"; return 1; }
	t=$(mktemp -d) || { echo "refusing: no temp dir"; return 1; }
	unsquashfs -q -no-xattrs -d "$t/r" "$sq" etc/batman-build >/dev/null 2>&1
	f=$t/r/etc/batman-build
	if [ -f "$f" ] && [ ! -L "$f" ] && grep -q '^BATMAN_VERSION=' "$f"; then
		s=$(cat "$f"); rm -rf "$t"
		if grep -q '^BATMAN_WBOX=.' <<< "$s" || sed -n 's/^BATMAN_VERSION=//p' <<< "$s" | grep -q '\.wbox-'; then
			echo "refusing: $sq is a -wbox TEST image ($(sed -n 's/^BATMAN_VERSION=//p' <<< "$s")) — never written to a card"
			return 1
		fi
		return 0
	fi
	rm -rf "$t"
	if [ "$mode" = lenient ]; then
		# no stamp to judge by: the whole image must carry no wbox witness string either (code review r2 B-n5)
		t=$(mktemp -d) || { echo "refusing: no temp dir"; return 1; }
		unsquashfs -q -no-xattrs -d "$t/r" "$sq" >/dev/null 2>&1
		[ -d "$t/r" ] || { rm -rf "$t"; echo "refusing: cannot extract $sq to look for wbox witness strings"; return 1; }
		s=$(grep -rlaE 'WBOX-[a-z0-9-]+-[0-9a-f]{8}' "$t/r" 2>/dev/null | head -3); rm -rf "$t"
		[ -z "$s" ] || { echo "refusing: $sq has no build stamp and carries wbox witness strings (${s##*/r/}) — never written to a card"; return 1; }
		echo "note: $sq has no readable build stamp (a pre-stamp image) and no wbox witness — written"; return 0
	fi
	echo "refusing: no readable etc/batman-build in $sq (a regular file with BATMAN_VERSION=) — a card is written only from a stamped image"
	return 1
}
