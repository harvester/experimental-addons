# rancher-vcluster

Deploy Rancher management server using [vCluster](https://github.com/loft-sh/vcluster) on Harvester.

The addon creates a vCluster in the `rancher-vcluster` namespace, then bootstraps cert-manager and Rancher inside it using embedded `manifestsTemplate`. The vCluster syncs the Rancher ingress to the host cluster, making Rancher accessible at the configured hostname.

> **Warning**: This addon is experimental and not for production use.

## Requirements

- **Harvester v1.7.0+** (see [Harvester Compatibility](#harvester-compatibility) below)

## Configuration

Edit `rancher-vcluster.yaml` and set the `global.*` values under `valuesContent`:

```yaml
valuesContent: |-
  global:
    hostname: "rancher.example.com"       # Must resolve to Harvester VIP
    rancherVersion: v2.13.2               # Rancher chart version
    bootstrapPassword: "your-password"    # Initial admin password
```

These values are templated into the embedded `manifestsTemplate` via `{{ .Values.global.* }}`.

### Embedded Versions

| Component | Version | Notes |
|-----------|---------|-------|
| vCluster | v0.30.0 | Chart + syncer image |
| K3s | v1.34.2-k3s1 | Virtual cluster distro |
| cert-manager | v1.18.5 | Uses `crds.enabled` (not deprecated `installCRDs`) |
| Rancher | (from `global.rancherVersion`) | Default: v2.13.2 |

## Deployment

```bash
# 1. Edit rancher-vcluster.yaml — set hostname and bootstrapPassword

# 2. Apply the addon
kubectl apply -f rancher-vcluster.yaml

# 3. Enable the addon
kubectl patch addon rancher-vcluster -n rancher-vcluster \
  --type=merge -p '{"spec":{"enabled":true}}'

# 4. Monitor progress
kubectl get pods -n rancher-vcluster -w
```

Once the vCluster pod is running, the embedded HelmCharts install cert-manager and Rancher automatically. The Rancher ingress is synced to the host cluster.

## Harvester Compatibility

vCluster v0.30.0 requires **Harvester v1.7.0+**. Earlier Harvester versions have incompatibilities that prevent deployment:

### What changed in Harvester v1.7.0

| Change | v1.6.x behavior | v1.7.0+ behavior | Impact |
|--------|-----------------|-------------------|--------|
| Addon webhook validation | Required root-level `hostname:` in valuesContent ([#9447](https://github.com/harvester/harvester/pull/9447)) | Accepts `global.hostname` | Enables vCluster 0.20+ schema |
| Kubernetes version | K8s 1.30 | K8s 1.34 | Fixes CIDR detection (see below) |

### Why vCluster 0.19.x doesn't work on Harvester v1.6.x (K8s 1.33+)

vCluster 0.19.x auto-detects the host cluster's service CIDR by parsing Kubernetes error messages. K8s 1.33 changed the error message format ([loft-sh/vcluster#2834](https://github.com/loft-sh/vcluster/pull/2834)), causing vCluster to fall back to the wrong CIDR (10.96.0.0/12 instead of the host's actual CIDR). v0.19.x has no `serviceCIDR` config field to override this.

### Why vCluster 0.20+ doesn't work on Harvester v1.6.x

vCluster 0.20+ introduced `additionalProperties: false` in its Helm schema, rejecting unknown root-level keys. The Harvester v1.6.x addon webhook required `hostname:` at the root of valuesContent — this conflicts with vCluster's strict schema. The fix in [harvester/harvester#9447](https://github.com/harvester/harvester/pull/9447) updated the webhook to accept `global.hostname` instead.

### Version Compatibility Matrix

| Harvester | K8s | vCluster 0.19.x | vCluster 0.30.0 | Notes |
|-----------|-----|:---------------:|:---------------:|-------|
| v1.6.x | 1.30 | Partial | No | CIDR detection broken on K8s 1.33+ |
| v1.7.0+ | 1.34 | Not tested | **Yes** | Webhook updated for `global.*` format |

### Related Issues

- [harvester/harvester#9447](https://github.com/harvester/harvester/pull/9447) — Webhook validation updated for vCluster v0.30.0
- [harvester/harvester#9816](https://github.com/harvester/harvester/issues/9816) — FQDN validation failing on v1.7.0
- [harvester/harvester#9817](https://github.com/harvester/harvester/issues/9817) — Version field empty in addon UI
- [harvester/harvester#9796](https://github.com/harvester/harvester/issues/9796) — Outdated addon documentation
- [harvester/harvester#7284](https://github.com/harvester/harvester/issues/7284) — Addon upgrade path discussion
- [loft-sh/vcluster#2834](https://github.com/loft-sh/vcluster/pull/2834) — Service CIDR detection fix for K8s 1.33
- [loft-sh/vcluster#2732](https://github.com/loft-sh/vcluster/issues/2732) — serviceCIDR field missing in v0.20 refactor

## Upgrade Notes

### Upgrading from Harvester v1.6.x to v1.7.x

If you had rancher-vcluster running on Harvester v1.6.x:

1. The v1.6.x addon used root-level `hostname:` and `rancherVersion:` in valuesContent
2. The v1.7.0 addon uses `global.hostname`, `global.rancherVersion`, and `global.bootstrapPassword`
3. The embedded cert-manager was updated from v1.5.1 (`installCRDs`) to v1.18.5 (`crds.enabled`)
4. After upgrading Harvester, redeploy the addon with the new format

### Updating Rancher Version

Change `global.rancherVersion` in `valuesContent` and re-apply:

```bash
kubectl apply -f rancher-vcluster.yaml
```

The embedded HelmChart will detect the version change and upgrade Rancher in-place.

## Security Note

The Rancher deployed in vCluster can manage the underlying Harvester cluster, including provisioning downstream clusters. Running Rancher in a vCluster is **not as secure** as a separate VM-based install. A user with cluster-level or project admin access to the `rancher-vcluster` namespace will be able to access the Rancher instance.
