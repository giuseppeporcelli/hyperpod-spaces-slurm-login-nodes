#!/usr/bin/env bash
#
# restart-remote-access.sh
# Stops the remote access server (if running as root) and restarts it
# as the specified user via gosu, then exec's the given runtime script.
#
# Usage:
#   restart-remote-access.sh <username> <runtime_script> [runtime_args...]
#
# This script is used as a wrapper: it restarts the remote access server
# under the correct user identity, then hands off to the real runtime.

set -euo pipefail

REMOTE_ACCESS_SERVER="/opt/amazon/sagemaker/workspace/remote-access/remote-access-server"
REMOTE_ACCESS_PORT="${REMOTE_ACCESS_SERVER_PORT:-2222}"
SUPERVISOR_SOCKET="/var/run/supervisord/supervisor.sock"

USERNAME="${1:?FATAL: username argument required}"
shift
RUNTIME_SCRIPT="${1:?FATAL: runtime_script argument required}"
shift

log() { printf '[remote-access-restart] %s\n' "$*"; }

# -----------------------------------------------------------------------
# 1. Stop the remote access server running as root
# -----------------------------------------------------------------------
stop_remote_access_server() {
  log "Stopping remote access server (if running as root)..."

  # Try supervisor first (suppress errors if socket doesn't exist)
  if [ -S "$SUPERVISOR_SOCKET" ]; then
    log "Attempting stop via supervisord..."
    sudo /opt/conda/bin/supervisorctl -s "unix://${SUPERVISOR_SOCKET}" stop sagemaker-remote-access-server 2>/dev/null || true
  fi

  # Kill any remaining process directly
  if pgrep -f "[r]emote-access-server" >/dev/null 2>&1; then
    log "Killing remote access server process..."
    sudo pkill -f "remote-access-server" 2>/dev/null || true
    # Wait briefly for process to exit
    sleep 1
    # Force kill if still running
    if pgrep -f "[r]emote-access-server" >/dev/null 2>&1; then
      log "Force killing remote access server..."
      sudo pkill -9 -f "remote-access-server" 2>/dev/null || true
      sleep 1
    fi
  fi

  log "Remote access server stopped."
}

# -----------------------------------------------------------------------
# 2. Restart the remote access server as the target user
# -----------------------------------------------------------------------
start_remote_access_server_as_user() {
  if [ ! -x "$REMOTE_ACCESS_SERVER" ]; then
    log "WARNING: Remote access server binary not found or not executable at ${REMOTE_ACCESS_SERVER}, skipping restart"
    return 0
  fi

  # Fix log directory permissions so the non-root user can write logs
  if [ -d "/var/log/studio/remoteAccess" ]; then
    chmod -R 777 /var/log/studio/remoteAccess
  fi

  log "Starting remote access server as ${USERNAME} on port ${REMOTE_ACCESS_PORT}..."
  # Use su instead of gosu for the background process, reserving gosu for the
  # final exec into the runtime script (gosu is designed for exec, not fork).
  su -s /bin/bash "${USERNAME}" -c "nohup '${REMOTE_ACCESS_SERVER}' -port '${REMOTE_ACCESS_PORT}' > /dev/null 2>&1 &"

  # Verify it started
  sleep 2
  if pgrep -f "[r]emote-access-server" >/dev/null 2>&1; then
    log "Remote access server running as ${USERNAME}."
  else
    log "WARNING: Remote access server may not have started. Check logs."
  fi
}

# -----------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------
stop_remote_access_server
start_remote_access_server_as_user

log "Handing off to runtime: ${RUNTIME_SCRIPT} $*"
exec gosu "${USERNAME}" "${RUNTIME_SCRIPT}" "$@"
