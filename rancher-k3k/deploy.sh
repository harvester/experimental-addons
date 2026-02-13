#!/usr/bin/env bash
set -euo pipefail

# Deploy Rancher on Harvester using k3k
# This script orchestrates the full deployment including TLS cert propagation.
# Re-running this script with updated versions will upgrade existing components.
#
# Supports:
#   - Custom PVC sizing (10Gi to 1000Gi+)
#   - Private Helm chart repos (cert-manager, Rancher)
#   - OCI-based Helm registries (oci://harbor.example.com/project/chart)
#   - Private container registries
#   - Private CA certificates
#   - Custom storage classes
#   - In-place upgrades (re-run with new versions)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K3K_NS="rancher-k3k"
K3K_CLUSTER="rancher"
KUBECONFIG_FILE=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Kubeconfig is preserved for the user after successful deployment.
cleanup_on_error() {
    if [[ $? -ne 0 && -n "$KUBECONFIG_FILE" && -f "$KUBECONFIG_FILE" ]]; then
        rm -f "$KUBECONFIG_FILE"
    fi
}
trap cleanup_on_error EXIT

# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

# =============================================================================
# Configuration
# =============================================================================
echo -e "${CYAN}=============================================${NC}"
echo -e "${CYAN} Rancher on k3k - Deployment Configuration${NC}"
echo -e "${CYAN}=============================================${NC}"
echo ""

# --- Required ---
read -rp "Rancher hostname (e.g. rancher.example.com): " HOSTNAME
if [[ -z "$HOSTNAME" ]]; then
    err "Hostname is required"
    exit 1
fi

read -rp "Bootstrap password (min 12 chars) [admin1234567]: " BOOTSTRAP_PW
BOOTSTRAP_PW="${BOOTSTRAP_PW:-admin1234567}"
if [[ ${#BOOTSTRAP_PW} -lt 12 ]]; then
    err "Password must be at least 12 characters"
    exit 1
fi

# --- Storage ---
echo ""
echo -e "${CYAN}Storage Configuration:${NC}"
echo "  10Gi   - Base Rancher (minimum)"
echo "  50Gi   - Rancher + basic monitoring"
echo "  200Gi  - Rancher + Prometheus + Grafana + Loki"
echo "  500Gi  - Full observability stack with retention"
read -rp "PVC size [10Gi]: " PVC_SIZE
PVC_SIZE="${PVC_SIZE:-10Gi}"
# Strip trailing + (from help text copy-paste) and validate
PVC_SIZE="${PVC_SIZE%+}"
if ! [[ "$PVC_SIZE" =~ ^[0-9]+(Gi|Ti|Mi)$ ]]; then
    err "Invalid PVC size: $PVC_SIZE (use format like 10Gi, 500Gi, 1Ti)"
    exit 1
fi

read -rp "Storage class [harvester-longhorn]: " STORAGE_CLASS
STORAGE_CLASS="${STORAGE_CLASS:-harvester-longhorn}"

# --- Helm chart sources (optional) ---
echo ""
echo -e "${CYAN}Helm Chart Sources (press Enter for public defaults):${NC}"
echo "  Enter HTTP repo URLs or OCI URIs (oci://harbor.example.com/project/chart)"
read -rp "cert-manager source [https://charts.jetstack.io]: " CERTMANAGER_REPO
CERTMANAGER_REPO="${CERTMANAGER_REPO:-https://charts.jetstack.io}"

read -rp "cert-manager version [v1.18.5]: " CERTMANAGER_VERSION
CERTMANAGER_VERSION="${CERTMANAGER_VERSION:-v1.18.5}"

read -rp "Rancher source [https://releases.rancher.com/server-charts/latest]: " RANCHER_REPO
RANCHER_REPO="${RANCHER_REPO:-https://releases.rancher.com/server-charts/latest}"

read -rp "Rancher version [v2.13.2]: " RANCHER_VERSION
RANCHER_VERSION="${RANCHER_VERSION:-v2.13.2}"

read -rp "k3k source [https://rancher.github.io/k3k]: " K3K_REPO
K3K_REPO="${K3K_REPO:-https://rancher.github.io/k3k}"

read -rp "k3k version [1.0.2-rc2]: " K3K_VERSION
K3K_VERSION="${K3K_VERSION:-1.0.2-rc2}"

# --- Private registry (optional) ---
echo ""
echo -e "${CYAN}Private Container Registry (press Enter to skip):${NC}"
echo "  Enter the registry host (e.g. harbor.example.com)."
echo "  Containerd mirrors are generated for: docker.io, quay.io, ghcr.io"
echo "  Each requires a matching proxy cache project in Harbor."
echo "  Requires k3k >= v1.0.2-rc2 (secretMounts support)."
read -rp "Private registry host []: " PRIVATE_REGISTRY
PRIVATE_REGISTRY="${PRIVATE_REGISTRY:-}"

# --- Private CA certificate (optional) ---
echo ""
echo -e "${CYAN}Private CA Certificate (press Enter to skip):${NC}"
echo "  Path to a PEM-encoded CA bundle for internal TLS."
echo "  Used when Helm repos or registries use private certificates."
read -rp "CA certificate path []: " PRIVATE_CA_PATH
PRIVATE_CA_PATH="${PRIVATE_CA_PATH:-}"

# --- Helm repo authentication (optional) ---
echo ""
HELM_REPO_USER=""
HELM_REPO_PASS=""
read -rp "Do your Helm repos require authentication? (yes/no) [no]: " HELM_AUTH_NEEDED
HELM_AUTH_NEEDED="${HELM_AUTH_NEEDED:-no}"
if [[ "$HELM_AUTH_NEEDED" == "yes" ]]; then
    echo -e "${CYAN}Helm Repository Authentication:${NC}"
    read -rp "Helm repo username: " HELM_REPO_USER
    if [[ -z "$HELM_REPO_USER" ]]; then
        err "Username is required when authentication is enabled"
        exit 1
    fi
    read -rsp "Helm repo password: " HELM_REPO_PASS
    echo ""
    if [[ -z "$HELM_REPO_PASS" ]]; then
        err "Password is required when username is set"
        exit 1
    fi
fi

# --- TLS source ---
echo ""
echo -e "${CYAN}TLS Certificate Source:${NC}"
echo "  rancher      - Self-signed (default, no external dependency)"
echo "  letsEncrypt  - Let's Encrypt (requires public DNS)"
echo "  secret       - Provide your own TLS cert"
read -rp "TLS source [rancher]: " TLS_SOURCE
TLS_SOURCE="${TLS_SOURCE:-rancher}"

# Validate CA cert path if provided
if [[ -n "$PRIVATE_CA_PATH" && ! -f "$PRIVATE_CA_PATH" ]]; then
    err "CA certificate file not found: $PRIVATE_CA_PATH"
    exit 1
fi

# --- Confirm ---
echo ""
echo -e "${CYAN}Configuration Summary:${NC}"
echo "  Hostname:         $HOSTNAME"
echo "  Password:         ****"
echo "  PVC Size:         $PVC_SIZE"
echo "  Storage Class:    $STORAGE_CLASS"
echo "  cert-manager:     $CERTMANAGER_REPO ($CERTMANAGER_VERSION)$(is_oci "$CERTMANAGER_REPO" && echo ' [OCI]')"
echo "  Rancher:          $RANCHER_REPO ($RANCHER_VERSION)$(is_oci "$RANCHER_REPO" && echo ' [OCI]')"
echo "  k3k:              $K3K_REPO ($K3K_VERSION)$(is_oci "$K3K_REPO" && echo ' [OCI]')"
echo "  TLS Source:       $TLS_SOURCE"
[[ -n "$PRIVATE_REGISTRY" ]] && echo "  Registry:         $PRIVATE_REGISTRY (mirrors: docker.io, quay.io, ghcr.io)"
[[ -n "$PRIVATE_CA_PATH" ]] && echo "  CA Cert:          $PRIVATE_CA_PATH"
[[ -n "$HELM_REPO_USER" ]] && echo "  Helm Auth:        $HELM_REPO_USER / ****" || echo "  Helm Auth:        none (public repos)"
echo ""
read -rp "Proceed? (yes/no) [yes]: " CONFIRM
CONFIRM="${CONFIRM:-yes}"
if [[ "$CONFIRM" != "yes" ]]; then
    log "Aborted."
    exit 0
fi

# =============================================================================
# Compute OCI-derived variables
# =============================================================================
# For each chart source, determine whether it's OCI or HTTP and set the
# template variables accordingly.
if is_oci "$CERTMANAGER_REPO"; then
    CERTMANAGER_CHART="$CERTMANAGER_REPO"       # Full OCI URI goes into spec.chart
    CERTMANAGER_REPO_LINE=""                     # No spec.repo for OCI
else
    CERTMANAGER_CHART="cert-manager"             # Chart name only for HTTP
    CERTMANAGER_REPO_LINE="  repo: ${CERTMANAGER_REPO}"
fi

if is_oci "$RANCHER_REPO"; then
    RANCHER_CHART="$RANCHER_REPO"
    RANCHER_REPO_LINE=""
else
    RANCHER_CHART="rancher"
    RANCHER_REPO_LINE="  repo: ${RANCHER_REPO}"
fi

# =============================================================================
# Build Helm flags for private repos
# =============================================================================
build_helm_repo_flags
build_helm_ca_flags

# Log in to OCI registries on the host cluster (deduplicated by host)
OCI_LOGGED_HOSTS=()
for _repo_var in K3K_REPO CERTMANAGER_REPO RANCHER_REPO; do
    _repo_val="${!_repo_var}"
    if is_oci "$_repo_val"; then
        _host=$(oci_registry_host "$_repo_val")
        # Skip if already logged in to this host
        if [[ ! " ${OCI_LOGGED_HOSTS[*]+"${OCI_LOGGED_HOSTS[*]}"} " == *" ${_host} "* ]]; then
            log "Logging in to OCI registry: $_host"
            helm_registry_login "$_host"
            OCI_LOGGED_HOSTS+=("$_host")
        fi
    fi
done

# =============================================================================
# Build extra Rancher values
# =============================================================================
EXTRA_RANCHER_VALUES=""

if [[ -n "$PRIVATE_REGISTRY" ]]; then
    # Rancher images are all on docker.io, so systemDefaultRegistry needs host/docker.io
    EXTRA_RANCHER_VALUES="${EXTRA_RANCHER_VALUES}    systemDefaultRegistry: \"${PRIVATE_REGISTRY}/docker.io\"\n"
fi

if [[ -n "$PRIVATE_CA_PATH" ]]; then
    EXTRA_RANCHER_VALUES="${EXTRA_RANCHER_VALUES}    privateCA: \"true\"\n"
fi

# Format for YAML indentation (under spec.set:)
if [[ -n "$EXTRA_RANCHER_VALUES" ]]; then
    EXTRA_RANCHER_VALUES=$(echo -e "$EXTRA_RANCHER_VALUES")
else
    EXTRA_RANCHER_VALUES=""
fi

# =============================================================================
# Step 1: Install/upgrade k3k controller via Helm
# =============================================================================
echo ""
log "Step 1/9: Installing k3k controller..."
if is_oci "$K3K_REPO"; then
    # OCI: install directly from OCI URI (no helm repo add)
    if helm status k3k -n k3k-system &>/dev/null; then
        log "k3k already installed, upgrading to $K3K_VERSION..."
        helm upgrade k3k "$K3K_REPO" -n k3k-system --version "$K3K_VERSION" ${HELM_CA_FLAGS[@]+"${HELM_CA_FLAGS[@]}"}
    else
        helm install k3k "$K3K_REPO" -n k3k-system --create-namespace --version "$K3K_VERSION" ${HELM_CA_FLAGS[@]+"${HELM_CA_FLAGS[@]}"}
    fi
else
    # HTTP: add repo then install
    if ! helm repo add k3k "$K3K_REPO" --force-update ${HELM_REPO_FLAGS[@]+"${HELM_REPO_FLAGS[@]}"}; then
        err "Failed to add k3k Helm repo: $K3K_REPO"
        err "Check the URL, credentials, and CA certificate settings"
        exit 1
    fi
    helm repo update k3k
    if helm status k3k -n k3k-system &>/dev/null; then
        log "k3k already installed, upgrading to $K3K_VERSION..."
        helm upgrade k3k k3k/k3k -n k3k-system --version "$K3K_VERSION" ${HELM_CA_FLAGS[@]+"${HELM_CA_FLAGS[@]}"}
    else
        helm install k3k k3k/k3k -n k3k-system --create-namespace --version "$K3K_VERSION" ${HELM_CA_FLAGS[@]+"${HELM_CA_FLAGS[@]}"}
    fi
fi
log "Waiting for k3k controller..."
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
# Step 1.5 (optional): Create registry config Secrets for k3k cluster
# =============================================================================
if [[ -n "$PRIVATE_REGISTRY" ]]; then
    log "Creating K3s registry config for k3k cluster..."

    # Ensure namespace exists before creating Secrets
    kubectl create namespace "$K3K_NS" --dry-run=client -o yaml | kubectl apply -f -

    # Generate and store registries.yaml
    REGISTRIES_FILE=$(mktemp)
    build_registries_yaml "$REGISTRIES_FILE"
    log "Generated registries.yaml:"
    cat "$REGISTRIES_FILE" | while IFS= read -r line; do echo "    $line"; done
    kubectl -n "$K3K_NS" create secret generic k3s-registry-config \
        --from-file=registries.yaml="$REGISTRIES_FILE" \
        --dry-run=client -o yaml | kubectl apply -f -
    rm -f "$REGISTRIES_FILE"

    # Store CA cert if provided
    if [[ -n "$PRIVATE_CA_PATH" ]]; then
        kubectl -n "$K3K_NS" create secret generic k3s-registry-ca \
            --from-file=ca.crt="$PRIVATE_CA_PATH" \
            --dry-run=client -o yaml | kubectl apply -f -
    fi

    log "Registry config Secrets created in $K3K_NS"
fi

# =============================================================================
# Step 2: Create k3k virtual cluster
# =============================================================================
log "Step 2/9: Creating k3k virtual cluster..."
if kubectl get clusters.k3k.io "$K3K_CLUSTER" -n "$K3K_NS" &>/dev/null; then
    log "k3k cluster already exists, skipping"
else
    CLUSTER_MANIFEST=$(mktemp)
    sed -e "s|__PVC_SIZE__|${PVC_SIZE}|g" \
        -e "s|__STORAGE_CLASS__|${STORAGE_CLASS}|g" \
        "$SCRIPT_DIR/rancher-cluster.yaml" > "$CLUSTER_MANIFEST"
    inject_secret_mounts "$CLUSTER_MANIFEST"
    kubectl apply -f "$CLUSTER_MANIFEST"
    rm -f "$CLUSTER_MANIFEST"
fi

log "Waiting for k3k cluster to be ready..."
ATTEMPTS=0
while true; do
    STATUS=$(kubectl get clusters.k3k.io "$K3K_CLUSTER" -n "$K3K_NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [[ "$STATUS" == "Ready" ]]; then
        break
    fi
    if [[ $ATTEMPTS -ge 60 ]]; then
        echo ""
        err "Timed out waiting for k3k cluster (5 minutes). Current status: $STATUS"
        err "Check: kubectl get clusters.k3k.io $K3K_CLUSTER -n $K3K_NS -o yaml"
        err "Check: kubectl get pods -n $K3K_NS"
        exit 1
    fi
    ATTEMPTS=$((ATTEMPTS + 1))
    echo -n "."
    sleep 5
done
echo ""
log "k3k cluster is Ready"

# =============================================================================
# Step 3: Extract kubeconfig
# =============================================================================
log "Step 3/9: Extracting kubeconfig..."
KUBECONFIG_FILE=$(mktemp)

kubectl get secret "k3k-${K3K_CLUSTER}-kubeconfig" -n "$K3K_NS" \
    -o jsonpath='{.data.kubeconfig\.yaml}' | base64 -d > "$KUBECONFIG_FILE"

# Replace ClusterIP with NodePort address
CLUSTER_IP=$(sed -n 's/.*server: https:\/\/\([^:]*\).*/\1/p' "$KUBECONFIG_FILE")
NODE_PORT=$(kubectl get svc "k3k-${K3K_CLUSTER}-service" -n "$K3K_NS" \
    -o jsonpath='{.spec.ports[?(@.port==443)].nodePort}')
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

if [[ -n "$NODE_PORT" && -n "$NODE_IP" ]]; then
    sedi "s|server: https://${CLUSTER_IP}|server: https://${NODE_IP}:${NODE_PORT}|" "$KUBECONFIG_FILE"
    log "Kubeconfig updated: https://${NODE_IP}:${NODE_PORT}"
else
    warn "Could not determine NodePort. Using ClusterIP (only works from within the cluster)."
fi

K3K_CMD="kubectl --kubeconfig=$KUBECONFIG_FILE --insecure-skip-tls-verify"
if ! $K3K_CMD get nodes &>/dev/null; then
    err "Cannot connect to k3k cluster"
    exit 1
fi
log "Connected to k3k virtual cluster"

# =============================================================================
# Step 3.5 (optional): Install private CA into k3k cluster
# =============================================================================
if [[ -n "$PRIVATE_CA_PATH" ]]; then
    log "Installing private CA certificate into k3k cluster..."
    $K3K_CMD create namespace cattle-system --dry-run=client -o yaml | $K3K_CMD apply -f -
    $K3K_CMD -n cattle-system create secret generic tls-ca \
        --from-file=cacerts.pem="$PRIVATE_CA_PATH" \
        --dry-run=client -o yaml | $K3K_CMD apply -f -
    log "Private CA installed"
fi

# =============================================================================
# Step 3.6 (optional): Create in-cluster auth for HelmChart CRs
# =============================================================================
if [[ -n "$HELM_REPO_USER" ]]; then
    # HTTP charts use basic-auth Secret (spec.authSecret)
    if ! is_oci "$CERTMANAGER_REPO" || ! is_oci "$RANCHER_REPO"; then
        log "Creating Helm repo auth secret (basic-auth) in k3k cluster..."
        $K3K_CMD -n kube-system create secret generic helm-repo-auth \
            --type=kubernetes.io/basic-auth \
            --from-literal=username="$HELM_REPO_USER" \
            --from-literal=password="$HELM_REPO_PASS" \
            --dry-run=client -o yaml | $K3K_CMD apply -f -
        log "Helm repo auth secret (basic-auth) created"
    fi

    # OCI charts use dockerconfigjson Secret (spec.dockerRegistrySecret)
    if is_oci "$CERTMANAGER_REPO" || is_oci "$RANCHER_REPO"; then
        # Extract OCI host from the first OCI chart (typically all share one Harbor)
        _oci_host=""
        is_oci "$CERTMANAGER_REPO" && _oci_host=$(oci_registry_host "$CERTMANAGER_REPO")
        [[ -z "$_oci_host" ]] && is_oci "$RANCHER_REPO" && _oci_host=$(oci_registry_host "$RANCHER_REPO")
        log "Creating Helm OCI auth secret (dockerconfigjson) for $_oci_host..."
        create_oci_auth_secret "$K3K_CMD" "helm-oci-auth" "$_oci_host"
        log "Helm OCI auth secret created"
    fi
fi

if [[ -n "$PRIVATE_CA_PATH" ]]; then
    log "Creating Helm repo CA configmap in k3k cluster..."
    $K3K_CMD -n kube-system create configmap helm-repo-ca \
        --from-file=ca-bundle.crt="$PRIVATE_CA_PATH" \
        --dry-run=client -o yaml | $K3K_CMD apply -f -
    log "Helm repo CA configmap created"
fi

# =============================================================================
# Step 4: Deploy cert-manager
# =============================================================================
log "Step 4/9: Deploying cert-manager..."

CERTMANAGER_MANIFEST=$(mktemp)
sed -e "s|__CERTMANAGER_CHART__|${CERTMANAGER_CHART}|g" \
    -e "s|__CERTMANAGER_VERSION__|${CERTMANAGER_VERSION}|g" \
    "$SCRIPT_DIR/post-install/01-cert-manager.yaml" > "$CERTMANAGER_MANIFEST"

# Inject or remove the repo line (OCI has no spec.repo)
if [[ -n "$CERTMANAGER_REPO_LINE" ]]; then
    sedi "s|^__CERTMANAGER_REPO_LINE__$|${CERTMANAGER_REPO_LINE}|" "$CERTMANAGER_MANIFEST"
else
    sedi "/__CERTMANAGER_REPO_LINE__/d" "$CERTMANAGER_MANIFEST"
fi

inject_helmchart_auth "$CERTMANAGER_MANIFEST" "$CERTMANAGER_REPO"
$K3K_CMD apply -f "$CERTMANAGER_MANIFEST"
rm -f "$CERTMANAGER_MANIFEST"

log "Waiting for cert-manager deployment to be created..."
ATTEMPTS=0
while ! $K3K_CMD get deploy/cert-manager -n cert-manager &>/dev/null; do
    if [[ $ATTEMPTS -ge 60 ]]; then
        err "Timed out waiting for cert-manager deployment to appear"
        exit 1
    fi
    ATTEMPTS=$((ATTEMPTS + 1))
    sleep 5
done
$K3K_CMD wait --for=condition=available deploy/cert-manager -n cert-manager --timeout=300s
$K3K_CMD wait --for=condition=available deploy/cert-manager-webhook -n cert-manager --timeout=300s
log "cert-manager is ready"

# =============================================================================
# Step 5: Deploy Rancher
# =============================================================================
log "Step 5/9: Deploying Rancher..."

RANCHER_MANIFEST=$(mktemp)
sed -e "s|__HOSTNAME__|${HOSTNAME}|g" \
    -e "s|__BOOTSTRAP_PW__|${BOOTSTRAP_PW}|g" \
    -e "s|__RANCHER_CHART__|${RANCHER_CHART}|g" \
    -e "s|__RANCHER_VERSION__|${RANCHER_VERSION}|g" \
    -e "s|__TLS_SOURCE__|${TLS_SOURCE}|g" \
    "$SCRIPT_DIR/post-install/02-rancher.yaml" > "$RANCHER_MANIFEST"

# Inject or remove the repo line (OCI has no spec.repo)
if [[ -n "$RANCHER_REPO_LINE" ]]; then
    sedi "s|^__RANCHER_REPO_LINE__$|${RANCHER_REPO_LINE}|" "$RANCHER_MANIFEST"
else
    sedi "/__RANCHER_REPO_LINE__/d" "$RANCHER_MANIFEST"
fi

# Inject extra values (private registry, private CA)
if [[ -n "$EXTRA_RANCHER_VALUES" ]]; then
    sedi "s|^__EXTRA_RANCHER_VALUES__$|${EXTRA_RANCHER_VALUES}|" "$RANCHER_MANIFEST"
else
    sedi "/__EXTRA_RANCHER_VALUES__/d" "$RANCHER_MANIFEST"
fi

# Inject HelmChart auth/CA references
inject_helmchart_auth "$RANCHER_MANIFEST" "$RANCHER_REPO"

$K3K_CMD apply -f "$RANCHER_MANIFEST"
rm -f "$RANCHER_MANIFEST"

log "Waiting for Rancher deployment to be created (Helm chart installing)..."
ATTEMPTS=0
while ! $K3K_CMD get deploy/rancher -n cattle-system &>/dev/null; do
    if [[ $ATTEMPTS -ge 90 ]]; then
        err "Timed out waiting for Rancher deployment to appear"
        err "Check HelmChart status: kubectl get helmcharts -A"
        exit 1
    fi
    ATTEMPTS=$((ATTEMPTS + 1))
    sleep 5
done
log "Rancher deployment found, waiting for pods to be ready..."
$K3K_CMD wait --for=condition=available deploy/rancher -n cattle-system --timeout=600s
log "Rancher is running"

# =============================================================================
# Step 6: Copy TLS certificate to host cluster
# =============================================================================
log "Step 6/9: Copying Rancher TLS certificate to host cluster..."

ATTEMPTS=0
while ! $K3K_CMD get secret tls-rancher-ingress -n cattle-system &>/dev/null; do
    if [[ $ATTEMPTS -ge 30 ]]; then
        err "Timed out waiting for tls-rancher-ingress secret"
        exit 1
    fi
    ATTEMPTS=$((ATTEMPTS + 1))
    sleep 5
done

TLS_CRT=$($K3K_CMD -n cattle-system get secret tls-rancher-ingress -o jsonpath='{.data.tls\.crt}' | base64 -d)
TLS_KEY=$($K3K_CMD -n cattle-system get secret tls-rancher-ingress -o jsonpath='{.data.tls\.key}' | base64 -d)

kubectl -n "$K3K_NS" create secret tls tls-rancher-ingress \
    --cert=<(echo "$TLS_CRT") --key=<(echo "$TLS_KEY") \
    --dry-run=client -o yaml | kubectl apply -f -

log "TLS certificate copied to host cluster"

# =============================================================================
# Step 7: Create host ingress
# =============================================================================
log "Step 7/9: Creating host cluster ingress..."

sed "s|__HOSTNAME__|${HOSTNAME}|g" "$SCRIPT_DIR/host-ingress.yaml" | kubectl apply -f -

log "Host ingress created"

# =============================================================================
# Step 8: Deploy ingress reconciler and watcher
# =============================================================================
log "Step 8/9: Deploying ingress reconciler and watcher..."

sed "s|__HOSTNAME__|${HOSTNAME}|g" "$SCRIPT_DIR/ingress-reconciler.yaml" | kubectl apply -f -
sed "s|__HOSTNAME__|${HOSTNAME}|g" "$SCRIPT_DIR/ingress-watcher.yaml" | kubectl apply -f -

log "Ingress watcher deployed (reacts within 30s of pod restart)"
log "Ingress reconciler deployed (safety net, checks every 5 minutes)"

# =============================================================================
# Step 9: Merge kubeconfig
# =============================================================================
log "Step 9/9: Merging kubeconfig with default config..."

K3K_RENAMED=$(mktemp)
cp "$KUBECONFIG_FILE" "$K3K_RENAMED"

# Get original context/cluster/user names from k3k kubeconfig
OLD_CTX=$(kubectl --kubeconfig="$K3K_RENAMED" config current-context 2>/dev/null || echo "default")
OLD_CLUSTER=$(kubectl --kubeconfig="$K3K_RENAMED" config view --raw -o jsonpath='{.contexts[0].context.cluster}' 2>/dev/null || echo "default")
OLD_USER=$(kubectl --kubeconfig="$K3K_RENAMED" config view --raw -o jsonpath='{.contexts[0].context.user}' 2>/dev/null || echo "default")

log "Renaming context '${OLD_CTX}' -> 'rancher-k3k'"

# Rename context (native kubectl support)
kubectl --kubeconfig="$K3K_RENAMED" config rename-context "$OLD_CTX" rancher-k3k 2>/dev/null || true

# Update context to reference rancher-k3k cluster and user
kubectl --kubeconfig="$K3K_RENAMED" config set-context rancher-k3k --cluster=rancher-k3k --user=rancher-k3k >/dev/null

# Rename cluster and user entry names (no native kubectl rename for these)
if [[ -n "$OLD_CLUSTER" && "$OLD_CLUSTER" != "rancher-k3k" ]]; then
    sedi "s|  name: ${OLD_CLUSTER}$|  name: rancher-k3k|" "$K3K_RENAMED"
    sedi "s|^- name: ${OLD_CLUSTER}$|- name: rancher-k3k|" "$K3K_RENAMED"
fi
if [[ -n "$OLD_USER" && "$OLD_USER" != "rancher-k3k" ]]; then
    sedi "s|  name: ${OLD_USER}$|  name: rancher-k3k|" "$K3K_RENAMED"
    sedi "s|^- name: ${OLD_USER}$|- name: rancher-k3k|" "$K3K_RENAMED"
fi

# Set insecure-skip-tls-verify on the cluster entry
kubectl --kubeconfig="$K3K_RENAMED" config set-cluster rancher-k3k --insecure-skip-tls-verify=true >/dev/null

# Merge k3k config with default kubeconfig
DATESTAMP=$(date +%Y%m%d)
MERGED_KUBECONFIG="$(pwd)/merged.kubeconfig_${DATESTAMP}"

if [[ -f "$HOME/.kube/config" ]]; then
    export KUBECONFIG="$HOME/.kube/config:$K3K_RENAMED"
    kubectl config view --flatten > "$MERGED_KUBECONFIG"
    export KUBECONFIG=""
    log "Merged kubeconfig: ${MERGED_KUBECONFIG}"
else
    warn "No default kubeconfig at ~/.kube/config, saving k3k config standalone"
    cp "$K3K_RENAMED" "$MERGED_KUBECONFIG"
fi

rm -f "$K3K_RENAMED"
log "Context 'rancher-k3k' ready in merged kubeconfig"

# =============================================================================
# Done
# =============================================================================
echo ""
echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN} Rancher deployed successfully!${NC}"
echo -e "${GREEN}=========================================${NC}"
echo ""
echo -e " URL:           https://${HOSTNAME}"
echo -e " Password:      ${BOOTSTRAP_PW}"
echo -e " PVC Size:      ${PVC_SIZE}"
[[ -n "$PRIVATE_REGISTRY" ]] && echo -e " Registry:      ${PRIVATE_REGISTRY}"
echo ""
echo -e " k3k kubeconfig:    ${KUBECONFIG_FILE}"
echo -e " Merged kubeconfig: ${MERGED_KUBECONFIG}"
echo ""
echo " To use the merged kubeconfig:"
echo "   export KUBECONFIG=${MERGED_KUBECONFIG}"
echo "   kubectl config use-context rancher-k3k"
echo "   kubectl get pods -A"
echo ""
echo " To access k3k cluster directly:"
echo "   export KUBECONFIG=${KUBECONFIG_FILE}"
echo "   kubectl --insecure-skip-tls-verify get pods -A"
echo ""
echo " To destroy:"
echo "   $(dirname "$0")/destroy.sh"
echo ""
