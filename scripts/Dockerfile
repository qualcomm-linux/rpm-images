# syntax=docker/dockerfile:1
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# =============================================================================
# Multi-Architecture RPM Builder
# =============================================================================
# Builds RPM and SRPM packages from a source tarball and a spec file.
# Supported platforms: linux/amd64 (x86_64) and linux/arm64 (aarch64)
#
# Build Arguments:
#   TARBALL    - Filename/path of the source tarball relative to the build
#                context (required, e.g. mypackage-1.0.tar.gz)
#   SPEC_FILE  - Filename/path of the RPM spec file relative to the build
#                context (required, e.g. mypackage.spec)
#   BASE_IMAGE - Base image to use (default: fedora:latest)
#   RPM_MACROS - Extra rpmbuild macro definitions, space-separated
#                (optional, e.g. "--define 'debug_package %{nil}'")
#
# ── Single-arch build ────────────────────────────────────────────────────────
#   docker build \
#     --build-arg TARBALL=mypackage-1.0.tar.gz \
#     --build-arg SPEC_FILE=mypackage.spec \
#     --output type=local,dest=./output \
#     --target artifacts \
#     .
#
# ── Multi-arch build (requires docker buildx) ────────────────────────────────
#   docker buildx build \
#     --platform linux/amd64,linux/arm64 \
#     --build-arg TARBALL=mypackage-1.0.tar.gz \
#     --build-arg SPEC_FILE=mypackage.spec \
#     --output type=local,dest=./output \
#     --target artifacts \
#     .
#
# Output layout (when using --output type=local,dest=./output):
#   ./output/
#     ├── mypackage-1.0-1.x86_64.rpm      (amd64 build)
#     ├── mypackage-1.0-1.aarch64.rpm     (arm64 build)
#     └── mypackage-1.0-1.src.rpm
# =============================================================================

ARG BASE_IMAGE=fedora:latest

# ---------------------------------------------------------------------------
# Builder stage
# ---------------------------------------------------------------------------
FROM --platform=$TARGETPLATFORM ${BASE_IMAGE} AS builder

# Re-declare ARGs so they are in scope after FROM
ARG TARBALL
ARG SPEC_FILE
ARG RPM_MACROS=""

# Validate required arguments
RUN if [ -z "${TARBALL}" ]; then \
        echo "ERROR: Build argument TARBALL is required." >&2; exit 1; \
    fi && \
    if [ -z "${SPEC_FILE}" ]; then \
        echo "ERROR: Build argument SPEC_FILE is required." >&2; exit 1; \
    fi

# Install RPM build tools and a broad set of common build dependencies.
# dnf builddep (run later) will pull in any spec-specific extras.
RUN dnf -y install dnf-plugins-core \
    && dnf config-manager --set-enabled crb \
    && dnf -y install \
        https://dl.fedoraproject.org/pub/epel/epel-release-latest-10.noarch.rpm \
    && dnf -y update \
    && dnf -y install \ 
        rpm-build \
        rpmdevtools \
        gcc \
        gcc-c++ \
        make \
        cmake \
        git \
        wget \
        curl \
        tar \
        gzip \
        bzip2 \
        xz \
        patch \
        diffutils \
    && dnf clean all

RUN rpmdev-setuptree

COPY ${TARBALL} /root/rpmbuild/SOURCES/
COPY ${SPEC_FILE} /root/rpmbuild/SPECS/

RUN dnf builddep -y "/root/rpmbuild/SPECS/$(basename "${SPEC_FILE}")"

RUN eval rpmbuild -ba ${RPM_MACROS} \
        "/root/rpmbuild/SPECS/$(basename "${SPEC_FILE}")"

RUN mkdir -p /output \
    && find /root/rpmbuild/RPMS  -name "*.rpm"     -exec cp -v {} /output/ \; \
    && find /root/rpmbuild/SRPMS -name "*.src.rpm" -exec cp -v {} /output/ \; \
    && echo "" \
    && echo "=== Built packages ===" \
    && ls -lh /output/

# ---------------------------------------------------------------------------
# Artifacts stage
# Use this target with --output to extract only the built packages:
#   --target artifacts --output type=local,dest=./output
# ---------------------------------------------------------------------------
FROM scratch AS artifacts
COPY --from=builder /output /
