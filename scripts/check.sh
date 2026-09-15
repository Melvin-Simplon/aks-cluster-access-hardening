#!/usr/bin/env bash
#
# Assert the expected security posture. Exits non-zero if anything is off, so
# it can gate a pipeline or a demo.
#
# Usage: scripts/check.sh
# Env:   CLUSTER_NAME, [RESOURCE_GROUP], [ADMIN_GROUP], [READER_GROUP]

set -uo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

FAILURES=0

assert() {
    local label="$1" expected="$2" actual="$3"
    if [[ "${actual}" == "${expected}" ]]; then
        log_ok "${label}"
    else
        log_err "${label} (expected '${expected}', got '${actual:-empty}')"
        FAILURES=$((FAILURES + 1))
    fi
}

assert_not_empty() {
    local label="$1" actual="$2"
    if [[ -n "${actual}" && "${actual}" != "null" ]]; then
        log_ok "${label}: ${actual}"
    else
        log_err "${label} is empty"
        FAILURES=$((FAILURES + 1))
    fi
}

main() {
    require_cmd az
    require_var CLUSTER_NAME
    resolve_cluster

    log_step "Control plane exposure"
    assert_not_empty "api server allowlist is set" \
        "$(aks_query 'apiServerAccessProfile.authorizedIpRanges | join('\'','\'', @)')"

    log_step "Identity"
    assert "entra id integration enabled" "true"  "$(aks_query 'aadProfile.managed')"
    assert "local accounts disabled"      "true"  "$(aks_query 'disableLocalAccounts')"
    assert_not_empty "admin group declared on the cluster" \
        "$(aks_query 'aadProfile.adminGroupObjectIDs | join('\'','\'', @)')"

    if [[ -n "${ADMIN_GROUP:-}" ]]; then
        local members
        members=$(az ad group member list --group "${ADMIN_GROUP}" --query "length(@)" -o tsv 2>/dev/null || echo 0)
        if [[ "${members}" -gt 0 ]]; then
            log_ok "admin group has ${members} member(s)"
        else
            log_err "admin group '${ADMIN_GROUP}' is empty, nobody can administer the cluster"
            FAILURES=$((FAILURES + 1))
        fi
    fi

    log_step "Workload identity"
    assert "oidc issuer enabled"       "true" "$(aks_query 'oidcIssuerProfile.enabled')"
    assert "workload identity enabled" "true" "$(aks_query 'securityProfile.workloadIdentity.enabled')"

    log_step "In-cluster objects"
    if kubectl cluster-info >/dev/null 2>&1; then
        local ns="${PROD_NAMESPACE:-prod}"
        if kubectl get clusterrolebinding aks-lab-reader-view >/dev/null 2>&1; then
            log_ok "reader ClusterRoleBinding present"
        else
            log_err "reader ClusterRoleBinding missing"
            FAILURES=$((FAILURES + 1))
        fi
        if kubectl get resourcequota -n "${ns}" >/dev/null 2>&1 \
           && [[ -n "$(kubectl get resourcequota -n "${ns}" -o name 2>/dev/null)" ]]; then
            log_ok "resource quota present in ${ns}"
        else
            log_err "no resource quota in namespace ${ns}"
            FAILURES=$((FAILURES + 1))
        fi
        if [[ -n "$(kubectl get limitrange -n "${ns}" -o name 2>/dev/null)" ]]; then
            log_ok "limit range present in ${ns}"
        else
            log_err "no limit range in namespace ${ns}"
            FAILURES=$((FAILURES + 1))
        fi
    else
        log_warn "cluster unreachable, in-cluster assertions skipped"
    fi

    printf '\n'
    if [[ "${FAILURES}" -eq 0 ]]; then
        log_ok "all checks passed"
        return 0
    fi
    log_err "${FAILURES} check(s) failed"
    return 1
}

main "$@"
