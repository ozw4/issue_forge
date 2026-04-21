#!/usr/bin/env bash

add_worktree_exclude_path() {
  local relative_path="$1"
  local existing_path

  for existing_path in "${CODEX_FLOW_WORKTREE_EXCLUDE_PATHS[@]:-}"; do
    if [[ "${existing_path}" == ":(exclude)${relative_path}" ]]; then
      return 0
    fi
  done

  CODEX_FLOW_WORKTREE_EXCLUDE_PATHS+=(":(exclude)${relative_path}")
}

if [[ -z "${ISSUE_FORGE_ENGINE_CONSUMER_PATH:-}" ]]; then
  ISSUE_FORGE_ENGINE_CONSUMER_PATH=''

  if [[ "${ISSUE_FORGE_ENGINE_ROOT}" == "${CODEX_FLOW_REPO_ROOT}/"* ]]; then
    ISSUE_FORGE_ENGINE_CONSUMER_PATH="${ISSUE_FORGE_ENGINE_ROOT#"${CODEX_FLOW_REPO_ROOT}"/}"
  fi

  readonly ISSUE_FORGE_ENGINE_CONSUMER_PATH
fi

if [[ -z "${CODEX_FLOW_WORKTREE_EXCLUDES_INITIALIZED:-}" ]]; then
  declare -ag CODEX_FLOW_WORKTREE_EXCLUDE_PATHS
  declare -ag CODEX_FLOW_CLEAN_EXCLUDE_ARGS
  CODEX_FLOW_WORKTREE_EXCLUDE_PATHS=(":(exclude)${CODEX_FLOW_WORK_ROOT}")
  CODEX_FLOW_CLEAN_EXCLUDE_ARGS=()

  if [[ -n "${ISSUE_FORGE_ENGINE_CONSUMER_PATH}" ]]; then
    add_worktree_exclude_path "${ISSUE_FORGE_ENGINE_CONSUMER_PATH}"
    CODEX_FLOW_CLEAN_EXCLUDE_ARGS=(-e "${ISSUE_FORGE_ENGINE_CONSUMER_PATH}")
  fi

  readonly -a CODEX_FLOW_WORKTREE_EXCLUDE_PATHS
  # shellcheck disable=SC2034
  readonly -a CODEX_FLOW_CLEAN_EXCLUDE_ARGS
  readonly CODEX_FLOW_WORKTREE_EXCLUDES_INITIALIZED=1
fi

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
  cd "$CODEX_FLOW_REPO_ROOT" || exit 1
}

status_outside_work() {
  git status --porcelain --untracked-files=all -- . "${CODEX_FLOW_WORKTREE_EXCLUDE_PATHS[@]}"
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

require_base_commit_file() {
  local missing_message="$1"

  if [[ ! -f "$CODEX_FLOW_BASE_COMMIT_FILE" ]]; then
    printf '%s\n' "$missing_message" >&2
    exit 1
  fi
}

read_saved_branch() {
  printf '%s\n' "$(< "$CODEX_FLOW_CURRENT_BRANCH_FILE")"
}

read_saved_base_commit() {
  printf '%s\n' "$(< "$CODEX_FLOW_BASE_COMMIT_FILE")"
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

resolve_saved_base_commit() {
  local saved_base_commit
  local resolved_base_commit

  saved_base_commit="$(read_saved_base_commit)"

  if ! resolved_base_commit="$(git rev-parse --verify "${saved_base_commit}^{commit}" 2>/dev/null)"; then
    printf 'Invalid base commit in %s: %s\n' "$CODEX_FLOW_BASE_COMMIT_FILE" "$saved_base_commit" >&2
    exit 1
  fi

  printf '%s\n' "$resolved_base_commit"
}

resolve_current_branch_from_state() {
  local missing_message="$1"

  require_current_branch_file "$missing_message"
  resolve_current_branch
}

resolve_fixed_base_commit_from_state() {
  local missing_message="$1"

  require_base_commit_file "$missing_message"
  resolve_saved_base_commit
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
