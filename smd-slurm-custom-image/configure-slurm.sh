#!/usr/bin/env bash
#
# slurm_client_entrypoint.sh
# Runtime script: copies slurm.conf and munge.key from a shared mount,
# recreates tmpfs-backed directories, starts MUNGE, and exports environment
# variables.  Use as ENTRYPOINT to wrap your CMD.
#
# Pair with: slurm_client_setup.sh (build-time)
#

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (loaded from centralized config.sh)
# ---------------------------------------------------------------------------
source /usr/bin/config.sh

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() { printf '[slurm-runtime] %s\n' "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

ensure_dir() {
    local dir="$1" owner="${2:-root:root}" mode="${3:-755}"
    $SUDO mkdir -p "$dir"
    $SUDO chown "$owner" "$dir"
    $SUDO chmod "$mode" "$dir"
}

# ---------------------------------------------------------------------------
# 1. Validate shared mount
# ---------------------------------------------------------------------------
log "Looking for Slurm config in ${SLURM_SHARED_DIR} …"
[ -d "$SLURM_SHARED_DIR" ] \
    || die "Shared directory '${SLURM_SHARED_DIR}' not found. Mount it or set SLURM_SHARED_DIR."
[ -f "${SLURM_SHARED_DIR}/${SLURM_CONF_FILENAME}" ] \
    || die "${SLURM_CONF_FILENAME} not found in ${SLURM_SHARED_DIR}"
[ -f "${SLURM_SHARED_DIR}/${ACCOUNTING_CONF_FILENAME}" ] \
    || die "${ACCOUNTING_CONF_FILENAME} not found in ${SLURM_SHARED_DIR}"
[ -f "${SLURM_SHARED_DIR}/${GRES_CONF_FILENAME}" ] \
    || die "${GRES_CONF_FILENAME} not found in ${SLURM_SHARED_DIR}"
[ -f "${SLURM_SHARED_DIR}/${MUNGE_KEY_FILENAME}" ] \
    || die "${MUNGE_KEY_FILENAME} not found in ${SLURM_SHARED_DIR}"

# ---------------------------------------------------------------------------
# 2. Install Slurm config files from shared mount
# ---------------------------------------------------------------------------
log "Installing Slurm configuration files …"
$SUDO cp "${SLURM_SHARED_DIR}/${SLURM_CONF_FILENAME}"      "${SLURM_CONF_DIR}/slurm.conf"
$SUDO cp "${SLURM_SHARED_DIR}/${ACCOUNTING_CONF_FILENAME}"  "${SLURM_CONF_DIR}/accounting.conf"
$SUDO cp "${SLURM_SHARED_DIR}/${GRES_CONF_FILENAME}"        "${SLURM_CONF_DIR}/gres.conf"
$SUDO chmod 644 "${SLURM_CONF_DIR}/slurm.conf" \
                 "${SLURM_CONF_DIR}/accounting.conf" \
                 "${SLURM_CONF_DIR}/gres.conf"

# ---------------------------------------------------------------------------
# 3. Install MUNGE key from shared mount
# ---------------------------------------------------------------------------
log "Installing MUNGE key …"
$SUDO cp "${SLURM_SHARED_DIR}/${MUNGE_KEY_FILENAME}" "$MUNGE_KEY_DST"
$SUDO chown munge:munge "$MUNGE_KEY_DST"
$SUDO chmod 400 "$MUNGE_KEY_DST"

# ---------------------------------------------------------------------------
# 4. Recreate tmpfs-backed directories (lost between build and run)
# ---------------------------------------------------------------------------
log "Recreating runtime directories …"
ensure_dir "/run/munge"       "munge:munge" "755"
ensure_dir "/var/run/slurm"   "slurm:slurm" "755"

# Fix ownership of MUNGE dirs (UID may differ if image was rebuilt)
$SUDO chown -R munge:munge /etc/munge /var/log/munge /var/lib/munge /run/munge

# ---------------------------------------------------------------------------
# 5. Start MUNGE daemon
# ---------------------------------------------------------------------------
log "Starting MUNGE …"
$SUDO service munge stop 2>/dev/null || true
$SUDO service munge start || die "Failed to start MUNGE"

# Wait for the socket to appear
elapsed=0
while [ ! -S /var/run/munge/munge.socket.2 ] && [ "$elapsed" -lt "$MUNGE_SOCKET_TIMEOUT" ]; do
    sleep 1
    elapsed=$((elapsed + 1))
done

if [ -S /var/run/munge/munge.socket.2 ]; then
    $SUDO ln -sf /var/run/munge/munge.socket.2 /var/run/munge/munge.socket
    log "MUNGE socket ready."
else
    die "MUNGE socket did not appear within ${MUNGE_SOCKET_TIMEOUT}s"
fi

$SUDO service munge status || log "WARNING: MUNGE status check returned non-zero"
log "MUNGE user: $(id munge)"

# ---------------------------------------------------------------------------
# 6. Export environment
# ---------------------------------------------------------------------------
export SLURM_CONF
export MUNGE_KEY_PATH="$MUNGE_KEY_DST"

log "Slurm client ready."
