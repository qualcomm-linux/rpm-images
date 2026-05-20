#!/usr/bin/env bash
# =============================================================================
# Usage:
#   ./build-rpm.sh --tarball <path> --spec <path> [OPTIONS]
#
# Options:
#   -t, --tarball  <file>     Source tarball (required)
#   -s, --spec     <file>     RPM spec file  (required)
#   -o, --output   <dir>      Output directory (default: ./output)
#   -p, --platform <list>     Comma-separated platform list
#                             (default: linux/amd64,linux/arm64)
#       --single-arch         Build for the host architecture only
#       --macros   <string>   Extra rpmbuild --define strings
#       --base-image <image>  Override the builder base image
#                             (default: fedora:latest)
#   -h, --help                Show this help
#
# Examples:
#   # Multi-arch (amd64 + arm64)
#   ./build-rpm.sh --tarball mypackage-1.0.tar.gz --spec mypackage.spec
#
#   # Single arch (host only)
#   ./build-rpm.sh --tarball mypackage-1.0.tar.gz --spec mypackage.spec \
#                  --single-arch
#
#   # Custom output directory and extra macros
#   ./build-rpm.sh --tarball mypackage-1.0.tar.gz --spec mypackage.spec \
#                  --output ./rpms \
#                  --macros "--define 'debug_package %{nil}'"
# =============================================================================
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
TARBALL=""
SPEC_FILE=""
OUTPUT_DIR="./output"
PLATFORMS="linux/amd64,linux/arm64"
SINGLE_ARCH=false
RPM_MACROS=""
BASE_IMAGE="quay.io/centos/centos:stream10"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Argument parsing ───────────────────────────────────────────────────────────
usage() {
    grep '^#' "$0" | sed 's/^# \?//' | sed -n '/^Usage:/,/^====/p' | head -n -1
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--tarball)     TARBALL="$2";     shift 2 ;;
        -s|--spec)        SPEC_FILE="$2";   shift 2 ;;
        -o|--output)      OUTPUT_DIR="$2";  shift 2 ;;
        -p|--platform)    PLATFORMS="$2";   shift 2 ;;
        --single-arch)    SINGLE_ARCH=true; shift   ;;
        --macros)         RPM_MACROS="$2";  shift 2 ;;
        --base-image)     BASE_IMAGE="$2";  shift 2 ;;
        -h|--help)        usage ;;
        *) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ── Validate inputs ────────────────────────────────────────────────────────────
if [[ -z "${TARBALL}" ]]; then
    echo "ERROR: --tarball is required." >&2; exit 1
fi
if [[ -z "${SPEC_FILE}" ]]; then
    echo "ERROR: --spec is required." >&2; exit 1
fi
if [[ ! -f "${TARBALL}" ]]; then
    echo "ERROR: Tarball not found: ${TARBALL}" >&2; exit 1
fi
if [[ ! -f "${SPEC_FILE}" ]]; then
    echo "ERROR: Spec file not found: ${SPEC_FILE}" >&2; exit 1
fi

# ── Resolve absolute paths ─────────────────────────────────────────────────────
TARBALL_ABS="$(realpath "${TARBALL}")"
SPEC_ABS="$(realpath "${SPEC_FILE}")"

# The build context is the directory containing this script (where Dockerfile lives).
# Both the tarball and spec file must reside inside the build context.
BUILD_CONTEXT="${SCRIPT_DIR}"

CLEANUP_TARBALL=false
CLEANUP_SPEC=false

if [[ "${TARBALL_ABS}" != "${BUILD_CONTEXT}"/* ]]; then
    echo "INFO: Copying tarball into build context..."
    cp "${TARBALL_ABS}" "${BUILD_CONTEXT}/"
    TARBALL_ABS="${BUILD_CONTEXT}/$(basename "${TARBALL_ABS}")"
    CLEANUP_TARBALL=true
fi

if [[ "${SPEC_ABS}" != "${BUILD_CONTEXT}"/* ]]; then
    echo "INFO: Copying spec file into build context..."
    cp "${SPEC_ABS}" "${BUILD_CONTEXT}/"
    SPEC_ABS="${BUILD_CONTEXT}/$(basename "${SPEC_ABS}")"
    CLEANUP_SPEC=true
fi

# Paths relative to the build context (passed as Docker build args)
TARBALL_REL="${TARBALL_ABS#${BUILD_CONTEXT}/}"
SPEC_REL="${SPEC_ABS#${BUILD_CONTEXT}/}"

# ── Prepare output directory ───────────────────────────────────────────────────
mkdir -p "${OUTPUT_DIR}"
OUTPUT_ABS="$(realpath "${OUTPUT_DIR}")"

# ── Cleanup trap ───────────────────────────────────────────────────────────────
cleanup() {
    if [[ "${CLEANUP_TARBALL}" == true ]]; then
        rm -f "${BUILD_CONTEXT}/$(basename "${TARBALL_ABS}")"
    fi
    if [[ "${CLEANUP_SPEC}" == true ]]; then
        rm -f "${BUILD_CONTEXT}/$(basename "${SPEC_ABS}")"
    fi
}
trap cleanup EXIT

# ── Determine platform string ──────────────────────────────────────────────────
if [[ "${SINGLE_ARCH}" == true ]]; then
    ARCH="$(uname -m)"
    case "${ARCH}" in
        x86_64)  PLATFORMS="linux/amd64"  ;;
        aarch64) PLATFORMS="linux/arm64"  ;;
        *)       PLATFORMS="linux/${ARCH}" ;;
    esac
    echo "INFO: Single-arch mode – building for ${PLATFORMS}"
fi

# ── Detect docker / docker buildx ─────────────────────────────────────────────
DOCKER_CMD="docker"
#if ! command -v docker &>/dev/null; then
#    if command -v podman &>/dev/null; then
#        DOCKER_CMD="podman"
#        echo "INFO: docker not found, using podman"
#    else
#        echo "ERROR: Neither docker nor podman found in PATH." >&2; exit 1
#    fi
#fi

# For multi-arch builds we need buildx (or podman's equivalent)
PLATFORM_COUNT=$(echo "${PLATFORMS}" | tr ',' '\n' | wc -l)

if [[ "${PLATFORM_COUNT}" -gt 1 ]]; then
    # Ensure buildx is available
    if ! ${DOCKER_CMD} buildx version &>/dev/null; then
        echo "ERROR: docker buildx is required for multi-arch builds." >&2
        echo "       Install it or use --single-arch to build for the host only." >&2
        exit 1
    fi
    BUILD_CMD="${DOCKER_CMD} buildx build"
    # Ensure a multi-arch capable builder is active
    if ! ${DOCKER_CMD} buildx inspect --bootstrap &>/dev/null; then
        echo "INFO: Creating a new buildx builder instance..."
        ${DOCKER_CMD} buildx create --use --name rpm-builder
    fi
else
    # Single platform – plain docker build is sufficient
    BUILD_CMD="${DOCKER_CMD} build"
fi

# ── Run the build ──────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo " RPM Builder"
echo "============================================================"
echo " Tarball   : ${TARBALL_REL}"
echo " Spec file : ${SPEC_REL}"
echo " Platforms : ${PLATFORMS}"
echo " Output    : ${OUTPUT_ABS}"
echo " Base image: ${BASE_IMAGE}"
[[ -n "${RPM_MACROS}" ]] && echo " Macros    : ${RPM_MACROS}"
echo "============================================================"
echo ""

${BUILD_CMD} \
    --platform "${PLATFORMS}" \
    --build-arg "TARBALL=${TARBALL_REL}" \
    --build-arg "SPEC_FILE=${SPEC_REL}" \
    --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
    ${RPM_MACROS:+--build-arg "RPM_MACROS=${RPM_MACROS}"} \
    --output "type=local,dest=${OUTPUT_ABS}" \
    --target artifacts \
    "${BUILD_CONTEXT}"

echo ""
echo "============================================================"
echo " Build complete. Packages written to: ${OUTPUT_ABS}"
echo "============================================================"
ls -lh "${OUTPUT_ABS}/"
