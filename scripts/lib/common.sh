#!/usr/bin/env bash
# Shared helpers for the hardening scripts.
# Sourced, never executed directly.

# ---------------------------------------------------------------- output ----

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    readonly C_RESET=$'\033[0m'
    readonly C_RED=$'\033[31m'
    readonly C_GREEN=$'\033[32m'
    readonly C_YELLOW=$'\033[33m'
    readonly C_BLUE=$'\033[34m'
    readonly C_BOLD=$'\033[1m'
else
    readonly C_RESET='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_BOLD=''
fi

log_step() { printf '\n%s==> %s%s\n' "${C_BOLD}${C_BLUE}" "$*" "${C_RESET}"; }
log_info() { printf '    %s\n' "$*"; }
log_ok()   { printf '  %sOK%s  %s\n' "${C_GREEN}" "${C_RESET}" "$*"; }
log_warn() { printf '  %sWARN%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2; }
log_err()  { printf '  %sFAIL%s %s\n' "${C_RED}" "${C_RESET}" "$*" >&2; }

die() {
    log_err "$*"
    exit 1
}

# ---------------------------------------------------------------- guards ----

require_cmd() {
    local cmd
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"
    done
}

require_var() {
    local name
    for name in "$@"; do
        [[ -n "${!name:-}" ]] || die "required variable not set: $name (see scripts/config.env.example)"
    done
}

# Ask before doing something that is awkward to undo.
# Skipped entirely when ASSUME_YES=1, so the scripts stay usable from CI.
confirm() {
    local prompt="$1" answer
    if [[ "${ASSUME_YES:-0}" == "1" ]]; then
        log_info "auto-confirmed: ${prompt}"
        return 0
    fi
    if [[ ! -t 0 ]]; then
        die "confirmation needed but stdin is not a terminal: ${prompt} (set ASSUME_YES=1 to skip)"
    fi
    read -r -p "  ${prompt} [y/N] " answer
    [[ "${answer}" =~ ^[yY]$ ]]
}

# Echo a command, then run it unless DRY_RUN=1.
run() {
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        printf '  %s[dry-run]%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*"
        return 0
    fi
    printf '  %s$%s %s\n' "${C_BOLD}" "${C_RESET}" "$*"
    "$@"
}

# --------------------------------------------------------------- context ----

# Resolve RESOURCE_GROUP from CLUSTER_NAME when it was not provided, so that a
# cluster name alone is enough to drive every script.
resolve_cluster() {
    require_cmd az
    require_var CLUSTER_NAME

    if [[ -z "${RESOURCE_GROUP:-}" ]]; then
        RESOURCE_GROUP=$(az aks list \
            --query "[?name=='${CLUSTER_NAME}'].resourceGroup | [0]" -o tsv 2>/dev/null || true)
        [[ -n "${RESOURCE_GROUP}" && "${RESOURCE_GROUP}" != "null" ]] \
            || die "cluster '${CLUSTER_NAME}' not found in the current subscription"
        log_info "resolved resource group: ${RESOURCE_GROUP}"
    fi
    export RESOURCE_GROUP
}

aks_query() {
    az aks show -g "${RESOURCE_GROUP}" -n "${CLUSTER_NAME}" --query "$1" -o tsv 2>/dev/null || true
}

# Object id of an Entra group, empty when the group does not exist.
group_id() {
    az ad group show --group "$1" --query id -o tsv 2>/dev/null || true
}

PROJECT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
export PROJECT_ROOT

repo_root() { printf '%s' "${PROJECT_ROOT}"; }
