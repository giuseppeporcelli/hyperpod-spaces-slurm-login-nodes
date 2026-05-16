# FSx for Lustre - Static Provisioning

This directory contains Kubernetes manifests to expose an existing FSx for Lustre filesystem as a PersistentVolumeClaim in any namespace using static provisioning.

## Prerequisites

- An existing FSx for Lustre filesystem
- The [FSx CSI driver](https://docs.aws.amazon.com/eks/latest/userguide/fsx-csi.html) installed on your cluster
- `envsubst` available locally (part of `gettext`)

## Files

| File | Description |
|------|-------------|
| `fsx-sc.yaml` | StorageClass with no dynamic provisioner |
| `fsx-pv.yaml` | PersistentVolume pointing to your FSx filesystem |
| `fsx-pvc.yaml` | PersistentVolumeClaim bound to the PV |

## Configuration

Gather the following values from your FSx filesystem:

| Variable | Description | Example |
|----------|-------------|---------|
| `NAMESPACE` | Target Kubernetes namespace | `hyperpod-ns-team-a` |
| `FSX_FILESYSTEM_ID` | FSx filesystem ID | `fs-XXXXXXXXXX` |
| `FSX_DNS_NAME` | FSx DNS name | `fs-XXXXXXXXXX.fsx.us-west-2.amazonaws.com` |
| `FSX_MOUNT_NAME` | FSx mount name | `k7f3mp9x` |

You can retrieve these from an existing PV:

```bash
kubectl get pv fsx-pv -o jsonpath='{.spec.csi.volumeHandle}'        # FSX_FILESYSTEM_ID
kubectl get pv fsx-pv -o jsonpath='{.spec.csi.volumeAttributes.dnsname}'   # FSX_DNS_NAME
kubectl get pv fsx-pv -o jsonpath='{.spec.csi.volumeAttributes.mountname}' # FSX_MOUNT_NAME
```

Or from the AWS CLI:

```bash
aws fsx describe-file-systems --file-system-ids fs-XXXXXXXXXX
```

## Deployment

1. Export the required variables:

```bash
export NAMESPACE=hyperpod-ns-team-a
export FSX_FILESYSTEM_ID=fs-XXXXXXXXXX
export FSX_DNS_NAME=fs-XXXXXXXXXX.fsx.us-west-2.amazonaws.com
export FSX_MOUNT_NAME=k7f3mp9x
```

2. Apply the manifests in order:

```bash
kubectl apply -f fsx/fsx-sc.yaml
envsubst < fsx/fsx-pv.yaml | kubectl apply -f -
envsubst < fsx/fsx-pvc.yaml | kubectl apply -f -
```

3. Verify the PVC is bound:

```bash
kubectl get pvc fsx-claim -n $NAMESPACE
```

## Multi-Namespace Usage

Each namespace requires its own PV/PVC pair. The PV name includes the namespace (`fsx-pv-$NAMESPACE`) to avoid conflicts. All PVs can point to the same underlying FSx filesystem since FSx for Lustre supports `ReadWriteMany` access.

Repeat the deployment steps above for each namespace, changing only the `NAMESPACE` variable.
