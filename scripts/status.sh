#!/usr/bin/env bash
#
# Read-only snapshot of the cluster's security posture. Changes nothing.
#
# Usage: scripts/status.sh
# Env:   CLUSTER_NAME, [RESOURCE_GROUP]

set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

row() { printf '    %-34s %s\n' "$1" "${2:-not set}"; }

main() {
    require_cmd az
    require_var CLUSTER_NAME
    resolve_cluster

    log_step "Cluster ${CLUSTER_NAME} (${RESOURCE_GROUP})"
    row "kubernetes version"      "$(aks_query 'currentKubernetesVersion')"
    row "power state"             "$(aks_query 'powerState.code')"
    row "node count"              "$(aks_query 'agentPoolProfiles[0].count')"
    row "node size"               "$(aks_query 'agentPoolProfiles[0].vmSize')"

    log_step "Control plane exposure"
    row "public access"           "$(aks_query 'apiServerAccessProfile.enablePrivateCluster' | grep -q true && echo private || echo public)"
    row "authorized ip ranges"    "$(aks_query 'apiServerAccessProfile.authorizedIpRanges | join('\'','\'', @)')"

    log_step "Identity and authorization"
    row "entra id integration"    "$(aks_query 'aadProfile.managed')"
    row "azure rbac"              "$(aks_query 'aadProfile.enableAzureRbac')"
    row "admin group object ids"  "$(aks_query 'aadProfile.adminGroupObjectIDs | join('\'','\'', @)')"
    row "local accounts disabled" "$(aks_query 'disableLocalAccounts')"

    if [[ -n "${ADMIN_GROUP:-}" ]]; then
        row "members of ${ADMIN_GROUP}" \
            "$(az ad group member list --group "${ADMIN_GROUP}" --query "length(@)" -o tsv 2>/dev/null || echo '?')"
    fi
    if [[ -n "${READER_GROUP:-}" ]]; then
        row "members of ${READER_GROUP}" \
            "$(az ad group member list --group "${READER_GROUP}" --query "length(@)" -o tsv 2>/dev/null || echo '?')"
    fi

    log_step "Workload identity"
    row "oidc issuer"             "$(aks_query 'oidcIssuerProfile.enabled')"
    row "workload identity"       "$(aks_query 'securityProfile.workloadIdentity.enabled')"

    log_step "In-cluster objects"
    if kubectl cluster-info >/dev/null 2>&1; then
        row "reader clusterrolebinding" \
            "$(kubectl get clusterrolebinding aks-lab-reader-view -o name 2>/dev/null || echo absent)"
        row "namespace ${PROD_NAMESPACE:-prod}" \
            "$(kubectl get ns "${PROD_NAMESPACE:-prod}" -o name 2>/dev/null || echo absent)"
        row "resource quota" \
            "$(kubectl get resourcequota -n "${PROD_NAMESPACE:-prod}" -o name 2>/dev/null | tr '\n' ' ' || echo absent)"
        row "limit range" \
            "$(kubectl get limitrange -n "${PROD_NAMESPACE:-prod}" -o name 2>/dev/null | tr '\n' ' ' || echo absent)"
    else
        log_warn "cluster unreachable with the current kubeconfig, in-cluster state not read"
    fi
    printf '\n'
}

main "$@"
