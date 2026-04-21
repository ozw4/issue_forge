#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=tools/codex/lib/config.sh
source "${SCRIPT_DIR}/../codex/lib/config.sh"
# shellcheck source=tools/codex/lib/flow_state.sh
source "${SCRIPT_DIR}/../codex/lib/flow_state.sh"
# shellcheck source=tools/codex/lib/issue_bootstrap.sh
source "${SCRIPT_DIR}/../codex/lib/issue_bootstrap.sh"

if [[ "$#" -ne 1 ]]; then
  printf 'Usage: %s <issue_number>\n' "$0" >&2
  exit 1
fi

require_issue_bootstrap_commands

issue_number="$(resolve_numeric_issue_number "$1")"

enter_repo_root
ensure_clean_worktree 'Working tree must be clean before starting an issue branch.'

bootstrap_issue_branch "$issue_number"
branch_name="$CODEX_FLOW_BOOTSTRAP_BRANCH_NAME"

printf 'Prepared issue %s on branch %s\n' "$issue_number" "$branch_name"
