# rancher-k3k

[![ShellCheck](https://github.com/derhornspieler/rancher-k3k/actions/workflows/shellcheck.yaml/badge.svg)](https://github.com/derhornspieler/rancher-k3k/actions/workflows/shellcheck.yaml)
[![yamllint](https://github.com/derhornspieler/rancher-k3k/actions/workflows/yamllint.yaml/badge.svg)](https://github.com/derhornspieler/rancher-k3k/actions/workflows/yamllint.yaml)
[![Kubeconform](https://github.com/derhornspieler/rancher-k3k/actions/workflows/kubeconform.yaml/badge.svg)](https://github.com/derhornspieler/rancher-k3k/actions/workflows/kubeconform.yaml)
[![Gitleaks](https://github.com/derhornspieler/rancher-k3k/actions/workflows/gitleaks.yaml/badge.svg)](https://github.com/derhornspieler/rancher-k3k/actions/workflows/gitleaks.yaml)
[![markdownlint](https://github.com/derhornspieler/rancher-k3k/actions/workflows/markdownlint.yaml/badge.svg)](https://github.com/derhornspieler/rancher-k3k/actions/workflows/markdownlint.yaml)
[![actionlint](https://github.com/derhornspieler/rancher-k3k/actions/workflows/actionlint.yaml/badge.svg)](https://github.com/derhornspieler/rancher-k3k/actions/workflows/actionlint.yaml)

Deploy Rancher management server using [k3k](https://github.com/rancher/k3k) (Kubernetes in Kubernetes) on Harvester.

> **Warning**: This addon is experimental and not for production use.

## Quick Start

The deploy script supports two modes:

**Interactive** (prompts for all settings):

```bash
./deploy.sh
```

**Config file** (non-interactive, preferred for production):

```bash
./deploy.sh -c deploy.conf
```

Example `deploy.conf`:

```bash
HOSTNAME="rancher.example.com"
BOOTSTRAP_PW="admin1234567"
PVC_SIZE="40Gi"
STORAGE_CLASS="harvester-longhorn"
SERVER_COUNT=1
TLS_SOURCE="rancher"
PRIVATE_REGISTRY="harbor.example.com"
PRIVATE_CA_PATH="/path/to/ca.pem"
CONFIRM="yes"
```

The script handles everything end to end:

1. Installs k3k controller
2. Creates registry config secrets (if private registry configured)
3. Creates the virtual cluster (configurable storage, HA support)
4. Deploys cert-manager + Rancher inside it
5. Copies the TLS certificate to the host cluster
6. Creates the nginx ingress for external access
7. Deploys ingress reconciler (CronJob) and watcher (Deployment)
8. Merges kubeconfig with `~/.kube/config`

## Architecture

```text
External Traffic
  -> rancher.example.com (Harvester VIP)
    -> nginx ingress (host cluster, rancher-k3k namespace)
      -> rancher-k3k-traefik service -> k3k server pod :443
        -> Traefik (inside k3k virtual cluster)
          -> Rancher (cattle-system namespace)
```

```text
+------------------------------------------------------+
|  Harvester Host Cluster                              |
|  +------------------------------------------------+  |
|  |  k3k-system namespace                          |  |
|  |  +-- k3k-controller                            |  |
|  +------------------------------------------------+  |
|  |  rancher-k3k namespace                         |  |
|  |  +-- k3k-rancher-server-0 (K3s virtual cluster)|  |
|  |  +-- rancher-k3k-traefik (svc -> pod :443)     |  |
|  |  +-- rancher-k3k-ingress (nginx, with TLS)     |  |
|  |  +-- tls-rancher-ingress (copied from k3k)     |  |
|  +------------------------------------------------+  |
|                                                      |
|  Inside k3k virtual cluster:                         |
|    +-- cert-manager (3 pods)                         |
|    +-- Rancher (fleet disabled)                      |
|    +-- Traefik ingress controller                    |
+------------------------------------------------------+
```

## Configuration

All deployment settings are configured via `deploy.conf` or interactive prompts.
The YAML files in this repository are templates with `__PLACEHOLDER__` values
and should not be edited directly.

| Variable | Description | Default |
| -------- | ----------- | ------- |
| `HOSTNAME` | Rancher FQDN (must resolve to Harvester VIP) | (required) |
| `BOOTSTRAP_PW` | Initial admin password (min 12 chars) | `admin1234567` |
| `PVC_SIZE` | k3k virtual cluster storage | `50Gi` |
| `STORAGE_CLASS` | Kubernetes storage class | `harvester-longhorn` |
| `SERVER_COUNT` | Control plane nodes (1 or 3 for HA) | `1` |
| `TLS_SOURCE` | Certificate source: `rancher`, `letsEncrypt`, or `secret` | `rancher` |
| `PRIVATE_REGISTRY` | Container image proxy-cache host | (none) |
| `PRIVATE_CA_PATH` | PEM-encoded CA bundle for private TLS | (none) |
| `CERTMANAGER_VERSION` | cert-manager Helm chart version | `v1.18.5` |
| `RANCHER_VERSION` | Rancher Helm chart version | `v2.13.2` |
| `K3K_VERSION` | k3k Helm chart version | `1.0.2-rc2` |
| `HELM_AUTH_NEEDED` | Enable Helm repo authentication | `no` |
| `CONFIRM` | Skip confirmation prompt | (interactive) |

## TLS Certificate Flow

Harvester's nginx ingress does **not** have `--enable-ssl-passthrough`. The deploy
script works around this by:

1. Rancher generates a self-signed TLS cert (via dynamiclistener) with the correct SAN
2. The script copies this cert from inside the k3k cluster to the host cluster
3. The nginx ingress is configured to use this cert for TLS termination
4. Backend traffic to k3k Traefik uses `backend-protocol: HTTPS`

Without this, the cattle-cluster-agent gets: `x509: certificate is not valid for any names`

## Private Repositories

`deploy.sh` supports air-gapped and private environments where Helm charts and
container images come from internal registries (Harbor, Artifactory, Nexus, etc.).

### Helm Repository Authentication

When prompted, enter the username and password for your private Helm chart repo.
A single credential pair is used for all three repos (cert-manager, Rancher, k3k).
The password is read with hidden input.

The script propagates auth in two ways:

- **Host cluster**: `helm repo add` receives `--username`/`--password` flags
- **k3k cluster**: A `kubernetes.io/basic-auth` Secret (`helm-repo-auth`) is
  created in `kube-system`. The HelmChart CRs reference it via `spec.authSecret`.

### Private CA Certificate

If your repos or registries use TLS certificates signed by an internal CA,
provide the path to the PEM-encoded CA bundle when prompted.

The CA is propagated to:

- **Host cluster**: `helm repo add` and `helm install` receive `--ca-file`
- **k3k cluster (Rancher)**: A Secret (`tls-ca`) in `cattle-system` for
  Rancher's `privateCA` setting
- **k3k cluster (HelmChart CRs)**: A ConfigMap (`helm-repo-ca`) in
  `kube-system` referenced via `spec.repoCAConfigMap`

### Private Container Registry

> **Requires k3k >= v1.0.2-rc2.** The `secretMounts` field
> ([PR #570](https://github.com/rancher/k3k/pull/570)) is needed to mount
> `registries.yaml` and CA certificates into k3k server pods. v1.0.1 does not
> have this field and will reject the Cluster CR.

Enter the registry host (e.g. `harbor.example.com`) when prompted.
The script generates containerd mirror entries for six upstream registries:

| Upstream | Example usage | Harbor project |
| -------- | ------------- | -------------- |
| `docker.io` | K3s system images, Rancher, Fleet | `docker.io` |
| `quay.io` | cert-manager (Jetstack) | `quay.io` |
| `ghcr.io` | CloudNativePG, Zalando postgres-operator | `ghcr.io` |
| `registry.k8s.io` | CoreDNS, metrics-server, kube-proxy | `registry.k8s.io` |
| `gcr.io` | Various Google container images | `gcr.io` |
| `docker.elastic.co` | Elasticsearch, Kibana, Beats | `docker.elastic.co` |

Each mirror uses a rewrite rule that routes through the matching Harbor proxy
cache project. For example, `quay.io/jetstack/cert-manager-controller:v1.18.5`
becomes `harbor.example.com/quay.io/jetstack/cert-manager-controller:v1.18.5`.

The script configures three layers of registry support:

1. **K3s containerd mirrors** (`spec.secretMounts`): A `registries.yaml` is
   generated and mounted into the k3k virtual cluster pod at
   `/etc/rancher/k3s/registries.yaml`. Containerd mirrors all six upstream
   registries through your Harbor host, with optional TLS CA and auth.

2. **K3s system images** (`--system-default-registry`): Added to
   `spec.serverArgs` so K3s system components (CoreDNS, metrics-server, etc.)
   are pulled from `<host>/docker.io`.

3. **Rancher images** (`systemDefaultRegistry`): Set in the Rancher HelmChart
   CR so Rancher prepends `<host>/docker.io` to all its image references.

### Testing

Run the included test script to validate template processing:

```bash
# Tier 1: template validation (no cluster required)
./test-private-repos.sh

# Tier 2: local HTTPS server with auth (requires openssl + python3)
./test-private-repos.sh --full
```

## Backup and Restore

### Universal (recommended)

Full etcd-level backup/restore using the
[rancher-backup operator](https://ranchermanager.docs.rancher.com/how-to-guides/new-user-guides/backup-restore-and-disaster-recovery).
Preserves users, RBAC, fleet state, cluster registrations, settings, and tokens.
Works with any Rancher cluster (k3k, RKE2, K3s, Docker).

```bash
# Backup to S3
./rancher-backup.sh --s3-bucket my-bucket --s3-endpoint minio:9000 \
    --s3-access-key KEY --s3-secret-key SECRET

# Restore into existing Rancher
./rancher-restore.sh --backup-file rancher-backup-20260217.tar.gz \
    --s3-bucket my-bucket --s3-endpoint minio:9000 \
    --s3-access-key KEY --s3-secret-key SECRET

# Full deploy + restore (k3k)
./rancher-restore.sh --deploy-rancher --backup-file rancher-backup-20260217.tar.gz \
    --hostname rancher.example.com --bootstrap-pw admin1234567 \
    --s3-bucket my-bucket --s3-endpoint minio:9000 \
    --s3-access-key KEY --s3-secret-key SECRET
```

See [docs/universal-backup-restore.md](docs/universal-backup-restore.md) for the full guide.

### Legacy (k3k metadata rebuild)

The legacy scripts perform metadata-only backup (kubectl + API export) and
rebuild from config. They do **not** preserve Rancher internal state. Retained
for PVC resize workflows where a full rebuild is acceptable.

```bash
./backup.sh
./restore.sh --from ./backups/<timestamp>
./restore.sh --from ./backups/<timestamp> --pvc-size 20Gi
```

See [docs/backup-restore.md](docs/backup-restore.md) for the legacy guide.

## Terraform Setup

After deploying Rancher and completing the UI bootstrap:

```bash
./terraform-setup.sh
```

The script:

1. Extracts the k3k virtual cluster kubeconfig (`kubeconfig-k3k.yaml`)
2. Authenticates to the Rancher API and creates a persistent API token
3. Detects an imported Harvester cluster and generates its kubeconfig (`kubeconfig-harvester.yaml`)
4. Writes `terraform.tfvars` with Rancher API credentials

Use the output to configure the [Rancher2 Terraform provider](https://registry.terraform.io/providers/rancher/rancher2/latest):

```hcl
provider "rancher2" {
  api_url   = var.rancher_url    # https://rancher.example.com
  token_key = var.rancher_token  # from terraform.tfvars
  insecure  = true               # self-signed TLS
}
```

To provision RKE2 clusters on Harvester, create a cloud credential referencing the
generated Harvester kubeconfig:

```hcl
resource "rancher2_cloud_credential" "harvester" {
  name = "harvester"
  harvester_credential_config {
    cluster_id         = var.harvester_cluster_id
    cluster_type       = "imported"
    kubeconfig_content = file("kubeconfig-harvester.yaml")
  }
}
```

## Cleanup

```bash
./destroy.sh
```

## File Structure

```text
rancher-k3k/
├── deploy.sh                # Automated deployment script
├── destroy.sh               # Teardown with verification
├── rancher-backup.sh        # Universal backup (rancher-backup operator)
├── rancher-restore.sh       # Universal restore (data-only or full deploy)
├── backup-lib.sh            # Shared functions for universal backup/restore
├── backup.sh                # Legacy: k3k metadata backup (deprecated)
├── restore.sh               # Legacy: k3k metadata rebuild (deprecated)
├── lib.sh                   # Shared functions (OCI, auth, registry config)
├── terraform-setup.sh       # Post-deploy: API tokens + kubeconfigs
├── restore-ingress.sh       # Standalone ingress restoration
├── test-private-repos.sh    # Private registry test suite
├── deploy.conf              # Non-interactive deployment config
├── k3k-controller.yaml      # Harvester addon CRD for k3k controller
├── rancher-cluster.yaml     # k3k Cluster CR template (host cluster)
├── host-ingress.yaml        # Service + Ingress template (host cluster)
├── ingress-reconciler.yaml  # CronJob: ingress + flannel recovery
├── ingress-watcher.yaml     # Deployment: event-driven ingress recovery
├── post-install/            # HelmChart CR templates (k3k virtual cluster)
│   ├── 01-cert-manager.yaml
│   └── 02-rancher.yaml
├── templates/               # CR templates for rancher-backup operator
│   ├── backup-cr.yaml
│   ├── restore-cr.yaml
│   ├── s3-credentials.yaml
│   └── encryption-config.yaml
├── docs/                    # Operational documentation
│   ├── universal-backup-restore.md
│   ├── backup-restore.md
│   ├── certificate-change-recovery.md
│   └── multi-cluster-observability.md
├── test/                    # Test environment
│   ├── deploy-test.conf
│   ├── deploy-test.sh
│   └── destroy-test.sh
└── scripts/
    └── sync-to-public.sh    # Sync to public repo (scrubs private data)
```

## Known Limitations

### No embedded manifest support

Unlike vCluster's `manifestsTemplate`, k3k does not support deploying manifests inside the virtual cluster at creation time. Rancher, cert-manager, and the host ingress must be deployed as separate post-install steps. This makes the deployment multi-step and harder to manage as a single Harvester addon.

### Host Ingress is not managed

The nginx Ingress resource that routes external traffic to the k3k cluster is manually applied and **not managed by any controller**. During Harvester upgrades, this Ingress can be deleted when:

- The `rke2-ingress-nginx` Helm chart upgrades (e.g., v4.12.600 -> v4.13.400 during v1.6 -> v1.7)
- Node drains cause the nginx DaemonSet to restart with a temporarily unavailable admission webhook ([harvester/harvester#7956](https://github.com/harvester/harvester/issues/7956))

After a Harvester upgrade, re-run `deploy.sh` or manually re-apply `host-ingress.yaml` to restore access.

### Flannel crash after pod reschedule

When `k3k-rancher-server-0` is evicted during a node drain and rescheduled to a different node, flannel's persisted network state in the PVC no longer matches the new pod IP, causing:

```text
level=fatal msg="Failed to start networking: unable to initialize network policy controller:
  error getting node subnet: failed to find interface with specified node ip"
```

The pod enters CrashLoopBackOff until it is rescheduled back to a node with a matching IP or the PVC network state is cleared.

### Experimental status

k3k v1.0.2-rc2 is the minimum required version. The stable v1.0.2 release is pending.
v1.0.2 adds `secretMounts` ([PR #570](https://github.com/rancher/k3k/pull/570)) which is required
for private CA and container registry support.

## Known Issues

- [rancher/k3k#657](https://github.com/rancher/k3k/issues/657) -- Pods exceeding 2GB ephemeral storage crash entire k3k server
- [rancher/k3k#495](https://github.com/rancher/k3k/issues/495) -- Ingress permission regression since v0.3.5
- [rancher/k3k#590](https://github.com/rancher/k3k/issues/590) -- Addons on shared mode stuck pending
- [rancher/k3k#591](https://github.com/rancher/k3k/issues/591) -- k3k leaving finalizers on unrelated StatefulPods
- [harvester/harvester#7956](https://github.com/harvester/harvester/issues/7956) -- Ingress-nginx admission webhook during upgrades
- [harvester/harvester#6360](https://github.com/harvester/harvester/issues/6360) -- Dashboard 404 after upgrade (ingress-nginx changes)

## Troubleshooting

### Cluster not starting

```bash
kubectl logs -n k3k-system deployment/k3k
kubectl describe clusters.k3k.io rancher -n rancher-k3k
```

### Rancher image pull fails (no space)

The default 50Gi PVC should be sufficient. If not, back up the cluster with
`./backup.sh`, then restore with a larger PVC:

```bash
./restore.sh --from ./backups/<timestamp> --pvc-size 80Gi
```

### x509 certificate error on cluster import

The TLS certificate was not copied from the k3k cluster to the host cluster.
Re-run `deploy.sh` to restore the certificate and ingress.

### cattle-cluster-agent can't reach Rancher

Verify DNS resolution and connectivity from within the host cluster:

```bash
kubectl run test --image=curlimages/curl --rm -it --restart=Never -- \
    curl -sk https://<hostname>/ping
```
