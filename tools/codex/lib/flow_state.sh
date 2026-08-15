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

queue_issue_frontier_error() {
  printf 'Queue Issue frontier validation failed: %s\n' "$1" >&2
  return 1
}

queue_validate_direct_issue_commit() {
  local issue_number="$1"
  local expected_base="$2"
  local commit_sha="$3"
  local commit_token parent extra count subject

  git cat-file -e "${expected_base}^{commit}" 2>/dev/null \
    || queue_issue_frontier_error "saved base ${expected_base} for Issue ${issue_number} is not a commit" \
    || return 1
  git cat-file -e "${commit_sha}^{commit}" 2>/dev/null \
    || queue_issue_frontier_error "commit ${commit_sha} for Issue ${issue_number} is not a commit" \
    || return 1
  read -r commit_token parent extra <<< "$(git rev-list --parents -n 1 "$commit_sha")"
  [[ "$commit_token" == "$commit_sha" && -n "$parent" && -z "${extra:-}" ]] \
    || queue_issue_frontier_error "Issue ${issue_number} commit ${commit_sha} must have exactly one parent" \
    || return 1
  [[ "$parent" == "$expected_base" ]] \
    || queue_issue_frontier_error "Issue ${issue_number} commit parent ${parent} does not equal expected frontier ${expected_base}" \
    || return 1
  count="$(git rev-list --count "${expected_base}..${commit_sha}")"
  [[ "$count" == 1 ]] \
    || queue_issue_frontier_error "Issue ${issue_number} commit range from ${expected_base} must contain exactly one commit, found ${count}" \
    || return 1
  subject="$(git show -s --format=%s "$commit_sha")"
  [[ "$subject" == "chore: address issue #${issue_number}" ]] \
    || queue_issue_frontier_error "Issue ${issue_number} commit subject is not deterministic: ${subject}" \
    || return 1
}

validate_queue_issue_frontier() {
  local batch_state_file batch_state batch_branch current_branch expected_frontier head
  local issue_number issue_state_file issue_state issue_base issue_commit frontier_closed=0

  [[ -n "${run_state_dir:-}" && -n "${current_batch_id:-}" ]] || return 0
  declare -F queue_state_read_field >/dev/null 2>&1 || return 0
  # issue_numbers is a caller-owned global array checked dynamically here.
  # shellcheck disable=SC2154
  declare -p issue_numbers >/dev/null 2>&1 || return 0

  batch_state_file="${run_state_dir}/batches/${current_batch_id}/batch.state"
  [[ -f "$batch_state_file" && ! -L "$batch_state_file" ]] || return 0
  batch_state="$(queue_state_read_field "$batch_state_file" batch state)" || return 1
  expected_frontier="$(queue_state_read_field "$batch_state_file" batch base_commit)" || return 1
  [[ "$expected_frontier" != none ]] || return 0
  batch_branch="$(queue_state_read_field "$batch_state_file" batch branch)" || return 1
  current_branch="$(git branch --show-current)"
  [[ "$current_branch" == "$batch_branch" ]] \
    || queue_issue_frontier_error "current branch ${current_branch:-detached} does not match batch branch ${batch_branch}" \
    || return 1
  head="$(git rev-parse --verify 'HEAD^{commit}' 2>/dev/null)" \
    || queue_issue_frontier_error 'current HEAD is not a commit' \
    || return 1

  for issue_number in "${issue_numbers[@]}"; do
    issue_state_file="${run_state_dir}/batches/${current_batch_id}/issues/${issue_number}.state"
    [[ -f "$issue_state_file" && ! -L "$issue_state_file" ]] || continue
    issue_state="$(queue_state_read_field "$issue_state_file" issue state)" || return 1
    issue_base="$(queue_state_read_field "$issue_state_file" issue base_commit)" || return 1
    issue_commit="$(queue_state_read_field "$issue_state_file" issue commit_sha)" || return 1

    if [[ "$frontier_closed" -eq 1 ]]; then
      [[ "$issue_state" == planned && "$issue_base" == none && "$issue_commit" == none ]] \
        || queue_issue_frontier_error "Issue ${issue_number} follows the active frontier but is not pristine planned state" \
        || return 1
      continue
    fi

    case "$issue_state" in
      acknowledged)
        [[ "$issue_base" == "$expected_frontier" ]] \
          || queue_issue_frontier_error "Issue ${issue_number} saved base ${issue_base} does not equal expected frontier ${expected_frontier}" \
          || return 1
        [[ "$issue_commit" != none ]] \
          || queue_issue_frontier_error "acknowledged Issue ${issue_number} has no commit" \
          || return 1
        queue_validate_direct_issue_commit "$issue_number" "$expected_frontier" "$issue_commit" || return 1
        expected_frontier="$issue_commit"
        ;;
      committed|artifacts_archived)
        [[ "$issue_base" == "$expected_frontier" ]] \
          || queue_issue_frontier_error "Issue ${issue_number} saved base ${issue_base} does not equal expected frontier ${expected_frontier}" \
          || return 1
        [[ "$issue_commit" != none ]] \
          || queue_issue_frontier_error "Issue ${issue_number} state ${issue_state} has no commit" \
          || return 1
        queue_validate_direct_issue_commit "$issue_number" "$expected_frontier" "$issue_commit" || return 1
        expected_frontier="$issue_commit"
        [[ "$head" == "$expected_frontier" ]] \
          || queue_issue_frontier_error "branch HEAD ${head} does not equal active Issue frontier ${expected_frontier}" \
          || return 1
        frontier_closed=1
        ;;
      running)
        [[ "$issue_base" == "$expected_frontier" && "$issue_commit" == none ]] \
          || queue_issue_frontier_error "running Issue ${issue_number} does not start from expected frontier ${expected_frontier}" \
          || return 1
        if [[ "$head" != "$expected_frontier" ]]; then
          queue_validate_direct_issue_commit "$issue_number" "$expected_frontier" "$head" || return 1
        fi
        frontier_closed=1
        ;;
      leased)
        [[ "$issue_commit" == none && ( "$issue_base" == none || "$issue_base" == "$expected_frontier" ) ]] \
          || queue_issue_frontier_error "leased Issue ${issue_number} has an invalid base or commit identity" \
          || return 1
        [[ "$head" == "$expected_frontier" ]] \
          || queue_issue_frontier_error "branch HEAD ${head} cannot become Issue ${issue_number} base; expected frontier is ${expected_frontier}" \
          || return 1
        frontier_closed=1
        ;;
      planned)
        [[ "$issue_base" == none && "$issue_commit" == none ]] \
          || queue_issue_frontier_error "planned Issue ${issue_number} already has base or commit identity" \
          || return 1
        [[ "$head" == "$expected_frontier" ]] \
          || queue_issue_frontier_error "branch HEAD ${head} cannot become Issue ${issue_number} base; expected frontier is ${expected_frontier}" \
          || return 1
        frontier_closed=1
        ;;
      *)
        queue_issue_frontier_error "Issue ${issue_number} has unsupported state ${issue_state}" || return 1
        ;;
    esac
  done

  if [[ "$frontier_closed" -eq 0 && "$batch_state" == issues_running ]]; then
    [[ "$head" == "$expected_frontier" ]] \
      || queue_issue_frontier_error "branch HEAD ${head} does not equal final acknowledged Issue frontier ${expected_frontier}" \
      || return 1
  fi
}

ensure_clean_worktree() {
  local message="$1"

  if [[ -n "$(status_outside_work)" ]]; then
    printf '%s\n' "$message" >&2
    exit 1
  fi

  validate_queue_issue_frontier || exit 1
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

queue_completed_batch_integrity_error() {
  printf 'Completed batch integrity validation failed: %s\n' "$1" >&2
  return 1
}

queue_completed_batch_validation_ready() {
  [[ "${ISSUE_FORGE_INTERNAL_QUEUE_MINIMAL_CONFIG:-0}" == 1 ]] || return 1
  [[ -n "${CODEX_FLOW_REPO_ROOT:-}" && -n "${run_state_dir:-}" && -n "${run_id:-}" ]] || return 1
  [[ -d "$run_state_dir" && ! -L "$run_state_dir" ]] || return 1
  [[ -f "${run_state_dir}/manifest.state" && -f "${run_state_dir}/run.state" ]] || return 1
  declare -F queue_state_parse_file >/dev/null 2>&1 || return 1
  declare -F queue_state_validate_file >/dev/null 2>&1 || return 1
  declare -F validate_durable_issue_context >/dev/null 2>&1 || return 1
  declare -F validate_issue_archive >/dev/null 2>&1 || return 1
  declare -F check_attempt_validate_store >/dev/null 2>&1 || return 1
}

queue_validate_completed_batches_integrity() {
  local manifest="${run_state_dir}/manifest.state"
  local run_file="${run_state_dir}/run.state"
  local run_state every start=0 end first last batch_id batch_file issue_file issue
  local expected_frontier accepted_head context_path context_hash archive_path archive_hash commit
  local -a ordered_issues=()
  local -A manifest_fields=() run_fields=() batch_fields=() issue_fields=()

  queue_completed_batch_validation_ready || return 0
  queue_state_parse_file "$manifest" manifest manifest_fields \
    || queue_completed_batch_integrity_error "invalid manifest ${manifest}" \
    || return 1
  queue_state_validate_file "$manifest" manifest \
    || queue_completed_batch_integrity_error "invalid manifest ${manifest}" \
    || return 1
  queue_state_parse_file "$run_file" run run_fields \
    || queue_completed_batch_integrity_error "invalid run state ${run_file}" \
    || return 1
  queue_state_validate_file "$run_file" run \
    || queue_completed_batch_integrity_error "invalid run state ${run_file}" \
    || return 1
  [[ "${manifest_fields[run_id]}" == "$run_id" && "${run_fields[run_id]}" == "$run_id" ]] \
    || queue_completed_batch_integrity_error "run identity does not match ${run_id}" \
    || return 1

  IFS=',' read -r -a ordered_issues <<< "${manifest_fields[issues]}"
  every="${manifest_fields[review_every]}"
  run_state="${run_fields[state]}"

  while [[ "$start" -lt "${#ordered_issues[@]}" ]]; do
    end=$((start + every))
    [[ "$end" -le "${#ordered_issues[@]}" ]] || end="${#ordered_issues[@]}"
    first="${ordered_issues[$start]}"
    last="${ordered_issues[$((end - 1))]}"
    batch_id="batch-${first}-${last}"
    batch_file="${run_state_dir}/batches/${batch_id}/batch.state"

    if [[ ! -f "$batch_file" || -L "$batch_file" ]]; then
      [[ "$run_state" != completed ]] || {
        queue_completed_batch_integrity_error "completed run ${run_id} is missing batch ${batch_id}"
        return 1
      }
      start="$end"
      continue
    fi

    batch_fields=()
    queue_state_parse_file "$batch_file" batch batch_fields \
      || queue_completed_batch_integrity_error "invalid batch state ${batch_file}" \
      || return 1
    queue_state_validate_file "$batch_file" batch \
      || queue_completed_batch_integrity_error "invalid batch state ${batch_file}" \
      || return 1
    [[ "${batch_fields[run_id]}" == "$run_id" && "${batch_fields[batch_id]}" == "$batch_id" ]] \
      || queue_completed_batch_integrity_error "batch ${batch_id} does not belong to run ${run_id}" \
      || return 1

    if [[ "${batch_fields[state]}" != completed ]]; then
      [[ "$run_state" != completed ]] || {
        queue_completed_batch_integrity_error "completed run ${run_id} contains non-completed batch ${batch_id}"
        return 1
      }
      start="$end"
      continue
    fi

    expected_frontier="${batch_fields[base_commit]}"
    accepted_head="${batch_fields[accepted_head]}"
    [[ "$expected_frontier" != none && "$accepted_head" != none ]] \
      || queue_completed_batch_integrity_error "completed batch ${batch_id} lacks base or accepted head" \
      || return 1

    while [[ "$start" -lt "$end" ]]; do
      issue="${ordered_issues[$start]}"
      issue_file="${run_state_dir}/batches/${batch_id}/issues/${issue}.state"
      issue_fields=()
      queue_state_parse_file "$issue_file" issue issue_fields \
        || queue_completed_batch_integrity_error "invalid Issue ${issue} state ${issue_file}" \
        || return 1
      queue_state_validate_file "$issue_file" issue \
        || queue_completed_batch_integrity_error "invalid Issue ${issue} state ${issue_file}" \
        || return 1
      [[ "${issue_fields[run_id]}" == "$run_id" && "${issue_fields[batch_id]}" == "$batch_id" && \
         "${issue_fields[issue_number]}" == "$issue" && "${issue_fields[state]}" == acknowledged ]] \
        || queue_completed_batch_integrity_error "completed batch ${batch_id} contains invalid Issue ${issue} ownership/state" \
        || return 1
      [[ "${issue_fields[base_commit]}" == "$expected_frontier" ]] \
        || queue_completed_batch_integrity_error "Issue ${issue} base ${issue_fields[base_commit]} does not equal completed frontier ${expected_frontier}" \
        || return 1
      commit="${issue_fields[commit_sha]}"
      queue_validate_direct_issue_commit "$issue" "$expected_frontier" "$commit" || return 1

      context_path="${issue_fields[context_path]}"
      context_hash="${issue_fields[context_sha256]}"
      [[ "$context_path" != none && "$context_hash" != none ]] \
        || queue_completed_batch_integrity_error "Issue ${issue} lacks durable context identity" \
        || return 1
      validate_durable_issue_context "${CODEX_FLOW_REPO_ROOT}/${context_path}" "$issue" "$context_hash" >/dev/null \
        || queue_completed_batch_integrity_error "Issue ${issue} durable context is missing or changed" \
        || return 1

      archive_path="${issue_fields[artifact_path]}"
      archive_hash="${issue_fields[archive_manifest_sha256]}"
      [[ "$archive_path" != none && "$archive_hash" != none ]] \
        || queue_completed_batch_integrity_error "Issue ${issue} lacks authoritative archive identity" \
        || return 1
      validate_issue_archive "${CODEX_FLOW_REPO_ROOT}/${archive_path}" "$issue" "$batch_id" "$commit" "$archive_hash" >/dev/null \
        || queue_completed_batch_integrity_error "Issue ${issue} authoritative archive is missing or changed" \
        || return 1
      expected_frontier="$commit"
      start=$((start + 1))
    done

    check_attempt_validate_store \
      "${run_state_dir}/batches/${batch_id}/check-attempts/batch" \
      "${run_state_dir}/batches/${batch_id}/checks/batch.manifest.tsv" \
      || queue_completed_batch_integrity_error "batch ${batch_id} check provenance is missing or changed" \
      || return 1

    command git cat-file -e "${accepted_head}^{commit}" 2>/dev/null \
      || queue_completed_batch_integrity_error "accepted head ${accepted_head} for ${batch_id} is not a commit" \
      || return 1
    command git merge-base --is-ancestor "${batch_fields[base_commit]}" "$accepted_head" \
      || queue_completed_batch_integrity_error "accepted head ${accepted_head} does not descend from batch base ${batch_fields[base_commit]}" \
      || return 1
    command git merge-base --is-ancestor "$expected_frontier" "$accepted_head" \
      || queue_completed_batch_integrity_error "accepted head ${accepted_head} does not contain final Issue frontier ${expected_frontier}" \
      || return 1
  done
}

# Queue mode validates completed batches once at each batch/finalization Git boundary.
# The dynamic local flag prevents recursion while the validator itself inspects Git.
if [[ "${ISSUE_FORGE_INTERNAL_QUEUE_MINIMAL_CONFIG:-0}" == 1 ]]; then
  if ! unset ISSUE_FORGE_INTERNAL_QUEUE_COMPLETED_INTEGRITY_CACHE 2>/dev/null; then
    printf 'Private queue state variable is readonly and cannot be initialized: %s\n' \
      ISSUE_FORGE_INTERNAL_QUEUE_COMPLETED_INTEGRITY_CACHE >&2
    return 1
  fi
  ISSUE_FORGE_INTERNAL_QUEUE_COMPLETED_INTEGRITY_CACHE=''

  git() {
    local status state key=''
    case "${1:-}" in
      status|switch|checkout|fetch|pull|push|config) ;;
      *)
        command git "$@"
        return $?
        ;;
    esac

    if [[ "${ISSUE_FORGE_INTERNAL_QUEUE_COMPLETED_INTEGRITY_ACTIVE:-0}" != 1 && \
          -n "${run_state_dir:-}" && -n "${run_id:-}" && -f "${run_state_dir}/run.state" ]]; then
      state="$(awk -F '\t' '$1 == "state" { print $2; exit }' "${run_state_dir}/run.state" 2>/dev/null || true)"
      if [[ "$state" == completed ]]; then
        key="completed:${run_id}"
      elif [[ -n "${current_batch_id:-}" ]]; then
        key="batch:${run_id}:${current_batch_id}"
      fi
      if [[ -n "$key" && "$ISSUE_FORGE_INTERNAL_QUEUE_COMPLETED_INTEGRITY_CACHE" != "$key" ]]; then
        local ISSUE_FORGE_INTERNAL_QUEUE_COMPLETED_INTEGRITY_ACTIVE=1
        queue_validate_completed_batches_integrity || return 1
        ISSUE_FORGE_INTERNAL_QUEUE_COMPLETED_INTEGRITY_CACHE="$key"
      fi
    fi

    command git "$@"
    status=$?
    return "$status"
  }

  require_command() {
    if [[ "$1" == git ]]; then
      if ! type -P git >/dev/null 2>&1; then
        printf 'Missing required command: %s\n' "$1" >&2
        exit 1
      fi
      return 0
    fi
    if ! command -v "$1" >/dev/null 2>&1; then
      printf 'Missing required command: %s\n' "$1" >&2
      exit 1
    fi
  }
fi
