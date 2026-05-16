#!/usr/bin/env bash
#
# install-slurm.sh
# Build-time script: installs Slurm client binaries, creates users, lays out
# config files and directory structure.  Run this in a Dockerfile RUN layer.
#
# Runtime counterpart: configure-slurm.sh
#

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (loaded from centralized config.sh)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

BUILD_DIR="/tmp/slurm-build"
STAGE_DIR="/tmp/slurm-stage"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() { printf '[slurm-build] %s\n' "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

ensure_dir() {
    local dir="$1" owner="${2:-root:root}" mode="${3:-755}"
    $SUDO mkdir -p "$dir"
    $SUDO chown "$owner" "$dir"
    $SUDO chmod "$mode" "$dir"
}

# ---------------------------------------------------------------------------
# 1. Install build dependencies
# ---------------------------------------------------------------------------
log "Installing build dependencies …"
export DEBIAN_FRONTEND=noninteractive
$SUDO apt-get update -qq
$SUDO apt-get install -y --no-install-recommends \
    build-essential \
    munge libmunge-dev \
    libssl-dev libpam0g-dev \
    pkg-config xxd \
    libtool libtool-bin libhdf5-dev \
    wget bzip2 \
    gosu

# ---------------------------------------------------------------------------
# 2. Download & compile Slurm
# ---------------------------------------------------------------------------
SLURM_TARBALL="slurm-${SLURM_VERSION}.tar.bz2"
SLURM_URL="https://download.schedmd.com/slurm/${SLURM_TARBALL}"

log "Downloading Slurm ${SLURM_VERSION} …"
mkdir -p "$BUILD_DIR"
wget -q -O "${BUILD_DIR}/${SLURM_TARBALL}" "$SLURM_URL" \
    || die "Failed to download ${SLURM_URL}"

log "Extracting …"
tar xf "${BUILD_DIR}/${SLURM_TARBALL}" -C "$BUILD_DIR" \
    || die "Failed to extract ${SLURM_TARBALL}"

SLURM_SRC="${BUILD_DIR}/slurm-${SLURM_VERSION}"
[ -d "$SLURM_SRC" ] || die "Source directory ${SLURM_SRC} not found after extraction"

log "Configuring …"
(
    cd "$SLURM_SRC"
    ./configure --prefix=/usr/local --sysconfdir="$SLURM_CONF_DIR" \
        || die "configure failed"
)

log "Compiling ($(nproc) jobs) …"
make -C "$SLURM_SRC" -j"$(nproc)" || die "make failed"

log "Installing to staging area …"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
make -C "$SLURM_SRC" DESTDIR="$STAGE_DIR" install || die "make install failed"

$SUDO cp -a "${STAGE_DIR}/usr/local/." /usr/local/
$SUDO libtool --finish /usr/local/lib

rm -rf "$BUILD_DIR" "$STAGE_DIR"

# ---------------------------------------------------------------------------
# 3. Create users/groups (idempotent, with correct IDs)
# ---------------------------------------------------------------------------
log "Ensuring munge and slurm users exist …"

if id "munge" &>/dev/null; then
    $SUDO groupmod -g "$MUNGE_GID" munge  2>/dev/null || true
    $SUDO usermod  -u "$MUNGE_UID" munge  2>/dev/null || true
else
    $SUDO groupadd -g "$MUNGE_GID" munge
    $SUDO useradd  -r -u "$MUNGE_UID" -g munge -s /usr/sbin/nologin munge
fi

if id "slurm" &>/dev/null; then
    $SUDO groupmod -g "$SLURM_GID" slurm  2>/dev/null || true
    $SUDO usermod  -u "$SLURM_UID" slurm  2>/dev/null || true
else
    $SUDO groupadd -g "$SLURM_GID" slurm
    $SUDO useradd  -r -u "$SLURM_UID" -g slurm -s /usr/sbin/nologin slurm
fi

# ---------------------------------------------------------------------------
# 4. Create persistent directories (survive across container restarts)
# ---------------------------------------------------------------------------
log "Creating directories …"
ensure_dir "$SLURM_CONF_DIR"
ensure_dir "/var/spool/slurm"        "slurm:slurm" "755"
ensure_dir "/var/spool/slurm/state"  "slurm:slurm" "755"
ensure_dir "/var/log/slurm"          "slurm:slurm" "755"
ensure_dir "/etc/munge"              "munge:munge"  "700"
ensure_dir "/var/lib/munge"          "munge:munge"  "711"
ensure_dir "/var/log/munge"          "munge:munge"  "755"

# ---------------------------------------------------------------------------
# 5. Cleanup apt caches (keep image small)
# ---------------------------------------------------------------------------
log "Cleaning up …"
$SUDO apt-get clean
$SUDO rm -rf /var/lib/apt/lists/*

log "Build-time setup complete. Use slurm_client_entrypoint.sh at container start."
