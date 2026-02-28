#!/usr/bin/env bash
set -euo pipefail

# Universal Rancher Backup using rancher-backup operator
#
# Creates an etcd-level backup of Rancher state (users, RBAC, fleet, clusters,
# settings, tokens, cloud credentials, etc.) using the official rancher-backup
# operator. Works with any Rancher cluster: k3k, RKE2, K3s, or Docker.
#
# Usage:
#   ./rancher-backup.sh --s3-bucket my-bucket --s3-endpoint minio:9000 \
#       --s3-access-key KEY --s3-secret-key SECRET
#
#   ./rancher-backup.sh -c backup.conf
#
# See docs/universal-backup-restore.md for the full guide.

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

# shellcheck source=backup-lib.sh
source "$SCRIPT_DIR/backup-lib.sh"

# =============================================================================
# Default values
# =============================================================================
OPT_KUBECONFIG=""
OPT_CONTEXT=""
OPT_NAMESPACE="cattle-resources-system"
STORAGE_TYPE=""
S3_BUCKET=""
S3_ENDPOINT=""
S3_REGION=""
S3_FOLDER=""
S3_ACCESS_KEY=""
S3_SECRET_KEY=""
S3_INSECURE_TLS="false"
S3_ENDPOINT_CA=""
S3_CRED_SECRET="s3-credentials"
ENCRYPT=""
ENCRYPTION_SECRET="backup-encryption"
ENCRYPTION_KEY=""
RESOURCE_SET="rancher-resource-set"
BACKUP_SCHEDULE=""
BACKUP_RETENTION=""
BACKUP_NAME=""
SKIP_OPERATOR_INSTALL=""
OPERATOR_VERSION=""
WAIT_TIMEOUT=600
OUTPUT_DIR=""
DRY_RUN=false
CONFIG_FILE=""

# =============================================================================
# Parse arguments
# =============================================================================
usage() {
    cat <<EOF
Usage: $0 [options]

Cluster access:
  --kubeconfig <path>       Path to kubeconfig file
  --context <name>          Kubernetes context to use
  --namespace <ns>          Operator namespace (default: cattle-resources-system)

S3 storage:
  --storage s3              Storage type (only s3 supported)
  --s3-bucket <name>        S3 bucket name (required for S3)
  --s3-endpoint <host:port> S3 endpoint (e.g. minio.example.com:9000)
  --s3-region <region>      S3 region (e.g. us-east-1)
  --s3-folder <path>        Folder prefix within the bucket
  --s3-access-key <key>     S3 access key
  --s3-secret-key <key>     S3 secret key
  --s3-insecure-tls         Skip TLS verification for S3
  --s3-endpoint-ca <path>   CA certificate for S3 endpoint

Encryption:
  --encrypt                 Enable backup encryption
  --encryption-secret <n>   Encryption Secret name (default: backup-encryption)
  --encryption-key <key>    Encryption key (base64-encoded 32-byte key)

Backup options:
  --resource-set <name>     ResourceSet name (default: rancher-resource-set)
  --schedule <cron>         Cron schedule for recurring backups
  --retention <count>       Number of backups to retain
  --backup-name <name>      Custom backup CR name

Operator:
  --skip-operator-install   Don't install the rancher-backup operator
  --operator-version <ver>  Operator Helm chart version

Other:
  --wait-timeout <seconds>  Timeout for backup completion (default: 600)
  --output <path>           Directory for metadata sidecar export
  -c, --config <file>       Load options from config file
  --dry-run                 Render CR and show what would be done
  -h, --help                Show this help
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --kubeconfig)          OPT_KUBECONFIG="$2"; shift 2 ;;
        --context)             OPT_CONTEXT="$2"; shift 2 ;;
        --namespace)           OPT_NAMESPACE="$2"; shift 2 ;;
        --storage)             STORAGE_TYPE="$2"; shift 2 ;;
        --s3-bucket)           S3_BUCKET="$2"; shift 2 ;;
        --s3-endpoint)         S3_ENDPOINT="$2"; shift 2 ;;
        --s3-region)           S3_REGION="$2"; shift 2 ;;
        --s3-folder)           S3_FOLDER="$2"; shift 2 ;;
        --s3-access-key)       S3_ACCESS_KEY="$2"; shift 2 ;;
        --s3-secret-key)       S3_SECRET_KEY="$2"; shift 2 ;;
        --s3-insecure-tls)     S3_INSECURE_TLS="true"; shift ;;
        --s3-endpoint-ca)      S3_ENDPOINT_CA="$2"; shift 2 ;;
        --encrypt)             ENCRYPT="true"; shift ;;
        --encryption-secret)   ENCRYPTION_SECRET="$2"; shift 2 ;;
        --encryption-key)      ENCRYPTION_KEY="$2"; shift 2 ;;
        --resource-set)        RESOURCE_SET="$2"; shift 2 ;;
        --schedule)            BACKUP_SCHEDULE="$2"; shift 2 ;;
        --retention)           BACKUP_RETENTION="$2"; shift 2 ;;
        --backup-name)         BACKUP_NAME="$2"; shift 2 ;;
        --skip-operator-install) SKIP_OPERATOR_INSTALL="true"; shift ;;
        --operator-version)    OPERATOR_VERSION="$2"; shift 2 ;;
        --wait-timeout)        WAIT_TIMEOUT="$2"; shift 2 ;;
        --output|-o)           OUTPUT_DIR="$2"; shift 2 ;;
        -c|--config)           CONFIG_FILE="$2"; shift 2 ;;
        --dry-run)             DRY_RUN=true; shift ;;
        -h|--help)             usage ;;
        *) err "Unknown argument: $1"; exit 1 ;;
    esac
done

# Load config file (values can be overridden by CLI flags above)
if [[ -n "$CONFIG_FILE" ]]; then
    load_config_file "$CONFIG_FILE"
fi

# =============================================================================
# Validation
# =============================================================================
if [[ -n "$S3_BUCKET" ]]; then
    STORAGE_TYPE="s3"
fi

if [[ "$STORAGE_TYPE" == "s3" && -z "$S3_BUCKET" ]]; then
    err "--s3-bucket is required when using S3 storage"
    exit 1
fi

if [[ "$ENCRYPT" == "true" && -z "$ENCRYPTION_KEY" ]]; then
    err "--encryption-key is required when --encrypt is set"
    exit 1
fi

if [[ -n "$S3_ENDPOINT_CA" && ! -f "$S3_ENDPOINT_CA" ]]; then
    err "S3 endpoint CA file not found: $S3_ENDPOINT_CA"
    exit 1
fi

for cmd in kubectl helm jq; do
    if ! command -v "$cmd" &>/dev/null; then
        err "Required command not found: $cmd"
        exit 1
    fi
done

# Auto-generate backup name if not set
if [[ -z "$BACKUP_NAME" ]]; then
    BACKUP_NAME="rancher-backup-$(date +%Y%m%d-%H%M%S)"
fi

# =============================================================================
# Build kubectl command
# =============================================================================
build_kubectl_cmd
ORIGINAL_KUBECTL_CMD="$KUBECTL_CMD"

echo -e "${CYAN}=============================================${NC}"
echo -e "${CYAN} Universal Rancher Backup${NC}"
echo -e "${CYAN}=============================================${NC}"
echo ""

# =============================================================================
# Step 1: Detect cluster type
# =============================================================================
info "Step 1/6: Detecting cluster type..."
CLUSTER_TYPE=$(detect_cluster_type)
log "Cluster type: $CLUSTER_TYPE"

# =============================================================================
# Step 2: Handle k3k — extract vcluster kubeconfig
# =============================================================================
if [[ "$CLUSTER_TYPE" == "k3k" ]]; then
    info "Step 2/6: Extracting k3k virtual cluster kubeconfig..."

    # Detect k3k namespace and cluster name
    K3K_NS=$(${ORIGINAL_KUBECTL_CMD} get clusters.k3k.io -A --no-headers 2>/dev/null \
        | head -1 | awk '{print $1}')
    K3K_CLUSTER=$(${ORIGINAL_KUBECTL_CMD} get clusters.k3k.io -n "$K3K_NS" --no-headers 2>/dev/null \
        | head -1 | awk '{print $1}')
    info "k3k cluster: $K3K_CLUSTER in namespace $K3K_NS"

    setup_k3k_kubectl "$K3K_NS" "$K3K_CLUSTER"
    KUBECTL_CMD="$K3K_CMD"
else
    info "Step 2/6: Standalone cluster — using direct access"
fi

# =============================================================================
# Step 3: Verify Rancher is running
# =============================================================================
info "Step 3/6: Verifying Rancher..."
verify_rancher_running

# =============================================================================
# Step 4: Install rancher-backup operator
# =============================================================================
if [[ "$SKIP_OPERATOR_INSTALL" != "true" ]]; then
    info "Step 4/6: Installing rancher-backup operator..."
    install_backup_operator "$OPT_NAMESPACE" "$OPERATOR_VERSION"
else
    info "Step 4/6: Skipping operator install (--skip-operator-install)"
fi

# =============================================================================
# Step 5: Create Secrets + render Backup CR
# =============================================================================
info "Step 5/6: Creating resources..."

# Create S3 credentials Secret
if [[ "$STORAGE_TYPE" == "s3" && -n "$S3_ACCESS_KEY" ]]; then
    create_s3_credentials "$OPT_NAMESPACE" "$S3_CRED_SECRET" "$S3_ACCESS_KEY" "$S3_SECRET_KEY"
fi

# Create encryption Secret
if [[ "$ENCRYPT" == "true" ]]; then
    create_encryption_secret "$OPT_NAMESPACE" "$ENCRYPTION_SECRET" "$ENCRYPTION_KEY"
fi

# Render Backup CR
BACKUP_MANIFEST=$(mktemp)
render_backup_cr "$BACKUP_MANIFEST"

if $DRY_RUN; then
    echo ""
    info "Dry run — Backup CR that would be applied:"
    echo "---"
    cat "$BACKUP_MANIFEST"
    echo "---"
    rm -f "$BACKUP_MANIFEST"
    exit 0
fi

# Apply Backup CR
$KUBECTL_CMD apply -f "$BACKUP_MANIFEST"
rm -f "$BACKUP_MANIFEST"
log "Backup CR '$BACKUP_NAME' created"

# =============================================================================
# Step 6: Wait for backup completion
# =============================================================================
info "Step 6/6: Waiting for backup..."
echo ""
wait_for_backup "$BACKUP_NAME" "$WAIT_TIMEOUT"
echo ""

# Get backup filename
BACKUP_FILENAME=$($KUBECTL_CMD get backups.resources.cattle.io "$BACKUP_NAME" \
    -o jsonpath='{.status.filename}' 2>/dev/null || echo "unknown")

# =============================================================================
# Export metadata sidecar
# =============================================================================
if [[ -n "$OUTPUT_DIR" ]]; then
    mkdir -p "$OUTPUT_DIR"

    # Detect Rancher version
    RANCHER_VERSION=$($KUBECTL_CMD get deploy rancher -n cattle-system \
        -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null \
        | sed 's/.*://' || echo "unknown")

    # Detect hostname
    RANCHER_HOSTNAME=$($KUBECTL_CMD get ingress -n cattle-system -o jsonpath='{.items[0].spec.rules[0].host}' 2>/dev/null || echo "unknown")

    jq -n \
        --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg cluster_type "$CLUSTER_TYPE" \
        --arg rancher_version "$RANCHER_VERSION" \
        --arg hostname "$RANCHER_HOSTNAME" \
        --arg backup_name "$BACKUP_NAME" \
        --arg backup_filename "$BACKUP_FILENAME" \
        --arg storage_type "${STORAGE_TYPE:-local}" \
        --arg s3_bucket "$S3_BUCKET" \
        --arg s3_endpoint "$S3_ENDPOINT" \
        --arg s3_folder "$S3_FOLDER" \
        '{
            backup_timestamp: $timestamp,
            cluster_type: $cluster_type,
            rancher_version: $rancher_version,
            hostname: $hostname,
            backup_name: $backup_name,
            backup_filename: $backup_filename,
            storage: {
                type: $storage_type,
                s3_bucket: $s3_bucket,
                s3_endpoint: $s3_endpoint,
                s3_folder: $s3_folder
            }
        }' > "$OUTPUT_DIR/backup-metadata.json"

    log "Metadata exported to $OUTPUT_DIR/backup-metadata.json"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN} Backup Complete${NC}"
echo -e "${GREEN}=========================================${NC}"
echo ""
echo -e "  ${CYAN}Backup name:${NC}     $BACKUP_NAME"
echo -e "  ${CYAN}Backup file:${NC}     $BACKUP_FILENAME"
echo -e "  ${CYAN}Cluster type:${NC}    $CLUSTER_TYPE"
if [[ "$STORAGE_TYPE" == "s3" ]]; then
    echo -e "  ${CYAN}S3 bucket:${NC}       $S3_BUCKET"
    [[ -n "$S3_ENDPOINT" ]] && echo -e "  ${CYAN}S3 endpoint:${NC}     $S3_ENDPOINT"
    [[ -n "$S3_FOLDER" ]] && echo -e "  ${CYAN}S3 folder:${NC}       $S3_FOLDER"
fi
[[ "$ENCRYPT" == "true" ]] && echo -e "  ${CYAN}Encrypted:${NC}       yes"
if [[ -n "$BACKUP_SCHEDULE" ]]; then
    echo -e "  ${CYAN}Schedule:${NC}        $BACKUP_SCHEDULE"
    echo -e "  ${CYAN}Retention:${NC}       ${BACKUP_RETENTION:-unlimited}"
fi
echo ""
echo "  To restore from this backup:"
echo "    ./rancher-restore.sh --backup-file $BACKUP_FILENAME \\"
if [[ "$STORAGE_TYPE" == "s3" ]]; then
    echo "        --s3-bucket $S3_BUCKET \\"
    [[ -n "$S3_ENDPOINT" ]] && echo "        --s3-endpoint $S3_ENDPOINT \\"
    echo "        --s3-access-key <key> --s3-secret-key <secret>"
fi
[[ "$ENCRYPT" == "true" ]] && echo "        --encrypt --encryption-key <key>"
echo ""

# Clean up k3k kubeconfig if used
if [[ "$CLUSTER_TYPE" == "k3k" && -n "${K3K_KUBECONFIG:-}" ]]; then
    rm -f "$K3K_KUBECONFIG"
fi
