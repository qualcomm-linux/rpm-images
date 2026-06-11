# RPM Image Builder

## Overview

Generates CentOS Stream 10 (aarch64) images for Qualcomm platforms.

## Features

- Custom Linux kernel compilation (QCOM kernels, linux-next, upstream)
- CentOS Stream 10 OS image generation using **osbuild / image-builder**
- Board-specific flash artifact generation (`generate_flat_build.sh`)

---

## Supported Targets

- **Operating System**: CentOS Stream 10
- **Architecture**: aarch64 (ARM64)
- **Platforms**:

| Board name | Storage |
|---|---|
| `qcs6490-rb3gen2-vision-kit` | UFS |
| `qcs6490-rb3gen2-core-kit` | UFS |
| `qcs6490-rb3gen2-industrial-kit` | UFS |

---

## Prerequisites

### System Requirements
- **Architecture**: ARM or x86_64 development host
- **Runtime**: `podman` or `docker` installed and running
- **Privileged Access**: `sudo` access required for container builds
- **Network**: Access to CentOS Stream mirrors and package repositories
- **Disk Space**: Minimum 200 GB free in build directory

### Host Tools
```bash
# Fedora / CentOS Stream
sudo dnf install podman python3 git curl unzip mkdosfs mtools

# Ubuntu / Debian
sudo apt install podman python3 git curl unzip dosfstools mtools
```

---

## Architecture & Build Pipeline

```
┌─────────────────────────────────────────────────────────────────┐
│                    QCOM RPM Image Build Flow                    │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Phase 1: Kernel Compilation (RPM)                              │
│  └─→ build_binrpm_pkg.py                                        │
│                                                                 │
│  Phase 2: OS Image Generation (osbuild)                         │
│  └─→ image-builder-cli (qcow2)                                  │
│                                                                 │
│  Phase 3: Flash Artifact Extraction                             │
│  └─→ extract_flash_artifacts.sh                                 │
│                                                                 │
│  Phase 4: Board-Specific Flash Packages                         │
│  └─→ generate_flat_build.sh                                     │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## Workspace & Output Directory Layout

```
.
├── downloads/                           # Cached boot-binary ZIPs (auto-populated)
├── work/                                # Ephemeral build scratch space
├── build/
│   ├── out/                             # Default ARTIFACTDIR
│   │   └── flash_<board>_<storage>/    # Board-specific flash packages
│   │       ├── prog_firehose_*.elf
│   │       ├── rawprogram*.xml
│   │       ├── patch*.xml
│   │       ├── gpt_*.bin
│   │       ├── efi.bin                 # EFI System Partition (VFAT)
│   │       ├── rootfs.img              # Root filesystem (EXT4)
│   │       └── dtb.bin                 # DTB VFAT (FIT or legacy)
│   └── output/
│       ├── centos-10-qcow2-aarch64.qcow2
│       ├── centos-10-qcow2-aarch64.qcow2.md5
│       ├── flashimages/
│       │   ├── efi.bin                 # Extracted EFI partition
│       │   └── rootfs.img              # Extracted root filesystem
│       └── fit/
│           └── dtb.bin                 # FIT DTB image (4 MB VFAT)
└── work/linux/
    ├── arch/arm64/boot/Image
    ├── arch/arm64/boot/dts/*.dtb
    ├── build/out/dtbs.tar.gz
    └── rpmbuild/
        ├── RPMS/aarch64/kernel-*.rpm
        └── SRPMS/kernel-*.src.rpm
```

---

## Detailed Workflow Phases

### Phase 1: Kernel Compilation (RPM)

**Script**: `scripts/build_binrpm_pkg.py`

**Native Compilation**
```bash
python3 scripts/build_binrpm_pkg.py --qcom-next
```

**Cross-Compilation Example**
```bash
python3 scripts/build_binrpm_pkg.py \
  --qcom-next \
  --cross-prefix aarch64-linux-gnu- \
  --jobs 16
```

**Kernel Outputs**
```
work/linux/
├── arch/arm64/boot/Image
├── arch/arm64/boot/dts/*.dtb
├── build/out/dtbs.tar.gz
└── rpmbuild/
    ├── RPMS/aarch64/kernel-*.rpm
    └── SRPMS/kernel-*.src.rpm
```

---

### Phase 2: OS Image Generation

**Tool**: `image-builder-cli` (osbuild)

```bash
sudo podman run --rm --privileged \
  --net=host \
  -v "$(pwd)/build/output:/output:rw" \
  -v "$(pwd)/build/logs:/var/log:rw" \
  -v "$(pwd)/configs/cs-stream-console-aarch64.toml:/blueprint.toml:ro" \
  ghcr.io/osbuild/image-builder-cli:latest build \
  --verbose \
  --distro centos-10 \
  --arch aarch64 \
  --extra-repo https://mirror.stream.centos.org/10-stream/BaseOS/aarch64/os/ \
  --extra-repo https://mirror.stream.centos.org/10-stream/AppStream/aarch64/os/ \
  --extra-repo https://mirror.stream.centos.org/10-stream/CRB/aarch64/os/ \
  --blueprint /blueprint.toml \
  qcow2 \
  --output-dir /output \
  2>&1 | tee build/build-cs-stream-console.log
```

To include locally built kernel RPMs, add an `--extra-repo` pointing to a local HTTP server serving the RPMs:

```bash
# Serve local RPMs (run in a separate terminal)
python3 -m http.server 8000 --directory work/linux/rpmbuild/RPMS/aarch64/

# Add to the podman run command above:
  --extra-repo http://host-ip:8000/
```

**Output**
```
build/output/
├── centos-10-qcow2-aarch64.qcow2
└── centos-10-qcow2-aarch64.qcow2.md5
```

---

### Phase 3: Flash Artifact Extraction

Extract the EFI System Partition and root filesystem from the qcow2 image.

```bash
scripts/extract_flash_artifacts.sh \
  build/output/centos-10-qcow2-aarch64.qcow2 \
  build/output/flashimages
```

**Outputs**
```
build/output/flashimages/
├── efi.bin       # EFI System Partition (VFAT, contains GRUB + kernel)
└── rootfs.img    # Root filesystem (EXT4)
```

> **Critical**: `efi.bin` and `rootfs.img` must always be extracted from the
> **same** qcow2 image.

---

### Phase 4: Board-Specific Flash Package Generation

`generate_flat_build.sh` downloads Qualcomm boot binaries and CDT files,
generates GPT partition tables via `qcom-ptool`, and assembles a complete
per-board flash directory ready for QDL / PCAT.

```bash
./scripts/generate_flat_build.sh \
  --dtbs-tar    work/linux/build/out/dtbs.tar.gz \
  --esp-vfat    build/output/flashimages/efi.bin \
  --rootfs-ext4 build/output/flashimages/rootfs.img
```

#### Build a subset of boards

```bash
# Single board
./scripts/generate_flat_build.sh \
  --target-boards qcs6490-rb3gen2-vision-kit \
  --dtb-bin     build/output/fit/dtb.bin \
  --esp-vfat    build/output/flashimages/efi.bin \
  --rootfs-ext4 build/output/flashimages/rootfs.img

# Multiple boards (comma-separated)
./scripts/generate_flat_build.sh \
  --target-boards qcs6490-rb3gen2-vision-kit,qcs6490-rb3gen2-core-kit \
  --dtb-bin     build/output/fit/dtb.bin \
  --esp-vfat    build/output/flashimages/efi.bin \
  --rootfs-ext4 build/output/flashimages/rootfs.img
```

#### Key options

| Option | Default | Description |
|---|---|---|
| `--dtb-bin=<path>` | — | FIT DTB VFAT image from `fit_build.py` (preferred) |
| `--dtbs-tar=<path>` | `linux/build/out/dtbs.tar.gz` | Legacy DTB tarball (fallback) |
| `--esp-vfat=<path>` | — | EFI System Partition image |
| `--rootfs-ext4=<path>` | — | Root filesystem image |
| `--target-boards=<list\|all>` | `all` | Comma-separated board names or `all` |
| `--verbose=(true\|false)` | `false` | Enable debug output |
| `ARTIFACTDIR=<path>` | `$PWD/build/out` | Output directory (env var) |

**Flash outputs**
```
build/out/
└── flash_<board>_<ufs|emmc>/
    ├── prog_firehose_ddr_*.elf   # Firehose programmer
    ├── rawprogram*.xml           # Flash programming script
    ├── patch*.xml                # Patch script
    ├── gpt_*.bin                 # GPT partition table
    ├── efi.bin                   # EFI System Partition
    ├── rootfs.img                # Root filesystem
    ├── dtb.bin                   # DTB VFAT (FIT or legacy)
    ├── cdt_*.bin                 # Board CDT
    └── vmlinux                   # Kernel ELF (for crash debugging)
```

---

## License

*\<update with your project name and license\>*

*\<REPLACE-ME\>* is licensed under the [BSD-3-clause License](https://spdx.org/licenses/BSD-3-Clause.html). See [LICENSE.txt](LICENSE.txt) for the full license text.
