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

validate_non_negative_integer_config() {
  local variable_name="$1"
  local description="$2"
  local value="${!variable_name-}"

  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    issue_forge_consumer_config_error "${description} must be a non-negative integer: ${value}"
  fi
}

validate_positive_integer_config() {
  local variable_name="$1"
  local description="$2"
  local value="${!variable_name-}"

  validate_non_negative_integer_config "$variable_name" "$description"
  if [[ "$value" -eq 0 ]]; then
    issue_forge_consumer_config_error "${description} must be a positive integer: ${value}"
  fi
}

validate_nonempty_no_whitespace_config() {
  local variable_name="$1"
  local description="$2"
  local value="${!variable_name-}"

  require_consumer_config_value "$variable_name" "$description"
  if [[ "$value" =~ [[:space:]] ]]; then
    issue_forge_consumer_config_error "${description} must not contain whitespace: ${value}"
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
  require_consumer_config_value CODEX_FLOW_IMPLEMENTATION_REASONING 'implementation reasoning'
  require_consumer_config_value CODEX_FLOW_CHECK_FIX_REASONING 'check fix reasoning'
  require_consumer_config_value CODEX_FLOW_REVIEW_REASONING 'review reasoning'
  require_consumer_config_value CODEX_FLOW_REVIEW_FIX_REASONING 'review fix reasoning'
  require_consumer_config_value CODEX_FLOW_BATCH_BRANCH_PREFIX 'batch branch prefix'
  require_consumer_config_value CODEX_FLOW_QUEUE_REVIEW_EVERY 'queue review interval'
  require_consumer_config_value CODEX_FLOW_QUEUE_LIGHT_ISSUE_REVIEW 'queue light issue review'
  require_consumer_config_value CODEX_FLOW_BATCH_PR_DRAFT_DEFAULT 'batch PR draft default'
  require_consumer_config_value CODEX_FLOW_BATCH_REVIEW_REASONING 'batch review reasoning'
  require_consumer_config_value CODEX_FLOW_BATCH_FIX_REASONING 'batch fix reasoning'
  require_consumer_config_value CODEX_FLOW_BATCH_CHECK_FIX_REASONING 'batch check fix reasoning'
  require_consumer_config_value CODEX_FLOW_BATCH_REVIEW_MAX_FIX_ROUNDS 'batch review max fix rounds'
  require_consumer_config_value CODEX_FLOW_BATCH_CHECK_MAX_FIX_ROUNDS 'batch check max fix rounds'
  require_consumer_config_value CODEX_FLOW_AUTO_MERGE_WAIT_SECONDS 'auto-merge wait seconds'
  require_consumer_config_value CODEX_FLOW_AUTO_MERGE_POLL_SECONDS 'auto-merge poll seconds'

  validate_non_negative_integer_config CODEX_FLOW_PR_DRAFT_DEFAULT 'PR draft default'
  validate_nonempty_no_whitespace_config CODEX_FLOW_IMPLEMENTATION_REASONING 'implementation reasoning'
  validate_nonempty_no_whitespace_config CODEX_FLOW_CHECK_FIX_REASONING 'check fix reasoning'
  validate_nonempty_no_whitespace_config CODEX_FLOW_REVIEW_REASONING 'review reasoning'
  validate_nonempty_no_whitespace_config CODEX_FLOW_REVIEW_FIX_REASONING 'review fix reasoning'
  validate_nonempty_no_whitespace_config CODEX_FLOW_BATCH_BRANCH_PREFIX 'batch branch prefix'
  validate_positive_integer_config CODEX_FLOW_QUEUE_REVIEW_EVERY 'queue review interval'
  validate_non_negative_integer_config CODEX_FLOW_QUEUE_LIGHT_ISSUE_REVIEW 'queue light issue review'
  validate_non_negative_integer_config CODEX_FLOW_BATCH_PR_DRAFT_DEFAULT 'batch PR draft default'
  validate_nonempty_no_whitespace_config CODEX_FLOW_BATCH_REVIEW_REASONING 'batch review reasoning'
  validate_nonempty_no_whitespace_config CODEX_FLOW_BATCH_FIX_REASONING 'batch fix reasoning'
  validate_nonempty_no_whitespace_config CODEX_FLOW_BATCH_CHECK_FIX_REASONING 'batch check fix reasoning'
  validate_non_negative_integer_config CODEX_FLOW_BATCH_REVIEW_MAX_FIX_ROUNDS 'batch review max fix rounds'
  validate_non_negative_integer_config CODEX_FLOW_BATCH_CHECK_MAX_FIX_ROUNDS 'batch check max fix rounds'
  validate_positive_integer_config CODEX_FLOW_AUTO_MERGE_WAIT_SECONDS 'auto-merge wait seconds'
  validate_positive_integer_config CODEX_FLOW_AUTO_MERGE_POLL_SECONDS 'auto-merge poll seconds'
}

apply_consumer_project_defaults() {
  : "${CODEX_FLOW_BASE_BRANCH:=main}"
  : "${CODEX_FLOW_BASE_REF:=origin/${CODEX_FLOW_BASE_BRANCH}}"
  : "${CODEX_FLOW_BRANCH_PREFIX:=issue/}"
  : "${CODEX_FLOW_CHECKS_COMMAND:=./.issue_forge/checks/run_changed.sh}"
  : "${CODEX_FLOW_PROMPTS_DIR:=${ISSUE_FORGE_ENGINE_ROOT}/tools/codex/prompts}"
  : "${CODEX_FLOW_PR_DRAFT_DEFAULT:=1}"
  : "${CODEX_FLOW_PROFILE_WRITE_SANDBOX:=danger-full-access}"
  : "${CODEX_FLOW_PROFILE_WRITE_REASONING:=xhigh}"
  : "${CODEX_FLOW_PROFILE_READ_SANDBOX:=danger-full-access}"
  : "${CODEX_FLOW_PROFILE_READ_REASONING:=medium}"
  : "${CODEX_FLOW_IMPLEMENTATION_REASONING:=${CODEX_FLOW_PROFILE_WRITE_REASONING}}"
  : "${CODEX_FLOW_CHECK_FIX_REASONING:=${CODEX_FLOW_PROFILE_WRITE_REASONING}}"
  : "${CODEX_FLOW_REVIEW_REASONING:=${CODEX_FLOW_PROFILE_READ_REASONING}}"
  : "${CODEX_FLOW_REVIEW_FIX_REASONING:=${CODEX_FLOW_PROFILE_WRITE_REASONING}}"
  : "${CODEX_FLOW_BATCH_BRANCH_PREFIX:=batch/}"
  : "${CODEX_FLOW_QUEUE_REVIEW_EVERY:=3}"
  : "${CODEX_FLOW_QUEUE_LIGHT_ISSUE_REVIEW:=1}"
  : "${CODEX_FLOW_BATCH_PR_DRAFT_DEFAULT:=0}"
  : "${CODEX_FLOW_BATCH_REVIEW_REASONING:=xhigh}"
  : "${CODEX_FLOW_BATCH_FIX_REASONING:=xhigh}"
  : "${CODEX_FLOW_BATCH_CHECK_FIX_REASONING:=xhigh}"
  : "${CODEX_FLOW_BATCH_REVIEW_MAX_FIX_ROUNDS:=5}"
  : "${CODEX_FLOW_BATCH_CHECK_MAX_FIX_ROUNDS:=5}"
  : "${CODEX_FLOW_AUTO_MERGE_WAIT_SECONDS:=900}"
  : "${CODEX_FLOW_AUTO_MERGE_POLL_SECONDS:=15}"
}

issue_forge_load_consumer_config() {
  local repo_root="${1:?repo root is required}"
  local config_file="${repo_root}/.issue_forge/project.sh"

  if [[ ! -f "${config_file}" ]]; then
    issue_forge_consumer_config_error "Missing consumer config: ${config_file}"
  fi

  # shellcheck disable=SC2034
  readonly CODEX_FLOW_REPO_ROOT="${repo_root}"

  # shellcheck source=/dev/null
  source "${config_file}"
  apply_consumer_project_defaults
  validate_consumer_project_config
}
