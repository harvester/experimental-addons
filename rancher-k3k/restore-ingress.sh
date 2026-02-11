#!/usr/bin/env bash
set -euo pipefail

# Restore the host cluster Ingress for Rancher running inside k3k.
#
# The k3k host Ingress is not managed by any controller and can be deleted
# during Harvester upgrades, node drains, or ingress-nginx reconciliation.
# Run this script to restore access to Rancher.
#
# Usage:
#   ./restore-ingress.sh                          # auto-detect hostname from k3k cluster
#   ./restore-ingress.sh rancher.example.com      # specify hostname explicitly

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

# Cross-platform sed -i
sedi() {
    if sed --version &>/dev/null 2>&1; then
        sed -i "$@"
    else
        sed -i '' "$@"
    fi
}

# --- Preflight checks ---
if ! command -v kubectl &>/dev/null; then
    err "kubectl is not installed"
    exit 1
fi

if ! kubectl get clusters.k3k.io "$K3K_CLUSTER" -n "$K3K_NS" &>/dev/null; then
    err "k3k cluster '$K3K_CLUSTER' not found in namespace '$K3K_NS'"
    exit 1
fi

STATUS=$(kubectl get clusters.k3k.io "$K3K_CLUSTER" -n "$K3K_NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
if [[ "$STATUS" != "Ready" ]]; then
    err "k3k cluster is not Ready (current status: $STATUS)"
    exit 1
fi

# --- Determine hostname ---
HOSTNAME="${1:-}"

if [[ -z "$HOSTNAME" ]]; then
    log "No hostname specified, auto-detecting from k3k cluster..."

    KUBECONFIG_FILE=$(mktemp)
    trap "rm -f $KUBECONFIG_FILE" EXIT

    kubectl get secret "k3k-${K3K_CLUSTER}-kubeconfig" -n "$K3K_NS" \
        -o jsonpath='{.data.kubeconfig\.yaml}' | base64 -d > "$KUBECONFIG_FILE"

    # Replace ClusterIP with NodePort for external access
    CLUSTER_IP=$(sed -n 's/.*server: https:\/\/\([^:]*\).*/\1/p' "$KUBECONFIG_FILE")
    NODE_PORT=$(kubectl get svc "k3k-${K3K_CLUSTER}-service" -n "$K3K_NS" \
        -o jsonpath='{.spec.ports[?(@.port==443)].nodePort}' 2>/dev/null || echo "")
    NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

    if [[ -n "$NODE_PORT" && -n "$NODE_IP" ]]; then
        sedi "s|server: https://${CLUSTER_IP}|server: https://${NODE_IP}:${NODE_PORT}|" "$KUBECONFIG_FILE"
    fi

    HOSTNAME=$(kubectl --kubeconfig="$KUBECONFIG_FILE" --insecure-skip-tls-verify \
        get ingress -n cattle-system -o jsonpath='{.items[0].spec.rules[0].host}' 2>/dev/null || echo "")

    if [[ -z "$HOSTNAME" ]]; then
        err "Could not auto-detect hostname from k3k cluster"
        err "Usage: $0 <hostname>"
        exit 1
    fi

    log "Detected hostname: $HOSTNAME"
fi

# --- Check current state ---
echo ""
INGRESS_EXISTS=false
TLS_EXISTS=false
SVC_EXISTS=false

kubectl get ingress k3k-rancher-ingress -n "$K3K_NS" &>/dev/null && INGRESS_EXISTS=true
kubectl get secret tls-rancher-ingress -n "$K3K_NS" &>/dev/null && TLS_EXISTS=true
kubectl get svc k3k-rancher-traefik -n "$K3K_NS" &>/dev/null && SVC_EXISTS=true

echo -e "${YELLOW}Current state:${NC}"
echo "  Ingress:     $( $INGRESS_EXISTS && echo 'exists' || echo 'MISSING' )"
echo "  TLS secret:  $( $TLS_EXISTS && echo 'exists' || echo 'MISSING' )"
echo "  Service:     $( $SVC_EXISTS && echo 'exists' || echo 'MISSING' )"
echo ""

if $INGRESS_EXISTS && $TLS_EXISTS && $SVC_EXISTS; then
    log "All resources exist. Nothing to restore."
    log "If Rancher is still inaccessible, check DNS resolution and nginx-ingress controller health."
    exit 0
fi

# --- Restore Service if missing ---
if ! $SVC_EXISTS; then
    log "Restoring Service..."
    kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: k3k-rancher-traefik
  namespace: $K3K_NS
spec:
  type: ClusterIP
  selector:
    cluster: $K3K_CLUSTER
    role: server
  ports:
    - name: http
      port: 80
      targetPort: 80
    - name: https
      port: 443
      targetPort: 443
EOF
    log "Service restored"
fi

# --- Restore TLS secret if missing ---
if ! $TLS_EXISTS; then
    log "TLS secret missing, copying from k3k cluster..."

    if [[ -z "${KUBECONFIG_FILE:-}" ]]; then
        KUBECONFIG_FILE=$(mktemp)
        trap "rm -f $KUBECONFIG_FILE" EXIT

        kubectl get secret "k3k-${K3K_CLUSTER}-kubeconfig" -n "$K3K_NS" \
            -o jsonpath='{.data.kubeconfig\.yaml}' | base64 -d > "$KUBECONFIG_FILE"

        CLUSTER_IP=$(sed -n 's/.*server: https:\/\/\([^:]*\).*/\1/p' "$KUBECONFIG_FILE")
        NODE_PORT=$(kubectl get svc "k3k-${K3K_CLUSTER}-service" -n "$K3K_NS" \
            -o jsonpath='{.spec.ports[?(@.port==443)].nodePort}' 2>/dev/null || echo "")
        NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

        if [[ -n "$NODE_PORT" && -n "$NODE_IP" ]]; then
            sedi "s|server: https://${CLUSTER_IP}|server: https://${NODE_IP}:${NODE_PORT}|" "$KUBECONFIG_FILE"
        fi
    fi

    K3K_CMD="kubectl --kubeconfig=$KUBECONFIG_FILE --insecure-skip-tls-verify"

    TLS_CRT=$($K3K_CMD -n cattle-system get secret tls-rancher-ingress -o jsonpath='{.data.tls\.crt}' | base64 -d)
    TLS_KEY=$($K3K_CMD -n cattle-system get secret tls-rancher-ingress -o jsonpath='{.data.tls\.key}' | base64 -d)

    kubectl -n "$K3K_NS" create secret tls tls-rancher-ingress \
        --cert=<(echo "$TLS_CRT") --key=<(echo "$TLS_KEY") \
        --dry-run=client -o yaml | kubectl apply -f -

    log "TLS secret restored"
fi

# --- Restore Ingress if missing ---
if ! $INGRESS_EXISTS; then
    log "Restoring Ingress for $HOSTNAME..."
    kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: k3k-rancher-ingress
  namespace: $K3K_NS
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - $HOSTNAME
      secretName: tls-rancher-ingress
  rules:
    - host: $HOSTNAME
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: k3k-rancher-traefik
                port:
                  number: 443
EOF
    log "Ingress restored"
fi

# --- Verify ---
echo ""
echo -e "${GREEN}Restoration complete.${NC}"
echo ""
echo "  URL: https://$HOSTNAME"
echo ""
echo "  Verify with:"
echo "    kubectl get ingress k3k-rancher-ingress -n $K3K_NS"
echo "    curl -sk https://$HOSTNAME/ping"
echo ""
