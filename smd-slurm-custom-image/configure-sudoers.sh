#!/bin/sh
#
# configure-sudoers.sh
# Hardens the sudoers file by removing the blanket NOPASSWD rule and
# optionally granting passwordless sudo to specific groups.
#
# Expected environment variables:
#   SUDOERS_GROUPS - Comma-separated list of groups to grant sudo access
#                    (e.g. "domain admins,sagemaker-admins,devops")
#                    If unset or empty, no group rules are added.
#

set -eu

# ---------------------------------------------------------------------------
# Configuration (loaded from centralized config.sh)
# ---------------------------------------------------------------------------
. /usr/bin/config.sh

echo "[configure-sudoers] Removing blanket NOPASSWD rule..."
sed -i '/^ALL[[:space:]]\+ALL=(ALL)[[:space:]]\+NOPASSWD:[[:space:]]\+ALL/d' /etc/sudoers

if [ -n "$SUDOERS_GROUPS" ]; then
  REMAINING="$SUDOERS_GROUPS"
  while [ -n "$REMAINING" ]; do
    # Extract the first comma-delimited token
    GROUP="${REMAINING%%,*}"
    # Remove it from the remaining string
    if [ "$GROUP" = "$REMAINING" ]; then
      REMAINING=""
    else
      REMAINING="${REMAINING#*,}"
    fi

    # Trim leading/trailing whitespace
    GROUP=$(echo "$GROUP" | xargs)
    [ -z "$GROUP" ] && continue

    SUDOERS_FILE="/etc/sudoers.d/group-$(echo "$GROUP" | tr ' ' '_' | tr -cd '[:alnum:]_-')"

    # Escape spaces for sudoers syntax (e.g. "Domain Users" -> "Domain\ Users")
    ESCAPED_GROUP=$(echo "$GROUP" | sed 's/ /\\ /g')

    echo "[configure-sudoers] Granting NOPASSWD sudo to group '${GROUP}' -> ${SUDOERS_FILE}"
    echo "%${ESCAPED_GROUP} ALL=(ALL) NOPASSWD: ALL" > "$SUDOERS_FILE"
    chmod 0440 "$SUDOERS_FILE"
  done
else
  echo "[configure-sudoers] No SUDOERS_GROUPS defined; no group sudo rules added."
fi

echo "[configure-sudoers] Sudoers configuration complete."
