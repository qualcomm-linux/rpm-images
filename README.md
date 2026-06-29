# RPM Image Builder

## Overview

Generates CentOS Stream 10 (aarch64) disk images for Qualcomm RB3 Gen2 platforms using **[kiwi-ng](https://osinside.github.io/kiwi/)**.

## Features

- Custom Linux kernel compilation (QCOM kernels, linux-next, upstream)
- CentOS Stream 10 OS image generation using **kiwi-ng**
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

### Install kiwi-ng

```bash
sudo pipx install kiwi
sudo pipx ensurepath   # then restart your shell
```

### Host System Dependencies

```bash
# Fedora / CentOS Stream
sudo dnf install python3 git curl unzip dosfstools mtools rpm-build dtc uboot-tools \
                 createrepo-c binfmt-support qemu-user-static parted kpartx \
                 grub2-efi-aa64 shim pipx

# Ubuntu / Debian
sudo apt install python3 python3-pip pipx git curl unzip dosfstools mtools rpm cpio \
                 dtc u-boot-tools createrepo-c binfmt-support qemu-user-static \
                 parted kpartx e2fsprogs xfsprogs grub-efi-aarch64-bin shim-signed dnf
```

### Disk Space

Minimum **50 GB** free in the build directory.

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
│  Phase 2: OS Image Generation (kiwi-ng)                         │
│  └─→ kiwi-ng build → build/output/image.raw                     │
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

## Project Structure

```
.
├── kiwi/
│   ├── config.xml               # kiwi image description (repos, packages, type)
│   ├── config.sh                # Post-install script (hostname, password, locale)
│   └── root/
│       └── etc/repart.d/
│           └── 50-root.conf     # Auto-grow root partition on first boot
├── packages/                    # Drop custom kernel RPMs here before building
├── scripts/
│   ├── build_binrpm_pkg.py      # Kernel RPM builder
│   ├── extract_flash_artifacts.sh
│   └── generate_flat_build.sh
└── build/
    ├── output/
    │   ├── image.raw            # Full disk image (EFI + rootfs)
    │   └── flashimages/
    │       ├── efi.bin          # Extracted EFI System Partition
    │       ├── rootfs.img       # Extracted root filesystem
    │       └── dtbs.tar.gz      # Extracted device tree blobs
    └── out/
        └── flash_<board>_<storage>/  # Per-board flash packages
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
└── rpmbuild/
    ├── RPMS/aarch64/kernel-*.rpm
    └── SRPMS/kernel-*.src.rpm
```

---

### Phase 2: OS Image Generation

**Tool**: `kiwi-ng`

```bash
make image
```

This runs:
```bash
sudo kiwi-ng --type oem system build \
  --description kiwi/ \
  --target-dir build/output \
  [--add-repo file://$PWD/packages,rpm-md,local-packages,1]
```

kiwi reads configuration from:
- `kiwi/config.xml` — image type, repositories, package list, bootloader, kernel cmdline
- `kiwi/config.sh` — post-install script (hostname, root password, locale, services)
- `kiwi/root/` — overlay files copied verbatim into the image

**Output**
```
build/output/
└── image.raw    # Full GPT disk image (EFI System Partition + root filesystem)
```

#### Including a locally built kernel

Copy kernel RPMs into `packages/` before building — `make image` will
automatically run `createrepo_c` on the directory and pass it to kiwi as a
high-priority local repository:

```bash
cp work/linux/rpmbuild/RPMS/aarch64/*.rpm packages/
make image
```

#### Adding extra firmware

Place any firmware files not available in `linux-firmware` under
`kiwi/root/usr/lib/firmware/` — they will be baked into the image:

```
kiwi/root/usr/lib/firmware/
└── qcom/
    └── <board-specific firmware files>
```

---

### Phase 3: Flash Artifact Extraction

Extract the EFI System Partition and root filesystem from the raw disk image.

```bash
make flash-artifacts
```

Or manually:
```bash
sudo scripts/extract_flash_artifacts.sh \
  build/output/image.raw \
  build/output/flashimages
```

</details>

**Outputs**
```
build/output/flashimages/
├── efi.bin       # EFI System Partition (VFAT, contains GRUB2 + kernel)
├── rootfs.img    # Root filesystem (EXT4)
└── dtbs.tar.gz   # Device tree blobs
```

---

### Phase 4: Board-Specific Flash Package Generation

`generate_flat_build.sh` downloads Qualcomm boot binaries and CDT files,
generates GPT partition tables via `qcom-ptool`, and assembles a complete
per-board flash directory ready for QDL / PCAT. Drive it through the Makefile:

```bash
# All supported boards (default)
make flash

# A specific board
make flash TARGET_BOARDS=qcs6490-rb3gen2-vision-kit
```

<details>
<summary>Under the hood: the raw <code>generate_flat_build.sh</code> invocation</summary>

```bash
make flash
```

Or manually:
```bash
./scripts/generate_flat_build.sh \
  --dtbs-tar    build/output/flashimages/dtbs.tar.gz \
  --esp-vfat    build/output/flashimages/efi.bin \
  --rootfs-ext4 build/output/flashimages/rootfs.img
```

</details>

#### Build a subset of boards

```bash
# Single board
make flash TARGET_BOARDS=qcs6490-rb3gen2-vision-kit

# Multiple boards (comma-separated)
make flash TARGET_BOARDS=qcs6490-rb3gen2-vision-kit,qcs6490-rb3gen2-core-kit
```

#### Key options

| Option | Default | Description |
|---|---|---|
| `--dtb-bin=<path>` | — | FIT DTB VFAT image from `fit_build.py` (preferred) |
| `--dtbs-tar=<path>` | `flashimages/dtbs.tar.gz` | Legacy DTB tarball (fallback) |
| `--esp-vfat=<path>` | — | EFI System Partition image |
| `--rootfs-ext4=<path>` | — | Root filesystem image |
| `--target-boards=<list\|all>` | `all` | Comma-separated board names or `all` |
| `--verbose=(true\|false)` | `false` | Enable debug output |
| `ARTIFACTDIR=<path>` | `$PWD/build/out` | Output directory (env var) |

#### Makefile variables

The Makefile targets (`make image`, `make flash-artifacts`, `make flash`) accept
these overrides on the command line (see `make help` for the full list):

| Variable | Default | Description |
|---|---|---|
| `LOCAL_RPMS_DIR` | _unset_ | Directory of local kernel RPMs; mounted as a `file://` dnf repo for `make image` |
| `LOCAL_KERNEL_REPO` | _unset_ | URL of a local HTTP server serving kernel RPMs |
| `TARGET_BOARDS` | `qcs6490-rb3gen2-vision-kit` | Comma-separated boards (or `all`) for `make flash` |
| `EXTRA_FLASH_OPTS` | _unset_ | Extra flags forwarded to `generate_flat_build.sh` |

**Flash outputs**
```
build/out/
└── flash_<board>_<ufs>/
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
