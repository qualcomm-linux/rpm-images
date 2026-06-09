#!/usr/bin/env bash
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 <input.qcow2> [output_dir]"
  exit 1
fi

QCOW2="$1"
OUTDIR="${2:-output}"

for cmd in qemu-img parted dd truncate awk sort stat hexdump mkfs.vfat mcopy; do
  command -v "$cmd" >/dev/null || { echo "Missing required command: $cmd"; exit 1; }
done

# UFS devices use 4096-byte logical sectors.  The Linux FAT driver requires
# BPB bytes-per-sector >= device logical block size, so an image built with
# the default 512-byte sectors will fail to mount on UFS with:
#   "FAT: logical sector size too small for device (logical sector size = 512)"
# This function rebuilds the FAT image in-place with 4096-byte sectors while
# preserving every file already present in the image.
EFI_SECTOR_SIZE=4096
reformat_efi_for_ufs() {
  local img="$1"

  # Read current BPB bytes-per-sector (offset 11, 2 bytes LE)
  local cur_bps
  cur_bps=$(dd if="$img" bs=1 skip=11 count=2 2>/dev/null | hexdump -e '1/2 "%u\n"')
  if [[ "$cur_bps" -eq "$EFI_SECTOR_SIZE" ]]; then
    echo "[*] EFI image already has ${EFI_SECTOR_SIZE}-byte sectors — skipping reformat"
    return 0
  fi

  echo "[*] Reformatting EFI image: ${cur_bps}-byte -> ${EFI_SECTOR_SIZE}-byte sectors (UFS)"

  local img_size img_kib tmpdir
  img_size=$(stat -c '%s' "$img")
  img_kib=$(( img_size / 1024 ))
  tmpdir=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$tmpdir'" RETURN

  # Preserve the original FAT volume serial (4 bytes at BPB offset 67, LE).
  # Linux exposes this as the partition UUID in /dev/disk/by-uuid (format HI-LO)
  # and osbuild writes it into /etc/fstab.  mkfs.vfat assigns a new random
  # serial, which would make the fstab UUID stale and prevent /boot/efi from
  # mounting.  We read the original bytes and patch them back after mkfs.vfat.
  local orig_serial_hex
  orig_serial_hex=$(dd if="$img" bs=1 skip=67 count=4 2>/dev/null | hexdump -e '4/1 "%02x"')
  echo "[*] Preserving original FAT volume serial: ${orig_serial_hex}"

  export MTOOLS_SKIP_CHECK=1

  # Stage 1: copy all files out of the existing image recursively
  mcopy -vsmn -i "$img" '::*' "$tmpdir/" 2>/dev/null || true

  # Stage 2: recreate the image with 4096-byte sectors (same total size).
  # mkfs.vfat -C refuses to overwrite an existing file, so write to a temp
  # path then atomically replace the original.
  local new_img="${img}.reformat.$$"
  mkfs.vfat -S "$EFI_SECTOR_SIZE" -F 32 -n "ESP" -C "$new_img" "$img_kib"
  mv -f "$new_img" "$img"

  # Stage 2b: restore the original volume serial at BPB offset 67 so that
  # /dev/disk/by-uuid/<UUID> still matches what osbuild wrote into /etc/fstab.
  printf "\\x${orig_serial_hex:0:2}\\x${orig_serial_hex:2:2}\\x${orig_serial_hex:4:2}\\x${orig_serial_hex:6:2}" \
    | dd of="$img" bs=1 seek=67 count=4 conv=notrunc 2>/dev/null

  # Stage 3: copy files back preserving directory structure
  if [[ -n "$(ls -A "$tmpdir" 2>/dev/null)" ]]; then
    mcopy -vsmp -i "$img" "$tmpdir"/* ::/ 2>/dev/null || true
  fi

  # Verify new BPB sector size and that the serial was restored
  local new_bps new_serial_hex
  new_bps=$(dd if="$img" bs=1 skip=11 count=2 2>/dev/null | hexdump -e '1/2 "%u\n"')
  new_serial_hex=$(dd if="$img" bs=1 skip=67 count=4 2>/dev/null | hexdump -e '4/1 "%02x"')
  if [[ "$new_bps" -ne "$EFI_SECTOR_SIZE" ]]; then
    echo "[!] Reformat verification failed: BPB bytes-per-sector = $new_bps (expected $EFI_SECTOR_SIZE)"
    exit 1
  fi
  if [[ "$new_serial_hex" != "$orig_serial_hex" ]]; then
    echo "[!] Volume serial restore failed: got $new_serial_hex (expected $orig_serial_hex)"
    exit 1
  fi
  echo "[*] EFI image reformatted successfully (${EFI_SECTOR_SIZE}-byte sectors, UUID preserved)"
}

mkdir -p "$OUTDIR"

RAW="$(mktemp --suffix=.raw)"
cleanup() { rm -f "$RAW"; }
trap cleanup EXIT

echo "[*] Converting qcow2 → raw"
qemu-img convert -f qcow2 -O raw "$QCOW2" "$RAW"

echo "[*] Reading partition table"
PARTED_OUT=$(parted -s "$RAW" unit B print)
echo "$PARTED_OUT"

# --- choose a safe, fast block size ---
# 1MiB is typically the alignment used by image-builder/osbuild GPT layouts.
BS=$((1024*1024))

# Extract partition by part number using byte-accurate start (requires start % BS == 0)
extract_part_aligned() {
  local part="$1"
  local out="$2"

  local start size
  start=$(echo "$PARTED_OUT" | awk -v p="$part" '$1==p {gsub("B","",$2); print $2}')
  size=$(echo "$PARTED_OUT"  | awk -v p="$part" '$1==p {gsub("B","",$4); print $4}')

  [[ -z "$start" || -z "$size" ]] && return 1

  if (( start % BS != 0 )); then
    # Fallback: sector-based exact extraction (still reasonably fast)
    local SECTOR=512
    local skip_sectors=$(( start / SECTOR ))
    local count_sectors=$(( size / SECTOR ))
    echo "[*] Partition $part not aligned to ${BS}B; falling back to 512B sectors"
    dd if="$RAW" of="$out" bs=$SECTOR skip=$skip_sectors count=$count_sectors status=progress
    return 0
  fi

  local skip_blocks=$(( start / BS ))
  local count_blocks=$(( (size + BS - 1) / BS ))

  echo "[*] Extracting partition $part → $(basename "$out") (bs=${BS})"
  dd if="$RAW" of="$out" bs=$BS skip=$skip_blocks count=$count_blocks status=progress
  truncate -s "$size" "$out"
}

# EFI partition: pick partition with "esp" flag; fallback to p1
EFI_PART=$(echo "$PARTED_OUT" | awk '/esp/ {print $1; exit}')
EFI_PART="${EFI_PART:-1}"

# rootfs partition: pick largest partition that is not the EFI partition
ROOT_PART=$(echo "$PARTED_OUT" \
  | awk -v efi="$EFI_PART" 'NR>2 && $1 ~ /^[0-9]+$/ && $1 != efi {gsub("B","",$4); print $1, $4}' \
  | sort -k2 -n \
  | tail -n1 \
  | awk '{print $1}')

[[ -z "$ROOT_PART" ]] && { echo "[!] Failed to identify rootfs partition"; exit 1; }

# Extract
extract_part_aligned "$EFI_PART"  "$OUTDIR/efi.bin"   || { echo "[!] EFI partition not found"; exit 1; }
extract_part_aligned "$ROOT_PART" "$OUTDIR/rootfs.img" || { echo "[!] rootfs partition not found"; exit 1; }

# Reformat the EFI image with 4096-byte sectors so it mounts on UFS devices.
# osbuild produces FAT32 with 512-byte BPB sectors (standard PC default), but
# the QCS6490 UFS has 4096-byte logical blocks and the Linux FAT driver rejects
# images where BPB bytes-per-sector < device logical block size.
reformat_efi_for_ufs "$OUTDIR/efi.bin"

# -----------------------------
# Sanity checks (no mount)
# -----------------------------

echo "[*] Sanity check: EFI (layout + signature)"
EFI_SIZE=$(stat -c %s "$OUTDIR/efi.bin")
if [[ "$EFI_SIZE" -lt $((32*1024*1024)) ]]; then
  echo "[!] EFI sanity failed: too small (${EFI_SIZE} bytes)"
  exit 1
fi

# Boot sector signature 0x55AA at offset 510
EFI_SIG=$(dd if="$OUTDIR/efi.bin" bs=1 skip=510 count=2 2>/dev/null | hexdump -e '2/1 "%02x"')
if [[ "$EFI_SIG" != "55aa" ]]; then
  echo "[!] EFI sanity failed: missing 0x55AA boot signature (got $EFI_SIG)"
  exit 1
fi

# Verify BPB bytes-per-sector matches UFS requirement
EFI_BPS=$(dd if="$OUTDIR/efi.bin" bs=1 skip=11 count=2 2>/dev/null | hexdump -e '1/2 "%u\n"')
if [[ "$EFI_BPS" -ne "$EFI_SECTOR_SIZE" ]]; then
  echo "[!] EFI sanity failed: BPB bytes-per-sector=$EFI_BPS (expected $EFI_SECTOR_SIZE for UFS)"
  exit 1
fi

echo "[*] Sanity check: rootfs (detect ext4/xfs by magic)"

# ext4 magic 0xEF53 at offset 1024+56 = 1080
EXT4_MAGIC=$(dd if="$OUTDIR/rootfs.img" bs=1 skip=1080 count=2 2>/dev/null | hexdump -e '2/1 "%02x"')
# xfs magic "XFSB" at offset 0
XFS_MAGIC=$(dd if="$OUTDIR/rootfs.img" bs=1 count=4 2>/dev/null)

ROOT_FS="unknown"
if [[ "$EXT4_MAGIC" == "53ef" ]]; then
  ROOT_FS="ext4"
  # Now dumpe2fs should succeed
  command -v dumpe2fs >/dev/null || { echo "Missing dumpe2fs (e2fsprogs)"; exit 1; }
  dumpe2fs -h "$OUTDIR/rootfs.img" >/dev/null 2>&1 || {
    echo "[!] ext4 superblock present but dumpe2fs failed unexpectedly"
    exit 1
  }
elif [[ "$XFS_MAGIC" == "XFSB" ]]; then
  ROOT_FS="xfs"
  command -v xfs_repair >/dev/null || { echo "Missing xfs_repair (xfsprogs)"; exit 1; }
  xfs_repair -n "$OUTDIR/rootfs.img" >/dev/null 2>&1 || {
    echo "[!] xfs magic present but xfs_repair -n failed"
    exit 1
  }
else
  echo "[!] rootfs sanity failed: neither ext4 nor xfs magic found"
  echo "    Debug: first 64 bytes:"
  dd if="$OUTDIR/rootfs.img" bs=1 count=64 2>/dev/null | hexdump -C
  exit 1
fi

echo
echo "[✓] SUCCESS"
echo "    EFI    : $OUTDIR/efi.bin    (signature ok, ${EFI_SECTOR_SIZE}-byte sectors)"
echo "    rootfs : $OUTDIR/rootfs.img ($ROOT_FS)"
echo
echo "[✓] Images are FLASHABLE AS-IS (UFS 4K-sector compatible)"
