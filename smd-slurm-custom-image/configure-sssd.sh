#!/usr/bin/env bash
#
# sssd_configure.sh
# Runtime script: configures SSSD for Active Directory / LDAP authentication.
# Reads configuration from environment variables and shared mount, writes
# sssd.conf, installs the LDAPS certificate, configures SSH and sudoers,
# enables automatic home directory creation, and starts SSSD.
#
# Pair with: sssd_install.sh (build-time)
#
# All configurable variables are defined in config.sh.
# Override any value via environment variables (e.g. docker run -e).
# See config.sh for the full list and defaults.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (loaded from centralized config.sh)
# ---------------------------------------------------------------------------
source /usr/bin/config.sh

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() { printf '[sssd-runtime] %s\n' "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

# ---------------------------------------------------------------------------
# Guard: skip if SSSD is not enabled
# ---------------------------------------------------------------------------
if [ "$SSSD_ENABLED" != "true" ]; then
    log "SSSD_ENABLED is not 'true', skipping SSSD configuration."
    exit 0
fi

# ---------------------------------------------------------------------------
# Resolve LDAP auth token (secret — not stored in config.sh)
# ---------------------------------------------------------------------------
if [ -z "${SSSD_LDAP_AUTHTOK:-}" ]; then
    SSSD_LDAP_AUTHTOK_FILE="${SLURM_SHARED_DIR}/ldap_authtok"
    [ -f "$SSSD_LDAP_AUTHTOK_FILE" ] || die "SSSD_LDAP_AUTHTOK not set and ${SSSD_LDAP_AUTHTOK_FILE} not found"
    SSSD_LDAP_AUTHTOK="$(cat "$SSSD_LDAP_AUTHTOK_FILE")"
fi

# Use short aliases for derived paths from config.sh
CERT_DEST="$SSSD_CERT_DEST"
SSSD_CONF="$SSSD_CONF_PATH"
LDAP_CONF="$SSSD_LDAP_CONF"
SSHD_CONF="$SSSD_SSHD_CONF"

# ---------------------------------------------------------------------------
# Debug: dump resolved configuration
# ---------------------------------------------------------------------------
log "DEBUG: Resolved configuration:"
log "DEBUG:   SLURM_SHARED_DIR    = ${SLURM_SHARED_DIR}"
log "DEBUG:   SSSD_DOMAIN         = ${SSSD_DOMAIN}"
log "DEBUG:   SSSD_LDAP_URI       = ${SSSD_LDAP_URI}"
log "DEBUG:   SSSD_LDAP_SEARCH_BASE = ${SSSD_LDAP_SEARCH_BASE}"
log "DEBUG:   SSSD_LDAP_BIND_DN   = ${SSSD_LDAP_BIND_DN}"
log "DEBUG:   SSSD_LDAP_AUTHTOK   = (set, ${#SSSD_LDAP_AUTHTOK} chars)"
log "DEBUG:   SSSD_LDAP_AUTHTOK_TYPE = ${SSSD_LDAP_AUTHTOK_TYPE}"
log "DEBUG:   SSSD_LDAPS_CERT_PATH = ${SSSD_LDAPS_CERT_PATH}"
log "DEBUG:   SSSD_OVERRIDE_HOMEDIR = ${SSSD_OVERRIDE_HOMEDIR}"
log "DEBUG:   CERT_DEST           = ${CERT_DEST}"

# ---------------------------------------------------------------------------
# 1. Install LDAPS certificate
# ---------------------------------------------------------------------------
log "Installing LDAPS certificate from ${SSSD_LDAPS_CERT_PATH} …"
[ -f "$SSSD_LDAPS_CERT_PATH" ] || die "Certificate not found: ${SSSD_LDAPS_CERT_PATH}"

$SUDO cp "$SSSD_LDAPS_CERT_PATH" "$CERT_DEST"
$SUDO chmod 644 "$CERT_DEST"

log "DEBUG: Certificate installed at ${CERT_DEST}, size=$(stat -c%s "$CERT_DEST" 2>/dev/null || stat -f%z "$CERT_DEST" 2>/dev/null || echo 'unknown') bytes"
log "DEBUG: Certificate subject: $(openssl x509 -noout -subject -in "$CERT_DEST" 2>&1 || echo 'could not parse cert')"
log "DEBUG: Certificate issuer:  $(openssl x509 -noout -issuer -in "$CERT_DEST" 2>&1 || echo 'could not parse cert')"
log "DEBUG: Certificate expiry:  $(openssl x509 -noout -enddate -in "$CERT_DEST" 2>&1 || echo 'could not parse cert')"

# Update ldap.conf TLS_CACERT
if [ -f "$LDAP_CONF" ]; then
    $SUDO sed -i "s|^[# \t]*TLS_CACERT[ \t].*|TLS_CACERT ${CERT_DEST}|" "$LDAP_CONF"
    log "Updated TLS_CACERT in ${LDAP_CONF}"
fi

# ---------------------------------------------------------------------------
# 2. Write sssd.conf
# ---------------------------------------------------------------------------
log "Writing SSSD configuration …"
cat <<EOF | $SUDO tee "$SSSD_CONF" > /dev/null
[domain/${SSSD_DOMAIN}]
id_provider = ldap
cache_credentials = True
ldap_uri = ${SSSD_LDAP_URI}
ldap_search_base = ${SSSD_LDAP_SEARCH_BASE}
ldap_schema = AD
ldap_default_bind_dn = ${SSSD_LDAP_BIND_DN}
ldap_default_authtok_type = ${SSSD_LDAP_AUTHTOK_TYPE}
ldap_default_authtok = ${SSSD_LDAP_AUTHTOK}
ldap_tls_cacert = ${CERT_DEST}
ldap_tls_reqcert = allow
ldap_id_mapping = True
ldap_referrals = False
ldap_user_extra_attrs = altSecurityIdentities:altSecurityIdentities
ldap_user_ssh_public_key = altSecurityIdentities
ldap_use_tokengroups = True
enumerate = False
fallback_homedir = /home/%u
override_homedir = ${SSSD_OVERRIDE_HOMEDIR}
default_shell = /bin/bash
use_fully_qualified_names = False

[sssd]
config_file_version = 2
domains = ${SSSD_DOMAIN}
services = nss, pam, ssh

[pam]
offline_credentials_expiration = 14

[nss]
filter_users = nobody,root
filter_groups = nobody,root
EOF

$SUDO chmod 600 "$SSSD_CONF"
$SUDO chown root:root "$SSSD_CONF"

log "DEBUG: sssd.conf written, verifying..."
log "DEBUG: sssd.conf permissions: $(ls -la "$SSSD_CONF")"
log "DEBUG: sssd.conf content (redacted authtok):"
$SUDO sed 's/^ldap_default_authtok = .*/ldap_default_authtok = ***REDACTED***/' "$SSSD_CONF" | while IFS= read -r line; do log "DEBUG:   $line"; done

# ---------------------------------------------------------------------------
# 3. Configure SSH for SSSD
# ---------------------------------------------------------------------------
log "Restarting SSH to pick up SSSD changes …"
$SUDO service ssh restart 2>/dev/null || log "WARNING: Could not restart SSH service"

# ---------------------------------------------------------------------------
# 4. Enable automatic home directory creation
# ---------------------------------------------------------------------------
log "Enabling automatic home directory creation …"
$SUDO pam-auth-update --enable mkhomedir 2>/dev/null || log "WARNING: pam-auth-update not available or failed"

# ---------------------------------------------------------------------------
# 5. Start/restart services
# ---------------------------------------------------------------------------
log "DEBUG: nsswitch.conf passwd line: $(grep ^passwd /etc/nsswitch.conf 2>/dev/null || echo 'NOT FOUND')"
log "DEBUG: nsswitch.conf group line:  $(grep ^group /etc/nsswitch.conf 2>/dev/null || echo 'NOT FOUND')"
log "DEBUG: Checking if sssd binary exists: $(which sssd 2>/dev/null || echo 'NOT FOUND')"
log "DEBUG: SSSD version: $(sssd --version 2>/dev/null || echo 'unknown')"
log "DEBUG: SSSD packages installed: $(dpkg -l | grep sssd 2>/dev/null | awk '{print $2, $3}' || rpm -qa 2>/dev/null | grep sssd || echo 'could not query packages')"

log "Starting SSSD …"

# Kill any existing SSSD process before starting fresh
$SUDO killall sssd 2>/dev/null || true
sleep 1

# Start SSSD directly — the init script ('service sssd restart') uses
# start-stop-daemon flags that may be incompatible with this SSSD version.
if $SUDO sssd -D --logger=files 2>&1; then
    log "DEBUG: SSSD started via 'sssd -D --logger=files'"
else
    log "DEBUG: 'sssd -D --logger=files' failed (rc=$?), trying 'sssd -i' in background..."
    $SUDO sssd -i --logger=files &
    sleep 1
    if ps aux | grep '[s]ssd' > /dev/null 2>&1; then
        log "DEBUG: SSSD started via 'sssd -i' (background)"
    else
        log "ERROR: All SSSD start methods failed"
        log "DEBUG: SSSD log (last 30 lines):"
        tail -30 /var/log/sssd/*.log 2>/dev/null | while IFS= read -r line; do log "DEBUG:   $line"; done || log "DEBUG: No SSSD logs found in /var/log/sssd/"
        log "DEBUG: syslog SSSD entries (last 20 lines):"
        grep -i sssd /var/log/syslog 2>/dev/null | tail -20 | while IFS= read -r line; do log "DEBUG:   $line"; done || log "DEBUG: No SSSD entries in syslog"
        log "DEBUG: journalctl SSSD entries (last 20 lines):"
        journalctl -u sssd --no-pager -n 20 2>/dev/null | while IFS= read -r line; do log "DEBUG:   $line"; done || log "DEBUG: journalctl not available"
    fi
fi

log "DEBUG: SSSD process check: $(ps aux | grep '[s]ssd' || echo 'no sssd process found')"

if [ -f "$SSHD_CONF" ]; then
    log "Restarting SSH …"
    $SUDO service ssh restart 2>/dev/null || log "WARNING: Could not restart SSH service"
fi

log "SSSD configuration complete."
