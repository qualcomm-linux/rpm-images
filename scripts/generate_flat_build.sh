#!/usr/bin/env bash
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
set -euo pipefail

# ---- Defaults ---------------------------------------------------------------
TARGET_BOARDS="${TARGET_BOARDS:-all}"

# Image type: FIT multi-DTB (true) or single-DTB (false)
USE_FIT_IMAGE="${USE_FIT_IMAGE:-true}"

# Verbosity and safety
VERBOSE="${VERBOSE:-false}"
ALLOW_MISSING_SHA="${ALLOW_MISSING_SHA:-false}"

ESP_VFAT="${ESP_VFAT:-}"
ROOTFS_EXT4="${ROOTFS_EXT4:-}"

DTBS_TAR="${DTBS_TAR:-$PWD/linux/build/out/dtbs.tar.gz}"
VMLINUX_SRC="${VMLINUX_SRC:-}"        #optional override to a real kernel vmlinux file

ROOTDIR="${ROOTDIR:-$PWD/work}"
ARTIFACTDIR="${ARTIFACTDIR:-$PWD/build/out}"
DOWNLOADDIR="${DOWNLOADDIR:-$PWD/downloads}"

QCOM_PTOOL_URL="https://github.com/qualcomm-linux/qcom-ptool/archive/6540ea3824aee6ffc8cac5670d87652cb21f046f.tar.gz"
QCOM_PTOOL_TARBALL="$DOWNLOADDIR/qcom-ptool.tar.gz"

# qcom-dtb-metadata: pinned commit that introduced build-dtb-image.sh
QCOM_DTB_METADATA_URL="https://github.com/qualcomm-linux/qcom-dtb-metadata.git"
QCOM_DTB_METADATA_COMMIT="${QCOM_DTB_METADATA_COMMIT:-bf8f11f5274d850f71cc1af8b5a5c46683c14eee}"
QCOM_DTB_METADATA_DIR="$DOWNLOADDIR/qcom-dtb-metadata"

# VFAT sizing knobs (KiB)
# Use 4096-byte sectors to match UFS 4K sector size (same as qcom-deb-images).
# Minimum 4096 KiB (4 MiB) matches the fixed size used by qcom-deb-images and
# comfortably fits in the 64 MiB dtb_a/dtb_b partitions provisioned by ptool.
VFAT_MIN_KIB="${VFAT_MIN_KIB:-4096}"          # minimum image size (KiB)
VFAT_SECTOR_SIZE="${VFAT_SECTOR_SIZE:-4096}"   # sector size for mkfs.vfat -S (UFS = 4096)

usage() {
        cat <<EOF
Usage:
  ./scripts/generate_flat_build.sh [OPTIONS]
Inputs:
  --target-boards=<list|all>        default: all
                                    e.g. "qcs6490-rb3gen2-vision-kit,qcs6490-rb3gen2-core-kit"
Optional flat images (filenames are rewired to match their basenames):
  --esp-vfat=<path/to/efi.bin>
  --rootfs-ext4=<path/to/rootfs.img>
DTB handling:
  --dtbs-tar=<path/to/dtbs.tar.gz>  default: "$PWD/linux/build/out/dtbs.tar.gz"
  --use-fit-image=(true|false)      default: true
                                     true  = generate FIT multi-DTB image via build-dtb-image.sh
                                             (falls back to single-DTB on failure)
                                     false = single-DTB mode: extract per-board DTB from dtbs.tar.gz
                                             and pack into a VFAT image
  QCOM_DTB_METADATA_COMMIT          override pinned qcom-dtb-metadata commit (default: $QCOM_DTB_METADATA_COMMIT)
Kernel artifact:
  VMLINUX_SRC=<path/to/vmlinux>    optional; use a known-good kernel ELF instead of rootfs extraction
Logging and safety:
  --verbose=(true|false)            default: false
  --allow-missing-sha=(true|false)  default: false (ERROR if SHA256 is missing)
VFAT options (advanced):
  VFAT_MIN_KIB                      default: $VFAT_MIN_KIB
  VFAT_SECTOR_SIZE                  default: $VFAT_SECTOR_SIZE
Outputs:
   \$ARTIFACTDIR/flash_<board>_ufs/
EOF
}

# ---- Parse CLI --------------------------------------------------------------
for arg in "$@"; do
        case "$arg" in
                --target-boards=*)      TARGET_BOARDS="${arg#*=}";;

                --esp-vfat=*)           ESP_VFAT="${arg#*=}";;
                --rootfs-ext4=*)        ROOTFS_EXT4="${arg#*=}";;

                --dtbs-tar=*)           DTBS_TAR="${arg#*=}";;
                --use-fit-image=*)      USE_FIT_IMAGE="${arg#*=}";;
                --verbose=*)            VERBOSE="${arg#*=}";;
                --allow-missing-sha=*)  ALLOW_MISSING_SHA="${arg#*=}";;

                -h|--help) usage; exit 0;;
                *) echo "Unknown option: $arg" >&2; usage; exit 1;;
        esac
done

# ---- Helpers: deps & utils ---------------------------------------------------
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 2; }; }
need curl; need git; need unzip; need sha256sum; need tar; need mkfs.vfat; need mcopy; need python3

normalize_bool() {
        local v
        v="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
        case "$v" in
                1|true|yes|y)    echo "true" ;;
                0|false|no|n|'') echo "false" ;;
                *)               echo "INVALID" ;;
        esac
}

log_debug() {
        local msg="${1:-}"
        [[ "$VERBOSE" == "true" ]] && echo "$msg" >&2 || true
}

# Print verbose debug lines to stderr (so command substitutions are not polluted)
dbg() {
        [[ "$VERBOSE" == "true" ]] && printf '%s\n' "$*" >&2 || true
}

# Normalize boolean flags
for _b in VERBOSE ALLOW_MISSING_SHA USE_FIT_IMAGE; do
        val=$(normalize_bool "${!_b}")
        if [[ "$val" == "INVALID" ]]; then
                echo "Invalid boolean for $_b: ${!_b}. Use true/false (or 1/0/yes/no)." >&2
                exit 1
        fi
        printf -v "$_b" '%s' "$val"
done

mkdir -p "$ROOTDIR" "$ARTIFACTDIR" "$DOWNLOADDIR"

BUILD_DIR="${ROOTDIR}/build.$$"
rm -rf "$BUILD_DIR"; mkdir -p "$BUILD_DIR"
cleanup() {
        [[ -d "$ROOTDIR" && "$ROOTDIR" == "$PWD"/work ]] && rm -rf "$ROOTDIR"
}
trap cleanup EXIT

# mtools: avoid geometry prompts
export MTOOLS_SKIP_CHECK=1

# ---- Board registry ----------------------------------------------------------
declare -a BOARD_NAME BOARD_PLATFORMS BOARD_DTB
declare -a BOOT_DESC BOOT_URL BOOT_FILENAME BOOT_SHA
declare -a CDT_DESC CDT_URL CDT_FILENAME CDT_SHA CDT_BOARD_FILE
BOARD_COUNT=0

add_board() {
        local name="$1" platforms="$2" dtb="$3"
        local boot_desc="$4" boot_url="$5" boot_filename="$6" boot_sha="$7"
        local cdt_desc="$8" cdt_url="${9}" cdt_filename="${10}" cdt_sha="${11}" cdt_board_file="${12}"

        BOARD_NAME[BOARD_COUNT]="$name"
        BOARD_PLATFORMS[BOARD_COUNT]="$platforms"
        BOARD_DTB[BOARD_COUNT]="$dtb"

        BOOT_DESC[BOARD_COUNT]="$boot_desc"
        BOOT_URL[BOARD_COUNT]="$boot_url"
        BOOT_FILENAME[BOARD_COUNT]="$boot_filename"
        BOOT_SHA[BOARD_COUNT]="$boot_sha"

        CDT_DESC[BOARD_COUNT]="$cdt_desc"
        CDT_URL[BOARD_COUNT]="$cdt_url"
        CDT_FILENAME[BOARD_COUNT]="$cdt_filename"
        CDT_SHA[BOARD_COUNT]="$cdt_sha"
        CDT_BOARD_FILE[BOARD_COUNT]="$cdt_board_file"

        ((++BOARD_COUNT))
}

# ---- Populate boards --------------------------------------------------------
add_board \
        "qcs6490-rb3gen2-vision-kit" "qcs6490-rb3gen2/ufs" "qcom/qcs6490-rb3gen2.dtb" \
        "QCM6490 boot binaries" \
        "https://softwarecenter.qualcomm.com/nexus/generic/product/chip/tech-package/QCM6490_bootbinaries.1.0/qcm6490_bootbinaries.1.0-test-device-public/00123/QCM6490_bootbinaries.zip" \
        "qcm6490_boot-binaries.zip" \
        "df120b750128166c9f8f9ad28c7ecd30d3938c2750a250f2a12362757dc416b0" \
        "RB3 Gen2 Vision Kit CDT" \
        "https://artifacts.codelinaro.org/artifactory/codelinaro-le/Qualcomm_Linux/QCS6490/cdt/rb3gen2-vision-kit.zip" \
        "qcs6490-rb3gen2-vision-kit_cdt.zip" \
        "a339e297b454c4dc3805fe8cd11d6d8dcb801aa8f0c2dc691561c2785019fa3c" \
        "cdt_vision_kit.bin"

add_board \
        "qcs6490-rb3gen2-core-kit" "qcs6490-rb3gen2/ufs" "qcom/qcs6490-rb3gen2.dtb" \
        "QCM6490 boot binaries" \
        "https://softwarecenter.qualcomm.com/nexus/generic/product/chip/tech-package/QCM6490_bootbinaries.1.0/qcm6490_bootbinaries.1.0-test-device-public/00123/QCM6490_bootbinaries.zip" \
        "qcm6490_boot-binaries.zip" \
        "df120b750128166c9f8f9ad28c7ecd30d3938c2750a250f2a12362757dc416b0" \
        "RB3 Gen2 Core Kit CDT" \
        "https://artifacts.codelinaro.org/artifactory/codelinaro-le/Qualcomm_Linux/QCS6490/cdt/rb3gen2-core-kit.zip" \
        "qcs6490-rb3gen2-core-kit_cdt.zip" \
        "0fe1c0b4050cf54203203812b2c1f0d9698823d8defc8b6516414a4e5e0c557e" \
        "cdt_core_kit.bin"

add_board \
        "qcs6490-rb3gen2-industrial-kit" "qcs6490-rb3gen2/ufs" "qcom/qcs6490-rb3gen2.dtb" \
        "QCM6490 boot binaries" \
        "https://softwarecenter.qualcomm.com/nexus/generic/product/chip/tech-package/QCM6490_bootbinaries.1.0/qcm6490_bootbinaries.1.0-test-device-public/00123/QCM6490_bootbinaries.zip" \
        "qcm6490_boot-binaries.zip" \
        "df120b750128166c9f8f9ad28c7ecd30d3938c2750a250f2a12362757dc416b0" \
        "RB3 Gen2 Industrial Kit CDT" \
        "https://artifacts.codelinaro.org/artifactory/codelinaro-le/Qualcomm_Linux/QCS6490/cdt/rb3gen2-industrial-kit.zip" \
        "qcs6490-rb3gen2-industrial-kit_cdt.zip" \
        "6cf70a1b9eb0ff27176bb77c679d519f58fbad2cdf2fd7bec1e305c1bf52c013" \
        "cdt_industrial_kit.bin"

# ---- Utilities ---------------------------------------------------------------
download_if_needed() {
        local url="$1" out="$2"
        if [[ -f "$out" ]]; then
                log_debug "Already present: $out"
                return 0
        fi
        echo "Downloading: $url" >&2
        mkdir -p "$(dirname "$out")"
        local tmp="${out}.tmp.$$"; rm -f "$tmp"
        curl -L --fail --retry 5 --retry-all-errors --connect-timeout 15 --max-time 1200 -o "$tmp" "$url"
        mv -f "$tmp" "$out"
}

verify_sha256() {
        echo "${1}  ${2}" | sha256sum --strict -c -;
}

unpack_zip_smart() {
        local zipfile="$1" destdir="$2"
        rm -rf "$destdir"; mkdir -p "$destdir"
        local tmpdir="${BUILD_DIR}/tmp_unzip_$$"
        rm -rf "$tmpdir"
        mkdir -p "$tmpdir"

        unzip -o "$zipfile" -d "$tmpdir" >/dev/null
        local top_count; top_count="$(find "$tmpdir" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
        if [[ "$top_count" == "1" ]] && [[ -d "$(find "$tmpdir" -mindepth 1 -maxdepth 1 -type d -print -quit)" ]]; then
                local top; top="$(find "$tmpdir" -mindepth 1 -maxdepth 1 -type d -print -quit)"
                shopt -s dotglob nullglob; mv "$top"/* "$destdir"/ 2>/dev/null || true; shopt -u dotglob nullglob
        else
                shopt -s dotglob nullglob; mv "$tmpdir"/* "$destdir"/ 2>/dev/null || true; shopt -u dotglob nullglob
        fi
        rm -rf "$tmpdir"
}

ensure_qcom_ptool() {
        download_if_needed "$QCOM_PTOOL_URL" "$QCOM_PTOOL_TARBALL"
        local dest="$DOWNLOADDIR/qcom-ptool"
        local sha_file="$dest/.ptool.sha256"
        mkdir -p "$dest"
        local cur_sha
        cur_sha="$(sha256sum "$QCOM_PTOOL_TARBALL" | awk '{print $1}')"
        if [[ -f "$sha_file" ]] && [[ "$(cat "$sha_file")" == "$cur_sha" ]] && [[ -f "$dest/qcom_ptool/gen_partition.py" ]]; then
                echo "$dest" # cache valid, reuse
                return 0
        fi
        rm -rf "$dest"; mkdir -p "$dest"
        tar -xzf "$QCOM_PTOOL_TARBALL" --strip-components=1 -C "$dest"
        [[ -f "$dest/qcom_ptool/gen_partition.py" ]] || { echo "qcom-ptool unpack failed (gen_partition.py missing)" >&2; exit 3; }
        echo "$cur_sha" > "$sha_file"
        echo "$dest"  # ONLY return value on stdout
}

ensure_qcom_dtb_metadata() {
        local dest="$QCOM_DTB_METADATA_DIR"
        if [[ ! -d "$dest/.git" ]]; then
                echo "Cloning qcom-dtb-metadata -> $dest" >&2
                git clone "$QCOM_DTB_METADATA_URL" "$dest" >&2
        fi
        # Only fetch from origin if the pinned commit is not already present locally.
        # This avoids a slow/fragile network round-trip on every invocation.
        if ! git -C "$dest" cat-file -e "${QCOM_DTB_METADATA_COMMIT}^{commit}" 2>/dev/null; then
                echo "Fetching qcom-dtb-metadata (need $QCOM_DTB_METADATA_COMMIT)" >&2
                git -C "$dest" fetch origin >&2
        fi
        git -C "$dest" checkout "$QCOM_DTB_METADATA_COMMIT" >&2
        local script="$dest/build-dtb-image.sh"
        [[ -f "$script" ]] || {
                echo "WARNING: build-dtb-image.sh not found in $dest (commit $QCOM_DTB_METADATA_COMMIT)" >&2
                return 1
        }
        echo "$dest"
}

resolve_maybe_relative_to_artifactdir() {
        local p="$1"
        [[ -n "$p" ]] || return 0
        if [[ -f "$p" ]]; then
                printf '%s\n' "$p"
                return 0
        fi
        if [[ -n "$ARTIFACTDIR" && -f "$ARTIFACTDIR/$p" ]]; then
                printf '%s\n' "$ARTIFACTDIR/$p"
                return 0
        fi
        return 1
}

copy_boot_binaries_filtered() {
        local srcdir="$1" destdir="$2"
        find "$srcdir" -type f \
                -not -name 'gpt_*' \
                -not -name 'patch*.xml' \
                -not -name 'rawprogram*.xml' \
                -not -name 'wipe*.xml' \
                -not -name 'zeros_*' \
                \( -name 'LICENSE' -o -name 'Qualcomm-Technologies-Inc.-Proprietary' -o -name 'prog_*' -o -name 'boot.img' -o -name '*.bin' -o -name '*.elf' -o -name '*.fv' -o -name '*.mbn' \) \
                -exec cp --preserve=mode,timestamps -v '{}' "$destdir" \;
}

# Suggest DTB candidates when not found
suggest_dtb_candidates() {
        local want="$1" list="$2"
        local base dir
        base="$(basename "$want")"
        dir="$(dirname "$want")"
        echo "  Candidates with same basename:"
        awk -F/ -v b="$base" '$NF==b {print "    - "$0}' "$list" || true
        if [[ "$dir" != "." ]]; then
                echo "  Entries with similar prefix ($dir):"
                grep -F "$dir" "$list" | sed 's/^/    - /' | head -n 10 || true
        fi
}

# Resolve DTB path: exact match or unique basename match (returns path or empty)
resolve_dtb_path() {
        local want="$1" list="$2"
        local exact; exact="$(grep -Fx -- "$want" "$list" || true)"
        if [[ -n "$exact" ]]; then echo "$want"; return 0; fi
        local base; base="$(basename "$want")"
        mapfile -t matches < <(awk -F/ -v b="$base" '$NF==b {print}' "$list")
        if [[ "${#matches[@]}" -eq 1 ]]; then echo "${matches[0]}"; return 0; fi
        echo ""
}

# Compute VFAT image size (KiB) for a DTB with headroom
compute_fat_size_kib() {
        local dtb_file="$1"
        local size_bytes
        size_bytes="$(stat -c '%s' "$dtb_file" 2>/dev/null || echo 0)"
        local headroom=$((512 * 1024))        # +512 KiB
        local total=$((size_bytes + headroom))
        local kib=$(( (total + 1023) / 1024 ))
        if (( kib < VFAT_MIN_KIB )); then kib="$VFAT_MIN_KIB"; fi
        echo "$kib"
}

# Resolve a known-good kernel vmlinux from the build tree or an override path
resolve_kernel_vmlinux_source() {
        local -a candidates=()
        local src

        if [[ -n "$VMLINUX_SRC" ]]; then
                if [[ -d "$VMLINUX_SRC" ]]; then
                        candidates+=("$VMLINUX_SRC/vmlinux" "$VMLINUX_SRC/vmlinux.unstripped")
                else
                        candidates+=("$VMLINUX_SRC")
                fi
        fi

        candidates+=(
                "$PWD/linux/vmlinux"
                "$PWD/linux/vmlinux.unstripped"
                "$PWD/linux/build/vmlinux"
                "$PWD/linux/build/vmlinux.unstripped"
        )

        for src in "${candidates[@]}"; do
                [[ -f "$src" ]] || continue
                # Prefer ELF images; skip compressed images that merely happen to be named vmlinux
                if command -v file >/dev/null 2>&1; then
                        if file -b "$src" 2>/dev/null | grep -qiE '^ELF '; then
                                echo "$src"
                                return 0
                        fi
                else
                        echo "$src"
                        return 0
                fi
        done

        return 1
}

# Copy a real kernel vmlinux into the flash directory if available
copy_kernel_vmlinux_artifact() {
        local out_dir="$1"
        local dst="$out_dir/vmlinux"
        local src=""

        if src="$(resolve_kernel_vmlinux_source)"; then
                echo "Using kernel tree vmlinux: $src" >&2
                cp --preserve=mode,timestamps -v "$src" "$dst"
                return 0
        fi

        return 1
}

# Extract vmlinux from a mounted rootfs; fallback to copying vmlinuz if extract-vmlinux is unavailable
extract_kernel_from_mounted_rootfs() {
        local mnt="$1" out_dir="$2"
        local dst="$out_dir/vmlinux"

        # Prefer debug vmlinux
        local src=""
        src="$(find "$mnt/usr/lib/debug/lib/modules" -type f -name 'vmlinux' -print -quit 2>/dev/null || true)"
        if [[ -z "$src" ]]; then
                src="$(find "$mnt/usr/lib/modules" -maxdepth 2 -type f -name 'vmlinux' -print -quit 2>/dev/null || true)"
        fi
        if [[ -n "$src" ]]; then
                echo "Copying vmlinux from $src" >&2
                cp --preserve=mode,timestamps -v "$src" "$dst"
                return 0
        fi

        # Try /boot/vmlinux* first
        src="$(find "$mnt/boot" -type f -name 'vmlinux*' -print -quit 2>/dev/null || true)"
        if [[ -n "$src" ]]; then
                echo "Copying vmlinux from $src" >&2
                cp --preserve=mode,timestamps -v "$src" "$dst"
                return 0
        fi

        # Fallback: /boot/vmlinuz* + extract-vmlinux
        src="$(find "$mnt/boot" -type f -name 'vmlinuz*' -print -quit 2>/dev/null || true)"
        if [[ -n "$src" ]]; then
                if command -v extract-vmlinux >/dev/null 2>&1; then
                        echo "Extracting vmlinux from $src using extract-vmlinux" >&2
                        extract-vmlinux "$src" > "$dst"
                        return 0
                else
                        echo "WARNING: extract-vmlinux not found; copying compressed vmlinuz as vmlinux" >&2
                        cp --preserve=mode,timestamps -v "$src" "$dst"
                        return 0
                fi
        fi

        echo "WARNING: Kernel image not found in rootfs (vmlinux/vmlinuz); skipping vmlinux artifact" >&2
        return 1
}

# Extract vmlinux/vmlinuz from an ext4 image without root using e2tools or debugfs
extract_kernel_from_ext4_image() {
        local img="$1" out_dir="$2"
        local dst="$out_dir/vmlinux"

        # Try e2tools first (non-root)
        if command -v e2ls >/dev/null 2>&1 && command -v e2cp >/dev/null 2>&1; then
                local boot_list name tmp
                boot_list="$(e2ls "${img}":/boot 2>/dev/null || true)"
                name="$(printf '%s\n' "$boot_list" | awk '{print $NF}' | grep -E '^vmlinux(-.*)?$' | head -n1 || true)"
                if [[ -n "$name" ]]; then
                        echo "e2tools: copying /boot/$name -> $dst" >&2
                        e2cp -p "${img}":/boot/"$name" "$dst"
                        return 0
                fi
                name="$(printf '%s\n' "$boot_list" | awk '{print $NF}' | grep -E '^vmlinuz(-.*)?$' | head -n1 || true)"
                if [[ -n "$name" ]]; then
                        tmp="${BUILD_DIR}/vmlinuz.$$"
                        echo "e2tools: copying /boot/$name -> $tmp" >&2
                        e2cp -p "${img}":/boot/"$name" "$tmp"
                        if command -v extract-vmlinux >/dev/null 2>&1; then
                                echo "e2tools: extracting vmlinux using extract-vmlinux" >&2
                                extract-vmlinux "$tmp" > "$dst"
                        else
                                echo "e2tools: extract-vmlinux not found; copying compressed vmlinuz as vmlinux" >&2
                                cp --preserve=mode,timestamps -v "$tmp" "$dst"
                        fi
                        rm -f "$tmp"
                        return 0
                fi
        fi

        # Fallback to debugfs (non-root)
        if command -v debugfs >/dev/null 2>&1; then
                local boot_list name tmp
                boot_list="$(debugfs -R "ls -p /boot" "$img" 2>/dev/null | awk '{print $NF}' | tr -d '\r' || true)"
                name="$(printf '%s\n' "$boot_list" | grep -E '^vmlinux(-.*)?$' | head -n1 || true)"
                if [[ -n "$name" ]]; then
                        echo "debugfs: dumping /boot/$name -> $dst" >&2
                        debugfs -R "dump -p /boot/$name $dst" "$img" >/dev/null 2>&1 && return 0
                fi
                name="$(printf '%s\n' "$boot_list" | grep -E '^vmlinuz(-.*)?$' | head -n1 || true)"
                if [[ -n "$name" ]]; then
                        tmp="${BUILD_DIR}/vmlinuz.$$"
                        echo "debugfs: dumping /boot/$name -> $tmp" >&2
                        if debugfs -R "dump -p /boot/$name $tmp" "$img" >/dev/null 2>&1; then
                                if command -v extract-vmlinux >/dev/null 2>&1; then
                                        echo "debugfs: extracting vmlinux using extract-vmlinux" >&2
                                        extract-vmlinux "$tmp" > "$dst"
                                else
                                        echo "debugfs: extract-vmlinux not found; copying compressed vmlinuz as vmlinux" >&2
                                        cp --preserve=mode,timestamps -v "$tmp" "$dst"
                                fi
                                rm -f "$tmp"
                                return 0
                        fi
                fi
        fi

        return 1
}

# Generate ptool outputs for a platform using gen_partition.py -m partition map.
# This matches the approach used by qcom-deb-images/scripts/gen-ptool.sh.
generate_ptool_from_platform() {
        local platform_dir="$1" qcom_ptool="$2" cdt_board_file="$3"
        local esp_basename="${4:-}" rootfs_basename="${5:-}" dtb_basename="${6:-}"
        local conf="${qcom_ptool}/platforms/${platform_dir}/partitions.conf"
        local contents="${qcom_ptool}/platforms/${platform_dir}/contents.xml.in"
        log_debug "conf=$conf"
        log_debug "contents=$contents"
        [[ -f "$conf" ]] || { echo "Missing partitions.conf: $conf" >&2; exit 4; }

        mkdir -p "${BUILD_DIR}/ptool/${platform_dir}"
        pushd "${BUILD_DIR}/ptool/${platform_dir}" >/dev/null

        [[ -n "$dtb_basename" ]] && dtb_basename="$(basename "$dtb_basename")"

        # Extract disk type from partitions.conf --disk line
        local disk_type
        disk_type="$(sed -n 's/.*--type=\([^ ]*\).*/\1/p' "$conf" | head -n1)"
        [[ -n "$disk_type" ]] || { echo "Could not parse disk type from: $conf" >&2; exit 5; }

        local esp_ref="" rootfs_ref=""
        case "$disk_type" in
                emmc|nvme) esp_ref="../disk-sdcard.img1"; rootfs_ref="../disk-sdcard.img2" ;;
                ufs)       esp_ref="../disk-ufs.img1";    rootfs_ref="../disk-ufs.img2" ;;
                *) echo "Unsupported disk type: $disk_type (platform: $platform_dir)" >&2; exit 6 ;;
        esac
        [[ -n "$esp_basename"    ]] && esp_ref="$esp_basename"
        [[ -n "$rootfs_basename" ]] && rootfs_ref="$rootfs_basename"

        echo "$disk_type" > disk_type
        dbg "[ptool:$platform_dir] disk_type=$disk_type esp_ref=$esp_ref rootfs_ref=$rootfs_ref"

        # Build partition map for gen_partition.py -m flag.
        # Format: "name1=file1,name2=file2,..."  (same as qcom-deb-images gen-ptool.sh)
        local cdt_base=""
        [[ -n "$cdt_board_file" ]] && cdt_base="$(basename "$cdt_board_file")"

        local partition_map=""
        [[ -n "$cdt_base"     ]] && partition_map="${partition_map:+${partition_map},}cdt=${cdt_base}"
        [[ -n "$dtb_basename" ]] && partition_map="${partition_map:+${partition_map},}dtb_a=${dtb_basename},dtb_b=${dtb_basename}"
        [[ -n "$esp_ref"      ]] && partition_map="${partition_map:+${partition_map},}efi=${esp_ref}"
        [[ -n "$rootfs_ref"   ]] && partition_map="${partition_map:+${partition_map},}rootfs=${rootfs_ref}"

        dbg "[ptool:$platform_dir] partition_map=${partition_map:-<empty>}"

        python3 "${qcom_ptool}/qcom_ptool/gen_partition.py" -i "$conf" -o partitions.xml \
                ${partition_map:+-m "$partition_map"}
        [[ -e "$contents" ]] && python3 "${qcom_ptool}/qcom_ptool/gen_contents.py" \
                -p partitions.xml -t "$contents" -o contents.xml
        PYTHONPATH="${qcom_ptool}" python3 -m qcom_ptool.ptool -x partitions.xml

        popd >/dev/null
}

# Build targets file from --target-boards (all or CSV)
build_targets_set() {
        local targets_file="$1"; rm -f "$targets_file"; mkdir -p "$(dirname "$targets_file")"
        if [[ "$TARGET_BOARDS" == "all" ]]; then
                : >"$targets_file"
                for ((i=0; i<BOARD_COUNT; i++)); do echo "${BOARD_NAME[i]}" >>"$targets_file"; done
        else
                echo "$TARGET_BOARDS" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sed '/^$/d' | sort -u >"$targets_file"
        fi
}

validate_targets_exist() {
        local targets_file="$1"
        [[ "$TARGET_BOARDS" == "all" ]] && return 0
        local unknown=0
        while IFS= read -r t || [[ -n "${t:-}" ]]; do
                local found="false"
                for ((i=0; i<BOARD_COUNT; i++)); do
                        if [[ "$t" == "${BOARD_NAME[i]}" ]]; then
                                found="true"; break
                        fi
                done
                if [[ "$found" == "false" ]]; then
                        echo "ERROR: Unknown board in --target-boards: '$t'" >&2
                        unknown=1
                fi
        done < "$targets_file"
        if (( unknown )); then
                echo "Hint: known boards are:" >&2
                for ((i=0; i<BOARD_COUNT; i++)); do echo "  - ${BOARD_NAME[i]}" >&2; done
                exit 12
        fi
}

# ---- Build targets & gate downloads -----------------------------------------
TARGETS_FILE="${BUILD_DIR}/targets.txt"
build_targets_set "$TARGETS_FILE"
validate_targets_exist "$TARGETS_FILE"

# ---- Resolve inputs / downloads ---------------------------------------------
if [[ -n "$ESP_VFAT" ]]; then
        ESP_VFAT="$(resolve_maybe_relative_to_artifactdir "$ESP_VFAT")" || {
                echo "ERROR: --esp-vfat not found: $ESP_VFAT" >&2
                exit 8
        }
fi

if [[ -n "$ROOTFS_EXT4" ]]; then
        ROOTFS_EXT4="$(resolve_maybe_relative_to_artifactdir "$ROOTFS_EXT4")" || {
                echo "ERROR: --rootfs-ext4 not found: $ROOTFS_EXT4" >&2
                exit 9
        }
fi

if [[ -n "$DTBS_TAR" ]]; then
        DTBS_TAR="$(resolve_maybe_relative_to_artifactdir "$DTBS_TAR")" || {
                echo "ERROR: --dtbs-tar not found: $DTBS_TAR" >&2
                exit 7
        }
else
        echo "ERROR: --dtbs-tar must be provided" >&2
        exit 11
fi

QCOM_PTOOL_DIR="$(ensure_qcom_ptool)"

# Download ONLY for selected boards
for ((i=0; i<BOARD_COUNT; i++)); do
        name="${BOARD_NAME[i]}"

        # Skip boards not in targets
        if ! grep -Fxq "$name" "$TARGETS_FILE"; then
                continue
        fi

        download_if_needed "${BOOT_URL[i]}" "$DOWNLOADDIR/${BOOT_FILENAME[i]}"
        if [[ -n "${BOOT_SHA[i]}" ]]; then
                verify_sha256 "${BOOT_SHA[i]}" "$DOWNLOADDIR/${BOOT_FILENAME[i]}"
        else
                if [[ "$ALLOW_MISSING_SHA" == "true" ]]; then
                        echo "WARNING: No SHA256 provided for ${BOOT_FILENAME[i]} (continuing due to --allow-missing-sha=true)" >&2
                else
                        echo "ERROR: No SHA256 provided for ${BOOT_FILENAME[i]}" >&2
                        exit 10
                fi
        fi

        if [[ -n "${CDT_URL[i]}" ]]; then
                download_if_needed "${CDT_URL[i]}" "$DOWNLOADDIR/${CDT_FILENAME[i]}"
                if [[ -n "${CDT_SHA[i]}" ]]; then
                        verify_sha256 "${CDT_SHA[i]}" "$DOWNLOADDIR/${CDT_FILENAME[i]}"
                else
                        if [[ "$ALLOW_MISSING_SHA" == "true" ]]; then
                                echo "WARNING: No SHA256 provided for ${CDT_FILENAME[i]} (continuing due to --allow-missing-sha=true)" >&2
                        else
                                echo "ERROR: No SHA256 provided for ${CDT_FILENAME[i]}" >&2
                                exit 10
                        fi
                fi
        fi
done

DTBS_FILE="${BUILD_DIR}/dtbs.txt"; : >"$DTBS_FILE"
if [[ -f "$DTBS_TAR" ]]; then
        tar -tzf "$DTBS_TAR" --wildcards '*.dtb' | sed 's#^\./##' | sort -u >"$DTBS_FILE"
else
        echo "ERROR: dtbs.tar.gz not found at: $DTBS_TAR" >&2
        exit 7
fi

# ---- Auto-generate FIT multi-DTB image from dtbs.tar.gz --------------------
#   1. Unpack qcom/ DTBs from dtbs.tar.gz into a staging directory
#   2. Run build-dtb-image.sh --dtb-src <staging/qcom> --out dtb-multidtb.bin --prune
#   3. Use the resulting FAT image as DTB_BIN_SRC for all boards
#   Runs only when USE_FIT_IMAGE=true (default).  On any failure, DTB_BIN_SRC is
#   left empty and the per-board loop falls back to single-DTB mode.
DTB_BIN_SRC=""
if [[ "$USE_FIT_IMAGE" == "true" ]]; then
echo "[*] Attempting FIT multi-DTB image generation from $(basename "$DTBS_TAR") ..."
_fit_ok=false
if QCOM_DTB_METADATA_SCRIPT_DIR="$(ensure_qcom_dtb_metadata)"; then
        DTB_STAGING="${BUILD_DIR}/dtbs_fit_staging"
        mkdir -p "$DTB_STAGING"
        # Unpack only the qcom/ subtree.
        # Entries may be prefixed with "./" (kiwi/rpm-images layout) or bare
        # "qcom/" (some other tarballs).  Try the ./ form first, then bare.
        if ! tar -C "$DTB_STAGING" -xzf "$DTBS_TAR" ./qcom 2>/dev/null; then
                tar -C "$DTB_STAGING" -xzf "$DTBS_TAR" qcom 2>/dev/null || true
        fi
        if [[ ! -d "$DTB_STAGING/qcom" ]]; then
                echo "WARNING: No qcom/ subtree found in $(basename "$DTBS_TAR"); skipping FIT generation" >&2
        else
                DTB_MULTIDTB_BIN="${ARTIFACTDIR}/dtb-multidtb.bin"
                if bash "$QCOM_DTB_METADATA_SCRIPT_DIR/build-dtb-image.sh" \
                        --dtb-src "$DTB_STAGING/qcom" \
                        --out "$DTB_MULTIDTB_BIN" \
                        --prune; then
                        if [[ -f "$DTB_MULTIDTB_BIN" ]]; then
                                echo "[✓] FIT multi-DTB image generated: $DTB_MULTIDTB_BIN"
                                DTB_BIN_SRC="$DTB_MULTIDTB_BIN"
                                _fit_ok=true
                        else
                                echo "WARNING: build-dtb-image.sh succeeded but $DTB_MULTIDTB_BIN was not created" >&2
                        fi
                else
                        echo "WARNING: build-dtb-image.sh failed; will fall back to single-DTB mode" >&2
                fi
        fi
else
        echo "WARNING: Could not fetch qcom-dtb-metadata; will fall back to single-DTB mode" >&2
fi
[[ "$_fit_ok" == "true" ]] || echo "[!] FIT generation failed — falling back to single-DTB mode"
else
        echo "[*] USE_FIT_IMAGE=false — using single-DTB mode"
fi

# Helper to create one or more DTB VFAT images
create_fit_dtb_vfat_artifacts() {
        local src_bin="$1"
        local out_dir="$2"
        local board_name="$3"

        local -a vfat_names=()
        local board_base=""

        # Always create the generic multi-dtb image
        vfat_names+=("dtb-multi-dtb-image.vfat")

        # Add board-specific alias
        case "$board_name" in
                *"-vision-kit")
                        board_base="${board_name%-vision-kit}"
                        vfat_names+=("dtb-${board_base}-image.vfat")
                        ;;
                *"-core-kit")
                        board_base="${board_name%-core-kit}"
                        vfat_names+=("dtb-${board_base}-image.vfat")
                        ;;
                *"-industrial-kit")
                        board_base="${board_name%-industrial-kit}"
                        vfat_names+=("dtb-${board_base}-image.vfat")
                        ;;
        esac

        for vfat_name in "${vfat_names[@]}"; do
                cp --preserve=mode,timestamps -f "$src_bin" "${out_dir}/${vfat_name}"
        done

        # Return primary VFAT name for ptool mapping
        echo "${vfat_names[0]}"
}

# Single-DTB mode:
# Extract the requested DTB from dtbs.tar.gz and package it as combined-dtb.dtb.
create_single_dtb_vfat_from_tar() {
        local dtb_path_in_tar="$1"
        local out_vfat="$2"

        local extract_dir="${BUILD_DIR}/dtbs_extract.$$"
        rm -rf "$extract_dir"
        mkdir -p "$extract_dir"

        local dtb_src=""
        if tar -C "$extract_dir" -xzf "$DTBS_TAR" "$dtb_path_in_tar" 2>/dev/null \
           || tar -C "$extract_dir" -xzf "$DTBS_TAR" "./$dtb_path_in_tar" 2>/dev/null; then
                if [[ -f "$extract_dir/$dtb_path_in_tar" ]]; then
                        dtb_src="$extract_dir/$dtb_path_in_tar"
                elif [[ -f "$extract_dir/$(basename "$dtb_path_in_tar")" ]]; then
                        dtb_src="$extract_dir/$(basename "$dtb_path_in_tar")"
                fi
        fi

        if [[ -z "$dtb_src" || ! -f "$dtb_src" ]]; then
                echo "ERROR: Failed to extract DTB $dtb_path_in_tar from $DTBS_TAR" >&2
                rm -rf "$extract_dir"
                return 1
        fi

        local size_kib
        size_kib="$(compute_fat_size_kib "$dtb_src")"

        mkfs.vfat -S "$VFAT_SECTOR_SIZE" -C "$out_vfat" "$size_kib"
        mcopy -vmp -i "$out_vfat" "$dtb_src" ::/combined-dtb.dtb

        rm -rf "$extract_dir"
}

normalize_board_base() {
    local board="$1"
    case "$board" in
        qcs6490-rb3gen2-vision-kit)     echo "qcs6490-rb3gen2" ;;
        qcs6490-rb3gen2-core-kit)       echo "qcs6490-rb3gen2" ;;
        qcs6490-rb3gen2-industrial-kit) echo "qcs6490-rb3gen2" ;;
    esac
}

# ---- Build per-board/platform ------------------------------------------------
declare -A BOARD_RESULT BOARD_REASON
declare -A PLAT_RESULT PLAT_REASON   # key: "board/platform"

for ((i=0; i<BOARD_COUNT; i++)); do
    name="${BOARD_NAME[i]}"
    platforms="${BOARD_PLATFORMS[i]}"
    dtb="${BOARD_DTB[i]}"
    cdt_board_file="${CDT_BOARD_FILE[i]}"

    echo "=== Board: $name ==="

    if [[ "$VERBOSE" == "true" ]]; then
        {
            echo "Processing board [$i]:"
            echo "  Name          : $name"
            echo "  Platforms     : $platforms"
            echo "  DTB           : $dtb"
            echo "  CDT file      : ${cdt_board_file:-<none>}"
        } >&2
    fi

    # Determine if targeted
    if ! grep -Fxq "$name" "$TARGETS_FILE"; then
        echo "Skipping $name: not in target list"
        BOARD_RESULT["$name"]="SKIPPED"
        BOARD_REASON["$name"]="not in targets"

        for platform in $platforms; do
            PLAT_RESULT["$name/$platform"]="SKIPPED"
            PLAT_REASON["$name/$platform"]="board not targeted"
        done
        continue
    fi

    # Unzip boot and CDT only for targeted boards
    [[ -f "$DOWNLOADDIR/${BOOT_FILENAME[i]}" ]] || {
        echo "ERROR: Missing boot binaries zip for $name: $DOWNLOADDIR/${BOOT_FILENAME[i]}" >&2
        exit 14
    }
    unpack_zip_smart "$DOWNLOADDIR/${BOOT_FILENAME[i]}" "${BUILD_DIR}/${name}_boot-binaries"

    if [[ -n "${CDT_FILENAME[i]}" ]]; then
        [[ -f "$DOWNLOADDIR/${CDT_FILENAME[i]}" ]] || {
            echo "ERROR: Missing CDT zip for $name: $DOWNLOADDIR/${CDT_FILENAME[i]}" >&2
            exit 15
        }
        unpack_zip_smart "$DOWNLOADDIR/${CDT_FILENAME[i]}" "${BUILD_DIR}/${name}_cdt"
    fi

    for platform in $platforms; do
        esp_base=""
        rootfs_base=""

        [[ -n "$ESP_VFAT"    ]] && esp_base="$(basename "$ESP_VFAT")"
        [[ -n "$ROOTFS_EXT4" ]] && rootfs_base="$(basename "$ROOTFS_EXT4")"

        mkdir -p "${BUILD_DIR}/ptool/${platform}"
        # Stage dtb.bin for ptool only when FIT image is available;
        # in single-DTB fallback mode dtb.bin is written directly into flash_dir later.
        dtb_filename=""
        if [[ -n "$DTB_BIN_SRC" ]]; then
            cp --preserve=mode,timestamps -v "$DTB_BIN_SRC" "${BUILD_DIR}/ptool/${platform}/dtb.bin"
            dtb_filename="dtb.bin"
        fi
        main_base="$(normalize_board_base "$name")"

        dbg "  -> Platform build"
        dbg "     platform                  : $platform"
        dbg "     dtb_filename              : ${dtb_filename:-<single-dtb-fallback>}"
        dbg "     main_base                 : $main_base"
        dbg "     ESP_VFAT                  : ${ESP_VFAT:-<none>}"
        dbg "     esp_base                  : ${esp_base:-<none>}"
        dbg "     ROOTFS_EXT4               : ${ROOTFS_EXT4:-<none>}"
        dbg "     rootfs_base               : ${rootfs_base:-<none>}"
        dbg "     CDT board file            : ${cdt_board_file:-<none>}"
        dbg "     QCOM_PTOOL_DIR            : ${QCOM_PTOOL_DIR:-<none>}"

        # Generate ptool layout ONCE per platform
        generate_ptool_from_platform \
            "$platform" \
            "$QCOM_PTOOL_DIR" \
            "$cdt_board_file" \
            "$esp_base" \
            "$rootfs_base" \
            "$dtb_filename"

        disk_type="$(cat "${BUILD_DIR}/ptool/${platform}/disk_type")"
        flash_dir="${ARTIFACTDIR}/flash_${name}_${disk_type}"
        rm -rf "$flash_dir"
        mkdir -p "$flash_dir"

        cp -a "${BUILD_DIR}/ptool/${platform}/." "$flash_dir/"

        rm -f \
            "$flash_dir"/rawprogram*_BLANK_GPT.xml \
            "$flash_dir"/rawprogram*_WIPE_PARTITIONS.xml \
            "$flash_dir"/wipe_rawprogram_PHY*.xml \
            "$flash_dir"/gpt_empty*.bin \
            "$flash_dir"/partitions* \
            "$flash_dir"/disk_type 2>/dev/null || true

        copy_boot_binaries_filtered "${BUILD_DIR}/${name}_boot-binaries" "$flash_dir"

        if [[ -n "$cdt_board_file" ]]; then
            if [[ -f "${BUILD_DIR}/${name}_cdt/${cdt_board_file}" ]]; then
                cp --preserve=mode,timestamps -v \
                    "${BUILD_DIR}/${name}_cdt/${cdt_board_file}" \
                    "$flash_dir"
            elif [[ -f "${BUILD_DIR}/${name}_cdt/$(basename "$cdt_board_file")" ]]; then
                cp --preserve=mode,timestamps -v \
                    "${BUILD_DIR}/${name}_cdt/$(basename "$cdt_board_file")" \
                    "$flash_dir"
            else
                echo "WARNING: CDT file not found in unpacked CDT: $cdt_board_file"
            fi
        fi

        if [[ -n "$ESP_VFAT" ]]; then
            cp --preserve=mode,timestamps -v \
                "$ESP_VFAT" \
                "$flash_dir/$(basename "$ESP_VFAT")"
        fi

        if [[ -n "$ROOTFS_EXT4" ]]; then
            cp --preserve=mode,timestamps -v \
                "$ROOTFS_EXT4" \
                "$flash_dir/$(basename "$ROOTFS_EXT4")"
        fi

        # ---------------------------------------------------------------------
        # DTB artifacts
        #   FIT mode  (DTB_BIN_SRC set): dtb-multidtb.bin is a 4 MiB FAT image
        #     containing qclinux_fit.img (filename hardcoded in UEFI firmware).
        #     Copy it as dtb.bin and create named .vfat aliases.
        #   Single-DTB fallback (DTB_BIN_SRC empty): extract the per-board .dtb from
        #     dtbs.tar.gz and pack it into a VFAT image as combined-dtb.dtb.
        # ---------------------------------------------------------------------
        if [[ -n "$DTB_BIN_SRC" ]]; then
            echo "[FIT] Using FIT multi-DTB image for $name/$platform"
            cp --preserve=mode,timestamps -f "$DTB_BIN_SRC" "$flash_dir/dtb.bin"
            create_fit_dtb_vfat_artifacts "$DTB_BIN_SRC" "$flash_dir" "$name" >/dev/null
        else
            echo "[single-DTB] Using single-DTB fallback for $name/$platform (dtb: $dtb)"
            resolved_dtb="$(resolve_dtb_path "$dtb" "$DTBS_FILE" || true)"
            if [[ -z "$resolved_dtb" ]]; then
                echo "WARNING: DTB '$dtb' not found in $(basename "$DTBS_TAR"); skipping DTB artifacts for $name/$platform" >&2
                suggest_dtb_candidates "$dtb" "$DTBS_FILE"
            else
                single_dtb_vfat="${flash_dir}/dtb.bin"
                rm -f "$single_dtb_vfat"
                create_single_dtb_vfat_from_tar "$resolved_dtb" "$single_dtb_vfat"

                main_vfat="${flash_dir}/dtb-${main_base}-image.vfat"
                rm -f "$main_vfat"
                create_single_dtb_vfat_from_tar "$resolved_dtb" "$main_vfat"

                # Board-specific single-DTB variants for vision-kit
                if [[ "$name" == "qcs6490-rb3gen2-vision-kit" ]]; then
                    for variant in industrial-mezzanine vision-mezzanine; do
                        var_vfat="${flash_dir}/dtb-${main_base}-${variant}-image.vfat"
                        rm -f "$var_vfat"
                        create_single_dtb_vfat_from_tar "$resolved_dtb" "$var_vfat"
                    done
                fi
            fi
        fi

        # Kernel artifact: vmlinux
        # Prefer the real kernel ELF from the build tree; fall back to rootfs extraction
        if copy_kernel_vmlinux_artifact "$flash_dir"; then
            dbg "vmlinux artifact copied from kernel build tree"
        elif [[ -n "$ROOTFS_EXT4" ]]; then
            if extract_kernel_from_ext4_image "$ROOTFS_EXT4" "$flash_dir"; then
                dbg "vmlinux artifact extracted from ext4 image (non-root)"
            else
                if [[ "$(id -u)" == "0" ]]; then
                    mnt_dir="${BUILD_DIR}/mnt_rootfs.$$"
                    rm -rf "$mnt_dir"
                    mkdir -p "$mnt_dir"
                    if mount -o loop,ro "$ROOTFS_EXT4" "$mnt_dir"; then
                        extract_kernel_from_mounted_rootfs "$mnt_dir" "$flash_dir" || true
                        umount "$mnt_dir" || true
                    else
                        echo "WARNING: Failed to mount rootfs ($ROOTFS_EXT4) as root; skipping vmlinux extraction" >&2
                    fi
                    rm -rf "$mnt_dir"
                else
                    echo "INFO: Skipping vmlinux extraction (no passwordless sudo). Install 'e2tools' or 'e2fsprogs' (debugfs) or run as root to enable extraction." >&2
                fi
            fi
        fi
        PLAT_RESULT["$name/$platform"]="BUILT"
        PLAT_REASON["$name/$platform"]="ok (${disk_type})"
        BOARD_RESULT["$name"]="BUILT"
        BOARD_REASON["$name"]="ok (multi-platform)"
    done
done

echo
echo "================================================================================"
echo "Build summary (per platform):"
for ((i=0; i<BOARD_COUNT; i++)); do
        name="${BOARD_NAME[i]}"
        for platform in ${BOARD_PLATFORMS[i]}; do
                key="$name/$platform"
                printf "  - %-28s | %-18s : %-8s" "$name" "$platform" "${PLAT_RESULT[$key]:-SKIPPED}"
                [[ -n "${PLAT_REASON[$key]:-}" ]] && printf "  (%s)" "${PLAT_REASON[$key]}"
                echo
        done
done

echo
echo "Board roll-up:"
for ((i=0; i<BOARD_COUNT; i++)); do
        name="${BOARD_NAME[i]}"
        printf "  - %-28s : %-8s" "$name" "${BOARD_RESULT[$name]:-SKIPPED}"
        [[ -n "${BOARD_REASON[$name]:-}" ]] && printf "  (%s)" "${BOARD_REASON[$name]}"
        echo
done

echo
echo "Outputs in: $ARTIFACTDIR"
