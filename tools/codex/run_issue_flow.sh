#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/codex/lib/config.sh
source "${SCRIPT_DIR}/lib/config.sh"
readonly REPO_ROOT="${CODEX_FLOW_REPO_ROOT}"
# shellcheck source=tools/codex/lib/history_helpers.sh
source "${SCRIPT_DIR}/lib/history_helpers.sh"
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

run_implementation_phase() {
  log_info 'codex implementation'
  ./tools/codex/run_codex.sh write "$implement_prompt" > "$implementation_log" 2>&1
  archive_round_file "$implementation_log" 'implementation' 0 '.log'

  if [[ -z "$(status_outside_work)" ]]; then
    log_fail_with_path 'initial implementation session produced no file changes' "$implementation_log"
    exit 1
  fi
}

if [[ "$#" -gt 1 ]]; then
  printf 'Usage: %s [issue_number]\n' "$0" >&2
  exit 1
fi

require_command awk
require_command sed
require_publish_commands

enter_repo_root

issue_number="$(resolve_numeric_issue_number "${1:-}")"

issue_file="$(require_issue_file "$issue_number")"

current_branch="$(resolve_current_branch_from_state "Missing ${CODEX_FLOW_CURRENT_BRANCH_FILE}. Run tools/issue/start_from_issue.sh first.")"

require_flow_base_ref

ensure_clean_worktree 'Working tree must be clean before running the issue flow.'
mkdir -p "$CODEX_FLOW_CODEX_DIR"
mkdir -p "$CODEX_FLOW_CODEX_HISTORY_DIR"

implement_prompt="${CODEX_FLOW_CODEX_DIR}/implementation.prompt.md"
fix_checks_prompt="${CODEX_FLOW_CODEX_DIR}/fix-from-checks.prompt.md"
review_prompt="${CODEX_FLOW_CODEX_DIR}/review.prompt.md"
fix_review_prompt="${CODEX_FLOW_CODEX_DIR}/fix-from-review.prompt.md"

checks_log="${CODEX_FLOW_CODEX_DIR}/checks.log"
implementation_log="${CODEX_FLOW_CODEX_DIR}/implementation.log"
fix_checks_log="${CODEX_FLOW_CODEX_DIR}/fix-from-checks.log"
review_diff="${CODEX_FLOW_CODEX_DIR}/review.diff"
review_untracked="${CODEX_FLOW_CODEX_DIR}/review.untracked.txt"
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
  "$review_output"

run_implementation_phase
ensure_checks_pass
ensure_review_accepted
commit_issue_changes "chore: address issue #${issue_number}" 1 'Loop finished without repository changes to commit.'
publish_issue_results "$issue_number" "$current_branch"
