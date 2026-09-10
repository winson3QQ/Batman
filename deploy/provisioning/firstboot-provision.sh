#!/bin/sh
# firstboot-provision.sh — storage-provisioning SKELETON (#88).
#
# Validates the storage MECHANICS on a spare card: carve the SD's free space into a
# LUKS-encrypted, expand-to-fill data partition, make ext4, mount it, and persist across
# reboot — idempotently and safely.
#
# SCOPE (skeleton — mechanics only):
#   IN : partition-in-free-space, LUKS format/open, mkfs.ext4, expand-to-fill, mount, reboot
#        persistence, idempotency, safety (never touch p1/p2).
#   OUT: - GPT 5-partition scheme (this makes ONE data partition in the free space; the full
#          p1..p5 GPT layout is the next layer — see docs/storage-architecture.md §B1).
#        - dm-verity signed rootfs (B2 / #74).
#        - REAL key sealing (B3 / #47). This uses a PLACEHOLDER keyfile on the rootfs — that
#          is exactly the "encryption is theatre if the key is on the device" case; it is
#          fine for validating LUKS *mechanics* but MUST NOT ship. Real key = SE-sealed (#47).
#
# TEST TARGET: a spare card booted on manet01's Pi (its own card set aside). NEVER manet02.
#
# Usage:  sh firstboot-provision.sh [--yes]        provision (idempotent)
#         sh firstboot-provision.sh --status       show state
#         sh firstboot-provision.sh --teardown --yes   undo (drop the data partition)  [test only]

set -e
DISK=/dev/mmcblk0
PART_NUM=3                     # first free primary after OpenMANET's p1(boot)+p2(root)
PART=${DISK}p${PART_NUM}
LABEL=batdata
MAPPER=batdata_crypt
MOUNT=/opt/batdata
KEYFILE=/etc/batman-provision.key   # PLACEHOLDER key (skeleton). Real key = secure element (#47/B3).
INIT=/etc/init.d/batdata-mount

log(){ echo "[provision] $*"; }
die(){ echo "[provision] ABORT: $*" >&2; exit 1; }

# ---------------------------------------------------------------- safety + deps
[ "$(id -u)" = 0 ] || die "must run as root"
[ -b "$DISK" ] || die "$DISK not a block device"
for t in parted cryptsetup mkfs.ext4 blkid; do
  command -v "$t" >/dev/null 2>&1 || die "missing tool: $t  (opkg update && opkg install parted cryptsetup e2fsprogs)"
done
# refuse to run unless the disk looks like the expected OpenMANET card: exactly p1 + p2,
# free space after, and p1/p2 are NOT what we will create.
PARTCOUNT=$(parted -sm "$DISK" print 2>/dev/null | grep -cE '^[0-9]+:')

status(){
  echo "disk        : $DISK"
  echo "partitions  : $PARTCOUNT"
  parted -s "$DISK" unit GB print free 2>/dev/null | sed 's/^/  /'
  if [ -b "$PART" ]; then
    echo "data part   : $PART exists"
    cryptsetup isLuks "$PART" 2>/dev/null && echo "  LUKS       : yes" || echo "  LUKS       : NO"
  else
    echo "data part   : none yet"
  fi
  mount | grep -q " $MOUNT " && echo "mounted     : yes ($(df -h "$MOUNT" | tail -1 | awk '{print $1,$4" free"}'))" || echo "mounted     : no"
}

case "$1" in
  --status) status; exit 0 ;;
  --teardown)
    [ "$2" = "--yes" ] || die "teardown needs --yes (test only; destroys $PART)"
    log "teardown: unmount, close, remove init + partition"
    mount | grep -q " $MOUNT " && umount "$MOUNT" 2>/dev/null || true
    cryptsetup status "$MAPPER" >/dev/null 2>&1 && cryptsetup close "$MAPPER" 2>/dev/null || true
    [ -x "$INIT" ] && { "$INIT" disable 2>/dev/null || true; rm -f "$INIT"; }
    [ -b "$PART" ] && parted -s "$DISK" rm "$PART_NUM" 2>/dev/null || true
    rm -f "$KEYFILE"
    log "teardown done"; exit 0 ;;
esac

[ "$1" = "--yes" ] || { log "DRY RUN — pass --yes to apply. Current state:"; status; exit 0; }

# ---------------------------------------------------------------- 1. placeholder key
if [ ! -f "$KEYFILE" ]; then
  log "generating PLACEHOLDER key $KEYFILE (skeleton only — real key = secure element #47)"
  dd if=/dev/urandom of="$KEYFILE" bs=512 count=1 2>/dev/null
  chmod 600 "$KEYFILE"
fi

# ---------------------------------------------------------------- 2. partition (idempotent, free space only)
if [ -b "$PART" ]; then
  log "$PART already exists — skipping create (idempotent)"
else
  [ "$PARTCOUNT" -eq 2 ] || die "expected exactly 2 partitions (p1 boot, p2 root) before provisioning; found $PARTCOUNT — refusing to guess (safety)"
  # start at the first free sector after p2; end at 100% => EXPAND-TO-FILL whatever the card size
  START=$(parted -sm "$DISK" unit s print free 2>/dev/null | awk -F: '/free/{gsub("s","",$1); s=$1} END{print s}')
  [ -n "$START" ] || die "could not find free-space start"
  log "creating $PART from ${START}s to 100% (expand-to-fill)"
  parted -s "$DISK" mkpart primary ext4 "${START}s" 100%
  # settle: kernel may need a moment / re-read
  sleep 2; [ -b "$PART" ] || { partprobe "$DISK" 2>/dev/null || true; sleep 2; }
  [ -b "$PART" ] || die "$PART did not appear after mkpart (may need reboot for the kernel to re-read; re-run after reboot)"
fi

# ---------------------------------------------------------------- 3. LUKS (idempotent)
if cryptsetup isLuks "$PART" 2>/dev/null; then
  log "$PART already LUKS — skipping format"
else
  log "LUKS-formatting $PART (placeholder key)"
  cryptsetup luksFormat --type luks2 --batch-mode --key-file "$KEYFILE" "$PART"
fi
cryptsetup status "$MAPPER" >/dev/null 2>&1 || {
  log "opening LUKS -> /dev/mapper/$MAPPER"
  cryptsetup open --key-file "$KEYFILE" "$PART" "$MAPPER"
}

# ---------------------------------------------------------------- 4. ext4 (idempotent)
if blkid "/dev/mapper/$MAPPER" 2>/dev/null | grep -q 'TYPE="ext4"'; then
  log "ext4 already present on mapper — skipping mkfs"
else
  log "mkfs.ext4 on /dev/mapper/$MAPPER (fills the whole partition = card size)"
  mkfs.ext4 -F -L "$LABEL" -m 0 "/dev/mapper/$MAPPER"
fi

# ---------------------------------------------------------------- 5. mount
mkdir -p "$MOUNT"
mount | grep -q " $MOUNT " || { log "mounting -> $MOUNT"; mount "/dev/mapper/$MAPPER" "$MOUNT"; }
echo "provisioned $(date)" > "$MOUNT/PROVISION_MARKER" 2>/dev/null || true

# ---------------------------------------------------------------- 6. persist across reboot
if [ ! -x "$INIT" ]; then
  log "installing boot hook $INIT (unlock + mount on boot, placeholder key)"
  cat > "$INIT" <<EOF
#!/bin/sh /etc/rc.common
# batdata-mount (#88 skeleton): unlock the LUKS data partition + mount on boot.
# Placeholder key on rootfs — replace with SE-sealed release (#47/B3) before production.
START=78
STOP=10
boot() {
    [ -b "$PART" ] || return 0
    cryptsetup status "$MAPPER" >/dev/null 2>&1 || cryptsetup open --key-file "$KEYFILE" "$PART" "$MAPPER" 2>/dev/null
    mkdir -p "$MOUNT"
    mount | grep -q " $MOUNT " || mount "/dev/mapper/$MAPPER" "$MOUNT" 2>/dev/null
    logger -t batdata-mount "unlocked+mounted $PART on $MOUNT"
}
start() { boot; }
stop() {
    mount | grep -q " $MOUNT " && umount "$MOUNT" 2>/dev/null
    cryptsetup status "$MAPPER" >/dev/null 2>&1 && cryptsetup close "$MAPPER" 2>/dev/null
}
EOF
  chmod +x "$INIT"; "$INIT" enable 2>/dev/null || true
fi

log "DONE."
status
