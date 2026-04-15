#!/usr/bin/env bash

if [[ -n "${ISSUE_FORGE_RUNTIME_CONFIG_LOADED:-}" ]]; then
  return 0
fi

readonly ISSUE_FORGE_CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ISSUE_FORGE_ENGINE_ROOT="$(cd "${ISSUE_FORGE_CONFIG_DIR}/../../.." && pwd)"
readonly ISSUE_FORGE_ENGINE_PARENT_DIR="$(cd "${ISSUE_FORGE_ENGINE_ROOT}/.." && pwd)"

# shellcheck source=tools/codex/lib/engine_defaults.sh
source "${ISSUE_FORGE_CONFIG_DIR}/engine_defaults.sh"
# shellcheck source=tools/codex/lib/consumer_config.sh
source "${ISSUE_FORGE_CONFIG_DIR}/consumer_config.sh"

resolve_issue_forge_consumer_repo_root() {
  local candidate=""

  if [[ "$(basename "${ISSUE_FORGE_ENGINE_PARENT_DIR}")" == 'vendor' ]]; then
    candidate="$(git -C "${ISSUE_FORGE_ENGINE_PARENT_DIR}" rev-parse --show-toplevel 2>/dev/null || true)"
    if [[ -n "${candidate}" && -f "${candidate}/.issue_forge/project.sh" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  fi

  candidate="$(git -C "${ISSUE_FORGE_ENGINE_ROOT}" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -n "${candidate}" && -f "${candidate}/.issue_forge/project.sh" ]]; then
    printf '%s\n' "${candidate}"
    return 0
  fi

  printf 'Failed to resolve consumer repo root for issue_forge runtime.\n' >&2
  return 1
}

issue_forge_load_consumer_config "$(resolve_issue_forge_consumer_repo_root)"
readonly ISSUE_FORGE_RUNTIME_CONFIG_LOADED=1
