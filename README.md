# HyperPod Spaces as Slurm Login Nodes

## Overview

This project turns HyperPod Spaces workspaces into fully functional Slurm login nodes, letting users submit and manage HPC jobs directly from their JupyterLab or Code Editor environment. Each workspace is automatically configured with the correct Linux user identity and file system access so that Slurm commands (`srun`, `sbatch`, `squeue`, etc.) work seamlessly against the cluster.

To make this work, two pieces collaborate at runtime:

1. A Kubernetes mutating admission webhook (`hyperpod-spaces-user-webhook`) intercepts workspace creation and update events and injects the requesting user's username into the pod spec as an environment variable. This is the mechanism that ties a workspace to a real user identity without requiring any manual configuration.
2. Custom SageMaker Distribution images (`smd-slurm-custom-image/`) extend the official base images with Slurm client tooling, MUNGE authentication, and SSSD/LDAP integration. At container startup, the injected username is used to resolve the user's UID, GID, and supplemental groups from the identity provider, set up the home directory on the shared file system, initialize the Slurm client, and drop privileges to the correct user before launching the IDE.

The result is a workspace that behaves like an SSH session to a traditional Slurm login node: the user lands in their own home directory on the shared file system, has their correct group memberships, and can interact with the Slurm scheduler immediately.

---

## Webhook Setup

### What the Webhook Does

The webhook is a Go binary that runs as a TLS server on port 8443 inside the cluster. It registers itself as a `MutatingWebhookConfiguration` targeting the `workspaces.workspace.jupyter.org` CRD on `CREATE` and `UPDATE` operations.

When a workspace is created or updated:

1. It extracts the requesting user's username from the Kubernetes `AdmissionReview` request.
2. Strips any user-supplied `SPACES_WEBHOOK_USERNAME` from the existing env vars to prevent impersonation.
3. Builds a set of JSON Patch operations that inject environment variables into the workspace pod spec:
   - `SPACES_WEBHOOK_USERNAME` — the raw username from the admission request

At container startup, the custom image's proxy scripts first verify that `SPACES_WEBHOOK_USERNAME` is set (refusing to start if missing), then normalize the username (extracting the part after the last `/`, lowercasing, and stripping the `@domain` suffix), and derive the home directory from `USER_HOME_BASE` (hardcoded in `config.sh` as `/fsx`). SSSD/NSS is used to resolve the user's UID, GID, and supplemental groups from the identity provider (Active Directory / LDAP).

### Kubernetes Resources

The Helm chart (`chart/`) deploys the following resources into the `jupyter-k8s-system` namespace:

| Resource | Template | Purpose |
|----------|----------|---------|
| Deployment | `deployment.yaml` | Runs the webhook binary, mounts TLS certs from a Secret, exposes port 8443 |
| Service | `service.yaml` | Exposes the Deployment on port 443 → 8443 so the API server can reach `/mutate` |
| MutatingWebhookConfiguration | `webhookconfiguration.yaml` | Tells the API server to send `Workspace` admission reviews to the Service. Uses `cert-manager.io/inject-ca-from` to auto-inject the CA bundle. `failurePolicy: Ignore` ensures workspace creation isn't blocked if the webhook is down. |
| Certificate | `certificate.yaml` | cert-manager Certificate that generates a TLS keypair for the webhook Service DNS name and stores it in a Secret |
| ServiceAccount | `serviceaccount.yaml` | Identity for the webhook pod |

### TLS & cert-manager

The webhook requires TLS because the Kubernetes API server only calls webhooks over HTTPS. cert-manager handles this automatically:

1. The `Certificate` resource requests a cert for `<release>-hyperpod-spaces-user-webhook.jupyter-k8s-system.svc`.
2. cert-manager creates a `Secret` containing `tls.crt` and `tls.key`.
3. The Deployment mounts this Secret at `/certs`.
4. The `MutatingWebhookConfiguration` annotation `cert-manager.io/inject-ca-from` tells cert-manager to patch the webhook's `caBundle` field with the issuer's CA, so the API server trusts the webhook's certificate.

A cert-manager `Issuer` (or `ClusterIssuer`) must already exist in the namespace. The issuer name is configurable via `certManager.issuerName` in `values.yaml`.

### Prerequisites

- Docker
- `kubectl` connected to your target cluster
- Helm 3
- cert-manager installed on the cluster (with an Issuer created)
- FSx OpenZFS file system with per-user home directories
- SSSD configured in the custom image for user identity resolution (see [Custom Images](#custom-images-smd-slurm-custom-image))

### Helm Values

| Key | Default | Description |
|-----|---------|-------------|
| `image.repository` | `414900938744.dkr.ecr.us-west-2.amazonaws.com/hyperpod-spaces-user-webhook` | Container image repository |
| `image.tag` | `latest` | Image tag |
| `image.pullPolicy` | `Always` | Image pull policy |
| `replicas` | `1` | Number of webhook pod replicas |
| `namespace` | `jupyter-k8s-system` | Namespace to deploy into |
| `certManager.issuerName` | `jupyter-k8s-selfsigned-issuer` | cert-manager Issuer name |
| `certManager.issuerKind` | `Issuer` | cert-manager issuer kind (`Issuer` or `ClusterIssuer`) |
| `serviceAccount.annotations` | `{}` | Annotations for the ServiceAccount |

### Deploying the Webhook

```sh
# Set environment
export AWS_ACCOUNT_ID=<your-account-id>
export AWS_REGION=us-west-2

# Create ECR repository
aws ecr create-repository --repository-name hyperpod-spaces-user-webhook --region $AWS_REGION

# Log into ECR
aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com

# Build and push the webhook image
docker build -t $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/hyperpod-spaces-user-webhook:latest .
docker push $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/hyperpod-spaces-user-webhook:latest

# Install via Helm
helm install hyperpod-spaces-user-webhook ./chart \
  --set image.repository=$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/hyperpod-spaces-user-webhook \
  --set image.tag=latest
```

---

## Custom Images (`smd-slurm-custom-image/`)

### Purpose

The custom images extend the official SageMaker Distribution base images with:

- Slurm client binaries (compiled from source) for submitting jobs to an HPC cluster
- MUNGE authentication daemon for Slurm's auth protocol
- SSSD integration for Active Directory / LDAP user authentication
- Proxy entrypoint scripts that set up the Linux user identity at container startup. They verify that `SPACES_WEBHOOK_USERNAME` is present, then extract and normalize the username (stripping any path prefix, lowercasing, and removing the `@domain` suffix), and use SSSD/NSS to resolve the user's UID, GID, and supplemental groups from the identity provider (Active Directory / LDAP). The home directory is derived from `USER_HOME_BASE` (hardcoded in `config.sh`).

### Image Variants

There are two Dockerfiles, identical in structure but using different base images:

| Dockerfile | Base Image | Use Case |
|------------|-----------|----------|
| `Dockerfile.cpu` | `public.ecr.aws/sagemaker/sagemaker-distribution:4.0.0-cpu` | CPU-only workspaces |
| `Dockerfile.gpu` | `public.ecr.aws/sagemaker/sagemaker-distribution:4.0.0-gpu` | GPU-enabled workspaces |

### Centralized Configuration (`config.sh`)

All configurable variables used across the build-time and runtime scripts are defined in a single file: `config.sh`. This file is copied into the image at `/usr/bin/config.sh` and sourced by every script at startup.

Runtime security-sensitive variables are **hardcoded** and cannot be overridden via environment variables. This prevents privilege escalation through env var injection in workspace specs. Only build-time variables (used during `docker build`, not at runtime) retain the `VAR="${VAR:-default}"` pattern and can be overridden via Dockerfile build args.

The configuration is organized into six sections:

#### 1. User home directory (hardcoded)

| Variable | Value | Description |
|----------|-------|-------------|
| `USER_HOME_BASE` | `/fsx` | Base path for user home directories. Proxy scripts derive `HOME_DIR` as `${USER_HOME_BASE}/<username>`. |

#### 2. Shared mount (hardcoded)

| Variable | Value | Description |
|----------|-------|-------------|
| `SLURM_SHARED_DIR` | `/fsx/.hyperpod_spaces_conf` | Directory where Slurm/SSSD config files are mounted into the container |

#### 3. Slurm — build-time (`install-slurm.sh`) — overridable via build args

| Variable | Default | Description |
|----------|---------|-------------|
| `SLURM_VERSION` | `24.11.0` | Slurm version to download and compile |
| `MUNGE_UID` | `991` | UID for the `munge` system user |
| `MUNGE_GID` | `991` | GID for the `munge` system group |
| `SLURM_UID` | `992` | UID for the `slurm` system user |
| `SLURM_GID` | `992` | GID for the `slurm` system group |

#### 4. Slurm — runtime (`configure-slurm.sh`) — hardcoded

| Variable | Value | Description |
|----------|-------|-------------|
| `SLURM_CONF_FILENAME` | `slurm.conf` | Slurm config filename inside the shared directory |
| `ACCOUNTING_CONF_FILENAME` | `accounting.conf` | Accounting config filename |
| `GRES_CONF_FILENAME` | `gres.conf` | GRES config filename |
| `MUNGE_KEY_FILENAME` | `munge.key` | MUNGE key filename |
| `MUNGE_SOCKET_TIMEOUT` | `5` | Seconds to wait for the MUNGE socket at startup |

#### 5. SSSD / LDAP (`configure-sssd.sh`) — hardcoded

| Variable | Value | Description |
|----------|-------|-------------|
| `SSSD_ENABLED` | `true` | Set to `true` to enable SSSD configuration |
| `SSSD_DOMAIN` | `default` | AD/LDAP domain name |
| `SSSD_LDAP_URI` | `ldaps://m-ad-bbd53aced45f300e.elb.us-west-2.amazonaws.com` | LDAP server URI |
| `SSSD_LDAP_SEARCH_BASE` | `dc=hyperpod,dc=gianpo,dc=local` | LDAP search base |
| `SSSD_LDAP_BIND_DN` | `CN=ReadOnly,OU=Users,OU=hyperpod,DC=hyperpod,DC=gianpo,DC=local` | Bind DN for LDAP queries |
| `SSSD_LDAP_AUTHTOK_TYPE` | `obfuscated_password` | Auth token type |
| `SSSD_LDAPS_CERT_PATH` | `${SLURM_SHARED_DIR}/ldaps.crt` | Path to LDAPS CA certificate |
| `SSSD_OVERRIDE_HOMEDIR` | `/fsx/%u` | Override home directory template |

> `SSSD_LDAP_AUTHTOK` is intentionally not defined in `config.sh` — it is a secret. At runtime, if unset, `configure-sssd.sh` reads it from `${SLURM_SHARED_DIR}/ldap_authtok`.

#### 6. Sudoers (`configure-sudoers.sh`) — hardcoded

| Variable | Value | Description |
|----------|-------|-------------|
| `SUDOERS_GROUPS` | `ClusterAdmin,Domain Admins` | Comma-separated list of groups to grant passwordless sudo |

### Shared Filesystem Prerequisites

The runtime scripts expect a shared filesystem (e.g. FSx for Lustre or FSx for OpenZFS) to be mounted into the container at the path defined by `SLURM_SHARED_DIR` (default: `/fsx/.hyperpod_spaces_conf`). The following files must be present in that directory before the container starts:

| File | Required by | Description |
|------|-------------|-------------|
| `slurm.conf` | `configure-slurm.sh` | Main Slurm configuration file from the cluster controller |
| `accounting.conf` | `configure-slurm.sh` | Slurm accounting configuration |
| `gres.conf` | `configure-slurm.sh` | Slurm generic resources (GPU, etc.) configuration |
| `munge.key` | `configure-slurm.sh` | Shared MUNGE authentication key (must match the controller's key) |
| `ldaps.crt` | `configure-sssd.sh` | LDAPS CA certificate for the Active Directory / LDAP server |
| `ldap_authtok` | `configure-sssd.sh` | LDAP bind password/token (only required if `SSSD_LDAP_AUTHTOK` env var is not set) |

The filenames for the Slurm files and the LDAPS certificate path are hardcoded in `config.sh`.

> The SSSD-related files (`ldaps.crt`, `ldap_authtok`) are only required when `SSSD_ENABLED` is set to `true` (the default). If SSSD is disabled, only the four Slurm files are needed.

The directory and all files within it must be owned by `root:root` with read permissions for others removed. This prevents unprivileged users from reading sensitive material such as the MUNGE key and LDAP credentials. The runtime scripts run as root (or via `sudo`) and can still access the files.

```sh
sudo chown -R root:root /fsx/.hyperpod_spaces_conf
sudo chmod 700 /fsx/.hyperpod_spaces_conf
sudo chmod 600 /fsx/.hyperpod_spaces_conf/*
```

Expected directory layout:

```
/fsx/.hyperpod_spaces_conf/       drwx------ root:root
├── slurm.conf                    -rw------- root:root
├── accounting.conf               -rw------- root:root
├── gres.conf                     -rw------- root:root
├── munge.key                     -rw------- root:root
├── ldaps.crt                     -rw------- root:root   # only when SSSD is enabled
└── ldap_authtok                  -rw------- root:root   # only when SSSD is enabled and SSSD_LDAP_AUTHTOK is not set
```

### Build Process

Both Dockerfiles follow the same steps:

1. Switch to `root` and install `gosu` (for privilege de-escalation at runtime).
2. Copy `config.sh` to `/usr/bin/config.sh` (available to all runtime scripts) and to `/tmp/config.sh` (for build-time scripts).
3. Copy and execute `install-slurm.sh` — the build-time script that:
   - Sources `config.sh` for `SLURM_VERSION`, UID/GID values, and `SLURM_CONF_DIR`
   - Installs build dependencies (`build-essential`, `munge`, `libmunge-dev`, `libssl-dev`, etc.)
   - Downloads Slurm source from SchedMD
   - Compiles Slurm from source with `./configure --prefix=/usr/local`
   - Creates `munge` and `slurm` system users with the configured UIDs/GIDs
   - Sets up directory structure: `/var/spool/slurm`, `/var/log/slurm`, `/etc/munge`, etc.
   - Cleans up build artifacts and apt caches
4. Copy and execute `install-sssd.sh` — installs SSSD and LDAP client packages.
5. Copy runtime scripts into `/usr/bin/`:
   - `configure-slurm.sh` — runtime Slurm/MUNGE initialization
   - `configure-sssd.sh` — runtime SSSD/LDAP configuration
   - `configure-user.sh` — creates local passwd/group entries from NSS/SSSD
   - `configure-sudoers.sh` — hardens sudoers and grants group-based sudo
   - `launcher.sh` — stops the root-owned remote access server and restarts it as the target user before exec'ing the runtime
   - `start-code-editor-proxy.sh` — Code Editor entrypoint
   - `start-jupyterlab-proxy.sh` — JupyterLab entrypoint

### Runtime Scripts

#### `configure-slurm.sh`

Called at container startup (by the proxy scripts) to initialize the Slurm client environment:

1. Sources `config.sh` for all Slurm-related variables.
2. Reads Slurm config files (`slurm.conf`, `accounting.conf`, `gres.conf`) and the MUNGE key from the shared mount at `SLURM_SHARED_DIR`.
3. Copies them into the expected system locations (`/usr/local/etc/`, `/etc/munge/`).
4. Starts the MUNGE daemon and waits for the socket to become available.
5. Exports `SLURM_CONF` and `MUNGE_KEY_PATH` environment variables.

This expects the Slurm controller's config files and MUNGE key to be available on a shared filesystem (e.g. FSx for Lustre/OpenZFS) mounted into the container.

#### `configure-sssd.sh`

Configures SSSD for Active Directory / LDAP authentication:

1. Sources `config.sh` for all SSSD/LDAP variables.
2. Skips entirely if `SSSD_ENABLED` is not `true`.
3. Installs the LDAPS certificate, writes `sssd.conf`, configures SSH, enables automatic home directory creation, and starts SSSD.

#### `configure-user.sh`

Ensures the user and group entries exist in local databases (`/etc/passwd`, `/etc/group`) so that statically compiled tools like `gosu` can resolve the user. Accepts the username as a positional argument (passed by the proxy entrypoint scripts after normalization) and resolves UID, GID, and supplemental groups from SSSD/NSS via the `id` command.

#### `configure-sudoers.sh`

Removes the blanket `NOPASSWD` rule and grants passwordless sudo to the groups listed in `SUDOERS_GROUPS` (sourced from `config.sh`).

#### `start-jupyterlab-proxy.sh` / `start-code-editor-proxy.sh`

These are the container entrypoints. They consume the webhook-injected environment variables to set up the user identity before launching the IDE:

1. Verify that `SPACES_WEBHOOK_USERNAME` is set and non-empty, refusing to start otherwise. Then extract the username after the last `/` (if present), lowercase it, and strip the `@domain` suffix. The home directory is derived from `USER_HOME_BASE` (hardcoded in `config.sh`).
2. Fix permissions on SageMaker-specific directories.
3. Run `configure-sssd.sh` to set up LDAP authentication.
4. Run `configure-user.sh <username>` to create local passwd/group entries (UID/GID/groups resolved via SSSD/NSS).
5. Run `configure-sudoers.sh` to configure sudo access.
6. Run `configure-slurm.sh` to initialize the Slurm client.
7. Hand off to `launcher.sh`, which restarts the remote access server as the target user and then exec's the IDE runtime (see below).

#### `launcher.sh`

A wrapper script invoked by the proxy entrypoints after all configuration is complete. It takes a username and a runtime command as arguments and performs three steps:

1. Stops the remote access server if it is currently running as root. It first checks for a supervisord socket and attempts a clean stop via `supervisorctl`. Then it uses `pkill` (escalating to `kill -9` if needed) to ensure the process is fully terminated.
2. Fixes permissions on `/var/log/studio/remoteAccess` (if the directory exists) so the non-root user can write logs, then starts the remote access server as the target user via `su`. The server runs in the background on the port defined by `REMOTE_ACCESS_SERVER_PORT` (default `2222`).
3. Exec's into the runtime command (JupyterLab or Code Editor) as the target user via `gosu`, replacing the current process.

This ensures the remote access server runs under the correct user identity rather than root, matching the privilege level of the IDE session.

### Building the Custom Images

```sh
export AWS_ACCOUNT_ID=<your-account-id>
export AWS_REGION=us-west-2
export SMD_SLURM_IMAGE_TAG=0.1.0

# Create ECR repository
aws ecr create-repository --repository-name smd-slurm --region $AWS_REGION

# Log into ECR (skip if already logged in from webhook build)
aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com

# CPU variant
docker build -t $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/smd-slurm:${SMD_SLURM_IMAGE_TAG}-cpu \
  -f smd-slurm-custom-image/Dockerfile.cpu smd-slurm-custom-image/
docker push $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/smd-slurm:${SMD_SLURM_IMAGE_TAG}-cpu

# GPU variant
docker build -t $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/smd-slurm:${SMD_SLURM_IMAGE_TAG}-gpu \
  -f smd-slurm-custom-image/Dockerfile.gpu smd-slurm-custom-image/
docker push $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/smd-slurm:${SMD_SLURM_IMAGE_TAG}-gpu
```

---

## Creating the WorkspaceTemplate

After building and pushing the custom images, create the `WorkspaceTemplate` so users can launch workspaces with the Slurm-enabled image.

The template file at `workspace-templates/jupyterlab-smd-slurm-custom.yaml` uses three variables that need to be substituted before applying:

| Variable | Description | Example |
|----------|-------------|---------|
| `${AWS_ACCOUNT_ID}` | Your AWS account ID | `123456789012` |
| `${AWS_REGION}` | ECR region | `us-west-2` |
| `${SMD_SLURM_IMAGE_TAG}` | Custom Slurm image version tag | `0.1.0` |

Apply the template with `envsubst` (using the same `AWS_ACCOUNT_ID`, `AWS_REGION`, and `SMD_SLURM_IMAGE_TAG` variables from the image build step):

```sh
envsubst < workspace-templates/jupyterlab-smd-slurm-custom.yaml | kubectl apply -f -
```

This creates a WorkspaceTemplate named `jupyterlab-smd-slurm-custom` in the `jupyter-k8s-system` namespace. It:

- Allows both CPU (`smd-slurm:<tag>-cpu`) and GPU (`smd-slurm:<tag>-gpu`) image variants
- Defaults to the CPU image
- Sets the container command to `/usr/bin/start-jupyterlab-proxy.sh`, which handles user identity setup and Slurm configuration before launching JupyterLab
- Uses the `hyperpod-access-strategy` access strategy

To verify:

```sh
kubectl get workspacetemplate jupyterlab-smd-slurm-custom -n jupyter-k8s-system
```

For the Code Editor variant, apply the second template using the same variables:

```sh
envsubst < workspace-templates/code-editor-smd-slurm-custom.yaml | kubectl apply -f -
```

To verify:

```sh
kubectl get workspacetemplate code-editor-smd-slurm-custom -n jupyter-k8s-system
```

---

## Validating Admission Policies (`validating-admission-policies/`)

The project includes three Kubernetes `ValidatingAdmissionPolicy` resources (requires Kubernetes 1.30+) that enforce workspace integrity without requiring the webhook to handle validation. Each policy lives in its own subdirectory with the standard three-file structure (`policy.yaml`, `binding.yaml`, `params.yaml`).

### Protected PVC (`validating-admission-policies/protected-pvc/`)

Ensures only workspaces using approved templates can mount the protected FSx PVC.

| File | Resource | Purpose |
|------|----------|---------|
| `policy.yaml` | `ValidatingAdmissionPolicy` | CEL expression that checks if a workspace referencing the protected PVC has an allowed `workspace.jupyter.org/template-name` label |
| `binding.yaml` | `ValidatingAdmissionPolicyBinding` | Binds the policy with `Deny` action and references the parameter ConfigMap |
| `params.yaml` | `ConfigMap` | Configures the protected PVC name and the list of allowed template names |

To deploy:

```sh
kubectl apply -f validating-admission-policies/protected-pvc/
```

To change the protected PVC name or allowed templates, edit `protected-pvc/params.yaml` and re-apply.

### Command Integrity (`validating-admission-policies/command-integrity/`)

Ensures the container command in a workspace has not been altered from the template default. When a workspace references one of the configured templates, the policy checks that at least one element in `spec.containerConfig.command` contains the required script path stored in the parameter ConfigMap. This prevents users from bypassing the proxy entrypoint scripts that handle user identity setup, Slurm configuration, and privilege de-escalation.

| File | Resource | Purpose |
|------|----------|---------|
| `policy.yaml` | `ValidatingAdmissionPolicy` | CEL expression that validates the workspace command contains the expected script for the template |
| `binding.yaml` | `ValidatingAdmissionPolicyBinding` | Binds the policy with `Deny` action and references the parameter ConfigMap |
| `params.yaml` | `ConfigMap` | Maps each template name to the required substring that must appear in the container command (e.g. `exec /usr/bin/start-jupyterlab-proxy.sh`) |

To deploy:

```sh
kubectl apply -f validating-admission-policies/command-integrity/
```

To add a new template or update an expected command, edit `command-integrity/params.yaml`. Each key is a template name and the value is the required script path that must appear in at least one element of the command array.

### Environment Variable Protection (`validating-admission-policies/env-protection/`)

Prevents users from setting security-sensitive environment variables in their workspace specs when the workspace uses one of the configured templates. This blocks privilege escalation via env var injection (e.g. overriding `SUDOERS_GROUPS` or `USER_HOME_BASE`). Note that `SPACES_WEBHOOK_USERNAME` is intentionally not in this list — the mutating webhook already strips any user-supplied value and re-injects the authenticated username, so the webhook alone is sufficient protection for that variable.

The policy is scoped to specific templates: it first checks whether the workspace's `workspace.jupyter.org/template-name` label matches one of the template names listed in the `allowedTemplates` parameter. If the template is not in the list (or the label is missing), the policy allows the request. For matching templates, it then checks whether any env var in `spec.env` appears in the protected list and denies the request if so.

| File | Resource | Purpose |
|------|----------|---------|
| `policy.yaml` | `ValidatingAdmissionPolicy` | CEL expression that, for workspaces using a configured template, checks if any env var in `spec.env` matches the protected list |
| `binding.yaml` | `ValidatingAdmissionPolicyBinding` | Binds the policy with `Deny` action and references the parameter ConfigMap |
| `params.yaml` | `ConfigMap` | Contains `allowedTemplates` (newline-separated list of template names the policy applies to) and `protectedEnvVars` (newline-separated list of protected environment variable names) |

To deploy:

```sh
kubectl apply -f validating-admission-policies/env-protection/
```

To add or remove protected variables or change which templates the policy applies to, edit `env-protection/params.yaml` and re-apply.

### Deploying All Policies

To deploy all three policies at once:

```sh
kubectl apply -R -f validating-admission-policies/
```

---

## How It All Fits Together

```
User creates Workspace
        │
        ▼
K8s API Server
  ├─► ValidatingAdmissionPolicy — Protected PVC (CEL)
  │     └─ If workspace uses protected FSx PVC, validates template-name label
  │         └─ Denies if template not in allowed list (see validating-admission-policies/protected-pvc/)
  │
  ├─► ValidatingAdmissionPolicy — Command Integrity (CEL)
  │     └─ If workspace uses a configured template, validates container command
  │         └─ Denies if command does not contain the required script (see validating-admission-policies/command-integrity/)
  │
  ├─► ValidatingAdmissionPolicy — Env Protection (CEL)
  │     └─ If workspace uses a configured template, checks spec.env for security-sensitive variable names
  │         └─ Denies if any protected env var is set by the user (see validating-admission-policies/env-protection/)
  │
  └─► MutatingWebhookConfiguration
        │
        ▼
hyperpod-spaces-user-webhook /mutate
  ├─ Strips any user-supplied SPACES_WEBHOOK_USERNAME from existing env vars
  └─ Returns JSON Patch adding SPACES_WEBHOOK_USERNAME env var (raw username from AdmissionReview)
        │
        ▼
Workspace Pod starts with custom image
  ├─ Proxy script verifies SPACES_WEBHOOK_USERNAME is set (refuses to start if missing)
  ├─ All scripts source /usr/bin/config.sh (hardcoded security-sensitive values)
  ├─ Proxy script normalizes SPACES_WEBHOOK_USERNAME (strip prefix, lowercase, remove @domain)
  │   and derives home from USER_HOME_BASE
  ├─ configure-sssd.sh sets up LDAP authentication
  ├─ configure-user.sh receives the normalized username as an argument,
  │   resolves UID/GID/groups via SSSD/NSS, and creates local entries
  ├─ configure-sudoers.sh grants group-based sudo access
  ├─ configure-slurm.sh copies config from shared mount, starts MUNGE
  └─ launcher.sh stops root-owned remote access server, restarts it as
      the target user, then exec's gosu → launches JupyterLab or Code Editor
```
