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
# shellcheck source=tools/codex/lib/issue_bootstrap.sh
source "${SCRIPT_DIR}/lib/issue_bootstrap.sh"
# shellcheck source=tools/codex/lib/publish_helpers.sh
source "${SCRIPT_DIR}/lib/publish_helpers.sh"
# shellcheck source=tools/codex/lib/prompt_templates.sh
source "${SCRIPT_DIR}/lib/prompt_templates.sh"
# shellcheck source=tools/codex/lib/batch_review_helpers.sh
source "${SCRIPT_DIR}/lib/batch_review_helpers.sh"

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
  trap 'rm -f "$queue_lock"' EXIT
}

append_issue_context_to_batch_file() {
  local issue_number="$1"
  local issue_file="$2"
  local issues_file="$3"

  {
    printf '## Issue #%s\n\n' "$issue_number"
    cat "$issue_file"
    printf '\n'
  } >> "$issues_file"
}

archive_issue_codex_artifacts() {
  local batch_dir="$1"
  local issue_number="$2"
  local destination="${batch_dir}/issues/${issue_number}/codex"

  if [[ ! -d "$CODEX_FLOW_CODEX_DIR" ]]; then
    fail "Missing Codex artifact directory after issue ${issue_number}: ${CODEX_FLOW_CODEX_DIR}"
  fi

  if [[ -e "$destination" ]]; then
    fail "Codex archive destination already exists: ${destination}"
  fi

  mkdir -p "$(dirname "$destination")"
  cp -R "$CODEX_FLOW_CODEX_DIR" "$destination"
}

create_batch_branch() {
  local branch_name="$1"

  log_info "fetching origin/${CODEX_FLOW_BASE_BRANCH}"
  git fetch origin "$CODEX_FLOW_BASE_BRANCH"
  require_flow_base_ref
  log_info "creating batch branch ${branch_name}"
  git switch --create "$branch_name" "$CODEX_FLOW_BASE_REF"
}

process_issue_on_batch_branch() {
  local issue_number="$1"
  local batch_branch="$2"
  local batch_dir="$3"
  local issues_file="$4"
  local issue_file
  local issue_base_commit

  ensure_clean_worktree "Working tree must be clean before processing issue ${issue_number}."
  rm -rf "$CODEX_FLOW_CODEX_DIR"

  log_info "fetching issue ${issue_number}"
  write_issue_context_file "$issue_number"
  issue_file="$(require_issue_file "$issue_number")"
  append_issue_context_to_batch_file "$issue_number" "$issue_file" "$issues_file"

  issue_base_commit="$(git rev-parse --verify 'HEAD^{commit}')"
  write_current_issue_branch_state "$issue_number" "$batch_branch" "$issue_base_commit"

  log_info "running issue flow for issue ${issue_number}"
  CODEX_FLOW_SKIP_PUBLISH=1 "${ISSUE_FORGE_ENGINE_CODEX_DIR}/run_issue_flow.sh" "$issue_number"
  ensure_clean_worktree "Issue ${issue_number} flow left uncommitted repository changes."
  archive_issue_codex_artifacts "$batch_dir" "$issue_number"
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
  local _batch_pr_url
  local issues_file
  local index
  local -a batch_issues=()

  batch_id="$(batch_id_for_range "$first_issue" "$last_issue")"
  batch_dir="${CODEX_FLOW_QUEUE_DIR}/batches/${batch_id}"
  batch_branch="$(batch_branch_name_for_range "$first_issue" "$last_issue")"
  issues_file="${batch_dir}/issues.txt"

  if [[ -e "$batch_dir" ]]; then
    fail "Batch artifact directory already exists: ${batch_dir}"
  fi

  mkdir -p "${batch_dir}/history"
  : > "$issues_file"
  printf '%s\n' "$batch_id" > "${CODEX_FLOW_QUEUE_DIR}/current_batch"

  create_batch_branch "$batch_branch"
  batch_base_commit="$(git rev-parse --verify 'HEAD^{commit}')"
  printf '%s\n' "$batch_base_commit" > "${batch_dir}/base_commit"

  for ((index = start_index; index < end_index; index += 1)); do
    batch_issues+=("${issue_numbers[$index]}")
    process_issue_on_batch_branch "${issue_numbers[$index]}" "$batch_branch" "$batch_dir" "$issues_file"
  done

  ensure_batch_checks_pass "$batch_dir" "$issues_file" "$batch_base_commit" "$first_issue" "$last_issue" "$batch_check_fix_effort"
  ensure_batch_review_accepted \
    "$batch_dir" \
    "$issues_file" \
    "$batch_base_commit" \
    "$first_issue" \
    "$last_issue" \
    "$batch_review_effort" \
    "$batch_review_fix_effort" \
    "$batch_check_fix_effort"

  batch_head_commit="$(git rev-parse --verify 'HEAD^{commit}')"
  printf '%s\n' "$batch_head_commit" > "${batch_dir}/head_commit"
  write_batch_changed_files "$batch_base_commit" "${batch_dir}/changed-files.txt"

  publish_batch_results \
    "$first_issue" \
    "$last_issue" \
    "$batch_branch" \
    "$draft_pr" \
    batch_pr_number \
    _batch_pr_url \
    "${batch_issues[@]}"

  if [[ "$auto_merge" -eq 1 ]]; then
    auto_merge_batch_pr "$batch_pr_number"
  fi
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
  require_batch_prompt_templates
  ensure_clean_worktree 'Working tree must be clean before running the issue queue.'
  ensure_planned_batch_branches_available
  create_queue_lock

  while [[ "$start_index" -lt "$issue_count" ]]; do
    end_index=$((start_index + review_every))
    if [[ "$end_index" -gt "$issue_count" ]]; then
      end_index="$issue_count"
    fi

    process_batch "$start_index" "$end_index"
    start_index="$end_index"
  done
}

main "$@"
