#!/usr/bin/env bash
#
# configure-user.sh
# Runtime script: ensures the user and group entries exist in local databases
# (/etc/passwd, /etc/group) so that statically compiled tools like gosu can
# resolve the user.
#
# Identity resolution is delegated to resolve-user.sh, which supports two
# providers controlled by IDENTITY_PROVIDER in config.sh:
#
#   "sssd" — resolves UID/GID/groups via NSS (SSSD must be running)
#   "file" — resolves from a root-owned JSON-Lines file
#
# Usage:
#   configure-user.sh <username>
#
# Home directory is derived from USER_HOME_BASE (sourced from config.sh).

set -euo pipefail

source /usr/bin/config.sh

if [ -z "${1:-}" ]; then
  echo "[user-configure] FATAL: USERNAME argument is required. Usage: configure-user.sh <username>" >&2
  exit 1
fi

USERNAME="$1"
HOME_DIR="${USER_HOME_BASE}/${USERNAME}"

echo "[user-configure] Resolving user '${USERNAME}' via provider '${IDENTITY_PROVIDER}'..."

# ---------------------------------------------------------------------------
# Resolve identity attributes via the pluggable resolver
# ---------------------------------------------------------------------------
eval "$(/usr/bin/resolve-user.sh "${USERNAME}")"

UID_VAL="${RESOLVED_UID}"
GID_VAL="${RESOLVED_GID}"
PRIMARY_GROUP="${RESOLVED_PRIMARY_GROUP}"

echo "[user-configure] Resolved: uid=${UID_VAL} gid=${GID_VAL}"
echo "[user-configure] Primary group: ${PRIMARY_GROUP} (${GID_VAL})"

# ---------------------------------------------------------------------------
# Ensure primary group exists in /etc/group
# ---------------------------------------------------------------------------
if ! grep -q ":${GID_VAL}:" /etc/group 2>/dev/null; then
  echo "[user-configure] Adding group ${PRIMARY_GROUP}:x:${GID_VAL}"
  echo "${PRIMARY_GROUP}:x:${GID_VAL}:" >> /etc/group
fi

# ---------------------------------------------------------------------------
# Ensure user exists in /etc/passwd
# ---------------------------------------------------------------------------
if ! grep -q "^${USERNAME}:" /etc/passwd; then
  echo "[user-configure] Adding passwd entry ${USERNAME}:x:${UID_VAL}:${GID_VAL}::${HOME_DIR}:/bin/bash"
  echo "${USERNAME}:x:${UID_VAL}:${GID_VAL}::${HOME_DIR}:/bin/bash" >> /etc/passwd
fi

# ---------------------------------------------------------------------------
# Ensure user has a shadow entry so PAM doesn't treat the account as locked.
# '*' means no local password (auth is handled externally), but the account
# is not locked (a locked account uses '!' or '!!' prefix).
# ---------------------------------------------------------------------------
if ! grep -q "^${USERNAME}:" /etc/shadow 2>/dev/null; then
  echo "[user-configure] Adding shadow entry for ${USERNAME}"
  echo "${USERNAME}:*:19000:0:99999:7:::" >> /etc/shadow
fi

# ---------------------------------------------------------------------------
# Configure supplemental groups
# ---------------------------------------------------------------------------
echo "[user-configure] Supplemental groups: ${RESOLVED_SUPP_GROUPS:-none}"

IFS='|' read -ra SUPP_ENTRIES <<< "${RESOLVED_SUPP_GROUPS}"
for entry in "${SUPP_ENTRIES[@]}"; do
  [ -z "$entry" ] && continue
  # Each entry is "groupname:gid"
  GROUP_NAME="${entry%%:*}"
  GID_SUPP="${entry##*:}"

  if ! grep -q ":${GID_SUPP}:" /etc/group 2>/dev/null; then
    echo "[user-configure] Adding supplemental group ${GROUP_NAME}:x:${GID_SUPP}"
    echo "${GROUP_NAME}:x:${GID_SUPP}:" >> /etc/group
  fi

  usermod -aG "$GROUP_NAME" "$USERNAME" 2>/dev/null || \
    echo "[user-configure] WARNING: usermod -aG '${GROUP_NAME}' ${USERNAME} failed"
done

echo "[user-configure] User/group configuration complete."
