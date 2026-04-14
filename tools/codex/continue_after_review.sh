#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/codex/lib/config.sh
source "${SCRIPT_DIR}/lib/config.sh"
# shellcheck source=tools/codex/lib/flow_state.sh
source "${SCRIPT_DIR}/lib/flow_state.sh"
# shellcheck source=tools/codex/lib/publish_helpers.sh
source "${SCRIPT_DIR}/lib/publish_helpers.sh"

if [[ "$#" -gt 1 ]]; then
  printf 'Usage: %s [issue_number]\n' "$0" >&2
  exit 1
fi

require_command git

enter_repo_root

issue_number="$(resolve_issue_number "${1:-}")"
current_branch="$(resolve_current_branch_from_state "Missing ${CODEX_FLOW_CURRENT_BRANCH_FILE}. Run tools/issue/start_from_issue.sh first.")"
review_file="${CODEX_FLOW_CODEX_DIR}/review.txt"

require_issue_file "$issue_number" >/dev/null

if [[ ! -f "$review_file" ]]; then
  printf 'Missing review file: %s\n' "$review_file" >&2
  exit 1
fi

commit_issue_changes "wip: address review feedback for issue #${issue_number}" 0 'No repository changes to continue from.'

rm -rf "$CODEX_FLOW_CODEX_DIR"

./tools/codex/run_issue_flow.sh "$issue_number"
