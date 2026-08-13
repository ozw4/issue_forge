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

Options:
  --review-every <positive_integer>
  --batch-review-effort <non_empty_value_without_whitespace>
  --batch-fix-effort <non_empty_value_without_whitespace>
  --auto-merge
  --draft
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
  mkdir -p "$CODEX_FLOW_QUEUE_DIR"
  queue_lock="${CODEX_FLOW_QUEUE_DIR}/lock"

  if [[ -e "$queue_lock" ]]; then
    fail "Queue lock already exists: ${queue_lock}"
  fi

  printf '%s\n' "$$" > "$queue_lock"
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

  write_state_tsv "$(issue_state_file "$batch_id" "$issue_number")" \
    status "$3" \
    phase "$4" \
    lease_owner "$batch_id" \
    exit_code "$5"
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
      fail "Queue state is ${existing_status}; do not overwrite it with a fresh run. Use --resume when resume support is available."
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

process_issue_on_batch_branch() {
  local issue_number="$1"
  local batch_branch="$2"
  local batch_dir="$3"
  local issues_file="$4"
  local batch_id="$5"
  local issue_file
  local issue_base_commit
  local issue_head_commit
  local issue_light_review=0

  batch_current_issue="$issue_number"
  write_batch_state "$batch_id" running issues "$issue_number" ''
  write_issue_state "$batch_id" "$issue_number" leased context ''
  ensure_clean_worktree "Working tree must be clean before processing issue ${issue_number}."
  rm -rf "$CODEX_FLOW_CODEX_DIR"

  log_info "fetching issue ${issue_number}"
  write_issue_context_file "$issue_number"
  issue_file="$(require_issue_file "$issue_number")"
  append_issue_context_to_batch_file "$issue_number" "$issue_file" "$issues_file"

  issue_base_commit="$(git rev-parse --verify 'HEAD^{commit}')"
  write_atomic_value "${batch_dir}/issues/${issue_number}/base_commit" "$issue_base_commit"
  write_atomic_value "$CODEX_FLOW_CURRENT_ISSUE_FILE" "$issue_number"
  write_atomic_value "$CODEX_FLOW_CURRENT_BRANCH_FILE" "$batch_branch"
  write_atomic_value "$CODEX_FLOW_BASE_COMMIT_FILE" "$issue_base_commit"
  write_issue_state "$batch_id" "$issue_number" leased implementation ''

  log_info "running issue flow for issue ${issue_number}"
  if [[ "$CODEX_FLOW_QUEUE_LIGHT_ISSUE_REVIEW" -ne 0 ]]; then
    issue_light_review=1
  fi
  CODEX_FLOW_SKIP_PUBLISH=1 CODEX_FLOW_LIGHT_ISSUE_REVIEW="$issue_light_review" \
    "${ISSUE_FORGE_ENGINE_CODEX_DIR}/run_issue_flow.sh" "$issue_number"
  ensure_clean_worktree "Issue ${issue_number} flow left uncommitted repository changes."
  issue_head_commit="$(git rev-parse --verify 'HEAD^{commit}')"
  write_atomic_value "${batch_dir}/issues/${issue_number}/head_commit" "$issue_head_commit"
  archive_issue_codex_artifacts "$batch_dir" "$issue_number"
  write_issue_state "$batch_id" "$issue_number" committed batch ''
  write_batch_state "$batch_id" running issues '' ''
  batch_current_issue=''
  rm -rf "$CODEX_FLOW_CODEX_DIR"
}

read_pr_state_tsv() {
  local pr_number="$1"

  gh pr view "$pr_number" --json state,mergedAt --jq '[.state, (.mergedAt // "")] | @tsv'
}

wait_for_batch_pr_merge() {
  local pr_number="$1"
  local start_seconds="$SECONDS"
  local state_line
  local state
  local merged_at

  while true; do
    state_line="$(read_pr_state_tsv "$pr_number")"
    IFS=$'\t' read -r state merged_at <<< "$state_line"

    if [[ -z "$state" ]]; then
      fail "Malformed PR state response for PR #${pr_number}: ${state_line}"
    fi

    if [[ -n "$merged_at" ]]; then
      log_info "batch PR #${pr_number} merged"
      return 0
    fi

    if [[ "$state" == 'CLOSED' ]]; then
      fail "Batch PR #${pr_number} closed without merging"
    fi

    if (( SECONDS - start_seconds >= CODEX_FLOW_AUTO_MERGE_WAIT_SECONDS )); then
      fail "Timed out waiting for batch PR #${pr_number} to merge"
    fi

    sleep "$CODEX_FLOW_AUTO_MERGE_POLL_SECONDS"
  done
}

auto_merge_batch_pr() {
  local pr_number="$1"
  local head_sha

  head_sha="$(git rev-parse --verify 'HEAD^{commit}')"
  log_info "enabling auto-merge for batch PR #${pr_number}"
  gh pr merge "$pr_number" --auto --squash --delete-branch --match-head-commit "$head_sha"
  wait_for_batch_pr_merge "$pr_number"
  git fetch origin "$CODEX_FLOW_BASE_BRANCH"
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
  local batch_head_commit
  local batch_pr_number
  local batch_pr_url
  local issues_file
  local batch_issues_label
  local index
  local -a batch_issues=()

  batch_id="$(batch_id_for_range "$first_issue" "$last_issue")"
  batch_dir="${CODEX_FLOW_QUEUE_DIR}/batches/${batch_id}"
  batch_branch="$(batch_branch_name_for_range "$first_issue" "$last_issue")"
  issues_file="${batch_dir}/issues.txt"

  queue_current_batch="$batch_id"
  write_atomic_value "${CODEX_FLOW_QUEUE_DIR}/current_batch" "$batch_id"
  write_queue_state running batch "$batch_id" ''
  write_batch_state "$batch_id" running branch '' ''

  create_batch_branch "$batch_branch" "$batch_dir"
  batch_base_commit="$(< "${batch_dir}/base_commit")"
  write_batch_state "$batch_id" running issues '' ''

  for ((index = start_index; index < end_index; index += 1)); do
    batch_issues+=("${issue_numbers[$index]}")
    process_issue_on_batch_branch "${issue_numbers[$index]}" "$batch_branch" "$batch_dir" "$issues_file" "$batch_id"
  done

  batch_issues_label="$(join_issue_numbers "${batch_issues[@]}")"

  write_batch_state "$batch_id" running checks '' ''
  ensure_batch_checks_pass "$batch_dir" "$issues_file" "$batch_base_commit" "$first_issue" "$last_issue" "$batch_issues_label" "$batch_check_fix_effort"
  write_batch_state "$batch_id" running review '' ''
  ensure_batch_review_accepted \
    "$batch_dir" \
    "$issues_file" \
    "$batch_base_commit" \
    "$first_issue" \
    "$last_issue" \
    "$batch_issues_label" \
    "$batch_review_effort" \
    "$batch_review_fix_effort" \
    "$batch_check_fix_effort"

  batch_head_commit="$(git rev-parse --verify 'HEAD^{commit}')"
  write_atomic_value "${batch_dir}/head_commit" "$batch_head_commit"
  write_batch_changed_files "$batch_base_commit" "${batch_dir}/changed-files.txt"

  write_batch_state "$batch_id" running publish '' ''
  publish_batch_results \
    "$first_issue" \
    "$last_issue" \
    "$batch_branch" \
    "$draft_pr" \
    batch_pr_number \
    batch_pr_url \
    "${batch_issues[@]}"
  write_atomic_value "${batch_dir}/pr_number" "$batch_pr_number"
  write_atomic_value "${batch_dir}/pr_url" "$batch_pr_url"

  if [[ "$auto_merge" -eq 1 ]]; then
    write_batch_state "$batch_id" running merge '' ''
    auto_merge_batch_pr "$batch_pr_number"
  fi

  write_batch_state "$batch_id" running ack '' ''
  for index in "${!batch_issues[@]}"; do
    if [[ "$(read_state_tsv_value "$(issue_state_file "$batch_id" "${batch_issues[$index]}")" status)" != 'committed' ]]; then
      fail "Cannot ack issue ${batch_issues[$index]} because it is not committed"
    fi
    write_issue_state "$batch_id" "${batch_issues[$index]}" acked 'done' ''
  done

  write_batch_state "$batch_id" succeeded 'done' '' ''
  batch_current_issue=''
  queue_current_batch=''
  write_atomic_value "${CODEX_FLOW_QUEUE_DIR}/current_batch" ''
  write_queue_state running batch '' ''
}

main() {
  local issue_count
  local planned_batch_count
  local start_index=0
  local end_index

  parse_queue_arguments "$@"
  ensure_unique_issues

  issue_count="${#issue_numbers[@]}"
  planned_batch_count="$(batch_count_for_queue "$issue_count")"
  if [[ "$planned_batch_count" -gt 1 && "$auto_merge" -ne 1 ]]; then
    fail 'Multiple batches require --auto-merge so each next batch starts from the merged base branch.'
  fi

  require_command awk
  require_command gh
  require_command git
  require_command mktemp
  require_command sed

  enter_repo_root
  require_queue_prompt_templates
  ensure_clean_worktree 'Working tree must be clean before running the issue queue.'
  ensure_planned_batch_branches_available
  create_queue_lock
  ensure_fresh_queue_state_allows_start
  ensure_planned_batch_directories_available
  write_queue_plan
  initialize_planned_queue_artifacts

  while [[ "$start_index" -lt "$issue_count" ]]; do
    end_index=$((start_index + review_every))
    if [[ "$end_index" -gt "$issue_count" ]]; then
      end_index="$issue_count"
    fi

    process_batch "$start_index" "$end_index"
    start_index="$end_index"
  done

  queue_current_batch=''
  write_atomic_value "${CODEX_FLOW_QUEUE_DIR}/current_batch" ''
  write_queue_state succeeded 'done' '' ''
}

main "$@"
