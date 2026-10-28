# Qualcomm Linux RPM images

A collection of recipes to build Qualcomm Linux images for CentOS.

This repository provides [kiwi](https://osinside.github.io/kiwi/) recipes
based on CentOS Stream 10 for the Qualcomm RB3 Gen2 Development Kit
(QCS6490).

## Requirements

Install kiwi:

```bash
sudo pipx install kiwi
sudo pipx ensurepath   # then restart your shell
```

Building the image requires the following host dependencies:

```bash
# Fedora / CentOS Stream
sudo dnf install python3 git curl unzip dosfstools mtools rpm-build dtc uboot-tools \
                 createrepo_c e2fsprogs xfsprogs binfmt-support qemu-user-static parted kpartx \
                 grub2-efi-aa64 shim pipx

# Ubuntu / Debian
sudo apt install python3 python3-pip pipx git curl unzip dosfstools mtools rpm cpio \
                 device-tree-compiler u-boot-tools createrepo-c binfmt-support \
                 qemu-user-static qemu-utils parted kpartx e2fsprogs xfsprogs dnf
```

## Repositories

Images pull Qualcomm-specific packages (firmware, camera, DSP, GPU) from the
[Qualcomm RPM overlay repository](https://softwarecenter.qualcomm.com/nexus/rpm/centos/10/os/),
alongside CentOS Stream 10 (BaseOS, AppStream, CRB) and EPEL 10 for the rest
of the OS. All repositories are declared in [`kiwi/config.xml`](kiwi/config.xml).

## Steps

### (optional) Build a custom kernel

Build your own kernel:

```bash
# Native build of the qcom-next kernel
python3 scripts/build_binrpm_pkg.py --qcom-next

# Cross-compiled
python3 scripts/build_binrpm_pkg.py --qcom-next --cross-prefix aarch64-linux-gnu- --jobs 16
```

Copy the resulting RPMs into `packages/` before building the image; `make
image` runs `createrepo_c` on that directory automatically and adds it to
kiwi as a high-priority local repository:

```bash
cp linux/rpmbuild/RPMS/aarch64/kernel-*.rpm packages/
```

### Build the image

```bash
make image
```

This runs `kiwi` against [`kiwi/config.xml`](kiwi/config.xml) (repositories,
package list, image type, bootloader) and
[`kiwi/config.sh`](kiwi/config.sh), producing a full GPT disk image:

```
build/output/console/image.raw
```

To build the GNOME desktop variant instead of the headless console image:

```bash
make image KIWI_PROFILE=gnome
```

To build a performance variant, which quiets the serial console
(`quiet systemd.tty.term.console=dumb`) to avoid the boot-time and CPU cost
of synchronous output over the slow UART console, set `PERF_BUILD=1`.
This selects the base `console` or `gnome` content profile plus the `perf`
KIWI image-type profile. The standard and perf kernel command lines are defined in
[`kiwi/config.xml`](kiwi/config.xml), not in the Makefile:

```bash
make image PERF_BUILD=1
make image KIWI_PROFILE=gnome PERF_BUILD=1
```

If perf builds later need extra packages, add them to
[`kiwi/config.xml`](kiwi/config.xml) under a `packages` block with
`profiles="perf"`.

Internally the Makefile selects two KIWI profiles: one content profile
(`console` or `gnome`) and one image-type profile (`standard` or `perf`).
All variants use `KIWI_SHARED_CACHE` so KIWI/DNF repository metadata and
package cache can be reused between image builds.

#### Adding extra firmware

Place any firmware not available in `linux-firmware` under
`kiwi/root/usr/lib/firmware/qcom/` — it will be baked into the image.

### Extract flash artifacts

```bash
make flash-artifacts
```

Extracts the EFI System Partition and root filesystem from `image.raw` into
`build/output/<profile>/flashimages/` (`efi.bin`, `rootfs.img`, `dtbs.tar.gz`).

### Build board-specific flash packages

```bash
# Default board
make flash

# A specific board
make flash TARGET_BOARDS=qcs6490-rb3gen2

# All supported boards
make flash TARGET_BOARDS=all

# Perf image
make flash PERF_BUILD=1
```

`scripts/generate_flat_build.sh` downloads Qualcomm boot binaries and CDT
files, generates GPT partition tables via `qcom-ptool`, and assembles a
complete per-board flash directory ready for QDL. Flash outputs are
named with the active `KIWI_PROFILE`:

```
build/out/console-flash_qcs6490-rb3gen2_ufs/
├── prog_firehose_ddr_*.elf   # Firehose programmer
├── rawprogram*.xml           # Flash programming script
├── patch*.xml                # Patch script
├── gpt_*.bin                 # GPT partition table
├── efi.bin                   # EFI System Partition
├── rootfs.img                # Root filesystem
├── dtb.bin                   # DTB VFAT (FIT multi-DTB or single-DTB)
├── cdt.bin                   # Active CDT (vision-kit default)
├── cdt_core_kit.bin          # Core-kit CDT
├── cdt_industrial_kit.bin    # Industrial-kit CDT
└── vmlinux                   # Kernel ELF (for crash debugging)
```

#### CDT selection

All three kit variants share a single board entry and bundle all CDTs in the
flash directory; `cdt.bin` targets the vision-kit by default. To flash a
different kit, swap in the matching CDT file (e.g. `cdt_core_kit.bin`) for
`cdt.bin` before running QDL.

## Key options

### `generate_flat_build.sh`

| Option | Default | Description |
|---|---|---|
| `--dtbs-tar=<path>` | `flashimages/dtbs.tar.gz` | DTB tarball; FIT image auto-generated from it; falls back to single-DTB on failure |
| `--esp-vfat=<path>` | — | EFI System Partition image |
| `--rootfs-ext4=<path>` | — | Root filesystem image |
| `--target-boards=<list\|all>` | `all` | Comma-separated board names or `all` |
| `--use-fit-image=(true\|false)` | `true` | `true` = FIT multi-DTB via `build-dtb-image.sh` (falls back to single-DTB on failure); `false` = single-DTB |
| `--verbose=(true\|false)` | `false` | Enable debug output |

### Makefile variables

| Variable | Default | Description |
|---|---|---|
| `ARCH` | `aarch64` | Target architecture passed to kiwi-ng |
| `KIWI_PROFILE` | `console` | Image profile: `console` (headless) or `gnome` (desktop) |
| `PERF_BUILD` | `0` | `1` appends quiet serial-console kernel arguments |
| `TARGET_BOARDS` | `qcs6490-rb3gen2` | Comma-separated boards (or `all`) for `make flash` |
| `USE_FIT_IMAGE` | `1` | `1` = FIT multi-DTB image (recommended); `0` = single-DTB VFAT |
| `BUILD_OUTPUT` | `build/output` | Base directory for per-variant kiwi outputs |
| `ARTIFACTDIR` | `build/out` | Flash package output directory |
| `KIWI_SHARED_CACHE` | `build/kiwi-cache` | Shared KIWI package/cache directory reused across image variants |
| `EXTRA_FLASH_OPTS` | _unset_ | Extra flags forwarded to `generate_flat_build.sh` |
| `EXTRA_KIWI_OPTS` | _unset_ | Extra flags forwarded to `kiwi-ng` |
| `KIWI_PACKAGES_DIR` | `packages` | Directory for custom kernel RPMs |

See `make help` for the full list.

## Development

Please submit any patches using GitHub pull requests. Please read
[CONTRIBUTING.md file](CONTRIBUTING.md) for step by step instructions.

## License

This project is licensed under the [BSD-3-Clause-Clear License](https://spdx.org/licenses/BSD-3-Clause-Clear.html). See [LICENSE.txt](LICENSE.txt) for the full license text.
