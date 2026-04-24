# Universal Rancher Backup and Restore

Full etcd-level backup and restore for Rancher using the
[rancher-backup operator](https://ranchermanager.docs.rancher.com/how-to-guides/new-user-guides/backup-restore-and-disaster-recovery).
Works with any Rancher cluster: k3k, RKE2, K3s, or Docker.

## Overview

| Feature | Legacy (`backup.sh`/`restore.sh`) | Universal (`rancher-backup.sh`/`rancher-restore.sh`) |
| ------- | --------------------------------- | --------------------------------------------------- |
| Backup scope | Config + API metadata | Full etcd-level (users, RBAC, fleet, tokens, etc.) |
| Cluster types | k3k only | Any Rancher cluster |
| Restore mode | Rebuild from config | True state restore |
| S3 storage | No | Yes |
| Encryption | No | Yes |
| Scheduled backups | No | Yes (cron) |
| Cross-cluster migration | No | Yes |

## Prerequisites

- `kubectl` configured to access the Rancher cluster (or k3k host cluster)
- `helm` v3.x
- `jq`
- S3-compatible storage (MinIO, AWS S3, etc.) for remote backups

## How It Works

The scripts install and manage the official
[rancher-backup](https://github.com/rancher/backup-restore-operator) Helm
chart, which provides `Backup` and `Restore` custom resources. The operator
performs an etcd-level snapshot of all Rancher-managed resources and stores
the tarball in S3 or the local PV.

For **k3k clusters**, the scripts automatically detect the virtual cluster,
extract its kubeconfig, and install the operator **inside** the vcluster
where Rancher runs. Host-cluster operations (TLS cert copy, ingress setup)
are handled separately.

## Quick Start

### Backup

```bash
./rancher-backup.sh \
    --s3-bucket rancher-backups \
    --s3-endpoint minio.example.com:9000 \
    --s3-access-key your-access-key \
    --s3-secret-key your-secret-key \
    --s3-insecure-tls
```

### Restore into existing Rancher (Mode A)

```bash
./rancher-restore.sh \
    --backup-file rancher-backup-20260217-143000.tar.gz \
    --s3-bucket rancher-backups \
    --s3-endpoint minio.example.com:9000 \
    --s3-access-key your-access-key \
    --s3-secret-key your-secret-key \
    --s3-insecure-tls
```

### Full deploy + restore (Mode B)

```bash
./rancher-restore.sh --deploy-rancher \
    --backup-file rancher-backup-20260217-143000.tar.gz \
    --hostname rancher.example.com \
    --bootstrap-pw admin1234567 \
    --s3-bucket rancher-backups \
    --s3-endpoint minio.example.com:9000 \
    --s3-access-key your-access-key \
    --s3-secret-key your-secret-key \
    --s3-insecure-tls
```

## Configuration

All options can be passed as CLI flags or loaded from a config file (`-c`).

### Config file example

```bash
# backup-restore.conf
S3_BUCKET="rancher-backups"
S3_ENDPOINT="minio.example.com:9000"
S3_ACCESS_KEY="your-access-key"
S3_SECRET_KEY="your-secret-key"
S3_INSECURE_TLS="true"
ENCRYPT="true"
ENCRYPTION_KEY="base64-encoded-32-byte-key"
```

```bash
./rancher-backup.sh -c backup-restore.conf
./rancher-restore.sh -c backup-restore.conf --backup-file <filename>
```

## rancher-backup.sh Reference

### Cluster access

| Flag | Description | Default |
| ---- | ----------- | ------- |
| `--kubeconfig <path>` | Path to kubeconfig file | (current context) |
| `--context <name>` | Kubernetes context | (current context) |
| `--namespace <ns>` | Operator namespace | `cattle-resources-system` |

### S3 storage

| Flag | Description | Default |
| ---- | ----------- | ------- |
| `--storage s3` | Storage type | (local if no S3 flags) |
| `--s3-bucket <name>` | Bucket name | (required for S3) |
| `--s3-endpoint <host:port>` | Endpoint URL | (AWS default) |
| `--s3-region <region>` | Region | (none) |
| `--s3-folder <path>` | Folder prefix | (none) |
| `--s3-access-key <key>` | Access key | (none) |
| `--s3-secret-key <key>` | Secret key | (none) |
| `--s3-insecure-tls` | Skip TLS verification | `false` |
| `--s3-endpoint-ca <path>` | CA cert for endpoint | (none) |

### Encryption

| Flag | Description | Default |
| ---- | ----------- | ------- |
| `--encrypt` | Enable encryption | (disabled) |
| `--encryption-secret <name>` | Secret name | `backup-encryption` |
| `--encryption-key <key>` | Base64-encoded 32-byte key | (required if encrypting) |

### Backup options

| Flag | Description | Default |
| ---- | ----------- | ------- |
| `--resource-set <name>` | ResourceSet name | `rancher-resource-set` |
| `--schedule <cron>` | Cron schedule for recurring backups | (one-time) |
| `--retention <count>` | Number of backups to retain | (unlimited) |
| `--backup-name <name>` | Custom backup name | `rancher-backup-<timestamp>` |

### Operator

| Flag | Description | Default |
| ---- | ----------- | ------- |
| `--skip-operator-install` | Don't install the operator | (installs) |
| `--operator-version <ver>` | Operator chart version | (latest) |

### Other

| Flag | Description | Default |
| ---- | ----------- | ------- |
| `--wait-timeout <seconds>` | Timeout for completion | `600` |
| `--output <path>` | Metadata sidecar export dir | (none) |
| `-c, --config <file>` | Load config file | (none) |
| `--dry-run` | Show CR without applying | (disabled) |

## rancher-restore.sh Reference

Accepts all the same cluster access, S3, and encryption flags as
`rancher-backup.sh`, plus:

### Restore source

| Flag | Description | Default |
| ---- | ----------- | ------- |
| `--backup-file <filename>` | Backup tarball filename | (required) |
| `--prune` | Delete resources not in backup | `false` |

### Deploy mode (Mode B)

| Flag | Description | Default |
| ---- | ----------- | ------- |
| `--deploy-rancher` | Enable full deploy mode | (disabled) |
| `--hostname <fqdn>` | Rancher hostname | (required in deploy mode) |
| `--bootstrap-pw <pw>` | Bootstrap password | (required in deploy mode) |
| `--tls-source <source>` | TLS source | `rancher` |
| `--certmanager-version <v>` | cert-manager version | `v1.18.5` |
| `--certmanager-repo <url>` | cert-manager repo | `https://charts.jetstack.io` |
| `--rancher-version <v>` | Rancher version | `v2.13.2` |
| `--rancher-repo <url>` | Rancher repo | `https://releases.rancher.com/server-charts/latest` |

### Target type

| Flag | Description | Default |
| ---- | ----------- | ------- |
| `--target-type <type>` | `k3k` or `standalone` | (auto-detect) |

### k3k-specific (deploy mode)

| Flag | Description | Default |
| ---- | ----------- | ------- |
| `--k3k-namespace <ns>` | k3k namespace | `rancher-k3k` |
| `--k3k-cluster <name>` | k3k cluster name | `rancher` |
| `--k3k-pvc-size <size>` | PVC size | `40Gi` |
| `--k3k-storage-class <sc>` | Storage class | `harvester-longhorn` |
| `--k3k-repo <url>` | k3k Helm repo | `https://rancher.github.io/k3k` |
| `--k3k-version <ver>` | k3k version | `1.0.2-rc2` |

## Workflow: Backup and Restore

### One-time backup

```bash
./rancher-backup.sh --s3-bucket my-bucket --s3-endpoint minio:9000 \
    --s3-access-key KEY --s3-secret-key SECRET --output ./backup-meta/
```

### Scheduled backup (daily at 2 AM, keep 7)

```bash
./rancher-backup.sh --s3-bucket my-bucket --s3-endpoint minio:9000 \
    --s3-access-key KEY --s3-secret-key SECRET \
    --schedule "0 2 * * *" --retention 7
```

### Disaster recovery (full rebuild)

```bash
# 1. Deploy fresh cluster infrastructure
# 2. Restore Rancher + state
./rancher-restore.sh --deploy-rancher \
    --hostname rancher.example.com --bootstrap-pw admin1234567 \
    --backup-file rancher-backup-20260217.tar.gz \
    --s3-bucket my-bucket --s3-endpoint minio:9000 \
    --s3-access-key KEY --s3-secret-key SECRET
```

### Cross-cluster migration

```bash
# Backup from source cluster
./rancher-backup.sh --kubeconfig source-kubeconfig.yaml \
    --s3-bucket my-bucket --s3-endpoint minio:9000 \
    --s3-access-key KEY --s3-secret-key SECRET

# Restore to target cluster
./rancher-restore.sh --kubeconfig target-kubeconfig.yaml --deploy-rancher \
    --hostname rancher.new-cluster.com --bootstrap-pw admin1234567 \
    --backup-file rancher-backup-20260217.tar.gz \
    --s3-bucket my-bucket --s3-endpoint minio:9000 \
    --s3-access-key KEY --s3-secret-key SECRET
```

## Encrypted Backups

Generate a 32-byte base64-encoded key:

```bash
openssl rand -base64 32
```

Backup with encryption:

```bash
./rancher-backup.sh --encrypt --encryption-key "$(openssl rand -base64 32)" \
    --s3-bucket my-bucket --s3-endpoint minio:9000 \
    --s3-access-key KEY --s3-secret-key SECRET
```

Restore requires the same key:

```bash
./rancher-restore.sh --encrypt --encryption-key "SAME-KEY-FROM-BACKUP" \
    --backup-file rancher-backup-20260217.tar.gz \
    --s3-bucket my-bucket --s3-endpoint minio:9000 \
    --s3-access-key KEY --s3-secret-key SECRET
```

## k3k Cluster Detection

The scripts auto-detect k3k clusters by checking for the `clusters.k3k.io`
CRD. When detected:

1. The k3k virtual cluster kubeconfig is extracted
2. The NodePort is resolved for external access
3. The rancher-backup operator is installed **inside** the vcluster
4. All backup/restore operations target the vcluster
5. In deploy mode, host-side resources (TLS cert, ingress) are set up
   after the restore completes

Override auto-detection with `--target-type k3k` or `--target-type standalone`.

## Dry Run

Both scripts support `--dry-run` to preview the generated CR without applying:

```bash
./rancher-backup.sh --dry-run --s3-bucket my-bucket \
    --s3-endpoint minio:9000 --s3-access-key KEY --s3-secret-key SECRET
```

## What Gets Backed Up

The rancher-backup operator captures all Rancher-managed resources:

- Users and authentication config
- RBAC (roles, role bindings, global permissions)
- Cluster registrations and settings
- Fleet bundles and GitRepos
- API tokens
- Cloud credentials
- Rancher settings (server-url, cacerts, etc.)
- Project and namespace configurations
- Catalogs and app configurations

## Limitations

- **Downstream cluster state** is not backed up (only registration metadata).
  Workloads on downstream clusters are unaffected by Rancher backup/restore.
- **Secrets** (cloud credentials, auth tokens) are included in the backup.
  Use `--encrypt` for sensitive environments.
- **Operator version compatibility**: The operator version should match the
  Rancher version. Restoring across major Rancher versions may not work.
- **PVC storage**: Local-PV backups are stored on the cluster node. For
  production use, always use S3.

## Troubleshooting

### Operator fails to install

Check Helm repo access:

```bash
helm search repo rancher-charts/rancher-backup
```

### Backup CR stuck in "InProgress"

Check operator logs:

```bash
kubectl logs -n cattle-resources-system deploy/rancher-backup
```

### Restore CR fails with "backup not found"

Verify the backup file exists in S3:

```bash
aws s3 ls s3://my-bucket/ --endpoint-url http://minio:9000
```

### k3k kubeconfig extraction fails

Verify the k3k cluster is running:

```bash
kubectl get clusters.k3k.io -A
kubectl get pods -n rancher-k3k
```
