#!/usr/bin/env bash
# Shared functions for rancher-k3k deploy scripts
#
# Functions:
#   sedi                  - Cross-platform sed -i
#   is_oci                - Check if a chart reference is an OCI URI
#   oci_registry_host     - Extract registry host from OCI URI
#   helm_registry_login   - Authenticate to OCI registry for host-cluster Helm
#   create_oci_auth_secret - Create dockerconfigjson Secret for OCI HelmChart CRs
#   build_helm_repo_flags - Populate HELM_REPO_FLAGS array
#   build_helm_ca_flags   - Populate HELM_CA_FLAGS array
#   inject_helmchart_auth - Replace auth/CA placeholders in HelmChart CRs
#   build_registries_yaml - Generate K3s registries.yaml for Harbor proxy caches
#   inject_secret_mounts  - Replace secretMounts/serverArgs placeholders in Cluster CR

# Cross-platform sed -i
sedi() {
    if sed --version &>/dev/null 2>&1; then
        sed -i "$@"
    else
        sed -i '' "$@"
    fi
}

# Check if a chart reference is an OCI URI.
# Usage: if is_oci "$REPO_OR_URI"; then ...
is_oci() {
    [[ "${1:-}" == oci://* ]]
}

# Extract the registry host from an OCI URI.
# Handles hosts with ports (e.g. registry.example.com:5000).
#   oci://harbor.example.com/helm/cert-manager → harbor.example.com
#   oci://registry.example.com:5000/charts/rancher → registry.example.com:5000
# Usage: HOST=$(oci_registry_host "$OCI_URI")
oci_registry_host() {
    echo "${1#oci://}" | cut -d/ -f1
}

# Authenticate to an OCI registry for host-cluster Helm operations.
# Skipped if no credentials are configured.
# Usage: helm_registry_login <host>
# Reads: HELM_REPO_USER, HELM_REPO_PASS, PRIVATE_CA_PATH
helm_registry_login() {
    local host="$1"
    local login_flags=()
    if [[ -n "${HELM_REPO_USER:-}" && -n "${HELM_REPO_PASS:-}" ]]; then
        login_flags+=(--username "$HELM_REPO_USER" --password "$HELM_REPO_PASS")
    fi
    if [[ -n "${PRIVATE_CA_PATH:-}" ]]; then
        login_flags+=(--ca-file "$PRIVATE_CA_PATH")
    fi
    if [[ ${#login_flags[@]} -gt 0 ]]; then
        helm registry login "$host" "${login_flags[@]}"
    fi
}

# Create a kubernetes.io/dockerconfigjson Secret for OCI HelmChart CRs.
# The K3s helm-controller uses spec.dockerRegistrySecret to pull OCI charts.
# Usage: create_oci_auth_secret <kubectl-cmd> <secret-name> <registry-host>
# Reads: HELM_REPO_USER, HELM_REPO_PASS
create_oci_auth_secret() {
    local kubectl_cmd="$1"
    local secret_name="$2"
    local registry_host="$3"
    $kubectl_cmd -n kube-system create secret docker-registry "$secret_name" \
        --docker-server="$registry_host" \
        --docker-username="$HELM_REPO_USER" \
        --docker-password="$HELM_REPO_PASS" \
        --dry-run=client -o yaml | $kubectl_cmd apply -f -
}

# Build Helm repo flags for authentication and CA.
# Sets HELM_REPO_FLAGS array (--username, --password, --ca-file as needed).
# Reads: HELM_REPO_USER, HELM_REPO_PASS, PRIVATE_CA_PATH
build_helm_repo_flags() {
    HELM_REPO_FLAGS=()
    if [[ -n "${HELM_REPO_USER:-}" && -n "${HELM_REPO_PASS:-}" ]]; then
        HELM_REPO_FLAGS+=(--username "$HELM_REPO_USER" --password "$HELM_REPO_PASS")
    fi
    if [[ -n "${PRIVATE_CA_PATH:-}" ]]; then
        HELM_REPO_FLAGS+=(--ca-file "$PRIVATE_CA_PATH")
    fi
}

# Build Helm CA flags only (for install/upgrade commands that don't take --username/--password).
# Sets HELM_CA_FLAGS array.
# Reads: PRIVATE_CA_PATH
build_helm_ca_flags() {
    HELM_CA_FLAGS=()
    if [[ -n "${PRIVATE_CA_PATH:-}" ]]; then
        HELM_CA_FLAGS+=(--ca-file "$PRIVATE_CA_PATH")
    fi
}

# Replace auth/CA placeholders in a HelmChart CR manifest file.
# If HELM_REPO_USER is set, injects auth lines; otherwise removes placeholders.
# If PRIVATE_CA_PATH is set, injects repoCAConfigMap lines; otherwise removes placeholders.
#
# Auth type depends on the chart source:
#   HTTP repos  → spec.authSecret (kubernetes.io/basic-auth)
#   OCI registries → spec.dockerRegistrySecret (kubernetes.io/dockerconfigjson)
#
# Usage: inject_helmchart_auth <manifest-file> [chart-or-repo]
# Reads: HELM_REPO_USER, PRIVATE_CA_PATH
inject_helmchart_auth() {
    local file="$1"
    local chart_ref="${2:-}"

    if [[ -n "${HELM_REPO_USER:-}" ]]; then
        if is_oci "$chart_ref"; then
            # OCI: use dockerRegistrySecret
            sedi "s|^__AUTH_SECRET_LINE1__$|  dockerRegistrySecret:|" "$file"
            sedi "s|^__AUTH_SECRET_LINE2__$|    name: helm-oci-auth|" "$file"
        else
            # HTTP: use authSecret (existing behavior)
            sedi "s|^__AUTH_SECRET_LINE1__$|  authSecret:|" "$file"
            sedi "s|^__AUTH_SECRET_LINE2__$|    name: helm-repo-auth|" "$file"
        fi
    else
        sedi "/__AUTH_SECRET_LINE1__/d" "$file"
        sedi "/__AUTH_SECRET_LINE2__/d" "$file"
    fi

    if [[ -n "${PRIVATE_CA_PATH:-}" ]]; then
        sedi "s|^__REPO_CA_LINE1__$|  repoCAConfigMap:|" "$file"
        sedi "s|^__REPO_CA_LINE2__$|    name: helm-repo-ca|" "$file"
    else
        sedi "/__REPO_CA_LINE1__/d" "$file"
        sedi "/__REPO_CA_LINE2__/d" "$file"
    fi
}

# Upstream registries that the Rancher-on-k3k stack pulls from.
# Each needs a corresponding proxy cache project in Harbor.
#   docker.io  - K3s system images, Rancher, Fleet
#   quay.io    - cert-manager (jetstack)
#   ghcr.io    - CloudNativePG, Zalando postgres-operator
MIRROR_REGISTRIES=("docker.io" "quay.io" "ghcr.io")

# Generate a K3s registries.yaml with mirror entries for all upstream registries.
# Writes the YAML to the file path given as the first argument.
#
# PRIVATE_REGISTRY is the registry host (e.g. harbor.example.com).
# Mirror entries are generated for each registry in MIRROR_REGISTRIES.
# Each mirror uses a rewrite rule that maps image paths through the
# Harbor proxy cache project named after the upstream registry:
#   docker.io/rancher/k3s:v1.34 → harbor.example.com/docker.io/rancher/k3s:v1.34
#   quay.io/jetstack/cert-manager-controller:v1.18 → harbor.example.com/quay.io/jetstack/cert-manager-controller:v1.18
#
# Usage: build_registries_yaml <output-file>
# Reads: PRIVATE_REGISTRY, PRIVATE_CA_PATH, HELM_REPO_USER, HELM_REPO_PASS
build_registries_yaml() {
    local outfile="$1"
    local reg_host="${PRIVATE_REGISTRY:-}"

    if [[ -z "$reg_host" ]]; then
        return 1
    fi

    # Generate mirror entries for each upstream registry
    cat > "$outfile" <<REGEOF
mirrors:
REGEOF

    for upstream in "${MIRROR_REGISTRIES[@]}"; do
        cat >> "$outfile" <<REGEOF
  ${upstream}:
    endpoint:
      - "https://${reg_host}"
    rewrite:
      "^(.*)$": "${upstream}/\$1"
REGEOF
    done

    # Add configs section for TLS and/or auth (single entry for the Harbor host)
    if [[ -n "${PRIVATE_CA_PATH:-}" || -n "${HELM_REPO_USER:-}" ]]; then
        cat >> "$outfile" <<REGEOF
configs:
  "${reg_host}":
REGEOF

        if [[ -n "${PRIVATE_CA_PATH:-}" ]]; then
            cat >> "$outfile" <<REGEOF
    tls:
      ca_file: /etc/rancher/k3s/tls/ca.crt
REGEOF
        fi

        if [[ -n "${HELM_REPO_USER:-}" ]]; then
            cat >> "$outfile" <<REGEOF
    auth:
      username: "${HELM_REPO_USER}"
      password: "${HELM_REPO_PASS}"
REGEOF
        fi
    fi
}

# Replace secretMounts and extra serverArgs placeholders in a Cluster CR manifest.
# If PRIVATE_REGISTRY is set, injects secretMounts for registries.yaml (and optionally CA).
# If PRIVATE_REGISTRY is set, injects --system-default-registry serverArg.
# Otherwise removes the placeholders.
#
# Requires k3k >= v1.0.2-rc2 (PR #570 added secretMounts to the CRD).
#
# Usage: inject_secret_mounts <manifest-file>
# Reads: PRIVATE_REGISTRY, PRIVATE_CA_PATH
inject_secret_mounts() {
    local file="$1"

    if [[ -n "${PRIVATE_REGISTRY:-}" ]]; then
        # Build the secretMounts block in a temp file
        local mounts_file
        mounts_file=$(mktemp)
        {
            echo "  secretMounts:"
            echo "    - secretName: k3s-registry-config"
            echo "      mountPath: /etc/rancher/k3s/registries.yaml"
            echo "      subPath: registries.yaml"
            echo "      role: all"
            if [[ -n "${PRIVATE_CA_PATH:-}" ]]; then
                echo "    - secretName: k3s-registry-ca"
                echo "      mountPath: /etc/rancher/k3s/tls/ca.crt"
                echo "      subPath: ca.crt"
                echo "      role: all"
            fi
        } > "$mounts_file"

        # Replace __SECRET_MOUNTS__ with the contents of mounts_file
        # Use line-by-line approach for macOS/Linux portability
        local tmpfile
        tmpfile=$(mktemp)
        while IFS= read -r line; do
            if [[ "$line" == *"__SECRET_MOUNTS__"* ]]; then
                cat "$mounts_file"
            else
                printf '%s\n' "$line"
            fi
        done < "$file" > "$tmpfile"
        mv "$tmpfile" "$file"
        rm -f "$mounts_file"

        # Inject --system-default-registry serverArg (K3s system images are all on docker.io)
        sedi "s|^__EXTRA_SERVER_ARGS__$|    - \"--system-default-registry=${PRIVATE_REGISTRY}/docker.io\"|" "$file"
    else
        sedi "/__SECRET_MOUNTS__/d" "$file"
        sedi "/__EXTRA_SERVER_ARGS__/d" "$file"
    fi
}
