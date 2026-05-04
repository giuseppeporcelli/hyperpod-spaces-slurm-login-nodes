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
# Strip domain suffix: remove @domain
if [[ "$FULL_USERNAME" == *@* ]]; then
  USERNAME="${FULL_USERNAME%%@*}"
else
  USERNAME="$FULL_USERNAME"
fi
echo "[proxy] Username after domain suffix strip: ${USERNAME}"
HOME_DIR="${USER_HOME_BASE}/${USERNAME}"

echo "[proxy] Starting Code Editor proxy for user=${USERNAME}, home=${HOME_DIR}"

echo "[proxy] Setting HOME=${HOME_DIR}"
export HOME="${HOME_DIR}"

echo "[proxy] Fixing permissions..."
chmod 777 /var/log/studio /opt/amazon/sagemaker/user-data /home/sagemaker-user

echo "[proxy] Running SSSD configuration..."
/usr/bin/configure-sssd.sh

echo "[proxy] Waiting 2 seconds for SSSD to initialize..."
sleep 2

# Create local passwd/group entries so gosu can resolve the user.
# gosu is statically compiled and reads /etc/passwd directly — it does
# not use NSS/SSSD. The local entry is only used for uid/gid mapping.
echo "[proxy] Running user/group configuration..."
/usr/bin/configure-user.sh "${USERNAME}"

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

echo "[proxy] Launching Code Editor as ${USERNAME}..."
exec gosu "${USERNAME}" sagemaker-code-editor --host 0.0.0.0 --port 8888 --without-connection-token --default-folder "$HOME_DIR"
