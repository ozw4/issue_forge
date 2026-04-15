#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/codex/lib/config.sh
source "${SCRIPT_DIR}/lib/config.sh"
readonly REPO_ROOT="${CODEX_FLOW_REPO_ROOT}"
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

require_flow_base_ref

pr_url="$(current_pr_url_for_branch "$current_branch")"
if [[ -z "$pr_url" ]]; then
  pr_url="$(create_issue_pr_for_branch "$issue_number" "$current_branch")"
fi

printf '%s\n' "$pr_url"
