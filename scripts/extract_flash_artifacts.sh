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

for cmd in qemu-img parted dd truncate awk sort stat hexdump; do
  command -v "$cmd" >/dev/null || { echo "Missing required command: $cmd"; exit 1; }
done

mkdir -p "$OUTDIR"

RAW="$(mktemp --suffix=.raw)"
LOOP_DEV=""
cleanup() {
  if [[ -n "$LOOP_DEV" ]]; then
    losetup -d "$LOOP_DEV" >/dev/null 2>&1 || true
  fi
  rm -f "$RAW"
}
trap cleanup EXIT

echo "[*] Converting qcow2 → raw"
qemu-img convert -f qcow2 -O raw "$QCOW2" "$RAW"

echo "[*] Reading partition table"
PARTED_TARGET="$RAW"
set +e
PARTED_OUT=$(parted -s "$PARTED_TARGET" unit B print 2>&1)
PARTED_RC=$?
set -e

if [[ $PARTED_RC -ne 0 ]]; then
  echo "$PARTED_OUT"

  # Some images are partitioned for 4096-byte logical sectors (GPT header at
  # byte offset 4096), which parted cannot parse directly from a regular file.
  # Retry through a read-only loop device with 4K logical sectors.
  if [[ "$PARTED_OUT" == *"unrecognised disk label"* ]]; then
    command -v losetup >/dev/null || {
      echo "[!] Failed to parse partition table and 'losetup' is missing"
      exit 1
    }
    [[ $EUID -eq 0 ]] || {
      echo "[!] Failed to parse partition table from raw file"
      echo "    This image likely uses 4096-byte logical sectors."
      echo "    Re-run as root (or with sudo) to enable 4K loop-device probing."
      exit 1
    }

    echo "[*] Retrying partition table read via 4K-sector loop device"
    LOOP_DEV=$(losetup --find --show --read-only --sector-size 4096 "$RAW")
    PARTED_TARGET="$LOOP_DEV"
    PARTED_OUT=$(parted -s "$PARTED_TARGET" unit B print)
  else
    echo "[!] Failed to read partition table"
    exit 1
  fi
fi

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
echo "    EFI    : $OUTDIR/efi.bin    (signature ok)"
echo "    rootfs : $OUTDIR/rootfs.img ($ROOT_FS)"
echo
echo "[✓] Images are FLASHABLE AS-IS"
