#!/usr/bin/env bash

# shellcheck source=tools/codex/lib/review_material_helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/review_material_helpers.sh"
# shellcheck source=tools/codex/lib/token_usage_helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/token_usage_helpers.sh"
# shellcheck source=tools/codex/lib/agent_attempts.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/agent_attempts.sh"
# shellcheck source=tools/codex/lib/check_attempts.sh
if ! declare -F run_check_attempt >/dev/null 2>&1; then
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check_attempts.sh"
fi

generate_batch_review_material() {
  local base_commit="$1"
  local batch_diff="$2"
  local batch_untracked="$3"
  local batch_summary="$4"
  local has_material=0
  local path

  git diff --no-ext-diff "$base_commit" -- . "${CODEX_FLOW_WORKTREE_EXCLUDE_PATHS[@]}" > "$batch_diff"
  : > "$batch_untracked"

  while IFS= read -r path; do
    if [[ -z "$path" ]]; then
      continue
    fi

    has_material=1
    printf '%s\n' "$path" >> "$batch_untracked"
    append_untracked_file_diff_to_review_material "$path" "$batch_diff" 'batch'
  done < <(git ls-files --others --exclude-standard -- . "${CODEX_FLOW_WORKTREE_EXCLUDE_PATHS[@]}")

  write_review_material_summary "$base_commit" "$batch_summary" "$batch_untracked"

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
  local operation="$1"
  local round="$2"
  local prompt_file="$3"
  local output_log="$4"
  local reasoning_effort="$5"
  local snapshot_file="${6:-}"

  CODEX_RUN_REASONING_EFFORT="$reasoning_effort" \
    run_codex_with_attempt "$operation" "$round" write "$prompt_file" "$output_log" combined "$snapshot_file"
}

run_codex_batch_read() {
  local operation="$1"
  local round="$2"
  local prompt_file="$3"
  local output_log="$4"
  local reasoning_effort="$5"
  local snapshot_file="${6:-}"

  CODEX_RUN_REASONING_EFFORT="$reasoning_effort" \
    run_codex_with_attempt "$operation" "$round" read "$prompt_file" "$output_log" stdout "$snapshot_file"
}

run_batch_checks_once() {
  local base_commit="$1"
  local checks_log="$2"
  local round="$3"
  local batch_id="$4"
  local attempts_root="$5"
  local manifest_file="$6"
  local status

  if run_check_attempt \
    "$attempts_root" \
    "$manifest_file" \
    "$checks_log" \
    batch \
    "$batch_id" \
    batch-checks \
    "$round" \
    "$base_commit" \
    "$CODEX_FLOW_CHECKS_COMMAND" \
    "$base_commit"; then
    status=0
  else
    status=$?
  fi

  return "$status"
}

ensure_batch_checks_pass() {
  local batch_dir="$1"
  local issues_file="$2"
  local base_commit="$3"
  local first_issue="$4"
  local last_issue="$5"
  local issues_label="$6"
  local check_fix_effort="$7"
  local batch_state_dir="$8"
  local batch_id
  local checks_log="${batch_dir}/checks.log"
  local fix_checks_prompt="${batch_dir}/fix-from-batch-checks.prompt.md"
  local fix_checks_log="${batch_dir}/fix-from-batch-checks.log"
  local fix_round=0
  local history_dir="${batch_dir}/history"
  local attempts_root="${batch_state_dir}/check-attempts/batch"
  local manifest_file="${batch_state_dir}/checks/batch.manifest.tsv"
  local check_round

  batch_id="$(basename "$batch_state_dir")"

  mkdir -p "$history_dir"

  while true; do
    log_info 'running batch checks'
    check_round=$((fix_round + 1))
    if run_batch_checks_once "$base_commit" "$checks_log" "$check_round" "$batch_id" "$attempts_root" "$manifest_file"; then
      archive_round_file "$CHECK_ATTEMPT_LAST_LOG" 'batch-checks' "$check_round" '.log'
      log_info 'batch checks passed'
      return 0
    fi

    if [[ -n "${CHECK_ATTEMPT_LAST_LOG:-}" && -f "$CHECK_ATTEMPT_LAST_LOG" ]]; then
      archive_round_file "$CHECK_ATTEMPT_LAST_LOG" 'batch-checks' "$check_round" '.log'
    fi

    if [[ "${CHECK_ATTEMPT_LAST_PUBLISH_ERROR:-0}" -eq 1 ]]; then
      printf '[queue] batch checks completed but legacy log publication failed\n' >&2
      printf '[queue] see attempt: %s\n' "$CHECK_ATTEMPT_LAST_DIR" >&2
      return 1
    fi

    case "${CHECK_ATTEMPT_LAST_STATUS:-}" in
      invalid)
        printf '[queue] batch checks changed the repository and were recorded as invalid\n' >&2
        printf '[queue] see attempt: %s\n' "$CHECK_ATTEMPT_LAST_DIR" >&2
        return 1
        ;;
      interrupted)
        printf '[queue] batch checks were interrupted\n' >&2
        printf '[queue] see attempt: %s\n' "$CHECK_ATTEMPT_LAST_DIR" >&2
        return "${CHECK_ATTEMPT_LAST_EXIT_STATUS:-1}"
        ;;
    esac

    if [[ "$fix_round" -ge "$CODEX_FLOW_BATCH_CHECK_MAX_FIX_ROUNDS" ]]; then
      printf '[queue] batch checks failed after %s fix rounds\n' "$CODEX_FLOW_BATCH_CHECK_MAX_FIX_ROUNDS" >&2
      printf '[queue] see log: %s\n' "$checks_log" >&2
      exit 1
    fi

    fix_round=$((fix_round + 1))
    write_fix_from_batch_checks_prompt_file "$issues_file" "$checks_log" "$fix_checks_prompt"
    ensure_clean_worktree 'Working tree must be clean before batch checks fix.'
    log_info "codex fix from batch checks (round ${fix_round})"
    run_codex_batch_write batch-fix-from-checks "$fix_round" "$fix_checks_prompt" "$fix_checks_log" "$check_fix_effort"
    archive_round_file "$fix_checks_log" 'fix-from-batch-checks' "$fix_round" '.log'
    ensure_batch_token_usage_tsv "$batch_dir" 'fix-from-batch-checks' "$issues_label" "$fix_round" "$check_fix_effort" "$fix_checks_log"

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

write_batch_review_lifecycle() {
  local state_file="$1"
  local review_round="$2"
  local fix_round="$3"
  local next_action="$4"
  local temporary_file

  if [[ ! "$review_round" =~ ^[1-9][0-9]*$ ]]; then
    printf 'Batch review lifecycle review round is invalid: %s\n' "$review_round" >&2
    return 1
  fi
  if [[ ! "$fix_round" =~ ^[0-9]+$ ]]; then
    printf 'Batch review lifecycle fix round is invalid: %s\n' "$fix_round" >&2
    return 1
  fi
  if [[ "$next_action" != review && "$next_action" != fix && "$next_action" != complete ]]; then
    printf 'Batch review lifecycle next action is invalid: %s\n' "$next_action" >&2
    return 1
  fi

  temporary_file="$(mktemp "${state_file}.tmp.XXXXXX")" || {
    printf 'Failed to create temporary batch review lifecycle state: %s\n' "$state_file" >&2
    return 1
  }
  if ! printf '%s\t%s\n' \
    schema_version 1 \
    review_round "$review_round" \
    fix_round "$fix_round" \
    next_action "$next_action" \
    updated_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    > "$temporary_file"; then
    rm -f -- "$temporary_file"
    printf 'Failed to write batch review lifecycle state: %s\n' "$state_file" >&2
    return 1
  fi
  if ! mv -T -f -- "$temporary_file" "$state_file"; then
    rm -f -- "$temporary_file"
    printf 'Failed to publish batch review lifecycle state: %s\n' "$state_file" >&2
    return 1
  fi
}

initialize_batch_review_lifecycle() {
  local state_file="$1"

  if [[ -e "$state_file" ]]; then
    if [[ ! -f "$state_file" ]]; then
      printf 'Batch review lifecycle state is not a regular file: %s\n' "$state_file" >&2
      return 1
    fi
    return 0
  fi

  mkdir -p "$(dirname "$state_file")"
  write_batch_review_lifecycle "$state_file" 1 0 review
}

read_batch_review_lifecycle() {
  local state_file="$1"
  local values

  if [[ ! -f "$state_file" ]]; then
    printf 'Batch review lifecycle state does not exist: %s\n' "$state_file" >&2
    return 1
  fi

  if ! values="$(awk -F '\t' '
    NF != 2 { exit 1 }
    NR == 1 && ($1 != "schema_version" || $2 != "1") { exit 1 }
    NR == 2 && ($1 != "review_round" || $2 !~ /^[0-9]+$/ || $2 == 0) { exit 1 }
    NR == 3 && ($1 != "fix_round" || $2 !~ /^[0-9]+$/) { exit 1 }
    NR == 4 && ($1 != "next_action" || ($2 != "review" && $2 != "fix" && $2 != "complete")) { exit 1 }
    NR == 5 && ($1 != "updated_at" || $2 == "") { exit 1 }
    NR > 5 { exit 1 }
    NR == 2 { review_round = $2 }
    NR == 3 { fix_round = $2 }
    NR == 4 { next_action = $2 }
    END {
      if (NR != 5) exit 1
      print review_round "\t" fix_round "\t" next_action
    }
  ' "$state_file")"; then
    printf 'Batch review lifecycle state is invalid: %s\n' "$state_file" >&2
    return 1
  fi

  IFS=$'\t' read -r \
    BATCH_REVIEW_LIFECYCLE_REVIEW_ROUND \
    BATCH_REVIEW_LIFECYCLE_FIX_ROUND \
    BATCH_REVIEW_LIFECYCLE_NEXT_ACTION \
    <<< "$values"
}

reconcile_committed_batch_review_fix() {
  local snapshot_file="$1"
  local batch_state_dir="$2"
  local review_fix_round="$3"
  local first_issue="$4"
  local last_issue="$5"
  local expected_state
  local expected_head
  local current_head
  local resolution_history
  local review_fix_subject="chore: address batch review for issues #${first_issue}-#${last_issue}"
  local checks_fix_subject="chore: address batch checks for issues #${first_issue}-#${last_issue}"
  local commit
  local parents
  local previous_commit
  local subject
  local commit_index=0

  printf -v resolution_history '%s/history/fix-resolution.round-%02d.tsv' \
    "$batch_state_dir" "$review_fix_round"

  if [[ ! -f "$resolution_history" ]]; then
    printf 'Cannot reconcile committed batch review fix: resolution history is missing: %s\n' \
      "$resolution_history" >&2
    return 1
  fi
  if [[ -n "$(status_outside_work)" ]]; then
    printf 'Cannot reconcile committed batch review fix: working tree is not clean.\n' >&2
    return 1
  fi
  if ! expected_state="$(_review_snapshot_read_expected_state "$snapshot_file")"; then
    printf 'Cannot reconcile committed batch review fix: review snapshot is invalid: %s\n' \
      "$snapshot_file" >&2
    return 1
  fi
  IFS=$'\t' read -r expected_head _ <<< "$expected_state"
  if ! current_head="$(git rev-parse --verify 'HEAD^{commit}')"; then
    printf 'Cannot reconcile committed batch review fix: current HEAD is not a commit.\n' >&2
    return 1
  fi
  if [[ "$current_head" == "$expected_head" ]]; then
    printf 'Cannot reconcile committed batch review fix: no commit follows the review snapshot.\n' >&2
    return 1
  fi
  if ! git merge-base --is-ancestor "$expected_head" "$current_head"; then
    printf 'Cannot reconcile committed batch review fix: current HEAD does not descend from review snapshot HEAD %s.\n' \
      "$expected_head" >&2
    return 1
  fi

  previous_commit="$expected_head"
  while IFS= read -r commit; do
    commit_index=$((commit_index + 1))
    parents="$(git show -s --format=%P "$commit")"
    if [[ "$parents" != "$previous_commit" ]]; then
      printf 'Cannot reconcile committed batch review fix: commit %s is not on the expected linear frontier.\n' \
        "$commit" >&2
      return 1
    fi
    subject="$(git show -s --format=%s "$commit")"
    if [[ "$commit_index" -eq 1 ]]; then
      if [[ "$subject" != "$review_fix_subject" ]]; then
        printf 'Cannot reconcile committed batch review fix: first commit has unexpected subject: %s\n' \
          "$subject" >&2
        return 1
      fi
    elif [[ "$subject" != "$checks_fix_subject" ]]; then
      printf 'Cannot reconcile committed batch review fix: intervening commit has unexpected subject: %s\n' \
        "$subject" >&2
      return 1
    fi
    previous_commit="$commit"
  done < <(git rev-list --reverse "${expected_head}..${current_head}")

  if [[ "$commit_index" -eq 0 || "$previous_commit" != "$current_head" ]]; then
    printf 'Cannot reconcile committed batch review fix: expected fix commit range is incomplete.\n' >&2
    return 1
  fi
}

run_batch_review_once() {
  local batch_dir="$1"
  local issues_file="$2"
  local base_commit="$3"
  local issues_label="$4"
  local review_effort="$5"
  local review_round="$6"
  local batch_state_dir="$7"
  local batch_diff="${batch_dir}/batch.diff"
  local batch_untracked="${batch_dir}/batch.untracked.txt"
  local batch_summary="${batch_dir}/batch.summary.txt"
  local batch_review_prompt="${batch_dir}/batch-review.prompt.md"
  local batch_review_raw="${batch_dir}/batch-review.raw.txt"
  local batch_review_output="${batch_dir}/batch-review.txt"
  local batch_review_snapshot="${batch_dir}/batch-review.snapshot.state"
  local history_dir="${batch_dir}/history"
  local batch_findings_ledger="${batch_state_dir}/findings.tsv"
  local batch_findings_history_dir="${batch_state_dir}/history"
  local batch_fix_resolution="${batch_state_dir}/fix-resolution.tsv"
  local batch_review_verification="${batch_state_dir}/review-verification.tsv"

  mkdir -p "$history_dir" "$batch_findings_history_dir"
  generate_batch_review_material "$base_commit" "$batch_diff" "$batch_untracked" "$batch_summary"
  archive_round_file "$batch_diff" 'batch-diff' "$review_round" '.txt'
  archive_round_file "$batch_untracked" 'batch-untracked' "$review_round" '.txt'
  archive_round_file "$batch_summary" 'batch-summary' "$review_round" '.txt'
  write_batch_review_prompt_file \
    "$issues_file" \
    "$batch_diff" \
    "$batch_untracked" \
    "$batch_summary" \
    "$batch_review_prompt" \
    "$batch_findings_ledger" \
    "$batch_fix_resolution"

  capture_review_snapshot "$batch_review_snapshot"
  log_info "codex batch review (round ${review_round})"
  run_codex_batch_read \
    batch-review "$review_round" "$batch_review_prompt" "$batch_review_raw" \
    "$review_effort" "$batch_review_snapshot"
  assert_review_snapshot_matches "$batch_review_snapshot" "after batch review"
  archive_round_file "$batch_review_raw" 'batch-review-raw' "$review_round" '.txt'
  ensure_batch_token_usage_tsv "$batch_dir" 'batch-review' "$issues_label" "$review_round" "$review_effort" "$batch_review_raw"

  if ! extract_structured_review_output_file "$batch_review_raw" "$batch_review_output"; then
    printf 'Failed to extract structured batch review output.\n' >&2
    printf 'Batch review raw log: %s\n' "$batch_review_raw" >&2
    exit 1
  fi
  archive_round_file "$batch_review_output" 'batch-review' "$review_round" '.txt'
  ensure_valid_batch_review_output "$batch_review_raw" "$batch_review_output"
  extract_review_verification \
    "$batch_review_output" \
    "$batch_findings_ledger" \
    "$batch_fix_resolution" \
    "$batch_review_verification"
  update_finding_ledger \
    "$batch_review_output" \
    "$batch_findings_ledger" \
    "$review_round" \
    "$batch_review_verification"
  history_dir="$batch_findings_history_dir"
  archive_round_file "$batch_findings_ledger" 'findings' "$review_round" '.tsv'
  cp -- "$batch_findings_ledger" "${batch_dir}/findings.tsv"
  cp -- "$(history_round_path 'findings' "$review_round" '.tsv')" "${batch_dir}/history/"
  cp -- "$batch_review_verification" "${batch_dir}/review-verification.tsv"
}

ensure_batch_review_accepted() {
  local batch_dir="$1"
  local issues_file="$2"
  local base_commit="$3"
  local first_issue="$4"
  local last_issue="$5"
  local issues_label="$6"
  local review_effort="$7"
  local review_fix_effort="$8"
  local check_fix_effort="$9"
  local batch_state_dir="${10}"
  local batch_review_output="${batch_dir}/batch-review.txt"
  local fix_review_prompt="${batch_dir}/fix-from-batch-review.prompt.md"
  local fix_review_log="${batch_dir}/fix-from-batch-review.log"
  local batch_review_snapshot="${batch_dir}/batch-review.snapshot.state"
  local batch_findings_ledger="${batch_state_dir}/findings.tsv"
  local batch_pending_findings="${batch_state_dir}/pending-findings.tsv"
  local batch_fix_resolution="${batch_state_dir}/fix-resolution.tsv"
  local batch_state_history_dir="${batch_state_dir}/history"
  local lifecycle_state="${batch_state_dir}/review-lifecycle.state"
  local review_fix_round
  local review_round
  local next_action
  local fix_commit_reconciled
  local run_fix_checks
  local history_dir="${batch_dir}/history"

  mkdir -p "$history_dir"
  initialize_batch_review_lifecycle "$lifecycle_state"

  while true; do
    read_batch_review_lifecycle "$lifecycle_state"
    review_round="$BATCH_REVIEW_LIFECYCLE_REVIEW_ROUND"
    review_fix_round="$BATCH_REVIEW_LIFECYCLE_FIX_ROUND"
    next_action="$BATCH_REVIEW_LIFECYCLE_NEXT_ACTION"

    case "$next_action" in
      review)
        run_batch_review_once "$batch_dir" "$issues_file" "$base_commit" "$issues_label" "$review_effort" "$review_round" "$batch_state_dir"
        if review_output_accepted "$batch_review_output"; then
          write_batch_review_lifecycle "$lifecycle_state" "$review_round" "$review_fix_round" complete
          if declare -F queue_failpoint >/dev/null 2>&1; then
            queue_failpoint after_batch_review_lifecycle_complete
          fi
        else
          review_fix_round="$review_round"
          write_batch_review_lifecycle "$lifecycle_state" "$review_round" "$review_fix_round" fix
          if declare -F queue_failpoint >/dev/null 2>&1; then
            queue_failpoint after_batch_review_lifecycle_fix
          fi
        fi
        ;;
      fix)
        if [[ "$review_fix_round" -gt "$CODEX_FLOW_BATCH_REVIEW_MAX_FIX_ROUNDS" ]]; then
          printf '[queue] batch review did not reach acceptance after %s fix rounds\n' "$CODEX_FLOW_BATCH_REVIEW_MAX_FIX_ROUNDS" >&2
          printf '[queue] see review: %s\n' "$batch_review_output" >&2
          exit 1
        fi

        fix_commit_reconciled=0
        run_fix_checks=0
        if ! assert_review_snapshot_matches "$batch_review_snapshot" "before batch review fix" 2>/dev/null; then
          if ! reconcile_committed_batch_review_fix \
            "$batch_review_snapshot" \
            "$batch_state_dir" \
            "$review_fix_round" \
            "$first_issue" \
            "$last_issue"; then
            exit 1
          fi
          fix_commit_reconciled=1
          run_fix_checks=1
          log_info "adopting committed batch review fix (round ${review_fix_round})"
        fi

        if [[ "$fix_commit_reconciled" -eq 0 ]]; then
          write_pending_findings "$batch_findings_ledger" "$batch_pending_findings"
          cp -- "$batch_pending_findings" "${batch_dir}/pending-findings.tsv"
          write_fix_from_batch_review_prompt_file \
            "$issues_file" \
            "$batch_review_output" \
            "$fix_review_prompt" \
            "$batch_pending_findings" \
            "$batch_review_snapshot"
          ensure_clean_worktree 'Working tree must be clean before batch review fix.'
          log_info "codex fix from batch review (round ${review_fix_round})"
          run_codex_batch_write \
            batch-fix-from-review "$review_fix_round" "$fix_review_prompt" "$fix_review_log" \
            "$review_fix_effort" "$batch_review_snapshot"
          archive_round_file "$fix_review_log" 'fix-from-batch-review' "$review_fix_round" '.log'
          ensure_batch_token_usage_tsv "$batch_dir" 'fix-from-batch-review' "$issues_label" "$review_fix_round" "$review_fix_effort" "$fix_review_log"
          extract_fix_resolution_report "$fix_review_log" "$batch_pending_findings" "$batch_fix_resolution"
          history_dir="$batch_state_history_dir"
          archive_round_file "$batch_fix_resolution" 'fix-resolution' "$review_fix_round" '.tsv'
          cp -- "$batch_fix_resolution" "${batch_dir}/fix-resolution.tsv"
          cp -- "$(history_round_path 'fix-resolution' "$review_fix_round" '.tsv')" "${batch_dir}/history/"
          history_dir="${batch_dir}/history"

          if [[ -z "$(status_outside_work)" ]]; then
            if awk -F '\t' '$2 == "fixed" { found = 1 } END { exit !found }' "$batch_fix_resolution"; then
              printf 'Batch review fix reported fixed findings but produced no repository changes.\n' >&2
              printf 'Batch review fix log: %s\n' "$fix_review_log" >&2
              exit 1
            fi
            log_info 'batch review fix reported no code changes; skipping commit and checks'
          else
            commit_issue_changes "chore: address batch review for issues #${first_issue}-#${last_issue}" 1
            run_fix_checks=1
            if declare -F queue_failpoint >/dev/null 2>&1; then
              queue_failpoint after_batch_review_fix_commit
            fi
          fi
        fi

        if [[ "$run_fix_checks" -eq 1 ]]; then
          ensure_batch_checks_pass "$batch_dir" "$issues_file" "$base_commit" "$first_issue" "$last_issue" "$issues_label" "$check_fix_effort" "$batch_state_dir"
          if declare -F queue_failpoint >/dev/null 2>&1; then
            queue_failpoint after_batch_review_fix_checks
          fi
        fi

        review_round=$((review_round + 1))
        write_batch_review_lifecycle "$lifecycle_state" "$review_round" "$review_fix_round" review
        if declare -F queue_failpoint >/dev/null 2>&1; then
          queue_failpoint after_batch_review_lifecycle_review
        fi
        ;;
      complete)
        return 0
        ;;
    esac
  done
}
