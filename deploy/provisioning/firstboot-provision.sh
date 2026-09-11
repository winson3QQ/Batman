#!/bin/sh
# firstboot-provision.sh — storage-provisioning SKELETON (#88).
#
# Validates the storage MECHANICS: carve the SD's free space into an (optionally
# LUKS-encrypted) expand-to-fill data partition, ext4, mount, persist across reboot —
# idempotently and safely.
#
# TWO MODES (auto-detected):
#   - LUKS mode      : dm-crypt + cryptsetup present  -> encrypted (placeholder key).
#   - MECHANICS-ONLY : dm-crypt/cryptsetup absent      -> **NO ENCRYPTION** (ext4 on the bare
#     partition). Validates partition/expand/mount/persist/idempotency without LUKS. The
#     OpenMANET 1.7.0 image lacks dm-crypt (no built-in, no matching kmod) -> the production
#     image must add CONFIG_DM_CRYPT to enable encryption at all (#47/#88). Loudly warned.
#
# SCOPE (skeleton): one data partition in the FREE SPACE (not the full GPT p1..p5 scheme, §B1);
#   no dm-verity (#74/B2); PLACEHOLDER key on rootfs when LUKS is used (theatre — real key =
#   secure element #47/B3, do NOT ship). Safe: only free space, never p1/p2, idempotent.
# TEST TARGET: a spare card (verify: NO p3, no FTS). NEVER the production node.
#
# Usage:  sh firstboot-provision.sh [--yes] | --status | --teardown --yes

set -e
DISK=/dev/mmcblk0
PART_NUM=3
PART=${DISK}p${PART_NUM}
LABEL=batdata
MAPPER=batdata_crypt
MOUNT=/opt/batdata
KEYFILE=/etc/batman-provision.key   # PLACEHOLDER (LUKS mode only). Real key = secure element (#47/B3).
INIT=/etc/init.d/batdata-mount

log(){ echo "[provision] $*"; }
die(){ echo "[provision] ABORT: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "must run as root"
[ -b "$DISK" ] || die "$DISK not a block device"
command -v parted >/dev/null 2>&1 || die "missing parted (opkg install parted)"
command -v mkfs.ext4 >/dev/null 2>&1 || die "missing mkfs.ext4 (opkg install e2fsprogs)"

# --- auto-detect LUKS capability ---
LUKS=0
if command -v cryptsetup >/dev/null 2>&1; then
  modprobe dm-crypt 2>/dev/null || true
  [ -e /dev/mapper/control ] && LUKS=1
fi
if [ "$LUKS" = 1 ]; then DEV="/dev/mapper/$MAPPER"; else DEV="$PART"; fi

PARTCOUNT=$(parted -sm "$DISK" print 2>/dev/null | grep -cE '^[0-9]+:')

# ext4-present check without blkid (dumpe2fs if available, else a probe mount)
has_ext4(){
  if command -v dumpe2fs >/dev/null 2>&1; then dumpe2fs -h "$1" >/dev/null 2>&1; return $?; fi
  mkdir -p /tmp/_pchk 2>/dev/null; if mount -t ext4 "$1" /tmp/_pchk 2>/dev/null; then umount /tmp/_pchk; return 0; fi; return 1
}

status(){
  echo "mode        : $([ "$LUKS" = 1 ] && echo 'LUKS (encrypted)' || echo 'MECHANICS-ONLY (NO ENCRYPTION)')"
  echo "disk        : $DISK   partitions: $PARTCOUNT"
  parted -s "$DISK" unit GB print free 2>/dev/null | sed 's/^/  /'
  [ -b "$PART" ] && echo "data part   : $PART exists" || echo "data part   : none yet"
  [ "$LUKS" = 1 ] && { cryptsetup isLuks "$PART" 2>/dev/null && echo "  LUKS       : yes" || echo "  LUKS       : no"; }
  mount | grep -q " $MOUNT " && echo "mounted     : yes ($(df -h "$MOUNT" | tail -1 | awk '{print $2" size,",$4" free"}'))" || echo "mounted     : no"
}

case "$1" in
  --status) status; exit 0 ;;
  --teardown)
    [ "$2" = "--yes" ] || die "teardown needs --yes (destroys $PART)"
    mount | grep -q " $MOUNT " && umount "$MOUNT" 2>/dev/null || true
    cryptsetup status "$MAPPER" >/dev/null 2>&1 && cryptsetup close "$MAPPER" 2>/dev/null || true
    [ -x "$INIT" ] && { "$INIT" disable 2>/dev/null || true; rm -f "$INIT"; }
    [ -b "$PART" ] && parted -s "$DISK" rm "$PART_NUM" 2>/dev/null || true
    rm -f "$KEYFILE"; log "teardown done"; exit 0 ;;
esac

[ "$1" = "--yes" ] || { log "DRY RUN — pass --yes to apply."; status; exit 0; }
[ "$LUKS" = 1 ] || log "!!! MECHANICS-ONLY MODE: NO ENCRYPTION (dm-crypt unavailable on this image) !!!"

# --- 1. partition (idempotent, free space only) ---
if [ -b "$PART" ]; then
  log "$PART exists — skip create (idempotent)"
else
  [ "$PARTCOUNT" -eq 2 ] || die "expected exactly p1+p2+free before provisioning; found $PARTCOUNT partitions — refusing (safety)"
  # machine format free line: ':<start>s:<end>s:<size>s:free;' -> start=$2, size=$4.
  # pick the LARGEST free region (the big tail after p2), take its start sector.
  START=$(parted -sm "$DISK" unit s print free 2>/dev/null | awk -F: '/free;?$/{s=$2; sz=$4; gsub("s","",sz); if(sz+0>best){best=sz+0; bs=$2}} END{gsub("s","",bs); print bs}')
  [ -n "$START" ] && [ "$START" -gt 0 ] 2>/dev/null || die "no usable free-space start found (got '$START')"
  log "creating $PART ${START}s..100% (expand-to-fill)"
  parted -s "$DISK" mkpart primary ext4 "${START}s" 100%
  sleep 2; [ -b "$PART" ] || { partprobe "$DISK" 2>/dev/null || true; sleep 2; }
  [ -b "$PART" ] || die "$PART not visible after mkpart — reboot then re-run"
fi

# --- 2. LUKS (only if capable; idempotent) ---
if [ "$LUKS" = 1 ]; then
  [ -f "$KEYFILE" ] || { log "gen PLACEHOLDER key (real key = SE #47)"; dd if=/dev/urandom of="$KEYFILE" bs=512 count=1 2>/dev/null; chmod 600 "$KEYFILE"; }
  cryptsetup isLuks "$PART" 2>/dev/null || { log "luksFormat $PART"; cryptsetup luksFormat --type luks2 --batch-mode --key-file "$KEYFILE" "$PART"; }
  cryptsetup status "$MAPPER" >/dev/null 2>&1 || { log "luksOpen -> $DEV"; cryptsetup open --key-file "$KEYFILE" "$PART" "$MAPPER"; }
fi

# --- 3. ext4 (idempotent) ---
if has_ext4 "$DEV"; then log "ext4 present on $DEV — skip mkfs"; else log "mkfs.ext4 $DEV (fills partition = card size)"; mkfs.ext4 -F -L "$LABEL" -m 0 "$DEV"; fi

# --- 4. mount ---
mkdir -p "$MOUNT"
mount | grep -q " $MOUNT " || { log "mount $DEV -> $MOUNT"; mount "$DEV" "$MOUNT"; }
echo "provisioned $(date) mode=$([ "$LUKS" = 1 ] && echo luks || echo plain)" > "$MOUNT/PROVISION_MARKER" 2>/dev/null || true

# --- 5. persist across reboot ---
if [ ! -x "$INIT" ]; then
  log "installing boot hook $INIT"
  cat > "$INIT" <<EOF
#!/bin/sh /etc/rc.common
# batdata-mount (#88 skeleton). LUKS mode uses a PLACEHOLDER key on rootfs — replace with
# SE-sealed release (#47/B3) before production. Mount-only: the production init (with
# crash/boot-reason capture) is generated by uci-defaults/95-batman-storage — that is the SoT.
START=11   # before logd (S12), same slot as production
STOP=10
boot() {
    [ -b "$PART" ] || return 0
    if [ "$LUKS" = 1 ]; then
        cryptsetup status "$MAPPER" >/dev/null 2>&1 || cryptsetup open --key-file "$KEYFILE" "$PART" "$MAPPER" 2>/dev/null
    fi
    mkdir -p "$MOUNT"
    mount | grep -q " $MOUNT " || mount "$DEV" "$MOUNT" 2>/dev/null
    logger -t batdata-mount "mounted $DEV on $MOUNT"
}
start() { boot; }
stop() {
    mount | grep -q " $MOUNT " && umount "$MOUNT" 2>/dev/null
    [ "$LUKS" = 1 ] && cryptsetup status "$MAPPER" >/dev/null 2>&1 && cryptsetup close "$MAPPER" 2>/dev/null
    true
}
EOF
  chmod +x "$INIT"; "$INIT" enable 2>/dev/null || true
fi

log "DONE."
status
