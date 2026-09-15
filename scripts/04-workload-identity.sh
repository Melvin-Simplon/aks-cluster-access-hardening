#!/usr/bin/env bash
#
# Step 4: workload identity, so pods authenticate to Azure without a secret.
#
# Usage: scripts/04-workload-identity.sh
# Env:   CLUSTER_NAME, IDENTITY_NAME, SERVICE_ACCOUNT, PROD_NAMESPACE,
#        [RESOURCE_GROUP], [DRY_RUN], [ASSUME_YES]

set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

main() {
    require_cmd az kubectl
    require_var CLUSTER_NAME IDENTITY_NAME SERVICE_ACCOUNT
    resolve_cluster

    local ns="${PROD_NAMESPACE:-prod}"

    log_step "Step 4: workload identity"

    # Enabling the OIDC issuer briefly interrupts the control plane and cannot
    # be undone afterwards, so it is confirmed rather than applied silently.
    if [[ "$(aks_query 'oidcIssuerProfile.enabled')" == "true" \
       && "$(aks_query 'securityProfile.workloadIdentity.enabled')" == "true" ]]; then
        log_ok "cluster features already enabled"
    else
        log_warn "enabling the OIDC issuer is irreversible and briefly disrupts the control plane"
        confirm "enable the OIDC issuer and workload identity?" || die "aborted"
        run az aks update \
            --resource-group "${RESOURCE_GROUP}" \
            --name "${CLUSTER_NAME}" \
            --enable-oidc-issuer \
            --enable-workload-identity \
            --only-show-errors \
            --output none
    fi

    local issuer
    issuer=$(aks_query 'oidcIssuerProfile.issuerUrl')
    [[ -n "${issuer}" ]] || die "could not read the OIDC issuer url"

    log_step "Managed identity '${IDENTITY_NAME}'"
    if az identity show -g "${RESOURCE_GROUP}" -n "${IDENTITY_NAME}" >/dev/null 2>&1; then
        log_ok "already exists"
    else
        run az identity create -g "${RESOURCE_GROUP}" -n "${IDENTITY_NAME}" --output none
    fi

    local client_id
    client_id=$(az identity show -g "${RESOURCE_GROUP}" -n "${IDENTITY_NAME}" \
        --query clientId -o tsv 2>/dev/null || true)
    [[ -n "${client_id}" || "${DRY_RUN:-0}" == "1" ]] || die "could not read the identity client id"

    log_step "Annotated service account '${SERVICE_ACCOUNT}' in namespace '${ns}'"
    local manifest
    manifest="$(repo_root)/k8s/workload-identity/serviceaccount.yaml"
    [[ -f "${manifest}" ]] || die "manifest not found: ${manifest}"
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] would apply ${manifest}"
    else
        sed "s/__MANAGED_IDENTITY_CLIENT_ID__/${client_id}/" "${manifest}" | kubectl apply -f -
    fi

    log_step "Federated credential"
    local subject="system:serviceaccount:${ns}:${SERVICE_ACCOUNT}"
    if az identity federated-credential show \
        --identity-name "${IDENTITY_NAME}" \
        --resource-group "${RESOURCE_GROUP}" \
        --name "fc-${SERVICE_ACCOUNT}" >/dev/null 2>&1; then
        log_ok "already exists"
    else
        run az identity federated-credential create \
            --name "fc-${SERVICE_ACCOUNT}" \
            --identity-name "${IDENTITY_NAME}" \
            --resource-group "${RESOURCE_GROUP}" \
            --issuer "${issuer}" \
            --subject "${subject}" \
            --audience api://AzureADTokenExchange \
            --output none
        log_info "propagation takes a few seconds before the first token request succeeds"
    fi

    log_ok "step 4 complete, trust declared for ${subject}"
}

main "$@"
