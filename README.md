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
sudo dnf install podman python3 git curl unzip mkdosfs mtools rpm-build dtc uboot-tools createrepo-c

# Ubuntu / Debian
sudo apt install podman python3 git curl unzip dosfstools mtools rpm dtc u-boot-tools createrepo-c
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
│  Phase 2: Manifest Generation                                   │
│  └─→ image-builder-cli --with-manifest  (resolves RPM SHAs)    │
│  └─→ patch_manifest.py                  (injects efi/rootfs     │
│                                          pipelines)             │
│                                                                 │
│  Phase 3: Image Build (osbuild)                                 │
│  └─→ osbuild → efi.bin + rootfs.img  (no qcow2, no extraction) │
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
│       ├── flashimages/
│       │   ├── efi-image/
│       │   │   └── efi.bin             # EFI partition (FAT32, 4K sectors)
│       │   └── rootfs-image/
│       │       └── rootfs.img          # Root filesystem (EXT4)
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

### Phase 2: Manifest Generation

`make manifest` runs two steps:

1. **`image-builder-cli --with-manifest`** — depsolves the blueprint against
   CentOS Stream 10 (BaseOS + AppStream + CRB) and optionally a local kernel
   RPM repo.  Writes a raw osbuild v2 manifest with every RPM's SHA-256
   checksum and download URL baked in.

2. **`scripts/patch_manifest.py`** — replaces the `image`/`qcow2` pipelines
   in the raw manifest with `efi-image` and `rootfs-image` pipelines that
   emit raw images directly.  Writes `configs/osbuild-pipeline.json`.

```bash
# Serve your locally built kernel RPMs (separate terminal)
python3 -m http.server 8000 --directory work/linux/rpmbuild/RPMS/aarch64/

# Generate the manifest
make manifest LOCAL_RPMS=http://10.147.152.194:8000/

# Without a custom kernel (uses stock CentOS kernel):
make manifest
```

> `configs/osbuild-pipeline.json` is **not committed** to the repo — it
> embeds SHA-256 checksums tied to your specific kernel RPM build.  Every
> developer generates their own copy.

---

### Phase 3: Image Build (osbuild)

`make image` runs osbuild inside the image-builder-cli container against the
manifest.  osbuild downloads every RPM from the URL baked into the manifest
and produces `efi.bin` and `rootfs.img` directly — no qcow2, no extraction.

```bash
make image
```

**Outputs**
```
build/output/flashimages/
├── efi-image/
│   └── efi.bin       # EFI partition (FAT32, 4096-byte sectors for UFS)
└── rootfs-image/
    └── rootfs.img    # Root filesystem (EXT4)
```

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