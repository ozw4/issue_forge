#!/usr/bin/env bash

if [[ -n "${ISSUE_FORGE_RUNTIME_CONFIG_LOADED:-}" ]]; then
  return 0
fi

ISSUE_FORGE_CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ISSUE_FORGE_CONFIG_DIR
ISSUE_FORGE_ENGINE_CODEX_DIR="$(cd "${ISSUE_FORGE_CONFIG_DIR}/.." && pwd)"
readonly ISSUE_FORGE_ENGINE_CODEX_DIR
# shellcheck disable=SC2034
ISSUE_FORGE_ENGINE_ISSUE_DIR="$(cd "${ISSUE_FORGE_ENGINE_CODEX_DIR}/../issue" && pwd)"
# shellcheck disable=SC2034
readonly ISSUE_FORGE_ENGINE_ISSUE_DIR
ISSUE_FORGE_ENGINE_ROOT="$(cd "${ISSUE_FORGE_ENGINE_CODEX_DIR}/../.." && pwd)"
readonly ISSUE_FORGE_ENGINE_ROOT
ISSUE_FORGE_ENGINE_PARENT_DIR="$(cd "${ISSUE_FORGE_ENGINE_ROOT}/.." && pwd)"
readonly ISSUE_FORGE_ENGINE_PARENT_DIR

# shellcheck source=tools/codex/lib/engine_defaults.sh
source "${ISSUE_FORGE_CONFIG_DIR}/engine_defaults.sh"
# shellcheck source=tools/codex/lib/consumer_config.sh
source "${ISSUE_FORGE_CONFIG_DIR}/consumer_config.sh"

issue_forge_config_error() {
  printf '%s\n' "$1" >&2
  exit 1
}

issue_forge_resolve_absolute_directory() {
  local input_path="$1"

  cd "${input_path}" 2>/dev/null && pwd
}

issue_forge_git_root_with_consumer_config() {
  local search_path="$1"
  local candidate

  candidate="$(git -C "${search_path}" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -z "${candidate}" || ! -f "${candidate}/.issue_forge/project.sh" ]]; then
    return 1
  fi

  printf '%s\n' "${candidate}"
}

resolve_issue_forge_consumer_root_from_env() {
  local configured_root="${ISSUE_FORGE_CONSUMER_ROOT:-}"
  local candidate

  if [[ -z "${configured_root}" ]]; then
    return 1
  fi

  if ! candidate="$(issue_forge_resolve_absolute_directory "${configured_root}")"; then
    issue_forge_config_error "Invalid ISSUE_FORGE_CONSUMER_ROOT directory: ${configured_root}"
  fi

  if [[ ! -f "${candidate}/.issue_forge/project.sh" ]]; then
    issue_forge_config_error "Invalid ISSUE_FORGE_CONSUMER_ROOT: ${candidate} does not contain .issue_forge/project.sh"
  fi

  printf '%s\n' "${candidate}"
}

resolve_issue_forge_consumer_repo_root() {
  local candidate=""

  if [[ -n "${ISSUE_FORGE_CONSUMER_ROOT:-}" ]]; then
    resolve_issue_forge_consumer_root_from_env
    return 0
  fi

  if candidate="$(issue_forge_git_root_with_consumer_config "${PWD}")"; then
    if [[ "${candidate}" != "${ISSUE_FORGE_ENGINE_ROOT}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  fi

  if [[ "$(basename "${ISSUE_FORGE_ENGINE_PARENT_DIR}")" == 'vendor' ]]; then
    if candidate="$(issue_forge_git_root_with_consumer_config "${ISSUE_FORGE_ENGINE_PARENT_DIR}")"; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  fi

  if candidate="$(issue_forge_git_root_with_consumer_config "${ISSUE_FORGE_ENGINE_ROOT}")"; then
    printf '%s\n' "${candidate}"
    return 0
  fi

  issue_forge_config_error 'Failed to resolve consumer repo root for issue_forge runtime. Run from the consumer repo root or set ISSUE_FORGE_CONSUMER_ROOT.'
}

if ! CODEX_FLOW_RESOLVED_REPO_ROOT="$(resolve_issue_forge_consumer_repo_root)"; then
  exit 1
fi

issue_forge_load_consumer_config "${CODEX_FLOW_RESOLVED_REPO_ROOT}"
unset CODEX_FLOW_RESOLVED_REPO_ROOT
readonly ISSUE_FORGE_RUNTIME_CONFIG_LOADED=1
