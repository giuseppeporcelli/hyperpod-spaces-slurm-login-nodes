#!/usr/bin/env bash
#
# install-sssd.sh
# Build-time script: installs SSSD and LDAP client packages, removes
# ec2-instance-connect, and creates required directories.
# Run this in a Dockerfile RUN layer.
#
# Runtime counterpart: configure-sssd.sh
#
# Reference: https://github.com/awslabs/awsome-distributed-training
#            setup_sssd.py (base-config)
#

set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() { printf '[sssd-build] %s\n' "$*"; }

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

# ---------------------------------------------------------------------------
# 1. Install SSSD and LDAP packages
# ---------------------------------------------------------------------------
log "Installing SSSD and LDAP packages …"
export DEBIAN_FRONTEND=noninteractive
$SUDO apt-get update -qq
$SUDO apt-get install -y --no-install-recommends \
    sssd \
    ldap-utils \
    sssd-tools

# ---------------------------------------------------------------------------
# 2. Remove ec2-instance-connect (overrides AuthorizedKeysCommand)
# ---------------------------------------------------------------------------
log "Removing ec2-instance-connect …"
$SUDO apt-get remove -y ec2-instance-connect 2>/dev/null || true

# ---------------------------------------------------------------------------
# 3. Create required directories
# ---------------------------------------------------------------------------
log "Creating SSSD/LDAP directories …"
$SUDO mkdir -p /etc/sssd /etc/ldap

# ---------------------------------------------------------------------------
# 4. Cleanup
# ---------------------------------------------------------------------------
log "Cleaning up …"
$SUDO apt-get clean
$SUDO rm -rf /var/lib/apt/lists/*

log "SSSD build-time setup complete."
