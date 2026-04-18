#!/usr/bin/env bash
set -euo pipefail

# Universal Rancher Restore using rancher-backup operator
#
# Restores Rancher state from an etcd-level backup created by the rancher-backup
# operator. Works with any Rancher cluster: k3k, RKE2, K3s, or Docker.
#
# Two modes:
#   Mode A — Data-only restore (Rancher already running)
#   Mode B — Full deploy + restore (--deploy-rancher, builds from scratch)
#
# Usage:
#   # Mode A: restore into existing Rancher
#   ./rancher-restore.sh --backup-file rancher-backup-20260217.tar.gz \
#       --s3-bucket my-bucket --s3-endpoint minio:9000 \
#       --s3-access-key KEY --s3-secret-key SECRET
#
#   # Mode B: deploy + restore (k3k)
#   ./rancher-restore.sh --deploy-rancher --backup-file rancher-backup-20260217.tar.gz \
#       --hostname rancher.example.com --bootstrap-pw admin1234567 \
#       --s3-bucket my-bucket --s3-endpoint minio:9000 \
#       --s3-access-key KEY --s3-secret-key SECRET
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

# Backup file
BACKUP_FILE=""

# S3 storage
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

# Encryption
ENCRYPT=""
ENCRYPTION_SECRET="backup-encryption"
ENCRYPTION_KEY=""

# Restore options
RESTORE_PRUNE="false"
RESTORE_NAME=""

# Deploy mode
DEPLOY_RANCHER=""
HOSTNAME=""
BOOTSTRAP_PW=""
TLS_SOURCE="rancher"
CERTMANAGER_VERSION="v1.18.5"
CERTMANAGER_REPO="https://charts.jetstack.io"
RANCHER_VERSION="v2.13.2"
RANCHER_REPO="https://releases.rancher.com/server-charts/latest"

# k3k-specific deploy options
TARGET_TYPE=""
K3K_NAMESPACE="rancher-k3k"
K3K_CLUSTER="rancher"
K3K_PVC_SIZE="40Gi"
K3K_STORAGE_CLASS="harvester-longhorn"
K3K_REPO="https://rancher.github.io/k3k"
K3K_VERSION="1.0.2-rc2"

# Operator
SKIP_OPERATOR_INSTALL=""
OPERATOR_VERSION=""
WAIT_TIMEOUT=600

# Other
DRY_RUN=false
CONFIG_FILE=""

# =============================================================================
# Parse arguments
# =============================================================================
usage() {
    cat <<EOF
Usage: $0 --backup-file <filename> [options]

Cluster access:
  --kubeconfig <path>         Path to kubeconfig file
  --context <name>            Kubernetes context to use
  --namespace <ns>            Operator namespace (default: cattle-resources-system)

Restore source:
  --backup-file <filename>    Backup filename (required, e.g. rancher-backup-xxx.tar.gz)

S3 storage:
  --storage s3                Storage type (only s3 supported)
  --s3-bucket <name>          S3 bucket name
  --s3-endpoint <host:port>   S3 endpoint
  --s3-region <region>        S3 region
  --s3-folder <path>          Folder prefix within the bucket
  --s3-access-key <key>       S3 access key
  --s3-secret-key <key>       S3 secret key
  --s3-insecure-tls           Skip TLS verification for S3
  --s3-endpoint-ca <path>     CA certificate for S3 endpoint

Encryption:
  --encrypt                   Backup was encrypted
  --encryption-secret <name>  Encryption Secret name (default: backup-encryption)
  --encryption-key <key>      Encryption key (must match backup)

Restore options:
  --prune                     Delete resources not in backup
  --restore-name <name>       Custom Restore CR name

Deploy mode (Mode B):
  --deploy-rancher            Full deploy mode — install Rancher before restore
  --hostname <fqdn>           Rancher hostname (required with --deploy-rancher)
  --bootstrap-pw <password>   Bootstrap password (required with --deploy-rancher)
  --tls-source <source>       TLS source: rancher, letsEncrypt, secret (default: rancher)
  --certmanager-version <ver> cert-manager version (default: v1.18.5)
  --certmanager-repo <url>    cert-manager Helm repo
  --rancher-version <ver>     Rancher version (default: v2.13.2)
  --rancher-repo <url>        Rancher Helm repo

Target type:
  --target-type <type>        Target cluster type: k3k or standalone (default: auto-detect)

k3k-specific (deploy mode):
  --k3k-namespace <ns>        k3k namespace (default: rancher-k3k)
  --k3k-cluster <name>        k3k cluster name (default: rancher)
  --k3k-pvc-size <size>       k3k PVC size (default: 40Gi)
  --k3k-storage-class <sc>    k3k storage class (default: harvester-longhorn)
  --k3k-repo <url>            k3k Helm repo
  --k3k-version <ver>         k3k version (default: 1.0.2-rc2)

Operator:
  --skip-operator-install     Don't install the rancher-backup operator
  --operator-version <ver>    Operator Helm chart version

Other:
  --wait-timeout <seconds>    Timeout for restore (default: 600)
  -c, --config <file>         Load options from config file
  --dry-run                   Show what would be done without executing
  -h, --help                  Show this help
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --kubeconfig)            OPT_KUBECONFIG="$2"; shift 2 ;;
        --context)               OPT_CONTEXT="$2"; shift 2 ;;
        --namespace)             OPT_NAMESPACE="$2"; shift 2 ;;
        --backup-file)           BACKUP_FILE="$2"; shift 2 ;;
        --storage)               STORAGE_TYPE="$2"; shift 2 ;;
        --s3-bucket)             S3_BUCKET="$2"; shift 2 ;;
        --s3-endpoint)           S3_ENDPOINT="$2"; shift 2 ;;
        --s3-region)             S3_REGION="$2"; shift 2 ;;
        --s3-folder)             S3_FOLDER="$2"; shift 2 ;;
        --s3-access-key)         S3_ACCESS_KEY="$2"; shift 2 ;;
        --s3-secret-key)         S3_SECRET_KEY="$2"; shift 2 ;;
        --s3-insecure-tls)       S3_INSECURE_TLS="true"; shift ;;
        --s3-endpoint-ca)        S3_ENDPOINT_CA="$2"; shift 2 ;;
        --encrypt)               ENCRYPT="true"; shift ;;
        --encryption-secret)     ENCRYPTION_SECRET="$2"; shift 2 ;;
        --encryption-key)        ENCRYPTION_KEY="$2"; shift 2 ;;
        --prune)                 RESTORE_PRUNE="true"; shift ;;
        --restore-name)          RESTORE_NAME="$2"; shift 2 ;;
        --deploy-rancher)        DEPLOY_RANCHER="true"; shift ;;
        --hostname)              HOSTNAME="$2"; shift 2 ;;
        --bootstrap-pw)          BOOTSTRAP_PW="$2"; shift 2 ;;
        --tls-source)            TLS_SOURCE="$2"; shift 2 ;;
        --certmanager-version)   CERTMANAGER_VERSION="$2"; shift 2 ;;
        --certmanager-repo)      CERTMANAGER_REPO="$2"; shift 2 ;;
        --rancher-version)       RANCHER_VERSION="$2"; shift 2 ;;
        --rancher-repo)          RANCHER_REPO="$2"; shift 2 ;;
        --target-type)           TARGET_TYPE="$2"; shift 2 ;;
        --k3k-namespace)         K3K_NAMESPACE="$2"; shift 2 ;;
        --k3k-cluster)           K3K_CLUSTER="$2"; shift 2 ;;
        --k3k-pvc-size)          K3K_PVC_SIZE="$2"; shift 2 ;;
        --k3k-storage-class)     K3K_STORAGE_CLASS="$2"; shift 2 ;;
        --k3k-repo)              K3K_REPO="$2"; shift 2 ;;
        --k3k-version)           K3K_VERSION="$2"; shift 2 ;;
        --skip-operator-install) SKIP_OPERATOR_INSTALL="true"; shift ;;
        --operator-version)      OPERATOR_VERSION="$2"; shift 2 ;;
        --wait-timeout)          WAIT_TIMEOUT="$2"; shift 2 ;;
        -c|--config)             CONFIG_FILE="$2"; shift 2 ;;
        --dry-run)               DRY_RUN=true; shift ;;
        -h|--help)               usage ;;
        *) err "Unknown argument: $1"; exit 1 ;;
    esac
done

# Load config file
if [[ -n "$CONFIG_FILE" ]]; then
    load_config_file "$CONFIG_FILE"
fi

# =============================================================================
# Validation
# =============================================================================
if [[ -z "$BACKUP_FILE" ]]; then
    err "--backup-file is required"
    exit 1
fi

if [[ -n "$S3_BUCKET" ]]; then
    STORAGE_TYPE="s3"
fi

if [[ "$ENCRYPT" == "true" && -z "$ENCRYPTION_KEY" ]]; then
    err "--encryption-key is required when --encrypt is set"
    exit 1
fi

if [[ "$DEPLOY_RANCHER" == "true" ]]; then
    if [[ -z "$HOSTNAME" ]]; then
        err "--hostname is required with --deploy-rancher"
        exit 1
    fi
    if [[ -z "$BOOTSTRAP_PW" ]]; then
        err "--bootstrap-pw is required with --deploy-rancher"
        exit 1
    fi
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

# Auto-generate restore name if not set
if [[ -z "$RESTORE_NAME" ]]; then
    RESTORE_NAME="rancher-restore-$(date +%Y%m%d-%H%M%S)"
fi

# =============================================================================
# Build kubectl command
# =============================================================================
build_kubectl_cmd
ORIGINAL_KUBECTL_CMD="$KUBECTL_CMD"

echo -e "${CYAN}=============================================${NC}"
if [[ "$DEPLOY_RANCHER" == "true" ]]; then
    echo -e "${CYAN} Universal Rancher Restore (Deploy Mode)${NC}"
else
    echo -e "${CYAN} Universal Rancher Restore${NC}"
fi
echo -e "${CYAN}=============================================${NC}"
echo ""
echo -e "  ${CYAN}Backup file:${NC}    $BACKUP_FILE"
[[ "$STORAGE_TYPE" == "s3" ]] && echo -e "  ${CYAN}S3 bucket:${NC}      $S3_BUCKET"
[[ -n "$S3_ENDPOINT" ]] && echo -e "  ${CYAN}S3 endpoint:${NC}    $S3_ENDPOINT"
[[ "$ENCRYPT" == "true" ]] && echo -e "  ${CYAN}Encrypted:${NC}      yes"
[[ "$RESTORE_PRUNE" == "true" ]] && echo -e "  ${CYAN}Prune:${NC}          yes"
if [[ "$DEPLOY_RANCHER" == "true" ]]; then
    echo -e "  ${CYAN}Hostname:${NC}       $HOSTNAME"
    echo -e "  ${CYAN}Rancher:${NC}        $RANCHER_VERSION"
    echo -e "  ${CYAN}cert-manager:${NC}   $CERTMANAGER_VERSION"
fi
echo ""

# =============================================================================
# Detect or set target type
# =============================================================================
if [[ -z "$TARGET_TYPE" ]]; then
    if [[ "$DEPLOY_RANCHER" == "true" ]]; then
        # For deploy mode, check if k3k CRD is present on host
        if $ORIGINAL_KUBECTL_CMD get crd clusters.k3k.io &>/dev/null 2>&1; then
            TARGET_TYPE="k3k"
        else
            TARGET_TYPE="standalone"
        fi
    else
        TARGET_TYPE=$(detect_cluster_type)
    fi
fi
info "Target type: $TARGET_TYPE"

# =============================================================================
# Mode B: Full deploy + restore
# =============================================================================
if [[ "$DEPLOY_RANCHER" == "true" ]]; then
    TOTAL_STEPS=8
    STEP=0

    # --- Step 1: k3k-specific setup (or skip for standalone) ---
    STEP=$((STEP + 1))
    if [[ "$TARGET_TYPE" == "k3k" ]]; then
        info "Step ${STEP}/${TOTAL_STEPS}: Installing k3k controller ($K3K_VERSION)..."

        if $DRY_RUN; then
            info "Dry run — would install k3k controller"
        else
            # Install k3k controller
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

            # Wait for controller
            local_attempts=0
            while ! $ORIGINAL_KUBECTL_CMD get deploy k3k -n k3k-system &>/dev/null; do
                if [[ $local_attempts -ge 24 ]]; then
                    err "Timed out waiting for k3k controller deployment"
                    exit 1
                fi
                local_attempts=$((local_attempts + 1))
                sleep 5
            done
            $ORIGINAL_KUBECTL_CMD wait --for=condition=available deploy/k3k -n k3k-system --timeout=120s
            log "k3k controller is ready"

            # Create k3k virtual cluster
            info "Creating k3k virtual cluster (PVC: $K3K_PVC_SIZE)..."
            $ORIGINAL_KUBECTL_CMD create namespace "$K3K_NAMESPACE" --dry-run=client -o yaml \
                | $ORIGINAL_KUBECTL_CMD apply -f -

            CLUSTER_MANIFEST=$(mktemp)
            sed -e "s|__PVC_SIZE__|${K3K_PVC_SIZE}|g" \
                -e "s|__STORAGE_CLASS__|${K3K_STORAGE_CLASS}|g" \
                -e "s|__SERVER_COUNT__|1|g" \
                "$SCRIPT_DIR/rancher-cluster.yaml" > "$CLUSTER_MANIFEST"
            sedi "/__SECRET_MOUNTS__/d" "$CLUSTER_MANIFEST"
            sedi "/__EXTRA_SERVER_ARGS__/d" "$CLUSTER_MANIFEST"
            $ORIGINAL_KUBECTL_CMD apply -f "$CLUSTER_MANIFEST"
            rm -f "$CLUSTER_MANIFEST"

            # Wait for k3k cluster
            info "Waiting for k3k cluster to be ready..."
            k3k_attempts=0
            while true; do
                STATUS=$($ORIGINAL_KUBECTL_CMD get clusters.k3k.io "$K3K_CLUSTER" -n "$K3K_NAMESPACE" \
                    -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
                if [[ "$STATUS" == "Ready" ]]; then
                    break
                fi
                if [[ $k3k_attempts -ge 60 ]]; then
                    echo ""
                    err "Timed out waiting for k3k cluster (5 minutes). Current status: $STATUS"
                    exit 1
                fi
                k3k_attempts=$((k3k_attempts + 1))
                echo -n "."
                sleep 5
            done
            echo ""
            log "k3k cluster is Ready"

            # Extract kubeconfig
            setup_k3k_kubectl "$K3K_NAMESPACE" "$K3K_CLUSTER"
            KUBECTL_CMD="$K3K_CMD"
        fi
    else
        info "Step ${STEP}/${TOTAL_STEPS}: Standalone mode — skipping k3k setup"
    fi

    # --- Step 2: Deploy cert-manager ---
    STEP=$((STEP + 1))
    info "Step ${STEP}/${TOTAL_STEPS}: Deploying cert-manager ($CERTMANAGER_VERSION)..."

    if $DRY_RUN; then
        info "Dry run — would install cert-manager $CERTMANAGER_VERSION"
    else
        if [[ "$TARGET_TYPE" == "k3k" ]]; then
            # k3k: use HelmChart CR inside vcluster
            CERTMANAGER_MANIFEST=$(mktemp)
            if is_oci "$CERTMANAGER_REPO"; then
                CM_CHART_VALUE="$CERTMANAGER_REPO"
                CM_REPO_LINE=""
            else
                CM_CHART_VALUE="cert-manager"
                CM_REPO_LINE="  repo: ${CERTMANAGER_REPO}"
            fi

            sed -e "s|__CERTMANAGER_CHART__|${CM_CHART_VALUE}|g" \
                -e "s|__CERTMANAGER_VERSION__|${CERTMANAGER_VERSION}|g" \
                "$SCRIPT_DIR/post-install/01-cert-manager.yaml" > "$CERTMANAGER_MANIFEST"

            if [[ -n "$CM_REPO_LINE" ]]; then
                sedi "s|^__CERTMANAGER_REPO_LINE__$|${CM_REPO_LINE}|" "$CERTMANAGER_MANIFEST"
            else
                sedi "/__CERTMANAGER_REPO_LINE__/d" "$CERTMANAGER_MANIFEST"
            fi
            sedi "/__AUTH_SECRET_LINE1__/d" "$CERTMANAGER_MANIFEST"
            sedi "/__AUTH_SECRET_LINE2__/d" "$CERTMANAGER_MANIFEST"
            sedi "/__REPO_CA_LINE1__/d" "$CERTMANAGER_MANIFEST"
            sedi "/__REPO_CA_LINE2__/d" "$CERTMANAGER_MANIFEST"
            sedi "/__EXTRA_CERTMANAGER_VALUES__/d" "$CERTMANAGER_MANIFEST"

            $KUBECTL_CMD apply -f "$CERTMANAGER_MANIFEST"
            rm -f "$CERTMANAGER_MANIFEST"
        else
            # Standalone: use helm install
            helm repo add jetstack "$CERTMANAGER_REPO" --force-update 2>/dev/null || true
            helm repo update jetstack 2>/dev/null || true
            if ! helm status cert-manager -n cert-manager &>/dev/null; then
                helm install cert-manager jetstack/cert-manager \
                    -n cert-manager --create-namespace \
                    --version "$CERTMANAGER_VERSION" \
                    --set crds.enabled=true
            fi
        fi

        # Wait for cert-manager
        info "Waiting for cert-manager..."
        cm_attempts=0
        while ! $KUBECTL_CMD get deploy/cert-manager -n cert-manager &>/dev/null; do
            if [[ $cm_attempts -ge 60 ]]; then
                err "Timed out waiting for cert-manager deployment"
                exit 1
            fi
            cm_attempts=$((cm_attempts + 1))
            sleep 5
        done
        $KUBECTL_CMD wait --for=condition=available deploy/cert-manager -n cert-manager --timeout=300s
        $KUBECTL_CMD wait --for=condition=available deploy/cert-manager-webhook -n cert-manager --timeout=300s
        log "cert-manager is ready"
    fi

    # --- Step 3: Deploy Rancher ---
    STEP=$((STEP + 1))
    info "Step ${STEP}/${TOTAL_STEPS}: Deploying Rancher ($RANCHER_VERSION)..."

    if $DRY_RUN; then
        info "Dry run — would install Rancher $RANCHER_VERSION"
    else
        if [[ "$TARGET_TYPE" == "k3k" ]]; then
            # k3k: use HelmChart CR inside vcluster
            RANCHER_MANIFEST=$(mktemp)
            if is_oci "$RANCHER_REPO"; then
                R_CHART_VALUE="$RANCHER_REPO"
                R_REPO_LINE=""
            else
                R_CHART_VALUE="rancher"
                R_REPO_LINE="  repo: ${RANCHER_REPO}"
            fi

            sed -e "s|__HOSTNAME__|${HOSTNAME}|g" \
                -e "s|__BOOTSTRAP_PW__|${BOOTSTRAP_PW}|g" \
                -e "s|__RANCHER_CHART__|${R_CHART_VALUE}|g" \
                -e "s|__RANCHER_VERSION__|${RANCHER_VERSION}|g" \
                -e "s|__TLS_SOURCE__|${TLS_SOURCE}|g" \
                -e "s|__RANCHER_REPLICAS__|1|g" \
                "$SCRIPT_DIR/post-install/02-rancher.yaml" > "$RANCHER_MANIFEST"

            if [[ -n "$R_REPO_LINE" ]]; then
                sedi "s|^__RANCHER_REPO_LINE__$|${R_REPO_LINE}|" "$RANCHER_MANIFEST"
            else
                sedi "/__RANCHER_REPO_LINE__/d" "$RANCHER_MANIFEST"
            fi
            sedi "/__AUTH_SECRET_LINE1__/d" "$RANCHER_MANIFEST"
            sedi "/__AUTH_SECRET_LINE2__/d" "$RANCHER_MANIFEST"
            sedi "/__REPO_CA_LINE1__/d" "$RANCHER_MANIFEST"
            sedi "/__REPO_CA_LINE2__/d" "$RANCHER_MANIFEST"
            sedi "/__EXTRA_RANCHER_VALUES__/d" "$RANCHER_MANIFEST"

            $KUBECTL_CMD apply -f "$RANCHER_MANIFEST"
            rm -f "$RANCHER_MANIFEST"
        else
            # Standalone: use helm install
            helm repo add rancher-latest "$RANCHER_REPO" --force-update 2>/dev/null || true
            helm repo update rancher-latest 2>/dev/null || true
            if ! helm status rancher -n cattle-system &>/dev/null; then
                $KUBECTL_CMD create namespace cattle-system --dry-run=client -o yaml \
                    | $KUBECTL_CMD apply -f -
                helm install rancher rancher-latest/rancher \
                    -n cattle-system \
                    --version "$RANCHER_VERSION" \
                    --set hostname="$HOSTNAME" \
                    --set bootstrapPassword="$BOOTSTRAP_PW" \
                    --set ingress.tls.source="$TLS_SOURCE" \
                    --set "global.cattle.psp.enabled=false" \
                    --set "features=fleet=false"
            fi
        fi

        # Wait for Rancher
        info "Waiting for Rancher..."
        r_attempts=0
        while ! $KUBECTL_CMD get deploy/rancher -n cattle-system &>/dev/null; do
            if [[ $r_attempts -ge 90 ]]; then
                err "Timed out waiting for Rancher deployment"
                exit 1
            fi
            r_attempts=$((r_attempts + 1))
            sleep 5
        done
        $KUBECTL_CMD wait --for=condition=available deploy/rancher -n cattle-system --timeout=600s
        log "Rancher is running"
    fi

    # --- Step 4: Install rancher-backup operator ---
    STEP=$((STEP + 1))
    if [[ "$SKIP_OPERATOR_INSTALL" != "true" ]]; then
        info "Step ${STEP}/${TOTAL_STEPS}: Installing rancher-backup operator..."
        if ! $DRY_RUN; then
            install_backup_operator "$OPT_NAMESPACE" "$OPERATOR_VERSION"
        else
            info "Dry run — would install rancher-backup operator"
        fi
    else
        info "Step ${STEP}/${TOTAL_STEPS}: Skipping operator install"
    fi

    # --- Step 5: Create Secrets ---
    STEP=$((STEP + 1))
    info "Step ${STEP}/${TOTAL_STEPS}: Creating restore resources..."

    if ! $DRY_RUN; then
        if [[ "$STORAGE_TYPE" == "s3" && -n "$S3_ACCESS_KEY" ]]; then
            create_s3_credentials "$OPT_NAMESPACE" "$S3_CRED_SECRET" "$S3_ACCESS_KEY" "$S3_SECRET_KEY"
        fi

        if [[ "$ENCRYPT" == "true" ]]; then
            create_encryption_secret "$OPT_NAMESPACE" "$ENCRYPTION_SECRET" "$ENCRYPTION_KEY"
        fi
    fi

    # --- Step 6: Apply Restore CR ---
    STEP=$((STEP + 1))
    info "Step ${STEP}/${TOTAL_STEPS}: Applying Restore CR..."

    RESTORE_MANIFEST=$(mktemp)
    render_restore_cr "$RESTORE_MANIFEST"

    if $DRY_RUN; then
        echo ""
        info "Dry run — Restore CR that would be applied:"
        echo "---"
        cat "$RESTORE_MANIFEST"
        echo "---"
        rm -f "$RESTORE_MANIFEST"
        exit 0
    fi

    $KUBECTL_CMD apply -f "$RESTORE_MANIFEST"
    rm -f "$RESTORE_MANIFEST"
    log "Restore CR '$RESTORE_NAME' created"

    # --- Step 7: Wait for restore ---
    STEP=$((STEP + 1))
    info "Step ${STEP}/${TOTAL_STEPS}: Waiting for restore..."
    echo ""
    wait_for_restore "$RESTORE_NAME" "$WAIT_TIMEOUT"
    echo ""

    # --- Step 8: k3k post-restore (TLS cert copy + host ingress) ---
    STEP=$((STEP + 1))
    if [[ "$TARGET_TYPE" == "k3k" ]]; then
        info "Step ${STEP}/${TOTAL_STEPS}: Setting up k3k host ingress..."

        # Wait for TLS secret
        tls_attempts=0
        while ! $KUBECTL_CMD get secret tls-rancher-ingress -n cattle-system &>/dev/null; do
            if [[ $tls_attempts -ge 30 ]]; then
                warn "TLS secret not found after 150s, skipping cert copy"
                break
            fi
            tls_attempts=$((tls_attempts + 1))
            sleep 5
        done

        if $KUBECTL_CMD get secret tls-rancher-ingress -n cattle-system &>/dev/null; then
            TLS_CRT=$($KUBECTL_CMD -n cattle-system get secret tls-rancher-ingress -o jsonpath='{.data.tls\.crt}' | base64 -d)
            TLS_KEY=$($KUBECTL_CMD -n cattle-system get secret tls-rancher-ingress -o jsonpath='{.data.tls\.key}' | base64 -d)

            $ORIGINAL_KUBECTL_CMD -n "$K3K_NAMESPACE" create secret tls tls-rancher-ingress \
                --cert=<(echo "$TLS_CRT") --key=<(echo "$TLS_KEY") \
                --dry-run=client -o yaml | $ORIGINAL_KUBECTL_CMD apply -f -
            log "TLS certificate copied to host cluster"
        fi

        # Create host ingress
        sed "s|__HOSTNAME__|${HOSTNAME}|g" "$SCRIPT_DIR/host-ingress.yaml" \
            | $ORIGINAL_KUBECTL_CMD apply -f -
        log "Host ingress created"

        # Deploy reconciler and watcher
        sed "s|__HOSTNAME__|${HOSTNAME}|g" "$SCRIPT_DIR/ingress-reconciler.yaml" \
            | $ORIGINAL_KUBECTL_CMD apply -f -
        sed "s|__HOSTNAME__|${HOSTNAME}|g" "$SCRIPT_DIR/ingress-watcher.yaml" \
            | $ORIGINAL_KUBECTL_CMD apply -f -
        log "Ingress reconciler and watcher deployed"
    else
        info "Step ${STEP}/${TOTAL_STEPS}: Standalone mode — no post-restore setup needed"
    fi

# =============================================================================
# Mode A: Data-only restore (Rancher already running)
# =============================================================================
else
    TOTAL_STEPS=5
    STEP=0

    # --- Step 1: Detect cluster type + connect ---
    STEP=$((STEP + 1))
    info "Step ${STEP}/${TOTAL_STEPS}: Detecting cluster type..."
    CLUSTER_TYPE=$(detect_cluster_type)
    log "Cluster type: $CLUSTER_TYPE"

    if [[ "$CLUSTER_TYPE" == "k3k" ]]; then
        K3K_NS=$($ORIGINAL_KUBECTL_CMD get clusters.k3k.io -A --no-headers 2>/dev/null \
            | head -1 | awk '{print $1}')
        K3K_CLUSTER_NAME=$($ORIGINAL_KUBECTL_CMD get clusters.k3k.io -n "$K3K_NS" --no-headers 2>/dev/null \
            | head -1 | awk '{print $1}')
        setup_k3k_kubectl "$K3K_NS" "$K3K_CLUSTER_NAME"
        KUBECTL_CMD="$K3K_CMD"
    fi

    # --- Step 2: Verify Rancher ---
    STEP=$((STEP + 1))
    info "Step ${STEP}/${TOTAL_STEPS}: Verifying Rancher..."
    verify_rancher_running

    # --- Step 3: Install operator ---
    STEP=$((STEP + 1))
    if [[ "$SKIP_OPERATOR_INSTALL" != "true" ]]; then
        info "Step ${STEP}/${TOTAL_STEPS}: Installing rancher-backup operator..."
        install_backup_operator "$OPT_NAMESPACE" "$OPERATOR_VERSION"
    else
        info "Step ${STEP}/${TOTAL_STEPS}: Skipping operator install"
    fi

    # --- Step 4: Create Secrets + apply Restore CR ---
    STEP=$((STEP + 1))
    info "Step ${STEP}/${TOTAL_STEPS}: Creating restore resources..."

    if [[ "$STORAGE_TYPE" == "s3" && -n "$S3_ACCESS_KEY" ]]; then
        create_s3_credentials "$OPT_NAMESPACE" "$S3_CRED_SECRET" "$S3_ACCESS_KEY" "$S3_SECRET_KEY"
    fi

    if [[ "$ENCRYPT" == "true" ]]; then
        create_encryption_secret "$OPT_NAMESPACE" "$ENCRYPTION_SECRET" "$ENCRYPTION_KEY"
    fi

    RESTORE_MANIFEST=$(mktemp)
    render_restore_cr "$RESTORE_MANIFEST"

    if $DRY_RUN; then
        echo ""
        info "Dry run — Restore CR that would be applied:"
        echo "---"
        cat "$RESTORE_MANIFEST"
        echo "---"
        rm -f "$RESTORE_MANIFEST"
        exit 0
    fi

    $KUBECTL_CMD apply -f "$RESTORE_MANIFEST"
    rm -f "$RESTORE_MANIFEST"
    log "Restore CR '$RESTORE_NAME' created"

    # --- Step 5: Wait for restore ---
    STEP=$((STEP + 1))
    info "Step ${STEP}/${TOTAL_STEPS}: Waiting for restore..."
    echo ""
    wait_for_restore "$RESTORE_NAME" "$WAIT_TIMEOUT"
    echo ""
fi

# =============================================================================
# Verify Rancher health
# =============================================================================
info "Verifying Rancher health after restore..."
r_health_attempts=0
while true; do
    ready=$($KUBECTL_CMD get deploy rancher -n cattle-system \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [[ "${ready:-0}" -ge 1 ]]; then
        break
    fi
    if [[ $r_health_attempts -ge 60 ]]; then
        warn "Rancher not ready after 5 minutes — may need manual intervention"
        break
    fi
    r_health_attempts=$((r_health_attempts + 1))
    sleep 5
done
if [[ "${ready:-0}" -ge 1 ]]; then
    log "Rancher is healthy (${ready} ready replicas)"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN} Restore Complete${NC}"
echo -e "${GREEN}=========================================${NC}"
echo ""
echo -e "  ${CYAN}Restore name:${NC}    $RESTORE_NAME"
echo -e "  ${CYAN}Backup file:${NC}     $BACKUP_FILE"
echo -e "  ${CYAN}Target type:${NC}     $TARGET_TYPE"
if [[ "$DEPLOY_RANCHER" == "true" && -n "$HOSTNAME" ]]; then
    echo -e "  ${CYAN}Rancher URL:${NC}     https://${HOSTNAME}"
fi
[[ "$RESTORE_PRUNE" == "true" ]] && echo -e "  ${CYAN}Pruned:${NC}          yes"
echo ""
if [[ "$DEPLOY_RANCHER" == "true" ]]; then
    echo -e "  ${YELLOW}NOTE:${NC} Restored Rancher state includes users, settings, and cluster"
    echo -e "  registrations. Downstream clusters may need their agents re-deployed"
    echo -e "  if the Rancher URL or certificates have changed."
fi
echo ""

# Clean up k3k kubeconfig if used
if [[ -n "${K3K_KUBECONFIG:-}" ]]; then
    rm -f "$K3K_KUBECONFIG"
fi
