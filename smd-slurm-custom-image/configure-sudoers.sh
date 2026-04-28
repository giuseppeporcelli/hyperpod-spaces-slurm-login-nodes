#!/bin/sh
#
# configure-sudoers.sh
# Hardens the sudoers file by removing the blanket NOPASSWD rule and
# configuring group-based sudo access in two tiers:
#
#   1. Full sudo — groups listed in SUDOERS_GROUPS receive unrestricted
#      passwordless sudo (ALL commands).
#
#   2. Restricted sudo — groups listed in SUDOERS_RESTRICTED_GROUPS receive
#      passwordless sudo limited to the commands in SUDOERS_ALLOWED_COMMANDS.
#      A Cmnd_Alias is generated per group and only those commands are
#      permitted; all other sudo invocations are denied.
#
# All variables are sourced from config.sh (hardcoded, not overridable):
#   SUDOERS_GROUPS             - CSV of groups for full sudo
#   SUDOERS_RESTRICTED_GROUPS  - CSV of groups for command-limited sudo
#   SUDOERS_ALLOWED_COMMANDS   - Newline-separated list of allowed commands
#                                (standard sudoers Cmnd syntax, wildcards OK)
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

# ---------------------------------------------------------------------------
# Restricted-sudo groups: command-limited NOPASSWD rules
# ---------------------------------------------------------------------------
if [ -n "$SUDOERS_RESTRICTED_GROUPS" ] && [ -n "$SUDOERS_ALLOWED_COMMANDS" ]; then
  # Build the comma-separated Cmnd_Alias value from the newline-separated list
  CMND_LIST=""
  IFS_SAVE="$IFS"
  IFS='
'
  for CMD in $SUDOERS_ALLOWED_COMMANDS; do
    CMD=$(echo "$CMD" | xargs)
    [ -z "$CMD" ] && continue
    if [ -z "$CMND_LIST" ]; then
      CMND_LIST="$CMD"
    else
      CMND_LIST="$CMND_LIST, $CMD"
    fi
  done
  IFS="$IFS_SAVE"

  REMAINING="$SUDOERS_RESTRICTED_GROUPS"
  while [ -n "$REMAINING" ]; do
    GROUP="${REMAINING%%,*}"
    if [ "$GROUP" = "$REMAINING" ]; then
      REMAINING=""
    else
      REMAINING="${REMAINING#*,}"
    fi

    GROUP=$(echo "$GROUP" | xargs)
    [ -z "$GROUP" ] && continue

    SAFE_NAME=$(echo "$GROUP" | tr ' ' '_' | tr -cd '[:alnum:]_-')
    SUDOERS_FILE="/etc/sudoers.d/restricted-${SAFE_NAME}"
    ESCAPED_GROUP=$(echo "$GROUP" | sed 's/ /\\ /g')
    ALIAS_NAME="RESTRICTED_$(echo "$SAFE_NAME" | tr '[:lower:]' '[:upper:]' | tr '-' '_')"

    echo "[configure-sudoers] Granting restricted NOPASSWD sudo to group '${GROUP}' -> ${SUDOERS_FILE}"
    {
      echo "Cmnd_Alias ${ALIAS_NAME} = ${CMND_LIST}"
      echo "%${ESCAPED_GROUP} ALL=(ALL) NOPASSWD: ${ALIAS_NAME}"
    } > "$SUDOERS_FILE"
    chmod 0440 "$SUDOERS_FILE"
  done
else
  echo "[configure-sudoers] No SUDOERS_RESTRICTED_GROUPS or SUDOERS_ALLOWED_COMMANDS defined; skipping restricted sudo rules."
fi

echo "[configure-sudoers] Sudoers configuration complete."
