#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=tools/codex/lib/config.sh
source "${SCRIPT_DIR}/lib/config.sh"
# shellcheck source=tools/codex/lib/flow_state.sh
source "${SCRIPT_DIR}/lib/flow_state.sh"
# shellcheck source=tools/codex/lib/issue_bootstrap.sh
source "${SCRIPT_DIR}/lib/issue_bootstrap.sh"
# shellcheck source=tools/codex/lib/publish_helpers.sh
source "${SCRIPT_DIR}/lib/publish_helpers.sh"

if [[ "$#" -gt 1 ]]; then
  printf 'Usage: %s [issue_number]\n' "$0" >&2
  exit 1
fi

require_publish_commands

enter_repo_root

issue_number="$(resolve_numeric_issue_number "${1:-}")"

current_branch="$(resolve_current_branch_from_state "Missing ${CODEX_FLOW_CURRENT_BRANCH_FILE}.")"
resolve_fixed_base_commit_from_state "Missing ${CODEX_FLOW_BASE_COMMIT_FILE}. Run the issue bootstrap entrypoint first." >/dev/null

require_flow_base_ref

issue_file="$(require_issue_file "$issue_number")"
issue_title="$(read_issue_title_from_issue_file "$issue_file")"
sync_issue_pr_for_branch "$issue_number" "$current_branch" "$issue_title" pr_url pr_action

printf '%s\n' "$pr_url"
