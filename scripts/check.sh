#!/usr/bin/env bash
#
# Assert the expected security posture and print an Ansible style report.
#
# The report goes to stdout, diagnostics go to stderr, and the exit code is the
# machine readable answer: 0 when everything is in place, 1 otherwise.
#
# Usage: scripts/check.sh
# Env:   CLUSTER_NAME, [RESOURCE_GROUP], [ADMIN_GROUP], [READER_GROUP],
#        [PROD_NAMESPACE]

set -uo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

OK_COUNT=0
FAILED_COUNT=0
SKIPPED_COUNT=0

readonly LABEL_WIDTH=30
readonly STATUS_WIDTH=9

section() {
    printf '\n%s%s%s\n' "${C_BOLD}" "$1" "${C_RESET}"
}

# report <label> <ok|failed|skipped> [value]
report() {
    local label="$1" status="$2" value="${3:-}" color
    case "${status}" in
        ok)      color="${C_GREEN}";  OK_COUNT=$((OK_COUNT + 1)) ;;
        failed)  color="${C_RED}";    FAILED_COUNT=$((FAILED_COUNT + 1)) ;;
        skipped) color="${C_YELLOW}"; SKIPPED_COUNT=$((SKIPPED_COUNT + 1)) ;;
        *)       color="${C_RESET}" ;;
    esac
    printf '  %-*s %s%-*s%s %s\n' \
        "${LABEL_WIDTH}" "${label}" \
        "${color}" "${STATUS_WIDTH}" "${status}" "${C_RESET}" \
        "${value}"
}

# Keep object ids and long lists readable in a fixed width column.
short() {
    local value="$1" max="${2:-24}"
    if [[ "${#value}" -gt "${max}" ]]; then
        printf '%s...' "${value:0:max}"
    else
        printf '%s' "${value}"
    fi
}

# expect <label> <expected> <actual> [display]
expect() {
    local label="$1" expected="$2" actual="$3" display="${4:-}"
    if [[ "${actual}" == "${expected}" ]]; then
        report "${label}" ok "${display:-${actual}}"
    else
        report "${label}" failed "expected ${expected}, got ${actual:-empty}"
    fi
}

# expect_set <label> <actual>
expect_set() {
    local label="$1" actual="$2"
    if [[ -n "${actual}" && "${actual}" != "null" ]]; then
        report "${label}" ok "$(short "${actual}")"
    else
        report "${label}" failed "not set"
    fi
}

recap() {
    local line status
    line=$(printf '_%.0s' $(seq 1 44))
    printf '\n%sRECAP%s %s\n' "${C_BOLD}" "${C_RESET}" "${line}"
    if [[ "${FAILED_COUNT}" -eq 0 ]]; then
        status="${C_GREEN}"
    else
        status="${C_RED}"
    fi
    printf '%s%s%s : ok=%d  failed=%d  skipped=%d\n\n' \
        "${status}" "${CLUSTER_NAME}" "${C_RESET}" \
        "${OK_COUNT}" "${FAILED_COUNT}" "${SKIPPED_COUNT}"
}

check_control_plane() {
    section "Control plane exposure"
    expect_set "api server allowlist" \
        "$(aks_query 'apiServerAccessProfile.authorizedIpRanges')"
}

check_identity() {
    section "Identity"
    expect "entra id integration" "true" "$(aks_query 'aadProfile.managed')" "enabled"
    expect "local accounts"       "true" "$(aks_query 'disableLocalAccounts')" "disabled"
    expect_set "admin group declared" "$(aks_query 'aadProfile.adminGroupObjectIDs')"

    local group members
    for group in "${ADMIN_GROUP:-}" "${READER_GROUP:-}"; do
        [[ -n "${group}" ]] || continue
        members=$(az ad group member list --group "${group}" --query "length(@)" -o tsv 2>/dev/null)
        if [[ -z "${members}" ]]; then
            report "${group} membership" skipped "group not readable"
        elif [[ "${members}" -gt 0 ]]; then
            report "${group} membership" ok "${members} member(s)"
        else
            report "${group} membership" failed "0 members"
        fi
    done
}

check_workload_identity() {
    section "Workload identity"
    expect "oidc issuer"       "true" "$(aks_query 'oidcIssuerProfile.enabled')" "enabled"
    expect "workload identity" "true" "$(aks_query 'securityProfile.workloadIdentity.enabled')" "enabled"
}

check_cluster_objects() {
    local ns="${PROD_NAMESPACE:-prod}"
    section "In-cluster objects"

    if ! kubectl cluster-info >/dev/null 2>&1; then
        log_warn "cluster unreachable with the current kubeconfig"
        report "reader clusterrolebinding" skipped "cluster unreachable"
        report "resource quota"            skipped "cluster unreachable"
        report "limit range"               skipped "cluster unreachable"
        return
    fi

    local found
    found=$(kubectl get clusterrolebinding aks-lab-reader-view -o name 2>/dev/null)
    if [[ -n "${found}" ]]; then
        report "reader clusterrolebinding" ok "present"
    else
        report "reader clusterrolebinding" failed "absent"
    fi

    found=$(kubectl get resourcequota -n "${ns}" -o name 2>/dev/null | head -1)
    if [[ -n "${found}" ]]; then
        report "resource quota" ok "${found#*/}"
    else
        report "resource quota" failed "none in ${ns}"
    fi

    found=$(kubectl get limitrange -n "${ns}" -o name 2>/dev/null | head -1)
    if [[ -n "${found}" ]]; then
        report "limit range" ok "${found#*/}"
    else
        report "limit range" failed "none in ${ns}"
    fi
}

main() {
    require_cmd az
    require_var CLUSTER_NAME
    resolve_cluster >&2

    check_control_plane
    check_identity
    check_workload_identity
    check_cluster_objects
    recap

    [[ "${FAILED_COUNT}" -eq 0 ]]
}

main "$@"
