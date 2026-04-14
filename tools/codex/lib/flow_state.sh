#!/usr/bin/env bash

if [[ -z "${CODEX_FLOW_WORKTREE_EXCLUDE_PATHSPEC:-}" ]]; then
  readonly CODEX_FLOW_WORKTREE_EXCLUDE_PATHSPEC=":(exclude)${CODEX_FLOW_WORK_ROOT}"
fi

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  fi
}

enter_repo_root() {
  local repo_root

  repo_root="$(git rev-parse --show-toplevel)"
  cd "$repo_root"
}

status_outside_work() {
  git status --porcelain --untracked-files=all -- . "$CODEX_FLOW_WORKTREE_EXCLUDE_PATHSPEC"
}

ensure_clean_worktree() {
  local message="$1"

  if [[ -n "$(status_outside_work)" ]]; then
    printf '%s\n' "$message" >&2
    exit 1
  fi
}

resolve_issue_number() {
  local provided_issue_number="${1:-}"

  if [[ -n "$provided_issue_number" ]]; then
    printf '%s\n' "$provided_issue_number"
    return
  fi

  if [[ ! -f "$CODEX_FLOW_CURRENT_ISSUE_FILE" ]]; then
    printf 'Missing %s and no issue number was provided.\n' "$CODEX_FLOW_CURRENT_ISSUE_FILE" >&2
    exit 1
  fi

  printf '%s\n' "$(< "$CODEX_FLOW_CURRENT_ISSUE_FILE")"
}

require_numeric_issue_number() {
  local issue_number="$1"

  if [[ ! "$issue_number" =~ ^[0-9]+$ ]]; then
    printf 'Issue number must be numeric: %s\n' "$issue_number" >&2
    exit 1
  fi
}

resolve_numeric_issue_number() {
  local issue_number

  issue_number="$(resolve_issue_number "${1:-}")"
  require_numeric_issue_number "$issue_number"
  printf '%s\n' "$issue_number"
}

require_current_branch_file() {
  local missing_message="$1"

  if [[ ! -f "$CODEX_FLOW_CURRENT_BRANCH_FILE" ]]; then
    printf '%s\n' "$missing_message" >&2
    exit 1
  fi
}

read_saved_branch() {
  printf '%s\n' "$(< "$CODEX_FLOW_CURRENT_BRANCH_FILE")"
}

resolve_current_branch() {
  local saved_branch
  local current_branch

  saved_branch="$(read_saved_branch)"
  current_branch="$(git branch --show-current)"

  if [[ -z "$current_branch" ]]; then
    printf 'Not on a local branch.\n' >&2
    exit 1
  fi

  if [[ "$current_branch" != "$saved_branch" ]]; then
    printf 'Current branch does not match %s: %s != %s\n' "$CODEX_FLOW_CURRENT_BRANCH_FILE" "$current_branch" "$saved_branch" >&2
    exit 1
  fi

  printf '%s\n' "$current_branch"
}

resolve_current_branch_from_state() {
  local missing_message="$1"

  require_current_branch_file "$missing_message"
  resolve_current_branch
}

require_flow_base_ref() {
  if ! git rev-parse --verify "$CODEX_FLOW_BASE_REF" >/dev/null 2>&1; then
    printf 'Missing required base ref: %s\n' "$CODEX_FLOW_BASE_REF" >&2
    exit 1
  fi
}

issue_file_path() {
  printf '%s/%s.md\n' "$CODEX_FLOW_ISSUES_DIR" "$1"
}

require_issue_file() {
  local issue_number="$1"
  local issue_file

  issue_file="$(issue_file_path "$issue_number")"
  if [[ ! -f "$issue_file" ]]; then
    printf 'Missing issue context file: %s\n' "$issue_file" >&2
    exit 1
  fi

  printf '%s\n' "$issue_file"
}
