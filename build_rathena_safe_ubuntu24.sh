#!/usr/bin/env bash
set -Eeuo pipefail

# rAthena safe build helper for Ubuntu 24.x
# - mitigates OOM during compilation
# - creates swap if needed
# - limits parallel jobs
# - lowers optimization level by default
#
# Usage:
#   chmod +x build_rathena_safe_ubuntu24.sh
#   ./build_rathena_safe_ubuntu24.sh /root/rathena
#
# Optional env vars:
#   SWAP_SIZE_GB=2         # default: 2
#   BUILD_JOBS=1           # default: 1
#   BUILD_TARGET=server    # default: server
#   CFLAGS_LEVEL=-O1       # default: -O1
#   SKIP_DEPS=0            # set to 1 to skip apt install

RATHENA_DIR="${1:-/root/rathena}"
SWAP_SIZE_GB="${SWAP_SIZE_GB:-2}"
BUILD_JOBS="${BUILD_JOBS:-1}"
BUILD_TARGET="${BUILD_TARGET:-server}"
CFLAGS_LEVEL="${CFLAGS_LEVEL:--O1}"
SKIP_DEPS="${SKIP_DEPS:-0}"

log() {
  printf '\n[%s] %s\n' "$(date '+%F %T')" "$*"
}

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "This script must be run as root." >&2
    exit 1
  fi
}

check_dir() {
  if [[ ! -d "$RATHENA_DIR" ]]; then
    echo "rAthena directory not found: $RATHENA_DIR" >&2
    exit 1
  fi
  if [[ ! -f "$RATHENA_DIR/configure" && ! -f "$RATHENA_DIR/CMakeLists.txt" && ! -f "$RATHENA_DIR/Makefile" ]]; then
    log "Warning: this does not look like a typical rAthena root, but continuing anyway."
  fi
}

install_deps() {
  if [[ "$SKIP_DEPS" == "1" ]]; then
    log "Skipping dependency installation."
    return
  fi

  export DEBIAN_FRONTEND=noninteractive
  log "Updating package lists..."
  apt-get update -y

  log "Installing build dependencies..."
  apt-get install -y \
    build-essential \
    git \
    make \
    gcc \
    g++ \
    autoconf \
    automake \
    libtool \
    pkg-config \
    cmake \
    zlib1g-dev \
    libpcre3-dev \
    libmariadb-dev \
    libmariadb-dev-compat \
    mariadb-client \
    ca-certificates \
    htop
}

show_memory() {
  log "Memory status"
  free -h || true
  swapon --show || true
}

ensure_swap() {
  local swap_total_mb
  swap_total_mb="$(free -m | awk '/^Swap:/ {print $2}')"

  if [[ "${swap_total_mb:-0}" -gt 0 ]]; then
    log "Swap already exists (${swap_total_mb} MB). Skipping swap creation."
    return
  fi

  log "No swap detected. Creating ${SWAP_SIZE_GB}G swapfile..."

  if command -v fallocate >/dev/null 2>&1; then
    fallocate -l "${SWAP_SIZE_GB}G" /swapfile || true
  fi

  if [[ ! -f /swapfile || ! -s /swapfile ]]; then
    dd if=/dev/zero of=/swapfile bs=1M count="$((SWAP_SIZE_GB * 1024))" status=progress
  fi

  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile

  if ! grep -q '^/swapfile ' /etc/fstab; then
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
  fi

  log "Swap created successfully."
}

prepare_build_flags() {
  export CFLAGS="$CFLAGS_LEVEL"
  export CXXFLAGS="$CFLAGS_LEVEL"
  export MAKEFLAGS="-j${BUILD_JOBS}"
  log "Build flags: CFLAGS=$CFLAGS CXXFLAGS=$CXXFLAGS MAKEFLAGS=$MAKEFLAGS"
}

build_rathena() {
  cd "$RATHENA_DIR"

  if [[ -x ./configure ]]; then
    log "Running ./configure ..."
    ./configure
  else
    log "No executable ./configure found. Skipping configure step."
  fi

  log "Cleaning previous build..."
  make clean || true

  log "Starting build target: ${BUILD_TARGET}"
  if ! make "$BUILD_TARGET" -j"$BUILD_JOBS"; then
    log "Build failed. Collecting quick diagnostics..."
    dmesg | tail -n 60 || true
    free -h || true
    exit 1
  fi
}

post_build() {
  log "Build finished successfully."

  log "Result files (top few):"
  find "$RATHENA_DIR" -maxdepth 3 -type f \( -name login-server -o -name char-server -o -name map-server \) -print 2>/dev/null || true

  log "Final memory status:"
  free -h || true
  swapon --show || true
}

main() {
  need_root
  check_dir
  show_memory
  install_deps
  ensure_swap
  show_memory
  prepare_build_flags
  build_rathena
  post_build
}

main "$@"
