#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

usage() {
  printf 'Usage: %s <issue_number> [issue_number ...]\n' "$0"
}

run_queue_step() {
  local issue_number="$1"
  local step_name="$2"
  local status
  shift 2

  if "$@"; then
    return 0
  else
    status="$?"
  fi

  printf '[queue] failed issue %s during %s\n' "$issue_number" "$step_name" >&2
  exit "$status"
}

declare -a issue_numbers=()

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      printf 'Unknown option: %s\n' "$1" >&2
      usage >&2
      exit 1
      ;;
    *)
      issue_numbers+=("$1")
      shift
      ;;
  esac
done

if [[ "${#issue_numbers[@]}" -eq 0 ]]; then
  usage >&2
  exit 1
fi

# shellcheck source=tools/codex/lib/config.sh
source "${SCRIPT_DIR}/lib/config.sh"
# shellcheck source=tools/codex/lib/flow_state.sh
source "${SCRIPT_DIR}/lib/flow_state.sh"

for issue_number in "${issue_numbers[@]}"; do
  require_numeric_issue_number "$issue_number"
done

enter_repo_root

total_issues="${#issue_numbers[@]}"
issue_index=0

for issue_number in "${issue_numbers[@]}"; do
  issue_index=$((issue_index + 1))
  printf '[queue] starting issue %s (%s/%s)\n' "$issue_number" "$issue_index" "$total_issues"

  rm -rf "$CODEX_FLOW_CODEX_DIR"
  run_queue_step "$issue_number" 'start_from_issue.sh' \
    "${ISSUE_FORGE_ENGINE_ISSUE_DIR}/start_from_issue.sh" "$issue_number"
  run_queue_step "$issue_number" 'run_issue_flow.sh' \
    "${ISSUE_FORGE_ENGINE_CODEX_DIR}/run_issue_flow.sh" "$issue_number"

  printf '[queue] finished issue %s (%s/%s)\n' "$issue_number" "$issue_index" "$total_issues"
done

printf '[queue] completed %s issue(s)\n' "$total_issues"
