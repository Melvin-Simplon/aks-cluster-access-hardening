#!/usr/bin/env bash
#
# Step 3: prod namespace and its resource limitation policy.
#
# Usage: scripts/03-prod-namespace.sh
# Env:   [PROD_NAMESPACE], [DRY_RUN]

set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

main() {
    require_cmd kubectl

    log_step "Step 3: prod namespace resource limits"

    local dir
    dir="$(repo_root)/k8s/prod"
    [[ -d "${dir}" ]] || die "manifest directory not found: ${dir}"

    # Fails fast on a cluster the caller cannot reach or has no rights on,
    # rather than printing a wall of RBAC errors.
    kubectl auth can-i create namespace >/dev/null 2>&1 \
        || log_warn "the current context may not allow creating namespaces"

    run kubectl apply -f "${dir}"

    if [[ "${DRY_RUN:-0}" != "1" ]]; then
        kubectl get resourcequota,limitrange -n "${PROD_NAMESPACE:-prod}"
    fi

    log_ok "step 3 complete"
}

main "$@"
