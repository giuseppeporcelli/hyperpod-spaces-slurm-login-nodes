#!/usr/bin/env bash
# =============================================================================
# config.sh — Centralized configuration for SMD Slurm custom images
# =============================================================================
#
# This file defines ALL configurable variables used across the build-time and
# runtime scripts in this image. Source it at the top of every script:
#
#     SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#     source "${SCRIPT_DIR}/config.sh"          # when scripts live side-by-side
#     source /usr/bin/config.sh                  # at runtime inside the container
#
# SECURITY NOTE:
#   Runtime security-sensitive variables are HARDCODED and cannot be overridden
#   via environment variables. This prevents privilege escalation through env
#   var injection in workspace specs. Only build-time variables (used during
#   docker build, not at runtime) retain the VAR="${VAR:-default}" pattern.
#
# Sections:
#   1. User home directory
#   2. Shared mount
#   3. Slurm — build-time (overridable via build args)
#   4. Slurm — runtime (hardcoded)
#   5. SSSD / LDAP (hardcoded)
#   6. Sudoers (hardcoded)
# =============================================================================

# ---------------------------------------------------------------------------
# 1. User home directory (HARDCODED — security sensitive)
# ---------------------------------------------------------------------------
# Base path for user home directories on the FSx volume.
# The proxy scripts derive HOME_DIR as ${USER_HOME_BASE}/<username>.
USER_HOME_BASE="/fsx"

# ---------------------------------------------------------------------------
# 2. Shared mount (HARDCODED — security sensitive)
# ---------------------------------------------------------------------------
# Directory where Slurm/SSSD config files and secrets are mounted.
# Must NOT be overridable — controls where MUNGE keys and LDAP creds are read from.
SLURM_SHARED_DIR="/fsx/.hyperpod_spaces_conf"

# ---------------------------------------------------------------------------
# 3. Slurm — build-time (install-slurm.sh) — overridable via build args
# ---------------------------------------------------------------------------
# These are only used during `docker build` and have no runtime security impact.
SLURM_VERSION="${SLURM_VERSION:-24.11.0}"

MUNGE_UID="${MUNGE_UID:-991}"
MUNGE_GID="${MUNGE_GID:-991}"
SLURM_UID="${SLURM_UID:-992}"
SLURM_GID="${SLURM_GID:-992}"

# ---------------------------------------------------------------------------
# 4. Slurm — runtime (configure-slurm.sh) — HARDCODED
# ---------------------------------------------------------------------------
SLURM_CONF_FILENAME="slurm.conf"
ACCOUNTING_CONF_FILENAME="accounting.conf"
GRES_CONF_FILENAME="gres.conf"
MUNGE_KEY_FILENAME="munge.key"

SLURM_CONF_DIR="/usr/local/etc"
SLURM_CONF="${SLURM_CONF_DIR}/slurm.conf"
MUNGE_KEY_DST="/etc/munge/munge.key"
MUNGE_SOCKET_TIMEOUT="5"

# ---------------------------------------------------------------------------
# 5. SSSD / LDAP (configure-sssd.sh) — HARDCODED
# ---------------------------------------------------------------------------
SSSD_ENABLED="true"
SSSD_DOMAIN="default"
SSSD_LDAP_URI="ldaps://m-ad-bbd53aced45f300e.elb.us-west-2.amazonaws.com"
SSSD_LDAP_SEARCH_BASE="dc=hyperpod,dc=gianpo,dc=local"
SSSD_LDAP_BIND_DN="CN=ReadOnly,OU=Users,OU=hyperpod,DC=hyperpod,DC=gianpo,DC=local"
SSSD_LDAP_AUTHTOK_TYPE="obfuscated_password"
SSSD_LDAPS_CERT_PATH="${SLURM_SHARED_DIR}/ldaps.crt"
SSSD_OVERRIDE_HOMEDIR="/fsx/%u"

# SSSD_LDAP_AUTHTOK is intentionally NOT defaulted here — it is a secret.
# At runtime, if unset, configure-sssd.sh reads it from:
#   ${SLURM_SHARED_DIR}/ldap_authtok

# Derived paths (not overridable)
SSSD_CERT_DEST="/etc/ldap/ldaps.crt"
SSSD_CONF_PATH="/etc/sssd/sssd.conf"
SSSD_LDAP_CONF="/etc/ldap/ldap.conf"
SSSD_SSHD_CONF="/etc/ssh/sshd_config"

# ---------------------------------------------------------------------------
# 6. Sudoers (configure-sudoers.sh) — HARDCODED
# ---------------------------------------------------------------------------
# Comma-separated list of groups to grant passwordless sudo.
# MUST NOT be overridable — prevents users from granting themselves sudo.
SUDOERS_GROUPS="ClusterAdmin,Domain Admins"
