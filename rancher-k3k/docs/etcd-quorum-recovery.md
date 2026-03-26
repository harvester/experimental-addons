# SOP: Recovering from Etcd Quorum Deadlock (k3k HA)

When all k3k HA server pods get new IPs simultaneously (e.g., after a full
Harvester cluster shutdown/restart), etcd can't form quorum because peer URLs
are stale. The entrypoint's `safe_mode()` can't update node IPs (needs the API
server, which needs quorum), so all pods CrashLoopBackOff forever.

---

## TL;DR — Quick Fix Checklist

If you just need the cluster running NOW:

1. **Verify** all server pods are CrashLoopBackOff with `timed out waiting for node to change IP`
2. **Check** if auto-recovery kicked in (annotations on Cluster CR)
3. **If not**, manually trigger: patch `spec.servers=1`, wait for Ready, patch back to 3
4. **Verify** Rancher `/ping` returns 200

---

## Background

### Why This Happens

k3k runs k3s inside pods. Each server pod gets a cluster IP that becomes its
etcd peer URL. In HA mode (3 servers), etcd stores peer URLs for all members.

When the entire Harvester cluster shuts down and comes back up, all 3 server
pods are recreated with **new IPs simultaneously**. Etcd tries to contact
peers at their old IPs, fails, and can't form quorum.

### The safe_mode Timeout

k3k's entrypoint has a `safe_mode()` function that detects IP changes and
updates the virtual node object. But it needs the Kubernetes API server to do
this — and the API server needs etcd quorum. Deadlock.

The hardcoded timeout is 120s, but the k3k cloud controller takes ~6 minutes
to update virtual node IPs. Even if quorum existed, `safe_mode()` would time
out first.

### Why start_single_node() Fixes It

When `spec.servers == 1`, k3k uses a different entrypoint: `start_single_node()`.
This function detects existing etcd data and automatically runs
`k3s server --cluster-reset`, which:

1. Removes all etcd members except the local node
2. Resets etcd to a single-node cluster
3. **Preserves ALL data** (Rancher config, downstream clusters, etc.)

After the single node comes up healthy, scaling back to 3 servers causes the
other nodes to join as new etcd members with correct IPs.

---

## Automated Recovery

The ingress-watcher Deployment detects and recovers from this deadlock
automatically using a state machine tracked via Cluster CR annotations.

### Detection Criteria (ALL must be true)

- `spec.servers > 1` (only HA clusters can deadlock)
- ALL server pods are in `CrashLoopBackOff`
- At least one pod's previous logs contain `timed out waiting for node to change IP`
- No recovery already in progress (no `etcd-recovery-state` annotation)

### Recovery State Machine

| State | Action |
|-------|--------|
| `(none)` → `scaling-down` | Save original server count, patch `spec.servers: 1` |
| `scaling-down` → `resetting` | Wait for old pods to terminate, server-0 to become Running |
| `resetting` → `scaling-up` | Wait for Cluster CR `status.phase=Ready`, restore `spec.servers` |
| `scaling-up` → cleanup | Wait for all pods Ready + cluster Ready, remove annotations |

### Monitoring Recovery Progress

```bash
# Check current recovery state
kubectl get clusters.k3k.io rancher -n rancher-k3k \
  -o jsonpath='{.metadata.annotations}' | jq .

# Watch pod status during recovery
kubectl get pods -l "cluster=rancher,role=server" -n rancher-k3k -w

# Watch cluster phase
kubectl get clusters.k3k.io rancher -n rancher-k3k -w
```

### Annotations Used

```
k3k.example.com/etcd-recovery-state: scaling-down|resetting|scaling-up|failed
k3k.example.com/etcd-original-servers: "3"
k3k.example.com/etcd-recovery-started: "2026-02-26T12:00:00Z"
```

### What to Do If Auto-Recovery Fails (state=failed)

A `failed` state means one of the recovery phases exceeded the 10-minute
timeout. The annotations are preserved for investigation.

```bash
# Check which state timed out
kubectl get clusters.k3k.io rancher -n rancher-k3k \
  -o jsonpath='{.metadata.annotations.k3k\.example\.ch/etcd-recovery-state}'

# Check watcher logs for details
kubectl logs -l app=ingress-watcher -n rancher-k3k --tail=50

# Clear failed state to allow manual recovery or retry
kubectl annotate clusters.k3k.io rancher -n rancher-k3k \
  k3k.example.com/etcd-recovery-state- \
  k3k.example.com/etcd-original-servers- \
  k3k.example.com/etcd-recovery-started-
```

After clearing, you can either let the watcher detect and retry automatically,
or use one of the manual procedures below.

---

## Manual Recovery — Spec Patch Method (Recommended)

This is the simplest approach. It triggers the same `start_single_node()`
mechanism that the automated recovery uses.

### Prerequisites

- `kubectl` access to the Harvester host cluster
- Cluster name and namespace (default: `rancher` in `rancher-k3k`)

### Procedure

```bash
NS="rancher-k3k"
CLUSTER="rancher"

# 1. Verify the deadlock
kubectl get pods -l "cluster=$CLUSTER,role=server" -n "$NS"
# All should show CrashLoopBackOff

kubectl logs rancher-server-0 -n "$NS" --previous --tail=5
# Should show: "timed out waiting for node to change IP"

# 2. Set recovery annotations (for tracking)
kubectl annotate clusters.k3k.io "$CLUSTER" -n "$NS" --overwrite \
  "k3k.example.com/etcd-recovery-state=scaling-down" \
  "k3k.example.com/etcd-original-servers=3" \
  "k3k.example.com/etcd-recovery-started=$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# 3. Scale down to 1 server
kubectl patch clusters.k3k.io "$CLUSTER" -n "$NS" --type=merge \
  -p '{"spec":{"servers":1}}'

# 4. Wait for server-0 to become Ready (may take 2-5 minutes)
kubectl get pods -l "cluster=$CLUSTER,role=server" -n "$NS" -w
# Wait until only rancher-server-0 exists and shows 1/1 Ready

# 5. Wait for Cluster CR to show Ready
kubectl get clusters.k3k.io "$CLUSTER" -n "$NS" -w
# Wait for PHASE=Ready

# 6. Scale back to 3 servers
kubectl patch clusters.k3k.io "$CLUSTER" -n "$NS" --type=merge \
  -p '{"spec":{"servers":3}}'

# 7. Wait for all 3 pods to be Ready
kubectl get pods -l "cluster=$CLUSTER,role=server" -n "$NS" -w

# 8. Clean up annotations
kubectl annotate clusters.k3k.io "$CLUSTER" -n "$NS" \
  k3k.example.com/etcd-recovery-state- \
  k3k.example.com/etcd-original-servers- \
  k3k.example.com/etcd-recovery-started-

# 9. Verify Rancher is healthy
curl -sk https://<rancher-url>/ping
# Should return "pong"
```

---

## Manual Recovery — InitContainer Method

This is the heavy-duty approach from the original 2026-02-26 incident. Use it
if the spec patch method fails (e.g., server-0 also crashes in single-node mode).

### Procedure

```bash
NS="rancher-k3k"
CLUSTER="rancher"

# 1. Scale k3k controller to 0 (prevent it from fighting your changes)
kubectl scale deployment k3k-controller-manager -n k3k-system --replicas=0

# 2. Verify controller is stopped
kubectl get pods -n k3k-system

# 3. Find the StatefulSet for the server pods
kubectl get statefulset -n "$NS" -l "cluster=$CLUSTER,role=server"

# 4. Patch the StatefulSet with an etcd-restore InitContainer
#    This runs --cluster-reset before the main k3s process starts
kubectl patch statefulset "${CLUSTER}-server" -n "$NS" --type=json -p '[{
  "op": "add",
  "path": "/spec/template/spec/initContainers",
  "value": [{
    "name": "etcd-restore",
    "image": "rancher/k3s:v1.31.4-k3s1",
    "command": ["k3s", "server", "--cluster-reset"],
    "volumeMounts": [{
      "name": "data",
      "mountPath": "/var/lib/rancher/k3s"
    }]
  }]
}]'

# 5. Delete the existing PVCs for server-1 and server-2
#    (server-0 will be the recovery node)
kubectl delete pvc data-${CLUSTER}-server-1 data-${CLUSTER}-server-2 -n "$NS"

# 6. Delete all server pods to force restart with InitContainer
kubectl delete pods -l "cluster=$CLUSTER,role=server" -n "$NS" --grace-period=0

# 7. Watch server-0 recover
kubectl logs "${CLUSTER}-server-0" -n "$NS" -c etcd-restore -f

# 8. Once server-0 is Running (main container), remove the InitContainer
kubectl patch statefulset "${CLUSTER}-server" -n "$NS" --type=json -p '[{
  "op": "remove",
  "path": "/spec/template/spec/initContainers"
}]'

# 9. Scale k3k controller back to 1
kubectl scale deployment k3k-controller-manager -n k3k-system --replicas=1

# 10. Wait for controller to reconcile and bring up servers 1+2
kubectl get pods -l "cluster=$CLUSTER,role=server" -n "$NS" -w

# 11. Verify
curl -sk https://<rancher-url>/ping
```

> **Warning:** This method directly modifies the StatefulSet, bypassing the
> k3k controller. Make sure you scale the controller back up (step 9) or the
> cluster won't be managed properly.

---

## Troubleshooting

### Recovery stuck in scaling-down (pods not terminating)

The k3k controller may be slow to reconcile the `spec.servers` change. Check
the controller logs:

```bash
kubectl logs -l app=k3k-controller-manager -n k3k-system --tail=20
```

If pods persist, force-delete them:

```bash
kubectl delete pods -l "cluster=rancher,role=server" -n rancher-k3k \
  --grace-period=0 --force
```

### Recovery stuck in resetting (cluster-reset failed)

Check server-0 logs for the cluster-reset output:

```bash
kubectl logs rancher-server-0 -n rancher-k3k --tail=50
```

Common failure: existing etcd data is corrupted. In this case, delete the PVC
for server-0 and let it start fresh (you will lose Rancher data — restore from
backup after):

```bash
kubectl delete pod rancher-server-0 -n rancher-k3k --grace-period=0
kubectl delete pvc data-rancher-server-0 -n rancher-k3k
# Pod will be recreated by the StatefulSet with a fresh PVC
```

### CSI initialization panic (nodes not found)

After recovery, the Harvester CSI driver may panic because the virtual nodes
don't exist yet. This resolves itself once the k3k cloud controller updates
the node objects (~2-3 minutes). Watch for pods stuck in `ContainerCreating`:

```bash
kubectl get pods -n rancher-k3k -o wide
kubectl describe pod rancher-server-0 -n rancher-k3k | tail -20
```

### How to inspect etcd members from inside vCluster

If you have a k3k kubeconfig, you can exec into a server pod:

```bash
kubectl exec -it rancher-server-0 -n rancher-k3k -- \
  k3s etcd-snapshot list

kubectl exec -it rancher-server-0 -n rancher-k3k -- \
  sh -c 'ETCDCTL_API=3 etcdctl \
    --endpoints=https://127.0.0.1:2379 \
    --cert=/var/lib/rancher/k3s/server/tls/etcd/server-client.crt \
    --key=/var/lib/rancher/k3s/server/tls/etcd/server-client.key \
    --cacert=/var/lib/rancher/k3s/server/tls/etcd/server-ca.crt \
    member list -w table'
```

### Watcher pod restarted during recovery

The recovery state is stored in Cluster CR annotations, not in the watcher pod.
When the watcher restarts, it reads the annotations and resumes the state
machine from wherever it left off. No manual intervention needed.

### All 3 pods crash but error is NOT etcd-related

If pods crash with a different error (not the safe_mode timeout), the deadlock
detection will NOT trigger. Check pod logs to identify the actual issue:

```bash
for POD in $(kubectl get pods -l "cluster=rancher,role=server" -n rancher-k3k \
    -o jsonpath='{.items[*].metadata.name}'); do
  echo "=== $POD ==="
  kubectl logs "$POD" -n rancher-k3k --previous --tail=10
done
```
