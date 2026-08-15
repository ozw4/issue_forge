#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=tools/codex/lib/config.sh
source "${SCRIPT_DIR}/lib/config.sh"
# shellcheck source=tools/codex/lib/history_helpers.sh
source "${SCRIPT_DIR}/lib/history_helpers.sh"
# shellcheck source=tools/codex/lib/checks_review_helpers.sh
source "${SCRIPT_DIR}/lib/checks_review_helpers.sh"
# shellcheck source=tools/codex/lib/flow_state.sh
source "${SCRIPT_DIR}/lib/flow_state.sh"
# shellcheck source=tools/codex/lib/queue_state.sh
source "${SCRIPT_DIR}/lib/queue_state.sh"
# shellcheck source=tools/codex/lib/issue_bootstrap.sh
source "${SCRIPT_DIR}/lib/issue_bootstrap.sh"
# shellcheck source=tools/codex/lib/publish_helpers.sh
source "${SCRIPT_DIR}/lib/publish_helpers.sh"
# shellcheck source=tools/codex/lib/prompt_templates.sh
source "${SCRIPT_DIR}/lib/prompt_templates.sh"
# shellcheck source=tools/codex/lib/batch_review_helpers.sh
source "${SCRIPT_DIR}/lib/batch_review_helpers.sh"

queue_lock=''
queue_lifecycle_started=0
queue_current_batch=''
batch_current_issue=''
history_allow_overwrite=1
queue_resume_mode=0
queue_resume_complete=0
queue_requeue_mode=0
requeue_issue_number=''

log_info() {
  printf '[queue] %s\n' "$1"
}

fail() {
  printf '[queue] %s\n' "$1" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: tools/codex/run_issue_queue.sh [options] <issue_number> [issue_number...]
       tools/codex/run_issue_queue.sh --resume
       tools/codex/run_issue_queue.sh --requeue <issue_number>

Options:
  --review-every <positive_integer>
  --batch-review-effort <non_empty_value_without_whitespace>
  --batch-fix-effort <non_empty_value_without_whitespace>
  --auto-merge
  --draft
  --resume
  --requeue <issue_number>  Destructively discard the current failed Issue attempt;
                            run --resume separately to restart queue processing.
  --help
EOF
}

require_positive_integer_value() {
  local name="$1"
  local value="$2"

  if [[ ! "$value" =~ ^[0-9]+$ || "$value" -eq 0 ]]; then
    fail "${name} must be a positive integer: ${value}"
  fi
}

require_nonempty_no_whitespace_value() {
  local name="$1"
  local value="$2"

  if [[ -z "$value" ]]; then
    fail "${name} must be non-empty"
  fi

  if [[ "$value" =~ [[:space:]] ]]; then
    fail "${name} must not contain whitespace: ${value}"
  fi
}

parse_queue_arguments() {
  review_every="$CODEX_FLOW_QUEUE_REVIEW_EVERY"
  batch_review_effort="$CODEX_FLOW_BATCH_REVIEW_REASONING"
  batch_review_fix_effort="$CODEX_FLOW_BATCH_FIX_REASONING"
  batch_check_fix_effort="$CODEX_FLOW_BATCH_CHECK_FIX_REASONING"
  draft_pr=0
  auto_merge=0
  issue_numbers=()

  if [[ "$CODEX_FLOW_BATCH_PR_DRAFT_DEFAULT" -ne 0 ]]; then
    draft_pr=1
  fi

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --review-every)
        if [[ "$#" -lt 2 ]]; then
          fail '--review-every requires a value'
        fi
        review_every="$2"
        require_positive_integer_value '--review-every' "$review_every"
        shift 2
        ;;
      --batch-review-effort)
        if [[ "$#" -lt 2 ]]; then
          fail '--batch-review-effort requires a value'
        fi
        batch_review_effort="$2"
        require_nonempty_no_whitespace_value '--batch-review-effort' "$batch_review_effort"
        shift 2
        ;;
      --batch-fix-effort)
        if [[ "$#" -lt 2 ]]; then
          fail '--batch-fix-effort requires a value'
        fi
        batch_review_fix_effort="$2"
        batch_check_fix_effort="$2"
        require_nonempty_no_whitespace_value '--batch-fix-effort' "$2"
        shift 2
        ;;
      --auto-merge)
        auto_merge=1
        shift
        ;;
      --draft)
        draft_pr=1
        shift
        ;;
      --help)
        usage
        exit 0
        ;;
      --*)
        usage >&2
        exit 1
        ;;
      *)
        require_numeric_issue_number "$1"
        issue_numbers+=("$1")
        shift
        ;;
    esac
  done

  require_positive_integer_value 'CODEX_FLOW_QUEUE_REVIEW_EVERY' "$review_every"
  require_nonempty_no_whitespace_value 'CODEX_FLOW_BATCH_REVIEW_REASONING' "$batch_review_effort"
  require_nonempty_no_whitespace_value 'CODEX_FLOW_BATCH_FIX_REASONING' "$batch_review_fix_effort"
  require_nonempty_no_whitespace_value 'CODEX_FLOW_BATCH_CHECK_FIX_REASONING' "$batch_check_fix_effort"

  if [[ "${#issue_numbers[@]}" -eq 0 ]]; then
    usage >&2
    exit 1
  fi

  if [[ "$auto_merge" -eq 1 && "$draft_pr" -ne 0 ]]; then
    fail '--auto-merge cannot be used with a draft batch PR'
  fi
}

parse_queue_cli() {
  if [[ "${1:-}" == '--resume' ]]; then
    if [[ "$#" -ne 1 ]]; then
      fail '--resume does not accept Issue numbers or fresh queue options'
    fi
    queue_resume_mode=1
    return 0
  fi

  if [[ "${1:-}" == '--requeue' ]]; then
    if [[ "$#" -ne 2 ]]; then
      fail '--requeue requires exactly one Issue number and cannot be combined with --resume, fresh Issue numbers, or other queue options'
    fi
    require_numeric_issue_number "$2"
    queue_requeue_mode=1
    requeue_issue_number="$2"
    return 0
  fi

  parse_queue_arguments "$@"
}

read_queue_plan() {
  local key
  local value
  local schema_version=''
  local schema_count=0
  local review_every_count=0
  local batch_review_effort_count=0
  local batch_review_fix_effort_count=0
  local batch_check_fix_effort_count=0
  local draft_pr_count=0
  local auto_merge_count=0

  if [[ ! -f "$CODEX_FLOW_QUEUE_PLAN_FILE" ]]; then
    if [[ "$queue_requeue_mode" -eq 1 ]]; then
      fail "Missing queue plan file required for --requeue: ${CODEX_FLOW_QUEUE_PLAN_FILE}"
    fi
    fail "Missing queue plan file required for --resume: ${CODEX_FLOW_QUEUE_PLAN_FILE}"
  fi

  issue_numbers=()
  while IFS=$'\t' read -r key value; do
    case "$key" in
      schema_version)
        schema_version="$value"
        schema_count=$((schema_count + 1))
        ;;
      review_every)
        review_every="$value"
        review_every_count=$((review_every_count + 1))
        ;;
      batch_review_effort)
        batch_review_effort="$value"
        batch_review_effort_count=$((batch_review_effort_count + 1))
        ;;
      batch_review_fix_effort)
        batch_review_fix_effort="$value"
        batch_review_fix_effort_count=$((batch_review_fix_effort_count + 1))
        ;;
      batch_check_fix_effort)
        batch_check_fix_effort="$value"
        batch_check_fix_effort_count=$((batch_check_fix_effort_count + 1))
        ;;
      draft_pr)
        draft_pr="$value"
        draft_pr_count=$((draft_pr_count + 1))
        ;;
      auto_merge)
        auto_merge="$value"
        auto_merge_count=$((auto_merge_count + 1))
        ;;
      issue)
        require_numeric_issue_number "$value"
        issue_numbers+=("$value")
        ;;
      '')
        fail "Malformed empty key in queue plan: ${CODEX_FLOW_QUEUE_PLAN_FILE}"
        ;;
      *)
        fail "Unsupported queue plan key in ${CODEX_FLOW_QUEUE_PLAN_FILE}: ${key}"
        ;;
    esac
  done < "$CODEX_FLOW_QUEUE_PLAN_FILE"

  if [[ "$schema_count" -ne 1 || "$schema_version" != "$CODEX_FLOW_QUEUE_STATE_SCHEMA_VERSION" ]]; then
    fail "Unsupported queue plan schema in ${CODEX_FLOW_QUEUE_PLAN_FILE}: expected schema_version ${CODEX_FLOW_QUEUE_STATE_SCHEMA_VERSION}"
  fi
  if [[ "$review_every_count" -ne 1 || "$batch_review_effort_count" -ne 1 \
    || "$batch_review_fix_effort_count" -ne 1 || "$batch_check_fix_effort_count" -ne 1 \
    || "$draft_pr_count" -ne 1 || "$auto_merge_count" -ne 1 ]]; then
    fail "Missing or duplicate required option key in queue plan: ${CODEX_FLOW_QUEUE_PLAN_FILE}"
  fi
  if [[ "${#issue_numbers[@]}" -eq 0 ]]; then
    fail "Queue plan contains no Issue numbers: ${CODEX_FLOW_QUEUE_PLAN_FILE}"
  fi

  require_positive_integer_value 'plan review_every' "$review_every"
  require_nonempty_no_whitespace_value 'plan batch_review_effort' "$batch_review_effort"
  require_nonempty_no_whitespace_value 'plan batch_review_fix_effort' "$batch_review_fix_effort"
  require_nonempty_no_whitespace_value 'plan batch_check_fix_effort' "$batch_check_fix_effort"
  if [[ ! "$draft_pr" =~ ^[01]$ ]]; then
    fail "plan draft_pr must be 0 or 1: ${draft_pr}"
  fi
  if [[ ! "$auto_merge" =~ ^[01]$ ]]; then
    fail "plan auto_merge must be 0 or 1: ${auto_merge}"
  fi
  if [[ "$auto_merge" -eq 1 && "$draft_pr" -eq 1 ]]; then
    fail 'Saved queue plan combines auto_merge with a draft batch PR'
  fi
}

ensure_unique_issues() {
  local issue_number
  local seen_file

  seen_file="$(mktemp)"
  trap 'rm -f "$seen_file"' RETURN

  for issue_number in "${issue_numbers[@]}"; do
    if grep -Fxq "$issue_number" "$seen_file"; then
      fail "Duplicate issue number in queue input: ${issue_number}"
    fi
    printf '%s\n' "$issue_number" >> "$seen_file"
  done

  trap - RETURN
  rm -f "$seen_file"
}

batch_count_for_queue() {
  local issue_count="$1"

  printf '%s\n' "$(((issue_count + review_every - 1) / review_every))"
}

batch_branch_name_for_range() {
  local first_issue="$1"
  local last_issue="$2"

  printf '%s%s-%s\n' "$CODEX_FLOW_BATCH_BRANCH_PREFIX" "$first_issue" "$last_issue"
}

batch_id_for_range() {
  local first_issue="$1"
  local last_issue="$2"

  printf 'batch-%s-%s\n' "$first_issue" "$last_issue"
}

join_issue_numbers() {
  local joined=''
  local issue_number

  for issue_number in "$@"; do
    if [[ -n "$joined" ]]; then
      joined="${joined},${issue_number}"
    else
      joined="$issue_number"
    fi
  done

  printf '%s\n' "$joined"
}

ensure_planned_batch_branches_available() {
  local start_index=0
  local end_index
  local first_issue
  local last_issue
  local branch_name
  local issue_count="${#issue_numbers[@]}"

  while [[ "$start_index" -lt "$issue_count" ]]; do
    end_index=$((start_index + review_every))
    if [[ "$end_index" -gt "$issue_count" ]]; then
      end_index="$issue_count"
    fi

    first_issue="${issue_numbers[$start_index]}"
    last_issue="${issue_numbers[$((end_index - 1))]}"
    branch_name="$(batch_branch_name_for_range "$first_issue" "$last_issue")"
    ensure_issue_branch_available "$branch_name"
    start_index="$end_index"
  done
}

create_queue_lock() {
  local saved_pid=''

  mkdir -p "$CODEX_FLOW_QUEUE_DIR"
  queue_lock="${CODEX_FLOW_QUEUE_DIR}/lock"

  if [[ -e "$queue_lock" ]]; then
    if [[ "$queue_resume_mode" -ne 1 && "$queue_requeue_mode" -ne 1 ]]; then
      fail "Queue lock already exists: ${queue_lock}"
    fi

    IFS= read -r saved_pid < "$queue_lock" || true
    if [[ "$saved_pid" =~ ^[0-9]+$ ]] && kill -0 "$saved_pid" 2>/dev/null; then
      fail "Queue lock belongs to a live local process (${saved_pid}): ${queue_lock}"
    fi
    log_info "reclaiming stale queue lock: ${queue_lock}"
  fi

  write_atomic_value "$queue_lock" "$$"
  trap 'handle_queue_exit' EXIT
}

batch_state_file() {
  printf '%s/batches/%s/state.tsv\n' "$CODEX_FLOW_QUEUE_DIR" "$1"
}

issue_state_file() {
  printf '%s/batches/%s/issues/%s/state.tsv\n' "$CODEX_FLOW_QUEUE_DIR" "$1" "$2"
}

write_atomic_value() {
  local destination="$1"
  local value="$2"

  printf '%s\n' "$value" | atomic_write_from_stdin "$destination"
}

write_queue_state() {
  write_state_tsv "$CODEX_FLOW_QUEUE_STATE_FILE" \
    status "$1" \
    phase "$2" \
    current_batch "$3" \
    exit_code "$4"
}

write_batch_state() {
  local batch_id="$1"

  write_state_tsv "$(batch_state_file "$batch_id")" \
    status "$2" \
    phase "$3" \
    current_issue "$4" \
    exit_code "$5"
}

write_issue_state() {
  local batch_id="$1"
  local issue_number="$2"

  write_issue_state_tsv \
    "$(issue_state_file "$batch_id" "$issue_number")" \
    "$3" \
    "$4" \
    "$5" \
    "$batch_id"
}

handle_queue_exit() {
  local original_exit_code="$?"
  local queue_phase='initializing'
  local saved_current_batch=''
  local batch_phase='branch'
  local saved_current_issue=''
  local issue_status=''
  local issue_phase='context'

  trap - EXIT
  set +e

  if [[ "$original_exit_code" -ne 0 && "$queue_lifecycle_started" -eq 1 ]]; then
    queue_phase="$(read_state_tsv_value "$CODEX_FLOW_QUEUE_STATE_FILE" phase 2>/dev/null)"
    [[ -n "$queue_phase" ]] || queue_phase='initializing'
    saved_current_batch="$(read_state_tsv_value "$CODEX_FLOW_QUEUE_STATE_FILE" current_batch 2>/dev/null)"
    [[ -n "$saved_current_batch" ]] || saved_current_batch="$queue_current_batch"

    write_queue_state failed "$queue_phase" "$saved_current_batch" "$original_exit_code" >/dev/null 2>&1

    if [[ -n "$saved_current_batch" ]]; then
      batch_phase="$(read_state_tsv_value "$(batch_state_file "$saved_current_batch")" phase 2>/dev/null)"
      [[ -n "$batch_phase" ]] || batch_phase='branch'
      saved_current_issue="$(read_state_tsv_value "$(batch_state_file "$saved_current_batch")" current_issue 2>/dev/null)"
      [[ -n "$saved_current_issue" ]] || saved_current_issue="$batch_current_issue"

      write_batch_state \
        "$saved_current_batch" failed "$batch_phase" "$saved_current_issue" "$original_exit_code" >/dev/null 2>&1

      if [[ -n "$saved_current_issue" ]]; then
        issue_status="$(read_state_tsv_value "$(issue_state_file "$saved_current_batch" "$saved_current_issue")" status 2>/dev/null)"
        if [[ "$issue_status" == 'leased' ]]; then
          issue_phase="$(read_state_tsv_value "$(issue_state_file "$saved_current_batch" "$saved_current_issue")" phase 2>/dev/null)"
          [[ -n "$issue_phase" ]] || issue_phase='context'
          write_issue_state \
            "$saved_current_batch" "$saved_current_issue" failed "$issue_phase" "$original_exit_code" >/dev/null 2>&1
        fi
      fi
    fi
  fi

  if [[ -n "$queue_lock" ]]; then
    rm -f -- "$queue_lock" >/dev/null 2>&1
  fi

  exit "$original_exit_code"
}

ensure_fresh_queue_state_allows_start() {
  local existing_status

  if [[ ! -f "$CODEX_FLOW_QUEUE_STATE_FILE" ]]; then
    return 0
  fi

  if ! existing_status="$(read_state_tsv_value "$CODEX_FLOW_QUEUE_STATE_FILE" status)"; then
    fail "Cannot start a fresh queue from unsupported state in ${CODEX_FLOW_QUEUE_STATE_FILE}."
  fi

  case "$existing_status" in
    succeeded)
      return 0
      ;;
    running|failed)
      fail "Queue state is ${existing_status}; do not overwrite it with a fresh run. Use --resume."
      ;;
    *)
      fail "Cannot start a fresh queue from queue status: ${existing_status}"
      ;;
  esac
}

ensure_planned_batch_directories_available() {
  local start_index=0
  local end_index
  local first_issue
  local last_issue
  local batch_id
  local batch_dir
  local issue_count="${#issue_numbers[@]}"

  while [[ "$start_index" -lt "$issue_count" ]]; do
    end_index=$((start_index + review_every))
    if [[ "$end_index" -gt "$issue_count" ]]; then
      end_index="$issue_count"
    fi

    first_issue="${issue_numbers[$start_index]}"
    last_issue="${issue_numbers[$((end_index - 1))]}"
    batch_id="$(batch_id_for_range "$first_issue" "$last_issue")"
    batch_dir="${CODEX_FLOW_QUEUE_DIR}/batches/${batch_id}"
    if [[ -e "$batch_dir" ]]; then
      fail "Batch artifact directory already exists: ${batch_dir}"
    fi

    start_index="$end_index"
  done
}

write_queue_plan() {
  local issue_number

  {
    printf 'schema_version\t%s\n' "$CODEX_FLOW_QUEUE_STATE_SCHEMA_VERSION"
    printf 'review_every\t%s\n' "$review_every"
    printf 'batch_review_effort\t%s\n' "$batch_review_effort"
    printf 'batch_review_fix_effort\t%s\n' "$batch_review_fix_effort"
    printf 'batch_check_fix_effort\t%s\n' "$batch_check_fix_effort"
    printf 'draft_pr\t%s\n' "$draft_pr"
    printf 'auto_merge\t%s\n' "$auto_merge"
    for issue_number in "${issue_numbers[@]}"; do
      printf 'issue\t%s\n' "$issue_number"
    done
  } | atomic_write_from_stdin "$CODEX_FLOW_QUEUE_PLAN_FILE"
}

initialize_planned_queue_artifacts() {
  local start_index=0
  local end_index
  local first_issue
  local last_issue
  local batch_id
  local batch_dir
  local batch_branch
  local issue_number
  local index
  local issue_count="${#issue_numbers[@]}"

  write_queue_state running initializing '' ''
  queue_lifecycle_started=1
  write_atomic_value "${CODEX_FLOW_QUEUE_DIR}/current_batch" ''

  while [[ "$start_index" -lt "$issue_count" ]]; do
    end_index=$((start_index + review_every))
    if [[ "$end_index" -gt "$issue_count" ]]; then
      end_index="$issue_count"
    fi

    first_issue="${issue_numbers[$start_index]}"
    last_issue="${issue_numbers[$((end_index - 1))]}"
    batch_id="$(batch_id_for_range "$first_issue" "$last_issue")"
    batch_dir="${CODEX_FLOW_QUEUE_DIR}/batches/${batch_id}"
    batch_branch="$(batch_branch_name_for_range "$first_issue" "$last_issue")"

    mkdir -p "${batch_dir}/history"
    initialize_batch_token_usage_tsv "$batch_dir"
    printf '' | atomic_write_from_stdin "${batch_dir}/issues.txt"
    write_atomic_value "${batch_dir}/branch" "$batch_branch"
    write_batch_state "$batch_id" planned branch '' ''

    for ((index = start_index; index < end_index; index += 1)); do
      issue_number="${issue_numbers[$index]}"
      mkdir -p "${batch_dir}/issues/${issue_number}"
      write_issue_state "$batch_id" "$issue_number" queued context ''
    done

    start_index="$end_index"
  done

  write_queue_state running batch '' ''
}

append_issue_context_to_batch_file() {
  local issue_number="$1"
  local issue_file="$2"
  local issues_file="$3"

  if [[ -f "$issues_file" ]] && grep -Fxq "## Issue #${issue_number}" "$issues_file"; then
    return 0
  fi

  {
    if [[ -f "$issues_file" ]]; then
      cat "$issues_file"
    fi
    printf '## Issue #%s\n\n' "$issue_number"
    cat "$issue_file"
    printf '\n'
  } | atomic_write_from_stdin "$issues_file"
}

archive_issue_codex_artifacts() {
  local batch_dir="$1"
  local issue_number="$2"
  local destination="${batch_dir}/issues/${issue_number}/codex"
  local destination_parent
  local temporary_directory

  if [[ ! -d "$CODEX_FLOW_CODEX_DIR" ]]; then
    fail "Missing Codex artifact directory after issue ${issue_number}: ${CODEX_FLOW_CODEX_DIR}"
  fi

  if [[ -e "$destination" ]]; then
    fail "Codex archive destination already exists: ${destination}"
  fi

  destination_parent="$(dirname "$destination")"
  mkdir -p "$destination_parent"
  temporary_directory="$(mktemp -d "${destination_parent}/.codex.tmp.XXXXXX")"

  if ! cp -R "${CODEX_FLOW_CODEX_DIR}/." "$temporary_directory/"; then
    rm -rf -- "$temporary_directory"
    fail "Failed to copy Codex artifacts for issue ${issue_number}"
  fi

  if ! mv -- "$temporary_directory" "$destination"; then
    rm -rf -- "$temporary_directory"
    fail "Failed to atomically archive Codex artifacts for issue ${issue_number}: ${destination}"
  fi
}

reconcile_issue_codex_archive() {
  local batch_dir="$1"
  local issue_number="$2"
  local issue_dir="${batch_dir}/issues/${issue_number}"
  local destination="${issue_dir}/codex"

  find "$issue_dir" -mindepth 1 -maxdepth 1 -type d -name '.codex.tmp.*' \
    -exec rm -rf -- {} +

  if [[ ! -d "$destination" ]]; then
    archive_issue_codex_artifacts "$batch_dir" "$issue_number"
  else
    log_info "reusing completed Codex archive for issue ${issue_number}"
  fi

  rm -rf -- "$CODEX_FLOW_CODEX_DIR"
}

create_batch_branch() {
  local branch_name="$1"
  local batch_dir="$2"
  local batch_base_commit

  log_info "fetching origin/${CODEX_FLOW_BASE_BRANCH}"
  git fetch origin "$CODEX_FLOW_BASE_BRANCH"
  require_flow_base_ref
  batch_base_commit="$(git rev-parse --verify "${CODEX_FLOW_BASE_REF}^{commit}")"
  write_atomic_value "${batch_dir}/base_commit" "$batch_base_commit"
  log_info "creating batch branch ${branch_name}"
  git switch --create "$branch_name" "$batch_base_commit"
}

resolve_commit_file() {
  local commit_file="$1"
  local label="$2"
  local saved_commit
  local resolved_commit

  if [[ ! -f "$commit_file" ]]; then
    fail "Missing ${label}: ${commit_file}"
  fi
  saved_commit="$(< "$commit_file")"
  if ! resolved_commit="$(git rev-parse --verify "${saved_commit}^{commit}" 2>/dev/null)"; then
    fail "Invalid ${label} in ${commit_file}: ${saved_commit}"
  fi
  printf '%s\n' "$resolved_commit"
}

restore_batch_branch() {
  local batch_id="$1"
  local batch_branch="$2"
  local batch_dir="$3"
  local allow_create="$4"
  local batch_base_commit
  local current_branch
  local worktree_status

  batch_base_commit="$(resolve_commit_file "${batch_dir}/base_commit" 'batch base commit')"
  current_branch="$(git branch --show-current)"
  worktree_status="$(status_outside_work)"

  if ! git show-ref --verify --quiet "refs/heads/${batch_branch}"; then
    if [[ "$allow_create" -ne 1 ]]; then
      fail "Missing local batch branch required for resume: ${batch_branch}"
    fi
    if [[ -n "$worktree_status" ]]; then
      fail "Cannot recreate batch branch ${batch_branch} with a dirty worktree"
    fi
    log_info "recreating batch branch ${batch_branch} from saved base commit"
    git switch --create "$batch_branch" "$batch_base_commit"
  elif [[ "$current_branch" != "$batch_branch" ]]; then
    if [[ -n "$worktree_status" ]]; then
      fail "Cannot resume batch ${batch_id} from dirty branch ${current_branch:-detached}; expected ${batch_branch}"
    fi
    log_info "switching to saved batch branch ${batch_branch}"
    git switch "$batch_branch"
  fi

  if ! git merge-base --is-ancestor "$batch_base_commit" "$batch_branch"; then
    fail "Saved batch base commit is not in local branch history: ${batch_base_commit} not in ${batch_branch}"
  fi

  write_atomic_value "$CODEX_FLOW_CURRENT_BRANCH_FILE" "$batch_branch"
}

reconcile_batch_branch_phase() {
  local batch_id="$1"
  local batch_branch="$2"
  local batch_dir="$3"

  if [[ ! -f "${batch_dir}/base_commit" ]]; then
    if git show-ref --verify --quiet "refs/heads/${batch_branch}"; then
      fail "Batch branch exists without saved base commit: ${batch_branch}"
    fi
    create_batch_branch "$batch_branch" "$batch_dir"
    return 0
  fi

  restore_batch_branch "$batch_id" "$batch_branch" "$batch_dir" 1
}

restore_issue_runtime_state() {
  local issue_number="$1"
  local batch_branch="$2"
  local batch_dir="$3"
  local issue_base_commit

  issue_base_commit="$(resolve_commit_file "${batch_dir}/issues/${issue_number}/base_commit" "Issue ${issue_number} base commit")"
  write_atomic_value "$CODEX_FLOW_CURRENT_ISSUE_FILE" "$issue_number"
  write_atomic_value "$CODEX_FLOW_CURRENT_BRANCH_FILE" "$batch_branch"
  write_atomic_value "$CODEX_FLOW_BASE_COMMIT_FILE" "$issue_base_commit"
}

prepare_issue_context_on_batch_branch() {
  local issue_number="$1"
  local batch_branch="$2"
  local batch_dir="$3"
  local issues_file="$4"
  local batch_id="$5"
  local issue_dir="${batch_dir}/issues/${issue_number}"
  local issue_file
  local issue_base_commit

  batch_current_issue="$issue_number"
  write_batch_state "$batch_id" running issues "$issue_number" ''
  write_issue_state "$batch_id" "$issue_number" leased context ''
  ensure_clean_worktree "Working tree must be clean before processing issue ${issue_number}."
  rm -rf -- "$CODEX_FLOW_CODEX_DIR"

  log_info "fetching issue ${issue_number}"
  write_issue_context_file "$issue_number"
  issue_file="$(require_issue_file "$issue_number")"
  append_issue_context_to_batch_file "$issue_number" "$issue_file" "$issues_file"

  if [[ -f "${issue_dir}/base_commit" ]]; then
    issue_base_commit="$(resolve_commit_file "${issue_dir}/base_commit" "Issue ${issue_number} base commit")"
    if [[ "$issue_base_commit" != "$(git rev-parse --verify 'HEAD^{commit}')" ]]; then
      fail "Saved Issue ${issue_number} base commit does not match current HEAD during context reconciliation"
    fi
  else
    issue_base_commit="$(git rev-parse --verify 'HEAD^{commit}')"
    write_atomic_value "${issue_dir}/base_commit" "$issue_base_commit"
  fi
  write_atomic_value "$CODEX_FLOW_CURRENT_ISSUE_FILE" "$issue_number"
  write_atomic_value "$CODEX_FLOW_CURRENT_BRANCH_FILE" "$batch_branch"
  write_atomic_value "$CODEX_FLOW_BASE_COMMIT_FILE" "$issue_base_commit"
  write_issue_state "$batch_id" "$issue_number" leased implementation ''
}

run_issue_checkpoint_flow() {
  local issue_number="$1"
  local batch_dir="$2"
  local batch_id="$3"
  local issue_checkpoint_file
  local issue_head_commit_file
  local issue_light_review=0

  issue_checkpoint_file="$(issue_state_file "$batch_id" "$issue_number")"
  issue_head_commit_file="${batch_dir}/issues/${issue_number}/head_commit"

  log_info "running issue flow for issue ${issue_number}"
  if [[ "$CODEX_FLOW_QUEUE_LIGHT_ISSUE_REVIEW" -ne 0 ]]; then
    issue_light_review=1
  fi
  CODEX_FLOW_SKIP_PUBLISH=1 \
    CODEX_FLOW_LIGHT_ISSUE_REVIEW="$issue_light_review" \
    CODEX_FLOW_PHASE_STATE_FILE="$issue_checkpoint_file" \
    CODEX_FLOW_ISSUE_HEAD_COMMIT_FILE="$issue_head_commit_file" \
    "${ISSUE_FORGE_ENGINE_CODEX_DIR}/run_issue_flow.sh" "$issue_number"
  if [[ "$(read_state_tsv_value "$issue_checkpoint_file" status)" != 'committed' \
    || "$(read_state_tsv_value "$issue_checkpoint_file" phase)" != 'archive' ]]; then
    fail "Issue ${issue_number} flow returned without a committed / archive checkpoint"
  fi
}

validate_issue_head_in_batch_branch() {
  local batch_dir="$1"
  local issue_number="$2"
  local batch_branch="$3"
  local issue_head_commit

  issue_head_commit="$(resolve_commit_file "${batch_dir}/issues/${issue_number}/head_commit" "Issue ${issue_number} head commit")"
  if ! git merge-base --is-ancestor "$issue_head_commit" "$batch_branch"; then
    fail "Issue ${issue_number} head commit is not in batch branch history: ${issue_head_commit}"
  fi
}

process_issue_on_batch_branch() {
  local issue_number="$1"
  local batch_branch="$2"
  local batch_dir="$3"
  local issues_file="$4"
  local batch_id="$5"
  local issue_status
  local issue_phase

  while true; do
    issue_status="$(read_state_tsv_value "$(issue_state_file "$batch_id" "$issue_number")" status)"
    issue_phase="$(read_state_tsv_value "$(issue_state_file "$batch_id" "$issue_number")" phase)"

    case "${issue_status}/${issue_phase}" in
      acked/done)
        return 0
        ;;
      committed/batch)
        validate_issue_head_in_batch_branch "$batch_dir" "$issue_number" "$batch_branch"
        return 0
        ;;
      queued/context|leased/context|failed/context)
        prepare_issue_context_on_batch_branch \
          "$issue_number" "$batch_branch" "$batch_dir" "$issues_file" "$batch_id"
        ;;
      leased/implementation|failed/implementation|leased/checks|failed/checks|leased/review|failed/review|leased/commit|failed/commit)
        batch_current_issue="$issue_number"
        write_batch_state "$batch_id" running issues "$issue_number" ''
        write_issue_state "$batch_id" "$issue_number" leased "$issue_phase" ''
        restore_issue_runtime_state "$issue_number" "$batch_branch" "$batch_dir"
        run_issue_checkpoint_flow "$issue_number" "$batch_dir" "$batch_id"
        ;;
      committed/archive)
        batch_current_issue="$issue_number"
        write_batch_state "$batch_id" running issues "$issue_number" ''
        restore_issue_runtime_state "$issue_number" "$batch_branch" "$batch_dir"
        ensure_clean_worktree "Issue ${issue_number} archive reconciliation requires a clean worktree."
        validate_issue_head_in_batch_branch "$batch_dir" "$issue_number" "$batch_branch"
        reconcile_issue_codex_archive "$batch_dir" "$issue_number"
        write_issue_state "$batch_id" "$issue_number" committed batch ''
        write_batch_state "$batch_id" running issues '' ''
        batch_current_issue=''
        ;;
      *)
        fail "Unsupported Issue state for issue ${issue_number}: ${issue_status} / ${issue_phase}"
        ;;
    esac
  done
}

ack_batch_issues() {
  local batch_id="$1"
  local batch_dir="$2"
  local batch_branch="$3"
  shift 3
  local issue_number
  local issue_status
  local issue_phase

  for issue_number in "$@"; do
    issue_status="$(read_state_tsv_value "$(issue_state_file "$batch_id" "$issue_number")" status)"
    issue_phase="$(read_state_tsv_value "$(issue_state_file "$batch_id" "$issue_number")" phase)"
    case "${issue_status}/${issue_phase}" in
      acked/done)
        ;;
      committed/batch)
        validate_issue_head_in_batch_branch "$batch_dir" "$issue_number" "$batch_branch"
        write_issue_state "$batch_id" "$issue_number" acked 'done' ''
        ;;
      *)
        fail "Cannot ack issue ${issue_number} from state ${issue_status} / ${issue_phase}"
        ;;
    esac
  done
}

process_batch() {
  local start_index="$1"
  local end_index="$2"
  local first_issue="${issue_numbers[$start_index]}"
  local last_issue="${issue_numbers[$((end_index - 1))]}"
  local batch_id
  local batch_dir
  local batch_branch
  local batch_base_commit
  local batch_pr_number
  local batch_pr_url
  local issues_file
  local batch_issues_label
  local index
  local issue_number
  local batch_status
  local batch_phase
  local -a batch_issues=()

  batch_id="$(batch_id_for_range "$first_issue" "$last_issue")"
  batch_dir="${CODEX_FLOW_QUEUE_DIR}/batches/${batch_id}"
  batch_branch="$(batch_branch_name_for_range "$first_issue" "$last_issue")"
  issues_file="${batch_dir}/issues.txt"
  batch_base_commit=''

  for ((index = start_index; index < end_index; index += 1)); do
    batch_issues+=("${issue_numbers[$index]}")
  done
  batch_issues_label="$(join_issue_numbers "${batch_issues[@]}")"

  queue_current_batch="$batch_id"
  write_atomic_value "${CODEX_FLOW_QUEUE_DIR}/current_batch" "$batch_id"
  write_queue_state running batch "$batch_id" ''

  while true; do
    batch_status="$(read_state_tsv_value "$(batch_state_file "$batch_id")" status)"
    batch_phase="$(read_state_tsv_value "$(batch_state_file "$batch_id")" phase)"
    case "$batch_status" in
      planned|running|failed) ;;
      succeeded)
        if [[ "$batch_phase" == 'done' ]]; then
          break
        fi
        fail "Succeeded batch has non-terminal phase: ${batch_id} / ${batch_phase}"
        ;;
      *) fail "Unsupported batch status for ${batch_id}: ${batch_status}" ;;
    esac

    if [[ "$batch_status" == 'failed' ]]; then
      write_batch_state "$batch_id" running "$batch_phase" \
        "$(read_state_tsv_value "$(batch_state_file "$batch_id")" current_issue)" ''
    fi

    case "$batch_phase" in
      branch)
        reconcile_batch_branch_phase "$batch_id" "$batch_branch" "$batch_dir"
        write_batch_state "$batch_id" running issues '' ''
        ;;
      issues)
        restore_batch_branch "$batch_id" "$batch_branch" "$batch_dir" 0
        batch_base_commit="$(resolve_commit_file "${batch_dir}/base_commit" 'batch base commit')"
        for issue_number in "${batch_issues[@]}"; do
          process_issue_on_batch_branch "$issue_number" "$batch_branch" "$batch_dir" "$issues_file" "$batch_id"
        done
        write_batch_state "$batch_id" running checks '' ''
        ;;
      checks)
        restore_batch_branch "$batch_id" "$batch_branch" "$batch_dir" 0
        batch_base_commit="$(resolve_commit_file "${batch_dir}/base_commit" 'batch base commit')"
        ensure_batch_checks_pass "$batch_dir" "$issues_file" "$batch_base_commit" "$first_issue" "$last_issue" "$batch_issues_label" "$batch_check_fix_effort"
        write_batch_state "$batch_id" running review '' ''
        ;;
      review)
        restore_batch_branch "$batch_id" "$batch_branch" "$batch_dir" 0
        batch_base_commit="$(resolve_commit_file "${batch_dir}/base_commit" 'batch base commit')"
        ensure_batch_review_accepted \
          "$batch_dir" "$issues_file" "$batch_base_commit" "$first_issue" "$last_issue" \
          "$batch_issues_label" "$batch_review_effort" "$batch_review_fix_effort" "$batch_check_fix_effort"
        write_batch_state "$batch_id" running publish '' ''
        ;;
      publish)
        restore_batch_branch "$batch_id" "$batch_branch" "$batch_dir" 0
        batch_base_commit="$(resolve_commit_file "${batch_dir}/base_commit" 'batch base commit')"
        write_batch_head_metadata "$batch_dir" "$batch_base_commit"
        publish_batch_results \
          "$batch_dir" "$first_issue" "$last_issue" "$batch_branch" "$draft_pr" \
          batch_pr_number batch_pr_url "${batch_issues[@]}"
        if [[ -z "$batch_pr_number" || -z "$batch_pr_url" ]]; then
          fail 'Batch publish returned incomplete PR metadata.'
        fi
        if [[ "$auto_merge" -eq 1 ]]; then
          write_batch_state "$batch_id" running merge '' ''
        else
          write_batch_state "$batch_id" running ack '' ''
        fi
        ;;
      merge)
        restore_batch_branch "$batch_id" "$batch_branch" "$batch_dir" 0
        if [[ ! -f "${batch_dir}/pr_number" || ! -f "${batch_dir}/pr_url" ]]; then
          fail "Missing saved batch PR metadata required for merge: ${batch_dir}/pr_number and ${batch_dir}/pr_url"
        fi
        batch_pr_number="$(< "${batch_dir}/pr_number")"
        if [[ ! "$batch_pr_number" =~ ^[0-9]+$ ]]; then
          fail "Invalid saved batch PR number for merge: ${batch_pr_number}"
        fi
        auto_merge_batch_pr "$batch_pr_number"
        write_batch_state "$batch_id" running ack '' ''
        ;;
      ack)
        restore_batch_branch "$batch_id" "$batch_branch" "$batch_dir" 0
        ack_batch_issues "$batch_id" "$batch_dir" "$batch_branch" "${batch_issues[@]}"
        write_batch_state "$batch_id" succeeded 'done' '' ''
        ;;
      done)
        if [[ "$batch_status" != 'succeeded' ]]; then
          fail "Batch done phase requires succeeded status: ${batch_id}"
        fi
        ;;
      *)
        fail "Unsupported batch phase for ${batch_id}: ${batch_phase}"
        ;;
    esac
  done

  batch_current_issue=''
  queue_current_batch=''
  write_atomic_value "${CODEX_FLOW_QUEUE_DIR}/current_batch" ''
  write_queue_state running batch '' ''
}

validate_resume_queue_artifacts() {
  local start_index=0
  local end_index
  local first_issue
  local last_issue
  local batch_id
  local batch_dir
  local expected_branch
  local saved_branch
  local batch_status
  local batch_phase
  local issue_number
  local index
  local checkpoint_batch
  local checkpoint_known=0
  local issue_count="${#issue_numbers[@]}"

  checkpoint_batch="$(read_state_tsv_value "$CODEX_FLOW_QUEUE_STATE_FILE" current_batch)"

  while [[ "$start_index" -lt "$issue_count" ]]; do
    end_index=$((start_index + review_every))
    if [[ "$end_index" -gt "$issue_count" ]]; then
      end_index="$issue_count"
    fi
    first_issue="${issue_numbers[$start_index]}"
    last_issue="${issue_numbers[$((end_index - 1))]}"
    batch_id="$(batch_id_for_range "$first_issue" "$last_issue")"
    batch_dir="${CODEX_FLOW_QUEUE_DIR}/batches/${batch_id}"
    expected_branch="$(batch_branch_name_for_range "$first_issue" "$last_issue")"

    if [[ ! -d "$batch_dir" ]]; then
      fail "Missing planned batch artifact directory: ${batch_dir}"
    fi
    if [[ ! -f "${batch_dir}/branch" ]]; then
      fail "Missing saved batch branch metadata: ${batch_dir}/branch"
    fi
    saved_branch="$(< "${batch_dir}/branch")"
    if [[ "$saved_branch" != "$expected_branch" ]]; then
      fail "Saved batch branch does not match restored plan for ${batch_id}: ${saved_branch} != ${expected_branch}"
    fi

    batch_status="$(read_state_tsv_value "$(batch_state_file "$batch_id")" status)"
    batch_phase="$(read_state_tsv_value "$(batch_state_file "$batch_id")" phase)"
    read_state_tsv_value "$(batch_state_file "$batch_id")" current_issue >/dev/null
    read_state_tsv_value "$(batch_state_file "$batch_id")" exit_code >/dev/null
    if [[ "$batch_status" == 'succeeded' && "$batch_phase" != 'done' ]]; then
      fail "Succeeded batch has non-terminal phase: ${batch_id} / ${batch_phase}"
    fi

    for ((index = start_index; index < end_index; index += 1)); do
      issue_number="${issue_numbers[$index]}"
      read_state_tsv_value "$(issue_state_file "$batch_id" "$issue_number")" status >/dev/null
      read_state_tsv_value "$(issue_state_file "$batch_id" "$issue_number")" phase >/dev/null
      read_state_tsv_value "$(issue_state_file "$batch_id" "$issue_number")" lease_owner >/dev/null
      read_state_tsv_value "$(issue_state_file "$batch_id" "$issue_number")" exit_code >/dev/null
    done

    if [[ -n "$checkpoint_batch" && "$checkpoint_batch" == "$batch_id" ]]; then
      checkpoint_known=1
    fi
    start_index="$end_index"
  done

  if [[ -n "$checkpoint_batch" && "$checkpoint_known" -ne 1 ]]; then
    fail "Queue current_batch is not present in the restored plan: ${checkpoint_batch}"
  fi
}

validate_resume_queue_state_file() {
  if [[ ! -f "$CODEX_FLOW_QUEUE_STATE_FILE" ]]; then
    if [[ "$queue_requeue_mode" -eq 1 ]]; then
      fail "Missing queue state file required for --requeue: ${CODEX_FLOW_QUEUE_STATE_FILE}"
    fi
    fail "Missing queue state file required for --resume: ${CODEX_FLOW_QUEUE_STATE_FILE}"
  fi
  read_state_tsv_value "$CODEX_FLOW_QUEUE_STATE_FILE" status >/dev/null
  read_state_tsv_value "$CODEX_FLOW_QUEUE_STATE_FILE" phase >/dev/null
  read_state_tsv_value "$CODEX_FLOW_QUEUE_STATE_FILE" current_batch >/dev/null
  read_state_tsv_value "$CODEX_FLOW_QUEUE_STATE_FILE" exit_code >/dev/null
}

requeue_current_failed_issue() {
  local target_index=-1
  local batch_start_index
  local batch_end_index
  local first_issue
  local last_issue
  local batch_id
  local batch_dir
  local expected_branch
  local saved_branch
  local issue_dir
  local issue_status
  local issue_phase
  local queue_status
  local first_unfinished_issue=''
  local later_issue
  local later_status
  local current_branch
  local worktree_status
  local issue_base_commit
  local index

  for index in "${!issue_numbers[@]}"; do
    if [[ "${issue_numbers[$index]}" == "$requeue_issue_number" ]]; then
      target_index="$index"
      break
    fi
  done
  if [[ "$target_index" -lt 0 ]]; then
    fail "Issue ${requeue_issue_number} is not present in the saved queue plan"
  fi

  batch_start_index=$(((target_index / review_every) * review_every))
  batch_end_index=$((batch_start_index + review_every))
  if [[ "$batch_end_index" -gt "${#issue_numbers[@]}" ]]; then
    batch_end_index="${#issue_numbers[@]}"
  fi
  first_issue="${issue_numbers[$batch_start_index]}"
  last_issue="${issue_numbers[$((batch_end_index - 1))]}"
  batch_id="$(batch_id_for_range "$first_issue" "$last_issue")"
  batch_dir="${CODEX_FLOW_QUEUE_DIR}/batches/${batch_id}"
  expected_branch="$(batch_branch_name_for_range "$first_issue" "$last_issue")"
  issue_dir="${batch_dir}/issues/${requeue_issue_number}"

  issue_status="$(read_state_tsv_value "${issue_dir}/state.tsv" status)"
  issue_phase="$(read_state_tsv_value "${issue_dir}/state.tsv" phase)"
  case "$issue_status" in
    committed|acked)
      fail "Issue ${requeue_issue_number} is already committed/acked and cannot be requeued"
      ;;
    failed|leased) ;;
    *)
      fail "Issue ${requeue_issue_number} is not the current failed Issue: ${issue_status} / ${issue_phase}"
      ;;
  esac

  for ((index = batch_start_index; index < batch_end_index; index += 1)); do
    later_issue="${issue_numbers[$index]}"
    later_status="$(read_state_tsv_value "$(issue_state_file "$batch_id" "$later_issue")" status)"
    if [[ -z "$first_unfinished_issue" && "$later_status" != 'committed' && "$later_status" != 'acked' ]]; then
      first_unfinished_issue="$later_issue"
    fi
  done
  if [[ "$first_unfinished_issue" != "$requeue_issue_number" ]]; then
    fail "Issue ${requeue_issue_number} is not the current failed Issue; first unfinished Issue in ${batch_id} is ${first_unfinished_issue:-none}"
  fi

  for ((index = target_index + 1; index < batch_end_index; index += 1)); do
    later_issue="${issue_numbers[$index]}"
    later_status="$(read_state_tsv_value "$(issue_state_file "$batch_id" "$later_issue")" status)"
    case "$later_status" in
      leased|committed|acked|failed)
        fail "Later Issue ${later_issue} has already progressed with status ${later_status}; refusing to requeue Issue ${requeue_issue_number}"
        ;;
    esac
  done

  queue_status="$(read_state_tsv_value "$CODEX_FLOW_QUEUE_STATE_FILE" status)"
  case "$queue_status" in
    running|failed) ;;
    *)
      fail "Issue ${requeue_issue_number} is not the current failed Issue because queue status is ${queue_status}"
      ;;
  esac

  if [[ ! -f "${batch_dir}/branch" ]]; then
    fail "Missing saved local batch branch metadata for requeue: ${batch_dir}/branch"
  fi
  saved_branch="$(< "${batch_dir}/branch")"
  if [[ "$saved_branch" != "$expected_branch" ]]; then
    fail "Saved batch branch does not match the queue plan for ${batch_id}: ${saved_branch} != ${expected_branch}"
  fi
  if ! git show-ref --verify --quiet "refs/heads/${saved_branch}"; then
    fail "Missing local batch branch required for requeue: ${saved_branch}"
  fi
  issue_base_commit="$(resolve_commit_file "${issue_dir}/base_commit" "Issue ${requeue_issue_number} base commit required for requeue")"

  if [[ -f "${batch_dir}/pr_number" && -f "${batch_dir}/pr_url" ]]; then
    fail "Batch ${batch_id} already has published PR metadata; requeue after PR publication is not supported"
  fi

  current_branch="$(git branch --show-current)"
  worktree_status="$(status_outside_work)"
  if [[ -n "$worktree_status" && "$current_branch" != "$saved_branch" ]]; then
    fail "Cannot requeue Issue ${requeue_issue_number} from dirty branch ${current_branch:-detached}; expected ${saved_branch}"
  fi
  if [[ -z "$worktree_status" && "$current_branch" != "$saved_branch" ]]; then
    log_info "switching to saved batch branch ${saved_branch}"
    git switch "$saved_branch"
  fi

  log_info "destructively requeueing Issue ${requeue_issue_number} from ${issue_base_commit}"
  git reset --hard "$issue_base_commit"
  git clean -fd "${CODEX_FLOW_CLEAN_EXCLUDE_ARGS[@]}" -- . "$CODEX_FLOW_WORKTREE_EXCLUDE_PATHSPEC"

  rm -rf -- "$CODEX_FLOW_CODEX_DIR" "${issue_dir}/codex"
  find "$issue_dir" -mindepth 1 -maxdepth 1 -type d -name '.codex.tmp.*' -exec rm -rf -- {} +
  rm -f -- "${issue_dir}/head_commit"
  rm -f -- \
    "${batch_dir}/head_commit" \
    "${batch_dir}/changed-files.txt" \
    "${batch_dir}/checks.log" \
    "${batch_dir}/batch-review.txt" \
    "${batch_dir}/batch-review.raw.txt" \
    "${batch_dir}/pr_number" \
    "${batch_dir}/pr_url"

  write_atomic_value "$CODEX_FLOW_CURRENT_ISSUE_FILE" "$requeue_issue_number"
  write_atomic_value "$CODEX_FLOW_CURRENT_BRANCH_FILE" "$saved_branch"
  write_issue_state "$batch_id" "$requeue_issue_number" queued context ''
  write_batch_state "$batch_id" failed issues "$requeue_issue_number" ''
  write_atomic_value "${CODEX_FLOW_QUEUE_DIR}/current_batch" "$batch_id"
  write_queue_state failed batch "$batch_id" ''
  rm -f -- "${issue_dir}/base_commit" "$CODEX_FLOW_BASE_COMMIT_FILE"

  log_info "Issue ${requeue_issue_number} is queued at context; run run_issue_queue.sh --resume to restart it"
}

resume_queue_state() {
  local queue_status
  local queue_phase
  local checkpoint_batch

  queue_status="$(read_state_tsv_value "$CODEX_FLOW_QUEUE_STATE_FILE" status)"
  queue_phase="$(read_state_tsv_value "$CODEX_FLOW_QUEUE_STATE_FILE" phase)"
  checkpoint_batch="$(read_state_tsv_value "$CODEX_FLOW_QUEUE_STATE_FILE" current_batch)"

  if [[ "$queue_status" == 'succeeded' && "$queue_phase" == 'done' ]]; then
    log_info 'queue is already complete; nothing to resume'
    queue_resume_complete=1
    return 0
  fi

  case "$queue_status" in
    running|failed) ;;
    succeeded)
      fail "Succeeded queue has non-terminal phase: ${queue_phase}"
      ;;
    *)
      fail "Unsupported queue status for --resume: ${queue_status}"
      ;;
  esac

  queue_lifecycle_started=1
  write_queue_state running batch "$checkpoint_batch" ''
  return 0
}

run_planned_batches() {
  local issue_count="${#issue_numbers[@]}"
  local start_index=0
  local end_index
  local first_issue
  local last_issue
  local batch_id
  local batch_status
  local batch_phase

  while [[ "$start_index" -lt "$issue_count" ]]; do
    end_index=$((start_index + review_every))
    if [[ "$end_index" -gt "$issue_count" ]]; then
      end_index="$issue_count"
    fi
    first_issue="${issue_numbers[$start_index]}"
    last_issue="${issue_numbers[$((end_index - 1))]}"
    batch_id="$(batch_id_for_range "$first_issue" "$last_issue")"
    batch_status="$(read_state_tsv_value "$(batch_state_file "$batch_id")" status)"
    batch_phase="$(read_state_tsv_value "$(batch_state_file "$batch_id")" phase)"

    if [[ "$batch_status" == 'succeeded' && "$batch_phase" == 'done' ]]; then
      log_info "skipping completed batch ${batch_id}"
    else
      process_batch "$start_index" "$end_index"
    fi
    start_index="$end_index"
  done
}

main() {
  local issue_count
  local planned_batch_count

  parse_queue_cli "$@"

  require_command git
  require_command mktemp

  enter_repo_root

  if [[ "$queue_requeue_mode" -eq 1 ]]; then
    require_command find
    read_queue_plan
    ensure_unique_issues
    validate_resume_queue_state_file
    create_queue_lock
    validate_resume_queue_artifacts
    requeue_current_failed_issue
    return 0
  fi

  require_command awk
  require_command find
  require_command gh
  require_command sed
  require_queue_prompt_templates

  if [[ "$queue_resume_mode" -eq 1 ]]; then
    read_queue_plan
    ensure_unique_issues
    validate_resume_queue_state_file
    create_queue_lock
    resume_queue_state
    if [[ "$queue_resume_complete" -eq 1 ]]; then
      return 0
    fi
    validate_resume_queue_artifacts
  else
    ensure_unique_issues
    issue_count="${#issue_numbers[@]}"
    planned_batch_count="$(batch_count_for_queue "$issue_count")"
    if [[ "$planned_batch_count" -gt 1 && "$auto_merge" -ne 1 ]]; then
      fail 'Multiple batches require --auto-merge so each next batch starts from the merged base branch.'
    fi
    ensure_fresh_queue_state_allows_start
    ensure_clean_worktree 'Working tree must be clean before running the issue queue.'
    ensure_planned_batch_branches_available
    create_queue_lock
    ensure_planned_batch_directories_available
    write_queue_plan
    initialize_planned_queue_artifacts
  fi

  issue_count="${#issue_numbers[@]}"
  planned_batch_count="$(batch_count_for_queue "$issue_count")"
  if [[ "$planned_batch_count" -gt 1 && "$auto_merge" -ne 1 ]]; then
    fail 'Restored multi-batch queue requires auto_merge=1.'
  fi

  run_planned_batches

  queue_current_batch=''
  write_atomic_value "${CODEX_FLOW_QUEUE_DIR}/current_batch" ''
  write_queue_state succeeded 'done' '' ''
}

main "$@"
