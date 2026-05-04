# Example `.hyperpod_spaces_conf` Directory

This directory contains **example files only**. They are provided to illustrate
the expected layout and format of the `.hyperpod_spaces_conf` directory that
must exist on the shared filesystem at runtime.

**Do not deploy these files as-is.** They contain placeholder values and dummy
secrets. In a real cluster, these files are generated from your actual Slurm
controller configuration, MUNGE key, and Active Directory / LDAP setup.

At runtime, the container expects this directory at:

```
${USER_HOME_BASE}/.hyperpod_spaces_conf/    (default: /home/.hyperpod_spaces_conf/)
```

## Required Files

All deployments need the four Slurm files:

| File | Description |
|------|-------------|
| `slurm.conf` | Main Slurm configuration (copy from your controller) |
| `accounting.conf` | Slurm accounting configuration |
| `gres.conf` | Generic resources (GPU) configuration |
| `munge.key` | Shared MUNGE authentication key (must match the controller) |

## Identity Provider Files

Depending on the `IDENTITY_PROVIDER` setting in `config.sh`:

### When `IDENTITY_PROVIDER=sssd` (default)

| File | Description |
|------|-------------|
| `ldaps.crt` | LDAPS CA certificate for the AD/LDAP server |
| `ldap_authtok` | LDAP bind password (only if `SSSD_LDAP_AUTHTOK` env var is not set) |

### When `IDENTITY_PROVIDER=file`

| File | Description |
|------|-------------|
| `users.jsonl` | JSON-Lines user database (see format below) |

## Ownership and Permissions

The directory and all files must be owned by `root:root` with restrictive
permissions:

```sh
sudo chown -R root:root /home/.hyperpod_spaces_conf
sudo chmod 700 /home/.hyperpod_spaces_conf
sudo chmod 600 /home/.hyperpod_spaces_conf/*
```
