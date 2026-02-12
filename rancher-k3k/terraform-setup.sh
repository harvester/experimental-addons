#!/usr/bin/env bash
set -euo pipefail

# Post-deployment setup for Terraform access to Rancher on k3k
#
# Run this after:
#   1. deploy.sh completed successfully
#   2. Rancher bootstrap finished via the UI (admin password set)
#   3. (Optional) Harvester imported into Rancher via Virtualization Management
#
# Outputs:
#   - kubeconfig-k3k.yaml       — kubectl access to the k3k virtual cluster
#   - kubeconfig-harvester.yaml — Harvester kubeconfig (if cluster imported)
#   - terraform.tfvars          — Rancher API credentials for Terraform
#
# All output files are covered by .gitignore and must not be committed.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K3K_NS="rancher-k3k"
K3K_CLUSTER="rancher"

# Restrict file permissions — output files contain secrets
umask 077

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

# =============================================================================
# Prerequisites
# =============================================================================
for cmd in kubectl jq curl; do
    if ! command -v "$cmd" &>/dev/null; then
        err "Required command not found: $cmd"
        exit 1
    fi
done

# =============================================================================
# Step 1: Verify existing deployment
# =============================================================================
echo -e "${CYAN}=============================================${NC}"
echo -e "${CYAN} Rancher on k3k — Terraform Setup${NC}"
echo -e "${CYAN}=============================================${NC}"
echo ""

log "Checking for existing k3k deployment..."

if ! kubectl get clusters.k3k.io "$K3K_CLUSTER" -n "$K3K_NS" &>/dev/null; then
    err "k3k cluster '$K3K_CLUSTER' not found in namespace '$K3K_NS'"
    err "Run deploy.sh first"
    exit 1
fi

STATUS=$(kubectl get clusters.k3k.io "$K3K_CLUSTER" -n "$K3K_NS" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
if [[ "$STATUS" != "Ready" ]]; then
    err "k3k cluster is not Ready (current: $STATUS)"
    exit 1
fi
log "k3k cluster is Ready"

# Detect hostname from ingress
HOSTNAME=$(kubectl get ingress rancher-k3k-ingress -n "$K3K_NS" \
    -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || echo "")
if [[ -z "$HOSTNAME" ]]; then
    read -rp "Could not detect hostname. Enter Rancher hostname: " HOSTNAME
    if [[ -z "$HOSTNAME" ]]; then
        err "Hostname is required"
        exit 1
    fi
fi
log "Rancher hostname: $HOSTNAME"
RANCHER_URL="https://${HOSTNAME}"

# Connectivity check
if ! curl -sk --connect-timeout 5 "${RANCHER_URL}/ping" &>/dev/null; then
    warn "Cannot reach ${RANCHER_URL}/ping"
    read -rp "Continue anyway? (yes/no) [no]: " CONT
    if [[ "${CONT:-no}" != "yes" ]]; then
        exit 1
    fi
fi

# =============================================================================
# Step 2: Extract k3k kubeconfig
# =============================================================================
echo ""
log "Step 1/4: Extracting k3k virtual cluster kubeconfig..."

KUBECONFIG_FILE="${SCRIPT_DIR}/kubeconfig-k3k.yaml"

kubectl get secret "k3k-${K3K_CLUSTER}-kubeconfig" -n "$K3K_NS" \
    -o jsonpath='{.data.kubeconfig\.yaml}' | base64 -d > "$KUBECONFIG_FILE"

# Replace ClusterIP with NodePort address for external access
CLUSTER_IP=$(sed -n 's/.*server: https:\/\/\([^:]*\).*/\1/p' "$KUBECONFIG_FILE")
NODE_PORT=$(kubectl get svc "k3k-${K3K_CLUSTER}-service" -n "$K3K_NS" \
    -o jsonpath='{.spec.ports[?(@.port==443)].nodePort}')
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

if [[ -n "$NODE_PORT" && -n "$NODE_IP" ]]; then
    sedi "s|server: https://${CLUSTER_IP}|server: https://${NODE_IP}:${NODE_PORT}|" "$KUBECONFIG_FILE"
    log "Kubeconfig server: https://${NODE_IP}:${NODE_PORT}"
else
    warn "Could not determine NodePort — kubeconfig uses ClusterIP (cluster-internal only)"
fi
log "Saved: $KUBECONFIG_FILE"

# =============================================================================
# Step 3: Authenticate to Rancher and create API token
# =============================================================================
echo ""
log "Step 2/4: Authenticating to Rancher API..."
echo "  Enter your Rancher admin credentials (set during UI bootstrap)."
echo ""

read -rp "Username [admin]: " RANCHER_USER
RANCHER_USER="${RANCHER_USER:-admin}"
read -rsp "Password: " RANCHER_PASS
echo ""

if [[ -z "$RANCHER_PASS" ]]; then
    err "Password is required"
    exit 1
fi

# Build JSON with jq to prevent injection from special characters in credentials.
# Pipe via stdin (-d @-) so the password never appears in the process list.
LOGIN_RESPONSE=$(jq -n --arg u "$RANCHER_USER" --arg p "$RANCHER_PASS" \
    '{username: $u, password: $p}' | \
    curl -sk "${RANCHER_URL}/v3-public/localProviders/local?action=login" \
    -H 'Content-Type: application/json' \
    -d @-)

LOGIN_TOKEN=$(echo "$LOGIN_RESPONSE" | jq -r '.token // empty')
if [[ -z "$LOGIN_TOKEN" ]]; then
    err "Login failed:"
    echo "$LOGIN_RESPONSE" | jq . 2>/dev/null || echo "$LOGIN_RESPONSE"
    exit 1
fi
log "Authenticated"

echo ""
log "Step 3/4: Creating Rancher API token..."

read -rp "Token description [terraform]: " TOKEN_DESC
TOKEN_DESC="${TOKEN_DESC:-terraform}"

TOKEN_RESPONSE=$(jq -n --arg desc "$TOKEN_DESC" \
    '{type: "token", description: $desc, ttl: 0}' | \
    curl -sk "${RANCHER_URL}/v3/tokens" \
    -H "Authorization: Bearer ${LOGIN_TOKEN}" \
    -H 'Content-Type: application/json' \
    -d @-)

API_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.token // empty')
if [[ -z "$API_TOKEN" ]]; then
    err "Failed to create API token:"
    echo "$TOKEN_RESPONSE" | jq . 2>/dev/null || echo "$TOKEN_RESPONSE"
    exit 1
fi

TOKEN_NAME=$(echo "$TOKEN_RESPONSE" | jq -r '.name // empty')
log "API token created: $TOKEN_NAME (no expiry)"

# =============================================================================
# Step 4: Detect Harvester cluster and generate kubeconfig
# =============================================================================
echo ""
log "Step 4/4: Detecting Harvester cluster in Rancher..."

CLUSTERS_JSON=$(curl -sk "${RANCHER_URL}/v3/clusters" \
    -H "Authorization: Bearer ${LOGIN_TOKEN}")

# Harvester appears with provider.cattle.io=harvester label when imported
HARVESTER_CLUSTER_ID=""
HARVESTER_CLUSTER_NAME=""
HARVESTER_KC_FILE=""

HARVESTER_INFO=$(echo "$CLUSTERS_JSON" | jq -r '
    .data[] |
    select(
        (.labels["provider.cattle.io"] == "harvester") or
        (.driver == "harvester")
    ) |
    "\(.id)\t\(.name)"' 2>/dev/null | head -1)

if [[ -n "$HARVESTER_INFO" ]]; then
    HARVESTER_CLUSTER_ID=$(echo "$HARVESTER_INFO" | cut -f1)
    HARVESTER_CLUSTER_NAME=$(echo "$HARVESTER_INFO" | cut -f2)
    log "Found Harvester cluster: $HARVESTER_CLUSTER_NAME ($HARVESTER_CLUSTER_ID)"

    # Generate kubeconfig for Terraform cloud credentials
    HARVESTER_KC_RESPONSE=$(curl -sk \
        "${RANCHER_URL}/v3/clusters/${HARVESTER_CLUSTER_ID}?action=generateKubeconfig" \
        -H "Authorization: Bearer ${LOGIN_TOKEN}" \
        -X POST)

    HARVESTER_KC=$(echo "$HARVESTER_KC_RESPONSE" | jq -r '.config // empty')
    if [[ -n "$HARVESTER_KC" ]]; then
        HARVESTER_KC_FILE="${SCRIPT_DIR}/kubeconfig-harvester.yaml"
        echo "$HARVESTER_KC" > "$HARVESTER_KC_FILE"
        log "Harvester kubeconfig saved: $HARVESTER_KC_FILE"
    else
        warn "Could not generate Harvester kubeconfig"
        warn "You may need cluster-owner permissions on the imported Harvester cluster"
    fi
else
    CLUSTER_LIST=$(echo "$CLUSTERS_JSON" | jq -r '.data[] | "    \(.name) (\(.id))"' 2>/dev/null)
    warn "No Harvester-type cluster found in Rancher."
    if [[ -n "$CLUSTER_LIST" ]]; then
        echo "  Clusters visible:"
        echo "$CLUSTER_LIST"
    fi
    echo ""
    echo "  To import Harvester into Rancher:"
    echo "    1. Rancher UI → Virtualization Management → Import Existing"
    echo "    2. Enter the Harvester VIP URL and register the cluster"
    echo "    3. Re-run this script to generate the Harvester kubeconfig"
fi

# =============================================================================
# Save terraform.tfvars
# =============================================================================
TFVARS_FILE="${SCRIPT_DIR}/terraform.tfvars"
{
    echo "# Generated by terraform-setup.sh — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# WARNING: Contains secrets. Do not commit to version control."
    echo ""
    echo "rancher_url   = \"${RANCHER_URL}\""
    echo "rancher_token = \"${API_TOKEN}\""
    if [[ -n "$HARVESTER_CLUSTER_ID" ]]; then
        echo "harvester_cluster_id = \"${HARVESTER_CLUSTER_ID}\""
    fi
} > "$TFVARS_FILE"

# =============================================================================
# Output summary
# =============================================================================
echo ""
echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN} Terraform Setup Complete${NC}"
echo -e "${GREEN}=========================================${NC}"
echo ""
echo -e "${CYAN}k3k Virtual Cluster (kubectl):${NC}"
echo "  export KUBECONFIG=${KUBECONFIG_FILE}"
echo "  kubectl --insecure-skip-tls-verify get pods -A"
echo ""
echo -e "${CYAN}Rancher API:${NC}"
echo "  URL:   ${RANCHER_URL}"
echo "  Token: ${API_TOKEN}"
echo ""
echo -e "${CYAN}Terraform Provider Configuration:${NC}"
echo ""
cat <<'EOF'
  terraform {
    required_providers {
      rancher2 = {
        source  = "rancher/rancher2"
        version = "~> 13.1"
      }
    }
  }

  variable "rancher_url" {
    type = string
  }

  variable "rancher_token" {
    type      = string
    sensitive = true
  }

  provider "rancher2" {
    api_url   = var.rancher_url
    token_key = var.rancher_token
    insecure  = true
  }

EOF

if [[ -n "$HARVESTER_CLUSTER_ID" ]]; then
    echo -e "${CYAN}Harvester Cloud Credential (Terraform):${NC}"
    echo ""
    cat <<EOF
  variable "harvester_cluster_id" {
    type    = string
    default = "${HARVESTER_CLUSTER_ID}"
  }

  resource "rancher2_cloud_credential" "harvester" {
    name = "harvester"
    harvester_credential_config {
      cluster_id         = var.harvester_cluster_id
      cluster_type       = "imported"
      kubeconfig_content = file("kubeconfig-harvester.yaml")
    }
  }

EOF
fi

echo -e "${CYAN}Output Files:${NC}"
echo "  k3k kubeconfig:        ${KUBECONFIG_FILE}"
[[ -n "$HARVESTER_KC_FILE" ]] && \
echo "  Harvester kubeconfig:  ${HARVESTER_KC_FILE}"
echo "  Terraform variables:   ${TFVARS_FILE}"
echo ""
warn "These files contain secrets — covered by .gitignore (kubeconfig*, *.tfvars)"
echo ""
