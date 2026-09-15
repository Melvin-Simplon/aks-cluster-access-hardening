#!/usr/bin/env bash
#
# Step 2: Entra ID authentication, group based RBAC, local accounts disabled.
#
# Usage: scripts/02-entra-id-rbac.sh
# Env:   CLUSTER_NAME, ADMIN_GROUP, READER_GROUP, [RESOURCE_GROUP],
#        [DRY_RUN], [ASSUME_YES]

set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

# Returns the group object id on stdout, so every message it emits has to go to
# stderr. Otherwise the logs end up inside the caller's variable.
ensure_group() {
    local name="$1" id
    id=$(group_id "${name}")
    if [[ -n "${id}" ]]; then
        log_ok "group '${name}' exists (${id})" >&2
    else
        log_info "creating group '${name}'" >&2
        run az ad group create --display-name "${name}" --mail-nickname "${name}" --output none >&2
        id=$(group_id "${name}")
    fi
    printf '%s' "${id}"
}

main() {
    require_cmd az kubectl
    require_var CLUSTER_NAME ADMIN_GROUP READER_GROUP
    resolve_cluster

    log_step "Step 2: Entra ID authentication and Kubernetes RBAC"

    local admin_id reader_id
    admin_id=$(ensure_group "${ADMIN_GROUP}")
    reader_id=$(ensure_group "${READER_GROUP}")

    # An admin group with no members plus local accounts disabled locks
    # everyone out of the cluster. Refuse to walk into that.
    local members
    members=$(az ad group member list --group "${ADMIN_GROUP}" --query "length(@)" -o tsv 2>/dev/null || echo 0)
    if [[ "${members}" == "0" ]]; then
        log_warn "admin group '${ADMIN_GROUP}' has no members"
        if confirm "add the signed-in user to it?"; then
            local me
            me=$(az ad signed-in-user show --query id -o tsv)
            run az ad group member add --group "${ADMIN_GROUP}" --member-id "${me}" --output none
        else
            die "refusing to continue with an empty admin group"
        fi
    fi

    # Azure rejects --enable-aad on a cluster where managed Entra ID is already
    # on, so the flag is only passed the first time. Afterwards the admin group
    # is updated on its own, and only when it actually differs.
    log_step "Enabling Entra ID integration"
    if [[ "$(aks_query 'aadProfile.managed')" == "true" ]]; then
        log_ok "already enabled"
        if [[ "$(aks_query 'aadProfile.adminGroupObjectIDs')" == *"${admin_id}"* ]]; then
            log_ok "admin group already declared on the cluster"
        else
            log_info "declaring '${ADMIN_GROUP}' as the cluster admin group"
            run az aks update \
                --resource-group "${RESOURCE_GROUP}" \
                --name "${CLUSTER_NAME}" \
                --aad-admin-group-object-ids "${admin_id}" \
                --only-show-errors \
                --output none
        fi
    else
        run az aks update \
            --resource-group "${RESOURCE_GROUP}" \
            --name "${CLUSTER_NAME}" \
            --enable-aad \
            --aad-admin-group-object-ids "${admin_id}" \
            --only-show-errors \
            --output none
    fi

    log_step "Binding the readers group to the view ClusterRole"
    local manifest
    manifest="$(repo_root)/k8s/rbac/reader-clusterrolebinding.yaml"
    [[ -f "${manifest}" ]] || die "manifest not found: ${manifest}"
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] would apply ${manifest} with subject ${reader_id}"
    else
        sed "s/__READER_GROUP_OBJECT_ID__/${reader_id}/" "${manifest}" | kubectl apply -f -
    fi

    log_step "Disabling local accounts"
    if [[ "$(aks_query 'disableLocalAccounts')" == "true" ]]; then
        log_ok "already disabled"
    else
        log_warn "this removes the --admin kubeconfig backdoor for everyone"
        if confirm "disable local accounts now?"; then
            run az aks update \
                --resource-group "${RESOURCE_GROUP}" \
                --name "${CLUSTER_NAME}" \
                --disable-local-accounts \
                --only-show-errors \
                --output none
        else
            log_warn "skipped, the cluster keeps a non-auditable admin path"
        fi
    fi

    log_ok "step 2 complete"
}

main "$@"
