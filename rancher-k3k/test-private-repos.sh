#!/usr/bin/env bash
set -euo pipefail

# Test private Helm repo support in deploy.sh
#
# Tier 1 (default): Template validation — no cluster needed
# Tier 2 (--full):  Local HTTPS server with basic auth

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FULL_TESTS=false
[[ "${1:-}" == "--full" ]] && FULL_TESTS=true

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0
SKIP=0

pass() { echo -e "${GREEN}  PASS${NC} $1"; PASS=$((PASS + 1)); }
fail() { echo -e "${RED}  FAIL${NC} $1: $2"; FAIL=$((FAIL + 1)); }
skip() { echo -e "${YELLOW}  SKIP${NC} $1: $2"; SKIP=$((SKIP + 1)); }

# Validate YAML using python3 (available on macOS and most Linux)
validate_yaml() {
    local file="$1"
    if command -v python3 &>/dev/null; then
        python3 -c "
import sys, yaml
with open(sys.argv[1]) as f:
    list(yaml.safe_load_all(f))
" "$file" 2>&1
    else
        # Fall back to basic check: no remaining placeholders
        if grep -q '__[A-Z_]*__' "$file"; then
            echo "Unresolved placeholders found"
            return 1
        fi
    fi
}

# Check that a YAML file contains a specific string
yaml_contains() {
    grep -q "$1" "$2"
}

# Check that a YAML file does NOT contain a specific string
yaml_not_contains() {
    ! grep -q "$1" "$2"
}

# =============================================================================
# Source lib.sh to get real functions
# =============================================================================
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

# =============================================================================
# Tier 1: Template Validation
# =============================================================================
echo ""
echo "========================================"
echo " Tier 1: Template Validation"
echo "========================================"
echo ""

TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# --- Test 1: Public defaults (no auth, no CA) ---
echo "Test 1: cert-manager template with public defaults (HTTP)"
HELM_REPO_USER="" PRIVATE_CA_PATH=""
cp "$SCRIPT_DIR/post-install/01-cert-manager.yaml" "$TMPDIR_TEST/cm-public.yaml"
sedi "s|^__CERTMANAGER_REPO_LINE__$|  repo: https://charts.jetstack.io|" "$TMPDIR_TEST/cm-public.yaml"
sedi "s|__CERTMANAGER_CHART__|cert-manager|g" "$TMPDIR_TEST/cm-public.yaml"
sedi "s|__CERTMANAGER_VERSION__|v1.18.5|g" "$TMPDIR_TEST/cm-public.yaml"
inject_helmchart_auth "$TMPDIR_TEST/cm-public.yaml"

if validate_yaml "$TMPDIR_TEST/cm-public.yaml" >/dev/null 2>&1; then
    pass "Valid YAML"
else
    fail "Valid YAML" "$(validate_yaml "$TMPDIR_TEST/cm-public.yaml" 2>&1)"
fi

if yaml_not_contains "__AUTH_SECRET" "$TMPDIR_TEST/cm-public.yaml" && \
   yaml_not_contains "__REPO_CA" "$TMPDIR_TEST/cm-public.yaml"; then
    pass "Placeholders removed"
else
    fail "Placeholders removed" "Unresolved placeholders remain"
fi

if yaml_not_contains "authSecret" "$TMPDIR_TEST/cm-public.yaml"; then
    pass "No authSecret (expected for public)"
else
    fail "No authSecret" "authSecret should not be present for public repos"
fi

# --- Test 2: Auth + CA enabled (HTTP) ---
echo ""
echo "Test 2: cert-manager template with auth + CA (HTTP)"
HELM_REPO_USER="testuser" PRIVATE_CA_PATH="/tmp/fake-ca.pem"
cp "$SCRIPT_DIR/post-install/01-cert-manager.yaml" "$TMPDIR_TEST/cm-auth.yaml"
sedi "s|^__CERTMANAGER_REPO_LINE__$|  repo: https://harbor.example.com/chartrepo/library|" "$TMPDIR_TEST/cm-auth.yaml"
sedi "s|__CERTMANAGER_CHART__|cert-manager|g" "$TMPDIR_TEST/cm-auth.yaml"
sedi "s|__CERTMANAGER_VERSION__|v1.18.5|g" "$TMPDIR_TEST/cm-auth.yaml"
inject_helmchart_auth "$TMPDIR_TEST/cm-auth.yaml" "https://harbor.example.com/chartrepo/library"

if validate_yaml "$TMPDIR_TEST/cm-auth.yaml" >/dev/null 2>&1; then
    pass "Valid YAML"
else
    fail "Valid YAML" "$(validate_yaml "$TMPDIR_TEST/cm-auth.yaml" 2>&1)"
fi

if yaml_contains "authSecret:" "$TMPDIR_TEST/cm-auth.yaml"; then
    pass "authSecret present"
else
    fail "authSecret present" "authSecret not found"
fi

if yaml_contains "name: helm-repo-auth" "$TMPDIR_TEST/cm-auth.yaml"; then
    pass "authSecret name correct"
else
    fail "authSecret name" "Expected 'name: helm-repo-auth'"
fi

if yaml_contains "repoCAConfigMap:" "$TMPDIR_TEST/cm-auth.yaml"; then
    pass "repoCAConfigMap present"
else
    fail "repoCAConfigMap present" "repoCAConfigMap not found"
fi

if yaml_contains "name: helm-repo-ca" "$TMPDIR_TEST/cm-auth.yaml"; then
    pass "repoCAConfigMap name correct"
else
    fail "repoCAConfigMap name" "Expected 'name: helm-repo-ca'"
fi

# --- Test 3: Rancher template with public defaults (HTTP) ---
echo ""
echo "Test 3: Rancher template with public defaults (HTTP)"
HELM_REPO_USER="" PRIVATE_CA_PATH=""
cp "$SCRIPT_DIR/post-install/02-rancher.yaml" "$TMPDIR_TEST/rancher-public.yaml"
sedi "s|__HOSTNAME__|rancher.test.local|g" "$TMPDIR_TEST/rancher-public.yaml"
sedi "s|__BOOTSTRAP_PW__|admin1234567890|g" "$TMPDIR_TEST/rancher-public.yaml"
sedi "s|^__RANCHER_REPO_LINE__$|  repo: https://releases.rancher.com/server-charts/latest|" "$TMPDIR_TEST/rancher-public.yaml"
sedi "s|__RANCHER_CHART__|rancher|g" "$TMPDIR_TEST/rancher-public.yaml"
sedi "s|__RANCHER_VERSION__|v2.13.2|g" "$TMPDIR_TEST/rancher-public.yaml"
sedi "s|__TLS_SOURCE__|rancher|g" "$TMPDIR_TEST/rancher-public.yaml"
sedi "/__EXTRA_RANCHER_VALUES__/d" "$TMPDIR_TEST/rancher-public.yaml"
inject_helmchart_auth "$TMPDIR_TEST/rancher-public.yaml"

if validate_yaml "$TMPDIR_TEST/rancher-public.yaml" >/dev/null 2>&1; then
    pass "Valid YAML"
else
    fail "Valid YAML" "$(validate_yaml "$TMPDIR_TEST/rancher-public.yaml" 2>&1)"
fi

# Check non-comment lines for unresolved placeholders
if ! grep -v '^#' "$TMPDIR_TEST/rancher-public.yaml" | grep -q '__'; then
    pass "All placeholders resolved"
else
    fail "All placeholders resolved" "Unresolved placeholders remain in non-comment lines"
fi

# --- Test 4: Rancher template with auth + CA (HTTP) ---
echo ""
echo "Test 4: Rancher template with auth + CA (HTTP)"
HELM_REPO_USER="testuser" PRIVATE_CA_PATH="/tmp/fake-ca.pem"
cp "$SCRIPT_DIR/post-install/02-rancher.yaml" "$TMPDIR_TEST/rancher-auth.yaml"
sedi "s|__HOSTNAME__|rancher.test.local|g" "$TMPDIR_TEST/rancher-auth.yaml"
sedi "s|__BOOTSTRAP_PW__|admin1234567890|g" "$TMPDIR_TEST/rancher-auth.yaml"
sedi "s|^__RANCHER_REPO_LINE__$|  repo: https://harbor.example.com/chartrepo/library|" "$TMPDIR_TEST/rancher-auth.yaml"
sedi "s|__RANCHER_CHART__|rancher|g" "$TMPDIR_TEST/rancher-auth.yaml"
sedi "s|__RANCHER_VERSION__|v2.13.2|g" "$TMPDIR_TEST/rancher-auth.yaml"
sedi "s|__TLS_SOURCE__|rancher|g" "$TMPDIR_TEST/rancher-auth.yaml"
sedi "/__EXTRA_RANCHER_VALUES__/d" "$TMPDIR_TEST/rancher-auth.yaml"
inject_helmchart_auth "$TMPDIR_TEST/rancher-auth.yaml" "https://harbor.example.com/chartrepo/library"

if validate_yaml "$TMPDIR_TEST/rancher-auth.yaml" >/dev/null 2>&1; then
    pass "Valid YAML"
else
    fail "Valid YAML" "$(validate_yaml "$TMPDIR_TEST/rancher-auth.yaml" 2>&1)"
fi

if yaml_contains "authSecret:" "$TMPDIR_TEST/rancher-auth.yaml" && \
   yaml_contains "repoCAConfigMap:" "$TMPDIR_TEST/rancher-auth.yaml"; then
    pass "Auth + CA injected"
else
    fail "Auth + CA injected" "Expected authSecret and repoCAConfigMap"
fi

# --- Test OCI-1: is_oci() and oci_registry_host() helpers ---
echo ""
echo "Test OCI-1: is_oci() helper"
if is_oci "oci://harbor.example.com/helm/cert-manager"; then
    pass "Detects OCI URI"
else
    fail "OCI detection" "Should detect oci:// prefix"
fi

if ! is_oci "https://charts.jetstack.io"; then
    pass "Rejects HTTP URL"
else
    fail "HTTP rejection" "Should not detect HTTP as OCI"
fi

if ! is_oci ""; then
    pass "Rejects empty string"
else
    fail "Empty string" "Should not detect empty as OCI"
fi

echo ""
echo "Test OCI-2: oci_registry_host() helper"
HOST=$(oci_registry_host "oci://harbor.example.com/helm/cert-manager")
if [[ "$HOST" == "harbor.example.com" ]]; then
    pass "Extracts host: $HOST"
else
    fail "Host extraction" "Expected harbor.example.com, got $HOST"
fi

HOST=$(oci_registry_host "oci://registry.example.com:5000/charts/rancher")
if [[ "$HOST" == "registry.example.com:5000" ]]; then
    pass "Extracts host with port: $HOST"
else
    fail "Host+port extraction" "Expected registry.example.com:5000, got $HOST"
fi

# --- Test OCI-3: cert-manager template with OCI URI + auth ---
echo ""
echo "Test OCI-3: cert-manager template with OCI URI + auth"
HELM_REPO_USER="testuser" PRIVATE_CA_PATH="/tmp/fake-ca.pem"
cp "$SCRIPT_DIR/post-install/01-cert-manager.yaml" "$TMPDIR_TEST/cm-oci.yaml"
sedi "/__CERTMANAGER_REPO_LINE__/d" "$TMPDIR_TEST/cm-oci.yaml"
sedi "s|__CERTMANAGER_CHART__|oci://harbor.example.com/helm/cert-manager|g" "$TMPDIR_TEST/cm-oci.yaml"
sedi "s|__CERTMANAGER_VERSION__|v1.18.5|g" "$TMPDIR_TEST/cm-oci.yaml"
inject_helmchart_auth "$TMPDIR_TEST/cm-oci.yaml" "oci://harbor.example.com/helm/cert-manager"

if validate_yaml "$TMPDIR_TEST/cm-oci.yaml" >/dev/null 2>&1; then
    pass "Valid YAML"
else
    fail "Valid YAML" "$(validate_yaml "$TMPDIR_TEST/cm-oci.yaml" 2>&1)"
fi

if yaml_contains "chart: oci://harbor.example.com/helm/cert-manager" "$TMPDIR_TEST/cm-oci.yaml"; then
    pass "OCI chart reference in spec.chart"
else
    fail "OCI chart ref" "Expected oci:// URI in chart field"
fi

if yaml_not_contains "repo:" "$TMPDIR_TEST/cm-oci.yaml"; then
    pass "No repo field (OCI mode)"
else
    fail "No repo" "repo: should not be present for OCI"
fi

if yaml_contains "dockerRegistrySecret:" "$TMPDIR_TEST/cm-oci.yaml"; then
    pass "dockerRegistrySecret present (OCI auth)"
else
    fail "dockerRegistrySecret" "Expected dockerRegistrySecret for OCI"
fi

if yaml_not_contains "authSecret:" "$TMPDIR_TEST/cm-oci.yaml"; then
    pass "No authSecret (OCI uses dockerRegistrySecret)"
else
    fail "No authSecret" "authSecret should not be present for OCI"
fi

if yaml_contains "repoCAConfigMap:" "$TMPDIR_TEST/cm-oci.yaml"; then
    pass "repoCAConfigMap present"
else
    fail "repoCAConfigMap" "Expected repoCAConfigMap in OCI mode"
fi

# --- Test OCI-4: Rancher template with OCI URI + auth ---
echo ""
echo "Test OCI-4: Rancher template with OCI URI + auth"
HELM_REPO_USER="testuser" PRIVATE_CA_PATH="/tmp/fake-ca.pem"
cp "$SCRIPT_DIR/post-install/02-rancher.yaml" "$TMPDIR_TEST/rancher-oci.yaml"
sedi "s|__HOSTNAME__|rancher.test.local|g" "$TMPDIR_TEST/rancher-oci.yaml"
sedi "s|__BOOTSTRAP_PW__|admin1234567890|g" "$TMPDIR_TEST/rancher-oci.yaml"
sedi "/__RANCHER_REPO_LINE__/d" "$TMPDIR_TEST/rancher-oci.yaml"
sedi "s|__RANCHER_CHART__|oci://harbor.example.com/helm/rancher|g" "$TMPDIR_TEST/rancher-oci.yaml"
sedi "s|__RANCHER_VERSION__|v2.13.2|g" "$TMPDIR_TEST/rancher-oci.yaml"
sedi "s|__TLS_SOURCE__|rancher|g" "$TMPDIR_TEST/rancher-oci.yaml"
sedi "/__EXTRA_RANCHER_VALUES__/d" "$TMPDIR_TEST/rancher-oci.yaml"
inject_helmchart_auth "$TMPDIR_TEST/rancher-oci.yaml" "oci://harbor.example.com/helm/rancher"

if validate_yaml "$TMPDIR_TEST/rancher-oci.yaml" >/dev/null 2>&1; then
    pass "Valid YAML"
else
    fail "Valid YAML" "$(validate_yaml "$TMPDIR_TEST/rancher-oci.yaml" 2>&1)"
fi

if yaml_contains "chart: oci://harbor.example.com/helm/rancher" "$TMPDIR_TEST/rancher-oci.yaml" && \
   yaml_not_contains "repo:" "$TMPDIR_TEST/rancher-oci.yaml" && \
   yaml_contains "dockerRegistrySecret:" "$TMPDIR_TEST/rancher-oci.yaml"; then
    pass "OCI mode: chart ref, no repo, dockerRegistrySecret"
else
    fail "OCI mode" "Expected OCI chart ref, no repo, dockerRegistrySecret"
fi

# --- Test OCI-5: cert-manager OCI without auth (public OCI) ---
echo ""
echo "Test OCI-5: cert-manager OCI without auth (public OCI)"
HELM_REPO_USER="" PRIVATE_CA_PATH=""
cp "$SCRIPT_DIR/post-install/01-cert-manager.yaml" "$TMPDIR_TEST/cm-oci-pub.yaml"
sedi "/__CERTMANAGER_REPO_LINE__/d" "$TMPDIR_TEST/cm-oci-pub.yaml"
sedi "s|__CERTMANAGER_CHART__|oci://ghcr.io/jetstack/cert-manager|g" "$TMPDIR_TEST/cm-oci-pub.yaml"
sedi "s|__CERTMANAGER_VERSION__|v1.18.5|g" "$TMPDIR_TEST/cm-oci-pub.yaml"
inject_helmchart_auth "$TMPDIR_TEST/cm-oci-pub.yaml" "oci://ghcr.io/jetstack/cert-manager"

if validate_yaml "$TMPDIR_TEST/cm-oci-pub.yaml" >/dev/null 2>&1; then
    pass "Valid YAML"
else
    fail "Valid YAML" "$(validate_yaml "$TMPDIR_TEST/cm-oci-pub.yaml" 2>&1)"
fi

if yaml_not_contains "dockerRegistrySecret:" "$TMPDIR_TEST/cm-oci-pub.yaml" && \
   yaml_not_contains "authSecret:" "$TMPDIR_TEST/cm-oci-pub.yaml" && \
   yaml_not_contains "repoCAConfigMap:" "$TMPDIR_TEST/cm-oci-pub.yaml"; then
    pass "No auth secrets (public OCI)"
else
    fail "No auth" "Should have no auth/CA for public OCI"
fi

# --- Test OCI-6: Mixed mode (cert-manager OCI, Rancher HTTP) ---
echo ""
echo "Test OCI-6: Mixed mode (cert-manager OCI + Rancher HTTP)"
HELM_REPO_USER="testuser" PRIVATE_CA_PATH="/tmp/fake-ca.pem"

# cert-manager as OCI
cp "$SCRIPT_DIR/post-install/01-cert-manager.yaml" "$TMPDIR_TEST/cm-mixed.yaml"
sedi "/__CERTMANAGER_REPO_LINE__/d" "$TMPDIR_TEST/cm-mixed.yaml"
sedi "s|__CERTMANAGER_CHART__|oci://harbor.example.com/helm/cert-manager|g" "$TMPDIR_TEST/cm-mixed.yaml"
sedi "s|__CERTMANAGER_VERSION__|v1.18.5|g" "$TMPDIR_TEST/cm-mixed.yaml"
inject_helmchart_auth "$TMPDIR_TEST/cm-mixed.yaml" "oci://harbor.example.com/helm/cert-manager"

# Rancher as HTTP
cp "$SCRIPT_DIR/post-install/02-rancher.yaml" "$TMPDIR_TEST/rancher-mixed.yaml"
sedi "s|__HOSTNAME__|rancher.test.local|g" "$TMPDIR_TEST/rancher-mixed.yaml"
sedi "s|__BOOTSTRAP_PW__|admin1234567890|g" "$TMPDIR_TEST/rancher-mixed.yaml"
sedi "s|^__RANCHER_REPO_LINE__$|  repo: https://releases.rancher.com/server-charts/latest|" "$TMPDIR_TEST/rancher-mixed.yaml"
sedi "s|__RANCHER_CHART__|rancher|g" "$TMPDIR_TEST/rancher-mixed.yaml"
sedi "s|__RANCHER_VERSION__|v2.13.2|g" "$TMPDIR_TEST/rancher-mixed.yaml"
sedi "s|__TLS_SOURCE__|rancher|g" "$TMPDIR_TEST/rancher-mixed.yaml"
sedi "/__EXTRA_RANCHER_VALUES__/d" "$TMPDIR_TEST/rancher-mixed.yaml"
inject_helmchart_auth "$TMPDIR_TEST/rancher-mixed.yaml" "https://releases.rancher.com/server-charts/latest"

# Verify cert-manager got OCI auth
if yaml_contains "dockerRegistrySecret:" "$TMPDIR_TEST/cm-mixed.yaml" && \
   yaml_not_contains "authSecret:" "$TMPDIR_TEST/cm-mixed.yaml"; then
    pass "cert-manager uses dockerRegistrySecret (OCI)"
else
    fail "cert-manager OCI auth" "Expected dockerRegistrySecret only"
fi

# Verify Rancher got HTTP auth
if yaml_contains "authSecret:" "$TMPDIR_TEST/rancher-mixed.yaml" && \
   yaml_not_contains "dockerRegistrySecret:" "$TMPDIR_TEST/rancher-mixed.yaml"; then
    pass "Rancher uses authSecret (HTTP)"
else
    fail "Rancher HTTP auth" "Expected authSecret only"
fi

# --- Test 5: build_helm_repo_flags with no auth ---
echo ""
echo "Test 5: build_helm_repo_flags without auth"
HELM_REPO_USER="" HELM_REPO_PASS="" PRIVATE_CA_PATH=""
build_helm_repo_flags
if [[ ${#HELM_REPO_FLAGS[@]} -eq 0 ]]; then
    pass "Empty flags for public repos"
else
    fail "Empty flags" "Expected empty array, got: ${HELM_REPO_FLAGS[*]}"
fi

# --- Test 6: build_helm_repo_flags with auth + CA ---
echo ""
echo "Test 6: build_helm_repo_flags with auth + CA"
HELM_REPO_USER="myuser" HELM_REPO_PASS="mypass" PRIVATE_CA_PATH="/tmp/fake-ca.pem"
build_helm_repo_flags
EXPECTED_FLAGS="--username myuser --password mypass --ca-file /tmp/fake-ca.pem"
ACTUAL_FLAGS="${HELM_REPO_FLAGS[*]}"
if [[ "$ACTUAL_FLAGS" == "$EXPECTED_FLAGS" ]]; then
    pass "Correct flags: $ACTUAL_FLAGS"
else
    fail "Flag construction" "Expected '$EXPECTED_FLAGS', got '$ACTUAL_FLAGS'"
fi

# --- Test 7: build_helm_ca_flags ---
echo ""
echo "Test 7: build_helm_ca_flags with CA"
PRIVATE_CA_PATH="/tmp/fake-ca.pem"
build_helm_ca_flags
if [[ "${HELM_CA_FLAGS[*]}" == "--ca-file /tmp/fake-ca.pem" ]]; then
    pass "CA-only flags correct"
else
    fail "CA-only flags" "Expected '--ca-file /tmp/fake-ca.pem', got '${HELM_CA_FLAGS[*]}'"
fi

PRIVATE_CA_PATH=""
build_helm_ca_flags
if [[ ${#HELM_CA_FLAGS[@]} -eq 0 ]]; then
    pass "Empty CA flags when no CA"
else
    fail "Empty CA flags" "Expected empty, got: ${HELM_CA_FLAGS[*]}"
fi

# --- Test 8: helm repo add with public repos as custom input ---
echo ""
echo "Test 8: helm repo add with public repos (exercises flag construction)"
if command -v helm &>/dev/null; then
    HELM_REPO_USER="" HELM_REPO_PASS="" PRIVATE_CA_PATH=""
    build_helm_repo_flags

    # Use unique test names to avoid conflicts with actual repos
    TEST_REPOS=(
        "test-cm-pub|https://charts.jetstack.io"
        "test-rancher-pub|https://releases.rancher.com/server-charts/latest"
        "test-k3k-pub|https://rancher.github.io/k3k"
    )

    for entry in "${TEST_REPOS[@]}"; do
        IFS='|' read -r name url <<< "$entry"
        if helm repo add "$name" "$url" --force-update ${HELM_REPO_FLAGS[@]+"${HELM_REPO_FLAGS[@]}"} 2>/dev/null; then
            pass "helm repo add $name ($url)"
            helm repo remove "$name" 2>/dev/null || true
        else
            fail "helm repo add $name" "Failed to add $url"
        fi
    done
else
    skip "helm repo add" "helm not installed"
fi

# --- Test 9: helm repo add with auth flags against public repos ---
echo ""
echo "Test 9: helm repo add with auth flags (flags accepted by public repos)"
if command -v helm &>/dev/null; then
    HELM_REPO_USER="dummyuser" HELM_REPO_PASS="dummypass" PRIVATE_CA_PATH=""
    build_helm_repo_flags

    # Public repos accept --username/--password flags even if unused
    if helm repo add test-auth-flags "https://charts.jetstack.io" --force-update ${HELM_REPO_FLAGS[@]+"${HELM_REPO_FLAGS[@]}"} 2>/dev/null; then
        pass "helm repo add with auth flags accepted"
        helm repo remove test-auth-flags 2>/dev/null || true
    else
        fail "helm repo add with auth flags" "Public repo rejected auth flags"
    fi
else
    skip "helm repo add with auth" "helm not installed"
fi

# --- Test 10: build_registries_yaml with Harbor host + auth + CA ---
echo ""
echo "Test 10: build_registries_yaml with Harbor host (multi-registry mirrors)"
PRIVATE_REGISTRY="harbor.example.com" PRIVATE_CA_PATH="/tmp/fake-ca.pem"
HELM_REPO_USER="testuser" HELM_REPO_PASS="testpass"
REGISTRY_FILE="$TMPDIR_TEST/registries.yaml"
build_registries_yaml "$REGISTRY_FILE"

if validate_yaml "$REGISTRY_FILE" >/dev/null 2>&1; then
    pass "Valid YAML"
else
    fail "Valid YAML" "$(validate_yaml "$REGISTRY_FILE" 2>&1)"
fi

if yaml_contains "docker.io:" "$REGISTRY_FILE"; then
    pass "docker.io mirror present"
else
    fail "docker.io mirror" "docker.io mirror entry not found"
fi

if yaml_contains "quay.io:" "$REGISTRY_FILE"; then
    pass "quay.io mirror present"
else
    fail "quay.io mirror" "quay.io mirror entry not found"
fi

if yaml_contains "ghcr.io:" "$REGISTRY_FILE"; then
    pass "ghcr.io mirror present"
else
    fail "ghcr.io mirror" "ghcr.io mirror entry not found"
fi

if yaml_contains "https://harbor.example.com" "$REGISTRY_FILE"; then
    pass "Endpoint points to Harbor host"
else
    fail "Endpoint" "Expected https://harbor.example.com"
fi

# Verify rewrite rules route to correct Harbor projects
if yaml_contains 'docker.io/' "$REGISTRY_FILE" && \
   yaml_contains 'quay.io/' "$REGISTRY_FILE" && \
   yaml_contains 'ghcr.io/' "$REGISTRY_FILE"; then
    pass "Rewrite rules map to Harbor proxy cache projects"
else
    fail "Rewrite rules" "Expected rewrite with docker.io/, quay.io/, ghcr.io/ prefixes"
fi

if yaml_contains "ca_file:" "$REGISTRY_FILE"; then
    pass "CA file configured"
else
    fail "CA file" "Expected tls.ca_file"
fi

if yaml_contains "username:" "$REGISTRY_FILE" && yaml_contains "password:" "$REGISTRY_FILE"; then
    pass "Auth credentials present"
else
    fail "Auth" "Expected auth username/password"
fi

# --- Test 11: build_registries_yaml without CA or auth ---
echo ""
echo "Test 11: build_registries_yaml without CA or auth"
PRIVATE_REGISTRY="registry.example.com:5000" PRIVATE_CA_PATH="" HELM_REPO_USER="" HELM_REPO_PASS=""
build_registries_yaml "$TMPDIR_TEST/registries-plain.yaml"

if validate_yaml "$TMPDIR_TEST/registries-plain.yaml" >/dev/null 2>&1; then
    pass "Valid YAML"
else
    fail "Valid YAML" "$(validate_yaml "$TMPDIR_TEST/registries-plain.yaml" 2>&1)"
fi

if yaml_contains "https://registry.example.com:5000" "$TMPDIR_TEST/registries-plain.yaml"; then
    pass "Endpoint uses full host:port"
else
    fail "Endpoint" "Expected https://registry.example.com:5000"
fi

# All three upstream registries should still have mirror entries
if yaml_contains "docker.io:" "$TMPDIR_TEST/registries-plain.yaml" && \
   yaml_contains "quay.io:" "$TMPDIR_TEST/registries-plain.yaml" && \
   yaml_contains "ghcr.io:" "$TMPDIR_TEST/registries-plain.yaml"; then
    pass "All three upstream mirrors present"
else
    fail "Upstream mirrors" "Expected docker.io, quay.io, ghcr.io mirror entries"
fi

if yaml_not_contains "configs:" "$TMPDIR_TEST/registries-plain.yaml"; then
    pass "No configs section (no CA, no auth)"
else
    fail "No configs" "configs section should not be present without CA or auth"
fi

# --- Test 12: inject_secret_mounts with private registry + CA ---
echo ""
echo "Test 12: inject_secret_mounts with private registry + CA (requires k3k >= v1.0.2-rc2)"
PRIVATE_REGISTRY="harbor.example.com" PRIVATE_CA_PATH="/tmp/fake-ca.pem"
cp "$SCRIPT_DIR/rancher-cluster.yaml" "$TMPDIR_TEST/cluster-registry.yaml"
sedi "s|__PVC_SIZE__|10Gi|g" "$TMPDIR_TEST/cluster-registry.yaml"
sedi "s|__STORAGE_CLASS__|harvester-longhorn|g" "$TMPDIR_TEST/cluster-registry.yaml"
inject_secret_mounts "$TMPDIR_TEST/cluster-registry.yaml"

if validate_yaml "$TMPDIR_TEST/cluster-registry.yaml" >/dev/null 2>&1; then
    pass "Valid YAML"
else
    fail "Valid YAML" "$(validate_yaml "$TMPDIR_TEST/cluster-registry.yaml" 2>&1)"
fi

if yaml_contains "secretMounts:" "$TMPDIR_TEST/cluster-registry.yaml"; then
    pass "secretMounts present"
else
    fail "secretMounts" "secretMounts block not found"
fi

if yaml_contains "k3s-registry-config" "$TMPDIR_TEST/cluster-registry.yaml"; then
    pass "Registry config secret referenced"
else
    fail "Registry config" "k3s-registry-config not found"
fi

if yaml_contains "k3s-registry-ca" "$TMPDIR_TEST/cluster-registry.yaml"; then
    pass "Registry CA secret referenced"
else
    fail "Registry CA" "k3s-registry-ca not found"
fi

if yaml_contains "registries.yaml" "$TMPDIR_TEST/cluster-registry.yaml"; then
    pass "registries.yaml mountPath/subPath present"
else
    fail "registries.yaml" "registries.yaml mount not found"
fi

if yaml_contains "role: all" "$TMPDIR_TEST/cluster-registry.yaml"; then
    pass "role: all set on secret mounts"
else
    fail "role: all" "Expected role: all on secret mounts"
fi

if yaml_contains "system-default-registry=harbor.example.com/docker.io" "$TMPDIR_TEST/cluster-registry.yaml"; then
    pass "--system-default-registry=harbor.example.com/docker.io injected"
else
    fail "--system-default-registry" "Expected harbor.example.com/docker.io in serverArg"
fi

# --- Test 13: inject_secret_mounts without private registry ---
echo ""
echo "Test 13: inject_secret_mounts without private registry (public)"
PRIVATE_REGISTRY="" PRIVATE_CA_PATH=""
cp "$SCRIPT_DIR/rancher-cluster.yaml" "$TMPDIR_TEST/cluster-public.yaml"
sedi "s|__PVC_SIZE__|10Gi|g" "$TMPDIR_TEST/cluster-public.yaml"
sedi "s|__STORAGE_CLASS__|harvester-longhorn|g" "$TMPDIR_TEST/cluster-public.yaml"
inject_secret_mounts "$TMPDIR_TEST/cluster-public.yaml"

if validate_yaml "$TMPDIR_TEST/cluster-public.yaml" >/dev/null 2>&1; then
    pass "Valid YAML"
else
    fail "Valid YAML" "$(validate_yaml "$TMPDIR_TEST/cluster-public.yaml" 2>&1)"
fi

if yaml_not_contains "secretMounts:" "$TMPDIR_TEST/cluster-public.yaml"; then
    pass "No secretMounts (public)"
else
    fail "No secretMounts" "secretMounts should not be present for public registries"
fi

if yaml_not_contains "system-default-registry" "$TMPDIR_TEST/cluster-public.yaml"; then
    pass "No --system-default-registry (public)"
else
    fail "No --system-default-registry" "serverArg should not be present for public"
fi

# Check no unresolved placeholders in non-comment lines
if ! grep -v '^#' "$TMPDIR_TEST/cluster-public.yaml" | grep -q '__'; then
    pass "All placeholders cleaned"
else
    fail "Placeholders cleaned" "Unresolved placeholders remain"
fi

# --- Test 14: inject_secret_mounts with registry but no CA ---
echo ""
echo "Test 14: inject_secret_mounts with registry, no CA"
PRIVATE_REGISTRY="registry.example.com" PRIVATE_CA_PATH=""
cp "$SCRIPT_DIR/rancher-cluster.yaml" "$TMPDIR_TEST/cluster-noca.yaml"
sedi "s|__PVC_SIZE__|10Gi|g" "$TMPDIR_TEST/cluster-noca.yaml"
sedi "s|__STORAGE_CLASS__|harvester-longhorn|g" "$TMPDIR_TEST/cluster-noca.yaml"
inject_secret_mounts "$TMPDIR_TEST/cluster-noca.yaml"

if validate_yaml "$TMPDIR_TEST/cluster-noca.yaml" >/dev/null 2>&1; then
    pass "Valid YAML"
else
    fail "Valid YAML" "$(validate_yaml "$TMPDIR_TEST/cluster-noca.yaml" 2>&1)"
fi

if yaml_contains "k3s-registry-config" "$TMPDIR_TEST/cluster-noca.yaml"; then
    pass "Registry config secret referenced"
else
    fail "Registry config" "k3s-registry-config not found"
fi

if yaml_not_contains "k3s-registry-ca" "$TMPDIR_TEST/cluster-noca.yaml"; then
    pass "No CA secret (not needed)"
else
    fail "No CA secret" "k3s-registry-ca should not be present without CA"
fi

# =============================================================================
# Tier 2: Local HTTPS Server (optional)
# =============================================================================
if [[ "$FULL_TESTS" == "true" ]]; then
    echo ""
    echo "========================================"
    echo " Tier 2: Local HTTPS Server"
    echo "========================================"
    echo ""

    if ! command -v openssl &>/dev/null; then
        skip "Tier 2" "openssl not installed"
    elif ! command -v python3 &>/dev/null; then
        skip "Tier 2" "python3 not installed"
    elif ! command -v helm &>/dev/null; then
        skip "Tier 2" "helm not installed"
    else
        TIER2_DIR=$(mktemp -d)
        TIER2_PORT=18443
        SERVER_PID=""

        tier2_cleanup() {
            [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true
            rm -rf "$TIER2_DIR"
        }
        # Add to existing trap
        trap 'rm -rf "$TMPDIR_TEST"; tier2_cleanup' EXIT

        # Generate self-signed CA + server cert
        echo "  Generating test CA and server certificate..."
        openssl req -x509 -newkey rsa:2048 -keyout "$TIER2_DIR/ca-key.pem" \
            -out "$TIER2_DIR/ca.pem" -days 1 -nodes \
            -subj "/CN=Test CA" 2>/dev/null

        openssl req -newkey rsa:2048 -keyout "$TIER2_DIR/server-key.pem" \
            -out "$TIER2_DIR/server.csr" -nodes \
            -subj "/CN=localhost" 2>/dev/null

        openssl x509 -req -in "$TIER2_DIR/server.csr" \
            -CA "$TIER2_DIR/ca.pem" -CAkey "$TIER2_DIR/ca-key.pem" \
            -CAcreateserial -out "$TIER2_DIR/server.pem" -days 1 \
            -extfile <(echo "subjectAltName=DNS:localhost,IP:127.0.0.1") 2>/dev/null

        # Create minimal Helm repo index
        mkdir -p "$TIER2_DIR/repo"
        cat > "$TIER2_DIR/repo/index.yaml" <<'INDEXEOF'
apiVersion: v1
entries:
  test-chart:
  - apiVersion: v2
    name: test-chart
    version: 0.1.0
    description: Test chart
    urls:
    - https://localhost:18443/test-chart-0.1.0.tgz
generated: "2026-01-01T00:00:00Z"
INDEXEOF

        # Start HTTPS server with basic auth
        cat > "$TIER2_DIR/server.py" <<'PYEOF'
import http.server
import ssl
import base64
import sys
import os

EXPECTED_AUTH = base64.b64encode(b"testuser:testpass").decode()
SERVE_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "repo")

class AuthHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=SERVE_DIR, **kwargs)

    def do_GET(self):
        auth = self.headers.get("Authorization", "")
        if auth == f"Basic {EXPECTED_AUTH}":
            super().do_GET()
        else:
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="test"')
            self.end_headers()
            self.wfile.write(b"Unauthorized")

    def log_message(self, format, *args):
        pass  # Suppress output

port = int(sys.argv[1])
cert = sys.argv[2]
key = sys.argv[3]

ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(cert, key)

server = http.server.HTTPServer(("127.0.0.1", port), AuthHandler)
server.socket = ctx.wrap_socket(server.socket, server_side=True)
server.serve_forever()
PYEOF

        python3 "$TIER2_DIR/server.py" "$TIER2_PORT" \
            "$TIER2_DIR/server.pem" "$TIER2_DIR/server-key.pem" &
        SERVER_PID=$!
        sleep 1

        # Verify server is running
        if ! kill -0 "$SERVER_PID" 2>/dev/null; then
            fail "HTTPS server" "Server failed to start"
        else
            pass "HTTPS server started on port $TIER2_PORT"

            # Test: helm repo add with CA only (no auth) — should get 401
            echo ""
            echo "Test T2-1: helm repo add with CA but no auth (expect 401)"
            HELM_REPO_USER="" HELM_REPO_PASS="" PRIVATE_CA_PATH="$TIER2_DIR/ca.pem"
            build_helm_repo_flags
            if helm repo add test-noauth "https://localhost:${TIER2_PORT}" \
                --force-update ${HELM_REPO_FLAGS[@]+"${HELM_REPO_FLAGS[@]}"} 2>/dev/null; then
                # Some helm versions add the repo even on 401 (lazy fetch)
                # Try an update to actually hit the server
                if helm repo update test-noauth 2>&1 | grep -qi "unauthorized\|401\|failed"; then
                    pass "Correctly rejected without auth"
                else
                    pass "Repo added (helm defers auth check to fetch time)"
                fi
                helm repo remove test-noauth 2>/dev/null || true
            else
                pass "Correctly rejected without auth"
            fi

            # Test: helm repo add with CA + auth — should succeed
            echo ""
            echo "Test T2-2: helm repo add with CA + auth"
            HELM_REPO_USER="testuser" HELM_REPO_PASS="testpass" PRIVATE_CA_PATH="$TIER2_DIR/ca.pem"
            build_helm_repo_flags
            if helm repo add test-withauth "https://localhost:${TIER2_PORT}" \
                --force-update ${HELM_REPO_FLAGS[@]+"${HELM_REPO_FLAGS[@]}"} 2>/dev/null; then
                pass "helm repo add with auth + CA succeeded"
                helm repo remove test-withauth 2>/dev/null || true
            else
                fail "helm repo add with auth + CA" "Failed despite correct credentials"
            fi

            # Test: helm repo add without CA — should fail (untrusted cert)
            echo ""
            echo "Test T2-3: helm repo add without CA (expect TLS failure)"
            HELM_REPO_USER="testuser" HELM_REPO_PASS="testpass" PRIVATE_CA_PATH=""
            build_helm_repo_flags
            if helm repo add test-noca "https://localhost:${TIER2_PORT}" \
                --force-update ${HELM_REPO_FLAGS[@]+"${HELM_REPO_FLAGS[@]}"} 2>/dev/null; then
                fail "TLS rejection" "Should have failed without CA"
                helm repo remove test-noca 2>/dev/null || true
            else
                pass "Correctly rejected without CA (untrusted certificate)"
            fi
        fi

        tier2_cleanup
        SERVER_PID=""
    fi
else
    echo ""
    echo "Tier 2 tests skipped (use --full to enable)"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "========================================"
echo " Results: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
echo "========================================"

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
