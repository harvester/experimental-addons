#!/usr/bin/env bash
set -euo pipefail

# Destroy Rancher k3k deployment on Harvester
# This removes all k3k resources from the cluster.

K3K_NS="k3k-rancher"
K3K_CLUSTER="rancher"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }

echo -e "${YELLOW}This will destroy the k3k Rancher deployment.${NC}"
echo "The following will be removed:"
echo "  - Ingress watcher, reconciler CronJob, RBAC (k3k-rancher namespace)"
echo "  - Host cluster ingress, service, and TLS secret (k3k-rancher namespace)"
echo "  - k3k virtual cluster and all data inside it"
echo "  - k3k controller (Helm release)"
echo "  - k3k-rancher and k3k-system namespaces"
echo ""
read -rp "Are you sure? (yes/no): " CONFIRM

if [[ "$CONFIRM" != "yes" ]]; then
    log "Aborted."
    exit 0
fi

# --- Step 1: Remove ingress watcher and reconciler ---
log "Removing ingress watcher and reconciler..."
kubectl delete deploy ingress-watcher -n "$K3K_NS" 2>/dev/null && log "  Watcher Deployment deleted" || warn "  Watcher Deployment not found"
kubectl delete cronjob ingress-reconciler -n "$K3K_NS" 2>/dev/null && log "  CronJob deleted" || warn "  CronJob not found"
kubectl delete rolebinding ingress-reconciler -n "$K3K_NS" 2>/dev/null && log "  RoleBinding deleted" || warn "  RoleBinding not found"
kubectl delete role ingress-reconciler -n "$K3K_NS" 2>/dev/null && log "  Role deleted" || warn "  Role not found"
kubectl delete serviceaccount ingress-reconciler -n "$K3K_NS" 2>/dev/null && log "  ServiceAccount deleted" || warn "  ServiceAccount not found"

# --- Step 2: Remove host ingress resources ---
log "Removing host cluster ingress resources..."
kubectl delete ingress k3k-rancher-ingress -n "$K3K_NS" 2>/dev/null && log "  Ingress deleted" || warn "  Ingress not found"
kubectl delete svc k3k-rancher-traefik -n "$K3K_NS" 2>/dev/null && log "  Service deleted" || warn "  Service not found"
kubectl delete secret tls-rancher-ingress -n "$K3K_NS" 2>/dev/null && log "  TLS secret deleted" || warn "  TLS secret not found"

# --- Step 3: Delete virtual cluster ---
log "Deleting k3k virtual cluster..."
if kubectl get clusters.k3k.io "$K3K_CLUSTER" -n "$K3K_NS" &>/dev/null; then
    kubectl delete clusters.k3k.io "$K3K_CLUSTER" -n "$K3K_NS"
    log "  Waiting for cluster deletion..."
    while kubectl get clusters.k3k.io "$K3K_CLUSTER" -n "$K3K_NS" &>/dev/null; do
        sleep 2
    done
    log "  Virtual cluster deleted"
else
    warn "  Virtual cluster not found"
fi

# --- Step 4: Remove k3k controller ---
log "Removing k3k controller..."
if helm status k3k -n k3k-system &>/dev/null; then
    helm uninstall k3k -n k3k-system
    log "  Helm release deleted"
elif kubectl get addon k3k-controller -n k3k-system &>/dev/null; then
    # Fallback: installed via Harvester addon
    kubectl patch addon k3k-controller -n k3k-system --type=merge -p '{"spec":{"enabled":false}}' 2>/dev/null || true
    sleep 5
    kubectl delete addon k3k-controller -n k3k-system 2>/dev/null || true
    log "  Harvester addon deleted"
else
    warn "  k3k controller not found"
fi

# --- Step 5: Clean up namespaces ---
log "Cleaning up namespaces..."
kubectl delete ns "$K3K_NS" 2>/dev/null && log "  $K3K_NS deleted" || warn "  $K3K_NS not found"
kubectl delete ns k3k-system 2>/dev/null && log "  k3k-system deleted" || warn "  k3k-system not found"

echo ""
log "========================================="
log " Teardown complete"
log "========================================="
