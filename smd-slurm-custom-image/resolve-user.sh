#!/usr/bin/env bash
#
# resolve-user.sh
# Resolves UID, GID, primary group name, and supplemental groups for a given
# username. Supports two identity providers controlled by IDENTITY_PROVIDER
# in config.sh:
#
#   "sssd" — resolves via NSS (SSSD must be running)
#   "file" — resolves from a root-owned JSON-Lines file (USER_DB_PATH)
#
# Output: prints shell variable assignments to stdout, intended to be eval'd:
#
#   RESOLVED_UID=10001
#   RESOLVED_GID=10001
#   RESOLVED_PRIMARY_GROUP=alice
#   RESOLVED_SUPP_GIDS="10100 10200"
#   RESOLVED_SUPP_GROUPS="devs:10100 docker:10200"
#
# Usage:
#   eval "$(resolve-user.sh <username>)"
#
# Exit codes:
#   0 — success
#   1 — user not found or resolution error

set -euo pipefail

source /usr/bin/config.sh

if [ -z "${1:-}" ]; then
  echo "FATAL: USERNAME argument required. Usage: resolve-user.sh <username>" >&2
  exit 1
fi

USERNAME="$1"

# ---------------------------------------------------------------------------
# Provider: SSSD / NSS
# ---------------------------------------------------------------------------
resolve_via_sssd() {
  local user="$1"

  local uid_val gid_val primary_group supp_gids

  uid_val=$(id -u "$user" 2>/dev/null) || {
    echo "ERROR: Cannot resolve UID for '${user}' via NSS" >&2; return 1
  }
  gid_val=$(id -g "$user" 2>/dev/null) || {
    echo "ERROR: Cannot resolve GID for '${user}' via NSS" >&2; return 1
  }
  primary_group=$(id -gn "$user" 2>/dev/null) || primary_group="$user"
  supp_gids=$(id -G "$user" 2>/dev/null) || supp_gids=""

  echo "RESOLVED_UID=${uid_val}"
  echo "RESOLVED_GID=${gid_val}"
  echo "RESOLVED_PRIMARY_GROUP=${primary_group}"

  # Build supplemental group list (excluding primary)
  local supp_gid_list="" supp_group_list=""
  read -ra gid_array <<< "$supp_gids"
  for gid in "${gid_array[@]}"; do
    [ "$gid" = "$gid_val" ] && continue
    local gname
    gname=$(getent group "$gid" 2>/dev/null | cut -d: -f1) || true
    gname="${gname:-grp${gid}}"
    supp_gid_list="${supp_gid_list:+${supp_gid_list} }${gid}"
    supp_group_list="${supp_group_list:+${supp_group_list} }${gname}:${gid}"
  done

  echo "RESOLVED_SUPP_GIDS=\"${supp_gid_list}\""
  echo "RESOLVED_SUPP_GROUPS=\"${supp_group_list}\""
}

# ---------------------------------------------------------------------------
# Provider: JSON-Lines file
# ---------------------------------------------------------------------------
resolve_via_file() {
  local user="$1"
  local db_path="${USER_DB_PATH}"

  # Validate the database file exists and has safe ownership
  if [ ! -f "$db_path" ]; then
    echo "ERROR: User database not found: ${db_path}" >&2
    return 1
  fi

  local file_owner file_perms
  file_owner=$(stat -c '%u:%g' "$db_path" 2>/dev/null || stat -f '%u:%g' "$db_path" 2>/dev/null)
  if [ "$file_owner" != "0:0" ]; then
    echo "ERROR: ${db_path} must be owned by root:root (current: ${file_owner})" >&2
    return 1
  fi

  # jq is available in sagemaker-distribution base images.
  # Parse the matching line from the JSONL file.
  local record
  record=$(jq -c --arg u "$user" 'select(.username == $u)' "$db_path" 2>/dev/null | head -1)

  if [ -z "$record" ]; then
    echo "ERROR: User '${user}' not found in ${db_path}" >&2
    return 1
  fi

  local uid_val gid_val primary_group
  uid_val=$(echo "$record" | jq -r '.uid')
  gid_val=$(echo "$record" | jq -r '.gid')
  primary_group=$(echo "$record" | jq -r '.group // .username')

  if [ "$uid_val" = "null" ] || [ "$gid_val" = "null" ]; then
    echo "ERROR: uid or gid missing for '${user}' in ${db_path}" >&2
    return 1
  fi

  echo "RESOLVED_UID=${uid_val}"
  echo "RESOLVED_GID=${gid_val}"
  echo "RESOLVED_PRIMARY_GROUP=${primary_group}"

  # Supplemental groups: {"groupname": gid, ...}
  local supp_gid_list="" supp_group_list=""
  local supp_json
  supp_json=$(echo "$record" | jq -r '.supplemental_groups // empty | to_entries[] | "\(.key):\(.value)"' 2>/dev/null) || true

  for entry in $supp_json; do
    local gname="${entry%%:*}"
    local gid="${entry##*:}"
    supp_gid_list="${supp_gid_list:+${supp_gid_list} }${gid}"
    supp_group_list="${supp_group_list:+${supp_group_list} }${gname}:${gid}"
  done

  echo "RESOLVED_SUPP_GIDS=\"${supp_gid_list}\""
  echo "RESOLVED_SUPP_GROUPS=\"${supp_group_list}\""
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
case "${IDENTITY_PROVIDER}" in
  sssd)
    resolve_via_sssd "$USERNAME"
    ;;
  file)
    resolve_via_file "$USERNAME"
    ;;
  *)
    echo "ERROR: Unknown IDENTITY_PROVIDER '${IDENTITY_PROVIDER}'. Must be 'sssd' or 'file'." >&2
    exit 1
    ;;
esac
