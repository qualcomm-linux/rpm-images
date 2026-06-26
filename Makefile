#   make image           1: Build CentOS Stream 10 disk image with mkosi
#                           (also produces image.efi and image.rootfs.raw directly)
#   make flash           2: Assemble per-board flash packages (default)

ARCH     ?= aarch64
PROFILES ?= --profile rb3gen2

BUILD_OUTPUT ?= build/output
BUILD_LOGS   ?= build/logs

# Optional: extra mkosi flags (e.g. --force to overwrite without prompting)
EXTRA_MKOSI_OPTS ?=

ARTIFACTDIR      ?= build/out
TARGET_BOARDS    ?= qcs6490-rb3gen2-vision-kit
EXTRA_FLASH_OPTS ?=

export ARTIFACTDIR

IMAGE_RAW    := $(BUILD_OUTPUT)/image.raw
IMAGE_EFI    := $(BUILD_OUTPUT)/image.efi
# systemd-repart inserts SplitName before the ".raw" extension:
#   SplitName=esp    -> image.esp.raw   (FAT32 filesystem, flashed to efi partition)
#   SplitName=rootfs -> image.rootfs.raw (ext4 filesystem, flashed to rootfs partition)
# image.efi is the UKI PE binary (used for direct kernel boot / qemu), NOT for flashing.
IMAGE_ESP    := $(BUILD_OUTPUT)/image.esp.raw
IMAGE_ROOTFS := $(BUILD_OUTPUT)/image.root-arm64.raw
FLASHIMAGES  := $(BUILD_OUTPUT)/flashimages
# dtbs.tar.gz is produced by mkosi.postinst.d/10-dtbs.chroot into BUILD_OUTPUT
# (mkosi maps $OUTPUTDIR inside the chroot to the host-side output directory).
DTBS_TAR     := $(BUILD_OUTPUT)/dtbs.tar.gz

.PHONY: all image flash-artifacts flash clean clean-cache clean-downloads help

all: flash

# mkosi produces image.raw (full disk), image.efi (UKI), and image.rootfs.raw
# (raw ext4 partition) in one pass when SplitArtifacts=yes and mkosi.repart/
# defines SplitName=rootfs on the root partition.  systemd-repart inserts the
# SplitName before ".raw", giving image.rootfs.raw.  No sudo needed.
$(IMAGE_RAW) $(IMAGE_EFI) $(IMAGE_ESP) $(IMAGE_ROOTFS) $(DTBS_TAR): mkosi.conf mkosi.conf.d/centos.conf mkosi.postinst.d/10-dtbs.chroot
	mkdir -p $(BUILD_OUTPUT) $(BUILD_LOGS) mkosi.packages
	umask 0022 && mkosi \
	  $(PROFILES) \
	  -O $(BUILD_OUTPUT) \
	  --force \
	  $(EXTRA_MKOSI_OPTS) \
	  build \
	  2>&1 | tee $(BUILD_LOGS)/build-cs-stream-console.log
	@test -f $(IMAGE_RAW)    || { echo "[!] mkosi did not produce $(IMAGE_RAW)";    exit 1; }
	@test -f $(IMAGE_EFI)    || { echo "[!] mkosi did not produce $(IMAGE_EFI)";    exit 1; }
	@test -f $(IMAGE_ROOTFS) || { echo "[!] mkosi did not produce $(IMAGE_ROOTFS)";   exit 1; }
	@test -f $(DTBS_TAR)    || { echo "[!] mkosi.postinst.d/10-dtbs.chroot did not produce $(DTBS_TAR)"; exit 1; }

image: $(IMAGE_RAW) $(IMAGE_EFI) $(IMAGE_ESP) $(IMAGE_ROOTFS) $(DTBS_TAR)

flash-artifacts: $(IMAGE_EFI) $(IMAGE_ESP) $(IMAGE_ROOTFS) $(DTBS_TAR)

flash: $(IMAGE_ESP) $(IMAGE_ROOTFS) $(DTBS_TAR)
	./scripts/generate_flat_build.sh \
	  --dtbs-tar=$(DTBS_TAR) \
	  --esp-vfat=$(IMAGE_ESP) \
	  --rootfs-ext4=$(IMAGE_ROOTFS) \
	  --target-boards=$(TARGET_BOARDS) \
	  $(EXTRA_FLASH_OPTS)

clean:
	rm -rf $(BUILD_OUTPUT) $(ARTIFACTDIR) $(BUILD_LOGS)

# Remove the mkosi package cache (forces re-download of all packages)
clean-cache:
	rm -rf mkosi.cache/

# Remove cached boot-binary and CDT downloads
clean-downloads:
	rm -rf downloads/

help:
	@echo "Usage: make [TARGET] [VARIABLE=value ...]"
	@echo ""
	@echo "Build targets:"
	@echo "  image           Step 1: Build disk image (mkosi) — also emits image.efi + image.rootfs.raw"
	@echo "  flash           Step 2: Assemble per-board flash packages"
	@echo "  flash-artifacts Alias: image.efi + image.rootfs.raw + dtbs.tar.gz"
	@echo "  all             All steps (default)"
	@echo ""
	@echo "Utility targets:"
	@echo "  clean           Remove build outputs (BUILD_OUTPUT, ARTIFACTDIR, BUILD_LOGS)"
	@echo "  clean-cache     Remove mkosi package cache (mkosi.cache/)"
	@echo "  clean-downloads Remove cached boot-binary and CDT downloads"
	@echo "  help            Show this help"
	@echo ""
	@echo "Variables (override on command line):"
	@echo "  PROFILES         mkosi profile flags (default: $(PROFILES))"
	@echo "  TARGET_BOARDS    Boards to flash (default: $(TARGET_BOARDS))"
	@echo "                   Use 'all' to build all supported boards"
	@echo "  ARTIFACTDIR      Flash package output directory (default: $(ARTIFACTDIR))"
	@echo "  EXTRA_FLASH_OPTS Extra flags for generate_flat_build.sh"
	@echo "  EXTRA_MKOSI_OPTS Extra flags for mkosi"
	@echo ""
	@echo "To include a custom kernel, copy RPMs into mkosi.packages/ before 'make image':"
	@echo "  cp work/linux/rpmbuild/RPMS/aarch64/*.rpm mkosi.packages/"
