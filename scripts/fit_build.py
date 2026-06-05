#!/usr/bin/env python3
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
"""
fit_build.py - Build a FIT DTB image for Qualcomm ARM64 platforms.

Delegates to build-dtb-image.sh from qcom-dtb-metadata (PR #83), which is
the official self-contained build tool.  Cloning qcom-dtb-metadata is
sufficient — no additional tooling repositories, no network access at build
time, and no metadata path arguments.

Build pipeline (handled entirely by build-dtb-image.sh):
  1. Stage DTBs into a temporary tree
  2. Compile qcom-metadata.dts → qcom-metadata.dtb  (dtc)
  3. Copy qcom-next-fitimage.its into the staging directory
  4. mkimage -f qcom-next-fitimage.its out/qclinux_fit.img -E -B 8
  5. Pack qclinux_fit.img into a 4 MB FAT image (mformat -S 5 + mcopy)
     Sector size: 4096 bytes (mformat -S 5 = 2^(5+7)), matching UFS 4K sectors
     and meta-qcom QCOM_VFAT_SECTOR_SIZE=4096 / DTBBIN_SIZE=4096.
"""
import argparse, json, os, shutil, subprocess, sys
from pathlib import Path

VERBOSE = False

QCOM_DTB_METADATA_COMMIT = "bdc5cd91fded70c0b8e52228067054aa841f1e7f"


def die(msg: str):
    raise SystemExit(f"ERROR: {msg}")


def info(msg: str):
    print(f"[INFO] {msg}", file=sys.stderr)


def dbg(msg: str):
    if VERBOSE:
        print(f"[DBG] {msg}", file=sys.stderr)


def need(*bins: str):
    missing = [b for b in bins if shutil.which(b) is None]
    if missing:
        die("Missing tool(s): " + ", ".join(missing))


def run(cmd, cwd=None, shell=False, allow_fail=False):
    dbg(f"Running: {cmd!r} (cwd={cwd}, shell={shell})")
    if VERBOSE:
        p = subprocess.run(cmd, cwd=cwd, shell=shell, text=True)
    else:
        p = subprocess.run(cmd, cwd=cwd, shell=shell, text=True,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if (not allow_fail) and p.returncode:
        s = cmd if isinstance(cmd, str) else " ".join(map(str, cmd))
        if VERBOSE:
            die(f"Command failed: {s} (see output above)")
        die(f"Command failed: {s}\nSTDOUT:\n{p.stdout}\nSTDERR:\n{p.stderr}")
    return p


def write_json(p: Path, obj):
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(obj, indent=2) + "\n", encoding="utf-8")


def clone_or_update(url: str, dst: Path, ref: str = "main"):
    """Clone or update a git repo to a specific branch, tag, or commit."""
    need("git")
    if not (dst / ".git").is_dir():
        info(f"Cloning repo -> {dst}")
        run(["git", "clone", url, str(dst)])
    info(f"Updating repo (checkout {ref!r}) -> {dst}")
    run(["git", "fetch", "--tags", "origin"], cwd=str(dst))
    run(["git", "checkout", ref], cwd=str(dst))
    if not ref.startswith("v") and len(ref) < 20:
        # branch name: reset to remote
        run(["git", "reset", "--hard", f"origin/{ref}"], cwd=str(dst))
    return dst


def unpack_rpm(src: Path, unpack_dir: Path) -> Path:
    """Unpack an RPM into unpack_dir and return the directory."""
    need("rpm2cpio", "cpio", "bash")
    info(f"Unpacking .rpm -> {unpack_dir}")
    shutil.rmtree(unpack_dir, ignore_errors=True)
    unpack_dir.mkdir(parents=True, exist_ok=True)
    run(f"rpm2cpio '{src}' | cpio -idmu", cwd=str(unpack_dir), shell=True)
    return unpack_dir


def main():
    global VERBOSE

    ap = argparse.ArgumentParser(
        description=(
            "Build FIT DTB image using build-dtb-image.sh from qcom-dtb-metadata. "
            "Produces dtb.bin: a 4 MB FAT image (4096-byte sectors) containing "
            "qclinux_fit.img, matching meta-qcom linux-qcom-dtbbin.bbclass."
        )
    )
    ap.add_argument(
        "source",
        help="kernel.deb | kernel.rpm | directory containing dtb/dtbo files",
    )
    ap.add_argument(
        "--outdir", default="./out",
        help="Output root directory (default: ./out)",
    )
    ap.add_argument(
        "--forcecreate", action="store_true",
        help="Pass --prune to build-dtb-image.sh to drop DTBs with no metadata entry",
    )
    ap.add_argument(
        "--report", action="store_true",
        help="Write JSON report into <outdir>/build.report.json",
    )
    ap.add_argument(
        "-v", "--verbose", action="store_true",
        help="Verbose: stream command output + debug logs",
    )

    args = ap.parse_args()
    VERBOSE = bool(args.verbose)

    outdir = Path(args.outdir).resolve()
    metadir = outdir / "qcom-dtb-metadata"
    unpack_dir = outdir / "unpack"

    info(f"Output root -> {outdir}")
    outdir.mkdir(parents=True, exist_ok=True)

    # Clone/update qcom-dtb-metadata pinned to the commit that introduced
    # build-dtb-image.sh (PR #83, merged into main).
    metadir = clone_or_update(
        "https://github.com/qualcomm-linux/qcom-dtb-metadata.git",
        metadir,
        ref=QCOM_DTB_METADATA_COMMIT,
    )

    script = metadir / "build-dtb-image.sh"
    if not script.is_file():
        die(
            f"build-dtb-image.sh not found in {metadir}. "
            f"Ensure qcom-dtb-metadata is at commit {QCOM_DTB_METADATA_COMMIT} or later."
        )

    source = Path(args.source).resolve()

    # Determine source mode for build-dtb-image.sh:
    #   --kernel-deb  : pass .deb directly; the script handles extraction and
    #                   DTB discovery (probes usr/lib/linux-image-*/ first,
    #                   then Ubuntu compat paths)
    #   --dtb-src     : pass a directory; the script finds all *.dtb/*.dtbo
    #                   recursively via find -L
    if source.is_file() and source.suffix == ".deb":
        info(f"Source mode: --kernel-deb {source}")
        script_args = ["--kernel-deb", str(source)]
    elif source.is_file() and source.suffix == ".rpm":
        # Unpack RPM first; build-dtb-image.sh has no native RPM support
        kernel_path = unpack_rpm(source, unpack_dir)
        info(f"Source mode: --dtb-src {kernel_path} (unpacked from RPM)")
        script_args = ["--dtb-src", str(kernel_path)]
    elif source.is_dir():
        info(f"Source mode: --dtb-src {source}")
        script_args = ["--dtb-src", str(source)]
    else:
        die(f"Unsupported source: {source} (expected .deb, .rpm, or directory)")

    dtb_bin = outdir / "dtb.bin"

    # build-dtb-image.sh pipeline:
    #   1. Stage DTBs into a temp tree (arch/arm64/boot/dts/qcom/)
    #   2. dtc: qcom-metadata.dts → qcom-metadata.dtb
    #   3. Copy qcom-next-fitimage.its into staging dir
    #   4. mkimage -f qcom-next-fitimage.its out/qclinux_fit.img -E -B 8
    #   5. dd + mformat -S 5 (4096-byte sectors) + mcopy → dtb.bin (4 MB FAT)
    #      qclinux_fit.img stored at FAT root (filename hardcoded in UEFI firmware)
    cmd = ["bash", str(script)] + script_args + ["--out", str(dtb_bin)]
    info(f"Running build-dtb-image.sh -> {dtb_bin}")
    run(cmd, cwd=str(outdir))

    if not dtb_bin.is_file():
        die(f"build-dtb-image.sh ran but dtb.bin not found at {dtb_bin}")

    print(f"[OK] dtb.bin -> {dtb_bin}")

    if args.report:
        info("Writing build report JSON")
        rep = {
            "source": str(source),
            "outdir": str(outdir),
            "dtb_bin": str(dtb_bin),
            "qcom_dtb_metadata_commit": QCOM_DTB_METADATA_COMMIT,
            "script": str(script),
        }
        write_json(outdir / "build.report.json", rep)
        info(f"Report -> {outdir / 'build.report.json'}")


if __name__ == "__main__":
    main()
