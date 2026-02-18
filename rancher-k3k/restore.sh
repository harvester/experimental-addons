#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# DEPRECATED: Use rancher-restore.sh instead.
#
# This script performs a metadata-only rebuild (redeploy from config).
# rancher-restore.sh uses the rancher-backup operator to restore full
# Rancher state (users, RBAC, fleet, clusters, settings, tokens, etc.)
# and works with any Rancher cluster, not just k3k.
#
# This script is retained for backward compatibility and PVC resize workflows
# where a metadata rebuild (not state restore) is acceptable.
# =============================================================================

# Restore Rancher k3k vcluster from backup
#
# Rebuilds the entire k3k Rancher stack from a backup created by backup.sh:
#   1. Installs k3k controller (Helm)
#   2. Creates k3k virtual cluster with specified PVC size
#   3. Deploys cert-manager + Rancher (same versions as backup)
#   4. Copies TLS certificates
#   5. Creates host ingress and reconciler/watcher
#   6. Optionally runs terraform-setup.sh for API token creation
#
# Usage:
#   ./restore.sh --from ./backups/20260215-143000
#   ./restore.sh --from ./backups/20260215-143000 --pvc-size 20Gi
#   ./restore.sh --from ./backups/20260215-143000 --dry-run
#
# After restore, you must:
#   - Re-import any Harvester/downstream clusters into Rancher
#   - Create new API tokens via terraform-setup.sh
#   - Update terraform.tfvars with new token + cluster ID

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
PVC_SIZE_OVERRIDE=""
DRY_RUN=false
SKIP_TERRAFORM_SETUP=false
K3K_REPO_OVERRIDE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --from|-f)        BACKUP_DIR="$2"; shift 2 ;;
        --pvc-size|-p)    PVC_SIZE_OVERRIDE="$2"; shift 2 ;;
        --dry-run)        DRY_RUN=true; shift ;;
        --skip-terraform) SKIP_TERRAFORM_SETUP=true; shift ;;
        --k3k-repo)       K3K_REPO_OVERRIDE="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 --from <backup-dir> [options]"
            echo ""
            echo "Options:"
            echo "  --from, -f <dir>      Backup directory (required)"
            echo "  --pvc-size, -p <size>  Override PVC size (e.g. 20Gi)"
            echo "  --dry-run              Show what would be done without executing"
            echo "  --skip-terraform       Skip terraform-setup.sh prompt"
            echo "  --k3k-repo <url>       Override k3k Helm repo URL"
            echo ""
            echo "After restore, you must re-import clusters and create API tokens."
            exit 0
            ;;
        *) err "Unknown argument: $1"; exit 1 ;;
    esac
done

if [[ -z "$BACKUP_DIR" ]]; then
    err "Backup directory required. Use: $0 --from <backup-dir>"
    exit 1
fi

if [[ ! -f "$BACKUP_DIR/config.json" ]]; then
    err "Invalid backup: $BACKUP_DIR/config.json not found"
    exit 1
fi

# =============================================================================
# Prerequisites
# =============================================================================
for cmd in kubectl jq curl helm; do
    if ! command -v "$cmd" &>/dev/null; then
        err "Required command not found: $cmd"
        exit 1
    fi
done

# =============================================================================
# Load backup configuration
# =============================================================================
CONFIG="$BACKUP_DIR/config.json"

HOSTNAME=$(jq -r '.deployment.hostname' "$CONFIG")
TLS_SOURCE=$(jq -r '.deployment.tls_source' "$CONFIG")
BOOTSTRAP_PW=$(jq -r '.deployment.bootstrap_password' "$CONFIG")
K3K_NS=$(jq -r '.deployment.namespace' "$CONFIG")
K3K_CLUSTER=$(jq -r '.deployment.cluster_name' "$CONFIG")
PVC_SIZE=$(jq -r '.storage.pvc_size' "$CONFIG")
STORAGE_CLASS=$(jq -r '.storage.storage_class' "$CONFIG")
K3K_VERSION=$(jq -r '.versions.k3k' "$CONFIG")
CERTMANAGER_VERSION=$(jq -r '.versions.certmanager' "$CONFIG")
RANCHER_VERSION=$(jq -r '.versions.rancher' "$CONFIG")
CM_TYPE=$(jq -r '.chart_sources.certmanager.type' "$CONFIG")
CM_CHART=$(jq -r '.chart_sources.certmanager.chart' "$CONFIG")
CM_REPO=$(jq -r '.chart_sources.certmanager.repo' "$CONFIG")
R_TYPE=$(jq -r '.chart_sources.rancher.type' "$CONFIG")
R_CHART=$(jq -r '.chart_sources.rancher.chart' "$CONFIG")
R_REPO=$(jq -r '.chart_sources.rancher.repo' "$CONFIG")
BACKUP_TIMESTAMP=$(jq -r '.backup_timestamp' "$CONFIG")

# Apply overrides
if [[ -n "$PVC_SIZE_OVERRIDE" ]]; then
    info "PVC size override: $PVC_SIZE -> $PVC_SIZE_OVERRIDE"
    PVC_SIZE="$PVC_SIZE_OVERRIDE"
fi

K3K_REPO="${K3K_REPO_OVERRIDE:-https://rancher.github.io/k3k}"

echo -e "${CYAN}=============================================${NC}"
echo -e "${CYAN} Rancher k3k Restore${NC}"
echo -e "${CYAN}=============================================${NC}"
echo ""
echo -e "  ${CYAN}Backup from:${NC}      $BACKUP_TIMESTAMP"
echo -e "  ${CYAN}Hostname:${NC}         $HOSTNAME"
echo -e "  ${CYAN}PVC Size:${NC}         $PVC_SIZE"
echo -e "  ${CYAN}Storage Class:${NC}    $STORAGE_CLASS"
echo -e "  ${CYAN}TLS Source:${NC}       $TLS_SOURCE"
echo -e "  ${CYAN}cert-manager:${NC}     $CERTMANAGER_VERSION"
echo -e "  ${CYAN}Rancher:${NC}          $RANCHER_VERSION"
echo -e "  ${CYAN}k3k:${NC}              $K3K_VERSION"
echo ""

# Show previously imported clusters if available
if [[ -f "$BACKUP_DIR/imported-clusters.json" ]]; then
    CLUSTER_COUNT=$(jq 'length' "$BACKUP_DIR/imported-clusters.json" 2>/dev/null || echo "0")
    if [[ "$CLUSTER_COUNT" -gt 0 ]]; then
        echo -e "  ${YELLOW}Clusters to re-import after restore:${NC}"
        jq -r '.[] | "    - \(.name) (\(.id)) [\(.driver // "unknown")]"' "$BACKUP_DIR/imported-clusters.json" 2>/dev/null || true
        echo ""
    fi
fi

if $DRY_RUN; then
    info "Dry run — no changes will be made"
    exit 0
fi

read -rp "Proceed with restore? (yes/no) [yes]: " CONFIRM
CONFIRM="${CONFIRM:-yes}"
if [[ "$CONFIRM" != "yes" ]]; then
    info "Aborted."
    exit 0
fi

# =============================================================================
# Step 1: Verify no existing k3k cluster (safety check)
# =============================================================================
info "Step 1/8: Pre-flight checks..."

if kubectl get clusters.k3k.io "$K3K_CLUSTER" -n "$K3K_NS" &>/dev/null; then
    err "k3k cluster '$K3K_CLUSTER' already exists in namespace '$K3K_NS'"
    err "Run destroy.sh first, then retry the restore"
    exit 1
fi
log "No existing k3k cluster found — safe to proceed"

# =============================================================================
# Step 2: Install k3k controller
# =============================================================================
info "Step 2/8: Installing k3k controller ($K3K_VERSION)..."

if is_oci "$K3K_REPO"; then
    if helm status k3k -n k3k-system &>/dev/null; then
        helm upgrade k3k "$K3K_REPO" -n k3k-system --version "$K3K_VERSION"
    else
        helm install k3k "$K3K_REPO" -n k3k-system --create-namespace --version "$K3K_VERSION"
    fi
else
    helm repo add k3k "$K3K_REPO" --force-update 2>/dev/null || true
    helm repo update k3k 2>/dev/null || true
    if helm status k3k -n k3k-system &>/dev/null; then
        helm upgrade k3k k3k/k3k -n k3k-system --version "$K3K_VERSION"
    else
        helm install k3k k3k/k3k -n k3k-system --create-namespace --version "$K3K_VERSION"
    fi
fi

ATTEMPTS=0
while ! kubectl get deploy k3k -n k3k-system &>/dev/null; do
    if [[ $ATTEMPTS -ge 24 ]]; then
        err "Timed out waiting for k3k controller deployment"
        exit 1
    fi
    ATTEMPTS=$((ATTEMPTS + 1))
    sleep 5
done
kubectl wait --for=condition=available deploy/k3k -n k3k-system --timeout=120s
log "k3k controller is ready"

# =============================================================================
# Step 3: Restore registry config secrets (if they existed)
# =============================================================================
info "Step 3/8: Restoring registry configuration..."

kubectl create namespace "$K3K_NS" --dry-run=client -o yaml | kubectl apply -f -

REGISTRY_RESTORED=false
if [[ -f "$BACKUP_DIR/k3s-registry-config.yaml" ]]; then
    # Strip resourceVersion/uid/creationTimestamp for clean apply
    jq 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.managedFields)' \
        <(kubectl convert -f "$BACKUP_DIR/k3s-registry-config.yaml" -o json 2>/dev/null || \
          python3 -c "import yaml,json,sys; json.dump(yaml.safe_load(sys.stdin),sys.stdout)" < "$BACKUP_DIR/k3s-registry-config.yaml") \
        2>/dev/null | kubectl apply -f - 2>/dev/null || \
    kubectl apply -f "$BACKUP_DIR/k3s-registry-config.yaml" 2>/dev/null || true
    REGISTRY_RESTORED=true
    log "Registry config restored"
fi
if [[ -f "$BACKUP_DIR/k3s-registry-ca.yaml" ]]; then
    kubectl apply -f "$BACKUP_DIR/k3s-registry-ca.yaml" 2>/dev/null || true
    log "Registry CA restored"
fi

if ! $REGISTRY_RESTORED; then
    log "No registry config to restore (public registry setup)"
fi

# =============================================================================
# Step 4: Create k3k virtual cluster
# =============================================================================
info "Step 4/8: Creating k3k virtual cluster (PVC: $PVC_SIZE)..."

CLUSTER_MANIFEST=$(mktemp)
sed -e "s|__PVC_SIZE__|${PVC_SIZE}|g" \
    -e "s|__STORAGE_CLASS__|${STORAGE_CLASS}|g" \
    "$SCRIPT_DIR/rancher-cluster.yaml" > "$CLUSTER_MANIFEST"

# Remove optional placeholders (no private registry during restore by default)
sedi "/__SECRET_MOUNTS__/d" "$CLUSTER_MANIFEST"
sedi "/__EXTRA_SERVER_ARGS__/d" "$CLUSTER_MANIFEST"

# Inject secret mounts if registry config was restored
if $REGISTRY_RESTORED; then
    # Re-read the template and inject properly
    rm -f "$CLUSTER_MANIFEST"
    sed -e "s|__PVC_SIZE__|${PVC_SIZE}|g" \
        -e "s|__STORAGE_CLASS__|${STORAGE_CLASS}|g" \
        "$SCRIPT_DIR/rancher-cluster.yaml" > "$CLUSTER_MANIFEST"

    # Build minimal secretMounts
    MOUNTS_BLOCK="  secretMounts:\n    - secretName: k3s-registry-config\n      mountPath: /etc/rancher/k3s/registries.yaml\n      subPath: registries.yaml\n      role: all"
    if [[ -f "$BACKUP_DIR/k3s-registry-ca.yaml" ]]; then
        MOUNTS_BLOCK="${MOUNTS_BLOCK}\n    - secretName: k3s-registry-ca\n      mountPath: /etc/rancher/k3s/tls/ca.crt\n      subPath: ca.crt\n      role: all"
    fi

    tmpfile=$(mktemp)
    while IFS= read -r line; do
        if [[ "$line" == *"__SECRET_MOUNTS__"* ]]; then
            echo -e "$MOUNTS_BLOCK"
        else
            printf '%s\n' "$line"
        fi
    done < "$CLUSTER_MANIFEST" > "$tmpfile"
    mv "$tmpfile" "$CLUSTER_MANIFEST"
    sedi "/__EXTRA_SERVER_ARGS__/d" "$CLUSTER_MANIFEST"
fi

kubectl apply -f "$CLUSTER_MANIFEST"
rm -f "$CLUSTER_MANIFEST"

info "Waiting for k3k cluster to be ready..."
ATTEMPTS=0
while true; do
    STATUS=$(kubectl get clusters.k3k.io "$K3K_CLUSTER" -n "$K3K_NS" \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [[ "$STATUS" == "Ready" ]]; then
        break
    fi
    if [[ $ATTEMPTS -ge 60 ]]; then
        echo ""
        err "Timed out waiting for k3k cluster (5 minutes). Current status: $STATUS"
        exit 1
    fi
    ATTEMPTS=$((ATTEMPTS + 1))
    echo -n "."
    sleep 5
done
echo ""
log "k3k cluster is Ready"

# =============================================================================
# Step 5: Extract kubeconfig and deploy cert-manager + Rancher
# =============================================================================
info "Step 5/8: Extracting kubeconfig..."

KUBECONFIG_FILE=$(mktemp)
kubectl get secret "k3k-${K3K_CLUSTER}-kubeconfig" -n "$K3K_NS" \
    -o jsonpath='{.data.kubeconfig\.yaml}' | base64 -d > "$KUBECONFIG_FILE"

CLUSTER_IP=$(sed -n 's/.*server: https:\/\/\([^:]*\).*/\1/p' "$KUBECONFIG_FILE")
NODE_PORT=$(kubectl get svc "k3k-${K3K_CLUSTER}-service" -n "$K3K_NS" \
    -o jsonpath='{.spec.ports[?(@.port==443)].nodePort}')
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

if [[ -n "$NODE_PORT" && -n "$NODE_IP" ]]; then
    sedi "s|server: https://${CLUSTER_IP}|server: https://${NODE_IP}:${NODE_PORT}|" "$KUBECONFIG_FILE"
    log "Kubeconfig updated: https://${NODE_IP}:${NODE_PORT}"
fi

K3K_CMD="kubectl --kubeconfig=$KUBECONFIG_FILE --insecure-skip-tls-verify"
if ! $K3K_CMD get nodes &>/dev/null; then
    err "Cannot connect to k3k cluster"
    exit 1
fi
log "Connected to k3k virtual cluster"

# Save kubeconfig for the user
cp "$KUBECONFIG_FILE" "$SCRIPT_DIR/kubeconfig-k3k.yaml"

# Deploy cert-manager
info "Step 6/8: Deploying cert-manager ($CERTMANAGER_VERSION)..."

CERTMANAGER_MANIFEST=$(mktemp)
if [[ "$CM_TYPE" == "oci" ]]; then
    CERTMANAGER_CHART_VALUE="$CM_CHART"
    CERTMANAGER_REPO_LINE=""
else
    CERTMANAGER_CHART_VALUE="cert-manager"
    CERTMANAGER_REPO_LINE="  repo: ${CM_REPO}"
fi

sed -e "s|__CERTMANAGER_CHART__|${CERTMANAGER_CHART_VALUE}|g" \
    -e "s|__CERTMANAGER_VERSION__|${CERTMANAGER_VERSION}|g" \
    "$SCRIPT_DIR/post-install/01-cert-manager.yaml" > "$CERTMANAGER_MANIFEST"

if [[ -n "$CERTMANAGER_REPO_LINE" ]]; then
    sedi "s|^__CERTMANAGER_REPO_LINE__$|${CERTMANAGER_REPO_LINE}|" "$CERTMANAGER_MANIFEST"
else
    sedi "/__CERTMANAGER_REPO_LINE__/d" "$CERTMANAGER_MANIFEST"
fi

# Remove auth/CA placeholders (not needed for restore from public repos)
sedi "/__AUTH_SECRET_LINE1__/d" "$CERTMANAGER_MANIFEST"
sedi "/__AUTH_SECRET_LINE2__/d" "$CERTMANAGER_MANIFEST"
sedi "/__REPO_CA_LINE1__/d" "$CERTMANAGER_MANIFEST"
sedi "/__REPO_CA_LINE2__/d" "$CERTMANAGER_MANIFEST"

$K3K_CMD apply -f "$CERTMANAGER_MANIFEST"
rm -f "$CERTMANAGER_MANIFEST"

info "Waiting for cert-manager..."
ATTEMPTS=0
while ! $K3K_CMD get deploy/cert-manager -n cert-manager &>/dev/null; do
    if [[ $ATTEMPTS -ge 60 ]]; then
        err "Timed out waiting for cert-manager deployment"
        exit 1
    fi
    ATTEMPTS=$((ATTEMPTS + 1))
    sleep 5
done
$K3K_CMD wait --for=condition=available deploy/cert-manager -n cert-manager --timeout=300s
$K3K_CMD wait --for=condition=available deploy/cert-manager-webhook -n cert-manager --timeout=300s
log "cert-manager is ready"

# Deploy Rancher
info "Step 7/8: Deploying Rancher ($RANCHER_VERSION)..."

RANCHER_MANIFEST=$(mktemp)
if [[ "$R_TYPE" == "oci" ]]; then
    RANCHER_CHART_VALUE="$R_CHART"
    RANCHER_REPO_LINE=""
else
    RANCHER_CHART_VALUE="rancher"
    RANCHER_REPO_LINE="  repo: ${R_REPO}"
fi

sed -e "s|__HOSTNAME__|${HOSTNAME}|g" \
    -e "s|__BOOTSTRAP_PW__|${BOOTSTRAP_PW}|g" \
    -e "s|__RANCHER_CHART__|${RANCHER_CHART_VALUE}|g" \
    -e "s|__RANCHER_VERSION__|${RANCHER_VERSION}|g" \
    -e "s|__TLS_SOURCE__|${TLS_SOURCE}|g" \
    "$SCRIPT_DIR/post-install/02-rancher.yaml" > "$RANCHER_MANIFEST"

if [[ -n "$RANCHER_REPO_LINE" ]]; then
    sedi "s|^__RANCHER_REPO_LINE__$|${RANCHER_REPO_LINE}|" "$RANCHER_MANIFEST"
else
    sedi "/__RANCHER_REPO_LINE__/d" "$RANCHER_MANIFEST"
fi

# Remove optional placeholders
sedi "/__AUTH_SECRET_LINE1__/d" "$RANCHER_MANIFEST"
sedi "/__AUTH_SECRET_LINE2__/d" "$RANCHER_MANIFEST"
sedi "/__REPO_CA_LINE1__/d" "$RANCHER_MANIFEST"
sedi "/__REPO_CA_LINE2__/d" "$RANCHER_MANIFEST"
sedi "/__EXTRA_RANCHER_VALUES__/d" "$RANCHER_MANIFEST"

# Restore private CA if it was backed up
if [[ -f "$BACKUP_DIR/tls-ca.yaml" ]]; then
    $K3K_CMD create namespace cattle-system --dry-run=client -o yaml | $K3K_CMD apply -f -
    $K3K_CMD apply -f "$BACKUP_DIR/tls-ca.yaml" 2>/dev/null || true
    log "Private CA certificate restored"
fi

$K3K_CMD apply -f "$RANCHER_MANIFEST"
rm -f "$RANCHER_MANIFEST"

info "Waiting for Rancher deployment..."
ATTEMPTS=0
while ! $K3K_CMD get deploy/rancher -n cattle-system &>/dev/null; do
    if [[ $ATTEMPTS -ge 90 ]]; then
        err "Timed out waiting for Rancher deployment"
        exit 1
    fi
    ATTEMPTS=$((ATTEMPTS + 1))
    sleep 5
done
$K3K_CMD wait --for=condition=available deploy/rancher -n cattle-system --timeout=600s
log "Rancher is running"

# =============================================================================
# Step 8: Copy TLS cert + create host ingress + reconciler
# =============================================================================
info "Step 8/8: Setting up host ingress and TLS..."

# Wait for TLS secret to be generated
ATTEMPTS=0
while ! $K3K_CMD get secret tls-rancher-ingress -n cattle-system &>/dev/null; do
    if [[ $ATTEMPTS -ge 30 ]]; then
        err "Timed out waiting for tls-rancher-ingress secret"
        exit 1
    fi
    ATTEMPTS=$((ATTEMPTS + 1))
    sleep 5
done

# Copy TLS cert to host cluster
TLS_CRT=$($K3K_CMD -n cattle-system get secret tls-rancher-ingress -o jsonpath='{.data.tls\.crt}' | base64 -d)
TLS_KEY=$($K3K_CMD -n cattle-system get secret tls-rancher-ingress -o jsonpath='{.data.tls\.key}' | base64 -d)

kubectl -n "$K3K_NS" create secret tls tls-rancher-ingress \
    --cert=<(echo "$TLS_CRT") --key=<(echo "$TLS_KEY") \
    --dry-run=client -o yaml | kubectl apply -f -
log "TLS certificate copied to host cluster"

# Create host ingress
sed "s|__HOSTNAME__|${HOSTNAME}|g" "$SCRIPT_DIR/host-ingress.yaml" | kubectl apply -f -
log "Host ingress created"

# Deploy ingress reconciler and watcher
sed "s|__HOSTNAME__|${HOSTNAME}|g" "$SCRIPT_DIR/ingress-reconciler.yaml" | kubectl apply -f -
sed "s|__HOSTNAME__|${HOSTNAME}|g" "$SCRIPT_DIR/ingress-watcher.yaml" | kubectl apply -f -
log "Ingress reconciler and watcher deployed"

# Clean up temp kubeconfig
rm -f "$KUBECONFIG_FILE"

# =============================================================================
# Summary
# =============================================================================
echo ""
echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN} Restore Complete${NC}"
echo -e "${GREEN}=========================================${NC}"
echo ""
echo -e "  ${CYAN}Rancher URL:${NC}   https://${HOSTNAME}"
echo -e "  ${CYAN}Password:${NC}      ${BOOTSTRAP_PW}"
echo -e "  ${CYAN}PVC Size:${NC}      ${PVC_SIZE}"
echo -e "  ${CYAN}Kubeconfig:${NC}    ${SCRIPT_DIR}/kubeconfig-k3k.yaml"
echo ""

# Show clusters that need re-importing
if [[ -f "$BACKUP_DIR/imported-clusters.json" ]]; then
    CLUSTER_COUNT=$(jq 'length' "$BACKUP_DIR/imported-clusters.json" 2>/dev/null || echo "0")
    if [[ "$CLUSTER_COUNT" -gt 0 ]]; then
        echo -e "  ${YELLOW}ACTION REQUIRED — Re-import these clusters:${NC}"
        jq -r '.[] | "    - \(.name) (\(.driver // "unknown"))"' "$BACKUP_DIR/imported-clusters.json" 2>/dev/null || true
        echo ""
        echo "  Re-import via:"
        echo "    Rancher UI → Virtualization Management → Import Existing"
        echo ""
    fi
fi

echo -e "  ${YELLOW}ACTION REQUIRED — Create new API tokens:${NC}"
echo "    ./terraform-setup.sh"
echo ""
echo "  After terraform-setup.sh completes, update your Terraform configs"
echo "  with the new rancher_token and harvester_cluster_id."
echo ""

if ! $SKIP_TERRAFORM_SETUP; then
    read -rp "Run terraform-setup.sh now? (yes/no) [no]: " RUN_TF_SETUP
    if [[ "${RUN_TF_SETUP:-no}" == "yes" ]]; then
        "$SCRIPT_DIR/terraform-setup.sh"
    fi
fi
