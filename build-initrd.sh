#!/bin/bash
set -e

set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${DIR}/../.." && pwd)"
TOOLS_DIR="${PROJECT_ROOT}/tools/build"
BUILD_DIR="${PROJECT_ROOT}/build"
OUTPUT_DIR="${BUILD_DIR}/output"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $@" | tee -a "${BUILD_DIR}/logs/initramfs_build.log"
}

check_docker() {
    if ! command -v docker &> /dev/null; then
        log "ERROR: docker is not installed. Please install Docker first."
        exit 1
    fi
}

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -a, --arch ARCH      Architecture to build for (default: arm64)"
    echo "  -m, --mirror URL     Debian mirror URL"
    echo "  -o, --out DIR       Output directory"
    echo "  -h, --help          Show this help message"
    echo ""
    echo "Security:"
    echo "  This script uses Docker containers to isolate the build environment."
    echo "  No direct system modifications will be made."
}

ARCH="arm64"
MIRROR=""
OUT_DIR="${OUTPUT_DIR}"

while [ $# -gt 0 ]; do
    case "$1" in
        -a|--arch)
            ARCH="$2"
            shift 2
            ;;
        -m|--mirror)
            MIRROR="$2"
            shift 2
            ;;
        -o|--out)
            OUT_DIR="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

initramfs_builder_image="vamos-droidian-initramfs-builder:latest"

log "=========================================="
log "Safe Initramfs Build (Docker Isolated)"
log "=========================================="
log ""
log "Configuration:"
log "  Architecture: ${ARCH}"
log "  Output:       ${OUT_DIR}"
log "  Docker Image: ${initramfs_builder_image}"
log "=========================================="
log ""

check_docker

mkdir -p "${BUILD_DIR}/logs"
mkdir -p "${OUT_DIR}"

if ! docker image inspect "${initramfs_builder_image}" > /dev/null 2>&1; then
    log "Building Docker image: ${initramfs_builder_image}"
    docker buildx build \
        -f "${TOOLS_DIR}/Dockerfile.initramfs" \
        -t "${initramfs_builder_image}" \
        --build-arg UID="$(id -u)" \
        --build-arg GID="$(id -g)" \
        "${PROJECT_ROOT}" \
        --load
    log "Docker image built successfully"
else
    log "Docker image already exists, using cached version"
fi

CHROOT_DIR="${BUILD_DIR}/initramfs_chroot_${ARCH}"
INITRAMFS_OUT="${BUILD_DIR}/initramfs_out"

container_id=""
cleanup() {
    if [ -n "$container_id" ]; then
        log "Cleaning up container..."
        docker container rm -f "$container_id" > /dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

log "[1/4] Starting isolated build container..."
container_id=$(docker run -d \
    --rm \
    --cap-drop=ALL \
    --security-opt=no-new-privileges \
    -u "$(id -u):$(id -g)" \
    -v "${PROJECT_ROOT}":"${PROJECT_ROOT}":ro \
    -v "${BUILD_DIR}":"${BUILD_DIR}":rw \
    -w "${PROJECT_ROOT}" \
    "${initramfs_builder_image}")

log "[2/4] Creating Debian chroot environment..."
docker exec "$container_id" bash -c "
    set -e
    export DEBIAN_FRONTEND=noninteractive

    mkdir -p ${CHROOT_DIR}
    mkdir -p ${INITRAMFS_OUT}

    if [ ! -f ${CHROOT_DIR}/.min-done ]; then
        echo 'Bootstrap Debian ${ARCH}...'
        debootstrap --arch ${ARCH} --variant=minbase bookworm ${CHROOT_DIR} ${MIRROR:-http://mirrors.tuna.tsinghua.edu.cn/debian} || \
            debootstrap --arch ${ARCH} --variant=minbase bookworm ${CHROOT_DIR} ${MIRROR:-http://mirrors.ustc.edu.cn/debian}
        touch ${CHROOT_DIR}/.min-done
        echo 'Bootstrap complete'
    else
        echo 'Using existing chroot environment'
    fi
" 2>&1 | tee -a "${BUILD_DIR}/logs/initramfs_build.log"

log "[3/4] Installing initramfs packages..."
docker exec "$container_id" bash -c "
    set -e
    export DEBIAN_FRONTEND=noninteractive

    echo 'Updating package lists...'
    chroot ${CHROOT_DIR} apt-get update

    echo 'Installing packages...'
    chroot ${CHROOT_DIR} apt-get install -y --no-install-recommends \
        initramfs-tools \
        dctrl-tools \
        e2fsprogs \
        lvm2 \
        cryptsetup \
        busybox-static

    echo 'Copying Halium configuration...'
    mkdir -p ${CHROOT_DIR}/usr/share/initramfs-tools/conf.d
    mkdir -p ${CHROOT_DIR}/usr/share/initramfs-tools/scripts
    mkdir -p ${CHROOT_DIR}/usr/share/initramfs-tools/hooks

    cp ${DIR}/conf/halium ${CHROOT_DIR}/usr/share/initramfs-tools/conf.d/
    cp -r ${DIR}/scripts/* ${CHROOT_DIR}/usr/share/initramfs-tools/scripts/ 2>/dev/null || true
    cp -r ${DIR}/hooks/* ${CHROOT_DIR}/usr/share/initramfs-tools/hooks/ 2>/dev/null || true
" 2>&1 | tee -a "${BUILD_DIR}/logs/initramfs_build.log"

log "[4/4] Building initramfs..."
docker exec "$container_id" bash -c "
    set -e

    echo 'Generating initramfs...'
    chroot ${CHROOT_DIR} update-initramfs -tc -k all -v

    echo 'Copying output...'
    cp ${CHROOT_DIR}/boot/initrd.img-* ${INITRAMFS_OUT}/initrd.img-halium-generic

    if [ -f ${INITRAMFS_OUT}/initrd.img-halium-generic ]; then
        echo 'Initramfs created successfully!'
        ls -lh ${INITRAMFS_OUT}/initrd.img-halium-generic
    else
        echo 'ERROR: Failed to create initramfs!'
        exit 1
    fi
" 2>&1 | tee -a "${BUILD_DIR}/logs/initramfs_build.log"

log ""
log "=========================================="
log "Build complete!"
log "Output: ${INITRAMFS_OUT}/initrd.img-halium-generic"
log "Log: ${BUILD_DIR}/logs/initramfs_build.log"
log "=========================================="
