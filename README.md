# HyperPod Spaces as Slurm Login Nodes

## Overview

This project turns HyperPod Spaces workspaces into fully functional Slurm login nodes, letting users submit and manage HPC jobs directly from their JupyterLab or Code Editor environment. Each workspace is automatically configured with the correct Linux user identity and file system access so that Slurm commands (`srun`, `sbatch`, `squeue`, etc.) work seamlessly against the cluster.

To make this work, two pieces collaborate at runtime:

1. A `WorkspaceAccessStrategy` patch on the HyperPod Spaces platform injects the workspace creator's username into each pod as the `WORKSPACE_CREATOR_USERNAME` environment variable. The value is derived from the `workspace.jupyter.org/created-by` annotation, which is set by the platform itself and cannot be overridden by users. This is the mechanism that ties a workspace to a real user identity without requiring any manual configuration.
2. Custom SageMaker Distribution images (`smd-slurm-custom-image/`) extend the official base images with Slurm client tooling, MUNGE authentication, and pluggable identity resolution. At container startup, the injected username is used to resolve the user's UID, GID, and supplemental groups from the configured identity provider — either SSSD/NSS connected to Active Directory over LDAPS, or a root-owned JSON-Lines file on the shared filesystem — set up the home directory on the shared file system, initialize the Slurm client, and drop privileges to the correct user before launching the IDE.

The result is a workspace that behaves like an SSH session to a traditional Slurm login node: the user lands in their own home directory on the shared file system, has their correct group memberships, and can interact with the Slurm scheduler immediately.

---

## Username Injection via WorkspaceAccessStrategy

### How It Works

The platform's built-in `WorkspaceAccessStrategy` injects the creator's username into each workspace pod. The `mergeEnv` mechanism with a `valueTemplate` pulls the value from the `workspace.jupyter.org/created-by` annotation — a trusted, platform-set annotation that users cannot override.

### Applying the Patch

Run the following command to patch the existing `WorkspaceAccessStrategy`:

```sh
kubectl patch workspaceaccessstrategy hyperpod-access-strategy \
  -n jupyter-k8s-system \
  --type=json \
  -p '[{
    "op": "add",
    "path": "/spec/deploymentModifications/podModifications/primaryContainerModifications/mergeEnv/-",
    "value": {
      "name": "WORKSPACE_CREATOR_USERNAME",
      "valueTemplate": "{{ index .Workspace.Annotations \"workspace.jupyter.org/created-by\" }}"
    }
  }]'
```

This adds a `WORKSPACE_CREATOR_USERNAME` environment variable to every workspace pod created through the `hyperpod-access-strategy`. The value is resolved at pod creation time from the workspace's `created-by` annotation.

### Security Model

The `workspace.jupyter.org/created-by` annotation is set by the Jupyter workspace controller when the workspace is created. Users cannot modify it. The `ValidatingAdmissionPolicy` for environment variable protection (see [Env Protection](#environment-variable-protection-validating-admission-policiesenv-protection)) additionally blocks users from setting `WORKSPACE_CREATOR_USERNAME` in their workspace `spec.env`, providing defense-in-depth.

---

## Custom Images (`smd-slurm-custom-image/`)

### Purpose

The custom images extend the official SageMaker Distribution base images with:

- Slurm client binaries (compiled from source) for submitting jobs to an HPC cluster
- MUNGE authentication daemon for Slurm's auth protocol
- SSSD integration for Active Directory / LDAP user authentication
- Pluggable identity resolution (`resolve-user.sh`) supporting SSSD/NSS or a JSON-Lines user database file
- Proxy entrypoint scripts that set up the Linux user identity at container startup. They verify that `WORKSPACE_CREATOR_USERNAME` is present, then extract and normalize the username (stripping any path prefix, lowercasing, and removing the `@domain` suffix), and delegate identity resolution to `resolve-user.sh` which resolves the user's UID, GID, and supplemental groups from the configured provider. The home directory is derived from `USER_HOME_BASE` (hardcoded in `config.sh`).

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
| `USER_HOME_BASE` | `/home` | Base path for user home directories (where FSx for OpenZFS is typically mounted on HyperPod Slurm clusters). Proxy scripts derive `HOME_DIR` as `${USER_HOME_BASE}/<username>`. |

#### 2. Shared mount (hardcoded)

| Variable | Value | Description |
|----------|-------|-------------|
| `SLURM_SHARED_DIR` | `${USER_HOME_BASE}/.hyperpod_spaces_conf` | Directory where Slurm/SSSD config files are mounted into the container |

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

#### 5. Identity provider — hardcoded

| Variable | Value | Description |
|----------|-------|-------------|
| `IDENTITY_PROVIDER` | `sssd` | Controls how UID/GID/groups are resolved. `sssd` uses SSSD/NSS (requires AD/LDAP). `file` reads from a root-owned JSON-Lines file at `USER_DB_PATH`. |
| `USER_DB_PATH` | `${SLURM_SHARED_DIR}/users.jsonl` | Path to the JSON-Lines user database (only used when `IDENTITY_PROVIDER=file`) |

#### 5a. SSSD / LDAP (`configure-sssd.sh`) — hardcoded

These variables are only relevant when `IDENTITY_PROVIDER` is set to `sssd`.

| Variable | Value | Description |
|----------|-------|-------------|
| `SSSD_ENABLED` | `true` | Set to `true` to enable SSSD configuration |
| `SSSD_DOMAIN` | `default` | AD/LDAP domain name |
| `SSSD_LDAP_URI` | `ldaps://m-ad-bbd53aced45f300e.elb.us-west-2.amazonaws.com` | LDAP server URI |
| `SSSD_LDAP_SEARCH_BASE` | `dc=hyperpod,dc=gianpo,dc=local` | LDAP search base |
| `SSSD_LDAP_BIND_DN` | `CN=ReadOnly,OU=Users,OU=hyperpod,DC=hyperpod,DC=gianpo,DC=local` | Bind DN for LDAP queries |
| `SSSD_LDAP_AUTHTOK_TYPE` | `obfuscated_password` | Auth token type |
| `SSSD_LDAPS_CERT_PATH` | `${SLURM_SHARED_DIR}/ldaps.crt` | Path to LDAPS CA certificate |
| `SSSD_OVERRIDE_HOMEDIR` | `${USER_HOME_BASE}/%u` | Override home directory template |

> `SSSD_LDAP_AUTHTOK` is intentionally not defined in `config.sh` — it is a secret. At runtime, if unset, `configure-sssd.sh` reads it from `${SLURM_SHARED_DIR}/ldap_authtok`.

#### 6. Sudoers (`configure-sudoers.sh`) — hardcoded

| Variable | Value | Description |
|----------|-------|-------------|
| `SUDOERS_GROUPS` | `ClusterAdmin,Domain Admins` | Comma-separated list of groups to grant full (unrestricted) passwordless sudo |
| `SUDOERS_RESTRICTED_GROUPS` | `language,evaluation,multimodal` | Comma-separated list of groups to grant command-limited passwordless sudo |
| `SUDOERS_ALLOWED_COMMANDS` | *(see below)* | Newline-separated list of commands that restricted groups may run via sudo (standard sudoers `Cmnd` syntax, wildcards allowed) |

The allowed commands for restricted groups are:

```
/bin/systemctl restart|start|stop|status|reload *
/usr/bin/docker *
/usr/local/bin/docker-compose *
/sbin/fsck *
/usr/bin/tail|less|cat|head /var/log/*
/usr/bin/grep * /var/log/*
/usr/bin/nvidia-smi
/usr/bin/htop
/usr/bin/iotop
/usr/bin/apt * *
/bin/kill -[0-9]* [0-9]*
/usr/bin/pkill -f *
```

Each restricted group gets its own drop-in file under `/etc/sudoers.d/restricted-<group>` containing a `Cmnd_Alias` and a single rule that grants `NOPASSWD` access only to those commands. Groups in `SUDOERS_GROUPS` still receive full unrestricted sudo via separate drop-in files under `/etc/sudoers.d/group-<group>`.

### Shared Filesystem Prerequisites

The runtime scripts expect a shared filesystem (e.g. FSx for Lustre or FSx for OpenZFS) to be mounted into the container at the path defined by `SLURM_SHARED_DIR` (default: `${USER_HOME_BASE}/.hyperpod_spaces_conf`, i.e. `/home/.hyperpod_spaces_conf`). The following files must be present in that directory before the container starts:

| File | Required by | Description |
|------|-------------|-------------|
| `slurm.conf` | `configure-slurm.sh` | Main Slurm configuration file from the cluster controller |
| `accounting.conf` | `configure-slurm.sh` | Slurm accounting configuration |
| `gres.conf` | `configure-slurm.sh` | Slurm generic resources (GPU, etc.) configuration |
| `munge.key` | `configure-slurm.sh` | Shared MUNGE authentication key (must match the controller's key) |
| `ldaps.crt` | `configure-sssd.sh` | LDAPS CA certificate for the Active Directory / LDAP server |
| `ldap_authtok` | `configure-sssd.sh` | LDAP bind password/token (only required if `SSSD_LDAP_AUTHTOK` env var is not set) |
| `users.jsonl` | `resolve-user.sh` | JSON-Lines user database (only when `IDENTITY_PROVIDER=file`) |

The filenames for the Slurm files and the LDAPS certificate path are hardcoded in `config.sh`.

> When `IDENTITY_PROVIDER=sssd` (the default), the SSSD-related files (`ldaps.crt`, `ldap_authtok`) are required and `users.jsonl` is not needed. When `IDENTITY_PROVIDER=file`, only the four Slurm files and `users.jsonl` are needed — the SSSD files can be omitted.

An example directory with placeholder files is provided at [`example-hyperpod-spaces-conf/`](example-hyperpod-spaces-conf/) for reference.

The directory and all files within it must be owned by `root:root` with read permissions for others removed. This prevents unprivileged users from reading sensitive material such as the MUNGE key and LDAP credentials. The runtime scripts run as root (or via `sudo`) and can still access the files.

```sh
sudo chown -R root:root /home/.hyperpod_spaces_conf
sudo chmod 700 /home/.hyperpod_spaces_conf
sudo chmod 600 /home/.hyperpod_spaces_conf/*
```

Expected directory layout:

```
/home/.hyperpod_spaces_conf/      drwx------ root:root
├── slurm.conf                    -rw------- root:root
├── accounting.conf               -rw------- root:root
├── gres.conf                     -rw------- root:root
├── munge.key                     -rw------- root:root
├── ldaps.crt                     -rw------- root:root   # only when IDENTITY_PROVIDER=sssd
├── ldap_authtok                  -rw------- root:root   # only when IDENTITY_PROVIDER=sssd and SSSD_LDAP_AUTHTOK is not set
└── users.jsonl                   -rw------- root:root   # only when IDENTITY_PROVIDER=file
```

#### `users.jsonl` Format (file-based identity provider)

When `IDENTITY_PROVIDER=file`, user identity is resolved from a JSON-Lines file where each line is a self-contained JSON object describing one user:

```json
{"username":"alice","uid":10001,"gid":10001,"group":"alice","supplemental_groups":{"devs":10100,"docker":10200}}
{"username":"bob","uid":10002,"gid":10002,"group":"bob","supplemental_groups":{"devs":10100}}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `username` | string | yes | Login name (must match the normalized `WORKSPACE_CREATOR_USERNAME`) |
| `uid` | integer | yes | Numeric UID |
| `gid` | integer | yes | Numeric primary GID |
| `group` | string | no | Primary group name (defaults to `username` if omitted) |
| `supplemental_groups` | object | no | Map of group name → GID for supplemental group memberships |

The file must be owned by `root:root` with mode `0600`. `resolve-user.sh` validates ownership before reading and will refuse to proceed if the file is not root-owned.

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
   - `configure-user.sh` — creates local passwd/group entries using the pluggable identity resolver
   - `resolve-user.sh` — pluggable identity resolver (SSSD/NSS or JSON-Lines file)
   - `configure-sudoers.sh` — hardens sudoers and grants group-based sudo
   - `configure-ras.sh` — stops the root-owned remote access server and restarts it as the target user
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

#### `resolve-user.sh`

Pluggable identity resolver that abstracts how UID, GID, primary group, and supplemental groups are looked up for a given username. Controlled by `IDENTITY_PROVIDER` in `config.sh`:

- `sssd` — resolves via `id` and `getent` (requires SSSD/NSS to be running).
- `file` — parses the JSON-Lines file at `USER_DB_PATH` using `jq`. Validates that the file is owned by `root:root` before reading.

The script prints shell variable assignments to stdout (`RESOLVED_UID`, `RESOLVED_GID`, `RESOLVED_PRIMARY_GROUP`, `RESOLVED_SUPP_GIDS`, `RESOLVED_SUPP_GROUPS`) intended to be `eval`'d by the caller.

#### `configure-user.sh`

Ensures the user and group entries exist in local databases (`/etc/passwd`, `/etc/group`) so that statically compiled tools like `gosu` can resolve the user. Accepts the username as a positional argument (passed by the proxy entrypoint scripts after normalization) and delegates identity resolution to `resolve-user.sh`.

#### `configure-sudoers.sh`

Removes the blanket `NOPASSWD` rule and configures two tiers of sudo access (all sourced from `config.sh`):

1. Groups in `SUDOERS_GROUPS` receive full unrestricted passwordless sudo.
2. Groups in `SUDOERS_RESTRICTED_GROUPS` receive passwordless sudo limited to the commands defined in `SUDOERS_ALLOWED_COMMANDS`. A per-group `Cmnd_Alias` and sudoers drop-in file are generated under `/etc/sudoers.d/restricted-<group>`.

#### `start-jupyterlab-proxy.sh` / `start-code-editor-proxy.sh`

These are the container entrypoints. They consume the platform-injected environment variable to set up the user identity before launching the IDE:

1. Verify that `WORKSPACE_CREATOR_USERNAME` is set and non-empty, refusing to start otherwise. Then extract the username after the last `/` (if present), lowercase it, and strip the `@domain` suffix. The home directory is derived from `USER_HOME_BASE` (hardcoded in `config.sh`).
2. Fix permissions on SageMaker-specific directories.
3. Run `configure-sssd.sh` to set up LDAP authentication (skipped when `IDENTITY_PROVIDER` is not `sssd`).
4. Run `configure-user.sh <username>` to create local passwd/group entries (UID/GID/groups resolved via the configured identity provider).
5. Run `configure-sudoers.sh` to configure sudo access.
6. Run `configure-slurm.sh` to initialize the Slurm client.
7. Replace `/home/sagemaker-user` with a symlink to the user's home directory on the shared filesystem, then `cd` into it.
8. Run `configure-ras.sh` to stop the root-owned remote access server and restart it as the target user.
9. Exec into the IDE runtime via `gosu`, dropping privileges to the target user.

#### `configure-ras.sh`

Called by the proxy entrypoints after all other configuration is complete. It takes a username as its only argument and performs two steps:

1. Stops the remote access server if it is currently running as root. It first checks for a supervisord socket and attempts a clean stop via `supervisorctl`. Then it uses `pkill` (escalating to `kill -9` if needed) to ensure the process is fully terminated.
2. Fixes permissions on `/var/log/studio/remoteAccess` (if the directory exists) so the non-root user can write logs, then starts the remote access server as the target user via `su`. The server runs in the background on the port defined by `REMOTE_ACCESS_SERVER_PORT` (default `2222`).

After this script returns, the proxy entrypoints exec into the IDE runtime via `gosu`, dropping privileges to the target user.

### Building the Custom Images

```sh
export AWS_ACCOUNT_ID=<your-account-id>
export AWS_REGION=us-west-2
export SMD_SLURM_IMAGE_TAG=0.1.0

# Create ECR repository
aws ecr create-repository --repository-name smd-slurm --region $AWS_REGION

# Log into ECR
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

The project includes three Kubernetes `ValidatingAdmissionPolicy` resources (requires Kubernetes 1.30+) that enforce workspace integrity. Each policy lives in its own subdirectory with the standard three-file structure (`policy.yaml`, `binding.yaml`, `params.yaml`).

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

Prevents users from setting security-sensitive environment variables in their workspace specs when the workspace uses one of the configured templates. This blocks privilege escalation via env var injection (e.g. overriding `SUDOERS_GROUPS` or `USER_HOME_BASE`). `WORKSPACE_CREATOR_USERNAME` is included in the protected list — while the value is injected by the platform via `mergeEnv`/`valueTemplate` (not user-controllable through that path), this policy provides defense-in-depth by blocking any attempt to set it in `spec.env`.

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
  │         └─ Denies if template not in allowed list
  │
  ├─► ValidatingAdmissionPolicy — Command Integrity (CEL)
  │     └─ If workspace uses a configured template, validates container command
  │         └─ Denies if command does not contain the required script
  │
  └─► ValidatingAdmissionPolicy — Env Protection (CEL)
        └─ If workspace uses a configured template, checks spec.env for
           security-sensitive variable names (including WORKSPACE_CREATOR_USERNAME)
            └─ Denies if any protected env var is set by the user
        │
        ▼
WorkspaceAccessStrategy (hyperpod-access-strategy)
  └─ mergeEnv injects WORKSPACE_CREATOR_USERNAME from
     workspace.jupyter.org/created-by annotation
        │
        ▼
Workspace Pod starts with custom image
  ├─ Proxy script verifies WORKSPACE_CREATOR_USERNAME is set (refuses to start if missing)
  ├─ All scripts source /usr/bin/config.sh (hardcoded security-sensitive values)
  ├─ Proxy script normalizes WORKSPACE_CREATOR_USERNAME (strip prefix, lowercase, remove @domain)
  │   and derives home from USER_HOME_BASE
  ├─ configure-sssd.sh sets up LDAP authentication (skipped when IDENTITY_PROVIDER ≠ sssd)
  ├─ configure-user.sh receives the normalized username as an argument,
  │   delegates to resolve-user.sh (SSSD/NSS or JSONL file), and creates local entries
  ├─ configure-sudoers.sh grants group-based sudo access
  │   (full sudo for SUDOERS_GROUPS, command-limited for SUDOERS_RESTRICTED_GROUPS)
  ├─ configure-slurm.sh copies config from shared mount, starts MUNGE
  ├─ Proxy script symlinks /home/sagemaker-user → user home on shared FS
  ├─ configure-ras.sh stops root-owned remote access server,
  │   restarts it as the target user
  └─ Proxy script exec's gosu → launches JupyterLab or Code Editor
```
