#!/usr/bin/env bash
set -euo pipefail

# Backup Rancher k3k vcluster state
#
# Creates a timestamped backup directory containing:
#   - Deployment configuration (hostname, versions, PVC, TLS source)
#   - Rancher settings and API state
#   - List of imported clusters (for re-import reference)
#   - TLS certificates
#   - Host-side ingress resources
#   - k3k kubeconfig
#
# Usage:
#   ./backup.sh                    # Interactive - prompts for Rancher password
#   ./backup.sh --output /path     # Specify backup directory
#
# The backup enables:
#   - PVC resize (destroy → recreate with different size → restore)
#   - Disaster recovery (redeploy from captured config)
#   - Migration to a different storage class or host cluster

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K3K_NS="rancher-k3k"
K3K_CLUSTER="rancher"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[OK]${NC}    $*"; }
info() { echo -e "${CYAN}[INFO]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

# =============================================================================
# Parse arguments
# =============================================================================
BACKUP_DIR=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output|-o) BACKUP_DIR="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--output /path/to/backup]"
            echo ""
            echo "Backs up the Rancher k3k vcluster deployment configuration and state."
            echo "Creates a timestamped directory with all data needed to restore."
            exit 0
            ;;
        *) err "Unknown argument: $1"; exit 1 ;;
    esac
done

# Default backup directory with timestamp
if [[ -z "$BACKUP_DIR" ]]; then
    BACKUP_DIR="${SCRIPT_DIR}/backups/$(date +%Y%m%d-%H%M%S)"
fi

# =============================================================================
# Prerequisites
# =============================================================================
for cmd in kubectl jq curl; do
    if ! command -v "$cmd" &>/dev/null; then
        err "Required command not found: $cmd"
        exit 1
    fi
done

echo -e "${CYAN}=============================================${NC}"
echo -e "${CYAN} Rancher k3k Backup${NC}"
echo -e "${CYAN}=============================================${NC}"
echo ""

# =============================================================================
# Step 1: Verify k3k cluster exists and is healthy
# =============================================================================
info "Step 1/7: Verifying k3k cluster..."

if ! kubectl get clusters.k3k.io "$K3K_CLUSTER" -n "$K3K_NS" &>/dev/null; then
    err "k3k cluster '$K3K_CLUSTER' not found in namespace '$K3K_NS'"
    exit 1
fi

STATUS=$(kubectl get clusters.k3k.io "$K3K_CLUSTER" -n "$K3K_NS" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
if [[ "$STATUS" != "Ready" ]]; then
    err "k3k cluster is not Ready (current: $STATUS)"
    exit 1
fi
log "k3k cluster is Ready"

# Create backup directory
mkdir -p "$BACKUP_DIR"
info "Backup directory: $BACKUP_DIR"

# =============================================================================
# Step 2: Capture k3k cluster configuration
# =============================================================================
info "Step 2/7: Capturing cluster configuration..."

# Export the k3k Cluster CR
kubectl get clusters.k3k.io "$K3K_CLUSTER" -n "$K3K_NS" -o yaml > "$BACKUP_DIR/k3k-cluster.yaml"

# Extract key config values
PVC_SIZE=$(kubectl get clusters.k3k.io "$K3K_CLUSTER" -n "$K3K_NS" \
    -o jsonpath='{.spec.persistence.storageRequestSize}' 2>/dev/null || echo "unknown")
STORAGE_CLASS=$(kubectl get clusters.k3k.io "$K3K_CLUSTER" -n "$K3K_NS" \
    -o jsonpath='{.spec.persistence.storageClassName}' 2>/dev/null || echo "unknown")
SERVER_COUNT=$(kubectl get clusters.k3k.io "$K3K_CLUSTER" -n "$K3K_NS" \
    -o jsonpath='{.spec.servers}' 2>/dev/null || echo "1")

# Detect hostname from ingress
HOSTNAME=$(kubectl get ingress rancher-k3k-ingress -n "$K3K_NS" \
    -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || echo "")
if [[ -z "$HOSTNAME" ]]; then
    err "Could not detect hostname from ingress"
    exit 1
fi
RANCHER_URL="https://${HOSTNAME}"

log "Hostname: $HOSTNAME, PVC: $PVC_SIZE, StorageClass: $STORAGE_CLASS"

# =============================================================================
# Step 3: Extract k3k kubeconfig and detect versions
# =============================================================================
info "Step 3/7: Extracting kubeconfig and versions..."

# Extract kubeconfig
K3K_KC=$(mktemp)
kubectl get secret "k3k-${K3K_CLUSTER}-kubeconfig" -n "$K3K_NS" \
    -o jsonpath='{.data.kubeconfig\.yaml}' | base64 -d > "$K3K_KC"

# Fix server URL to NodePort
CLUSTER_IP=$(sed -n 's/.*server: https:\/\/\([^:]*\).*/\1/p' "$K3K_KC")
NODE_PORT=$(kubectl get svc "k3k-${K3K_CLUSTER}-service" -n "$K3K_NS" \
    -o jsonpath='{.spec.ports[?(@.port==443)].nodePort}' 2>/dev/null || echo "")
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "")

if [[ -n "$NODE_PORT" && -n "$NODE_IP" ]]; then
    sedi "s|server: https://${CLUSTER_IP}|server: https://${NODE_IP}:${NODE_PORT}|" "$K3K_KC"
fi

K3K_CMD="kubectl --kubeconfig=$K3K_KC --insecure-skip-tls-verify"

if ! $K3K_CMD get nodes &>/dev/null; then
    err "Cannot connect to k3k cluster"
    rm -f "$K3K_KC"
    exit 1
fi

cp "$K3K_KC" "$BACKUP_DIR/kubeconfig-k3k.yaml"

# Detect installed versions from HelmChart CRs
CERTMANAGER_VERSION=$($K3K_CMD get helmcharts.helm.cattle.io cert-manager -n kube-system \
    -o jsonpath='{.spec.version}' 2>/dev/null || echo "unknown")
CERTMANAGER_REPO=$($K3K_CMD get helmcharts.helm.cattle.io cert-manager -n kube-system \
    -o jsonpath='{.spec.repo}' 2>/dev/null || echo "")
CERTMANAGER_CHART=$($K3K_CMD get helmcharts.helm.cattle.io cert-manager -n kube-system \
    -o jsonpath='{.spec.chart}' 2>/dev/null || echo "cert-manager")

RANCHER_VERSION=$($K3K_CMD get helmcharts.helm.cattle.io rancher -n kube-system \
    -o jsonpath='{.spec.version}' 2>/dev/null || echo "unknown")
RANCHER_REPO=$($K3K_CMD get helmcharts.helm.cattle.io rancher -n kube-system \
    -o jsonpath='{.spec.repo}' 2>/dev/null || echo "")
RANCHER_CHART=$($K3K_CMD get helmcharts.helm.cattle.io rancher -n kube-system \
    -o jsonpath='{.spec.chart}' 2>/dev/null || echo "rancher")

# Detect TLS source and bootstrap password from Rancher HelmChart set values
TLS_SOURCE=$($K3K_CMD get helmcharts.helm.cattle.io rancher -n kube-system \
    -o jsonpath='{.spec.set.ingress\.tls\.source}' 2>/dev/null || echo "rancher")
BOOTSTRAP_PW=$($K3K_CMD get helmcharts.helm.cattle.io rancher -n kube-system \
    -o jsonpath='{.spec.set.bootstrapPassword}' 2>/dev/null || echo "")

# Detect k3k controller version
K3K_VERSION=$(helm list -n k3k-system -o json 2>/dev/null | jq -r '.[0].chart // ""' | sed 's/k3k-//' || echo "unknown")

# Export HelmChart CRs (full YAML for exact restore)
$K3K_CMD get helmcharts.helm.cattle.io -n kube-system -o yaml > "$BACKUP_DIR/helmcharts.yaml" 2>/dev/null || true

log "cert-manager: $CERTMANAGER_VERSION, Rancher: $RANCHER_VERSION, k3k: $K3K_VERSION"

# =============================================================================
# Step 4: Backup TLS certificates
# =============================================================================
info "Step 4/7: Backing up TLS certificates..."

# TLS cert from inside vcluster (cattle-system)
if $K3K_CMD get secret tls-rancher-ingress -n cattle-system &>/dev/null; then
    $K3K_CMD get secret tls-rancher-ingress -n cattle-system -o yaml > "$BACKUP_DIR/tls-rancher-ingress-vcluster.yaml"
    log "Backed up vcluster TLS cert"
else
    warn "tls-rancher-ingress not found in vcluster cattle-system"
fi

# TLS cert from host cluster (rancher-k3k namespace)
if kubectl get secret tls-rancher-ingress -n "$K3K_NS" &>/dev/null; then
    kubectl get secret tls-rancher-ingress -n "$K3K_NS" -o yaml > "$BACKUP_DIR/tls-rancher-ingress-host.yaml"
    log "Backed up host TLS cert"
else
    warn "tls-rancher-ingress not found in host namespace"
fi

# Private CA cert if present
if $K3K_CMD get secret tls-ca -n cattle-system &>/dev/null; then
    $K3K_CMD get secret tls-ca -n cattle-system -o yaml > "$BACKUP_DIR/tls-ca.yaml"
    log "Backed up private CA cert"
fi

# =============================================================================
# Step 5: Backup Rancher API state
# =============================================================================
info "Step 5/7: Backing up Rancher API state..."

# Try to get Rancher state via API if reachable
RANCHER_REACHABLE=false
if curl -sk --connect-timeout 5 "${RANCHER_URL}/ping" &>/dev/null; then
    RANCHER_REACHABLE=true
    info "Rancher API is reachable at $RANCHER_URL"

    echo ""
    echo "  Enter Rancher admin credentials to backup API state."
    echo "  (Press Enter to skip API backup — config backup will still be saved)"
    echo ""
    read -rp "  Username [admin]: " RANCHER_USER
    RANCHER_USER="${RANCHER_USER:-admin}"

    if [[ -n "$RANCHER_USER" ]]; then
        read -rsp "  Password: " RANCHER_PASS
        echo ""

        if [[ -n "$RANCHER_PASS" ]]; then
            # Login
            LOGIN_RESPONSE=$(jq -n --arg u "$RANCHER_USER" --arg p "$RANCHER_PASS" \
                '{username: $u, password: $p}' | \
                curl -sk "${RANCHER_URL}/v3-public/localProviders/local?action=login" \
                -H 'Content-Type: application/json' \
                -d @- 2>/dev/null || echo '{}')

            LOGIN_TOKEN=$(echo "$LOGIN_RESPONSE" | jq -r '.token // empty')

            if [[ -n "$LOGIN_TOKEN" ]]; then
                log "Authenticated to Rancher API"

                # Export settings
                curl -sk "${RANCHER_URL}/v3/settings" \
                    -H "Authorization: Bearer ${LOGIN_TOKEN}" \
                    | jq '[.data[] | select(.value != "" and .value != null) | {name, value, source}]' \
                    > "$BACKUP_DIR/rancher-settings.json" 2>/dev/null || true
                log "Backed up Rancher settings"

                # Export imported clusters list
                curl -sk "${RANCHER_URL}/v3/clusters" \
                    -H "Authorization: Bearer ${LOGIN_TOKEN}" \
                    | jq '[.data[] | {id, name, driver, state, provider: .labels["provider.cattle.io"]}]' \
                    > "$BACKUP_DIR/imported-clusters.json" 2>/dev/null || true
                log "Backed up imported clusters list"

                # Export API tokens (metadata only, not the actual token values)
                curl -sk "${RANCHER_URL}/v3/tokens" \
                    -H "Authorization: Bearer ${LOGIN_TOKEN}" \
                    | jq '[.data[] | {name, description, expired, ttl, userId}]' \
                    > "$BACKUP_DIR/api-tokens.json" 2>/dev/null || true
                log "Backed up API token metadata"

                # Export cloud credentials (metadata only)
                curl -sk "${RANCHER_URL}/v3/cloudcredentials" \
                    -H "Authorization: Bearer ${LOGIN_TOKEN}" \
                    | jq '[.data[] | {id, name, type: .harvesterCredentialConfig.clusterType}]' \
                    > "$BACKUP_DIR/cloud-credentials.json" 2>/dev/null || true
                log "Backed up cloud credential metadata"

                # Export server-url setting specifically
                SERVER_URL=$(curl -sk "${RANCHER_URL}/v3/settings/server-url" \
                    -H "Authorization: Bearer ${LOGIN_TOKEN}" \
                    | jq -r '.value // empty' 2>/dev/null || echo "")
                if [[ -n "$SERVER_URL" ]]; then
                    log "Server URL: $SERVER_URL"
                fi
            else
                warn "Login failed — skipping API state backup"
            fi
        else
            warn "No password provided — skipping API state backup"
        fi
    else
        warn "Skipping API state backup"
    fi
else
    warn "Rancher API not reachable — skipping API state backup"
fi

# =============================================================================
# Step 6: Backup host-side resources
# =============================================================================
info "Step 6/7: Backing up host-side resources..."

# Service
kubectl get svc rancher-k3k-traefik -n "$K3K_NS" -o yaml > "$BACKUP_DIR/host-service.yaml" 2>/dev/null || true

# Ingress
kubectl get ingress rancher-k3k-ingress -n "$K3K_NS" -o yaml > "$BACKUP_DIR/host-ingress.yaml" 2>/dev/null || true

# Ingress reconciler
kubectl get cronjob ingress-reconciler -n "$K3K_NS" -o yaml > "$BACKUP_DIR/ingress-reconciler.yaml" 2>/dev/null || true

# Ingress watcher
kubectl get deploy ingress-watcher -n "$K3K_NS" -o yaml > "$BACKUP_DIR/ingress-watcher.yaml" 2>/dev/null || true

# Registry config secrets (for private registry setups)
kubectl get secret k3s-registry-config -n "$K3K_NS" -o yaml > "$BACKUP_DIR/k3s-registry-config.yaml" 2>/dev/null || true
kubectl get secret k3s-registry-ca -n "$K3K_NS" -o yaml > "$BACKUP_DIR/k3s-registry-ca.yaml" 2>/dev/null || true

log "Backed up host-side resources"

# =============================================================================
# Step 7: Write config manifest
# =============================================================================
info "Step 7/7: Writing backup manifest..."

# Determine chart source type
CM_SOURCE="http"
is_oci "$CERTMANAGER_CHART" && CM_SOURCE="oci"
R_SOURCE="http"
is_oci "$RANCHER_CHART" && R_SOURCE="oci"

jq -n \
    --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg hostname "$HOSTNAME" \
    --arg pvc_size "$PVC_SIZE" \
    --arg storage_class "$STORAGE_CLASS" \
    --arg server_count "$SERVER_COUNT" \
    --arg tls_source "$TLS_SOURCE" \
    --arg bootstrap_pw "$BOOTSTRAP_PW" \
    --arg certmanager_version "$CERTMANAGER_VERSION" \
    --arg certmanager_repo "$CERTMANAGER_REPO" \
    --arg certmanager_chart "$CERTMANAGER_CHART" \
    --arg certmanager_source "$CM_SOURCE" \
    --arg rancher_version "$RANCHER_VERSION" \
    --arg rancher_repo "$RANCHER_REPO" \
    --arg rancher_chart "$RANCHER_CHART" \
    --arg rancher_source "$R_SOURCE" \
    --arg k3k_version "$K3K_VERSION" \
    --arg k3k_ns "$K3K_NS" \
    --arg k3k_cluster "$K3K_CLUSTER" \
    --argjson rancher_reachable "$RANCHER_REACHABLE" \
    '{
        backup_timestamp: $timestamp,
        deployment: {
            hostname: $hostname,
            tls_source: $tls_source,
            bootstrap_password: $bootstrap_pw,
            namespace: $k3k_ns,
            cluster_name: $k3k_cluster
        },
        storage: {
            pvc_size: $pvc_size,
            storage_class: $storage_class,
            server_count: ($server_count | tonumber)
        },
        versions: {
            k3k: $k3k_version,
            certmanager: $certmanager_version,
            rancher: $rancher_version
        },
        chart_sources: {
            certmanager: {
                type: $certmanager_source,
                chart: $certmanager_chart,
                repo: $certmanager_repo
            },
            rancher: {
                type: $rancher_source,
                chart: $rancher_chart,
                repo: $rancher_repo
            }
        },
        api_state_captured: $rancher_reachable
    }' > "$BACKUP_DIR/config.json"

log "Backup manifest written"

# Clean up temp kubeconfig
rm -f "$K3K_KC"

# =============================================================================
# Summary
# =============================================================================
echo ""
echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN} Backup Complete${NC}"
echo -e "${GREEN}=========================================${NC}"
echo ""
echo -e "  ${CYAN}Backup location:${NC} $BACKUP_DIR"
echo ""
echo "  Files:"
ls -1 "$BACKUP_DIR" | while read -r f; do
    SIZE=$(du -h "$BACKUP_DIR/$f" | cut -f1 | tr -d ' ')
    echo "    $f ($SIZE)"
done
echo ""
if [[ "$RANCHER_REACHABLE" == "true" ]]; then
    echo -e "  ${GREEN}API state:${NC} captured (settings, clusters, tokens)"
else
    echo -e "  ${YELLOW}API state:${NC} not captured (Rancher was not reachable)"
fi
echo ""
echo "  To restore from this backup:"
echo "    ./restore.sh --from $BACKUP_DIR"
echo ""
echo "  To resize the PVC (e.g. 500Gi -> 20Gi):"
echo "    ./backup.sh"
echo "    ./destroy.sh"
echo "    ./restore.sh --from $BACKUP_DIR --pvc-size 20Gi"
echo ""
