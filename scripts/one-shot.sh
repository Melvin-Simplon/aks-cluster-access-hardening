#!/usr/bin/env bash
#
# Run every hardening step in one go.
#
# Confirms once up front instead of prompting at each step, then runs the four
# steps unattended and finishes with the verification pass.
#
# Usage: scripts/one-shot.sh
# Env:   everything the individual steps need, plus
#        [DRY_RUN]    print the commands without applying them
#        [ASSUME_YES] skip the single confirmation too

set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

readonly STEPS=(
    "01-whitelist-ip.sh"
    "02-entra-id-rbac.sh"
    "03-prod-namespace.sh"
    "04-workload-identity.sh"
)

plan() {
    log_step "One-shot hardening plan"
    printf '    %-24s %s\n' "cluster"        "${CLUSTER_NAME}"
    printf '    %-24s %s\n' "resource group" "${RESOURCE_GROUP}"
    printf '    %-24s %s\n' "allowed cidr"   "${ALLOWED_CIDR:-not set}"
    printf '    %-24s %s\n' "admin group"    "${ADMIN_GROUP:-not set}"
    printf '    %-24s %s\n' "reader group"   "${READER_GROUP:-not set}"
    printf '    %-24s %s\n' "namespace"      "${PROD_NAMESPACE:-prod}"
    printf '\n'
    log_info "this will restrict the API server, switch authentication to Entra ID,"
    log_info "disable the local admin accounts, apply the namespace policy and"
    log_info "enable workload identity, without asking again."
    printf '\n'
    log_warn "two of these steps can cost you access to the cluster if misconfigured:"
    log_warn "  the IP allowlist, if it does not cover your egress address"
    log_warn "  disabling local accounts, if the admin group has no members"
    log_info "each step still refuses to proceed when it detects that situation."
}

main() {
    require_cmd az kubectl
    require_var CLUSTER_NAME
    resolve_cluster

    plan

    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log_info "dry run, nothing will be applied"
    else
        confirm "run all ${#STEPS[@]} steps now?" || die "aborted, nothing applied"
    fi

    # One confirmation covers the whole run, so the steps themselves stop asking.
    export ASSUME_YES=1

    local dir step
    dir="$(dirname "${BASH_SOURCE[0]}")"
    for step in "${STEPS[@]}"; do
        "${dir}/${step}"
    done

    log_step "Verification"
    "${dir}/check.sh"
}

main "$@"
