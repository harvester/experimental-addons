#!/usr/bin/env bash
set -euo pipefail

# Destroy Rancher k3k deployment on Harvester
# This removes all k3k resources from the cluster and monitors teardown progress.

K3K_NS="k3k-rancher"
K3K_CLUSTER="rancher"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Show pod summary for a namespace
monitor_ns() {
    local ns="$1"
    local label="${2:-$ns}"
    if kubectl get ns "$ns" &>/dev/null; then
        local pod_count running terminating
        pod_count=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
        running=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | grep -c "Running" || echo "0")
        terminating=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | grep -c "Terminating" || echo "0")
        echo -e "  ${CYAN}${label}:${NC} ${pod_count} pods (${running} running, ${terminating} terminating)"
    else
        echo -e "  ${CYAN}${label}:${NC} namespace not found"
    fi
}

echo -e "${YELLOW}This will destroy the k3k Rancher deployment.${NC}"
echo "The following will be removed:"
echo "  - Ingress watcher, reconciler CronJob, RBAC (k3k-rancher namespace)"
echo "  - Host cluster ingress, service, and TLS secret (k3k-rancher namespace)"
echo "  - k3k virtual cluster and all data inside it"
echo "  - k3k controller (Helm release)"
echo "  - rancher-k3k context/cluster/user from ~/.kube/config"
echo "  - k3k-rancher and k3k-system namespaces"
echo ""

# --- Pre-flight: Show current state ---
echo -e "${CYAN}Current resource state:${NC}"
monitor_ns "$K3K_NS" "k3k-rancher"
monitor_ns "k3k-system" "k3k-system"
if kubectl get clusters.k3k.io "$K3K_CLUSTER" -n "$K3K_NS" &>/dev/null; then
    STATUS=$(kubectl get clusters.k3k.io "$K3K_CLUSTER" -n "$K3K_NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    echo -e "  ${CYAN}Cluster CR:${NC} ${STATUS}"
fi
if helm status k3k -n k3k-system &>/dev/null; then
    echo -e "  ${CYAN}k3k Helm:${NC} installed"
else
    echo -e "  ${CYAN}k3k Helm:${NC} not found"
fi
echo ""

read -rp "Are you sure? (yes/no): " CONFIRM

if [[ "$CONFIRM" != "yes" ]]; then
    log "Aborted."
    exit 0
fi

echo ""

# --- Step 1: Remove ingress watcher and reconciler ---
log "Step 1/6: Removing ingress watcher and reconciler..."
kubectl delete deploy ingress-watcher -n "$K3K_NS" 2>/dev/null && log "  Watcher Deployment deleted" || warn "  Watcher Deployment not found"
kubectl delete cronjob ingress-reconciler -n "$K3K_NS" 2>/dev/null && log "  CronJob deleted" || warn "  CronJob not found"
kubectl delete rolebinding ingress-reconciler -n "$K3K_NS" 2>/dev/null && log "  RoleBinding deleted" || warn "  RoleBinding not found"
kubectl delete role ingress-reconciler -n "$K3K_NS" 2>/dev/null && log "  Role deleted" || warn "  Role not found"
kubectl delete serviceaccount ingress-reconciler -n "$K3K_NS" 2>/dev/null && log "  ServiceAccount deleted" || warn "  ServiceAccount not found"

# --- Step 2: Remove host ingress resources ---
log "Step 2/6: Removing host cluster ingress resources..."
kubectl delete ingress k3k-rancher-ingress -n "$K3K_NS" 2>/dev/null && log "  Ingress deleted" || warn "  Ingress not found"
kubectl delete svc k3k-rancher-traefik -n "$K3K_NS" 2>/dev/null && log "  Service deleted" || warn "  Service not found"
kubectl delete secret tls-rancher-ingress -n "$K3K_NS" 2>/dev/null && log "  TLS secret deleted" || warn "  TLS secret not found"

# --- Step 3: Delete virtual cluster ---
log "Step 3/6: Deleting k3k virtual cluster..."
if kubectl get clusters.k3k.io "$K3K_CLUSTER" -n "$K3K_NS" &>/dev/null; then
    kubectl delete clusters.k3k.io "$K3K_CLUSTER" -n "$K3K_NS"
    log "  Waiting for cluster deletion (monitoring pods)..."
    ATTEMPTS=0
    while kubectl get clusters.k3k.io "$K3K_CLUSTER" -n "$K3K_NS" &>/dev/null; do
        if (( ATTEMPTS % 6 == 0 )); then
            POD_COUNT=$(kubectl get pods -n "$K3K_NS" --no-headers 2>/dev/null | wc -l | tr -d ' ')
            TERMINATING=$(kubectl get pods -n "$K3K_NS" --no-headers 2>/dev/null | grep -c "Terminating" || echo "0")
            echo -e "  ${CYAN}[monitor]${NC} ${POD_COUNT} pods remaining (${TERMINATING} terminating)..."
        fi
        if [[ $ATTEMPTS -ge 60 ]]; then
            warn "  Cluster deletion taking longer than expected (5 min)"
            warn "  Check: kubectl get clusters.k3k.io -n $K3K_NS"
            warn "  Continuing with remaining steps..."
            break
        fi
        ATTEMPTS=$((ATTEMPTS + 1))
        sleep 5
    done
    if ! kubectl get clusters.k3k.io "$K3K_CLUSTER" -n "$K3K_NS" &>/dev/null; then
        log "  Virtual cluster deleted"
    fi
else
    warn "  Virtual cluster not found"
fi

# --- Step 4: Remove k3k controller ---
log "Step 4/6: Removing k3k controller..."
if helm status k3k -n k3k-system &>/dev/null; then
    helm uninstall k3k -n k3k-system
    log "  Helm release deleted"
    log "  Waiting for k3k controller pods to terminate..."
    ATTEMPTS=0
    while kubectl get pods -n k3k-system --no-headers 2>/dev/null | grep -q .; do
        if (( ATTEMPTS % 6 == 0 )); then
            POD_INFO=$(kubectl get pods -n k3k-system --no-headers 2>/dev/null | awk '{printf "    %s %s\n", $1, $3}')
            echo -e "  ${CYAN}[monitor]${NC} Pods in k3k-system:"
            echo "$POD_INFO"
        fi
        if [[ $ATTEMPTS -ge 24 ]]; then
            warn "  Pods still terminating after 2 min, continuing..."
            break
        fi
        ATTEMPTS=$((ATTEMPTS + 1))
        sleep 5
    done
elif kubectl get addon k3k-controller -n k3k-system &>/dev/null; then
    # Fallback: installed via Harvester addon
    kubectl patch addon k3k-controller -n k3k-system --type=merge -p '{"spec":{"enabled":false}}' 2>/dev/null || true
    sleep 5
    kubectl delete addon k3k-controller -n k3k-system 2>/dev/null || true
    log "  Harvester addon deleted"
else
    warn "  k3k controller not found"
fi

# --- Step 5: Clean up kubeconfig ---
log "Step 5/6: Cleaning up kubeconfig..."
if [[ -f "$HOME/.kube/config" ]]; then
    kubectl config delete-context rancher-k3k 2>/dev/null && log "  Context 'rancher-k3k' removed" || warn "  Context 'rancher-k3k' not found"
    kubectl config delete-cluster rancher-k3k 2>/dev/null && log "  Cluster 'rancher-k3k' removed" || warn "  Cluster 'rancher-k3k' not found"
    kubectl config delete-user rancher-k3k 2>/dev/null && log "  User 'rancher-k3k' removed" || warn "  User 'rancher-k3k' not found"
else
    warn "  No ~/.kube/config found, skipping"
fi

# --- Step 6: Clean up namespaces ---
log "Step 6/6: Cleaning up namespaces..."
kubectl delete ns "$K3K_NS" 2>/dev/null && log "  $K3K_NS deletion initiated" || warn "  $K3K_NS not found"
kubectl delete ns k3k-system 2>/dev/null && log "  k3k-system deletion initiated" || warn "  k3k-system not found"

# Monitor namespace termination
log "Waiting for namespaces to terminate..."
ATTEMPTS=0
while kubectl get ns "$K3K_NS" &>/dev/null 2>&1 || kubectl get ns k3k-system &>/dev/null 2>&1; do
    REMAINING=""
    kubectl get ns "$K3K_NS" &>/dev/null 2>&1 && REMAINING="$K3K_NS "
    kubectl get ns k3k-system &>/dev/null 2>&1 && REMAINING="${REMAINING}k3k-system"
    if (( ATTEMPTS % 6 == 0 )); then
        echo -e "  ${CYAN}[monitor]${NC} Waiting for: ${REMAINING}"
    fi
    if [[ $ATTEMPTS -ge 60 ]]; then
        warn "Namespace deletion taking longer than expected (5 min)"
        warn "Remaining: $REMAINING"
        warn "Check for finalizers: kubectl get ns <name> -o yaml"
        break
    fi
    ATTEMPTS=$((ATTEMPTS + 1))
    sleep 5
done

# --- Final verification ---
echo ""
echo -e "${CYAN}Final verification:${NC}"
CLEAN=true

if kubectl get ns "$K3K_NS" &>/dev/null 2>&1; then
    echo -e "  ${RED}[!]${NC} Namespace $K3K_NS still exists (may be terminating)"
    CLEAN=false
else
    echo -e "  ${GREEN}[ok]${NC} Namespace $K3K_NS removed"
fi

if kubectl get ns k3k-system &>/dev/null 2>&1; then
    echo -e "  ${RED}[!]${NC} Namespace k3k-system still exists (may be terminating)"
    CLEAN=false
else
    echo -e "  ${GREEN}[ok]${NC} Namespace k3k-system removed"
fi

if helm status k3k -n k3k-system &>/dev/null 2>&1; then
    echo -e "  ${RED}[!]${NC} k3k Helm release still present"
    CLEAN=false
else
    echo -e "  ${GREEN}[ok]${NC} k3k Helm release removed"
fi

if kubectl config get-contexts rancher-k3k &>/dev/null 2>&1; then
    echo -e "  ${RED}[!]${NC} rancher-k3k context still in kubeconfig"
    CLEAN=false
else
    echo -e "  ${GREEN}[ok]${NC} rancher-k3k kubeconfig entries removed"
fi

echo ""
if $CLEAN; then
    log "========================================="
    log " Teardown complete - all resources removed"
    log "========================================="
else
    warn "========================================="
    warn " Teardown finished with warnings"
    warn " Some resources may still be terminating"
    warn "========================================="
fi
