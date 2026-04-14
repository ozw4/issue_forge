#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=tools/codex/lib/engine_defaults.sh
source "${SCRIPT_DIR}/lib/engine_defaults.sh"
# shellcheck source=tools/codex/lib/consumer_config.sh
source "${SCRIPT_DIR}/lib/consumer_config.sh"
issue_forge_load_consumer_config "${REPO_ROOT}"
# shellcheck source=tools/codex/lib/flow_state.sh
source "${SCRIPT_DIR}/lib/flow_state.sh"

usage() {
  printf 'Usage: %s [--hard] [issue_number]\n' "$0" >&2
}

destructive_restart=0
issue_number=""

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --hard)
      destructive_restart=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      printf 'Unknown option: %s\n' "$1" >&2
      usage
      exit 1
      ;;
    *)
      if [[ -n "$issue_number" ]]; then
        usage
        exit 1
      fi
      issue_number="$1"
      shift
      ;;
  esac
done

require_command git

enter_repo_root

issue_number="$(resolve_issue_number "$issue_number")"
current_branch="$(resolve_current_branch_from_state "Missing ${CODEX_FLOW_CURRENT_BRANCH_FILE}. Run tools/issue/start_from_issue.sh first.")"
require_issue_file "$issue_number" >/dev/null

dirty_status="$(status_outside_work)"
if [[ -n "$dirty_status" ]]; then
  if [[ "$destructive_restart" -ne 1 ]]; then
    printf 'Refusing to discard changes outside %s without an explicit destructive flag.\n' "$CODEX_FLOW_WORK_ROOT" >&2
    printf 'The following changes would be discarded:\n' >&2
    printf '%s\n' "$dirty_status" >&2
    printf 'Re-run with --hard to reset tracked files and clean untracked files outside %s.\n' "$CODEX_FLOW_WORK_ROOT" >&2
    exit 1
  fi

  git reset --hard HEAD
  git clean -fd -- . "$CODEX_FLOW_WORKTREE_EXCLUDE_PATHSPEC"
fi

rm -rf "$CODEX_FLOW_CODEX_DIR"

./tools/codex/run_issue_flow.sh "$issue_number"
