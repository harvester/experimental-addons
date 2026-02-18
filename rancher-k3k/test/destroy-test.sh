#!/usr/bin/env bash
set -euo pipefail

# Destroy TEST vcluster
# This removes the TEST k3k cluster and all associated resources.
#
# Usage: ./destroy-test.sh [-y]

K3K_NS="k3k-test"
K3K_CLUSTER="test"

# --- Flags ---
AUTO_CONFIRM=false
while getopts "y" opt; do
    case $opt in
        y) AUTO_CONFIRM=true ;;
        *) echo "Usage: $0 [-y]"; exit 1 ;;
    esac
done
shift $((OPTIND - 1))

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }

echo ""
echo -e "${YELLOW}This will destroy the TEST vcluster:${NC}"
echo "  Namespace: ${K3K_NS}"
echo "  Cluster:   ${K3K_CLUSTER}"
echo ""
if $AUTO_CONFIRM; then
    CONFIRM="yes"
else
    read -rp "Are you sure? (yes/no) [no]: " CONFIRM
    CONFIRM="${CONFIRM:-no}"
fi
if [[ "$CONFIRM" != "yes" ]]; then
    log "Aborted."
    exit 0
fi

log "Deleting host ingress and service..."
kubectl delete ingress test-k3k-ingress -n "$K3K_NS" --ignore-not-found
kubectl delete svc test-k3k-traefik -n "$K3K_NS" --ignore-not-found
kubectl delete secret tls-rancher-ingress -n "$K3K_NS" --ignore-not-found

log "Deleting TEST k3k cluster..."
kubectl delete clusters.k3k.io "$K3K_CLUSTER" -n "$K3K_NS" --ignore-not-found --timeout=120s

log "Deleting namespace..."
kubectl delete ns "$K3K_NS" --ignore-not-found --timeout=60s

# Remove context from kubeconfig
if kubectl config get-contexts rancher-test &>/dev/null 2>&1; then
    log "Removing rancher-test context from kubeconfig..."
    kubectl config delete-context rancher-test 2>/dev/null || true
    kubectl config delete-cluster rancher-test 2>/dev/null || true
    kubectl config delete-user rancher-test 2>/dev/null || true
fi

echo ""
log "TEST vcluster destroyed."
echo ""
