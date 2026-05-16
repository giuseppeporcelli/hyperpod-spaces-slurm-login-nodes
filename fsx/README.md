# FSx Storage — Static Provisioning

This directory contains Kubernetes manifests to expose two FSx filesystems as PersistentVolumeClaims using static provisioning:

| Filesystem | Purpose | Mount Path | Use Case |
|-----------|---------|------------|----------|
| FSx for OpenZFS | User home directories + `.hyperpod_spaces_conf` | `/home` | Low-latency NFS, ideal for small files, configs, notebooks |
| FSx for Lustre | Shared ML data storage | `/fsx` | High-throughput parallel filesystem for datasets, checkpoints, model artifacts |

## Prerequisites

- An existing FSx for OpenZFS filesystem (for home directories)
- An existing FSx for Lustre filesystem (for shared ML data)
- The [FSx for Lustre CSI driver](https://docs.aws.amazon.com/eks/latest/userguide/fsx-csi.html) installed on your cluster
- The [FSx for OpenZFS CSI driver](https://docs.aws.amazon.com/eks/latest/userguide/fsx-openzfs-csi.html) installed on your cluster
- `envsubst` available locally (part of `gettext`)

## Files

| File | Description |
|------|-------------|
| `openzfs-sc.yaml` | StorageClass for FSx for OpenZFS (no dynamic provisioner) |
| `openzfs-pv.yaml` | PersistentVolume pointing to your OpenZFS filesystem |
| `openzfs-pvc.yaml` | PersistentVolumeClaim for OpenZFS bound to the PV |
| `lustre-sc.yaml` | StorageClass for FSx for Lustre (no dynamic provisioner) |
| `lustre-pv.yaml` | PersistentVolume pointing to your Lustre filesystem |
| `lustre-pvc.yaml` | PersistentVolumeClaim for Lustre bound to the PV |

## Configuration

### FSx for OpenZFS variables

| Variable | Description | Example |
|----------|-------------|---------|
| `NAMESPACE` | Target Kubernetes namespace | `hyperpod-ns-team-a` |
| `FSX_OPENZFS_VOLUME_ID` | OpenZFS volume ID | `fsvol-XXXXXXXXXXXXXXXXX` |
| `FSX_OPENZFS_DNS_NAME` | OpenZFS filesystem DNS name | `fs-XXXXXXXXXX.fsx.us-west-2.amazonaws.com` |
| `FSX_OPENZFS_MOUNT_NAME` | OpenZFS volume path | `/fsx/home` |
| `FSX_OPENZFS_STORAGE_CAPACITY` | Storage capacity for the PV/PVC | `512Gi` |

### FSx for Lustre variables

| Variable | Description | Example |
|----------|-------------|---------|
| `NAMESPACE` | Target Kubernetes namespace | `hyperpod-ns-team-a` |
| `FSX_LUSTRE_FILESYSTEM_ID` | Lustre filesystem ID | `fs-XXXXXXXXXX` |
| `FSX_LUSTRE_DNS_NAME` | Lustre DNS name | `fs-XXXXXXXXXX.fsx.us-west-2.amazonaws.com` |
| `FSX_LUSTRE_MOUNT_NAME` | Lustre mount name | `k7f3mp9x` |
| `FSX_LUSTRE_STORAGE_CAPACITY` | Storage capacity for the PV/PVC | `1200Gi` |

You can retrieve Lustre values from an existing PV:

```bash
kubectl get pv fsx-lustre-pv -o jsonpath='{.spec.csi.volumeHandle}'              # FSX_LUSTRE_FILESYSTEM_ID
kubectl get pv fsx-lustre-pv -o jsonpath='{.spec.csi.volumeAttributes.dnsname}'   # FSX_LUSTRE_DNS_NAME
kubectl get pv fsx-lustre-pv -o jsonpath='{.spec.csi.volumeAttributes.mountname}' # FSX_LUSTRE_MOUNT_NAME
```

Or from the AWS CLI:

```bash
aws fsx describe-file-systems --file-system-ids fs-XXXXXXXXXX
aws fsx describe-volumes --volume-ids fsvol-XXXXXXXXXXXXXXXXX
```

## Deployment

1. Export the required variables:

```bash
export NAMESPACE=hyperpod-ns-team-a

# OpenZFS (home directories)
export FSX_OPENZFS_VOLUME_ID=fsvol-XXXXXXXXXXXXXXXXX
export FSX_OPENZFS_DNS_NAME=fs-XXXXXXXXXX.fsx.us-west-2.amazonaws.com
export FSX_OPENZFS_MOUNT_NAME=/fsx/home
export FSX_OPENZFS_STORAGE_CAPACITY=512Gi

# Lustre (shared ML data)
export FSX_LUSTRE_FILESYSTEM_ID=fs-XXXXXXXXXX
export FSX_LUSTRE_DNS_NAME=fs-XXXXXXXXXX.fsx.us-west-2.amazonaws.com
export FSX_LUSTRE_MOUNT_NAME=k7f3mp9x
export FSX_LUSTRE_STORAGE_CAPACITY=1200Gi
```

2. Apply the StorageClasses (once per cluster):

```bash
kubectl apply -f fsx/openzfs-sc.yaml
kubectl apply -f fsx/lustre-sc.yaml
```

3. Apply the PV/PVC pairs (per namespace):

```bash
# OpenZFS
envsubst < fsx/openzfs-pv.yaml | kubectl apply -f -
envsubst < fsx/openzfs-pvc.yaml | kubectl apply -f -

# Lustre
envsubst < fsx/lustre-pv.yaml | kubectl apply -f -
envsubst < fsx/lustre-pvc.yaml | kubectl apply -f -
```

4. Verify the PVCs are bound:

```bash
kubectl get pvc fsx-openzfs-claim fsx-lustre-claim -n $NAMESPACE
```

## Multi-Namespace Usage

Each namespace requires its own PV/PVC pairs. The PV names include the namespace
(`fsx-openzfs-pv-$NAMESPACE`, `fsx-lustre-pv-$NAMESPACE`) to avoid conflicts.
All PVs can point to the same underlying filesystems since both FSx for OpenZFS
and FSx for Lustre support `ReadWriteMany` access.

Repeat the deployment steps above for each namespace, changing only the
`NAMESPACE` variable.

## How the Volumes Are Used

The workspace templates mount both volumes:

- `/home` (OpenZFS) — User home directories live here. The runtime scripts
  derive `HOME_DIR` as `/home/<username>` and the `.hyperpod_spaces_conf`
  directory with Slurm/SSSD configuration also resides here.
- `/fsx` (Lustre) — High-throughput shared storage for ML workloads. Users
  can store training datasets, model checkpoints, and experiment artifacts
  here. The parallel filesystem architecture makes it well-suited for large
  sequential reads/writes typical of distributed training.
