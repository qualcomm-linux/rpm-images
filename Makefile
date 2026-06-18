# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
#
# Makefile — generate efi.bin + rootfs.img directly via osbuild, then
#            assemble per-board flash packages.
#
# Workflow
# --------
#   Step 1 — Generate the manifest (once per kernel/blueprint change):
#
#     make manifest LOCAL_RPMS=http://<host>:8000/
#
#     image-builder-cli resolves all RPM checksums and writes them into
#     configs/osbuild-pipeline.json.  patch_manifest.py then replaces the
#     qcow2/image pipelines with efi-image + rootfs-image pipelines so
#     osbuild emits raw images directly — no qcow2, no extraction step.
#
#   Step 2 — Build the images (osbuild reads the manifest, downloads RPMs):
#
#     make image
#
#   Step 3 — Assemble per-board flash packages:
#
#     make flash DTBS_TAR=linux/build/out/dtbs.tar.gz

# ---------------------------------------------------------------------------
# Tunables
# ---------------------------------------------------------------------------
BLUEPRINT     ?= configs/cs-stream-console-aarch64.toml
MANIFEST      ?= configs/osbuild-pipeline.json

# LOCAL_RPMS: HTTP URL of a local RPM repo serving your custom Qcom kernel.
# Only needed for 'make manifest'.  osbuild bakes the URL + checksum into the
# manifest so 'make image' fetches the kernel directly — no local repo needed
# at build time.
# Example: make manifest LOCAL_RPMS=http://10.147.152.194:8000/
LOCAL_RPMS ?=

ARCH          ?= aarch64
DISTRO        ?= centos-10
EFI_SIZE_MIB  ?= 512
ROOT_SIZE_GIB ?= 8

BUILD_OUTPUT  ?= build/output
BUILD_LOGS    ?= build/logs
OSBUILD_STORE ?= build/osbuild-store

FLASHIMAGES := $(BUILD_OUTPUT)/flashimages
EFI_BIN     := $(FLASHIMAGES)/efi-image/efi.bin
ROOTFS_IMG  := $(FLASHIMAGES)/rootfs-image/rootfs.img

# image-builder-cli container — ships both image-builder-cli and osbuild.
IBC_IMAGE ?= ghcr.io/osbuild/image-builder-cli:latest

# CentOS Stream 10 mirrors.  --force-repo replaces the built-in distro repo
# set so BaseOS + AppStream + CRB are all visible during depsolve.
CENTOS_MIRROR ?= https://mirror.stream.centos.org/10-stream

# DTBS_TAR: DTB tarball from the kernel build (required for 'make flash').
DTBS_TAR ?=

ARTIFACTDIR      ?= build/out
TARGET_BOARDS    ?= qcs6490-rb3gen2-vision-kit
EXTRA_FLASH_OPTS ?=

export ARTIFACTDIR

# Auto-detect container runtime once at parse time.
RUNTIME := $(or $(shell command -v podman 2>/dev/null),$(shell command -v docker 2>/dev/null))
ifeq ($(RUNTIME),)
  $(error Neither podman nor docker found on PATH)
endif

# ---------------------------------------------------------------------------
# Phony targets
# ---------------------------------------------------------------------------
.PHONY: all manifest image flash clean clean-downloads help

all: flash

# ---------------------------------------------------------------------------
# manifest — resolve RPM checksums and write configs/osbuild-pipeline.json
#
# Step 1: image-builder-cli --with-manifest
#   Runs inside the IBC container.  Depsolves the blueprint against the three
#   CentOS Stream 10 repos (BaseOS/AppStream/CRB) plus LOCAL_RPMS when set.
#   Writes a raw osbuild v2 manifest to build/tmp/ibc-out/.
#
# Step 2: scripts/patch_manifest.py
#   Replaces the 'image' and 'qcow2' pipelines in the raw manifest with
#   'efi-image' and 'rootfs-image' pipelines that emit raw images directly.
#   Writes the final manifest to configs/osbuild-pipeline.json.
# ---------------------------------------------------------------------------
manifest: $(BLUEPRINT)
	@echo "[*] Generating $(MANIFEST)"
	@echo "    blueprint : $(BLUEPRINT)"
	@echo "    local-rpms: $(if $(LOCAL_RPMS),$(LOCAL_RPMS),(none — stock CentOS kernel))"
	@echo "    runtime   : $(RUNTIME)"
	mkdir -p $(BUILD_LOGS) build/tmp/ibc-out
	sudo  $(RUNTIME) run --rm --privileged \
	  --net=host \
	  -v "$(CURDIR)/$(BLUEPRINT):/blueprint.toml:ro" \
	  -v "$(CURDIR)/build/tmp/ibc-out:/manifest-out:rw" \
	  $(IBC_IMAGE) build \
	  --distro $(DISTRO) \
	  --arch   $(ARCH) \
	  --blueprint /blueprint.toml \
	  --with-manifest \
	  --output-dir /manifest-out \
	  --force-repo $(CENTOS_MIRROR)/BaseOS/$(ARCH)/os/ \
	  --force-repo $(CENTOS_MIRROR)/AppStream/$(ARCH)/os/ \
	  --force-repo $(CENTOS_MIRROR)/CRB/$(ARCH)/os/ \
	  $${LOCAL_RPMS:+--force-repo $(LOCAL_RPMS)} \
	  qcow2 \
	  2>&1 | grep -v "^time=" | tee $(BUILD_LOGS)/manifest-resolve.log
	@RAW=$$(find build/tmp/ibc-out -name '*.osbuild-manifest.json' | head -1); \
	if [ -z "$$RAW" ]; then \
	  echo "[!] image-builder-cli did not produce a manifest."; \
	  echo "    Check $(BUILD_LOGS)/manifest-resolve.log for errors."; \
	  exit 1; \
	fi; \
	echo "[*] Patching manifest: $$RAW -> $(MANIFEST)"; \
	python3 scripts/patch_manifest.py \
	  --input     "$$RAW" \
	  --output    $(MANIFEST) \
	  --efi-size  $(EFI_SIZE_MIB) \
	  --root-size $(ROOT_SIZE_GIB)
	@echo "[✓] Manifest ready: $(MANIFEST)"

# ---------------------------------------------------------------------------
# image — run osbuild against the manifest to produce efi.bin + rootfs.img
#
# osbuild downloads every RPM from the URL baked into the manifest (including
# the custom kernel if LOCAL_RPMS was set during 'make manifest').
# No local repo access needed at this step.
# ---------------------------------------------------------------------------
$(EFI_BIN) $(ROOTFS_IMG): $(MANIFEST)
	@if [ ! -f "$(MANIFEST)" ]; then \
	  echo ""; \
	  echo "ERROR: $(MANIFEST) not found."; \
	  echo "Run 'make manifest' first (optionally with LOCAL_RPMS=http://<host>:<port>/)."; \
	  echo ""; \
	  exit 1; \
	fi
	mkdir -p $(FLASHIMAGES) $(OSBUILD_STORE) $(BUILD_LOGS)
	sudo $(RUNTIME) run --rm --privileged \
	  --net=host \
	  --entrypoint="" \
	  -v "$(CURDIR)/$(MANIFEST):/manifest.json:ro" \
	  -v "$(CURDIR)/$(FLASHIMAGES):/output:rw" \
	  -v "$(CURDIR)/$(OSBUILD_STORE):/store:rw" \
	  $(IBC_IMAGE) \
	  osbuild \
	    --store /store \
	    --output-directory /output \
	    --export efi-image \
	    --export rootfs-image \
	    /manifest.json \
	  2>&1 | tee $(BUILD_LOGS)/osbuild.log

image: $(EFI_BIN) $(ROOTFS_IMG)

# ---------------------------------------------------------------------------
# flash — assemble per-board flash packages
# ---------------------------------------------------------------------------
flash: $(EFI_BIN) $(ROOTFS_IMG)
	@[ -n "$(DTBS_TAR)" ] || { \
	  echo "ERROR: DTBS_TAR is required."; \
	  echo "  make flash DTBS_TAR=linux/build/out/dtbs.tar.gz"; \
	  exit 1; \
	}
	./scripts/generate_flat_build.sh \
	  --dtbs-tar=$(DTBS_TAR) \
	  --esp-vfat=$(EFI_BIN) \
	  --rootfs-ext4=$(ROOTFS_IMG) \
	  --target-boards=$(TARGET_BOARDS) \
	  $(EXTRA_FLASH_OPTS)

# ---------------------------------------------------------------------------
# Housekeeping
# ---------------------------------------------------------------------------
clean:
	rm -rf $(BUILD_OUTPUT) $(ARTIFACTDIR) $(BUILD_LOGS) build/tmp

clean-downloads:
	rm -rf downloads/

help:
	@echo "Usage: make [TARGET] [VARIABLE=value ...]"
	@echo ""
	@echo "Targets:"
	@echo "  manifest   Generate configs/osbuild-pipeline.json (run once per kernel/blueprint change)"
	@echo "  image      Build efi.bin + rootfs.img via osbuild (requires sudo)"
	@echo "  flash      Assemble per-board flash packages (default)"
	@echo "  clean      Remove build outputs"
	@echo ""
	@echo "Key variables:"
	@echo "  LOCAL_RPMS      URL of local kernel RPM repo (for 'make manifest' only)"
	@echo "                  Example: LOCAL_RPMS=http://10.147.152.194:8000/"
	@echo "  DTBS_TAR        DTB tarball path (required for 'make flash')"
	@echo "  TARGET_BOARDS   Boards to flash (default: $(TARGET_BOARDS); use 'all' for all)"
	@echo "  BLUEPRINT       TOML blueprint (default: $(BLUEPRINT))"
	@echo "  EFI_SIZE_MIB    EFI partition size in MiB (default: $(EFI_SIZE_MIB))"
	@echo "  ROOT_SIZE_GIB   rootfs size in GiB (default: $(ROOT_SIZE_GIB))"
	@echo "  IBC_IMAGE       image-builder-cli container (default: $(IBC_IMAGE))"
	@echo "  OSBUILD_STORE   osbuild object store (default: $(OSBUILD_STORE))"
	@echo ""
	@echo "Typical workflow:"
	@echo "  make manifest LOCAL_RPMS=http://10.147.152.194:8000/"
	@echo "  make image"
	@echo "  make flash DTBS_TAR=linux/build/out/dtbs.tar.gz"
