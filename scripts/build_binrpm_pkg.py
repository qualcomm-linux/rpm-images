#!/usr/bin/env python3
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
#
# Build Linux kernel Image + DTBs + modules and package RPMs
# using: make binrpm-pkg
#
# Outputs remain in default kernel locations:
#   - Image:  arch/arm64/boot/Image
#   - Modules: *.ko scattered in build tree (until modules_install)
#

import argparse
import os
import platform
import shutil
import subprocess
import sys
from typing import Optional
from pathlib import Path

GIT_REPO = "https://github.com/torvalds/linux"
GIT_REF = "master"

LINUX_NEXT_GIT_REPO = "https://git.kernel.org/pub/scm/linux/kernel/git/next/linux-next.git"
LINUX_NEXT_GIT_REF = "master"

QCOM_NEXT_GIT_REPO = "https://github.com/qualcomm-linux/kernel"
QCOM_NEXT_GIT_REF = "qcom-next"

QCOM_618Y_GIT_REPO = "https://github.com/qualcomm-linux/kernel"
QCOM_618Y_GIT_REF = "qcom-6.18.y"

BASE_CONFIG = "defconfig"


def log_i(msg: str):
    print(f"I: {msg}", file=sys.stderr)


def fatal(msg: str, code: int = 1):
    print(f"F: {msg}", file=sys.stderr)
    sys.exit(code)


def run(cmd, cwd=None, env=None, check=True):
    log_i(f"RUN: {' '.join(str(c) for c in cmd)}")
    return subprocess.run(cmd, cwd=cwd, env=env, check=check)


def rpm_installed(pkg: str) -> bool:
    try:
        r = subprocess.run(["rpm", "-q", pkg],
                           stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL)
        return r.returncode == 0
    except FileNotFoundError:
        return False


def check_dependencies():
    # Minimal RPM-side deps for building kernel + binrpm-pkg
    packages = [
        "git", "make", "gcc",
        "bc", "bison", "flex", "perl", "python3",
        "openssl-devel", "elfutils-libelf-devel",
        "rpm-build", "rpmdevtools",
        "rsync", "tar", "gzip",
        "findutils", "diffutils", "coreutils",
        "kmod", "dwarves",
    ]

    missing = [p for p in packages if not rpm_installed(p)]
    if missing:
        fatal(
            "Missing build-dependencies (install with dnf/yum):\n  "
            + " ".join(missing)
            + "\nExample:\n  sudo dnf install -y " + " ".join(missing)
        )

    if shutil.which("rpmbuild") is None:
        fatal("rpmbuild not found in PATH (install rpm-build).")


def ensure_cross_compiler(cross_prefix: Optional[str], arch: str):
    if arch not in ("arm64", "aarch64"):
        return
    host = platform.machine()
    if host in ("aarch64", "arm64"):
        return  # native build, no cross needed
    if not cross_prefix:
        fatal(f"Host is {host}, target is {arch}. Provide --cross-prefix (e.g. aarch64-linux-gnu-).")
    cc = f"{cross_prefix}gcc"
    if shutil.which(cc) is None:
        fatal(f"Cross compiler not found: {cc}")
def main():
    parser = argparse.ArgumentParser(
        description="Build kernel in-place (Image + modules + dtbs) and run make binrpm-pkg"
    )
    parser.add_argument("--repo", default=GIT_REPO)
    parser.add_argument("--ref", default=GIT_REF)
    parser.add_argument("--linux-next", action="store_true")
    parser.add_argument("--qcom-next", action="store_true")
    parser.add_argument("--qcom-6.18.y", dest="qcom_618y", action="store_true",
                        help="Use qcom-6.18.y branch from qualcomm-linux/kernel")

    parser.add_argument("--local-dir", type=str, default=None,
                        help="Use existing kernel source tree instead of cloning")
    parser.add_argument("--work-dir", type=str, default="linux",
                        help="Directory to clone into (ignored with --local-dir)")

    parser.add_argument("--arch", default="arm64",
                        help="Target ARCH (default: arm64)")

    # Default cross-prefix: empty when running on aarch64, else aarch64-linux-gnu-
    default_cross = "" if platform.machine() in ("aarch64", "arm64") else "aarch64-linux-gnu-"
    parser.add_argument("--cross-prefix", default=default_cross,
                        help="CROSS_COMPILE prefix. Use '' for native builds.")

    parser.add_argument("--jobs", type=int, default=0,
                        help="Parallel jobs (default: nproc)")

    parser.add_argument("fragments", metavar="FRAGMENT", nargs="*",
                        help="Config fragments (local file path or arch/arm64/configs/<name>)")

    # Allow fragments after flags
    args, unknown = parser.parse_known_args()
    args.fragments = args.fragments + unknown

    # Repo defaults
    if args.linux_next and args.repo == GIT_REPO and args.ref == GIT_REF:
        args.repo, args.ref = LINUX_NEXT_GIT_REPO, LINUX_NEXT_GIT_REF
    if args.qcom_next and args.repo == GIT_REPO and args.ref == GIT_REF:
        args.repo, args.ref = QCOM_NEXT_GIT_REPO, QCOM_NEXT_GIT_REF
    if args.qcom_618y and args.repo == GIT_REPO and args.ref == GIT_REF:
        args.repo, args.ref = QCOM_618Y_GIT_REPO, QCOM_618Y_GIT_REF

    cross_prefix = args.cross_prefix.strip()
    if cross_prefix in ("''", '""', "none"):
        cross_prefix = ""

    check_dependencies()
    ensure_cross_compiler(cross_prefix if cross_prefix else None, args.arch)

    # Source directory
    if args.local_dir:
        linux_dir = Path(args.local_dir).resolve()
        if not linux_dir.exists():
            fatal(f"--local-dir does not exist: {linux_dir}")
        log_i(f"Using existing kernel source: {linux_dir}")
    else:
        linux_dir = Path(args.work_dir).resolve()
        if linux_dir.exists() and any(linux_dir.iterdir()):
            log_i(f"Directory {linux_dir} exists and is not empty; reusing it.")
        else:
            log_i(f"Cloning {args.repo}:{args.ref} into {linux_dir}")
            run(["git", "clone", "--depth=1", "--branch", args.ref, args.repo, str(linux_dir)])

    jobs = args.jobs if args.jobs > 0 else (os.cpu_count() or 8)

    # Prepare local fragments directory inside source tree
    local_conf_dir = linux_dir / "kernel" / "configs"
    local_conf_dir.mkdir(parents=True, exist_ok=True)

    arch_configs_dir = linux_dir / "arch" / "arm64" / "configs"

    QCOM_FRAGMENTS = ["prune.config", "qcom.config"]
    config_targets = []
    for name in QCOM_FRAGMENTS:
        if (arch_configs_dir / name).exists():
            log_i(f"Applying in-tree fragment: arch/arm64/configs/{name}")
            config_targets.append(f"arch/arm64/configs/{name}")

    for i, fragment in enumerate(args.fragments):
        frag_path = Path(fragment)
        if frag_path.exists():
            local_name = f"local_{i}.config"
            dest_path = local_conf_dir / local_name
            log_i(f"Copying local fragment {frag_path} -> {dest_path}")
            shutil.copy2(frag_path, dest_path)
            config_targets.append(f"kernel/configs/{local_name}")
        elif (arch_configs_dir / fragment).exists():
            log_i(f"Using repo fragment: {fragment}")
            config_targets.append(f"arch/arm64/configs/{fragment}")
        else:
            fatal(f"Fragment not found: {fragment}")

    # Env
    env = os.environ.copy()
    env["ARCH"] = args.arch
    if cross_prefix and args.arch in ("arm64", "aarch64"):
        env["CROSS_COMPILE"] = cross_prefix

    make_base = ["make", f"-j{jobs}"]

    # 1) base config
    log_i(f"Configuring kernel: {BASE_CONFIG}")
    run(make_base + [BASE_CONFIG], cwd=linux_dir, env=env)


    # 2) merge fragments (if any) -> .config in-tree
    if config_targets:
        merge = [str(linux_dir / "scripts" / "kconfig" / "merge_config.sh"),
                 "-m", "-r", ".config"] + config_targets
        run(merge, cwd=linux_dir, env=env)
        run(make_base + ["olddefconfig"], cwd=linux_dir, env=env)


    # 3) package RPMs (rpmbuild outputs under linux_dir/rpmbuild by default)
    log_i("Building RPMs via: make binrpm-pkg")
    run(make_base + ["binrpm-pkg"], cwd=linux_dir, env=env)

    # Report locations 
    boot_dir = linux_dir / "arch" / "arm64" / "boot"
    log_i("Done. Outputs kept in default kernel locations:")
    log_i(f"  Image : {boot_dir / 'Image'}")
    log_i(f"  Modules (*.ko): scattered under source tree (find . -name '*.ko')")
    log_i(f"  RPMs  : {linux_dir / 'rpmbuild' / 'RPMS'} (and SRPMS under rpmbuild/SRPMS)")


if __name__ == "__main__":
    main()
