#!/bin/bash
set -e

source /usr/bin/config.sh

if [ -z "${WORKSPACE_CREATOR_USERNAME:-}" ]; then
  echo "[proxy] FATAL: WORKSPACE_CREATOR_USERNAME is not set or empty. Refusing to start." >&2
  exit 1
fi

FULL_USERNAME="${WORKSPACE_CREATOR_USERNAME}"
echo "[proxy] Raw username from workspace annotation: ${FULL_USERNAME}"
# Extract username after last '/' and lowercase it
if [[ "$FULL_USERNAME" == */* ]]; then
  FULL_USERNAME="${FULL_USERNAME##*/}"
fi
FULL_USERNAME="${FULL_USERNAME,,}"
echo "[proxy] Username after prefix strip and lowercase: ${FULL_USERNAME}"
# Strip domain suffix: remove @domain, or fallback to last '-' as separator
if [[ "$FULL_USERNAME" == *@* ]]; then
  USERNAME="${FULL_USERNAME%%@*}"
elif [[ "$FULL_USERNAME" == *-* ]]; then
  USERNAME="${FULL_USERNAME%-*}"
else
  USERNAME="$FULL_USERNAME"
fi
echo "[proxy] Username after domain suffix strip: ${USERNAME}"
HOME_DIR="${USER_HOME_BASE}/${USERNAME}"

RUNTIME_SCRIPT="/opt/amazon/sagemaker/workspace/bin/start-workspace-jupyterlab-runtime"

echo "[proxy] Starting JupyterLab proxy for user=${USERNAME}, home=${HOME_DIR}"

echo "[proxy] Setting HOME=${HOME_DIR}"
export HOME="${HOME_DIR}"

echo "[proxy] Fixing permissions..."
chmod 777 /var/log/studio /opt/amazon/sagemaker/user-data /home/sagemaker-user
chmod -R 777 /opt/conda/etc/jupyter

echo "[proxy] Checking ServerApp.root_dir..."
if ! grep -q 'ServerApp.root_dir' "$RUNTIME_SCRIPT"; then
  echo "[proxy] Injecting --ServerApp.root_dir=${HOME_DIR}"
  sed -i "s|^CMD=\"jupyter lab |CMD=\"jupyter lab --ServerApp.root_dir=${HOME_DIR} |" "$RUNTIME_SCRIPT"
else
  echo "[proxy] ServerApp.root_dir already set, skipping"
fi

echo "[proxy] Checking terminado_settings..."
mkdir -p /opt/conda/etc/jupyter
if ! grep -q 'terminado_settings' /opt/conda/etc/jupyter/jupyter_server_config.py 2>/dev/null; then
  echo "[proxy] Setting terminado cwd to ${HOME_DIR}"
  echo "c.ServerApp.terminado_settings = {\"cwd\": \"${HOME_DIR}\"}" >> /opt/conda/etc/jupyter/jupyter_server_config.py
else
  echo "[proxy] terminado_settings already set, skipping"
fi

# Start SSSD only when using the sssd identity provider
if [ "${IDENTITY_PROVIDER}" = "sssd" ]; then
  echo "[proxy] Running SSSD configuration..."
  /usr/bin/configure-sssd.sh

  echo "[proxy] Waiting 2 seconds for SSSD to initialize..."
  sleep 2
else
  echo "[proxy] SSSD skipped (IDENTITY_PROVIDER=${IDENTITY_PROVIDER})"
fi

# Create local passwd/group entries so gosu can resolve the user.
# gosu is statically compiled and reads /etc/passwd directly — it does
# not use NSS/SSSD. The local entry is only used for uid/gid mapping.
echo "[proxy] Running user/group configuration..."
/usr/bin/configure-user.sh "${USERNAME}"

echo "[proxy] Ensuring home directory exists with correct ownership..."
if [ ! -d "$HOME_DIR" ]; then
  mkdir -p "$HOME_DIR"
fi
chown "${USERNAME}:$(id -gn "${USERNAME}")" "$HOME_DIR"
chmod 750 "$HOME_DIR"

echo "[proxy] Running sudoers configuration..."
/usr/bin/configure-sudoers.sh

echo "[proxy] Running Slurm configuration..."
/usr/bin/configure-slurm.sh

echo "[proxy] Sym-linking /home/sagemaker-user"
mv /home/sagemaker-user /tmp/sagemaker-user.bak
ln -s ${HOME_DIR} /home/sagemaker-user
cd "$HOME_DIR"

echo "[proxy] Configuring remote access server as ${USERNAME}..."
/usr/bin/configure-ras.sh "${USERNAME}"

echo "[proxy] Launching JupyterLab as ${USERNAME}..."
exec gosu "${USERNAME}" "$RUNTIME_SCRIPT"
