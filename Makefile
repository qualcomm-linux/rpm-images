#   make image           1: Build CentOS Stream qcow2 image
#   make flash-artifacts 2: Extract EFI + rootfs from qcow2
#   make flash           3: Assemble per-board flash packages (default)

BLUEPRINT ?= configs/cs-stream-console-aarch64.toml
DISTRO    ?= centos-10
ARCH      ?= aarch64

BUILD_OUTPUT ?= build/output
BUILD_LOGS   ?= build/logs

IMAGE_BUILDER_IMAGE ?= ghcr.io/osbuild/image-builder-cli:latest

# CentOS Stream mirrors for image-builder-cli
CENTOS_MIRROR ?= https://mirror.stream.centos.org/10-stream
EXTRA_REPOS   ?= \
  --extra-repo $(CENTOS_MIRROR)/BaseOS/$(ARCH)/os/ \
  --extra-repo $(CENTOS_MIRROR)/AppStream/$(ARCH)/os/ \
  --extra-repo $(CENTOS_MIRROR)/CRB/$(ARCH)/os/

# Optional: URL of a local HTTP server serving kernel RPMs.
# Example (run in a separate terminal before 'make image'):
#   python3 -m http.server 8000 --directory /path/to/rpms/
# Then:
#   make image LOCAL_KERNEL_REPO=http://<host-ip>:8000/
LOCAL_KERNEL_REPO ?=

EXTRA_IMAGE_BUILDER_OPTS ?=
SBOM              ?= 1

# DTBS_TAR: path to the DTB tarball produced by the kernel build (required).
DTBS_TAR ?=

ARTIFACTDIR      ?= build/out
TARGET_BOARDS    ?= qcs6490-rb3gen2-vision-kit
EXTRA_FLASH_OPTS ?=

export ARTIFACTDIR

QCOW2       := $(BUILD_OUTPUT)/centos-10-qcow2-$(ARCH).qcow2
FLASHIMAGES := $(BUILD_OUTPUT)/flashimages
EFI_BIN     := $(FLASHIMAGES)/efi.bin
ROOTFS_IMG  := $(FLASHIMAGES)/rootfs.img

.PHONY: all image flash-artifacts flash clean clean-downloads help

all: flash

# Builds a CentOS Stream 10 aarch64 qcow2 image via image-builder-cli.
# Output: $(QCOW2)
$(QCOW2): $(BLUEPRINT)
	mkdir -p $(BUILD_OUTPUT) $(BUILD_LOGS)
	podman run --rm --privileged \
	  --net=host \
	  -v "$(CURDIR)/$(BUILD_OUTPUT):/output:rw" \
	  -v "$(CURDIR)/$(BUILD_LOGS):/var/log:rw" \
	  -v "$(CURDIR)/$(BLUEPRINT):/blueprint.toml:ro" \
	  $(IMAGE_BUILDER_IMAGE) build \
	  --verbose \
	  --distro $(DISTRO) \
	  --arch $(ARCH) \
	  $(EXTRA_REPOS) \
	  $(if $(LOCAL_KERNEL_REPO),--extra-repo $(LOCAL_KERNEL_REPO)) \
	  --blueprint /blueprint.toml \
	  qcow2 \
	  --output-dir /output \
	  $(if $(SBOM),--with-sbom) \
	  $(EXTRA_IMAGE_BUILDER_OPTS) \
	  2>&1 | tee $(BUILD_LOGS)/build-cs-stream-console.log

image: $(QCOW2)

$(FLASHIMAGES)/.extracted: $(QCOW2)
	sudo scripts/extract_flash_artifacts.sh $< $(FLASHIMAGES)
	@touch $@

$(EFI_BIN) $(ROOTFS_IMG): $(FLASHIMAGES)/.extracted

flash-artifacts: $(EFI_BIN) $(ROOTFS_IMG)

flash: $(EFI_BIN) $(ROOTFS_IMG)
	@[ -n "$(DTBS_TAR)" ] || { \
	  echo "ERROR: DTBS_TAR is required."; \
	  echo "  Generate it from your kernel tree."; \
	  exit 1; \
	}
	./scripts/generate_flat_build.sh \
	  --dtbs-tar=$(DTBS_TAR) \
	  --esp-vfat=$(EFI_BIN) \
	  --rootfs-ext4=$(ROOTFS_IMG) \
	  --target-boards=$(TARGET_BOARDS) \
	  $(EXTRA_FLASH_OPTS)

clean:
	rm -rf $(BUILD_OUTPUT) $(ARTIFACTDIR) $(BUILD_LOGS)

# Remove cached boot-binary and CDT downloads
clean-downloads:
	rm -rf downloads/

help:
	@echo "Usage: make [TARGET] [VARIABLE=value ...]"
	@echo ""
	@echo "Build targets:"
	@echo "  image           Step 1: Build CentOS Stream qcow2 (image-builder-cli)"
	@echo "  flash-artifacts Step 2: Extract EFI + rootfs from qcow2"
	@echo "  flash           Step 3: Assemble per-board flash packages"
	@echo "  all             All steps (default)"
	@echo ""
	@echo "Utility targets:"
	@echo "  clean           Remove build outputs (BUILD_OUTPUT, ARTIFACTDIR, BUILD_LOGS)"
	@echo "  clean-downloads Remove cached boot-binary and CDT downloads"
	@echo "  help            Show this help"
	@echo ""
	@echo "Variables (override on command line):"
	@echo "  DTBS_TAR             DTB tarball (required; no default)"
	@echo "  BLUEPRINT            Image blueprint TOML (default: $(BLUEPRINT))"
	@echo "  DISTRO               OS distro for image-builder (default: $(DISTRO))"
	@echo "  ARCH                 Target architecture (default: $(ARCH))"
	@echo "  LOCAL_KERNEL_REPO    URL of local kernel RPM HTTP server (default: unset)"
	@echo "  TARGET_BOARDS        Boards to flash (default: $(TARGET_BOARDS))"
	@echo "                       Use 'all' to build all supported boards"
	@echo "  ARTIFACTDIR          Flash package output directory (default: $(ARTIFACTDIR))"
	@echo "  EXTRA_FLASH_OPTS     Extra flags for generate_flat_build.sh"
	@echo "  EXTRA_IMAGE_BUILDER_OPTS  Extra flags for image-builder-cli"
	@echo "  SBOM                 Generate SBOM; pass --with-sbom to image-builder-cli (default: 1)"
