# SOP: Recovering Downstream Clusters After a Certificate Change and Restore

When the Rancher vcluster TLS certificate changes (e.g., from self-signed
dynamiclistener to Vault-issued) and/or a backup/restore cycle is performed,
downstream cluster agents will fail to reconnect. This SOP documents the
full recovery procedure.

---

## TL;DR — Quick Fix Checklist

If you just need to get clusters reconnected NOW:

1. **Update `cacerts`** in Rancher with the new CA chain (Step 1)
2. **Compute the correct checksum** using the jq/file method (Step 2)
3. **Patch the agent deployment directly** on each disconnected cluster (Step 3)
4. **Patch `stv-aggregation` secret** on RKE2 clusters (Step 4)
5. **Delete failed system-agent-upgrader jobs** (Step 4)
6. **Accept that Rancher will fight you** — re-patch when needed (Step 5)

---

## Background

Rancher's `cattle-cluster-agent` on each downstream cluster verifies the
Rancher server TLS certificate using a CA bundle downloaded from the
`/v3/settings/cacerts` endpoint. The agent compares the SHA-256 hash of
that CA bundle against `CATTLE_CA_CHECKSUM` embedded in its deployment.

When the Rancher TLS certificate changes (new CA chain), the agents reject
the new certificate because:

1. The cached CA no longer matches the server certificate.
2. The `CATTLE_CA_CHECKSUM` no longer matches the new CA bundle.

A restore compounds the problem because Rancher regenerates agent
deployments with a checksum computed differently from how the agent
verifies it (see Known Bugs below).

---

## Known Bug #1: Cluster Agent Checksum Mismatch

Rancher's Go code computes `CATTLE_CA_CHECKSUM` by hashing the raw
`cacerts` setting value (no trailing newline):

```bash
# What Rancher computes internally (equivalent):
curl -sk https://rancher.example.com/cacerts | sha256sum
# Example: 9cb34b49...
```

The cluster agent verifies by downloading via the JSON API and writing
with `jq`, which appends a trailing newline:

```bash
# What the agent does:
curl -sk https://rancher.example.com/v3/settings/cacerts | jq -r .value > /tmp/ca
sha256sum /tmp/ca
# Example: a204fbc2...
```

The 1-byte trailing newline difference produces different hashes.
**Rancher always pushes the wrong checksum to cluster agents.**

## Known Bug #2: System Agent Upgrader Checksum Mismatch

The `system-agent-upgrader` (SUC plan) uses the checksum from the
`stv-aggregation` secret in `cattle-system`. This secret is managed by
the cluster agent, which writes its own computed hash (the jq/file-based
one: `a204fbc2...`). But the system agent install script verifies using
the raw pipe method (`curl /cacerts | sha256sum` = `9cb34b49...`).

**Result**: The stv-aggregation secret has the wrong hash for the
install script. The system-agent-upgrader jobs fail on every node.

## Known Bug #3: agentEnvVars Creates Duplicate Keys

**DO NOT use `spec.agentEnvVars` to set `CATTLE_CA_CHECKSUM`.** Rancher's
agent deployment template already includes `CATTLE_CA_CHECKSUM` in its
env list. Adding it via `agentEnvVars` creates a SECOND entry with the
same key. Kubernetes rejects this with a strategic merge patch error:

```text
The order in patch list... doesn't match $setElementOrder list...
two entries with the same key "CATTLE_CA_CHECKSUM"
```

This makes the agent deployment completely unreconcilable. If you
accidentally set `agentEnvVars`, clear it immediately:

```bash
$K3K_CMD patch clusters.management.cattle.io <cluster-id> --type=merge \
  -p '{"spec": {"agentEnvVars": []}}'
```

## Summary of the Three Checksums

| Component | How it computes hash | Hash value | Source of expected hash |
|-----------|---------------------|------------|----------------------|
| Rancher server (Go) | `sha256(raw_string)` | `9cb34b49...` | Computes internally |
| Cluster agent (shell) | `jq -r .value > file && sha256sum file` | `a204fbc2...` | `CATTLE_CA_CHECKSUM` env var (from Rancher: `9cb34b49...`) |
| System agent install.sh | `curl /cacerts \| sha256sum` | `9cb34b49...` | `stv-aggregation` secret (from cluster agent: `a204fbc2...`) |

**No single hash value satisfies all three.** You must patch each
component with the hash that matches its OWN computation method.

---

## Prerequisites

- `kubectl` access to the Harvester host cluster
- `kubectl` access to the Rancher vcluster (via k3k kubeconfig)
- SSH access to downstream RKE2 cluster nodes (if agents are disconnected)
- The new CA chain in PEM format (intermediate + root)

---

## Step 1: Update Rancher cacerts Settings

After a certificate change, update the Rancher settings so the
`/v3/settings/cacerts` endpoint returns the new CA chain.

```bash
K3K_CMD="kubectl --kubeconfig=<k3k-kubeconfig> --insecure-skip-tls-verify"

# Build the CA chain (intermediate + root PEM concatenated)
CA_CHAIN=$(cat intermediate-ca.pem root-ca.pem)

# Update the cacerts setting
$K3K_CMD patch settings.management.cattle.io cacerts --type=merge \
  -p "{\"value\": $(echo "$CA_CHAIN" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}"

# Also update internal-cacerts (may get overwritten by dynamiclistener, but try)
$K3K_CMD patch settings.management.cattle.io internal-cacerts --type=merge \
  -p "{\"value\": $(echo "$CA_CHAIN" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}"
```

Verify:

```bash
curl -sk https://<rancher-url>/cacerts | openssl x509 -noout -subject -issuer
# Should show your new CA, not dynamiclistener-org
```

> **Note:** Rancher's dynamiclistener may overwrite `internal-cacerts`
> back to the self-signed CA. This is expected when `tls-source=rancher`.
> The `cacerts` setting (which agents use) persists correctly.

## Step 2: Compute Both Checksums

You need TWO different checksums:

```bash
# CHECKSUM A: For cluster agents (file-based, with jq trailing newline)
CLUSTER_AGENT_CHECKSUM=$(
  curl -sk https://<rancher-url>/v3/settings/cacerts \
    | jq -r .value > /tmp/cacerts-verify \
  && sha256sum /tmp/cacerts-verify | awk '{print $1}'
)
echo "Cluster agent checksum: $CLUSTER_AGENT_CHECKSUM"

# CHECKSUM B: For system-agent-upgrader (pipe-based, no trailing newline)
SYSTEM_AGENT_CHECKSUM=$(
  curl -sk https://<rancher-url>/cacerts | sha256sum | awk '{print $1}'
)
echo "System agent checksum: $SYSTEM_AGENT_CHECKSUM"
```

Save both values. You will use Checksum A for cluster agent deployments
and Checksum B for the stv-aggregation secret.

## Step 3: Patch Cluster Agent Deployments Directly

This is the primary fix. You must patch the `cattle-cluster-agent`
deployment on each downstream cluster to replace `CATTLE_CA_CHECKSUM`
with Checksum A (the file-based hash the agent actually computes).

### Harvester (Host Cluster)

You have direct `kubectl` access:

```bash
CORRECT_CHECKSUM="<checksum-A-from-step-2>"

kubectl patch deploy cattle-cluster-agent -n cattle-system --type=json \
  -p "[{
    \"op\": \"replace\",
    \"path\": \"/spec/template/spec/containers/0/env\",
    \"value\": $(
      kubectl get deploy cattle-cluster-agent -n cattle-system \
        -o jsonpath='{.spec.template.spec.containers[0].env}' \
      | python3 -c "
import json, sys
envs = json.load(sys.stdin)
for e in envs:
    if e['name'] == 'CATTLE_CA_CHECKSUM':
        e['value'] = '$CORRECT_CHECKSUM'
print(json.dumps(envs))
"
    )
  }]"
```

### RKE2 Clusters (via SSH)

When the agent is disconnected, Rancher's proxy kubeconfig
(`/k8s/clusters/<id>`) does not work. Use SSH to get a direct kubeconfig:

```bash
# SSH to any controlplane node
ssh -i <ssh-key> rocky@<controlplane-ip> \
  "sudo cat /etc/rancher/rke2/rke2.yaml" > /tmp/rke2-kubeconfig.yaml

# Fix the server address (defaults to 127.0.0.1)
sed -i 's|server: https://127.0.0.1:6443|server: https://<controlplane-ip>:6443|' \
  /tmp/rke2-kubeconfig.yaml

RKE2_CMD="kubectl --kubeconfig=/tmp/rke2-kubeconfig.yaml --insecure-skip-tls-verify"

# Verify access
$RKE2_CMD get nodes

# Apply the same patch as Harvester above
CORRECT_CHECKSUM="<checksum-A-from-step-2>"

$RKE2_CMD patch deploy cattle-cluster-agent -n cattle-system --type=json \
  -p "[{
    \"op\": \"replace\",
    \"path\": \"/spec/template/spec/containers/0/env\",
    \"value\": $(
      $RKE2_CMD get deploy cattle-cluster-agent -n cattle-system \
        -o jsonpath='{.spec.template.spec.containers[0].env}' \
      | python3 -c "
import json, sys
envs = json.load(sys.stdin)
for e in envs:
    if e['name'] == 'CATTLE_CA_CHECKSUM':
        e['value'] = '$CORRECT_CHECKSUM'
print(json.dumps(envs))
"
    )
  }]"
```

> **Tip:** Find RKE2 node IPs from Harvester:
> `kubectl get vmi -A | grep controlplane`

### Other Imported Clusters

For any cluster where you have direct `kubectl` access, apply the same
deployment patch. The pattern is always: replace `CATTLE_CA_CHECKSUM` in
the `cattle-cluster-agent` deployment in `cattle-system`.

## Step 4: Fix System Agent Upgrader Jobs (RKE2 Only)

After the cluster agent connects, it writes its checksum (Checksum A)
to the `stv-aggregation` secret. But the system-agent-upgrader install
script expects Checksum B (pipe-based). Fix this:

```bash
RKE2_CMD="kubectl --kubeconfig=/tmp/rke2-kubeconfig.yaml --insecure-skip-tls-verify"
SYSTEM_AGENT_CHECKSUM="<checksum-B-from-step-2>"

# Patch stv-aggregation with Checksum B (base64-encoded)
ENCODED=$(echo -n "$SYSTEM_AGENT_CHECKSUM" | base64 -w0)
$RKE2_CMD patch secret stv-aggregation -n cattle-system --type=strategic \
  -p "{\"data\":{\"CATTLE_CA_CHECKSUM\":\"$ENCODED\"}}"

# Delete all failed system-agent-upgrader jobs
$RKE2_CMD delete jobs -n cattle-system \
  -l upgrade.cattle.io/plan=system-agent-upgrader \
  --field-selector=status.successful=0

# The System Upgrade Controller will create new jobs automatically.
# Watch them complete:
$RKE2_CMD get jobs -n cattle-system \
  -l upgrade.cattle.io/plan=system-agent-upgrader -w
```

> **Note:** The cluster agent may overwrite `stv-aggregation` back to
> Checksum A on its next reconciliation. If system-agent-upgrader jobs
> start failing again, re-apply this patch.

## Step 5: The Rancher Reconciler Fight

**This is the most important section to understand.**

Rancher's cluster agent controller reconciles the `cattle-cluster-agent`
deployment every few minutes. Each time, it overwrites your corrected
`CATTLE_CA_CHECKSUM` with its own (wrong) value. This creates new
ReplicaSet pods that immediately crash with the checksum mismatch.

**What happens after you patch:**

1. Your patched deployment creates pods with the correct checksum.
2. Pods start, connect to Rancher, cluster shows Ready/Connected.
3. ~3-5 minutes later, Rancher reconciles and overwrites the deployment.
4. New ReplicaSet is created with wrong checksum. New pods crash.
5. **The old working pods keep running** (Kubernetes won't kill them
   because the new pods never become Ready).
6. Cluster remains Connected despite the CrashLoopBackOff noise.

**This is a stable state.** The cluster functions correctly. The
CrashLoopBackOff pods are cosmetic. You can verify:

```bash
# On Rancher - cluster should show Ready/Connected
$K3K_CMD get clusters.management.cattle.io \
  -o custom-columns='NAME:.metadata.name,DISPLAY:.spec.displayName,READY:.status.conditions[?(@.type=="Ready")].status,CONNECTED:.status.conditions[?(@.type=="Connected")].status'
```

### If Rancher kills the working pods

In rare cases (manual intervention, node drain, pod eviction), the
working pod may be killed. When this happens, only the broken pods
remain and the cluster disconnects. Re-apply Step 3 to fix it.

### Monitoring for the fight

You can watch for the reconciler overwriting your patch:

```bash
# On the downstream cluster, watch for new ReplicaSets
kubectl get rs -n cattle-system -l app=cattle-cluster-agent \
  --sort-by='.metadata.creationTimestamp'
```

If you see a new ReplicaSet appear with 0 ready pods, Rancher
just overwrote your patch.

---

## Step 6: Verify Everything

```bash
# 1. Check cluster status in Rancher
$K3K_CMD get clusters.management.cattle.io \
  -o custom-columns='NAME:.metadata.name,DISPLAY:.spec.displayName,READY:.status.conditions[?(@.type=="Ready")].status'

# 2. Check agent pods on downstream cluster (expect some CrashLoopBackOff — this is OK)
kubectl get pods -n cattle-system -l app=cattle-cluster-agent

# 3. Check agent logs on the RUNNING pod
kubectl logs -n cattle-system -l app=cattle-cluster-agent --tail=5

# 4. Check system-agent-upgrader jobs (RKE2)
$RKE2_CMD get jobs -n cattle-system -l upgrade.cattle.io/plan=system-agent-upgrader
```

**Expected success log:**

```text
INFO: Value from https://rancher.example.com/v3/settings/cacerts is an x509 certificate
INFO: Starting steve aggregation client
```

**Expected failure log (needs re-patching):**

```text
ERROR: Configured cacerts checksum (xxx) does not match given --ca-checksum (yyy)
```

---

## Post-Restore: Vault TLS Re-Application

When restoring a vcluster that used Vault-issued TLS (not the default
self-signed), the Vault issuer config must be re-applied because the
Rancher Backup operator does not back up cert-manager CRDs.

### Re-apply Vault Issuer

```bash
K3K_CMD="kubectl --kubeconfig=<k3k-kubeconfig> --insecure-skip-tls-verify"

# 1. Apply the vault-approle Secret and vault-issuer ClusterIssuer
$K3K_CMD apply -f vault-issuer.yaml

# 2. Wait for ClusterIssuer to be Ready
$K3K_CMD get clusterissuer vault-issuer -w

# 3. Remove ingress-shim annotations (Rancher Helm chart adds these)
$K3K_CMD annotate ingress rancher -n cattle-system \
  cert-manager.io/issuer- \
  cert-manager.io/issuer-kind-

# 4. Delete the restored Certificate CR (points to old 'rancher' Issuer)
$K3K_CMD delete certificate tls-rancher-ingress -n cattle-system

# 5. Delete the old TLS secret
$K3K_CMD delete secret tls-rancher-ingress -n cattle-system

# 6. Apply the Vault Certificate CR
$K3K_CMD apply -f vault-certificate.yaml

# 7. Wait for issuance
$K3K_CMD get certificate tls-rancher-ingress -n cattle-system -w
```

> **Critical:** Steps 3-5 must happen in order. The restored Certificate
> CR is owned by the Rancher Ingress via ingress-shim. If you apply the
> new Certificate without deleting the old one first, the issuerRef will
> not be updated.

### Copy Cert to Host Cluster

```bash
TLS_CRT=$($K3K_CMD -n cattle-system get secret tls-rancher-ingress \
  -o jsonpath='{.data.tls\.crt}' | base64 -d)
TLS_KEY=$($K3K_CMD -n cattle-system get secret tls-rancher-ingress \
  -o jsonpath='{.data.tls\.key}' | base64 -d)

kubectl -n rancher-k3k create secret tls tls-rancher-ingress \
  --cert=<(echo "$TLS_CRT") --key=<(echo "$TLS_KEY") \
  --dry-run=client -o yaml | kubectl apply -f -
```

### Update Rancher cacerts

Then proceed to Step 1 of this SOP to update the cacerts settings and
fix downstream agents.

---

## Quick Reference: Full Recovery Sequence

For an engineer performing a cert change + restore from scratch:

```text
 1. Deploy fresh vcluster          deploy.sh -c deploy.conf
 2. Install backup operator        helm install rancher-backup-crd + rancher-backup
 3. Restore from backup            Apply Restore CR with S3/MinIO config
 4. Re-apply Vault issuer          vault-issuer.yaml + vault-certificate.yaml
 5. Remove ingress-shim            Annotate ingress, delete old Certificate + Secret
 6. Wait for Vault cert            kubectl get certificate -w
 7. Copy cert to host              Extract from vcluster, apply to rancher-k3k ns
 8. Update Rancher cacerts         Patch cacerts setting with new CA chain
 9. Compute BOTH checksums         Checksum A (jq file method) + Checksum B (pipe method)
10. Patch agent deployments        On EACH downstream cluster with Checksum A
11. Patch stv-aggregation          On RKE2 clusters with Checksum B
12. Delete failed upgrader jobs    On RKE2 clusters
13. Verify all clusters Ready      kubectl get clusters.management.cattle.io
14. Accept the reconciler fight    Working pods persist alongside CrashLoopBackOff pods
```

---

## Troubleshooting

### Agent CrashLoopBackOff with checksum mismatch

```text
ERROR: Configured cacerts checksum (aaa) does not match given --ca-checksum (bbb)
```

The "Configured" hash is what the agent computed from `/v3/settings/cacerts`.
The "--ca-checksum" is `CATTLE_CA_CHECKSUM` from the deployment env.
**Set `CATTLE_CA_CHECKSUM` to match the "Configured" value** using a
direct deployment patch (Step 3).

### Agent running but "certificate signed by unknown authority"

```text
level=error msg="Failed to connect to proxy" error="tls: failed to verify certificate:
  x509: certificate signed by unknown authority"
```

The agent is running with an old CA that does not trust the new
certificate. The deployment needs to be rolled with the correct
`CATTLE_CA_CHECKSUM` so the agent re-downloads and trusts the new CA.

### System-agent-upgrader jobs keep failing

```text
[ERROR]  Configured cacerts checksum (9cb34b49...) does not match given --ca-checksum (a204fbc2...)
```

This is the reverse mismatch. The install script computes via pipe
(`9cb34b49...`) but the stv-aggregation secret has the jq-based hash
(`a204fbc2...`). Fix by patching stv-aggregation with the pipe-based
hash (Step 4).

### Rancher keeps overwriting CATTLE_CA_CHECKSUM

This is expected behavior. Rancher's cluster agent controller reconciles
every few minutes. **DO NOT use agentEnvVars** to try to persist the
override — it creates duplicate keys and breaks the deployment entirely.

Instead, accept the reconciler fight (Step 5). The working pods persist
because Kubernetes will not terminate them while the new pods are not
Ready.

If the working pod gets killed for any reason, re-apply Step 3.

### agentEnvVars caused a strategic merge patch error

If you accidentally set `CATTLE_CA_CHECKSUM` via `agentEnvVars`, clear
it immediately:

```bash
$K3K_CMD patch clusters.management.cattle.io <cluster-id> --type=merge \
  -p '{"spec": {"agentEnvVars": []}}'
```

Then re-apply Step 3 on the downstream cluster.

### Cluster ID changed after restore

Rancher may assign new cluster IDs after a restore. Always list current
clusters before patching:

```bash
$K3K_CMD get clusters.management.cattle.io \
  -o custom-columns='NAME:.metadata.name,DISPLAY:.spec.displayName'
```

### Harvester shows "Waiting for API to be available"

This means the Harvester cluster was re-added to Rancher but the agent
hasn't connected yet. Follow Step 3 to fix the agent checksum.
Harvester agents will begin connecting within 30 seconds of a correct
deployment patch.

### Cannot SSH to RKE2 nodes

RKE2 VMs provisioned by Rancher use the SSH key from the Terraform/node
driver config. Find the key in the Terraform workspace or ask the
infrastructure admin. The SSH user is typically `rocky` (configured in
`terraform.tfvars` as `ssh_user`). Find node IPs via Harvester:

```bash
kubectl get vmi -A | grep controlplane
```

### 100+ Error pods from system-agent-upgrader

These are non-critical. The system-agent-upgrader is a SUC plan that
upgrades the Rancher system agent binary on each node. If the nodes are
otherwise healthy, the failed jobs are cosmetic. Fix with Step 4 or
delete the jobs to reduce noise:

```bash
kubectl delete jobs -n cattle-system \
  -l upgrade.cattle.io/plan=system-agent-upgrader \
  --field-selector=status.successful=0
```
