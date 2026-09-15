# AKS cluster access hardening.
#
#   make setup     run every hardening step, in order
#   make status    read-only snapshot of the current posture
#   make check-up  assert the expected posture, non-zero exit on failure
#
# Configuration lives in scripts/config.env (git-ignored).
# Start from scripts/config.env.example.

SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

CONFIG := scripts/config.env
ifneq (,$(wildcard $(CONFIG)))
include $(CONFIG)
export
endif

SCRIPTS := scripts

.PHONY: help setup status check-up step-1 step-2 step-3 step-4 config lint

##@ Help

help: ## Display this help
	@$(SCRIPTS)/help.sh

##@ Setup

config: ## Create scripts/config.env from the example
	@test -f $(CONFIG) && echo "$(CONFIG) already exists, left untouched" \
		|| { cp $(CONFIG).example $(CONFIG); echo "created $(CONFIG), edit it before running setup"; }

##@ Hardening

setup: step-1 step-2 step-3 step-4 ## Run every hardening step in order
	@echo
	@echo "setup complete, run 'make check-up' to verify"

step-1: ## API server IP allowlist
	@$(SCRIPTS)/01-whitelist-ip.sh

step-2: ## Entra ID authentication, RBAC, local accounts disabled
	@$(SCRIPTS)/02-entra-id-rbac.sh

step-3: ## prod namespace and resource limits
	@$(SCRIPTS)/03-prod-namespace.sh

step-4: ## Workload identity
	@$(SCRIPTS)/04-workload-identity.sh

##@ Verification

status: ## Read-only snapshot of the current posture
	@$(SCRIPTS)/status.sh

check-up: ## Assert the expected posture, fails if anything is off
	@$(SCRIPTS)/check.sh

lint: ## Run shellcheck over the scripts
	@command -v shellcheck >/dev/null 2>&1 \
		|| { echo "shellcheck not installed"; exit 1; }
	@shellcheck -x $(SCRIPTS)/*.sh $(SCRIPTS)/lib/*.sh && echo "shellcheck clean"
