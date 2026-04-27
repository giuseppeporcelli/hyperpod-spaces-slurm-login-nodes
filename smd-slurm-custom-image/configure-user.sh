#!/usr/bin/env bash
#
# configure-user.sh
# Runtime script: ensures the user and group entries exist in local databases
# (/etc/passwd, /etc/group) so that statically compiled tools like gosu can
# resolve the user.
#
# Resolves UID, GID, and supplemental groups from SSSD/NSS via the `id` command
# rather than relying on environment variables. This ensures the local entries
# match what the identity provider (AD/LDAP) has authoritative.
#
# Usage:
#   configure-user.sh <username>
#
# The username must be resolvable via NSS/SSSD.
# Home directory is derived from USER_HOME_BASE (sourced from config.sh).

set -euo pipefail

source /usr/bin/config.sh

if [ -z "${1:-}" ]; then
  echo "[user-configure] FATAL: USERNAME argument is required. Usage: configure-user.sh <username>" >&2
  exit 1
fi

USERNAME="$1"
HOME_DIR="${USER_HOME_BASE}/${USERNAME}"

echo "[user-configure] Resolving user '${USERNAME}' via NSS (SSSD)..."

# Resolve UID and primary GID from SSSD/NSS
UID_VAL=$(id -u "$USERNAME" 2>/dev/null) || { echo "[user-configure] ERROR: Cannot resolve UID for '${USERNAME}' via id"; exit 1; }
GID_VAL=$(id -g "$USERNAME" 2>/dev/null) || { echo "[user-configure] ERROR: Cannot resolve GID for '${USERNAME}' via id"; exit 1; }

echo "[user-configure] Resolved: uid=${UID_VAL} gid=${GID_VAL}"

# Resolve primary group name
PRIMARY_GROUP=$(id -gn "$USERNAME" 2>/dev/null) || PRIMARY_GROUP="${USERNAME}"
echo "[user-configure] Primary group: ${PRIMARY_GROUP} (${GID_VAL})"

# Ensure primary group exists in /etc/group
if ! grep -q ":${GID_VAL}:" /etc/group 2>/dev/null; then
  echo "[user-configure] Adding group ${PRIMARY_GROUP}:x:${GID_VAL}"
  echo "${PRIMARY_GROUP}:x:${GID_VAL}:" >> /etc/group
fi

# Ensure user exists in /etc/passwd
if ! grep -q "^${USERNAME}:" /etc/passwd; then
  echo "[user-configure] Adding passwd entry ${USERNAME}:x:${UID_VAL}:${GID_VAL}::${HOME_DIR}:/bin/bash"
  echo "${USERNAME}:x:${UID_VAL}:${GID_VAL}::${HOME_DIR}:/bin/bash" >> /etc/passwd
fi

# Ensure user has a shadow entry so PAM doesn't treat the account as locked.
# '*' means no local password (auth is handled by SSSD), but the account is not locked
# (a locked account uses '!' or '!!' prefix).
if ! grep -q "^${USERNAME}:" /etc/shadow 2>/dev/null; then
  echo "[user-configure] Adding shadow entry for ${USERNAME}"
  echo "${USERNAME}:*:19000:0:99999:7:::" >> /etc/shadow
fi

# Resolve and configure supplemental groups from NSS
# `id -G` returns all GIDs (including primary); group names are resolved
# individually via getent to correctly handle names containing spaces.
SUPP_GIDS=$(id -G "$USERNAME" 2>/dev/null) || SUPP_GIDS=""

echo "[user-configure] Supplemental GIDs: ${SUPP_GIDS:-none}"

# Convert GID list to array (GIDs are numeric, so word-splitting is safe)
read -ra GID_ARRAY <<< "$SUPP_GIDS"

for GID_SUPP in "${GID_ARRAY[@]}"; do
  # Skip the primary group — already handled
  [ "$GID_SUPP" = "$GID_VAL" ] && continue

  # Resolve group name from GID; fall back to a synthetic name
  GROUP_NAME=$(getent group "$GID_SUPP" 2>/dev/null | cut -d: -f1) || true
  GROUP_NAME="${GROUP_NAME:-grp${GID_SUPP}}"

  if ! grep -q ":${GID_SUPP}:" /etc/group 2>/dev/null; then
    echo "[user-configure] Adding supplemental group ${GROUP_NAME}:x:${GID_SUPP}"
    echo "${GROUP_NAME}:x:${GID_SUPP}:" >> /etc/group
  fi

  usermod -aG "$GROUP_NAME" "$USERNAME" 2>/dev/null || \
    echo "[user-configure] WARNING: usermod -aG '${GROUP_NAME}' ${USERNAME} failed"
done

echo "[user-configure] User/group configuration complete."
