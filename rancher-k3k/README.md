# rancher-k3k

Deploy Rancher management server using [k3k](https://github.com/rancher/k3k) (Kubernetes in Kubernetes) on Harvester.

> **Warning**: This addon is experimental and not for production use.

## Quick Start

```bash
./deploy.sh
```

The script prompts for hostname and password, then handles everything:
1. Installs k3k controller
2. Creates the virtual cluster (configurable storage)
3. Deploys cert-manager + Rancher inside it
4. Copies the TLS certificate to the host cluster
5. Creates the nginx ingress for external access
6. Deploys ingress reconciler (CronJob) and watcher (Deployment)
7. Merges kubeconfig with `~/.kube/config`

## Architecture

```
External Traffic
  → rancher.example.com (Harvester VIP)
    → nginx ingress (host cluster, rancher-k3k namespace)
      → rancher-k3k-traefik service → k3k server pod :443
        → Traefik (inside k3k virtual cluster)
          → Rancher (cattle-system namespace)
```

```
┌──────────────────────────────────────────────────────┐
│  Harvester Host Cluster                              │
│  ┌────────────────────────────────────────────────┐  │
│  │  k3k-system namespace                          │  │
│  │  └── k3k-controller                            │  │
│  ├────────────────────────────────────────────────┤  │
│  │  rancher-k3k namespace                         │  │
│  │  ├── k3k-rancher-server-0 (K3s virtual cluster)│  │
│  │  ├── rancher-k3k-traefik (svc → pod :443)      │  │
│  │  ├── rancher-k3k-ingress (nginx, with TLS)     │  │
│  │  └── tls-rancher-ingress (copied from k3k)     │  │
│  └────────────────────────────────────────────────┘  │
│                                                      │
│  Inside k3k virtual cluster:                         │
│    ├── cert-manager (3 pods)                         │
│    ├── Rancher (fleet disabled)                      │
│    └── Traefik ingress controller                    │
└──────────────────────────────────────────────────────┘
```

## TLS Certificate Flow

Harvester's nginx ingress does **not** have `--enable-ssl-passthrough`. The deploy
script works around this by:

1. Rancher generates a self-signed TLS cert (via dynamiclistener) with the correct SAN
2. The script copies this cert from inside the k3k cluster to the host cluster
3. The nginx ingress is configured to use this cert for TLS termination
4. Backend traffic to k3k Traefik uses `backend-protocol: HTTPS`

Without this, the cattle-cluster-agent gets: `x509: certificate is not valid for any names`

## Known Limitations

### No embedded manifest support

Unlike vCluster's `manifestsTemplate`, k3k does not support deploying manifests inside the virtual cluster at creation time. Rancher, cert-manager, and the host ingress must be deployed as separate post-install steps. This makes the deployment multi-step and harder to manage as a single Harvester addon.

### Host Ingress is not managed

The nginx Ingress resource that routes external traffic to the k3k cluster is manually applied and **not managed by any controller**. During Harvester upgrades, this Ingress can be deleted when:

- The `rke2-ingress-nginx` Helm chart upgrades (e.g., v4.12.600 → v4.13.400 during v1.6 → v1.7)
- Node drains cause the nginx DaemonSet to restart with a temporarily unavailable admission webhook ([harvester/harvester#7956](https://github.com/harvester/harvester/issues/7956))

After a Harvester upgrade, re-run `deploy.sh` or manually re-apply `host-ingress.yaml` to restore access.

### Flannel crash after pod reschedule

When `k3k-rancher-server-0` is evicted during a node drain and rescheduled to a different node, flannel's persisted network state in the PVC no longer matches the new pod IP, causing:

```
level=fatal msg="Failed to start networking: unable to initialize network policy controller:
  error getting node subnet: failed to find interface with specified node ip"
```

The pod enters CrashLoopBackOff until it is rescheduled back to a node with a matching IP or the PVC network state is cleared.

### Experimental status

k3k v1.0.2-rc2 is the minimum required version. The stable v1.0.2 release is pending.
v1.0.2 adds `secretMounts` ([PR #570](https://github.com/rancher/k3k/pull/570)) which is required
for private CA and container registry support.

## Known Issues

- [rancher/k3k#657](https://github.com/rancher/k3k/issues/657) — Pods exceeding 2GB ephemeral storage crash entire k3k server
- [rancher/k3k#495](https://github.com/rancher/k3k/issues/495) — Ingress permission regression since v0.3.5
- [rancher/k3k#590](https://github.com/rancher/k3k/issues/590) — Addons on shared mode stuck pending
- [rancher/k3k#591](https://github.com/rancher/k3k/issues/591) — k3k leaving finalizers on unrelated StatefulPods
- [harvester/harvester#7956](https://github.com/harvester/harvester/issues/7956) — Ingress-nginx admission webhook during upgrades
- [harvester/harvester#6360](https://github.com/harvester/harvester/issues/6360) — Dashboard 404 after upgrade (ingress-nginx changes)

## Manual Installation

If you prefer not to use the script:

### Step 1: Install k3k Controller

```bash
helm repo add k3k https://rancher.github.io/k3k
helm install k3k k3k/k3k --namespace k3k-system --create-namespace --version 1.0.2-rc2
kubectl wait --for=condition=available deploy/k3k -n k3k-system --timeout=120s
```

### Step 2: Create Virtual Cluster

```bash
kubectl apply -f rancher-cluster.yaml
# Wait for Ready status
kubectl get clusters.k3k.io rancher -n rancher-k3k -w
```

### Step 3: Extract and Fix Kubeconfig

```bash
# Extract kubeconfig (key is kubeconfig.yaml, not kubeconfig)
kubectl get secret k3k-rancher-kubeconfig -n rancher-k3k \
    -o jsonpath='{.data.kubeconfig\.yaml}' | base64 -d > k3k-kubeconfig.yaml

# The kubeconfig points to a ClusterIP — replace with NodePort
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
NODE_PORT=$(kubectl get svc k3k-rancher-service -n rancher-k3k \
    -o jsonpath='{.spec.ports[?(@.port==443)].nodePort}')

# Edit k3k-kubeconfig.yaml: change server to https://<NODE_IP>:<NODE_PORT>
```

### Step 4: Deploy cert-manager + Rancher

```bash
export KUBECONFIG=k3k-kubeconfig.yaml
kubectl --insecure-skip-tls-verify apply -f post-install/01-cert-manager.yaml

# Wait for cert-manager, then edit 02-rancher.yaml (set hostname + password)
kubectl --insecure-skip-tls-verify apply -f post-install/02-rancher.yaml
```

### Step 5: Copy TLS Certificate and Create Ingress

```bash
# Wait for Rancher to generate the TLS cert
kubectl --insecure-skip-tls-verify -n cattle-system get secret tls-rancher-ingress

# Extract and copy to host cluster
TLS_CRT=$(kubectl --insecure-skip-tls-verify -n cattle-system \
    get secret tls-rancher-ingress -o jsonpath='{.data.tls\.crt}' | base64 -d)
TLS_KEY=$(kubectl --insecure-skip-tls-verify -n cattle-system \
    get secret tls-rancher-ingress -o jsonpath='{.data.tls\.key}' | base64 -d)

unset KUBECONFIG
kubectl -n rancher-k3k create secret tls tls-rancher-ingress \
    --cert=<(echo "$TLS_CRT") --key=<(echo "$TLS_KEY")

# Apply ingress (replace __HOSTNAME__ with your hostname)
sed 's|__HOSTNAME__|rancher.example.com|g' host-ingress.yaml | kubectl apply -f -
```

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

## File Structure

```
rancher-k3k/
├── deploy.sh                # Automated 9-step deployment script
├── destroy.sh               # Teardown with monitoring and verification
├── lib.sh                   # Shared functions (sedi, OCI, auth injection)
├── terraform-setup.sh       # Terraform + kubeconfig setup (post-deploy)
├── test-private-repos.sh    # 63 tests for private repo support
├── k3k-controller.yaml      # Harvester addon CRD for k3k controller
├── rancher-cluster.yaml     # k3k Cluster CR (host cluster)
├── host-ingress.yaml        # Service + Ingress template (host cluster)
├── ingress-reconciler.yaml  # CronJob: restores ingress every 5 min
├── ingress-watcher.yaml     # Deployment: event-driven ingress recovery
├── restore-ingress.sh       # Standalone ingress restoration script
├── post-install/            # Manifests for inside the k3k cluster
│   ├── 01-cert-manager.yaml
│   └── 02-rancher.yaml
└── README.md
```

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
The script generates containerd mirror entries for three upstream registries:

| Upstream | Components | Harbor project needed |
|----------|-----------|----------------------|
| `docker.io` | K3s system images, Rancher, Fleet | `docker.io` |
| `quay.io` | cert-manager (jetstack) | `quay.io` |
| `ghcr.io` | CloudNativePG, Zalando postgres-operator | `ghcr.io` |

Each mirror uses a rewrite rule that routes through the matching Harbor proxy
cache project. For example, `quay.io/jetstack/cert-manager-controller:v1.18.5`
becomes `harbor.example.com/quay.io/jetstack/cert-manager-controller:v1.18.5`.

The script configures three layers of registry support:

1. **K3s containerd mirrors** (`spec.secretMounts`): A `registries.yaml` is
   generated and mounted into the k3k virtual cluster pod at
   `/etc/rancher/k3s/registries.yaml`. Containerd mirrors all three upstream
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

## Configuration

### rancher-cluster.yaml

| Field | Description | Default |
|-------|-------------|---------|
| `spec.mode` | "shared" or "virtual" | virtual |
| `spec.servers` | Control plane nodes | 1 |
| `spec.agents` | Worker nodes | 0 |
| `spec.persistence.storageRequestSize` | PVC size (must fit K3s + images) | 10Gi |
| `spec.persistence.storageClassName` | Storage class | harvester-longhorn |

### post-install/02-rancher.yaml

| Field | Description | Required |
|-------|-------------|----------|
| `hostname` | Rancher URL (must resolve to Harvester VIP) | Yes |
| `bootstrapPassword` | Initial admin password | Yes |
| `features` | Feature flags (`fleet=false` for North-South boundary) | No |

## Cleanup

```bash
./destroy.sh
```

Or manually:

```bash
# Remove host ingress and TLS secret
kubectl delete ingress rancher-k3k-ingress -n rancher-k3k
kubectl delete svc rancher-k3k-traefik -n rancher-k3k
kubectl delete secret tls-rancher-ingress -n rancher-k3k

# Delete the virtual cluster
kubectl delete clusters.k3k.io rancher -n rancher-k3k

# Uninstall k3k controller
helm uninstall k3k -n k3k-system

# Clean up namespaces
kubectl delete ns rancher-k3k k3k-system
```

## Changelog

### 2026-02-12: k3k v1.0.2-rc2 + private CA support

- **Bump k3k 1.0.1 → 1.0.2-rc2**: Required for `secretMounts` support
  ([PR #570](https://github.com/rancher/k3k/pull/570)). v1.0.1 does not have
  the `secretMounts` field in the Cluster CRD, causing `kubectl apply` to reject
  the manifest when a private registry is configured.
- **Private CA support**: The `secretMounts` field allows mounting `registries.yaml`
  and CA certificates directly into k3k server/agent pods at
  `/etc/rancher/k3s/registries.yaml` and `/etc/rancher/k3s/tls/ca.crt`. This
  enables containerd inside the virtual cluster to trust private CAs for image
  pulls from Harbor, Artifactory, or other internal registries.
- **Auth prompt UX**: Helm repo authentication is now gated behind a yes/no
  question (`Do your Helm repos require authentication?`). Public repos no
  longer show username/password prompts.
- **`role: all`**: Secret mounts now include `role: all` to ensure both server
  and agent pods receive the registry configuration.

## Troubleshooting

### Cluster not starting
```bash
kubectl logs -n k3k-system deployment/k3k
kubectl describe clusters.k3k.io rancher -n rancher-k3k
```

### Rancher image pull fails (no space)
The default 10Gi PVC should be sufficient. If not, delete the cluster,
increase `storageRequestSize` in rancher-cluster.yaml, and redeploy.

### x509 certificate error on cluster import
The TLS certificate was not copied from the k3k cluster to the host cluster.
Re-run the TLS copy step (Step 5 in manual installation, or re-run deploy.sh).

### cattle-cluster-agent can't reach Rancher
Verify DNS resolution and connectivity from within the host cluster:
```bash
kubectl run test --image=curlimages/curl --rm -it --restart=Never -- \
    curl -sk https://<hostname>/ping
```
