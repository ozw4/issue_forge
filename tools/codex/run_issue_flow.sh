#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=tools/codex/lib/config.sh
source "${SCRIPT_DIR}/lib/config.sh"
# shellcheck source=tools/codex/lib/history_helpers.sh
source "${SCRIPT_DIR}/lib/history_helpers.sh"
# shellcheck source=tools/codex/lib/token_usage_helpers.sh
source "${SCRIPT_DIR}/lib/token_usage_helpers.sh"
# shellcheck source=tools/codex/lib/checks_review_helpers.sh
source "${SCRIPT_DIR}/lib/checks_review_helpers.sh"
# shellcheck source=tools/codex/lib/flow_state.sh
source "${SCRIPT_DIR}/lib/flow_state.sh"
# shellcheck source=tools/codex/lib/issue_bootstrap.sh
source "${SCRIPT_DIR}/lib/issue_bootstrap.sh"
# shellcheck source=tools/codex/lib/publish_helpers.sh
source "${SCRIPT_DIR}/lib/publish_helpers.sh"
# shellcheck source=tools/codex/lib/prompt_templates.sh
source "${SCRIPT_DIR}/lib/prompt_templates.sh"

log_info() {
  printf '[flow] %s\n' "$1"
}

log_fail_with_path() {
  printf '[flow] %s\n' "$1" >&2
  printf '[flow] see log: %s\n' "$2" >&2
}

run_codex_phase() {
  local mode="$1"
  local prompt_file="$2"
  local output_file="$3"
  local reasoning_effort="$4"
  local stderr_policy="${5:-combined}"

  case "$stderr_policy" in
    combined)
      CODEX_RUN_REASONING_EFFORT="$reasoning_effort" \
        "${ISSUE_FORGE_ENGINE_CODEX_DIR}/run_codex.sh" "$mode" "$prompt_file" > "$output_file" 2>&1
      ;;
    stdout)
      CODEX_RUN_REASONING_EFFORT="$reasoning_effort" \
        "${ISSUE_FORGE_ENGINE_CODEX_DIR}/run_codex.sh" "$mode" "$prompt_file" > "$output_file"
      ;;
    *)
      printf 'Invalid Codex phase stderr policy: %s\n' "$stderr_policy" >&2
      exit 1
      ;;
  esac
}

run_implementation_phase() {
  log_info 'codex implementation'
  run_codex_phase write "$implement_prompt" "$implementation_log" "$CODEX_FLOW_IMPLEMENTATION_REASONING"
  archive_round_file "$implementation_log" 'implementation' 0 '.log'
  ensure_issue_token_usage_tsv 'implementation' "$issue_number" 0 "$CODEX_FLOW_IMPLEMENTATION_REASONING" "$implementation_log"

  if [[ -z "$(status_outside_work)" ]]; then
    log_fail_with_path 'initial implementation session produced no file changes' "$implementation_log"
    exit 1
  fi
}

resolve_skip_publish_flag() {
  local value='0'

  if [[ -n "${CODEX_FLOW_SKIP_PUBLISH+x}" ]]; then
    value="$CODEX_FLOW_SKIP_PUBLISH"
  fi

  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    printf 'CODEX_FLOW_SKIP_PUBLISH must be a non-negative integer: %s\n' "$value" >&2
    exit 1
  fi

  if [[ "$value" -eq 0 ]]; then
    printf '0\n'
    return
  fi

  printf '1\n'
}

if [[ "$#" -gt 1 ]]; then
  printf 'Usage: %s [issue_number]\n' "$0" >&2
  exit 1
fi

require_command awk
require_command git
require_command mktemp
require_command sed

skip_publish="$(resolve_skip_publish_flag)"
if [[ "$skip_publish" -eq 0 ]]; then
  require_publish_commands
fi

enter_repo_root

issue_number="$(resolve_numeric_issue_number "${1:-}")"

issue_file="$(require_issue_file "$issue_number")"

current_branch="$(resolve_current_branch_from_state "Missing ${CODEX_FLOW_CURRENT_BRANCH_FILE}. Run the issue bootstrap entrypoint first.")"
resolve_fixed_base_commit_from_state "Missing ${CODEX_FLOW_BASE_COMMIT_FILE}. Run the issue bootstrap entrypoint first." >/dev/null

ensure_clean_worktree 'Working tree must be clean before running the issue flow.'
mkdir -p "$CODEX_FLOW_CODEX_DIR"
mkdir -p "$CODEX_FLOW_CODEX_HISTORY_DIR"
initialize_issue_token_usage_tsv

implement_prompt="${CODEX_FLOW_CODEX_DIR}/implementation.prompt.md"
fix_checks_prompt="${CODEX_FLOW_CODEX_DIR}/fix-from-checks.prompt.md"
review_prompt="${CODEX_FLOW_CODEX_DIR}/review.prompt.md"
fix_review_prompt="${CODEX_FLOW_CODEX_DIR}/fix-from-review.prompt.md"

checks_log="${CODEX_FLOW_CODEX_DIR}/checks.log"
implementation_log="${CODEX_FLOW_CODEX_DIR}/implementation.log"
fix_checks_log="${CODEX_FLOW_CODEX_DIR}/fix-from-checks.log"
review_diff="${CODEX_FLOW_CODEX_DIR}/review.diff"
review_untracked="${CODEX_FLOW_CODEX_DIR}/review.untracked.txt"
review_summary="${CODEX_FLOW_CODEX_DIR}/review.summary.txt"
review_raw_output="${CODEX_FLOW_CODEX_DIR}/review.raw.txt"
review_output="${CODEX_FLOW_CODEX_DIR}/review.txt"
fix_review_log="${CODEX_FLOW_CODEX_DIR}/fix-from-review.log"
history_dir="$CODEX_FLOW_CODEX_HISTORY_DIR"

checks_run_round=0
fix_checks_round=0
review_run_round=0
fix_review_round=0

write_issue_flow_prompt_files \
  "$issue_number" \
  "$issue_file" \
  "$implement_prompt" \
  "$fix_checks_prompt" \
  "$review_prompt" \
  "$fix_review_prompt" \
  "$checks_log" \
  "$review_diff" \
  "$review_untracked" \
  "$review_summary" \
  "$review_output"

run_implementation_phase
ensure_checks_pass
ensure_review_accepted
commit_issue_changes "chore: address issue #${issue_number}" 1 'Loop finished without repository changes to commit.'
if [[ "$skip_publish" -ne 0 ]]; then
  log_info 'publish skipped because CODEX_FLOW_SKIP_PUBLISH is set'
  exit 0
fi

publish_issue_results "$issue_number" "$current_branch"
