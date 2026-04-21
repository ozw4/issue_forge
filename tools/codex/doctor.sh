#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

declare -a failures=()
declare -a warnings=()
ok_count=0

log_result() {
  local level="$1"
  local message="$2"

  printf '%-4s %s\n' "$level" "$message"
}

flatten_message() {
  local message="$1"

  message="${message//$'\r'/ }"
  message="${message//$'\n'/ }"
  printf '%s\n' "$message"
}

record_ok() {
  ok_count=$((ok_count + 1))
  log_result 'OK' "$1"
}

record_warning() {
  warnings+=("$1")
  log_result 'WARN' "$1"
}

record_failure() {
  failures+=("$1")
  log_result 'FAIL' "$1"
}

check_required_command() {
  local command_name="$1"

  if command -v "$command_name" >/dev/null 2>&1; then
    record_ok "command available: ${command_name}"
    return 0
  fi

  record_failure "missing required command: ${command_name}"
  return 1
}

check_github_auth() {
  if ! command -v gh >/dev/null 2>&1; then
    return 0
  fi

  if gh auth status >/dev/null 2>&1; then
    record_ok 'GitHub CLI authentication is configured'
    return 0
  fi

  record_failure "GitHub CLI is not authenticated (\`gh auth status\` failed)"
  return 1
}

load_runtime_config() {
  local config_output

  if config_output="$(
    (
      # shellcheck source=tools/codex/lib/config.sh
      source "${SCRIPT_DIR}/lib/config.sh"
    ) 2>&1
  )"; then
    # shellcheck source=tools/codex/lib/config.sh
    source "${SCRIPT_DIR}/lib/config.sh"
    # shellcheck source=tools/codex/lib/flow_state.sh
    source "${SCRIPT_DIR}/lib/flow_state.sh"
    # shellcheck source=tools/codex/lib/prompt_templates.sh
    source "${SCRIPT_DIR}/lib/prompt_templates.sh"
    enter_repo_root
    record_ok "loaded consumer config via current runtime path: ${CODEX_FLOW_REPO_ROOT}/.issue_forge/project.sh"
    return 0
  fi

  config_output="$(flatten_message "$config_output")"
  if [[ -z "$config_output" ]]; then
    config_output='consumer config load failed via tools/codex/lib/config.sh'
  fi
  record_failure "$config_output"
  return 1
}

check_base_ref() {
  local output

  if output="$(
    (
      require_flow_base_ref
    ) 2>&1
  )"; then
    record_ok "bootstrap base ref resolves: ${CODEX_FLOW_BASE_REF}"
    return 0
  fi

  output="$(flatten_message "$output")"
  record_failure "${output:-Failed to resolve bootstrap base ref: ${CODEX_FLOW_BASE_REF}}"
  return 1
}

check_prompt_templates() {
  local template_name
  local template_path

  if [[ ! -d "${CODEX_FLOW_PROMPTS_DIR}" ]]; then
    record_failure "missing prompts directory: ${CODEX_FLOW_PROMPTS_DIR}"
    return 1
  fi

  record_ok "prompts directory exists: ${CODEX_FLOW_PROMPTS_DIR}"

  while IFS= read -r template_name; do
    template_path="$(prompt_template_file_path "$template_name")"
    if [[ -f "$template_path" ]]; then
      record_ok "prompt template present: ${template_path}"
      continue
    fi

    record_failure "missing prompt template: ${template_path}"
  done < <(required_prompt_template_names)
}

check_checks_command() {
  local checks_command="${CODEX_FLOW_CHECKS_COMMAND}"

  if [[ -z "$checks_command" ]]; then
    record_failure 'checks command is empty'
    return 1
  fi

  if [[ "$checks_command" =~ [[:space:]] ]]; then
    record_failure "checks command is not callable in the current execution model: ${checks_command}"
    return 1
  fi

  if [[ "$checks_command" == */* ]]; then
    if [[ -x "$checks_command" ]]; then
      record_ok "checks command is executable from repo root: ${checks_command}"
      return 0
    fi

    record_failure "checks command is not executable from repo root: ${checks_command}"
    return 1
  fi

  if command -v "$checks_command" >/dev/null 2>&1; then
    record_ok "checks command resolves on PATH: ${checks_command}"
    return 0
  fi

  record_failure "checks command does not resolve on PATH: ${checks_command}"
  return 1
}

check_work_ignore() {
  if git check-ignore -q "${CODEX_FLOW_WORK_ROOT}/.doctor-check"; then
    record_ok "${CODEX_FLOW_WORK_ROOT}/ is ignored by git"
    return 0
  fi

  record_warning "${CODEX_FLOW_WORK_ROOT}/ is not ignored by git; this is recommended for local hygiene but not a hard requirement"
  return 0
}

check_git_state() {
  local current_branch
  local dirty_status

  current_branch="$(git branch --show-current)"
  if [[ -n "$current_branch" ]]; then
    record_ok "current branch: ${current_branch}"
  else
    record_warning 'HEAD is detached; flow scripts expect a local branch'
  fi

  dirty_status="$(status_outside_work)"
  if [[ -n "$dirty_status" ]]; then
    record_warning "working tree is dirty outside ${CODEX_FLOW_WORK_ROOT}"
    return 0
  fi

  record_ok "working tree is clean outside ${CODEX_FLOW_WORK_ROOT}"
}

print_summary() {
  local failure
  local warning

  printf '\nSummary: %s ok, %s warning(s), %s failure(s)\n' \
    "$ok_count" \
    "${#warnings[@]}" \
    "${#failures[@]}"

  if (( ${#failures[@]} > 0 )); then
    printf 'Failures:\n'
    for failure in "${failures[@]}"; do
      printf ' - %s\n' "$failure"
    done
  fi

  if (( ${#warnings[@]} > 0 )); then
    printf 'Warnings:\n'
    for warning in "${warnings[@]}"; do
      printf ' - %s\n' "$warning"
    done
  fi
}

main() {
  local git_available=0
  local config_loaded=0

  check_required_command git && git_available=1
  check_required_command gh || true
  check_required_command codex || true
  check_required_command shellcheck || true
  check_github_auth || true

  if [[ "$git_available" -eq 1 ]]; then
    load_runtime_config && config_loaded=1
  fi

  if [[ "$config_loaded" -eq 1 ]]; then
    check_base_ref || true
    check_prompt_templates || true
    check_checks_command || true
    check_work_ignore || true
    check_git_state || true
  fi

  print_summary

  if (( ${#failures[@]} > 0 )); then
    exit 1
  fi
}

main "$@"
