#!/usr/bin/env bash

issue_forge_consumer_config_error() {
  printf '%s\n' "$1" >&2
  exit 1
}

require_consumer_config_value() {
  local variable_name="$1"
  local description="$2"
  local value="${!variable_name-}"

  if [[ -z "$value" ]]; then
    issue_forge_consumer_config_error "Missing required consumer config: ${description} (${variable_name})"
  fi
}

validate_consumer_project_config() {
  require_consumer_config_value CODEX_FLOW_BASE_REF 'base ref'
  require_consumer_config_value CODEX_FLOW_BASE_BRANCH 'base branch'
  require_consumer_config_value CODEX_FLOW_BRANCH_PREFIX 'branch prefix'
  require_consumer_config_value CODEX_FLOW_CHECKS_COMMAND 'checks command'
  require_consumer_config_value CODEX_FLOW_PROMPTS_DIR 'prompts directory'
  require_consumer_config_value CODEX_FLOW_PR_DRAFT_DEFAULT 'PR draft default'
  require_consumer_config_value CODEX_FLOW_PROFILE_WRITE_SANDBOX 'write profile sandbox'
  require_consumer_config_value CODEX_FLOW_PROFILE_WRITE_REASONING 'write profile reasoning'
  require_consumer_config_value CODEX_FLOW_PROFILE_READ_SANDBOX 'read profile sandbox'
  require_consumer_config_value CODEX_FLOW_PROFILE_READ_REASONING 'read profile reasoning'

  if [[ ! "${CODEX_FLOW_PR_DRAFT_DEFAULT}" =~ ^[0-9]+$ ]]; then
    issue_forge_consumer_config_error "PR draft default must be a non-negative integer: ${CODEX_FLOW_PR_DRAFT_DEFAULT}"
  fi
}

issue_forge_load_consumer_config() {
  local repo_root="${1:?repo root is required}"
  local config_file="${repo_root}/.issue_forge/project.sh"

  if [[ ! -f "${config_file}" ]]; then
    issue_forge_consumer_config_error "Missing consumer config: ${config_file}"
  fi

  readonly CODEX_FLOW_REPO_ROOT="${repo_root}"

  # shellcheck source=/dev/null
  source "${config_file}"
  validate_consumer_project_config
}
