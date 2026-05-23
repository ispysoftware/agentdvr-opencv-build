#!/usr/bin/env bash
# build.sh — Build libcvextern.so for linux-x64, linux-arm64, and linux-arm via Docker.
# Linux/WSL/macOS equivalent of build.ps1.
#
# Usage:
#   ./build.sh                       # both (x64 + arm64)
#   ./build.sh x64                   # x64 only
#   ./build.sh arm64                 # arm64 only
#   ./build.sh armhf                 # 32-bit ARM (armv7/armhf) only
#   ./build.sh all                   # x64 + arm64 + armhf
#   EMGU_TAG=4.12.0 BUILD_TYPE=full ./build.sh
#   SKIP_ZIP=1 ./build.sh

set -euo pipefail

ARCH="${1:-both}"
EMGU_TAG="${EMGU_TAG:-4.12.0}"
BUILD_TYPE="${BUILD_TYPE:-full}"
JOBS="${JOBS:-0}"
PORTABLE="${PORTABLE:-1}"
OUT_DIR="${OUT_DIR:-./out}"
SKIP_ZIP="${SKIP_ZIP:-0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

section() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()      { printf '\033[1;32m%s\033[0m\n' "$*"; }
warn()    { printf '\033[1;33m%s\033[0m\n' "$*"; }
fail()    { printf '\033[1;31m%s\033[0m\n' "$*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || fail "docker not found. Install Docker Desktop or Docker Engine."
docker version --format '{{.Server.Version}}' >/dev/null 2>&1 || fail "Docker daemon not running."
docker buildx version >/dev/null 2>&1 || fail "docker buildx required."

mkdir -p "$OUT_DIR"
ABS_OUT="$(cd "$OUT_DIR" && pwd)"
echo "Output directory: $ABS_OUT"

BUILD_ARGS=(
    --build-arg "EMGU_TAG=$EMGU_TAG"
    --build-arg "BUILD_TYPE=$BUILD_TYPE"
    --build-arg "PORTABLE=$PORTABLE"
)
[ "$JOBS" -gt 0 ] && BUILD_ARGS+=( --build-arg "JOBS=$JOBS" )

build_x64() {
    section "Building linux-x64 (Ubuntu 20.04 base, glibc 2.31 target)"
    local out="$ABS_OUT/linux-x64"
    mkdir -p "$out"
    docker buildx build \
        --platform linux/amd64 \
        -f Dockerfile.x64 \
        "${BUILD_ARGS[@]}" \
        --output "type=local,dest=$out" \
        .
    [ -f "$out/libcvextern.so" ] || fail "x64 build did not produce libcvextern.so"
    ok "linux-x64 build OK: $out/libcvextern.so ($(du -h "$out/libcvextern.so" | cut -f1))"
}

build_arm64() {
    section "Building linux-arm64 (Debian 11 base, glibc 2.31 target)"
    warn "arm64 via QEMU typically takes 2-6 hours. Native arm64 host is much faster."

    # Skip binfmt install on native arm64 hosts
    local host_arch
    host_arch="$(uname -m)"
    if [ "$host_arch" != "aarch64" ] && [ "$host_arch" != "arm64" ]; then
        echo "Installing QEMU binfmt handlers for arm64..."
        docker run --privileged --rm tonistiigi/binfmt --install arm64 >/dev/null || warn "binfmt install non-fatal"
    fi

    if ! docker buildx ls | grep -q '^emgucv-builder'; then
        docker buildx create --name emgucv-builder --use >/dev/null
    else
        docker buildx use emgucv-builder >/dev/null
    fi
    docker buildx inspect --bootstrap >/dev/null

    local out="$ABS_OUT/linux-arm64"
    mkdir -p "$out"
    docker buildx build \
        --platform linux/arm64 \
        -f Dockerfile.arm64 \
        "${BUILD_ARGS[@]}" \
        --output "type=local,dest=$out" \
        .
    [ -f "$out/libcvextern.so" ] || fail "arm64 build did not produce libcvextern.so"
    ok "linux-arm64 build OK: $out/libcvextern.so ($(du -h "$out/libcvextern.so" | cut -f1))"
}

build_armhf() {
    section "Building linux-arm (armv7/armhf, Debian 11 base, glibc 2.31 target)"
    warn "armhf via QEMU typically takes 3-8 hours. A native armhf host is much faster."

    # Skip binfmt install on native arm hosts
    local host_arch
    host_arch="$(uname -m)"
    if [ "$host_arch" != "armv7l" ] && [ "$host_arch" != "armhf" ]; then
        echo "Installing QEMU binfmt handlers for arm (v7)..."
        docker run --privileged --rm tonistiigi/binfmt --install arm >/dev/null || warn "binfmt install non-fatal"
    fi

    if ! docker buildx ls | grep -q '^emgucv-builder'; then
        docker buildx create --name emgucv-builder --use >/dev/null
    else
        docker buildx use emgucv-builder >/dev/null
    fi
    docker buildx inspect --bootstrap >/dev/null

    local out="$ABS_OUT/linux-arm"
    mkdir -p "$out"
    docker buildx build \
        --platform linux/arm/v7 \
        -f Dockerfile.armhf \
        "${BUILD_ARGS[@]}" \
        --output "type=local,dest=$out" \
        .
    [ -f "$out/libcvextern.so" ] || fail "armhf build did not produce libcvextern.so"
    ok "linux-arm build OK: $out/libcvextern.so ($(du -h "$out/libcvextern.so" | cut -f1))"
}

package_zip() {
    local a="$1"
    local dir="$ABS_OUT/linux-$a"
    local zip="$ABS_OUT/linux-$a.zip"
    [ -f "$dir/libcvextern.so" ] || return 0
    rm -f "$zip"
    ( cd "$dir" && zip -q "$zip" libcvextern.so )
    ok "Created $zip ($(du -h "$zip" | cut -f1))"
}

case "$ARCH" in
    x64)   build_x64 ;;
    arm64) build_arm64 ;;
    armhf) build_armhf ;;
    both)  build_x64; build_arm64 ;;
    all)   build_x64; build_arm64; build_armhf ;;
    *)     fail "Unknown arch '$ARCH' (expected: x64 | arm64 | armhf | both | all)" ;;
esac

if [ "$SKIP_ZIP" != "1" ] && command -v zip >/dev/null 2>&1; then
    section "Packaging CDN zips"
    [[ "$ARCH" = "both" || "$ARCH" = "all" || "$ARCH" = "x64" ]]   && package_zip x64
    [[ "$ARCH" = "both" || "$ARCH" = "all" || "$ARCH" = "arm64" ]] && package_zip arm64
    [[ "$ARCH" = "all"  || "$ARCH" = "armhf" ]]                    && package_zip arm
fi

section "Done"
echo "Upload the .zip files to https://files.ispyconnect.com/libs/opencv/${EMGU_TAG}.5764/ and bump OpenCvVersion in Dependencies.cs."
