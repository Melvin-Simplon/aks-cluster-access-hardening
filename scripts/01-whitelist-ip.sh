#!/usr/bin/env bash
#
# Step 1: restrict the API server to an authorized IP range.
#
# Usage: scripts/01-whitelist-ip.sh
# Env:   CLUSTER_NAME, ALLOWED_CIDR, [RESOURCE_GROUP], [DRY_RUN], [ASSUME_YES]

set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

main() {
    require_cmd az curl
    require_var CLUSTER_NAME ALLOWED_CIDR
    resolve_cluster

    log_step "Step 1: API server IP allowlist"

    local current
    current=$(aks_query "apiServerAccessProfile.authorizedIpRanges | join(',', @)")
    log_info "current allowlist: ${current:-none}"
    log_info "requested         : ${ALLOWED_CIDR}"

    if [[ "${current}" == "${ALLOWED_CIDR}" ]]; then
        log_ok "already applied, nothing to do"
        return 0
    fi

    # Lockout guard. Applying a range that does not cover the caller's egress
    # address costs administrative access to the cluster immediately.
    local my_ip
    my_ip=$(curl -fsS --max-time 10 https://api.ipify.org || true)
    if [[ -z "${my_ip}" ]]; then
        log_warn "could not determine this machine's public address"
    else
        log_info "this machine's public address: ${my_ip}"
        if [[ ",${ALLOWED_CIDR}," != *",${my_ip}/32,"* ]]; then
            log_warn "${my_ip} is not listed explicitly as ${my_ip}/32"
            log_warn "if it is not covered by one of the ranges above, you WILL lose access"
            confirm "apply anyway?" || die "aborted"
        fi
    fi

    run az aks update \
        --resource-group "${RESOURCE_GROUP}" \
        --name "${CLUSTER_NAME}" \
        --api-server-authorized-ip-ranges "${ALLOWED_CIDR}" \
        --only-show-errors \
        --output none

    log_ok "allowlist applied, rules take up to 2 minutes to propagate"
}

main "$@"
