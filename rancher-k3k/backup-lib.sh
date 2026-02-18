#!/usr/bin/env bash
# Shared functions for rancher-backup.sh and rancher-restore.sh
#
# Functions:
#   detect_cluster_type     - Detect k3k, rke2, k3s, or generic cluster
#   install_backup_operator - Install rancher-backup operator via Helm
#   create_s3_credentials   - Render + apply S3 credentials Secret
#   create_encryption_secret - Render + apply encryption Secret
#   render_backup_cr        - Render Backup CR from template
#   render_restore_cr       - Render Restore CR from template
#   wait_for_backup         - Poll Backup CR until complete
#   wait_for_restore        - Poll Restore CR until complete
#   setup_k3k_kubectl       - Extract k3k kubeconfig + build K3K_CMD
#   build_storage_location  - Build storageLocation YAML block for CR
#   build_kubectl_cmd       - Build kubectl command with global flags

BACKUP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib.sh
source "$BACKUP_LIB_DIR/lib.sh"

# Colors (may already be defined by caller)
RED="${RED:-\033[0;31m}"
GREEN="${GREEN:-\033[0;32m}"
YELLOW="${YELLOW:-\033[1;33m}"
CYAN="${CYAN:-\033[0;36m}"
NC="${NC:-\033[0m}"

# Logging (may already be defined by caller)
if ! declare -f log &>/dev/null; then
    log()  { echo -e "${GREEN}[OK]${NC}    $*"; }
fi
if ! declare -f info &>/dev/null; then
    info() { echo -e "${CYAN}[INFO]${NC}  $*"; }
fi
if ! declare -f warn &>/dev/null; then
    warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fi
if ! declare -f err &>/dev/null; then
    err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }
fi

# Default operator settings
BACKUP_OPERATOR_REPO="${BACKUP_OPERATOR_REPO:-https://charts.rancher.io}"
BACKUP_OPERATOR_CRD_CHART="${BACKUP_OPERATOR_CRD_CHART:-rancher-backup-crd}"
BACKUP_OPERATOR_CHART="${BACKUP_OPERATOR_CHART:-rancher-backup}"

# Build kubectl command with optional --kubeconfig and --context flags.
# Sets KUBECTL_CMD global variable.
# Usage: build_kubectl_cmd [--kubeconfig path] [--context name] [--namespace ns]
build_kubectl_cmd() {
    local kubeconfig="${OPT_KUBECONFIG:-}"
    local context="${OPT_CONTEXT:-}"
    KUBECTL_CMD="kubectl"
    if [[ -n "$kubeconfig" ]]; then
        KUBECTL_CMD="$KUBECTL_CMD --kubeconfig=$kubeconfig"
    fi
    if [[ -n "$context" ]]; then
        KUBECTL_CMD="$KUBECTL_CMD --context=$context"
    fi
}

# Detect the cluster type by inspecting cluster resources.
# Returns: k3k, rke2, k3s, or generic
# Usage: CLUSTER_TYPE=$(detect_cluster_type)
detect_cluster_type() {
    local cmd="${KUBECTL_CMD:-kubectl}"

    # Check for k3k clusters (k3k.io CRD present and cluster exists)
    if $cmd get crd clusters.k3k.io &>/dev/null; then
        if $cmd get clusters.k3k.io -A --no-headers 2>/dev/null | grep -q .; then
            echo "k3k"
            return
        fi
    fi

    # Check node labels for RKE2
    if $cmd get nodes -o jsonpath='{.items[0].status.nodeInfo.containerRuntimeVersion}' 2>/dev/null | grep -q containerd; then
        if $cmd get nodes -o jsonpath='{.items[0].metadata.labels}' 2>/dev/null | grep -q "node.kubernetes.io/instance-type"; then
            # RKE2 typically has this label pattern
            :
        fi
        # Check for rke2 specific resources
        if $cmd get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}' 2>/dev/null | grep -q "rke2"; then
            echo "rke2"
            return
        fi
        if $cmd get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}' 2>/dev/null | grep -q "k3s"; then
            echo "k3s"
            return
        fi
    fi

    echo "generic"
}

# Install the rancher-backup operator (CRD + operator charts).
# Skips if already installed. Uses KUBECTL_CMD for namespace detection.
# Usage: install_backup_operator <operator-namespace> [version]
install_backup_operator() {
    local ns="${1:-cattle-resources-system}"
    local version="${2:-}"
    local cmd="${KUBECTL_CMD:-kubectl}"
    local version_flag=""

    if [[ -n "$version" ]]; then
        version_flag="--version $version"
    fi

    # Check if operator is already running
    if $cmd get deploy rancher-backup -n "$ns" &>/dev/null; then
        log "rancher-backup operator already installed in $ns"
        return 0
    fi

    info "Installing rancher-backup operator..."

    # Add Helm repo
    helm repo add rancher-charts "$BACKUP_OPERATOR_REPO" --force-update 2>/dev/null || true
    helm repo update rancher-charts 2>/dev/null || true

    # Install CRD chart first
    # shellcheck disable=SC2086
    if ! helm status "$BACKUP_OPERATOR_CRD_CHART" -n "$ns" &>/dev/null; then
        helm install "$BACKUP_OPERATOR_CRD_CHART" "rancher-charts/$BACKUP_OPERATOR_CRD_CHART" \
            -n "$ns" --create-namespace $version_flag
    fi

    # Install operator chart
    # shellcheck disable=SC2086
    if ! helm status "$BACKUP_OPERATOR_CHART" -n "$ns" &>/dev/null; then
        helm install "$BACKUP_OPERATOR_CHART" "rancher-charts/$BACKUP_OPERATOR_CHART" \
            -n "$ns" $version_flag
    fi

    # Wait for operator to be ready
    info "Waiting for rancher-backup operator..."
    local attempts=0
    while ! $cmd get deploy rancher-backup -n "$ns" &>/dev/null; do
        if [[ $attempts -ge 30 ]]; then
            err "Timed out waiting for rancher-backup deployment"
            return 1
        fi
        attempts=$((attempts + 1))
        sleep 5
    done
    $cmd wait --for=condition=available deploy/rancher-backup -n "$ns" --timeout=300s
    log "rancher-backup operator is ready"
}

# Create S3 credentials Secret from template.
# Usage: create_s3_credentials <namespace> <secret-name> <access-key> <secret-key>
create_s3_credentials() {
    local ns="$1"
    local secret_name="$2"
    local access_key="$3"
    local secret_key="$4"
    local cmd="${KUBECTL_CMD:-kubectl}"

    local manifest
    manifest=$(mktemp)
    sed -e "s|__SECRET_NAME__|${secret_name}|g" \
        -e "s|__NAMESPACE__|${ns}|g" \
        -e "s|__S3_ACCESS_KEY__|${access_key}|g" \
        -e "s|__S3_SECRET_KEY__|${secret_key}|g" \
        "$BACKUP_LIB_DIR/templates/s3-credentials.yaml" > "$manifest"

    $cmd apply -f "$manifest"
    rm -f "$manifest"
    log "S3 credentials Secret '$secret_name' created in $ns"
}

# Create encryption config Secret from template.
# Usage: create_encryption_secret <namespace> <secret-name> <encryption-key>
create_encryption_secret() {
    local ns="$1"
    local secret_name="$2"
    local encryption_key="$3"
    local cmd="${KUBECTL_CMD:-kubectl}"

    local manifest
    manifest=$(mktemp)
    sed -e "s|__SECRET_NAME__|${secret_name}|g" \
        -e "s|__NAMESPACE__|${ns}|g" \
        -e "s|__ENCRYPTION_KEY__|${encryption_key}|g" \
        "$BACKUP_LIB_DIR/templates/encryption-config.yaml" > "$manifest"

    $cmd apply -f "$manifest"
    rm -f "$manifest"
    log "Encryption Secret '$secret_name' created in $ns"
}

# Build the storageLocation YAML block for Backup/Restore CRs.
# Outputs multi-line YAML suitable for injection into CR template.
# Usage: build_storage_location > file
build_storage_location() {
    local bucket="${S3_BUCKET:-}"
    local endpoint="${S3_ENDPOINT:-}"
    local region="${S3_REGION:-}"
    local folder="${S3_FOLDER:-}"
    local cred_secret="${S3_CRED_SECRET:-s3-credentials}"
    local insecure="${S3_INSECURE_TLS:-false}"
    local endpoint_ca="${S3_ENDPOINT_CA:-}"

    if [[ -z "$bucket" ]]; then
        return 0
    fi

    cat <<EOF
  storageLocation:
    s3:
      credentialSecretName: ${cred_secret}
      credentialSecretNamespace: ${OPT_NAMESPACE:-cattle-resources-system}
      bucketName: ${bucket}
EOF
    [[ -n "$endpoint" ]] && echo "      endpoint: ${endpoint}"
    [[ -n "$region" ]] && echo "      region: ${region}"
    [[ -n "$folder" ]] && echo "      folder: ${folder}"
    [[ "$insecure" == "true" ]] && echo "      insecureTLSSkipVerify: true"
    [[ -n "$endpoint_ca" ]] && echo "      endpointCA: $(base64 -w0 < "$endpoint_ca")"
}

# Render a Backup CR from template.
# Usage: render_backup_cr <output-file>
render_backup_cr() {
    local outfile="$1"
    local backup_name="${BACKUP_NAME:-rancher-backup-$(date +%Y%m%d-%H%M%S)}"
    local resource_set="${RESOURCE_SET:-rancher-resource-set}"
    local schedule="${BACKUP_SCHEDULE:-}"
    local retention="${BACKUP_RETENTION:-}"

    local storage_file
    storage_file=$(mktemp)
    build_storage_location > "$storage_file"

    # Start with template
    sed -e "s|__BACKUP_NAME__|${backup_name}|g" \
        -e "s|__RESOURCE_SET__|${resource_set}|g" \
        "$BACKUP_LIB_DIR/templates/backup-cr.yaml" > "$outfile"

    # Inject storage location
    local tmpfile
    tmpfile=$(mktemp)
    while IFS= read -r line; do
        if [[ "$line" == *"__STORAGE_LOCATION__"* ]]; then
            if [[ -s "$storage_file" ]]; then
                cat "$storage_file"
            fi
        else
            printf '%s\n' "$line"
        fi
    done < "$outfile" > "$tmpfile"
    mv "$tmpfile" "$outfile"
    rm -f "$storage_file"

    # Inject encryption config
    if [[ -n "${ENCRYPT:-}" && "$ENCRYPT" == "true" ]]; then
        local enc_name="${ENCRYPTION_SECRET:-backup-encryption}"
        sedi "s|^__ENCRYPTION_CONFIG__$|  encryptionConfigSecretName: ${enc_name}|" "$outfile"
    else
        sedi "/__ENCRYPTION_CONFIG__/d" "$outfile"
    fi

    # Inject schedule
    if [[ -n "$schedule" ]]; then
        sedi "s|^__SCHEDULE__$|  schedule: \"${schedule}\"|" "$outfile"
    else
        sedi "/__SCHEDULE__/d" "$outfile"
    fi

    # Inject retention
    if [[ -n "$retention" ]]; then
        sedi "s|^__RETENTION__$|  retentionCount: ${retention}|" "$outfile"
    else
        sedi "/__RETENTION__/d" "$outfile"
    fi
}

# Render a Restore CR from template.
# Usage: render_restore_cr <output-file>
render_restore_cr() {
    local outfile="$1"
    local restore_name="${RESTORE_NAME:-rancher-restore-$(date +%Y%m%d-%H%M%S)}"
    local backup_file="${BACKUP_FILE:-}"
    local prune="${RESTORE_PRUNE:-false}"

    local storage_file
    storage_file=$(mktemp)
    build_storage_location > "$storage_file"

    # Start with template
    sed -e "s|__RESTORE_NAME__|${restore_name}|g" \
        -e "s|__BACKUP_FILE__|${backup_file}|g" \
        "$BACKUP_LIB_DIR/templates/restore-cr.yaml" > "$outfile"

    # Inject storage location
    local tmpfile
    tmpfile=$(mktemp)
    while IFS= read -r line; do
        if [[ "$line" == *"__STORAGE_LOCATION__"* ]]; then
            if [[ -s "$storage_file" ]]; then
                cat "$storage_file"
            fi
        else
            printf '%s\n' "$line"
        fi
    done < "$outfile" > "$tmpfile"
    mv "$tmpfile" "$outfile"
    rm -f "$storage_file"

    # Inject encryption config
    if [[ -n "${ENCRYPT:-}" && "$ENCRYPT" == "true" ]]; then
        local enc_name="${ENCRYPTION_SECRET:-backup-encryption}"
        sedi "s|^__ENCRYPTION_CONFIG__$|  encryptionConfigSecretName: ${enc_name}|" "$outfile"
    else
        sedi "/__ENCRYPTION_CONFIG__/d" "$outfile"
    fi

    # Inject prune
    if [[ "$prune" == "true" ]]; then
        sedi "s|^__PRUNE__$|  prune: true|" "$outfile"
    else
        sedi "/__PRUNE__/d" "$outfile"
    fi
}

# Wait for a Backup CR to complete.
# Usage: wait_for_backup <backup-name> [timeout-seconds]
wait_for_backup() {
    local name="$1"
    local timeout="${2:-600}"
    local cmd="${KUBECTL_CMD:-kubectl}"
    local elapsed=0

    info "Waiting for backup '$name' to complete (timeout: ${timeout}s)..."
    while true; do
        local status
        status=$($cmd get backups.resources.cattle.io "$name" \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")

        if [[ "$status" == "True" ]]; then
            local filename
            filename=$($cmd get backups.resources.cattle.io "$name" \
                -o jsonpath='{.status.filename}' 2>/dev/null || echo "")
            log "Backup complete: $filename"
            return 0
        fi

        # Check for errors
        local error_msg
        error_msg=$($cmd get backups.resources.cattle.io "$name" \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null || echo "")
        if [[ -n "$error_msg" && "$status" == "False" ]]; then
            err "Backup failed: $error_msg"
            return 1
        fi

        if [[ $elapsed -ge $timeout ]]; then
            err "Timed out waiting for backup after ${timeout}s"
            return 1
        fi

        echo -n "."
        sleep 10
        elapsed=$((elapsed + 10))
    done
}

# Wait for a Restore CR to complete.
# Usage: wait_for_restore <restore-name> [timeout-seconds]
wait_for_restore() {
    local name="$1"
    local timeout="${2:-600}"
    local cmd="${KUBECTL_CMD:-kubectl}"
    local elapsed=0

    info "Waiting for restore '$name' to complete (timeout: ${timeout}s)..."
    while true; do
        local status
        status=$($cmd get restores.resources.cattle.io "$name" \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")

        if [[ "$status" == "True" ]]; then
            log "Restore complete"
            return 0
        fi

        # Check for errors
        local error_msg
        error_msg=$($cmd get restores.resources.cattle.io "$name" \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null || echo "")
        if [[ -n "$error_msg" && "$status" == "False" ]]; then
            err "Restore failed: $error_msg"
            return 1
        fi

        if [[ $elapsed -ge $timeout ]]; then
            err "Timed out waiting for restore after ${timeout}s"
            return 1
        fi

        echo -n "."
        sleep 10
        elapsed=$((elapsed + 10))
    done
}

# Extract k3k kubeconfig and build K3K_CMD.
# Sets globals: K3K_KUBECONFIG, K3K_CMD
# Usage: setup_k3k_kubectl <namespace> <cluster-name>
setup_k3k_kubectl() {
    local ns="${1:-rancher-k3k}"
    local cluster="${2:-rancher}"
    local cmd="${KUBECTL_CMD:-kubectl}"

    K3K_KUBECONFIG=$(mktemp)
    $cmd get secret "k3k-${cluster}-kubeconfig" -n "$ns" \
        -o jsonpath='{.data.kubeconfig\.yaml}' | base64 -d > "$K3K_KUBECONFIG"

    # Replace ClusterIP with NodePort address for external access
    local cluster_ip node_port node_ip
    cluster_ip=$(sed -n 's/.*server: https:\/\/\([^:]*\).*/\1/p' "$K3K_KUBECONFIG")
    node_port=$($cmd get svc "k3k-${cluster}-service" -n "$ns" \
        -o jsonpath='{.spec.ports[?(@.port==443)].nodePort}' 2>/dev/null || echo "")
    node_ip=$($cmd get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "")

    if [[ -n "$node_port" && -n "$node_ip" ]]; then
        sedi "s|server: https://${cluster_ip}|server: https://${node_ip}:${node_port}|" "$K3K_KUBECONFIG"
        info "k3k kubeconfig: https://${node_ip}:${node_port}"
    fi

    K3K_CMD="kubectl --kubeconfig=$K3K_KUBECONFIG --insecure-skip-tls-verify"

    if ! $K3K_CMD get nodes &>/dev/null; then
        err "Cannot connect to k3k cluster"
        rm -f "$K3K_KUBECONFIG"
        return 1
    fi

    log "Connected to k3k virtual cluster"
}

# Verify Rancher is running and responsive.
# Usage: verify_rancher_running
verify_rancher_running() {
    local cmd="${KUBECTL_CMD:-kubectl}"

    if ! $cmd get deploy rancher -n cattle-system &>/dev/null; then
        err "Rancher deployment not found in cattle-system"
        return 1
    fi

    local ready
    ready=$($cmd get deploy rancher -n cattle-system \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [[ "${ready:-0}" -lt 1 ]]; then
        err "No Rancher pods are ready"
        return 1
    fi

    log "Rancher is running (${ready} ready replicas)"
}

# Load config from a config file (key=value format).
# Usage: load_config_file <path>
load_config_file() {
    local config_file="$1"
    if [[ ! -f "$config_file" ]]; then
        err "Config file not found: $config_file"
        return 1
    fi
    # shellcheck source=/dev/null
    source "$config_file"
}
