# RPM Image Builder

## Overview

Generates CentOS Stream 10 (aarch64) disk images for Qualcomm RB3 Gen2 platforms using **[mkosi](https://mkosi.systemd.io/)**.

## Features

- Custom Linux kernel compilation (QCOM kernels, linux-next, upstream)
- CentOS Stream 10 OS image generation using **mkosi**
- Board-specific flash package generation (`generate_flat_build.sh`)

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

### Install mkosi

A recent version of mkosi is required:

```bash
pipx install -f git+https://github.com/systemd/mkosi.git
pipx ensurepath   # then restart your shell
```

### Host System Dependencies

```bash
# Fedora / CentOS Stream
sudo dnf install python3 git curl unzip mkdosfs mtools rpm-build dtc uboot-tools \
                 createrepo-c binfmt-support qemu-user-static systemd-repart \
                 uidmap pipx

# Ubuntu / Debian
sudo apt install python3 git curl unzip dosfstools mtools rpm dtc u-boot-tools \
                 createrepo-c binfmt-support qemu-user-static systemd-repart \
                 uidmap pipx
```

### Sub-UID/GID Setup (required for mkosi containerization)

```bash
echo "$USER:200000:65536" | sudo tee -a /etc/subuid
echo "$USER:200000:65536" | sudo tee -a /etc/subgid
```

### Enable aarch64 QEMU emulation (x86_64 hosts)

```bash
sudo update-binfmts --enable qemu-aarch64
```

### Disk Space

Minimum **50 GB** free in the build directory. The mkosi package cache
(`mkosi.cache/`) is reused across builds.

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
│  Phase 2: OS Image Generation (mkosi)                           │
│  └─→ mkosi build → build/output/image.raw                       │
│                                                                 │
│  Phase 3: Board-Specific Flash Packages                         │
│  └─→ generate_flat_build.sh                                     │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## Project Structure

```
.
├── mkosi.conf                   # Base mkosi config (arch, format, bootloader)
├── mkosi.conf.d/
│   └── centos.conf              # CentOS Stream 10 packages and services
├── mkosi.profiles/
│   ├── rb3gen2.conf             # RB3 Gen2 board profile (4K sectors, probe timeout)
├── mkosi.extra/
│   ├── etc/repart.d/50-root.conf  # Auto-grow root partition on first boot
│   └── usr/lib/firmware/          # Drop extra firmware files here
├── mkosi.packages/              # Drop custom kernel RPMs here before building
├── mkosi.postinst.chroot        # Creates 'qcom' user inside the image
├── scripts/
│   ├── build_binrpm_pkg.py      # Kernel RPM builder
│   └── generate_flat_build.sh
└── build/
    ├── output/
    │   ├── image.raw            # Full disk image (EFI + rootfs)
    │   ├── image.esp.raw        # EFI System Partition (VFAT)
    │   └── image.root-arm64.raw # Root filesystem (EXT4)
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
├── build/out/dtbs.tar.gz
└── rpmbuild/
    ├── RPMS/aarch64/kernel-*.rpm
    └── SRPMS/kernel-*.src.rpm
```

---

### Phase 2: OS Image Generation

**Tool**: `mkosi`

```bash
make image
```

This runs:
```bash
mkosi --profile rb3gen2 --force build
```

mkosi reads configuration from:
- `mkosi.conf` — base settings (distribution, architecture, bootloader, kernel cmdline)
- `mkosi.conf.d/centos.conf` — CentOS Stream 10 packages and services
- `mkosi.profiles/qcs6490-rb3gen2.conf` — RB3 Gen2 board settings
- `mkosi.profiles/ufs.conf` — UFS 4K sector size

**Output**
```
build/output/
└── image.raw    # Full GPT disk image (EFI System Partition + root filesystem)
```

#### Including a locally built kernel

Copy kernel RPMs into `mkosi.packages/` before building — no local HTTP server
is required:

```bash
cp work/linux/rpmbuild/RPMS/aarch64/*.rpm mkosi.packages/
make image
```

mkosi picks up all packages in `mkosi.packages/` automatically via
`PackageDirectories=mkosi.packages` in `mkosi.conf`.

#### Adding extra firmware

Place any firmware files not available in `linux-firmware` under
`mkosi.extra/usr/lib/firmware/` — they will be baked into the image:

```
mkosi.extra/usr/lib/firmware/
└── qcom/
    └── <board-specific firmware files>
```

---

### Phase 3: Board-Specific Flash Package Generation

`generate_flat_build.sh` downloads Qualcomm boot binaries and CDT files,
generates GPT partition tables via `qcom-ptool`, and assembles a complete
per-board flash directory ready for QDL / PCAT.

```bash
make flash
```

Or manually:
```bash
./scripts/generate_flat_build.sh \
  --dtbs-tar    build/output/dtbs.tar.gz \
  --esp-vfat    build/output/image.esp.raw \
  --rootfs-ext4 build/output/image.root-arm64.raw
```

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
| `--dtbs-tar=<path>` | `build/output/dtbs.tar.gz` | Legacy DTB tarball (fallback) |
| `--esp-vfat=<path>` | — | EFI System Partition image |
| `--rootfs-ext4=<path>` | — | Root filesystem image |
| `--target-boards=<list\|all>` | `all` | Comma-separated board names or `all` |
| `--verbose=(true\|false)` | `false` | Enable debug output |
| `ARTIFACTDIR=<path>` | `$PWD/build/out` | Output directory (env var) |

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
