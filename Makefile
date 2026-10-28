#   make image           1: Build CentOS Stream 10 disk image with kiwi
#   make flash-artifacts 2: Extract EFI + rootfs from raw disk image
#   make flash           3: Assemble per-board flash packages (default)

SHELL := /bin/bash

ARCH     ?= aarch64

BUILD_LOGS   ?= build/logs

space := $(empty) $(empty)

KIWI_PROFILE     ?= console
PERF_BUILD       ?= 0
PERF_BUILD_TRUE  = $(filter 1 true yes y,$(PERF_BUILD))
KIWI_TYPE_PROFILE = $(if $(PERF_BUILD_TRUE),perf,standard)
KIWI_PROFILE_OPTS = --profile $(KIWI_PROFILE) --profile $(KIWI_TYPE_PROFILE)
PERF_SUFFIX      = $(if $(PERF_BUILD_TRUE),-perf)
KIWI_PROFILE_SLUG = $(subst $(space),-,$(KIWI_PROFILE))$(PERF_SUFFIX)

BUILD_OUTPUT ?= build/output
KIWI_TARGET_DIR = $(BUILD_OUTPUT)/$(KIWI_PROFILE_SLUG)
KIWI_SHARED_CACHE ?= build/kiwi-cache

# Optional: extra kiwi-ng flags
EXTRA_KIWI_OPTS ?=

# Directory for custom kernel RPMs (populated before 'make image')
KIWI_PACKAGES_DIR ?= packages

ARTIFACTDIR      ?= build/out
TARGET_BOARDS    ?= qcs6490-rb3gen2
# Set USE_FIT_IMAGE=0 to use single-DTB mode instead of FIT multi-DTB
USE_FIT_IMAGE    ?= 1
EXTRA_FLASH_OPTS ?=

export ARTIFACTDIR BUILD_OUTPUT KIWI_PROFILE_SLUG

IMAGE_RAW    := $(KIWI_TARGET_DIR)/image.raw
FLASHIMAGES  := $(KIWI_TARGET_DIR)/flashimages
EFI_BIN      := $(FLASHIMAGES)/efi.bin
ROOTFS_IMG   := $(FLASHIMAGES)/rootfs.img
DTBS_TAR     := $(FLASHIMAGES)/dtbs.tar.gz
KIWI_FILES   := $(shell find kiwi -type f)

.PHONY: all image dtbs flash-artifacts flash clean clean-cache clean-downloads help

all: flash

# Build (or refresh) the local RPM-MD repository index.
$(KIWI_PACKAGES_DIR)/repodata: $(wildcard $(KIWI_PACKAGES_DIR)/*.rpm)
	createrepo_c $(KIWI_PACKAGES_DIR)/

$(IMAGE_RAW): $(KIWI_FILES) $(KIWI_PACKAGES_DIR)/repodata
	mkdir -p $(KIWI_TARGET_DIR) $(BUILD_LOGS) $(KIWI_SHARED_CACHE)
	sudo kiwi-ng --target-arch $(ARCH) $(KIWI_PROFILE_OPTS) --type oem \
	  --shared-cache-dir $(KIWI_SHARED_CACHE) \
	  system build \
	  --description kiwi/ \
	  --target-dir $(KIWI_TARGET_DIR) \
	  --add-repo file://$(CURDIR)/$(KIWI_PACKAGES_DIR),rpm-md,local-packages,1 \
	  $(EXTRA_KIWI_OPTS) \
	  2>&1 | tee $(BUILD_LOGS)/build-cs-stream-$(KIWI_PROFILE_SLUG).log
	@# Rename kiwi output (e.g. centos-stream10-aarch64.aarch64-10.0.0.raw) to image.raw
	@find $(KIWI_TARGET_DIR) -maxdepth 1 -name "*.raw" ! -name "image.raw" \
	  | head -1 | xargs -I{} mv {} $(IMAGE_RAW) 2>/dev/null || true
	@test -f $(IMAGE_RAW) || { echo "[!] kiwi did not produce $(IMAGE_RAW)"; exit 1; }

image: $(IMAGE_RAW)

dtbs: $(DTBS_TAR)

$(FLASHIMAGES)/.extracted: $(IMAGE_RAW)
	mkdir -p $(FLASHIMAGES)
	sudo scripts/extract_flash_artifacts.sh $< $(FLASHIMAGES)
	@touch $@

$(EFI_BIN) $(ROOTFS_IMG) $(DTBS_TAR): $(FLASHIMAGES)/.extracted

flash-artifacts: $(EFI_BIN) $(ROOTFS_IMG) $(DTBS_TAR)

flash: $(EFI_BIN) $(ROOTFS_IMG) $(DTBS_TAR)
	./scripts/generate_flat_build.sh \
	  --dtbs-tar=$(DTBS_TAR) \
	  --esp-vfat=$(EFI_BIN) \
	  --rootfs-ext4=$(ROOTFS_IMG) \
	  --target-boards=$(TARGET_BOARDS) \
	  --use-fit-image=$(USE_FIT_IMAGE) \
	  $(EXTRA_FLASH_OPTS)

clean:
	rm -rf $(BUILD_OUTPUT) $(ARTIFACTDIR) $(BUILD_LOGS)

# Remove the generated repodata index from the local packages directory
clean-cache:
	rm -rf $(KIWI_PACKAGES_DIR)/repodata $(KIWI_SHARED_CACHE)

# Remove cached boot-binary and CDT downloads
clean-downloads:
	rm -rf downloads/

help:
	@echo "Usage: make [TARGET] [VARIABLE=value ...]"
	@echo ""
	@echo "Build targets:"
	@echo "  image           Step 1: Build CentOS Stream 10 disk image (kiwi)"
	@echo "  flash-artifacts Step 2: Extract EFI + rootfs from raw disk image"
	@echo "  flash           Step 3: Assemble per-board flash packages"
	@echo "  all             All steps (default)"
	@echo ""
	@echo "Utility targets:"
	@echo "  clean           Remove build outputs (build/output, build/out, build/logs)"
	@echo "  clean-cache     Remove local package repo repodata and kiwi shared cache"
	@echo "  clean-downloads Remove cached boot-binary and CDT downloads"
	@echo "  help            Show this help"
	@echo ""
	@echo "Variables (override on command line):"
	@echo "  KIWI_PROFILE       Single image profile (default: $(KIWI_PROFILE))"
	@echo "                     console              = headless"
	@echo "                     gnome                = GNOME desktop"
	@echo "  PERF_BUILD         1 = select kiwi perf profile (default: $(PERF_BUILD))"
	@echo "  TARGET_BOARDS      Boards to flash; use 'all' for every board (default: $(TARGET_BOARDS))"
	@echo "  USE_FIT_IMAGE      1 = FIT multi-DTB image, 0 = single-DTB VFAT (default: $(USE_FIT_IMAGE))"
	@echo "  EXTRA_KIWI_OPTS    Extra flags for kiwi-ng"
	@echo "  EXTRA_FLASH_OPTS   Extra flags for generate_flat_build.sh"
	@echo ""
	@echo "Example: include custom RPMs before 'make image':"
	@echo "  cp work/linux/rpmbuild/RPMS/aarch64/*.rpm $(KIWI_PACKAGES_DIR)/"
	@echo ""
	@echo "Example: build GNOME desktop image:"
	@echo "  make flash KIWI_PROFILE=gnome"
	@echo ""
	@echo "Example: build the headless perf image:"
	@echo "  make flash PERF_BUILD=1"
