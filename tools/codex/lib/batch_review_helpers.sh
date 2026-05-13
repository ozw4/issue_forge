#!/usr/bin/env bash

append_untracked_file_diff_to_batch() {
  local path="$1"
  local diff_file="$2"
  local status

  set +e
  git diff --no-index -- /dev/null "$path" >> "$diff_file"
  status=$?
  set -e

  if [[ "$status" -ne 0 && "$status" -ne 1 ]]; then
    printf 'Failed to generate batch review material for untracked file: %s\n' "$path" >&2
    exit 1
  fi
}

generate_batch_review_material() {
  local base_commit="$1"
  local batch_diff="$2"
  local batch_untracked="$3"
  local has_material=0
  local path

  git diff --no-ext-diff --binary "$base_commit" -- . "${CODEX_FLOW_WORKTREE_EXCLUDE_PATHS[@]}" > "$batch_diff"
  : > "$batch_untracked"

  while IFS= read -r path; do
    if [[ -z "$path" ]]; then
      continue
    fi

    has_material=1
    printf '%s\n' "$path" >> "$batch_untracked"
    append_untracked_file_diff_to_batch "$path" "$batch_diff"
  done < <(git ls-files --others --exclude-standard -- . "${CODEX_FLOW_WORKTREE_EXCLUDE_PATHS[@]}")

  if [[ -s "$batch_diff" ]]; then
    has_material=1
  fi

  if [[ "$has_material" -ne 1 ]]; then
    printf 'Batch review material is empty: %s\n' "$batch_diff" >&2
    exit 1
  fi
}

write_batch_changed_files() {
  local base_commit="$1"
  local output_file="$2"

  git diff --name-only "$base_commit" -- . "${CODEX_FLOW_WORKTREE_EXCLUDE_PATHS[@]}" > "$output_file"
}

run_codex_batch_write() {
  local prompt_file="$1"
  local output_log="$2"
  local reasoning_effort="$3"

  CODEX_RUN_REASONING_EFFORT="$reasoning_effort" \
    "${ISSUE_FORGE_ENGINE_CODEX_DIR}/run_codex.sh" write "$prompt_file" > "$output_log" 2>&1
}

run_codex_batch_read() {
  local prompt_file="$1"
  local output_log="$2"
  local reasoning_effort="$3"

  CODEX_RUN_REASONING_EFFORT="$reasoning_effort" \
    "${ISSUE_FORGE_ENGINE_CODEX_DIR}/run_codex.sh" read "$prompt_file" > "$output_log"
}

run_batch_checks_once() {
  local base_commit="$1"
  local checks_log="$2"
  local status

  set +e
  "$CODEX_FLOW_CHECKS_COMMAND" "$base_commit" > "$checks_log" 2>&1
  status=$?
  set -e

  return "$status"
}

ensure_batch_checks_pass() {
  local batch_dir="$1"
  local issues_file="$2"
  local base_commit="$3"
  local first_issue="$4"
  local last_issue="$5"
  local check_fix_effort="$6"
  local checks_log="${batch_dir}/checks.log"
  local fix_checks_prompt="${batch_dir}/fix-from-batch-checks.prompt.md"
  local fix_checks_log="${batch_dir}/fix-from-batch-checks.log"
  local fix_round=0
  local history_dir="${batch_dir}/history"

  mkdir -p "$history_dir"

  while true; do
    log_info 'running batch checks'
    if run_batch_checks_once "$base_commit" "$checks_log"; then
      archive_round_file "$checks_log" 'batch-checks' "$((fix_round + 1))" '.log'
      log_info 'batch checks passed'
      return 0
    fi

    archive_round_file "$checks_log" 'batch-checks' "$((fix_round + 1))" '.log'

    if [[ "$fix_round" -ge "$CODEX_FLOW_BATCH_CHECK_MAX_FIX_ROUNDS" ]]; then
      printf '[queue] batch checks failed after %s fix rounds\n' "$CODEX_FLOW_BATCH_CHECK_MAX_FIX_ROUNDS" >&2
      printf '[queue] see log: %s\n' "$checks_log" >&2
      exit 1
    fi

    fix_round=$((fix_round + 1))
    write_fix_from_batch_checks_prompt_file "$issues_file" "$checks_log" "$fix_checks_prompt"
    ensure_clean_worktree 'Working tree must be clean before batch checks fix.'
    log_info "codex fix from batch checks (round ${fix_round})"
    run_codex_batch_write "$fix_checks_prompt" "$fix_checks_log" "$check_fix_effort"
    archive_round_file "$fix_checks_log" 'fix-from-batch-checks' "$fix_round" '.log'

    if [[ -z "$(status_outside_work)" ]]; then
      printf 'Batch checks fix produced no repository changes.\n' >&2
      printf 'Batch checks fix log: %s\n' "$fix_checks_log" >&2
      exit 1
    fi

    commit_issue_changes "chore: address batch checks for issues #${first_issue}-#${last_issue}" 1
  done
}

ensure_valid_batch_review_output() {
  local batch_review_raw="$1"
  local batch_review_output="$2"

  if ! validate_review_output "$batch_review_output"; then
    printf '[queue] batch review output format is invalid\n' >&2
    printf '[queue] see log: %s\n' "$batch_review_raw" >&2
    exit 1
  fi

  if ! validate_review_output_semantics "$batch_review_output"; then
    printf '[queue] batch review output is inconsistent with acceptance\n' >&2
    printf '[queue] see log: %s\n' "$batch_review_raw" >&2
    exit 1
  fi
}

run_batch_review_once() {
  local batch_dir="$1"
  local issues_file="$2"
  local base_commit="$3"
  local review_effort="$4"
  local review_round="$5"
  local batch_diff="${batch_dir}/batch.diff"
  local batch_untracked="${batch_dir}/batch.untracked.txt"
  local batch_review_prompt="${batch_dir}/batch-review.prompt.md"
  local batch_review_raw="${batch_dir}/batch-review.raw.txt"
  local batch_review_output="${batch_dir}/batch-review.txt"
  local before_status
  local after_status
  local history_dir="${batch_dir}/history"

  mkdir -p "$history_dir"
  generate_batch_review_material "$base_commit" "$batch_diff" "$batch_untracked"
  archive_round_file "$batch_diff" 'batch-diff' "$review_round" '.txt'
  archive_round_file "$batch_untracked" 'batch-untracked' "$review_round" '.txt'
  write_batch_review_prompt_file "$issues_file" "$batch_diff" "$batch_untracked" "$batch_review_prompt"

  before_status="$(status_outside_work)"
  log_info "codex batch review (round ${review_round})"
  run_codex_batch_read "$batch_review_prompt" "$batch_review_raw" "$review_effort"
  archive_round_file "$batch_review_raw" 'batch-review-raw' "$review_round" '.txt'
  after_status="$(status_outside_work)"

  if [[ "$before_status" != "$after_status" ]]; then
    printf 'Batch review session modified repository files.\n' >&2
    printf 'Batch review raw log: %s\n' "$batch_review_raw" >&2
    exit 1
  fi

  if ! extract_structured_review_output_file "$batch_review_raw" "$batch_review_output"; then
    printf 'Failed to extract structured batch review output.\n' >&2
    printf 'Batch review raw log: %s\n' "$batch_review_raw" >&2
    exit 1
  fi
  archive_round_file "$batch_review_output" 'batch-review' "$review_round" '.txt'
  ensure_valid_batch_review_output "$batch_review_raw" "$batch_review_output"
}

ensure_batch_review_accepted() {
  local batch_dir="$1"
  local issues_file="$2"
  local base_commit="$3"
  local first_issue="$4"
  local last_issue="$5"
  local review_effort="$6"
  local review_fix_effort="$7"
  local check_fix_effort="$8"
  local batch_review_output="${batch_dir}/batch-review.txt"
  local fix_review_prompt="${batch_dir}/fix-from-batch-review.prompt.md"
  local fix_review_log="${batch_dir}/fix-from-batch-review.log"
  local review_fix_round=0
  local review_round=1
  local history_dir="${batch_dir}/history"

  mkdir -p "$history_dir"
  run_batch_review_once "$batch_dir" "$issues_file" "$base_commit" "$review_effort" "$review_round"

  while ! review_output_accepted "$batch_review_output"; do
    if [[ "$review_fix_round" -ge "$CODEX_FLOW_BATCH_REVIEW_MAX_FIX_ROUNDS" ]]; then
      printf '[queue] batch review did not reach acceptance after %s fix rounds\n' "$CODEX_FLOW_BATCH_REVIEW_MAX_FIX_ROUNDS" >&2
      printf '[queue] see review: %s\n' "$batch_review_output" >&2
      exit 1
    fi

    review_fix_round=$((review_fix_round + 1))
    write_fix_from_batch_review_prompt_file "$issues_file" "$batch_review_output" "$fix_review_prompt"
    ensure_clean_worktree 'Working tree must be clean before batch review fix.'
    log_info "codex fix from batch review (round ${review_fix_round})"
    run_codex_batch_write "$fix_review_prompt" "$fix_review_log" "$review_fix_effort"
    archive_round_file "$fix_review_log" 'fix-from-batch-review' "$review_fix_round" '.log'

    if [[ -z "$(status_outside_work)" ]]; then
      printf 'Batch review fix produced no repository changes.\n' >&2
      printf 'Batch review fix log: %s\n' "$fix_review_log" >&2
      exit 1
    fi

    commit_issue_changes "chore: address batch review for issues #${first_issue}-#${last_issue}" 1
    ensure_batch_checks_pass "$batch_dir" "$issues_file" "$base_commit" "$first_issue" "$last_issue" "$check_fix_effort"
    review_round=$((review_round + 1))
    run_batch_review_once "$batch_dir" "$issues_file" "$base_commit" "$review_effort" "$review_round"
  done
}
